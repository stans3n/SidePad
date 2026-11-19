import Foundation
import Combine
import CryptoKit

enum ThreadStoreError: LocalizedError {
    case invalidHierarchy(String)
    case invalidFile(String)
    case externalChange
    case readOnly(String)
    case recoveryRequired(String)

    var errorDescription: String? {
        switch self {
        case .invalidHierarchy(let reason), .invalidFile(let reason): return reason
        case .externalChange: return "Markdown files changed outside SidePad. Your draft was not saved. Reload the files, then review or save your draft as a new Thread."
        case .readOnly(let reason): return "Threads are read-only until a successful reload. \(reason)"
        case .recoveryRequired(let path): return "An interrupted Thread transaction needs recovery. Original files and planned changes are preserved at \(path). See docs/threads/MARKDOWN_SCHEMA.md before reloading."
        }
    }
}

@MainActor
final class ThreadStore: ObservableObject {
    @Published private(set) var threads: [ThreadRecord] = []
    @Published var errorMessage: String?
    @Published private(set) var isReadOnly = false
    let directory: URL

    private struct Loaded {
        var url: URL
        var markdown: ThreadMarkdown
    }
    private struct Mutation {
        var url: URL
        var before: Data?
        var after: Data?
    }
    private var documents: [UUID: Loaded] = [:]
    private var snapshot: [URL: Data] = [:]
    private let fileManager = FileManager.default
    private static let transactionPrefix = ".thread-transaction-"
    /// Fault injection before a file mutation; used only by deterministic rollback tests.
    var writeFailureInjector: ((Int) throws -> Void)?

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SidePad/Threads", isDirectory: true)
    }

    init(directory: URL = ThreadStore.defaultDirectory) {
        self.directory = directory.standardizedFileURL
        do { try reload() }
        catch { errorMessage = error.localizedDescription }
    }

    func fileURL(for id: UUID) -> URL {
        documents[id]?.url ?? directory.appendingPathComponent(id.uuidString.lowercased() + ".md")
    }

    /// Reload is explicit. A failed reload preserves the last valid model and blocks mutation.
    func reload() throws {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if let pending = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first(where: { $0.lastPathComponent.hasPrefix(Self.transactionPrefix) }) {
                throw ThreadStoreError.recoveryRequired(pending.path)
            }
            let disk = try readSnapshot()
            var loaded: [UUID: Loaded] = [:]
            for url in disk.keys.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let source = String(data: disk[url]!, encoding: .utf8) else {
                    throw ThreadStoreError.invalidFile("\(url.lastPathComponent) is not UTF-8 Markdown.")
                }
                let markdown: ThreadMarkdown
                do { markdown = try ThreadMarkdown.parse(source) }
                catch { throw ThreadStoreError.invalidFile("\(url.lastPathComponent): \(error.localizedDescription)") }
                guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) == markdown.record.id else {
                    throw ThreadStoreError.invalidFile("\(url.lastPathComponent): filename must match its frontmatter UUID.")
                }
                guard loaded[markdown.record.id] == nil else {
                    throw ThreadStoreError.invalidFile("Duplicate Thread UUID: \(markdown.record.id)")
                }
                loaded[markdown.record.id] = Loaded(url: url, markdown: markdown)
            }
            let parsedRecords: [ThreadRecord] = loaded.values.map { $0.markdown.record }
            let records = parsedRecords.sorted { (lhs: ThreadRecord, rhs: ThreadRecord) -> Bool in
                if lhs.title == rhs.title { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            try Self.validateHierarchy(records)
            try validateReloadedEvidence(records)
            documents = loaded
            snapshot = disk
            threads = records
            isReadOnly = false
            errorMessage = nil
        } catch {
            isReadOnly = true
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func save(_ record: ThreadRecord) throws {
        var records = threads
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
        else { records.append(record) }
        try commit(records)
    }

    /// Save a deliberate recovery point entirely locally. Optional context fields are only
    /// changed when supplied; the legacy Resume Point is never rewritten or relabelled.
    @discardableResult
    func addCheckpoint(threadID: UUID, note: String, nextAction: String? = nil,
                       currentState: String? = nil, blockers: String? = nil,
                       resources: [String] = [], relatedTaskIDs: [UUID] = [],
                       expectedThread: ThreadRecord? = nil, checkpointID: UUID = UUID(),
                       now: Date = Date()) throws -> ThreadCheckpoint {
        try verifyUnchanged()
        guard var thread = threads.first(where: { $0.id == threadID }) else {
            throw ThreadStoreError.invalidFile("The project no longer exists. Reload before saving a checkpoint.")
        }
        if let saved = threads.lazy.flatMap(\.checkpoints).first(where: { $0.id == checkpointID }) {
            guard thread.checkpoints.contains(where: { $0.id == checkpointID }), saved.origin == .manual,
                  saved.threadID == threadID, saved.note == note, saved.resources == resources,
                  saved.relatedTaskIDs == relatedTaskIDs,
                  nextAction == nil || nextAction == saved.snapshot?.nextAction,
                  currentState == nil || currentState == saved.snapshot?.currentState,
                  blockers == nil || blockers == saved.snapshot?.blockers else {
                throw ThreadStoreError.invalidFile("This checkpoint ID already belongs to different saved evidence.")
            }
            return saved
        }
        guard thread.status != .archived else {
            throw ThreadStoreError.invalidFile("Reopen this project before adding a checkpoint.")
        }
        if let expectedThread, expectedThread != thread {
            throw ThreadStoreError.externalChange
        }
        if let nextAction { thread.nextAction = nextAction }
        if let currentState { thread.currentState = currentState }
        if let blockers { thread.blockers = blockers }
        let checkpoint = ThreadCheckpoint(id: checkpointID, threadID: threadID, createdAt: now,
            note: note, snapshot: ProgressSnapshot(thread: thread), relatedTaskIDs: relatedTaskIDs,
            resources: resources, origin: .manual)
        try ThreadCheckpoint.validate([checkpoint])
        thread.checkpoints.append(checkpoint)
        thread.updatedAt = checkpoint.createdAt
        thread.lastActivity = checkpoint.createdAt
        try save(thread)
        return checkpoint
    }

    /// Check persisted evidence without changing the loaded model or writing any files.
    func verifyUnchanged() throws {
        guard !isReadOnly else { throw ThreadStoreError.readOnly(errorMessage ?? "Fix the Markdown files and reload.") }
        guard try readSnapshot() == snapshot else { throw ThreadStoreError.externalChange }
    }

    /// Replace the collection, including removals used to undo an earlier creation batch.
    func commit(_ records: [ThreadRecord], allowActivityRemoval: Bool = false) throws {
        do {
            try verifyUnchanged()
            try Self.validateHierarchy(records)
            try validateExistingEvidence(records, allowActivityRemoval: allowActivityRemoval)
            var desired: [URL: Data] = [:]
            var loaded: [UUID: Loaded] = [:]
            for record in records {
                if let existing = documents[record.id], existing.markdown.record == record {
                    loaded[record.id] = existing
                    desired[existing.url] = snapshot[existing.url]
                    continue
                }
                let source = try documents[record.id]?.markdown.updating(record) ?? ThreadMarkdown.serialize(record)
                let parsed = try ThreadMarkdown.parse(source)
                let url = fileURL(for: record.id)
                let data = Data(source.utf8)
                guard data.count <= 5 * 1_024 * 1_024 else {
                    throw ThreadStoreError.invalidFile("\(url.lastPathComponent): prototype Thread size limit is 5 MiB.")
                }
                desired[url] = data
                loaded[record.id] = Loaded(url: url, markdown: parsed)
            }
            try Self.validateHierarchy(loaded.values.map(\.markdown.record))
            let mutations = Set(snapshot.keys).union(desired.keys).sorted(by: { $0.path < $1.path }).compactMap { url -> Mutation? in
                guard snapshot[url] != desired[url] else { return nil }
                return Mutation(url: url, before: snapshot[url], after: desired[url])
            }
            // Retain the original bytes before the first checkpoint schema upgrade. Reading
            // old files and ordinary edits remain non-migrating; repeated saves reuse backups.
            for (id, updated) in loaded {
                if let original = documents[id], original.markdown.schemaVersion < updated.markdown.schemaVersion,
                   let bytes = snapshot[original.url] {
                    try backupBeforeMigration(id: id, version: original.markdown.schemaVersion, bytes: bytes)
                }
            }
            if !mutations.isEmpty { try apply(mutations) }
            documents = loaded
            snapshot = desired
            // Disk timestamps use ISO 8601 millisecond precision; publish the canonical parsed values.
            threads = records.compactMap { loaded[$0.id]?.markdown.record }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    static func validateHierarchy(_ records: [ThreadRecord]) throws {
        var byID: [UUID: ThreadRecord] = [:]
        var eventsByID: [UUID: ProgressEvent] = [:]
        var checkpointsByID: [UUID: ThreadCheckpoint] = [:]
        for record in records {
            guard byID[record.id] == nil else { throw ThreadStoreError.invalidHierarchy("Duplicate Thread UUID: \(record.id)") }
            guard !record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !record.title.contains(where: { $0.isNewline || $0 == "\0" }),
                  record.createdAt.timeIntervalSince1970.isFinite, record.updatedAt.timeIntervalSince1970.isFinite,
                  record.lastActivity.timeIntervalSince1970.isFinite else {
                throw ThreadStoreError.invalidHierarchy("Thread titles must be nonempty single lines and timestamps must be valid.")
            }
            byID[record.id] = record
            try ProgressEvent.validate(record.progressEvents)
            try ThreadCheckpoint.validate(record.checkpoints)
            for checkpoint in record.checkpoints {
                if let existing = checkpointsByID[checkpoint.id], existing != checkpoint {
                    throw ThreadStoreError.invalidHierarchy("Conflicting copies of checkpoint UUID: \(checkpoint.id)")
                }
                checkpointsByID[checkpoint.id] = checkpoint
            }
            for event in record.progressEvents {
                if let existing = eventsByID[event.id], existing != event {
                    throw ThreadStoreError.invalidHierarchy("Conflicting copies of progress event UUID: \(event.id)")
                }
                eventsByID[event.id] = event
            }
        }
        var checked = Set<UUID>()
        for record in records {
            var path = Set<UUID>()
            var current: UUID? = record.id
            while let id = current, !checked.contains(id) {
                guard path.insert(id).inserted else { throw ThreadStoreError.invalidHierarchy("A Thread cannot be its own ancestor.") }
                guard let node = byID[id] else { throw ThreadStoreError.invalidHierarchy("A parent Thread is missing: \(id)") }
                current = node.parentID
            }
            checked.formUnion(path)
        }
    }

    private func validateExistingEvidence(_ records: [ThreadRecord], allowActivityRemoval: Bool) throws {
        let retained = Set(records.map(\.id))
        for (id, loaded) in documents where !retained.contains(id) {
            guard loaded.markdown.record.checkpoints.isEmpty,
                  allowActivityRemoval || loaded.markdown.record.progressEvents.isEmpty else {
                throw ThreadStoreError.invalidFile("A project with recorded history cannot be removed. Archive it instead.")
            }
        }
        for record in records {
            guard let previous = documents[record.id]?.markdown.record else { continue }
            let events = Dictionary(uniqueKeysWithValues: previous.progressEvents.map { ($0.id, $0) })
            for event in record.progressEvents {
                if let original = events[event.id], original != event {
                    throw ThreadStoreError.invalidFile("Recorded activity snapshots cannot be edited. Add a new update instead.")
                }
            }
            if !allowActivityRemoval {
                let retainedEvents = Set(record.progressEvents.map(\.id))
                guard previous.progressEvents.allSatisfy({ retainedEvents.contains($0.id) }) else {
                    throw ThreadStoreError.invalidFile("Recorded activity cannot be removed by a normal save. Add a new update instead.")
                }
            }
            // Confirmed Intent Undo may remove its own activity batch, but deliberate checkpoints have
            // no destructive restore/undo action and stay append-only in application writes.
            let checkpoints = Dictionary(uniqueKeysWithValues: record.checkpoints.map { ($0.id, $0) })
            for original in previous.checkpoints where checkpoints[original.id] != original {
                throw ThreadStoreError.invalidFile("Saved checkpoints cannot be edited or removed. Add a new checkpoint instead.")
            }
        }
    }

    private func validateReloadedEvidence(_ records: [ThreadRecord]) throws {
        let reloaded = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        for (id, previous) in documents {
            let old = previous.markdown.record
            guard !old.progressEvents.isEmpty || !old.checkpoints.isEmpty else { continue }
            let current = reloaded[id]
            let events = Dictionary(uniqueKeysWithValues: (current?.progressEvents ?? []).map { ($0.id, $0) })
            let checkpoints = Dictionary(uniqueKeysWithValues: (current?.checkpoints ?? []).map { ($0.id, $0) })
            let historyChanged = old.progressEvents.contains { events[$0.id] != $0 }
                || old.checkpoints.contains { checkpoints[$0.id] != $0 }
            if historyChanged, let originalBytes = snapshot[previous.url] {
                let recovery = try backupSnapshot(id: id, label: "history", bytes: originalBytes, folderName: ".history-recovery")
                throw ThreadStoreError.invalidFile("Recorded history changed outside SidePad. The last valid project is retained; original Markdown is backed up at \(recovery.path). Restore that evidence before reloading. New current-state edits can be kept separately.")
            }
        }
    }

    private func backupBeforeMigration(id: UUID, version: Int, bytes: Data) throws {
        _ = try backupSnapshot(id: id, label: "v\(version)", bytes: bytes, folderName: ".schema-backups")
    }

    @discardableResult
    private func backupSnapshot(id: UUID, label: String, bytes: Data, folderName: String) throws -> URL {
        let folder = directory.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let properties = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink != true else {
            throw ThreadStoreError.invalidFile("Recovery backups must be stored in a regular directory.")
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let destination = folder.appendingPathComponent("\(id.uuidString.lowercased())-\(label)-\(digest).md")
        if fileManager.fileExists(atPath: destination.path) {
            guard try currentData(at: destination) == bytes else {
                throw ThreadStoreError.invalidFile("An existing migration backup does not match the source; no project was changed.")
            }
        } else {
            // Exclusive publication prevents replacing a concurrently created backup.
            let staging = folder.appendingPathComponent(".backup-" + UUID().uuidString)
            defer { try? fileManager.removeItem(at: staging) }
            try bytes.write(to: staging, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
            try fileManager.linkItem(at: staging, to: destination)
        }
        return destination
    }

    private func readSnapshot() throws -> [URL: Data] {
        let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        var result: [URL: Data] = [:]
        for url in urls where url.pathExtension.lowercased() == "md" {
            let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true else {
                throw ThreadStoreError.invalidFile("\(url.lastPathComponent): Thread files must be regular files, not symbolic links.")
            }
            guard (properties.fileSize ?? 0) <= 5 * 1_024 * 1_024 else {
                throw ThreadStoreError.invalidFile("\(url.lastPathComponent): prototype Thread size limit is 5 MiB.")
            }
            result[url.standardizedFileURL] = try Data(contentsOf: url)
        }
        return result
    }

    private func currentData(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw ThreadStoreError.externalChange }
        return try Data(contentsOf: url)
    }

    private func write(_ data: Data?, to url: URL) throws {
        if let data { try data.write(to: url, options: .atomic) }
        else if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func apply(_ mutations: [Mutation]) throws {
        let transaction = directory.appendingPathComponent(Self.transactionPrefix + UUID().uuidString.lowercased(), isDirectory: true)
        let before = transaction.appendingPathComponent("before", isDirectory: true)
        let after = transaction.appendingPathComponent("after", isDirectory: true)
        var applied: [Mutation] = []
        do {
            try fileManager.createDirectory(at: before, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: after, withIntermediateDirectories: true)
            for mutation in mutations {
                try mutation.before?.write(to: before.appendingPathComponent(mutation.url.lastPathComponent), options: .atomic)
                try mutation.after?.write(to: after.appendingPathComponent(mutation.url.lastPathComponent), options: .atomic)
            }
            let manifest: [[String: Any]] = mutations.map {
                ["filename": $0.url.lastPathComponent, "existed_before": $0.before != nil, "exists_after": $0.after != nil]
            }
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: transaction.appendingPathComponent("manifest.json"), options: .atomic)
            guard try readSnapshot() == snapshot else { throw ThreadStoreError.externalChange }
            for (index, mutation) in mutations.enumerated() {
                try writeFailureInjector?(index)
                guard try currentData(at: mutation.url) == mutation.before else { throw ThreadStoreError.externalChange }
                try write(mutation.after, to: mutation.url)
                applied.append(mutation)
            }
            // An unrelated new or edited file appearing during the batch also forces rollback.
            var expected = snapshot
            for mutation in mutations { expected[mutation.url] = mutation.after }
            guard try readSnapshot() == expected else { throw ThreadStoreError.externalChange }
            try fileManager.removeItem(at: transaction)
        } catch {
            let originalError = error
            do {
                for mutation in applied.reversed() {
                    // Never overwrite a new external edit while trying to roll back our own write.
                    guard try currentData(at: mutation.url) == mutation.after else { throw ThreadStoreError.externalChange }
                    try write(mutation.before, to: mutation.url)
                }
                if fileManager.fileExists(atPath: transaction.path) { try fileManager.removeItem(at: transaction) }
            } catch {
                isReadOnly = true
                throw ThreadStoreError.recoveryRequired(transaction.path)
            }
            throw originalError
        }
    }
}
