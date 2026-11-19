import Foundation

/// Only the selected/explicitly named projects and their parent names enter an AI request.
struct IntentInputContext: Codable, Sendable {
    struct ThreadReference: Codable, Sendable {
        var id: UUID; var title: String; var parentID: UUID?
        var currentState: String?; var nextAction: String?; var blockers: String?; var recentProgress: [String]?
        enum CodingKeys: String, CodingKey {
            case id, title, parentID = "parent_id", currentState = "current_state", nextAction = "next_action", blockers
            case recentProgress = "recent_progress"
        }
    }
    struct TaskReference: Codable, Sendable {
        var id: UUID; var title: String; var threadID: UUID?; var parentTaskID: UUID?
        var isCompleted: Bool; var completedAt: String?
        enum CodingKeys: String, CodingKey {
            case id, title, threadID = "thread_id", parentTaskID = "parent_task_id", isCompleted = "is_completed", completedAt = "completed_at"
        }
    }
    var localDate: String
    var timeZone: String
    var selectedThreadID: UUID?
    var threads: [ThreadReference]
    var tasks: [TaskReference]
    enum CodingKeys: String, CodingKey {
        case localDate = "local_date", timeZone = "timezone", selectedThreadID = "selected_thread_id", threads, tasks
    }
    @MainActor init(threads: [ThreadRecord], tasks: [TaskItem], selectedThreadID: UUID?, now: Date, timeZone: TimeZone, input: String = "") throws {
        self.localDate = IntentValidator.localDate(now, timeZone: timeZone); self.timeZone = timeZone.identifier
        self.selectedThreadID = selectedThreadID
        try ThreadStore.validateHierarchy(threads)
        try WorkspaceStore.validateTasks(tasks)
        var scopes = Set(threads.filter { !$0.title.isEmpty && input.localizedCaseInsensitiveContains($0.title) }.map(\.id))
        if let selectedThreadID { scopes.insert(selectedThreadID) }
        let byID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        var hierarchy = scopes
        for id in scopes {
            var parent = byID[id]?.parentID
            while let id = parent { hierarchy.insert(id); parent = byID[id]?.parentID }
        }
        // With no project selected, names permit association/clarification without disclosing project prose.
        let candidates = hierarchy.isEmpty ? Array(threads.sorted { $0.id.uuidString < $1.id.uuidString }.prefix(50)) : threads.filter { hierarchy.contains($0.id) }
        guard candidates.count <= 50 else { throw IntentError.invalid("Too many matching projects. Select a more specific Thread.") }
        self.threads = candidates.map { item in
            let detailed = scopes.contains(item.id)
            return ThreadReference(id: item.id, title: String(item.title.prefix(160)), parentID: item.parentID,
                currentState: detailed ? String(item.currentState.prefix(600)) : nil,
                nextAction: detailed ? String(item.nextAction.prefix(600)) : nil,
                blockers: detailed ? String(item.blockers.prefix(600)) : nil,
                recentProgress: detailed ? item.progressEvents.sorted { $0.timestamp > $1.timestamp }.prefix(3).map { String($0.summary.prefix(240)) } : nil)
        }
        let relevant = tasks.filter { $0.threadID.map(scopes.contains) ?? (selectedThreadID == nil && scopes.isEmpty) }
        let incomplete = relevant.filter { !$0.isCompleted }.sorted { ($0.sortOrder, $0.id.uuidString) < ($1.sortOrder, $1.id.uuidString) }
        guard incomplete.count <= 80 else { throw IntentError.invalid("This scope has over 80 open tasks. Select a smaller Thread or edit manually.") }
        var completionDates: [UUID: Date] = [:]
        func rememberCompletion(_ event: ProgressEvent) {
            guard let id = event.taskID, event.taskCompleted == true,
                  event.source == .taskChange || event.summary == "Task completed" else { return }
            completionDates[id] = max(completionDates[id] ?? .distantPast, event.timestamp)
        }
        for task in relevant { for event in task.progressEvents ?? [] { rememberCompletion(event) } }
        for thread in threads where scopes.contains(thread.id) {
            for event in thread.progressEvents { rememberCompletion(event) }
        }
        func completion(_ task: TaskItem) -> Date? { completionDates[task.id] }
        let completed = relevant.filter(\.isCompleted).sorted {
            if completion($0) != completion($1) { return (completion($0) ?? .distantPast) > (completion($1) ?? .distantPast) }
            return ($0.sortOrder, $0.id.uuidString) < ($1.sortOrder, $1.id.uuidString)
        }.prefix(20)
        var included = incomplete + completed
        // Never send a child whose parent is an unexplained identifier.
        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var ids = Set(included.map(\.id))
        for task in included {
            var parent = task.parentTaskID
            while let id = parent, let record = tasksByID[id], ids.insert(id).inserted {
                included.append(record); parent = record.parentTaskID
            }
        }
        guard included.count <= 120 else { throw IntentError.invalid("Task hierarchy exceeds the AI context limit.") }
        self.tasks = included.map { TaskReference(id: $0.id, title: String($0.title.prefix(240)), threadID: $0.threadID,
            parentTaskID: $0.parentTaskID, isCompleted: $0.isCompleted, completedAt: completion($0).map(ProgressTimestamp.format)) }
    }
    func json() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 32_768 else { throw IntentError.invalid("Project context exceeds 32 KiB. Select a smaller Thread.") }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Intentionally handles explicit simple capture only; complex language stays with a provider or manual UI.
struct OfflineIntentParser: AIProvider {
    func parse(_ request: AIParseRequest) async throws -> Data {
        try Task.checkCancellation()
        let context = try JSONDecoder().decode(IntentInputContext.self, from: Data(request.contextJSON.utf8))
        let text = request.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4000 else { throw IntentError.invalid("请输入简短的任务或项目名称。") }
        func clarify(_ question: String) throws -> Data {
            try JSONEncoder().encode(IntentPlan(confidence: 0, needsClarification: true, clarification: question))
        }
        let childPrefixes = ["child thread:", "child thread：", "子项目:", "子项目：", "子线程:", "子线程："]
        let threadPrefixes = ["thread:", "thread：", "project:", "project：", "项目:", "项目："]
        if let prefix = (childPrefixes + threadPrefixes).first(where: { text.lowercased().hasPrefix($0) }) {
            let title = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let isChild = childPrefixes.contains(prefix)
            if isChild && context.selectedThreadID == nil { return try clarify("请先选择父 Thread，再创建子项目。") }
            guard !title.isEmpty, !title.contains("\n") else { return try clarify("请在项目指令后填写一个项目名称。") }
            return try JSONEncoder().encode(IntentPlan(operations: [IntentOperation(operation: .createThread,
                ref: "temp:thread", parentRef: isChild ? context.selectedThreadID?.uuidString : nil, title: title)]))
        }
        let complexMarkers = ["子项目", "下面", "里面", "下次", "目前", "记录", "项目", "删除", "更新", "移动", "标记", "归档", "rename", "project", "under ", "delete ", "update ", "archive ", "mark ", "move "]
        if complexMarkers.contains(where: { text.lowercased().contains($0) }) {
            return try clarify("离线模式支持直接输入任务、‘项目：名称’或‘子项目：名称’。层级批量操作和上下文更新请切换 AI 提供商，或使用手动编辑。")
        }
        let matching = context.threads.filter { text.localizedCaseInsensitiveContains($0.title) }
        if matching.count > 1 { return try clarify("请求中匹配到多个 Thread，请选择目标 Thread 后输入一个明确的任务名称。") }
        let selected = matching.first?.id ?? context.selectedThreadID
        var operations: [IntentOperation] = []
        for (index, raw) in text.split(separator: "\n").enumerated() {
            var title = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["task:", "task：", "任务:", "任务：", "add task ", "添加任务 "] where title.lowercased().hasPrefix(prefix) {
                title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines); break
            }
            var relative: String?
            for (prefix, value) in [("后天", "day_after_tomorrow"), ("明天", "tomorrow"), ("今天", "today"),
                                    ("day after tomorrow ", "day_after_tomorrow"), ("tomorrow ", "tomorrow"), ("today ", "today")] {
                if title.lowercased().hasPrefix(prefix) {
                    relative = value; title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines); break
                }
            }
            // Do not guess dates embedded in prose or split a compound instruction into a malformed task.
            if title.range(of: #"\d{4}-\d{2}-\d{2}|\b(next|tomorrow|yesterday|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b|下周|明天|后天|昨天|\d+月\d+日|[；;]"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return try clarify("此日期或多步请求超出离线模式。请使用开头的今天/明天/后天，或手动设置日期。")
            }
            guard !title.isEmpty else { return try clarify("请填写任务名称。") }
            operations.append(IntentOperation(operation: .createTask, ref: "temp:task\(index)", threadRef: selected?.uuidString,
                title: title, dueDate: relative.map { IntentDueDate(relative: $0, timeZone: request.timeZone.identifier) }))
        }
        return try JSONEncoder().encode(IntentPlan(operations: operations))
    }
}

struct IntentParserService {
    let provider: any AIProvider
    func parse(_ request: AIParseRequest) async throws -> IntentPlan {
        let data = try await provider.parse(request)
        try Task.checkCancellation()
        return try IntentValidator.decode(data)
    }
}
