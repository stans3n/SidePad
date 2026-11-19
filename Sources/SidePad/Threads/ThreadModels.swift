import Foundation

enum ThreadStatus: String, Codable, CaseIterable {
    case active, paused, completed, archived
}

/// Markdown owns project context. Task identity and completion stay in WorkspaceStore.
struct ThreadRecord: Identifiable, Equatable {
    var id: UUID
    var parentID: UUID?
    var title: String
    var status: ThreadStatus
    var createdAt: Date
    var updatedAt: Date
    var lastActivity: Date
    var summary: String
    var currentState: String
    var nextAction: String
    var blockers: String
    var resumePoint: String
    var notes: String
    var progressHistory: String
    var linkedResources: String
    var progressEvents: [ProgressEvent]
    var checkpoints: [ThreadCheckpoint]

    init(id: UUID = UUID(), title: String, parentID: UUID? = nil,
         status: ThreadStatus = .active, createdAt: Date = Date(),
         updatedAt: Date? = nil, lastActivity: Date? = nil,
         summary: String = "", currentState: String = "", nextAction: String = "",
         blockers: String = "", resumePoint: String = "", notes: String = "",
         progressHistory: String = "", linkedResources: String = "",
         progressEvents: [ProgressEvent] = [], checkpoints: [ThreadCheckpoint] = []) {
        self.id = id
        self.parentID = parentID
        self.title = title
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastActivity = lastActivity ?? updatedAt ?? createdAt
        self.summary = summary
        self.currentState = currentState
        self.nextAction = nextAction
        self.blockers = blockers
        self.resumePoint = resumePoint
        self.notes = notes
        self.progressHistory = progressHistory
        self.linkedResources = linkedResources
        self.progressEvents = progressEvents
        self.checkpoints = checkpoints
    }
}
