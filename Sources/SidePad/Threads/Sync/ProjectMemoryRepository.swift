import Foundation
import CryptoKit

/// The portable, editable part of a project. Tasks and historical evidence remain local authorities.
struct ProjectMemoryDocument: Codable, Equatable {
    var schemaVersion = 1
    var threadID: UUID
    var parentID: UUID?
    var title: String
    var status: ThreadStatus
    var summary: String
    var currentState: String
    var nextAction: String
    var blockers: String
    var resumePoint: String
    var notes: String
    var linkedResources: String
    var taskIDs: [UUID]
    var checkpointIDs: [UUID]
    var activityIDs: [UUID]

    init(thread: ThreadRecord, tasks: [TaskItem]) {
        threadID = thread.id; parentID = thread.parentID; title = thread.title; status = thread.status
        summary = thread.summary; currentState = thread.currentState; nextAction = thread.nextAction
        blockers = thread.blockers; resumePoint = thread.resumePoint; notes = thread.notes
        linkedResources = thread.linkedResources
        taskIDs = tasks.filter { $0.threadID == thread.id }.map(\.id).sorted { $0.uuidString < $1.uuidString }
        checkpointIDs = thread.checkpoints.map(\.id)
        activityIDs = thread.progressEvents.map(\.id)
    }

    func validate() throws {
        guard schemaVersion == 1, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !title.contains(where: { $0.isNewline || $0 == "\0" }), title.count <= 10_000,
              [summary, currentState, nextAction, blockers, resumePoint, notes, linkedResources]
                .allSatisfy({ $0.count <= 100_000 && !$0.contains("\0") }),
              Set(taskIDs).count == taskIDs.count, Set(checkpointIDs).count == checkpointIDs.count,
              Set(activityIDs).count == activityIDs.count else {
            throw MemorySyncError.invalidDocument
        }
        try ProgressSnapshot(currentState: currentState, nextAction: nextAction,
                             blockers: blockers, resumePoint: resumePoint).validate()
    }

    /// A deliberately conservative first adapter: one portable JSON code block, no custom Notion blocks.
    /// Keeping a single representation avoids two independently editable copies of current state.
    func markdown() throws -> String {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(self), as: UTF8.self)
        let longest = json.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "# SidePad project memory\n\n\(fence)json\n\(json)\n\(fence)\n"
    }

    static func parse(_ markdown: String) throws -> Self {
        guard markdown.utf8.count <= 400_000 else { throw MemorySyncError.invalidDocument }
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "# SidePad project memory\n\n"
        guard normalized.hasPrefix(prefix) else { throw MemorySyncError.invalidDocument }
        let block = String(normalized.dropFirst(prefix.count))
        guard let firstNewline = block.firstIndex(of: "\n") else { throw MemorySyncError.invalidDocument }
        let opener = String(block[..<firstNewline])
        guard opener.hasSuffix("json") else { throw MemorySyncError.invalidDocument }
        let fence = String(opener.dropLast(4))
        guard fence.count >= 3, fence.allSatisfy({ $0 == "`" }), block.hasSuffix("\n" + fence) else {
            throw MemorySyncError.invalidDocument
        }
        let json = String(block[block.index(after: firstNewline)...].dropLast(fence.count + 1))
        let permitted: Set<String> = ["schemaVersion", "threadID", "parentID", "title", "status", "summary", "currentState",
            "nextAction", "blockers", "resumePoint", "notes", "linkedResources", "taskIDs", "checkpointIDs", "activityIDs"]
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              Set(object.keys).isSubset(of: permitted) else { throw MemorySyncError.invalidDocument }
        let result: Self
        do { result = try JSONDecoder().decode(Self.self, from: Data(json.utf8)) }
        catch { throw MemorySyncError.invalidDocument }
        try result.validate()
        return result
    }
}

struct ProjectMemorySnapshot {
    var document: ProjectMemoryDocument
    var revision: String
}

@MainActor
protocol ProjectMemoryRepository: AnyObject {
    func snapshot(threadID: UUID) throws -> ProjectMemorySnapshot
    func applyReviewed(_ document: ProjectMemoryDocument, expectedRevision: String) throws -> ProjectMemorySnapshot
}

/// Adapts the existing Markdown owner. It does not introduce another task store.
@MainActor
final class LocalMarkdownMemoryRepository: ProjectMemoryRepository {
    private let threads: ThreadStore
    private let workspace: WorkspaceStore

    init(threads: ThreadStore, workspace: WorkspaceStore) {
        self.threads = threads; self.workspace = workspace
    }

    func snapshot(threadID: UUID) throws -> ProjectMemorySnapshot {
        try threads.verifyUnchanged()
        guard let record = threads.threads.first(where: { $0.id == threadID }) else { throw MemorySyncError.missingProject }
        let document = ProjectMemoryDocument(thread: record, tasks: workspace.tasks)
        let file = try Data(contentsOf: threads.fileURL(for: threadID))
        // Authored prose and task links participate in conflict detection, not just projected fields.
        let revision = MemoryRevision.hash(file + Data(try document.markdown().utf8))
        return ProjectMemorySnapshot(document: document, revision: revision)
    }

    func applyReviewed(_ document: ProjectMemoryDocument, expectedRevision: String) throws -> ProjectMemorySnapshot {
        try document.validate()
        let current = try snapshot(threadID: document.threadID)
        guard current.revision == expectedRevision else { throw MemorySyncError.localChanged }
        guard var record = threads.threads.first(where: { $0.id == document.threadID }) else { throw MemorySyncError.missingProject }
        // Hierarchy, task links and evidence references cannot be reassigned by a remote page.
        guard document.parentID == current.document.parentID,
              document.taskIDs == current.document.taskIDs,
              document.checkpointIDs == current.document.checkpointIDs,
              document.activityIDs == current.document.activityIDs else { throw MemorySyncError.identityChanged }
        if document == current.document { return current }
        record.title = document.title; record.status = document.status; record.summary = document.summary
        record.currentState = document.currentState; record.nextAction = document.nextAction
        record.blockers = document.blockers; record.resumePoint = document.resumePoint
        record.notes = document.notes; record.linkedResources = document.linkedResources
        record.updatedAt = Date(); record.lastActivity = record.updatedAt
        record.progressEvents.append(ProgressEvent(timestamp: record.updatedAt,
            summary: "Imported reviewed Notion project context", source: .manual,
            snapshot: ProgressSnapshot(thread: record)))
        try threads.save(record)
        return try snapshot(threadID: document.threadID)
    }
}

enum MemoryRevision {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hash(_ text: String) -> String { hash(Data(text.utf8)) }
}

enum MemorySyncError: LocalizedError, Equatable {
    case notConnected, missingProject, invalidDocument, identityChanged, localChanged, remoteChanged
    case incompleteRemote, remoteWarnings, permissionDenied, invalidResponse, requestTooLarge
    case http(Int), retryLimit, uncertainWrite, metadataChanged, alreadyLinked, noMapping, busy

    var errorDescription: String? {
        switch self {
        case .notConnected: "Notion is not connected. Local projects remain available offline."
        case .missingProject: "The local project is no longer available."
        case .invalidDocument: "This page is not a supported SidePad memory document. Its content has been preserved for review."
        case .identityChanged: "Remote identity, hierarchy, task or history references changed. Review them without replacing local records."
        case .localChanged: "The local project changed after the sync preview. Prepare a new preview."
        case .remoteChanged: "The Notion page changed after the sync preview. Both versions are preserved for review."
        case .incompleteRemote: "Notion returned incomplete or unsupported content. No overwrite is allowed."
        case .remoteWarnings: "Notion reported content warnings. Review the remote page before continuing."
        case .permissionDenied: "The Notion connection cannot access this page. Check its read and update permissions."
        case .invalidResponse: "Notion returned an unexpected response. No sync success was recorded."
        case .requestTooLarge: "This memory is too large for one safe Notion request. Keep it local or split the project."
        case .http(let code): "Notion request failed (HTTP \(code))."
        case .retryLimit: "Notion is still unavailable after bounded retries. Try again later."
        case .uncertainWrite: "The remote write may have succeeded. Refresh the preview to reconcile before retrying."
        case .metadataChanged: "Sync metadata changed externally. Reload it before continuing."
        case .alreadyLinked: "This project or Notion page is already linked. Unlink it explicitly before changing identity."
        case .noMapping: "Link a dedicated Notion page to this project before synchronising."
        case .busy: "A sync operation is already running."
        }
    }
}
