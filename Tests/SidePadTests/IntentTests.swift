import Foundation
import Testing
@testable import SidePad

@Suite(.serialized)
@MainActor
struct IntentTests {
    private let fixedNow = ISO8601DateFormatter().date(from: "2026-10-17T13:30:00Z")!
    private let zone = TimeZone(identifier: "Australia/Sydney")!

    private func workspace() -> (WorkspaceStore, UserDefaults, String) {
        let name = "SidePadThreadsTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        return (WorkspaceStore(defaults: defaults), defaults, name)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SidePadIntentTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func prepared(_ operations: [IntentOperation], threads: [ThreadRecord] = [], tasks: [TaskItem] = [], confidence: Double = 1) throws -> PreparedIntent {
        try IntentValidator.prepare(IntentPlan(confidence: confidence, operations: operations), threads: threads, tasks: tasks,
                                    selectedThreadID: nil, now: fixedNow, timeZone: zone)
    }

    @Test func strictSchemaRejectsUnknownKeysVersionsTypesAndOperations() throws {
        let plan = IntentPlan(operations: [.init(operation: .createThread, ref: "temp:a", title: "SidePad")])
        let data = try JSONEncoder().encode(plan)
        #expect(try IntentValidator.decode(data) == plan)
        let base = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for mutation in ["unknown", "version", "type", "missing", "operation", "nested"] {
            var object = base
            switch mutation {
            case "unknown": object["command"] = "touch /tmp/forbidden"
            case "version": object["schema_version"] = 3
            case "type": object["confidence"] = true
            case "missing": object.removeValue(forKey: "clarification")
            case "operation":
                var operations = object["operations"] as! [[String: Any]]; operations[0]["operation"] = "delete_thread"; object["operations"] = operations
            default:
                var operations = object["operations"] as! [[String: Any]]; operations[0]["shell"] = "anything"; object["operations"] = operations
            }
            let invalid = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) { try IntentValidator.decode(invalid) }
        }
        #expect(throws: (any Error).self) { try IntentValidator.decode(Data("```json\n{}\n```".utf8)) }
        #expect(throws: (any Error).self) { try IntentValidator.decode(Data(repeating: 0x20, count: 128 * 1024 + 1)) }
    }

    @Test func scenarioBNestedThreadsResolveTemporaryReferences() throws {
        let result = try prepared([
            .init(operation: .createThread, ref: "temp:sidepad", title: "SidePad"),
            .init(operation: .createThread, ref: "temp:threads", parentRef: "temp:sidepad", title: "Threads"),
            .init(operation: .createThread, ref: "temp:ai", parentRef: "temp:sidepad", title: "AI Integration")
        ])
        #expect(result.afterThreads.count == 3)
        #expect(result.afterThreads[1].parentID == result.afterThreads[0].id)
        #expect(result.afterThreads[2].parentID == result.afterThreads[0].id)
        #expect(result.requiresConfirmation)
    }

    @Test func explicitInboxTaskDoesNotInheritSelectedThread() throws {
        let selected = ThreadRecord(title: "SidePad")
        let standalone = IntentPlan(operations: [.init(operation: .createTask, ref: "temp:inbox", title: "Buy milk")])
        let inbox = try IntentValidator.prepare(standalone, threads: [selected], tasks: [], selectedThreadID: selected.id)
        #expect(inbox.afterTasks[0].threadID == nil)
        let linked = IntentPlan(operations: [.init(operation: .createTask, ref: "temp:linked", threadRef: selected.id.uuidString, title: "Test")])
        let result = try IntentValidator.prepare(linked, threads: [selected], tasks: [], selectedThreadID: selected.id)
        #expect(result.afterTasks[0].threadID == selected.id)
    }

    @Test func scenarioCAddsTwoCanonicalTasksUnderExistingThread() throws {
        let ai = ThreadRecord(title: "AI Integration")
        let result = try prepared([
            .init(operation: .createTask, ref: "temp:deepseek", threadRef: ai.id.uuidString, title: "配置 DeepSeek API"),
            .init(operation: .createTask, ref: "temp:codex", threadRef: ai.id.uuidString, title: "测试 Codex CLI")
        ], threads: [ai])
        #expect(result.afterThreads.count == 1)
        #expect(result.afterTasks.map(\.threadID) == [ai.id, ai.id])
        #expect(result.afterTasks.allSatisfy { !$0.isCompleted && $0.dueDate == nil })
    }

    @Test func scenarioDDeepHierarchyAndTasks() throws {
        let sidepad = ThreadRecord(title: "SidePad")
        let result = try prepared([
            .init(operation: .createThread, ref: "temp:release", parentRef: sidepad.id.uuidString, title: "Release 0.7"),
            .init(operation: .createThread, ref: "temp:ui", parentRef: "temp:release", title: "UI"),
            .init(operation: .createThread, ref: "temp:storage", parentRef: "temp:release", title: "Storage"),
            .init(operation: .createThread, ref: "temp:ai", parentRef: "temp:release", title: "AI"),
            .init(operation: .createTask, ref: "temp:hover", threadRef: "temp:ui", title: "修复 Hover"),
            .init(operation: .createTask, ref: "temp:focus", threadRef: "temp:ui", title: "测试 Focus"),
            .init(operation: .createSubtask, ref: "temp:child", parentRef: "temp:focus", title: "验证键盘焦点")
        ], threads: [sidepad])
        let ui = result.afterThreads.first { $0.title == "UI" }!
        #expect(result.afterThreads.count == 5)
        #expect(result.afterTasks.count == 3)
        #expect(result.afterTasks.allSatisfy { $0.threadID == ui.id })
        #expect(result.afterTasks[2].parentTaskID == result.afterTasks[1].id)
    }

    @Test func scenariosEAndFUpdateContextWithoutCompletingOrDuplicatingTasks() throws {
        let ai = ThreadRecord(title: "AI Integration", notes: "User formatting\n**Keep**")
        let portfolio = ThreadRecord(title: "Portfolio")
        let task = TaskItem(title: "测试 Codex CLI", sortOrder: 0, threadID: ai.id)
        let result = try prepared([
            .init(operation: .updateThreadContext, target: ai.id.uuidString,
                  context: .init(currentState: "已经完成 DeepSeek 接口，目前还没有完成 Codex CLI 测试。")),
            .init(operation: .appendProgressEvent, target: ai.id.uuidString, progress: "DeepSeek 接口完成"),
            .init(operation: .updateThreadContext, target: portfolio.id.uuidString,
                  context: .init(currentState: "做到 Research 页面布局", resumePoint: "下次继续添加实验结果图"))
        ], threads: [ai, portfolio], tasks: [task])
        #expect(result.requiresConfirmation)
        #expect(result.afterTasks == [task])
        #expect(result.afterThreads.count == 2)
        #expect(result.afterThreads[0].notes == ai.notes)
        #expect(result.afterThreads[1].resumePoint == "下次继续添加实验结果图")
        #expect(result.summary.contains("Current State"))
        #expect(result.afterThreads[0].progressEvents.count == 2)
        #expect(result.afterThreads[0].progressEvents[0].snapshot.currentState.contains("DeepSeek"))
        #expect(result.afterThreads[0].progressEvents[1].summary == "DeepSeek 接口完成")
        #expect(result.afterThreads[0].progressHistory == ai.progressHistory)
    }

    @Test func scenarioGAmbiguityDoesNotChooseArbitraryTarget() throws {
        let ambiguous = IntentPlan(confidence: 0, needsClarification: true, clarification: "请选择 Website A 或 Website B。")
        #expect(throws: IntentError.self) {
            try IntentValidator.prepare(ambiguous, threads: [ThreadRecord(title: "Website A"), ThreadRecord(title: "Website B")], tasks: [], selectedThreadID: nil)
        }
        var mixed = ambiguous
        mixed.operations = [.init(operation: .createTask, ref: "temp:a", title: "测试")]
        #expect(throws: IntentError.self) { try IntentValidator.prepare(mixed, threads: [], tasks: [], selectedThreadID: nil) }
    }

    @Test func relativeDatesUseDeviceTimezoneAndRejectImpossibleDates() throws {
        let tomorrow = try IntentDueDate(relative: "tomorrow").resolved(now: fixedNow, deviceTimeZone: zone)
        #expect(IntentValidator.localDate(tomorrow, timeZone: zone) == "2026-10-19")
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let usTomorrow = try IntentDueDate(relative: "tomorrow").resolved(now: fixedNow, deviceTimeZone: losAngeles)
        #expect(IntentValidator.localDate(usTomorrow, timeZone: losAngeles) == "2026-10-18")
        for due in [IntentDueDate(date: "2026-02-30"), IntentDueDate(date: "2026-13-01"), IntentDueDate(date: "26-1-1"),
                    IntentDueDate(date: "2026-10-19", relative: "tomorrow"), IntentDueDate(relative: "next_week"),
                    IntentDueDate(relative: "today", timeZone: "invented/timezone")] {
            #expect(throws: IntentError.self) { try due.resolved(now: fixedNow, deviceTimeZone: zone) }
        }
        let dstNow = ISO8601DateFormatter().date(from: "2026-10-03T14:30:00Z")!
        let dstDate = try IntentDueDate(relative: "tomorrow").resolved(now: dstNow, deviceTimeZone: zone)
        #expect(IntentValidator.localDate(dstDate, timeZone: zone) == "2026-10-05")
    }

    @Test func offlineChineseAndEnglishCaptureAndExplicitChild() async throws {
        let sidepad = ThreadRecord(title: "SidePad")
        let context = try IntentInputContext(threads: [sidepad], tasks: [], selectedThreadID: sidepad.id, now: fixedNow, timeZone: zone)
        for text in ["明天完成 SidePad 的 DeepSeek API 接入。", "Tomorrow finish the DeepSeek API integration"] {
            let request = AIParseRequest(input: text, contextJSON: try context.json(), now: fixedNow, timeZone: zone)
            let plan = try await IntentParserService(provider: OfflineIntentParser()).parse(request)
            let result = try IntentValidator.prepare(plan, threads: [sidepad], tasks: [], selectedThreadID: sidepad.id, now: fixedNow, timeZone: zone)
            #expect(result.afterTasks.count == 1)
            #expect(result.afterTasks[0].threadID == sidepad.id)
            #expect(IntentValidator.localDate(result.afterTasks[0].dueDate!, timeZone: zone) == "2026-10-19")
        }
        for text in ["子项目：Threads", "child thread: Threads"] {
            let plan = try await IntentParserService(provider: OfflineIntentParser()).parse(.init(input: text, contextJSON: try context.json()))
            let result = try prepared(plan.operations, threads: [sidepad])
            #expect(result.afterThreads.last?.parentID == sidepad.id)
        }
        let complex = try await IntentParserService(provider: OfflineIntentParser()).parse(.init(input: "给网站项目添加测试任务。", contextJSON: try context.json()))
        #expect(complex.needsClarification && complex.operations.isEmpty)
    }

    @Test func invalidBatchReferencesAndDuplicateIDsNeverMutate() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ThreadStore(directory: root)
        let (work, defaults, name) = workspace(); defer { defaults.removePersistentDomain(forName: name) }
        let initial = ThreadRecord(title: "Existing")
        try store.save(initial)
        let valid = IntentOperation(operation: .createThread, ref: "temp:a", title: "New")
        for bad in [IntentOperation(operation: .createThread, ref: "temp:a", title: "Duplicate ref"),
                    .init(operation: .createThread, ref: "temp:b", parentRef: "temp:later", title: "Forward parent"),
                    .init(operation: .createTask, ref: "temp:c", threadRef: UUID().uuidString, title: "Missing Thread"),
                    .init(operation: .createTask, ref: "temp:c", title: "Date", dueDate: .init(date: "2026-02-30")),
                    .init(operation: .createTask, ref: "temp:c", title: "Priority", priority: 9),
                    .init(operation: .createTask, ref: "temp:c", parentRef: "temp:a", title: "Unexpected field"),
                    .init(operation: .createThread, ref: "../../escape", title: "Unsafe reference")] {
            #expect(throws: (any Error).self) { try prepared([valid, bad], threads: store.threads) }
            #expect(store.threads.map(\.id) == [initial.id]); #expect(work.tasks.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "md" }.count == 1)
        }
    }

    @Test func executorRequiresConfirmationForEveryCreationRegardlessOfConfidence() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ThreadStore(directory: root)
        let (work, defaults, name) = workspace(); defer { defaults.removePersistentDomain(forName: name) }
        for confidence in [0.5, 0.85, 1] {
            let plan = try prepared([.init(operation: .createThread, ref: "temp:a", title: "Check")], confidence: confidence)
            #expect(plan.requiresConfirmation)
            #expect(throws: IntentError.confirmationRequired) { try ActionExecutor.apply(plan, workspace: work, threads: store) }
        }
        #expect(store.threads.isEmpty)
        let accepted = try prepared([.init(operation: .createThread, ref: "temp:a", title: "Check")])
        try ActionExecutor.apply(accepted, workspace: work, threads: store, confirmed: true)
        #expect(store.threads.count == 1)
    }

    @Test func executorExternalConflictDoesNotCreateTasks() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ThreadStore(directory: root)
        let existing = ThreadRecord(title: "SidePad")
        try store.save(existing)
        let (work, defaults, name) = workspace(); defer { defaults.removePersistentDomain(forName: name) }
        let result = try prepared([.init(operation: .createTask, ref: "temp:task", threadRef: existing.id.uuidString, title: "Test")], threads: store.threads)
        let url = store.fileURL(for: existing.id)
        var markdown = try String(contentsOf: url, encoding: .utf8)
        markdown += "\nExternal editor wrote this.\n"
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try ActionExecutor.apply(result, workspace: work, threads: store, confirmed: true) }
        #expect(work.tasks.isEmpty)
        #expect(try String(contentsOf: url, encoding: .utf8) == markdown)
    }

    @Test func coordinatorUndoAndUndoConflictProtectLaterChanges() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ThreadStore(directory: root)
        let (work, defaults, name) = workspace(); defer { defaults.removePersistentDomain(forName: name) }
        let settings = AISettingsStore(defaults: defaults)
        let coordinator = ThreadsCoordinator(workspace: work, threads: store, settings: settings)
        let id = try coordinator.createThread(title: "SidePad", parentID: nil)
        let taskID = try coordinator.addTask(title: "Test", threadID: id)
        #expect(coordinator.canUndo)
        try coordinator.undo()
        #expect(work.tasks.isEmpty && store.threads.count == 1)
        try coordinator.undo()
        #expect(store.threads.isEmpty && !coordinator.canUndo)
        _ = taskID
        let again = try coordinator.createThread(title: "Again", parentID: nil)
        _ = try coordinator.addTask(title: "Keep me", threadID: again)
        work.addTask("Later manual edit", toToday: true)
        #expect(throws: IntentError.self) { try coordinator.undo() }
        #expect(work.tasks.count == 2)
    }

    @Test func taskMetadataAndThreadsSelectionSurviveRestartAndLegacyShape() throws {
        let (work, defaults, name) = workspace(); defer { defaults.removePersistentDomain(forName: name) }
        work.addTask("Legacy task", toToday: true)
        let originalID = work.tasks[0].id
        let threadID = UUID()
        let parent = TaskItem(title: "Parent", sortOrder: 1, threadID: threadID, dueDate: fixedNow, priority: 2)
        let child = TaskItem(title: "Child", sortOrder: 2, threadID: threadID, parentTaskID: parent.id)
        try work.replaceTasks(work.tasks + [parent, child])
        work.defaultPage = .lastOpened; work.selection = .threads
        work.threadsSize = CGSize(width: 420, height: 620)
        let restored = WorkspaceStore(defaults: defaults)
        #expect(restored.tasks == work.tasks)
        #expect(restored.tasks[0].id == originalID && restored.tasks[0].threadID == nil)
        #expect(restored.selection == .threads && restored.threadsSize == CGSize(width: 420, height: 620))
        let json = try JSONSerialization.jsonObject(with: defaults.data(forKey: "SidePad.workspace.v4")!) as! [String: Any]
        #expect((json["lastSelection"] as? [String: Any])?["tasks"] != nil)
        #expect(restored.todayTasks.map(\.id).contains(originalID))
    }

    @Test func taskHierarchyRejectsCyclesAndDeletionPreservesDescendants() throws {
        let (work, defaults, name) = workspace(); defer { defaults.removePersistentDomain(forName: name) }
        let threadID = UUID()
        let root = TaskItem(title: "Root", sortOrder: 0, threadID: threadID)
        var child = TaskItem(title: "Child", sortOrder: 1, threadID: threadID, parentTaskID: root.id)
        let grandchild = TaskItem(title: "Grandchild", sortOrder: 2, threadID: threadID, parentTaskID: child.id)
        try work.replaceTasks([root, child, grandchild])
        #expect(throws: TaskLinkError.self) { try work.linkTask(root.id, to: threadID, parentTaskID: grandchild.id) }
        #expect(work.tasks[0].parentTaskID == nil)
        work.deleteTask(child.id)
        #expect(work.tasks.first { $0.id == grandchild.id }?.parentTaskID == root.id)
        child.isCompleted = true
        try work.replaceTasks([root, child, grandchild]); work.clearCompleted()
        #expect(work.tasks.first { $0.id == grandchild.id }?.parentTaskID == root.id)
        #expect(throws: TaskLinkError.self) { try work.editTask(root.id, threadID: threadID, parentTaskID: nil, dueDate: nil, priority: 99) }
        #expect(work.tasks[0].priority == nil)
    }

    @Test func failedProviderLeavesWorkspaceUnchanged() async throws {
        struct BrokenProvider: AIProvider {
            func parse(_ request: AIParseRequest) async throws -> Data { Data("{\"operations\":[{\"operation\":\"delete_thread\"}]}".utf8) }
        }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ThreadStore(directory: root)
        let original = ThreadRecord(title: "Keep"); try store.save(original)
        let (work, defaults, name) = workspace(); defer { defaults.removePersistentDomain(forName: name) }
        do {
            let plan = try await IntentParserService(provider: BrokenProvider()).parse(.init(input: "test"))
            let result = try prepared(plan.operations, threads: store.threads)
            try ActionExecutor.apply(result, workspace: work, threads: store, confirmed: true)
            Issue.record("Invalid provider response reached execution")
        } catch { }
        #expect(store.threads.map(\.id) == [original.id] && work.tasks.isEmpty)
    }

    @Test func duplicateUnfinishedTasksAreRejectedWithoutBlockingDifferentWork() throws {
        let first = ThreadRecord(title: "First"), second = ThreadRecord(title: "Second")
        let parent = TaskItem(title: "Parent", sortOrder: 0, threadID: first.id)
        let due = try IntentDueDate(relative: "tomorrow").resolved(now: fixedNow, deviceTimeZone: zone)
        let existing = TaskItem(title: "Review   CAFÉ", sortOrder: 1, threadID: first.id, dueDate: due, priority: 2)
        var operation = IntentOperation(operation: .createTask, ref: "temp:new", threadRef: first.id.uuidString,
            title: "  review café  ", dueDate: .init(relative: "tomorrow"), priority: 2)
        #expect(throws: IntentError.self) { try prepared([operation], threads: [first, second], tasks: [parent, existing]) }

        operation.title = "ＲＥＶＩＥＷ cafe"
        #expect(throws: IntentError.self) { try prepared([operation], threads: [first, second], tasks: [parent, existing]) }

        var completed = existing; completed.isCompleted = true
        #expect(try prepared([operation], threads: [first, second], tasks: [parent, completed]).afterTasks.count == 3)
        for changed in ["owner", "parent", "date", "priority"] {
            var distinct = operation
            switch changed {
            case "owner": distinct.threadRef = second.id.uuidString
            case "parent": distinct.operation = .createSubtask; distinct.parentRef = parent.id.uuidString
            case "date": distinct.dueDate = .init(relative: "today")
            default: distinct.priority = 3
            }
            #expect(try prepared([distinct], threads: [first, second], tasks: [parent, existing]).afterTasks.count == 3)
        }
    }

    @Test func duplicateBatchTasksAndSubtasksRejectTheEntirePlan() throws {
        let thread = ThreadRecord(title: "Project")
        let parent = TaskItem(title: "Parent", sortOrder: 0, threadID: thread.id)
        for isSubtask in [false, true] {
            let first = IntentOperation(operation: isSubtask ? .createSubtask : .createTask, ref: "temp:first",
                parentRef: isSubtask ? parent.id.uuidString : nil, threadRef: thread.id.uuidString, title: "Check")
            var second = first; second.ref = "temp:second"; second.title = "check"; second.priority = 0
            #expect(throws: IntentError.self) { try prepared([first, second], threads: [thread], tasks: [parent]) }
        }
        let existing = TaskItem(title: "Buy milk", sortOrder: 0)
        #expect(throws: IntentError.self) {
            try prepared([.init(operation: .createTask, ref: "temp:inbox", title: "BUY MILK", priority: 0)], tasks: [existing])
        }
    }

    @Test func previewShowsContextTargetsDatesAndPriority() throws {
        let context = IntentContextUpdate(summary: "Purpose", currentState: "In progress", nextAction: "Test", blockers: "",
            resumePoint: "Sources/Example.swift", notes: "Notes", linkedResources: "https://example.com")
        let result = try prepared([
            .init(operation: .createThread, ref: "temp:project", title: "Project", context: context),
            .init(operation: .createTask, ref: "temp:task", threadRef: "temp:project", title: "Verify",
                dueDate: .init(date: "2026-10-20", timeZone: "America/Los_Angeles"), priority: 3)
        ])
        for text in ["Purpose", "In progress", "Next Action: Test", "Blockers: (clear)", "Sources/Example.swift", "Notes: Notes",
                     "https://example.com", "Priority: 3", "2026-10-20 (America/Los_Angeles)", "Status: active",
                     result.afterThreads[0].id.uuidString + ".md", result.afterTasks[0].id.uuidString] {
            #expect(result.summary.contains(text))
        }
    }

    @Test func confirmedAIProgressPreservesLegacyProseAndHistoricalSnapshots() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ThreadStore(directory: root)
        let original = ThreadRecord(title: "Progress", currentState: "Before", progressHistory: "- Old handwritten note")
        try store.save(original)
        let (work, defaults, name) = workspace(); defer { defaults.removePersistentDomain(forName: name) }
        let rawInput = "记录：测试通过，暂停；下次继续发布。"
        let plan = IntentPlan(operations: [
            .init(operation: .updateThreadContext, target: original.id.uuidString,
                context: .init(currentState: "Tests passed", resumePoint: "Release next")),
            .init(operation: .appendProgressEvent, target: original.id.uuidString, progress: "Tests passed"),
            .init(operation: .changeThreadStatus, target: original.id.uuidString, status: .paused)
        ])
        let result = try IntentValidator.prepare(plan, threads: store.threads, tasks: [], selectedThreadID: original.id,
            now: fixedNow, timeZone: zone, rawInput: rawInput)
        #expect(store.threads[0].progressEvents.isEmpty)
        #expect(result.afterThreads[0].progressEvents.allSatisfy { $0.source == .aiConfirmed && $0.rawInput == rawInput })
        #expect(throws: IntentError.confirmationRequired) { try ActionExecutor.apply(result, workspace: work, threads: store) }
        try ActionExecutor.apply(result, workspace: work, threads: store, confirmed: true)
        let restarted = ThreadStore(directory: root)
        let saved = try #require(restarted.threads.first)
        #expect(saved.status == .paused && saved.progressEvents.count == 3)
        #expect(saved.progressEvents.allSatisfy { $0.timestamp == fixedNow })
        #expect(saved.progressEvents[0].snapshot.currentState == "Tests passed")
        #expect(saved.progressEvents[1].snapshot.resumePoint == "Release next")
        #expect(saved.progressEvents[2].summary.contains("active → paused"))
        #expect(saved.progressHistory == original.progressHistory)
        #expect(work.tasks.isEmpty)
    }
}
