import Foundation
import CoreFoundation

/// A deliberately small validator for the versioned, bundled schema's keyword set.
/// It fails closed on unknown fields before Codable sees any provider data.
enum IntentValidator {
    static func decode(_ data: Data) throws -> IntentPlan {
        guard data.count <= 128 * 1024 else { throw IntentError.invalid("AI response exceeds the size limit.") }
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let root = object as? [String: Any], let version = root["schema_version"] as? Int, [1, 2].contains(version) else {
            throw IntentError.invalid("Unsupported intent schema version.")
        }
        let schemaURL = try AIResources.url("IntentSchema_v\(version)", extension: "json")
        guard let schema = try JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as? [String: Any] else {
            throw IntentError.invalid("Intent schema resource is missing.")
        }
        try validateJSON(object, schema: schema, path: "plan")
        return try JSONDecoder().decode(IntentPlan.self, from: data)
    }

    private static func validateJSON(_ value: Any, schema: [String: Any], path: String) throws {
        let types = (schema["type"] as? [String]) ?? [schema["type"] as? String ?? ""]
        let isNull = value is NSNull
        let number = value as? NSNumber
        let isBoolean = number.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        let actual: String
        if isNull { actual = "null" }
        else if isBoolean { actual = "boolean" }
        else if let n = number { actual = n.doubleValue.rounded() == n.doubleValue ? "integer" : "number" }
        else if value is String { actual = "string" }
        else if value is [String: Any] { actual = "object" }
        else if value is [Any] { actual = "array" }
        else { throw IntentError.invalid("Unsupported JSON value at \(path).") }
        guard types.contains(actual) || (actual == "integer" && types.contains("number")) else {
            throw IntentError.invalid("Wrong JSON type at \(path).")
        }
        if let choices = schema["enum"] as? [Any],
           !choices.contains(where: { ($0 as? NSObject)?.isEqual(value) == true }) {
            throw IntentError.invalid("Unsupported value at \(path).")
        }
        if isNull { return }
        if let text = value as? String, let maximum = schema["maxLength"] as? Int, text.count > maximum {
            throw IntentError.invalid("Text too long at \(path).")
        }
        if let number, !isBoolean {
            let n = number.doubleValue
            guard n.isFinite, n >= (schema["minimum"] as? Double ?? -.greatestFiniteMagnitude),
                  n <= (schema["maximum"] as? Double ?? .greatestFiniteMagnitude) else {
                throw IntentError.invalid("Number out of range at \(path).")
            }
        }
        if let object = value as? [String: Any] {
            let fields = schema["properties"] as? [String: [String: Any]] ?? [:]
            let required = Set(schema["required"] as? [String] ?? [])
            guard required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: Set(fields.keys)) else {
                throw IntentError.invalid("Missing or unexpected JSON fields at \(path).")
            }
            for (key, child) in object { try validateJSON(child, schema: fields[key]!, path: "\(path).\(key)") }
        }
        if let array = value as? [Any] {
            guard array.count <= (schema["maxItems"] as? Int ?? 40), let itemSchema = schema["items"] as? [String: Any] else {
                throw IntentError.invalid("Too many operations at \(path).")
            }
            for (index, child) in array.enumerated() { try validateJSON(child, schema: itemSchema, path: "\(path)[\(index)]") }
        }
    }

    @MainActor static func prepare(_ plan: IntentPlan, threads: [ThreadRecord], tasks: [TaskItem],
                                  selectedThreadID: UUID?, now: Date = Date(), timeZone: TimeZone = .current,
                                  rawInput: String? = nil) throws -> PreparedIntent {
        // In-process plans (manual/offline) cross the identical schema boundary.
        _ = try decode(JSONEncoder().encode(plan))
        guard [1, 2].contains(plan.schemaVersion) else { throw IntentError.invalid("Unsupported intent schema version.") }
        if plan.needsClarification {
            guard plan.operations.isEmpty, let question = plan.clarification, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw IntentError.invalid("Clarification plans must contain a question and no operations.")
            }
            throw IntentError.clarification(question)
        }
        guard plan.clarification == nil, !plan.operations.isEmpty else { throw IntentError.invalid("No executable operations.") }
        try ThreadStore.validateHierarchy(threads)
        try WorkspaceStore.validateTasks(tasks)
        if let selectedThreadID, !threads.contains(where: { $0.id == selectedThreadID }) { throw IntentError.stale }
        var updatedThreads = threads
        var updatedTasks = tasks
        var refs: [String: UUID] = [:]
        var lines: [String] = []
        var createdThreadIDs: [UUID] = []
        var preview: [IntentPreviewItem] = []
        var changedTaskIDs = Set<UUID>()
        let completedRefs = Set(plan.operations.filter { $0.operation == .changeTaskStatus && $0.taskStatus == .completed }.compactMap(\.target))
        func resolve(_ ref: String) throws -> UUID {
            if ref.hasPrefix("temp:"), let id = refs[ref] { return id }
            if let id = UUID(uuidString: ref) { return id }
            throw IntentError.invalid("Unknown or forward reference: \(ref)")
        }
        func thread(_ ref: String) throws -> UUID {
            let id = try resolve(ref)
            guard let item = updatedThreads.first(where: { $0.id == id }) else { throw IntentError.invalid("Thread reference does not exist.") }
            guard item.status != .archived else { throw IntentError.invalid("Reopen the archived Thread before adding or editing content.") }
            return id
        }
        func register(_ reference: String?) throws -> UUID {
            guard let reference, reference.range(of: #"^temp:[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil,
                  refs[reference] == nil else { throw IntentError.invalid("Each creation needs a unique temp:name reference.") }
            let id = UUID(); refs[reference] = id; return id
        }
        func validTitle(_ title: String?) throws -> String {
            guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !title.contains("\n"), !title.contains("\r"), !title.contains("\0") else { throw IntentError.invalid("A nonempty single-line title is required.") }
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func threadPath(_ id: UUID) -> String {
            var components: [String] = []
            var current: UUID? = id
            while let next = current, let item = updatedThreads.first(where: { $0.id == next }) {
                components.append(item.title); current = item.parentID
            }
            return components.reversed().joined(separator: " → ")
        }
        func taskPath(_ id: UUID) -> [String] {
            var components: [String] = []
            var current: UUID? = id
            while let next = current, let item = updatedTasks.first(where: { $0.id == next }) {
                components.append(item.title); current = item.parentTaskID
            }
            return Array(components.reversed())
        }
        func threadPreview(_ id: UUID) -> String {
            "\(threadPath(id))\nMarkdown: \(id.uuidString).md"
        }
        func contextPreview(_ context: IntentContextUpdate) -> String {
            let values: [(String, String?)] = [("Summary", context.summary), ("Current State", context.currentState),
                ("Next Action", context.nextAction), ("Blockers", context.blockers), ("Resume Point", context.resumePoint),
                ("Notes", context.notes), ("Linked Resources", context.linkedResources)]
            return values.compactMap { name, value in value.map { "\(name): \($0.isEmpty ? "(clear)" : $0)" } }.joined(separator: "\n")
        }
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let eventTime = dateFormatter.string(from: now)
        for (operationIndex, operation) in plan.operations.enumerated() {
            let keys: Set<String>
            switch operation.operation {
            case .createThread: keys = ["operation", "ref", "parent_ref", "title", "context"]
            case .createTask: keys = ["operation", "ref", "thread_ref", "title", "due_date", "priority"]
            case .createSubtask: keys = ["operation", "ref", "parent_ref", "thread_ref", "title", "due_date", "priority"]
            case .updateThreadContext: keys = ["operation", "target", "context"]
            case .appendProgressEvent: keys = ["operation", "target", "progress"]
            case .changeThreadStatus: keys = ["operation", "target", "status"]
            case .changeTaskStatus: keys = ["operation", "target", "task_status"]
            }
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(operation)) as! [String: Any]
            guard object.allSatisfy({ keys.contains($0.key) || $0.value is NSNull }) else {
                throw IntentError.invalid("Fields do not match operation \(operation.operation.rawValue).")
            }
            switch operation.operation {
            case .createThread:
                let id = try register(operation.ref)
                let title = try validTitle(operation.title)
                let parentID = try operation.parentRef.map(thread)
                guard !updatedThreads.contains(where: { $0.parentID == parentID && $0.title.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
                    throw IntentError.invalid("A Thread named ‘\(title)’ already exists here. Use its existing ID.")
                }
                var record = ThreadRecord(id: id, title: title, parentID: parentID)
                record.createdAt = now; record.updatedAt = now; record.lastActivity = now
                operation.context?.apply(to: &record)
                updatedThreads.append(record); createdThreadIDs.append(id)
                var line = "＋ Thread: \(threadPreview(id))\nStatus: \(record.status.rawValue)"
                line += "\nParent: \(parentID?.uuidString ?? "none")\nCreated: \(eventTime)"
                if let context = operation.context { line += "\n" + contextPreview(context) }
                lines.append(line)
                preview.append(IntentPreviewItem(id: String(operationIndex), kind: .newThread, title: title,
                    breadcrumb: parentID.map(threadPath) ?? "Threads", depth: threadPath(id).components(separatedBy: " → ").count - 1,
                    details: "New Thread", contextChanges: operation.context.map { Self.contextChanges($0, before: ThreadRecord(title: title)) } ?? []))
            case .createTask, .createSubtask:
                let id = try register(operation.ref)
                let title = try validTitle(operation.title)
                // Null explicitly means Inbox. Providers send the selected UUID when appropriate.
                var threadID = try operation.threadRef.map(thread)
                var parentID: UUID?
                if operation.operation == .createSubtask {
                    guard let parentRef = operation.parentRef else { throw IntentError.invalid("Subtask parent is required.") }
                    let resolved = try resolve(parentRef)
                    guard let parent = updatedTasks.first(where: { $0.id == resolved }) else { throw IntentError.invalid("Parent task not found.") }
                    if operation.threadRef != nil, threadID != parent.threadID { throw IntentError.invalid("Subtask and parent must belong to the same Thread.") }
                    threadID = parent.threadID; parentID = resolved
                }
                if let threadID {
                    guard let target = updatedThreads.first(where: { $0.id == threadID }), target.status != .archived else {
                        throw IntentError.invalid("Task's Thread is missing or archived.")
                    }
                    if let index = updatedThreads.firstIndex(where: { $0.id == threadID }) {
                        updatedThreads[index].lastActivity = now; updatedThreads[index].updatedAt = now
                    }
                }
                let dueDate = try operation.dueDate?.resolved(now: now, deviceTimeZone: timeZone)
                let priority = operation.priority == 0 ? nil : operation.priority
                let normalizedTitle = Self.normalizedTaskTitle(title)
                guard !updatedTasks.contains(where: {
                    (plan.schemaVersion == 2 || !$0.isCompleted) && $0.threadID == threadID && $0.parentTaskID == parentID &&
                    (plan.schemaVersion == 2 || ($0.dueDate == dueDate && ($0.priority == 0 ? nil : $0.priority) == priority)) &&
                    Self.normalizedTaskTitle($0.title) == normalizedTitle
                }) else {
                    throw IntentError.invalid(plan.schemaVersion == 2
                        ? "A task named ‘\(title)’ already exists under this parent, including completed history. Use its existing ID."
                        : "An unfinished task named ‘\(title)’ already exists with the same parent, due date and priority. Use the existing task.")
                }
                var item = TaskItem(id: id, title: title, createdAt: now,
                                    sortOrder: (updatedTasks.map(\.sortOrder).max() ?? -1) + 1,
                                    threadID: threadID, parentTaskID: parentID, dueDate: dueDate,
                                    priority: priority)
                if plan.schemaVersion == 2, !completedRefs.contains(operation.ref ?? "") {
                    item.progressEvents = [ProgressEvent(timestamp: now, summary: "Task created", source: .aiConfirmed,
                        taskID: id, taskTitle: title, taskCompleted: false, rawInput: rawInput)]
                }
                updatedTasks.append(item)
                let owner = threadID.map(threadPath) ?? "Inbox"
                let parentTitle = parentID.flatMap { id in updatedTasks.first { $0.id == id }?.title }
                let parentPath = parentID.map(taskPath) ?? []
                var line = "＋ \(operation.operation == .createSubtask ? "Subtask" : "Task"): \(owner) → \(parentTitle.map { $0 + " → " } ?? "")\(title)"
                line += "\nTask ID: \(id.uuidString)\nThread ID: \(threadID?.uuidString ?? "Inbox")"
                line += "\nParent task: \(parentID?.uuidString ?? "none")"
                if let dueDate {
                    let dueZone = operation.dueDate?.timeZone.flatMap(TimeZone.init(identifier:)) ?? timeZone
                    line += "\nDue: \(Self.localDate(dueDate, timeZone: dueZone)) (\(dueZone.identifier))"
                } else { line += "\nDue: none" }
                line += "\nPriority: \(priority.map(String.init) ?? "none")\nCreated: \(eventTime)"
                lines.append(line)
                let backfill = completedRefs.contains(operation.ref ?? "")
                var details = backfill ? "Completed work added to history" : "New Task"
                if let dueDate { details += " · Due " + Self.localDate(dueDate, timeZone: operation.dueDate?.timeZone.flatMap(TimeZone.init(identifier:)) ?? timeZone) }
                if let priority { details += " · Priority \(priority)" }
                preview.append(IntentPreviewItem(id: String(operationIndex), kind: backfill ? .completedTask : .newTask,
                    title: title, breadcrumb: ([owner] + parentPath).joined(separator: " → "),
                    depth: parentPath.count,
                    details: details))
            case .changeTaskStatus:
                guard plan.schemaVersion == 2, let reference = operation.target, let status = operation.taskStatus else {
                    throw IntentError.invalid("Task status changes require schema v2, a target and task_status open/completed.")
                }
                let id = try resolve(reference)
                guard let index = updatedTasks.firstIndex(where: { $0.id == id }) else { throw IntentError.invalid("Target task not found.") }
                guard changedTaskIDs.insert(id).inserted else { throw IntentError.invalid("A task may change status only once in a batch.") }
                let original = updatedTasks[index]
                guard original.isCompleted != status.isCompleted else { throw IntentError.invalid("‘\(original.title)’ is already \(status.rawValue). No change is needed.") }
                if let owner = original.threadID { _ = try thread(owner.uuidString) }
                updatedTasks[index].isCompleted = status.isCompleted
                let summary = status.isCompleted ? "Task completed" : "Task reopened"
                let snapshot = original.threadID.flatMap { owner in updatedThreads.first { $0.id == owner } }.map(ProgressSnapshot.init(thread:)) ?? .init()
                let event = ProgressEvent(timestamp: now, summary: summary, source: .aiConfirmed, taskID: id,
                    taskTitle: original.title, taskCompleted: status.isCompleted, snapshot: snapshot, rawInput: rawInput)
                updatedTasks[index].progressEvents = (original.progressEvents ?? []) + [event]
                if let owner = original.threadID, let ownerIndex = updatedThreads.firstIndex(where: { $0.id == owner }) {
                    updatedThreads[ownerIndex].updatedAt = now; updatedThreads[ownerIndex].lastActivity = now
                }
                lines.append("\(summary): \(original.title)")
                // Creation and completion of a backfill appear as one clearly labeled review item.
                if !reference.hasPrefix("temp:") {
                    let owner = original.threadID.map(threadPath) ?? "Inbox"
                    let parents = original.parentTaskID.map(taskPath) ?? []
                    preview.append(IntentPreviewItem(id: String(operationIndex), kind: status.isCompleted ? .completedTask : .reopenedTask,
                        title: original.title, breadcrumb: ([owner] + parents).joined(separator: " → "),
                        depth: parents.count, details: summary))
                }
            case .updateThreadContext, .appendProgressEvent, .changeThreadStatus:
                guard let reference = operation.target else { throw IntentError.invalid("Target Thread is required.") }
                // Status changes may reopen archived threads; all other edits require an active record.
                let id = operation.operation == .changeThreadStatus ? try resolve(reference) : try thread(reference)
                guard let index = updatedThreads.firstIndex(where: { $0.id == id }) else { throw IntentError.invalid("Target Thread not found.") }
                let eventSummary: String
                switch operation.operation {
                case .updateThreadContext:
                    guard let context = operation.context, !context.isEmpty else { throw IntentError.invalid("Context update is empty.") }
                    let changes = Self.contextChanges(context, before: updatedThreads[index])
                    guard plan.schemaVersion == 1 || !changes.isEmpty else { throw IntentError.invalid("Context is unchanged.") }
                    preview.append(IntentPreviewItem(id: String(operationIndex), kind: .context, title: updatedThreads[index].title,
                        breadcrumb: threadPath(id), depth: 0, details: "Context change", contextChanges: changes))
                    context.apply(to: &updatedThreads[index])
                    eventSummary = "Context updated"
                    lines.append("✎ \(threadPreview(id))\n" + contextPreview(context))
                case .appendProgressEvent:
                    guard let progress = operation.progress, !progress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw IntentError.invalid("Progress event is empty.") }
                    guard plan.schemaVersion == 1 || !updatedThreads[index].progressEvents.contains(where: { Self.normalizedTaskTitle($0.summary) == Self.normalizedTaskTitle(progress) }) else {
                        throw IntentError.invalid("This progress note is already recorded.")
                    }
                    eventSummary = progress
                    preview.append(IntentPreviewItem(id: String(operationIndex), kind: .progress, title: "Progress update",
                        breadcrumb: threadPath(id), depth: 0, details: progress))
                    lines.append("✎ \(threadPreview(id))\nProgress: \(progress)")
                case .changeThreadStatus:
                    guard let status = operation.status else { throw IntentError.invalid("Status is required.") }
                    guard plan.schemaVersion == 1 || status != updatedThreads[index].status else { throw IntentError.invalid("Thread status is unchanged.") }
                    preview.append(IntentPreviewItem(id: String(operationIndex), kind: .threadStatus, title: updatedThreads[index].title,
                        breadcrumb: threadPath(id), depth: 0, details: "\(updatedThreads[index].status.rawValue) → \(status.rawValue)"))
                    eventSummary = "Status: \(updatedThreads[index].status.rawValue) → \(status.rawValue)"
                    updatedThreads[index].status = status
                    lines.append("✎ \(threadPreview(id))\n\(eventSummary)")
                default: throw IntentError.invalid("Unsupported Thread update.")
                }
                updatedThreads[index].updatedAt = now; updatedThreads[index].lastActivity = now
                let event = ProgressEvent(timestamp: now, summary: eventSummary, source: .aiConfirmed,
                    snapshot: ProgressSnapshot(thread: updatedThreads[index]), rawInput: rawInput)
                updatedThreads[index].progressEvents.append(event)
                lines[lines.count - 1] += "\nProgress Event: \(eventTime) · \(eventSummary)"
            }
        }
        try ThreadStore.validateHierarchy(updatedThreads)
        try WorkspaceStore.validateTasks(updatedTasks)
        return PreparedIntent(beforeThreads: threads, afterThreads: updatedThreads, beforeTasks: tasks, afterTasks: updatedTasks,
                              requiresConfirmation: true,
                              summary: lines.joined(separator: "\n\n"), createdThreadIDs: createdThreadIDs, preview: preview)
    }

    private static func contextChanges(_ context: IntentContextUpdate, before: ThreadRecord) -> [IntentContextChange] {
        let values: [(String, String, String?)] = [("Summary", before.summary, context.summary),
            ("Current State", before.currentState, context.currentState), ("Next Action", before.nextAction, context.nextAction),
            ("Blockers", before.blockers, context.blockers), ("Resume Point", before.resumePoint, context.resumePoint),
            ("Notes", before.notes, context.notes), ("Linked Resources", before.linkedResources, context.linkedResources)]
        return values.compactMap { label, before, after in
            guard let after, after != before else { return nil }
            return IntentContextChange(label: label, before: before, after: after)
        }
    }

    private static func normalizedTaskTitle(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func localDate(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct PreparedIntent {
    var beforeThreads: [ThreadRecord]
    var afterThreads: [ThreadRecord]
    var beforeTasks: [TaskItem]
    var afterTasks: [TaskItem]
    var requiresConfirmation: Bool
    var summary: String
    var createdThreadIDs: [UUID]
    var preview: [IntentPreviewItem] = []
}

struct IntentContextChange: Identifiable, Equatable {
    var label: String
    var before: String
    var after: String
    var id: String { label }
}

struct IntentPreviewItem: Identifiable, Equatable {
    enum Kind: String { case newThread, newTask, completedTask, reopenedTask, progress, context, threadStatus }
    var id: String
    var kind: Kind
    var title: String
    var breadcrumb: String
    var depth: Int
    var details: String
    var contextChanges: [IntentContextChange] = []
}
