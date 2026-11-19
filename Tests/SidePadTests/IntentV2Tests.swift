import Foundation
import Testing
@testable import SidePad

@Suite(.serialized)
@MainActor
struct IntentV2Tests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-22T14:30:00Z")!
    private let zone = TimeZone(identifier: "Australia/Sydney")!
    private func prepare(_ operations: [IntentOperation], threads: [ThreadRecord] = [], tasks: [TaskItem] = [], selected: UUID? = nil) throws -> PreparedIntent {
        try IntentValidator.prepare(IntentPlan(schemaVersion: 2, operations: operations), threads: threads, tasks: tasks,
            selectedThreadID: selected, now: now, timeZone: zone, rawInput: "Synthetic test input")
    }
    private func fixture() throws -> (ThreadStore, WorkspaceStore, UserDefaults, String, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SidePadV2-" + UUID().uuidString)
        let name = "SidePadV2." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        return (ThreadStore(directory: root), WorkspaceStore(defaults: defaults), defaults, name, root)
    }
    private func journal(_ prepared: PreparedIntent, threads: ThreadStore) throws {
        func markdown(_ records: [ThreadRecord]) throws -> [String] {
            try records.sorted { $0.id.uuidString < $1.id.uuidString }.map { try ThreadMarkdown.serialize($0) }
        }
        let object: [String: Any] = ["beforeThreads": try markdown(prepared.beforeThreads), "afterThreads": try markdown(prepared.afterThreads),
            "beforeTasks": try JSONSerialization.jsonObject(with: JSONEncoder().encode(prepared.beforeTasks)),
            "afterTasks": try JSONSerialization.jsonObject(with: JSONEncoder().encode(prepared.afterTasks))]
        try JSONSerialization.data(withJSONObject: object).write(to: ActionExecutor.recoveryURL(threads))
    }

    @Test func explicitSchemaVersionsAndTaskStatusSemantics() throws {
        let thread = ThreadRecord(title: "SidePad")
        let task = TaskItem(title: "Test", sortOrder: 0, threadID: thread.id)
        let operation = IntentOperation(operation: .changeTaskStatus, target: task.id.uuidString, taskStatus: .completed)
        let v2 = IntentPlan(schemaVersion: 2, operations: [operation])
        #expect(try IntentValidator.decode(JSONEncoder().encode(v2)) == v2)
        #expect(throws: (any Error).self) { try IntentValidator.decode(JSONEncoder().encode(IntentPlan(schemaVersion: 1, operations: [operation]))) }
        #expect(throws: (any Error).self) {
            try prepare([.init(operation: .changeTaskStatus, target: task.id.uuidString, status: .completed)], threads: [thread], tasks: [task])
        }
        let legacy = IntentPlan(schemaVersion: 1, operations: [.init(operation: .createTask, ref: "temp:old", title: "Legacy")])
        #expect(try IntentValidator.decode(JSONEncoder().encode(legacy)) == legacy)
    }

    @Test func completesExistingTaskCreatesFollowUpAndRecordsNewProgress() throws {
        let thread = ThreadRecord(title: "AI Integration")
        let task = TaskItem(title: "DeepSeek API 接入", sortOrder: 0, threadID: thread.id)
        let result = try prepare([
            .init(operation: .changeTaskStatus, target: task.id.uuidString, taskStatus: .completed),
            .init(operation: .createTask, ref: "temp:repair", threadRef: thread.id.uuidString, title: "修复 Codex CLI 能力检查并重新测试解析"),
            .init(operation: .appendProgressEvent, target: thread.id.uuidString, progress: "Codex CLI 能力检查报错，解析验证受阻。")
        ], threads: [thread], tasks: [task], selected: thread.id)
        #expect(result.afterTasks.count == 2 && result.afterTasks[0].isCompleted && !result.afterTasks[1].isCompleted)
        #expect(result.afterTasks[1].parentTaskID == nil && result.afterTasks[1].dueDate == nil && result.afterTasks[1].priority == nil)
        #expect(result.afterTasks[0].progressEvents?.last?.summary == "Task completed")
        #expect(result.afterTasks[0].progressEvents?.last?.timestamp == now)
        #expect(result.afterThreads[0].progressEvents.count == 1)
        #expect(result.preview.map(\.kind) == [.completedTask, .newTask, .progress])
        // The follow-up is a sibling task; the preview must not imply a subtask.
        #expect(result.preview[0].depth == 0 && result.preview[1].depth == 0)
        #expect(result.requiresConfirmation)
    }

    @Test func backfillResolvesTemporaryReferenceAndHasOneHistoryPreview() throws {
        let thread = ThreadRecord(title: "SidePad")
        let result = try prepare([
            .init(operation: .createTask, ref: "temp:history", threadRef: thread.id.uuidString, title: "调整设置页面 UI"),
            .init(operation: .changeTaskStatus, target: "temp:history", taskStatus: .completed),
            .init(operation: .createTask, ref: "temp:next", threadRef: thread.id.uuidString, title: "测试窗口缩放")
        ], threads: [thread])
        #expect(result.afterTasks[0].isCompleted && !result.afterTasks[1].isCompleted)
        #expect(result.afterTasks[0].progressEvents?.count == 1)
        #expect(result.afterTasks[0].dueDate == nil)
        #expect(result.preview.count == 2 && result.preview[0].kind == .completedTask)
        #expect(result.preview[0].details.contains("history"))
        #expect(result.preview.allSatisfy { !$0.breadcrumb.contains(thread.id.uuidString) && !$0.details.contains("temp:") })
        #expect(throws: (any Error).self) {
            try prepare([.init(operation: .changeTaskStatus, target: "temp:later", taskStatus: .completed),
                         .init(operation: .createTask, ref: "temp:later", title: "Later")])
        }
    }

    @Test func rejectsRedundantStatusesDuplicatesAndDoubleTransitions() throws {
        let thread = ThreadRecord(title: "SidePad")
        var completed = TaskItem(title: "DeepSeek API 接入", sortOrder: 0, threadID: thread.id)
        completed.isCompleted = true
        #expect(throws: (any Error).self) {
            try prepare([.init(operation: .changeTaskStatus, target: completed.id.uuidString, taskStatus: .completed)], threads: [thread], tasks: [completed])
        }
        #expect(throws: (any Error).self) {
            try prepare([.init(operation: .createTask, ref: "temp:duplicate", threadRef: thread.id.uuidString, title: "DeepSeek API 接入", priority: 3)], threads: [thread], tasks: [completed])
        }
        #expect(throws: (any Error).self) {
            try prepare([.init(operation: .changeTaskStatus, target: completed.id.uuidString, taskStatus: .open),
                         .init(operation: .changeTaskStatus, target: completed.id.uuidString, taskStatus: .completed)], threads: [thread], tasks: [completed])
        }
        let reopened = try prepare([.init(operation: .changeTaskStatus, target: completed.id.uuidString, taskStatus: .open)], threads: [thread], tasks: [completed])
        #expect(!reopened.afterTasks[0].isCompleted)
        #expect(reopened.afterTasks[0].progressEvents?.last?.summary == "Task reopened")
    }

    @Test func deterministicDeadlineAndInvalidCalendarDate() throws {
        let result = try prepare([.init(operation: .createTask, ref: "temp:test", title: "测试连接", dueDate: .init(relative: "tomorrow"))])
        #expect(result.afterTasks[0].dueDate.map { IntentValidator.localDate($0, timeZone: zone) } == "2026-10-24")
        #expect(result.afterTasks[0].priority == nil)
        #expect(throws: (any Error).self) {
            try prepare([.init(operation: .createTask, ref: "temp:history", title: "Finished", dueDate: .init(date: "2026-02-30")),
                         .init(operation: .changeTaskStatus, target: "temp:history", taskStatus: .completed)])
        }
    }

    @Test func explicitHistoricalDeadlineIsPreserved() throws {
        let result = try prepare([
            .init(operation: .createTask, ref: "temp:history", title: "Finished release", dueDate: .init(date: "2026-10-21")),
            .init(operation: .changeTaskStatus, target: "temp:history", taskStatus: .completed)
        ])
        #expect(result.afterTasks[0].isCompleted)
        #expect(result.afterTasks[0].dueDate.map { IntentValidator.localDate($0, timeZone: zone) } == "2026-10-21")
        #expect(result.preview[0].details.contains("2026-10-21"))
    }

    @Test func ambiguityStagesNoWritesAndExplicitTargetPreservesOtherThread() throws {
        let (threads, workspace, defaults, name, root) = try fixture()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        try threads.commit([ThreadRecord(title: "Project A"), ThreadRecord(title: "Project B")])
        let first = threads.threads.first { $0.title == "Project A" }!
        let second = threads.threads.first { $0.title == "Project B" }!
        let a = TaskItem(title: "Test connection", sortOrder: 0, threadID: first.id)
        let b = TaskItem(title: "Test connection", sortOrder: 1, threadID: second.id)
        try workspace.replaceTasks([a, b])
        let context = try IntentInputContext(threads: threads.threads, tasks: workspace.tasks, selectedThreadID: nil,
            now: now, timeZone: zone, input: "Complete Test connection in Project B")
        #expect(context.tasks.map(\.id) == [b.id])
        let coordinator = ThreadsCoordinator(workspace: workspace, threads: threads, settings: AISettingsStore(defaults: defaults))
        let ambiguous = IntentPlan(schemaVersion: 2, confidence: 0.3, needsClarification: true,
            clarification: "Which project contains the task?")
        #expect(throws: IntentError.self) { try coordinator.stagePlan(ambiguous) }
        #expect(coordinator.pendingPlan == nil && workspace.tasks == [a, b])
        #expect(throws: IntentError.self) {
            try prepare([.init(operation: .changeTaskStatus, target: UUID().uuidString, taskStatus: .completed)], threads: threads.threads, tasks: workspace.tasks)
        }
        try coordinator.stagePlan(IntentPlan(schemaVersion: 2, operations: [
            .init(operation: .changeTaskStatus, target: b.id.uuidString, taskStatus: .completed)
        ]))
        try coordinator.confirmPending()
        #expect(!workspace.tasks[0].isCompleted && workspace.tasks[1].isCompleted)
    }

    @Test func nestedPreviewAndBeforeAfterContextUseHumanNames() throws {
        let existing = ThreadRecord(title: "SidePad", currentState: "Before")
        let result = try prepare([
            .init(operation: .createThread, ref: "temp:ai", parentRef: existing.id.uuidString, title: "AI Integration"),
            .init(operation: .createTask, ref: "temp:parent", threadRef: "temp:ai", title: "Verify providers"),
            .init(operation: .createSubtask, ref: "temp:child", parentRef: "temp:parent", title: "Check errors"),
            .init(operation: .updateThreadContext, target: existing.id.uuidString, context: .init(currentState: "After"))
        ], threads: [existing])
        #expect(result.preview[2].breadcrumb == "SidePad → AI Integration → Verify providers")
        #expect(result.preview[2].depth > result.preview[1].depth)
        #expect(result.preview[3].contextChanges == [.init(label: "Current State", before: "Before", after: "After")])
        #expect(result.afterTasks[0].threadID == result.afterTasks[1].threadID)
    }

    @Test func boundedContextIncludesRecentCompletedAndExplicitOtherProjectOnly() throws {
        let parent = ThreadRecord(title: "Workspace")
        let selected = ThreadRecord(title: "SidePad", parentID: parent.id, currentState: "Current")
        let explicit = ThreadRecord(title: "Other project", blockers: "Explicit blocker")
        let unrelated = ThreadRecord(title: "Private unrelated", currentState: "SECRET", notes: "DO NOT TRANSMIT")
        var tasks = (0..<25).map { i in TaskItem(title: "Completed \(i)", sortOrder: i, threadID: selected.id) }
        for index in tasks.indices {
            tasks[index].isCompleted = true
            tasks[index].progressEvents = [ProgressEvent(timestamp: now.addingTimeInterval(Double(index)), summary: "Task completed", source: .taskChange,
                taskID: tasks[index].id, taskTitle: tasks[index].title, taskCompleted: true)]
        }
        tasks += [TaskItem(title: "Next", sortOrder: 26, threadID: selected.id), TaskItem(title: "Other task", sortOrder: 27, threadID: explicit.id), TaskItem(title: "Secret task", sortOrder: 28, threadID: unrelated.id)]
        let context = try IntentInputContext(threads: [parent, selected, explicit, unrelated], tasks: tasks,
            selectedThreadID: selected.id, now: now, timeZone: zone, input: "Also review Other project")
        #expect(context.tasks.filter { $0.isCompleted }.count == 20)
        #expect(context.tasks.contains { $0.title == "Completed 24" && $0.completedAt != nil })
        #expect(context.tasks.contains { $0.title == "Other task" })
        #expect(context.threads.contains { $0.id == parent.id })
        let json = try context.json()
        #expect(!json.contains("SECRET") && !json.contains("Secret task") && !json.contains("DO NOT TRANSMIT"))
        #expect(json.utf8.count <= 32_768)
    }

    @Test func mixedBatchAppliesAndReversesCompletionCreationAndProgress() throws {
        let (threads, workspace, defaults, name, root) = try fixture()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        try threads.save(ThreadRecord(title: "Project"))
        let thread = threads.threads[0]
        let beforeTasks = workspace.tasks, beforeThreads = threads.threads
        let operations: [IntentOperation] = [
            .init(operation: .createTask, ref: "temp:history", threadRef: thread.id.uuidString, title: "Completed UI"),
            .init(operation: .changeTaskStatus, target: "temp:history", taskStatus: .completed),
            .init(operation: .appendProgressEvent, target: thread.id.uuidString, progress: "Window resize remains unverified")
        ]
        let result = try prepare(operations, threads: beforeThreads, tasks: beforeTasks)
        #expect(throws: IntentError.confirmationRequired) { try ActionExecutor.apply(result, workspace: workspace, threads: threads) }
        let coordinator = ThreadsCoordinator(workspace: workspace, threads: threads, settings: AISettingsStore(defaults: defaults))
        try coordinator.stagePlan(IntentPlan(schemaVersion: 2, operations: operations), now: now, timeZone: zone)
        #expect(workspace.tasks.isEmpty && threads.threads == beforeThreads)
        try coordinator.confirmPending()
        #expect(workspace.tasks[0].isCompleted && threads.threads[0].progressEvents.count == 1)
        #expect(!FileManager.default.fileExists(atPath: ActionExecutor.recoveryURL(threads).path))
        #expect(coordinator.canUndo)
        try coordinator.undo()
        #expect(!coordinator.canUndo)
        #expect(workspace.tasks == beforeTasks && threads.threads == beforeThreads)
    }

    @Test func interruptedCrossStoreCommitRecoversOnlyUnchangedStates() throws {
        let (threads, workspace, defaults, name, root) = try fixture()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let result = try prepare([.init(operation: .createThread, ref: "temp:project", title: "Project"),
            .init(operation: .createTask, ref: "temp:task", threadRef: "temp:project", title: "Task")])
        try journal(result, threads: threads)
        try threads.commit(result.afterThreads) // Simulates termination before the task snapshot write.
        try ActionExecutor.recover(workspace: workspace, threads: threads)
        #expect(threads.threads.isEmpty && workspace.tasks.isEmpty)
        try journal(result, threads: threads)
        try threads.commit(result.afterThreads)
        workspace.addTask("Unrelated user edit", toToday: false)
        #expect(throws: (any Error).self) { try ActionExecutor.recover(workspace: workspace, threads: threads) }
        #expect(workspace.tasks[0].title == "Unrelated user edit" && threads.threads.count == 1)
        #expect(FileManager.default.fileExists(atPath: ActionExecutor.recoveryURL(threads).path))
    }

    @Test func failedBatchDoesNotLeaveTasksOrThreadChanges() throws {
        let (threads, workspace, defaults, name, root) = try fixture()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let result = try prepare([.init(operation: .createThread, ref: "temp:a", title: "A"),
            .init(operation: .createThread, ref: "temp:b", title: "B"),
            .init(operation: .createTask, ref: "temp:done", threadRef: "temp:a", title: "Done"),
            .init(operation: .changeTaskStatus, target: "temp:done", taskStatus: .completed)])
        threads.writeFailureInjector = { index in if index == 1 { throw IntentError.invalid("Synthetic disk failure") } }
        #expect(throws: (any Error).self) { try ActionExecutor.apply(result, workspace: workspace, threads: threads, confirmed: true) }
        #expect(workspace.tasks.isEmpty && threads.threads.isEmpty)
        let fresh = ThreadStore(directory: root)
        #expect(fresh.threads.isEmpty)
    }

    @Test func aiCaptureCannotSilentlyUseOfflineParser() async throws {
        let (threads, workspace, defaults, name, root) = try fixture()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let settings = AISettingsStore(defaults: defaults); settings.provider = .offline
        let coordinator = ThreadsCoordinator(workspace: workspace, threads: threads, settings: settings)
        _ = await coordinator.capture("Create a task")
        #expect(coordinator.pendingPlan == nil && coordinator.errorMessage != nil)
        #expect(workspace.tasks.isEmpty && threads.threads.isEmpty)
    }
}
