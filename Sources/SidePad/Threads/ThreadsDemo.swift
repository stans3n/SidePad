import Foundation

/// Only the explicitly built --demo app uses this disposable, offline sample library.
@MainActor
enum ThreadsDemo {
    static func makeController() -> PanelController {
        // The --demo bundle has its own identifier. Foundation may reject a named suite
        // equal to the current application's domain; standard already owns that domain.
        if Bundle.main.object(forInfoDictionaryKey: "SidePadDemoV2") as? Bool == true {
            return makeV2Controller()
        }
        let defaults = UserDefaults.standard
        let workspace = WorkspaceStore(defaults: defaults)
        let directory = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Threads Demo Data")
        let threads = ThreadStore(directory: directory)
        let settings = AISettingsStore(defaults: defaults)
        settings.provider = .offline
        if threads.threads.isEmpty && workspace.tasks.isEmpty && !threads.isReadOnly && !workspace.isReadOnly {
            do {
                let now = Date()
                let project = ThreadRecord(title: "SidePad Demo", createdAt: now.addingTimeInterval(-7_200),
                    summary: "Synthetic examples for trying project memory without changing your real library.")
                var child = ThreadRecord(title: "Progress Memory", parentID: project.id, createdAt: now.addingTimeInterval(-7_200),
                    currentState: "Historical snapshots are ready.", nextAction: "Try logging a new milestone.",
                    resumePoint: "Click the task, then select an earlier station.")
                let task = TaskItem(title: "Build the task timeline", createdAt: now.addingTimeInterval(-7_200),
                                    todayDate: now, sortOrder: 0, threadID: child.id)
                child.progressEvents = [
                    ProgressEvent(timestamp: now.addingTimeInterval(-3_600), summary: "Defined the event format", taskID: task.id,
                        taskTitle: task.title, taskCompleted: false, snapshot: .init(currentState: "Format drafted", nextAction: "Build stations"),
                        rawInput: "Keep a snapshot at every milestone."),
                    ProgressEvent(timestamp: now.addingTimeInterval(-1_800), summary: "Added clickable stations", taskID: task.id,
                        taskTitle: task.title, taskCompleted: false, snapshot: ProgressSnapshot(thread: child),
                        rawInput: "Select a timestamp to see the state at that moment.")
                ]
                try threads.commit([project, child])
                try workspace.replaceTasks([task, TaskItem(title: "A standalone note also works", sortOrder: 1)])
            } catch { threads.errorMessage = error.localizedDescription }
        }
        workspace.selection = .threads
        workspace.autoHide = false
        if workspace.size(for: .threads) == nil { workspace.setSize(CGSize(width: 460, height: 850), for: .threads) }
        let controller = PanelController(loadPage: false, store: workspace, threads: threads, aiSettings: settings,
            attachments: AttachmentStore(defaults: defaults, defaultDirectory: directory.appendingPathComponent("Attachments")))
        controller.threadsCoordinator.selectedThreadID = threads.threads.first { $0.title == "Progress Memory" }?.id
        controller.threadsViewState.expandedIDs = Set(threads.threads.map(\.id))
        if Bundle.main.object(forInfoDictionaryKey: "SidePadDemoPreview") as? Bool == true,
           let threadID = controller.threadsCoordinator.selectedThreadID,
           let task = workspace.tasks.first(where: { $0.threadID == threadID && !$0.isCompleted }) {
            // Explicit QA build only: exercise the real validation/preview/apply path
            // with a synthetic plan, without a provider call or real-library writes.
            do {
                try controller.threadsCoordinator.stagePlan(IntentPlan(schemaVersion: 2, operations: [
                    .init(operation: .changeTaskStatus, target: task.id.uuidString, taskStatus: .completed),
                    .init(operation: .createTask, ref: "temp:demo-followup", threadRef: threadID.uuidString,
                          title: "Review synthetic capture results"),
                    .init(operation: .appendProgressEvent, target: threadID.uuidString,
                          progress: "Synthetic preview fixture: completed a check and created its follow-up.")
                ]), rawInput: "Synthetic preview fixture for local UI verification.")
            } catch { controller.threadsCoordinator.errorMessage = error.localizedDescription }
        }
        return controller
    }

    /// Fresh, explicitly synthetic V2 library; never reads or resets real user data.
    private static func makeV2Controller() -> PanelController {
        let defaults = UserDefaults.standard
        let workspace = WorkspaceStore(defaults: defaults)
        let directory = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Threads V2 Demo Data")
        let threads = ThreadStore(directory: directory)
        let settings = AISettingsStore(defaults: defaults)
        settings.provider = .offline
        if threads.threads.isEmpty && workspace.tasks.isEmpty && !threads.isReadOnly && !workspace.isReadOnly {
            do {
                let now = Date()
                var sidepad = ThreadRecord(title: "SidePad", createdAt: now.addingTimeInterval(-86_400 * 4),
                    summary: "A lightweight place to pause and resume long-running work.",
                    currentState: "Project navigation is ready for an interaction review.",
                    nextAction: "Check the first click in an inactive window", notes: "Synthetic demonstration data only.",
                    linkedResources: "https://github.com/JUNERDD/Atd")
                let completed = TaskItem(title: "Simplify project navigation", isCompleted: true,
                    createdAt: now.addingTimeInterval(-86_400), sortOrder: 0, threadID: sidepad.id)
                let next = TaskItem(title: "Check the first click in an inactive window", todayDate: now,
                    sortOrder: 1, threadID: sidepad.id)
                sidepad.progressEvents = [ProgressEvent(timestamp: now.addingTimeInterval(-3_600),
                    summary: "Completed project navigation", source: .taskChange, taskID: completed.id,
                    taskTitle: completed.title, taskCompleted: true, snapshot: ProgressSnapshot(thread: sidepad))]
                sidepad.checkpoints = [ThreadCheckpoint(threadID: sidepad.id,
                    createdAt: now.addingTimeInterval(-1_800),
                    note: "Finished simplifying navigation. Next time, review the click targets.",
                    snapshot: ProgressSnapshot(thread: sidepad), relatedTaskIDs: [next.id],
                    resources: ["https://github.com/JUNERDD/Atd"])]
                let windows = ThreadRecord(title: "WindowSwitcher", createdAt: now.addingTimeInterval(-86_400 * 2),
                    currentState: "Window ordering is stable.", nextAction: "Fix window focus restoration")
                let child = ThreadRecord(title: "窗口与交互 · Window interactions", parentID: sidepad.id,
                    nextAction: "检查中文长句在窄窗口中能否自然换行，并保持所有操作入口可见。")
                let archived = ThreadRecord(title: "Earlier prototype", status: .archived,
                    summary: "An archived project remains discoverable in All Projects.")
                try threads.commit([sidepad, windows, child, archived])
                try workspace.replaceTasks([completed, next,
                    TaskItem(title: "A standalone task in Today", todayDate: now, sortOrder: 2)])
            } catch { threads.errorMessage = error.localizedDescription }
        }
        workspace.selection = .threads
        workspace.autoHide = false
        if workspace.size(for: .threads) == nil { workspace.setSize(CGSize(width: 420, height: 660), for: .threads) }
        let controller = PanelController(loadPage: false, store: workspace, threads: threads, aiSettings: settings,
            attachments: AttachmentStore(defaults: defaults, defaultDirectory: directory.appendingPathComponent("Attachments")))
        return controller
    }

}
