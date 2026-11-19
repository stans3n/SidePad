import Foundation

struct MemorySyncMapping: Codable, Equatable {
    var threadID: UUID
    var pageID: UUID
    var localRevision: String?
    var remoteRevision: String?
    var syncedAt: Date?
    var pendingWrite: MemoryPendingWrite?
    var review: MemorySyncReview?
}

struct MemoryPendingWrite: Codable, Equatable {
    var localRevision: String
    var priorRemoteRevision: String
    var desiredMarkdown: String
    var startedAt: Date
}

struct MemorySyncReview: Codable, Equatable {
    var localMarkdown: String
    var remoteMarkdown: String
    var localRevision: String
    var remoteRevision: String
    var observedAt: Date
}

/// Separate, local-only metadata. A failed or externally modified journal never affects Markdown loading.
@MainActor
final class MemorySyncJournal {
    private struct File: Codable { var schemaVersion = 1; var mappings: [MemorySyncMapping] = [] }
    private let url: URL
    private var source: Data?
    private(set) var mappings: [MemorySyncMapping] = []

    init(directory: URL) throws {
        url = directory.appendingPathComponent(".notion-sync", isDirectory: true).appendingPathComponent("state.json")
        try reload()
    }

    func reload() throws {
        let data = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        let value = try data.map { try JSONDecoder().decode(File.self, from: $0) } ?? File()
        guard value.schemaVersion == 1, Set(value.mappings.map(\.threadID)).count == value.mappings.count,
              Set(value.mappings.map(\.pageID)).count == value.mappings.count else { throw MemorySyncError.invalidDocument }
        mappings = value.mappings; source = data
    }

    func mapping(for id: UUID) -> MemorySyncMapping? { mappings.first { $0.threadID == id } }

    func save(_ mapping: MemorySyncMapping) throws {
        guard !mappings.contains(where: { $0.pageID == mapping.pageID && $0.threadID != mapping.threadID }) else {
            throw MemorySyncError.alreadyLinked
        }
        var values = mappings.filter { $0.threadID != mapping.threadID }; values.append(mapping)
        try write(values)
    }

    /// Explicit unlink removes identity metadata only; both content copies remain intact.
    func unlink(threadID: UUID) throws { try write(mappings.filter { $0.threadID != threadID }) }

    private func write(_ mappings: [MemorySyncMapping]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let output = try encoder.encode(File(mappings: mappings))
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                let current = FileManager.default.fileExists(atPath: target.path) ? try Data(contentsOf: target) : nil
                guard current == source else { throw MemorySyncError.metadataChanged }
                try output.write(to: target, options: .atomic)
            } catch { writeError = error }
        }
        if let error = coordinationError { throw error }
        if let error = writeError { throw error }
        self.mappings = mappings; source = output
    }
}

enum MemorySyncDisposition: String, Equatable {
    case initialReview, upToDate, localChanges, remoteChanges, conflict, reconcileRequired
}

struct MemorySyncPreview {
    var threadID: UUID
    var local: ProjectMemorySnapshot
    var remote: RemoteMemoryPage
    var disposition: MemorySyncDisposition
}

/// Two-phase, user-driven sync. Prepare never writes remote or project content.
/// Each confirmation checks the preview again. A failed write remains journalled until reconciled.
@MainActor
final class ProjectMemorySync {
    private let local: any ProjectMemoryRepository
    private let remote: any MemoryRemoteRepository
    let journal: MemorySyncJournal
    private var isBusy = false

    init(local: any ProjectMemoryRepository, remote: any MemoryRemoteRepository, journal: MemorySyncJournal) {
        self.local = local; self.remote = remote; self.journal = journal
    }

    func link(threadID: UUID, pageID: UUID) async throws {
        guard !isBusy else { throw MemorySyncError.busy }; isBusy = true; defer { isBusy = false }
        guard journal.mapping(for: threadID) == nil,
              !journal.mappings.contains(where: { $0.pageID == pageID }) else { throw MemorySyncError.alreadyLinked }
        _ = try local.snapshot(threadID: threadID)
        let page = try await remote.retrieve(pageID: pageID)
        if !page.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let document = try? ProjectMemoryDocument.parse(page.markdown), document.threadID == threadID else {
                throw MemorySyncError.identityChanged
            }
        }
        try journal.save(MemorySyncMapping(threadID: threadID, pageID: pageID))
    }

    func prepare(threadID: UUID) async throws -> MemorySyncPreview {
        guard !isBusy else { throw MemorySyncError.busy }; isBusy = true; defer { isBusy = false }
        guard var mapping = journal.mapping(for: threadID) else { throw MemorySyncError.noMapping }
        let snapshot = try local.snapshot(threadID: threadID)
        let page = try await remote.retrieve(pageID: mapping.pageID)
        var disposition: MemorySyncDisposition?
        if let pending = mapping.pendingWrite {
            if let expected = try? ProjectMemoryDocument.parse(pending.desiredMarkdown),
               let observed = try? ProjectMemoryDocument.parse(page.markdown), expected == observed {
                // A response may have been lost after Notion saved successfully. Do not send it twice.
                mapping.localRevision = pending.localRevision; mapping.remoteRevision = page.revision
                mapping.syncedAt = Date(); mapping.pendingWrite = nil
            } else if page.revision == pending.priorRemoteRevision {
                // No observed remote mutation. A new explicit confirmation may retry.
                mapping.pendingWrite = nil
            } else { disposition = .reconcileRequired }
        }
        if disposition == nil {
            if let baseLocal = mapping.localRevision, let baseRemote = mapping.remoteRevision {
                switch (snapshot.revision != baseLocal, page.revision != baseRemote) {
                case (false, false): disposition = .upToDate
                case (true, false): disposition = .localChanges
                case (false, true): disposition = .remoteChanges
                case (true, true): disposition = .conflict
                }
            } else { disposition = .initialReview }
        }
        // Preserve both candidates before any later confirmation or recovery attempt.
        mapping.review = MemorySyncReview(localMarkdown: try snapshot.document.markdown(), remoteMarkdown: page.markdown,
            localRevision: snapshot.revision, remoteRevision: page.revision, observedAt: Date())
        try journal.save(mapping)
        return MemorySyncPreview(threadID: threadID, local: snapshot, remote: page, disposition: disposition!)
    }

    func confirmPush(_ preview: MemorySyncPreview) async throws {
        guard !isBusy else { throw MemorySyncError.busy }; isBusy = true; defer { isBusy = false }
        guard var mapping = journal.mapping(for: preview.threadID), mapping.pageID == preview.remote.pageID else {
            throw MemorySyncError.noMapping
        }
        guard mapping.pendingWrite == nil else { throw MemorySyncError.uncertainWrite }
        // Both-changed states require manual reconciliation, not a last-write-wins button.
        guard preview.disposition == .localChanges || preview.disposition == .initialReview else {
            throw MemorySyncError.remoteChanged
        }
        let snapshot = try local.snapshot(threadID: preview.threadID)
        guard snapshot.revision == preview.local.revision else { throw MemorySyncError.localChanged }
        let markdown = try snapshot.document.markdown()
        mapping.pendingWrite = MemoryPendingWrite(localRevision: snapshot.revision,
            priorRemoteRevision: preview.remote.revision, desiredMarkdown: markdown, startedAt: Date())
        try journal.save(mapping)
        let result = try await remote.replace(pageID: mapping.pageID, expected: preview.remote, markdown: markdown)
        mapping.localRevision = snapshot.revision; mapping.remoteRevision = result.revision
        mapping.syncedAt = Date(); mapping.pendingWrite = nil; mapping.review = nil
        try journal.save(mapping)
    }

    /// The caller presents a merged current-state document for explicit review. Historical identities
    /// are still checked by the local repository. Upload remains a separate confirmation afterwards.
    func confirmReconciliation(_ preview: MemorySyncPreview, merged: ProjectMemoryDocument) async throws {
        guard !isBusy else { throw MemorySyncError.busy }; isBusy = true; defer { isBusy = false }
        guard var mapping = journal.mapping(for: preview.threadID), mapping.pageID == preview.remote.pageID else {
            throw MemorySyncError.noMapping
        }
        guard preview.disposition == .conflict || preview.disposition == .reconcileRequired,
              merged.threadID == preview.threadID else { throw MemorySyncError.identityChanged }
        let page = try await remote.retrieve(pageID: mapping.pageID)
        guard page.revision == preview.remote.revision else { throw MemorySyncError.remoteChanged }
        _ = try local.applyReviewed(merged, expectedRevision: preview.local.revision)
        // No synchronisation has succeeded yet. The resolved pair returns to explicit initial review.
        mapping.localRevision = nil; mapping.remoteRevision = nil; mapping.syncedAt = nil
        mapping.pendingWrite = nil
        try journal.save(mapping)
    }

    func confirmImport(_ preview: MemorySyncPreview) async throws {
        guard !isBusy else { throw MemorySyncError.busy }; isBusy = true; defer { isBusy = false }
        guard var mapping = journal.mapping(for: preview.threadID), mapping.pageID == preview.remote.pageID else {
            throw MemorySyncError.noMapping
        }
        guard mapping.pendingWrite == nil else { throw MemorySyncError.uncertainWrite }
        guard preview.disposition == .remoteChanges || preview.disposition == .initialReview else {
            throw MemorySyncError.localChanged
        }
        let page = try await remote.retrieve(pageID: mapping.pageID)
        guard page.revision == preview.remote.revision else { throw MemorySyncError.remoteChanged }
        let document = try ProjectMemoryDocument.parse(page.markdown)
        guard document.threadID == preview.threadID else { throw MemorySyncError.identityChanged }
        let saved = try local.applyReviewed(document, expectedRevision: preview.local.revision)
        mapping.localRevision = saved.revision; mapping.remoteRevision = page.revision
        mapping.syncedAt = Date(); mapping.review = nil
        try journal.save(mapping)
    }
}
