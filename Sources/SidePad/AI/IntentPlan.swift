import Foundation

struct IntentPlan: Codable, Equatable {
    var schemaVersion = 1
    var confidence: Double = 1
    var needsClarification = false
    var clarification: String?
    var operations: [IntentOperation] = []
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", confidence, needsClarification = "needs_clarification", clarification, operations
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(confidence, forKey: .confidence)
        try c.encode(needsClarification, forKey: .needsClarification); try c.encode(clarification, forKey: .clarification)
        try c.encode(operations, forKey: .operations)
    }
}

enum IntentOperationKind: String, Codable, CaseIterable {
    case createThread = "create_thread", createTask = "create_task", createSubtask = "create_subtask"
    case updateThreadContext = "update_thread_context", appendProgressEvent = "append_progress_event"
    case changeThreadStatus = "change_thread_status"
    case changeTaskStatus = "change_task_status"
    var isCreation: Bool { [.createThread, .createTask, .createSubtask].contains(self) }
}

enum IntentTaskStatus: String, Codable, CaseIterable {
    case open, completed
    var isCompleted: Bool { self == .completed }
}

struct IntentOperation: Codable, Equatable {
    var operation: IntentOperationKind
    var ref: String?
    var target: String?
    var parentRef: String?
    var threadRef: String?
    var title: String?
    var dueDate: IntentDueDate?
    var priority: Int?
    var context: IntentContextUpdate?
    var progress: String?
    var status: ThreadStatus?
    var taskStatus: IntentTaskStatus?
    enum CodingKeys: String, CodingKey {
        case operation, ref, target, parentRef = "parent_ref", threadRef = "thread_ref", title, dueDate = "due_date"
        case priority, context, progress, status
        case taskStatus = "task_status"
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(operation, forKey: .operation); try c.encode(ref, forKey: .ref)
        try c.encode(target, forKey: .target); try c.encode(parentRef, forKey: .parentRef)
        try c.encode(threadRef, forKey: .threadRef); try c.encode(title, forKey: .title)
        try c.encode(dueDate, forKey: .dueDate); try c.encode(priority, forKey: .priority)
        try c.encode(context, forKey: .context); try c.encode(progress, forKey: .progress); try c.encode(status, forKey: .status)
        try c.encodeIfPresent(taskStatus, forKey: .taskStatus)
    }
}

struct IntentContextUpdate: Codable, Equatable {
    var summary: String?
    var currentState: String?
    var nextAction: String?
    var blockers: String?
    var resumePoint: String?
    var notes: String?
    var linkedResources: String?
    enum CodingKeys: String, CodingKey {
        case summary, currentState = "current_state", nextAction = "next_action", blockers, resumePoint = "resume_point"
        case notes, linkedResources = "linked_resources"
    }
    var isEmpty: Bool { [summary, currentState, nextAction, blockers, resumePoint, notes, linkedResources].allSatisfy { $0 == nil } }
    func apply(to record: inout ThreadRecord) {
        if let summary { record.summary = summary }
        if let currentState { record.currentState = currentState }
        if let nextAction { record.nextAction = nextAction }
        if let blockers { record.blockers = blockers }
        if let resumePoint { record.resumePoint = resumePoint }
        if let notes { record.notes = notes }
        if let linkedResources { record.linkedResources = linkedResources }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(summary, forKey: .summary); try c.encode(currentState, forKey: .currentState)
        try c.encode(nextAction, forKey: .nextAction); try c.encode(blockers, forKey: .blockers)
        try c.encode(resumePoint, forKey: .resumePoint); try c.encode(notes, forKey: .notes)
        try c.encode(linkedResources, forKey: .linkedResources)
    }
}

struct IntentDueDate: Codable, Equatable {
    var date: String?
    var relative: String?
    var timeZone: String?
    enum CodingKeys: String, CodingKey { case date, relative, timeZone = "time_zone" }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date); try c.encode(relative, forKey: .relative); try c.encode(timeZone, forKey: .timeZone)
    }
    func resolved(now: Date, deviceTimeZone: TimeZone) throws -> Date {
        guard (date == nil) != (relative == nil) else { throw IntentError.invalid("Specify one absolute or relative due date.") }
        let zone: TimeZone
        if let timeZone {
            guard let parsed = TimeZone(identifier: timeZone) else { throw IntentError.invalid("Unknown time zone.") }
            zone = parsed
        } else { zone = deviceTimeZone }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        if let relative {
            let days = ["today": 0, "tomorrow": 1, "day_after_tomorrow": 2]
            guard let offset = days[relative], let result = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else {
                throw IntentError.invalid("Unsupported relative date.")
            }
            return result
        }
        guard let date, date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            throw IntentError.invalid("Due date must be YYYY-MM-DD.")
        }
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1900...9999).contains(parts[0]) else { throw IntentError.invalid("Invalid due date.") }
        let components = DateComponents(timeZone: zone, year: parts[0], month: parts[1], day: parts[2])
        guard let result = calendar.date(from: components),
              calendar.component(.year, from: result) == parts[0], calendar.component(.month, from: result) == parts[1],
              calendar.component(.day, from: result) == parts[2] else { throw IntentError.invalid("Invalid calendar date.") }
        return result
    }
}

enum IntentError: LocalizedError, Equatable {
    case invalid(String)
    case clarification(String)
    case stale
    case confirmationRequired
    var errorDescription: String? {
        switch self {
        case .invalid(let message), .clarification(let message): return message
        case .stale: return "数据已改变。请重新解析或刷新后重试，已有内容未被覆盖。"
        case .confirmationRequired: return "此操作需要先确认预览。"
        }
    }
}
