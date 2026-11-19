import Foundation
import Testing
@testable import SidePad

@Suite(.serialized)
@MainActor
struct ProgressWorkflowTests {
    private func fixture(_ body: (WorkspaceStore, ThreadStore, ThreadsCoordinator, UserDefaults) throws -> Void) throws {
        let name = "SidePadProgressWorkflow." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        let workspace = WorkspaceStore(defaults: defaults)
        let threads = ThreadStore(directory: directory)
        let coordinator = ThreadsCoordinator(workspace: workspace, threads: threads, settings: AISettingsStore(defaults: defaults))
        try body(workspace, threads, coordinator, defaults)
    }

    @Test func confirmedLogPersistsSnapshotAndRetryIsIdempotentWithUndo() throws {
        try fixture { work, threads, coordinator, defaults in
            let threadID = try coordinator.createThread(title: "Memory", parentID: nil)
            let taskID = try coordinator.addTask(title: "Timeline", threadID: threadID)
            let original = threads.threads.first!
            let task = work.tasks.first!
            let eventID = UUID()
            let snapshot = ProgressSnapshot(currentState: "Parser works", nextAction: "Check UI", blockers: "", resumePoint: "Open timeline")
            try coordinator.logProgress(threadID: threadID, taskID: taskID, summary: "  Added snapshots  ", snapshot: snapshot,
                                        expectedThread: original, expectedTask: task, eventID: eventID)
            let saved = threads.threads.first!
            #expect(saved.currentState == original.currentState)
            #expect(saved.progressEvents.first?.snapshot == snapshot)
            #expect(saved.progressEvents.count == 1)
            #expect(saved.progressEvents.first?.rawInput == "  Added snapshots  ")
            #expect(saved.progressEvents.first?.taskTitle == task.title)
            #expect(work.tasks == [task])
            let bytes = try Data(contentsOf: threads.fileURL(for: threadID))
            try coordinator.logProgress(threadID: threadID, taskID: taskID, summary: "  Added snapshots  ", snapshot: snapshot,
                                        expectedThread: original, expectedTask: task, eventID: eventID)
            #expect(try Data(contentsOf: threads.fileURL(for: threadID)) == bytes)
            #expect(throws: IntentError.self) {
                try coordinator.logProgress(threadID: threadID, taskID: taskID, summary: "Different", snapshot: snapshot,
                                            expectedThread: original, expectedTask: task, eventID: eventID)
            }
            #expect(ThreadStore(directory: threads.directory).threads == threads.threads)
            #expect(WorkspaceStore(defaults: defaults).tasks == work.tasks)
            try coordinator.undo()
            #expect(threads.threads == [original])
            #expect(work.tasks == [task])
        }
    }

    @Test func standaloneTaskNeedsNoThreadAndHistorySurvivesLinkingCompletionAndRestart() throws {
        try fixture { work, threads, coordinator, defaults in
            work.addTask("Standalone", toToday: true)
            let original = work.tasks[0]
            let snapshot = ProgressSnapshot(currentState: "Draft ready", nextAction: "Review", resumePoint: "Page 2")
            try coordinator.logProgress(threadID: nil, taskID: original.id, summary: "Saved a draft", snapshot: snapshot,
                                        expectedThread: nil, expectedTask: original)
            #expect(threads.threads.isEmpty)
            #expect(work.tasks[0].progressEvents?.count == 1)
            work.toggleCompleted(original.id)
            work.toggleCompleted(original.id)
            #expect(work.tasks[0].progressEvents?.map(\.taskCompleted) == [false, true, false])
            let parent = try coordinator.createThread(title: "Writing", parentID: nil)
            try work.linkTask(original.id, to: parent)
            let beforeTask = work.tasks[0]
            let beforeThread = threads.threads[0]
            try coordinator.logProgress(threadID: parent, taskID: original.id, summary: "Reviewed", snapshot: snapshot,
                                        expectedThread: beforeThread, expectedTask: beforeTask)
            let reopened = WorkspaceStore(defaults: defaults)
            #expect(!reopened.isReadOnly)
            #expect(reopened.tasks == work.tasks)
            #expect(threads.threads[0].progressEvents.count == 1)
            let export = try coordinator.contextMarkdown(threadID: parent, taskID: original.id)
            #expect(export.contains("latest 4 of 4"))
            #expect(export.contains("Saved a draft"))
            #expect(export.contains("Reviewed"))
        }
    }

    @Test func staleTaskExternalFileAndInvalidLogCannotWriteProgress() throws {
        try fixture { work, threads, coordinator, _ in
            let id = try coordinator.createThread(title: "Safe", parentID: nil)
            let taskID = try coordinator.addTask(title: "Review", threadID: id)
            let original = threads.threads[0]
            let originalTask = work.tasks[0]
            work.updateTask(taskID, title: "Edited elsewhere")
            #expect(throws: IntentError.self) {
                try coordinator.logProgress(threadID: id, taskID: taskID, summary: "Stale", snapshot: .init(),
                                            expectedThread: original, expectedTask: originalTask)
            }
            #expect(throws: ProgressMemoryError.self) {
                try coordinator.logProgress(threadID: id, taskID: nil, summary: "  ", snapshot: .init(),
                                            expectedThread: original, expectedTask: nil)
            }
            let path = threads.fileURL(for: id)
            let external = try String(contentsOf: path, encoding: .utf8) + "\nExternal evidence.\n"
            try external.write(to: path, atomically: true, encoding: .utf8)
            #expect(throws: ThreadStoreError.self) {
                try coordinator.logProgress(threadID: id, taskID: nil, summary: "Conflict", snapshot: .init(),
                                            expectedThread: original, expectedTask: nil)
            }
            #expect(try String(contentsOf: path, encoding: .utf8) == external)
            #expect(threads.threads[0].progressEvents.isEmpty)
            #expect(work.tasks[0].title == "Edited elsewhere")
        }
    }

    @Test func taskLogsKeepIndependentSnapshotsAndOnlyThreadLogsReplaceSharedState() throws {
        try fixture { work, threads, coordinator, _ in
            let id = try coordinator.createThread(title: "Shared", parentID: nil)
            let firstID = try coordinator.addTask(title: "First", threadID: id)
            let secondID = try coordinator.addTask(title: "Second", threadID: id)
            let shared = ProgressSnapshot(currentState: "Shared state", nextAction: "Project next step")
            try coordinator.logProgress(threadID: id, taskID: nil, summary: "Project milestone", snapshot: shared,
                expectedThread: threads.threads[0], expectedTask: nil)
            for taskID in [firstID, secondID] {
                let task = work.tasks.first { $0.id == taskID }!
                try coordinator.logProgress(threadID: id, taskID: taskID, summary: task.title + " update",
                    snapshot: .init(currentState: task.title + " state", nextAction: task.title + " next step"),
                    expectedThread: threads.threads[0], expectedTask: task)
            }
            #expect(ProgressSnapshot(thread: threads.threads[0]) == shared)
            let firstExport = try coordinator.contextMarkdown(threadID: id, taskID: firstID)
            #expect(firstExport.contains("First next step"))
            #expect(!firstExport.contains("Second next step"))
            #expect(!firstExport.contains("Project next step"))
            #expect(threads.threads[0].progressEvents.count == 3)
        }
    }

    @Test func retryAndNewBatchDetectChangedCanonicalSources() throws {
        try fixture { work, threads, coordinator, defaults in
            let id = try coordinator.createThread(title: "Retry", parentID: nil)
            let original = threads.threads[0]
            let eventID = UUID()
            try coordinator.logProgress(threadID: id, taskID: nil, summary: "Once", snapshot: .init(),
                                        expectedThread: original, expectedTask: nil, eventID: eventID)
            let path = threads.fileURL(for: id)
            let saved = try Data(contentsOf: path)
            try (String(decoding: saved, as: UTF8.self) + "\n## External Section\nExternal edit\n").write(to: path, atomically: true, encoding: .utf8)
            #expect(throws: ThreadStoreError.self) {
                try coordinator.logProgress(threadID: id, taskID: nil, summary: "Once", snapshot: .init(),
                                            expectedThread: original, expectedTask: nil, eventID: eventID)
            }
            try threads.reload()
            let other = WorkspaceStore(defaults: defaults)
            other.addTask("Other instance", toToday: false)
            let latest = defaults.data(forKey: "SidePad.workspace.v4")
            let threadBytes = try Data(contentsOf: path)
            #expect(throws: TaskLinkError.self) { try coordinator.createThread(title: "Must not write", parentID: nil) }
            #expect(defaults.data(forKey: "SidePad.workspace.v4") == latest)
            #expect(try Data(contentsOf: path) == threadBytes)
            #expect(work.tasks.isEmpty)
        }
    }

    @Test func corruptWorkspaceIsReadOnlyAndNeverOverwritesOriginalBytes() throws {
        try fixture { work, _, _, defaults in
            work.addTask("Keep me", toToday: false)
            let original = try #require(defaults.data(forKey: "SidePad.workspace.v4"))
            var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
            var tasks = try #require(object["tasks"] as? [[String: Any]])
            tasks[0]["progressEvents"] = [["timestamp": "invalid", "summary": "malformed"]]
            object["tasks"] = tasks
            let corrupt = try JSONSerialization.data(withJSONObject: object)
            defaults.set(corrupt, forKey: "SidePad.workspace.v4")
            let failed = WorkspaceStore(defaults: defaults)
            #expect(failed.isReadOnly && failed.persistenceError != nil)
            failed.selection = .threads
            failed.addTask("Must not replace", toToday: false)
            #expect(throws: TaskLinkError.self) { try failed.replaceTasks([]) }
            #expect(defaults.data(forKey: "SidePad.workspace.v4") == corrupt)
            defaults.set(original, forKey: "SidePad.workspace.v4")
            let recovered = WorkspaceStore(defaults: defaults)
            #expect(!recovered.isReadOnly)
            #expect(recovered.tasks.map(\.title) == ["Keep me"])
        }
    }

    @Test func longTaskHierarchyValidatesAndMovesWithoutRepeatedAncestorScans() throws {
        try fixture { work, _, _, _ in
            var tasks: [TaskItem] = []
            for index in 0..<5_000 {
                tasks.append(TaskItem(title: "Task \(index)", sortOrder: index, parentTaskID: tasks.last?.id))
            }
            let start = ContinuousClock.now
            try work.replaceTasks(tasks)
            let threadID = UUID()
            try work.linkTask(tasks[0].id, to: threadID)
            let elapsed = start.duration(to: .now)
            print("5,000-task deep hierarchy validate + link: \(elapsed)")
            #expect(elapsed < .seconds(10))
            #expect(work.tasks.count == 5_000 && work.tasks.allSatisfy { $0.threadID == threadID })
            var cyclic = work.tasks
            cyclic[0].parentTaskID = cyclic.last?.id
            #expect(throws: TaskLinkError.self) { try work.replaceTasks(cyclic) }
        }
    }

    @Test func handoffContainsStableIdentitySavedContextBoundedHistoryAndLiteralUserText() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let root = ThreadRecord(title: "SidePad")
        let task = TaskItem(title: "Implement", sortOrder: 0)
        var thread = ThreadRecord(title: "Memory", parentID: root.id, currentState: "Saved state", nextAction: "Run tests",
                                  resumePoint: "Review diff", notes: "```\n## Not a new export section\n```", progressHistory: "Original undated prose")
        thread.progressEvents = (0..<60).map {
            ProgressEvent(timestamp: timestamp.addingTimeInterval(Double($0)), summary: "Unique event \($0)",
                          taskID: task.id, taskTitle: "Earlier title", snapshot: .init(currentState: "State \($0)"))
        }
        let source = URL(fileURLWithPath: "/tmp/UPPERCASE.md")
        let result = HandoffMarkdown.render(thread: thread, task: nil, threads: [root, thread], tasks: [],
                                             directory: URL(fileURLWithPath: "/tmp"), sourceURL: source, now: timestamp)
        #expect(result.contains("handoff_schema_version: 1"))
        #expect(result.contains(thread.id.uuidString.lowercased()))
        #expect(result.contains("SidePad / Memory"))
        #expect(result.contains(source.path))
        #expect(result.contains("Saved state") && result.contains("Review diff"))
        #expect(result.contains("latest 50 of 60"))
        #expect(!result.contains("Unique event 0\n"))
        #expect(result.contains("Unique event 59\n"))
        #expect(result.contains("````text\n```\n## Not a new export section\n```\n````"))
        #expect(result.contains("Original undated prose"))
    }
}
