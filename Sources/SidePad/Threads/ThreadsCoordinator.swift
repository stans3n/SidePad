import Foundation
import Combine

@MainActor
enum ActionExecutor {
    static func sameThreads(_ left: [ThreadRecord], _ right: [ThreadRecord]) -> Bool {
        left.sorted { $0.id.uuidString < $1.id.uuidString } == right.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    private struct RecoveryJournal: Codable {
        var beforeThreads: [String]
        var afterThreads: [String]
        var beforeTasks: [TaskItem]
        var afterTasks: [TaskItem]
    }
    static func recoveryURL(_ threads: ThreadStore) -> URL {
        threads.directory.appendingPathComponent(".intent-batch-recovery.json")
    }
    private static func canonical(_ records: [ThreadRecord]) throws -> [String] {
        try records.sorted { $0.id.uuidString < $1.id.uuidString }.map { try ThreadMarkdown.serialize($0) }
    }
    /// An interrupted cross-store commit is repaired only if both stores still match recorded states.
    /// A conflict preserves the journal and all user data for explicit recovery.
    static func recover(workspace: WorkspaceStore, threads: ThreadStore) throws {
        let url = recoveryURL(threads)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? 0) <= 32 * 1024 * 1024 else {
            throw ThreadStoreError.recoveryRequired(url.path)
        }
        try threads.verifyUnchanged(); try workspace.verifyPersistence()
        let journal = try JSONDecoder().decode(RecoveryJournal.self, from: Data(contentsOf: url))
        let before = try journal.beforeThreads.map { try ThreadMarkdown.parse($0).record }
        let after = try journal.afterThreads.map { try ThreadMarkdown.parse($0).record }
        try ThreadStore.validateHierarchy(before); try ThreadStore.validateHierarchy(after)
        try WorkspaceStore.validateTasks(journal.beforeTasks); try WorkspaceStore.validateTasks(journal.afterTasks)
        let current = try canonical(threads.threads)
        let beforeMatches = current == journal.beforeThreads
        let afterMatches = current == journal.afterThreads
        let tasksBefore = workspace.tasks == journal.beforeTasks, tasksAfter = workspace.tasks == journal.afterTasks
        guard (beforeMatches || afterMatches) && (tasksBefore || tasksAfter) else { throw ThreadStoreError.recoveryRequired(url.path) }
        if !(afterMatches && tasksAfter) {
            // No completed two-store commit exists: restore the approved batch's original state.
            if !beforeMatches { try threads.commit(before, allowActivityRemoval: true) }
            if !tasksBefore { try workspace.replaceTasks(journal.beforeTasks) }
        }
        try FileManager.default.removeItem(at: url)
    }

    static func apply(_ prepared: PreparedIntent, workspace: WorkspaceStore, threads: ThreadStore, confirmed: Bool = false,
                      allowActivityRemoval: Bool = false) throws {
        guard !prepared.requiresConfirmation || confirmed else { throw IntentError.confirmationRequired }
        guard !workspace.isReadOnly else { throw TaskLinkError.invalid(workspace.persistenceError ?? "Task storage is read-only.") }
        try workspace.verifyPersistence(); try threads.verifyUnchanged()
        guard sameThreads(threads.threads, prepared.beforeThreads), workspace.tasks == prepared.beforeTasks else { throw IntentError.stale }
        try WorkspaceStore.validateTasks(prepared.afterTasks); try ThreadStore.validateHierarchy(prepared.afterThreads)
        let url = recoveryURL(threads)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ThreadStoreError.recoveryRequired(url.path) }
        let journal = RecoveryJournal(beforeThreads: try canonical(prepared.beforeThreads), afterThreads: try canonical(prepared.afterThreads),
            beforeTasks: prepared.beforeTasks, afterTasks: prepared.afterTasks)
        let data = try JSONEncoder().encode(journal)
        guard data.count <= 32 * 1024 * 1024 else { throw IntentError.invalid("Batch exceeds the recovery journal limit.") }
        // Foundation forbids combining atomic and withoutOverwriting. Publish a complete private
        // staging file with an exclusive hard link so an existing journal/symlink cannot be replaced.
        let staging = threads.directory.appendingPathComponent(".intent-staging-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try data.write(to: staging, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        try FileManager.default.linkItem(at: staging, to: url)
        do {
            try threads.commit(prepared.afterThreads, allowActivityRemoval: allowActivityRemoval)
            try workspace.replaceTasks(prepared.afterTasks)
            try workspace.verifyPersistence()
            try FileManager.default.removeItem(at: url)
        } catch {
            let original = error
            do { try recover(workspace: workspace, threads: threads) }
            catch { throw IntentError.invalid("The batch was interrupted; recovery data is preserved at \(url.path). \(error.localizedDescription)") }
            throw original
        }
    }
}

@MainActor
final class ThreadsCoordinator: ObservableObject {
    let workspace: WorkspaceStore
    let threads: ThreadStore
    let settings: AISettingsStore
    @Published var selectedThreadID: UUID?
    @Published private(set) var isLoading = false
    @Published var feedback: String?
    @Published var errorMessage: String?
    @Published private(set) var pendingPlan: IntentPlan?
    @Published private(set) var pendingSummary = ""
    @Published private(set) var pendingPreview: [IntentPreviewItem] = []
    @Published private(set) var canUndo = false
    private var pending: PreparedIntent?
    private var undoStack: [PreparedIntent] = []
    private var parsingTask: Task<IntentPlan, Error>?
    private var requestID: UUID?

    init(workspace: WorkspaceStore, threads: ThreadStore, settings: AISettingsStore) {
        self.workspace = workspace; self.threads = threads; self.settings = settings
        do { try ActionExecutor.recover(workspace: workspace, threads: threads) }
        catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func capture(_ text: String, attachments: [AIInputAttachment] = []) async -> Bool {
        guard settings.canUseAICapture else {
            errorMessage = settings.captureAvailabilityMessage; return false
        }
        return await parseCapture(text, attachments: attachments, legacyOffline: false)
    }

    /// Explicit compatibility entry point; the unified AI capture never invokes this fallback.
    @discardableResult
    func captureLegacyOffline(_ text: String) async -> Bool {
        await parseCapture(text, attachments: [], legacyOffline: true)
    }

    private func parseCapture(_ text: String, attachments: [AIInputAttachment], legacyOffline: Bool) async -> Bool {
        guard !isLoading else { return false }
        errorMessage = nil; feedback = nil; discardPending()
        let id = UUID(); requestID = id; isLoading = true
        let providerKind = settings.provider
        let verifiedAt = settings.verifiedAt
        defer { if requestID == id { parsingTask = nil; isLoading = false; requestID = nil } }
        do {
            // Reload before assembling metadata so known external edits are visible to reference resolution.
            try threads.reload()
            let beforeThreads = threads.threads; let beforeTasks = workspace.tasks
            let selection = selectedThreadID
            let now = Date(); let timeZone = TimeZone.current
            let context = try IntentInputContext(threads: beforeThreads, tasks: beforeTasks, selectedThreadID: selection, now: now, timeZone: timeZone, input: text)
            let provider: any AIProvider = legacyOffline ? OfflineIntentParser() : try settings.makeProvider()
            let request = AIParseRequest(input: text, contextJSON: try context.json(), now: now, timeZone: timeZone, attachments: attachments)
            let parser = IntentParserService(provider: provider)
            let task = Task { try await parser.parse(request) }; parsingTask = task
            let plan = try await task.value
            guard requestID == id, !Task.isCancelled else { return false }
            guard ActionExecutor.sameThreads(beforeThreads, threads.threads), beforeTasks == workspace.tasks,
                  selectedThreadID == selection, settings.provider == providerKind,
                  legacyOffline || settings.verifiedAt == verifiedAt else { throw IntentError.stale }
            if !legacyOffline { settings.recordCaptureSuccess() }
            try stagePlan(plan, rawInput: text, now: now, timeZone: timeZone)
        } catch is CancellationError {
            if requestID == id { feedback = "已取消，未应用操作。" }
        } catch {
            if requestID == id {
                if !legacyOffline, settings.provider == providerKind, settings.verifiedAt == verifiedAt { settings.recordCaptureFailure(error) }
                errorMessage = error.localizedDescription
            }
        }
        return false
    }

    /// Shared local validation/review boundary. Staging never mutates either store.
    func stagePlan(_ plan: IntentPlan, rawInput: String? = nil, now: Date = Date(), timeZone: TimeZone = .current) throws {
        discardPending()
        let prepared = try IntentValidator.prepare(plan, threads: threads.threads, tasks: workspace.tasks,
            selectedThreadID: selectedThreadID, now: now, timeZone: timeZone, rawInput: rawInput)
        pending = prepared; pendingPlan = plan; pendingSummary = prepared.summary; pendingPreview = prepared.preview
        feedback = "请检查操作预览后确认。确认前不会写入数据。"
    }

    func cancel() {
        parsingTask?.cancel(); parsingTask = nil; requestID = nil; isLoading = false
        discardPending()
        feedback = "已取消，未应用操作。"
    }

    func confirmPending() throws {
        guard let pending else { return }
        try execute(pending, confirmed: true)
        discardPending()
    }
    func discardPending() { pending = nil; pendingPlan = nil; pendingSummary = ""; pendingPreview = [] }

    private func execute(_ prepared: PreparedIntent, confirmed: Bool = false) throws {
        try ActionExecutor.apply(prepared, workspace: workspace, threads: threads, confirmed: confirmed)
        var committed = prepared
        // The Markdown codec normalizes dates to milliseconds and section delimiters.
        // Undo must compare the canonical committed values, not pre-serialization drafts.
        committed.afterThreads = threads.threads
        committed.afterTasks = workspace.tasks
        undoStack.append(committed)
        if undoStack.count > 20 { undoStack.removeFirst() }
        canUndo = true; errorMessage = nil
        feedback = "已应用确认的更改，可撤销。"
        if let first = prepared.createdThreadIDs.first { selectedThreadID = first }
    }

    @discardableResult
    func createThread(title: String, parentID: UUID?) throws -> UUID {
        let plan = IntentPlan(operations: [IntentOperation(operation: .createThread, ref: "temp:manual", parentRef: parentID?.uuidString, title: title)])
        let prepared = try IntentValidator.prepare(plan, threads: threads.threads, tasks: workspace.tasks, selectedThreadID: nil)
        try execute(prepared, confirmed: true)
        return prepared.createdThreadIDs[0]
    }

    @discardableResult
    func addTask(title: String, threadID: UUID?, parentTaskID: UUID? = nil, dueDate: Date? = nil, priority: Int? = nil) throws -> UUID {
        let due = dueDate.map { IntentDueDate(date: IntentValidator.localDate($0, timeZone: .current), timeZone: TimeZone.current.identifier) }
        let plan = IntentPlan(operations: [IntentOperation(operation: parentTaskID == nil ? .createTask : .createSubtask,
            ref: "temp:manual", parentRef: parentTaskID?.uuidString, threadRef: threadID?.uuidString,
            title: title, dueDate: due, priority: priority)])
        let prepared = try IntentValidator.prepare(plan, threads: threads.threads, tasks: workspace.tasks, selectedThreadID: threadID)
        try execute(prepared, confirmed: true)
        return prepared.afterTasks.last!.id
    }

    func undo() throws {
        guard let previous = undoStack.last else { return }
        guard ActionExecutor.sameThreads(threads.threads, previous.afterThreads), workspace.tasks == previous.afterTasks else { throw IntentError.stale }
        // commit also checks the actual files, so Undo cannot erase a later external edit.
        let reversal = PreparedIntent(beforeThreads: previous.afterThreads, afterThreads: previous.beforeThreads,
            beforeTasks: previous.afterTasks, afterTasks: previous.beforeTasks, requiresConfirmation: false,
            summary: "Undo", createdThreadIDs: [])
        try ActionExecutor.apply(reversal, workspace: workspace, threads: threads, allowActivityRemoval: true)
        undoStack.removeLast(); canUndo = !undoStack.isEmpty
        if let selectedThreadID, !threads.threads.contains(where: { $0.id == selectedThreadID }) { self.selectedThreadID = nil }
        feedback = "已撤销。"; errorMessage = nil
    }

    /// A user-submitted log uses one stable ID so retrying a successful form cannot append twice.
    func logProgress(threadID: UUID?, taskID: UUID?, summary: String, snapshot: ProgressSnapshot,
                     expectedThread: ThreadRecord?, expectedTask: TaskItem?, eventID: UUID = UUID()) throws {
        let note = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard threadID != nil || taskID != nil else { throw IntentError.invalid("Choose a Thread or task first.") }
        let task = taskID.flatMap { id in workspace.tasks.first { $0.id == id } }
        let thread = threadID.flatMap { id in threads.threads.first { $0.id == id } }
        let existing = threads.threads.flatMap(\.progressEvents).first { $0.id == eventID }
            ?? workspace.tasks.lazy.flatMap { $0.progressEvents ?? [] }.first { $0.id == eventID }
        if let existing {
            try threads.verifyUnchanged()
            try workspace.verifyPersistence()
            let ownerMatches = threadID.map { id in threads.threads.first { $0.id == id }?.progressEvents.contains { $0.id == eventID } == true }
                ?? (task?.progressEvents?.contains { $0.id == eventID } == true)
            guard ownerMatches, existing.summary == note, existing.taskID == taskID,
                  existing.snapshot == snapshot, existing.source == .manual else {
                throw IntentError.invalid("This progress ID already belongs to a different entry.")
            }
            feedback = "这条进展已保存。"; return
        }
        guard taskID == nil || (task != nil && task == expectedTask && task?.threadID == threadID),
              threadID == nil || (thread != nil && thread == expectedThread) else { throw IntentError.stale }
        guard thread?.status != .archived else { throw IntentError.invalid("Reopen this Thread before logging progress.") }
        let now = Date()
        let event = ProgressEvent(id: eventID, timestamp: now, summary: note, source: .manual,
            taskID: task?.id, taskTitle: task?.title, taskCompleted: task?.isCompleted,
            snapshot: snapshot, rawInput: summary)
        try ProgressEvent.validate([event])
        var updatedThreads = threads.threads
        var updatedTasks = workspace.tasks
        if let threadID, let index = updatedThreads.firstIndex(where: { $0.id == threadID }) {
            updatedThreads[index].progressEvents.append(event)
            // Task snapshots describe that task. Only a Thread log replaces shared project context.
            if taskID == nil {
                updatedThreads[index].currentState = snapshot.currentState
                updatedThreads[index].nextAction = snapshot.nextAction
                updatedThreads[index].blockers = snapshot.blockers
                updatedThreads[index].resumePoint = snapshot.resumePoint
            }
            updatedThreads[index].updatedAt = now; updatedThreads[index].lastActivity = now
        } else if let taskID, let index = updatedTasks.firstIndex(where: { $0.id == taskID }) {
            updatedTasks[index].progressEvents = (updatedTasks[index].progressEvents ?? []) + [event]
        }
        let prepared = PreparedIntent(beforeThreads: threads.threads, afterThreads: updatedThreads,
            beforeTasks: workspace.tasks, afterTasks: updatedTasks, requiresConfirmation: true,
            summary: note, createdThreadIDs: [])
        try execute(prepared, confirmed: true)
        feedback = "进展已保存，可撤销。"
    }

    func resumeThread(_ id: UUID) throws -> String {
        let context = try contextMarkdown(threadID: id)
        selectedThreadID = id
        return context
    }

    func contextMarkdown(threadID: UUID?, taskID: UUID? = nil) throws -> String {
        // Export only canonical saved data; stale external edits must first be resolved/reloaded.
        try threads.reload()
        try workspace.verifyPersistence()
        let thread = threadID.flatMap { id in threads.threads.first { $0.id == id } }
        let task = taskID.flatMap { id in workspace.tasks.first { $0.id == id } }
        guard threadID == nil || thread != nil, taskID == nil || task != nil,
              thread != nil || task != nil else { throw IntentError.stale }
        return HandoffMarkdown.render(thread: thread, task: task, threads: threads.threads,
            tasks: workspace.tasks, directory: threads.directory, sourceURL: thread.map { threads.fileURL(for: $0.id) })
    }
}
