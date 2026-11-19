import AppKit
import SwiftUI

/// Kept by the panel so switching to Today or a website never discards a local draft.
@MainActor
final class ThreadsViewState: ObservableObject {
    @Published var search = ""
    @Published var treeExpanded = false
    @Published var expandedIDs = Set<UUID>()
    @Published var captureText = ""
    var submittedCaptureText: String?
    @Published var errorMessage: String?
    @Published var feedback: String?
    @Published private(set) var drafts: [UUID: ThreadRecord] = [:]
    private var bases: [UUID: ThreadRecord] = [:]

    func value(for thread: ThreadRecord) -> ThreadRecord { drafts[thread.id] ?? thread }
    func isDirty(_ id: UUID) -> Bool { drafts[id] != nil }
    func hasConflict(_ thread: ThreadRecord) -> Bool {
        guard let base = bases[thread.id] else { return false }
        return base != thread
    }
    func update(_ value: ThreadRecord, base: ThreadRecord) {
        if bases[base.id] == nil { bases[base.id] = base }
        if value == bases[base.id] {
            drafts.removeValue(forKey: base.id)
            bases.removeValue(forKey: base.id)
        } else { drafts[base.id] = value }
    }
    func save(_ id: UUID, in store: ThreadStore) throws {
        guard var draft = drafts[id] else { return }
        guard let current = store.threads.first(where: { $0.id == id }), bases[id] == current else {
            throw DraftError.changed
        }
        draft.updatedAt = Date()
        draft.lastActivity = draft.updatedAt
        if ProgressSnapshot(thread: draft) != ProgressSnapshot(thread: current) {
            draft.progressEvents.append(ProgressEvent(timestamp: draft.updatedAt,
                summary: "Context updated", source: .manual, snapshot: ProgressSnapshot(thread: draft)))
        }
        if draft.status != current.status {
            draft.progressEvents.append(ProgressEvent(timestamp: draft.updatedAt,
                summary: "Thread status changed to \(draft.status.rawValue)", source: .manual,
                snapshot: ProgressSnapshot(thread: draft)))
        }
        try store.save(draft)
        discard(id)
        feedback = "Thread saved."
    }
    func discard(_ id: UUID) {
        drafts.removeValue(forKey: id)
        bases.removeValue(forKey: id)
    }
    func reloadDiscardingDraft(_ id: UUID, in store: ThreadStore) throws {
        try store.reload()
        discard(id)
        errorMessage = nil
        feedback = "Loaded the Markdown file."
    }
    func saveLocalCopy(_ id: UUID, in store: ThreadStore) throws -> UUID {
        guard var copy = drafts[id] else { throw DraftError.missing }
        try store.reload()
        copy.id = UUID()
        copy.title += " (local copy)"
        copy.createdAt = Date()
        copy.updatedAt = copy.createdAt
        copy.lastActivity = copy.createdAt
        if let parentID = copy.parentID, !store.threads.contains(where: { $0.id == parentID }) {
            copy.parentID = nil
        }
        try store.save(copy)
        discard(id)
        errorMessage = nil
        feedback = "Saved your draft as a new Thread. The original file is unchanged."
        return copy.id
    }

    private enum DraftError: LocalizedError {
        case changed, missing
        var errorDescription: String? {
            switch self {
            case .changed: "This Thread changed after you started editing. Reload the external version or save your draft as a separate copy."
            case .missing: "There is no local draft to copy."
            }
        }
    }
}

struct ThreadTreeRow: Identifiable {
    let thread: ThreadRecord
    let depth: Int
    let hasChildren: Bool
    let breadcrumb: String
    var id: UUID { thread.id }
}

/// Iterative traversal supports deep libraries without recursive SwiftUI view types.
enum ThreadTreeProjection {
    static func path(to id: UUID, in threads: [ThreadRecord]) -> String {
        let byID = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return path(to: id, byID: byID)
    }

    private static func path(to id: UUID, byID: [UUID: ThreadRecord]) -> String {
        var names: [String] = []
        var current: UUID? = id
        var seen = Set<UUID>()
        while let id = current, seen.insert(id).inserted, let thread = byID[id] {
            names.append(thread.title)
            current = thread.parentID
        }
        return names.reversed().joined(separator: " › ")
    }

    static func descendants(of id: UUID, in threads: [ThreadRecord]) -> Set<UUID> {
        let children = Dictionary(grouping: threads, by: \.parentID)
        var seen: Set<UUID> = [id]
        var pending = [id]
        while let current = pending.popLast() {
            for child in children[current] ?? [] where seen.insert(child.id).inserted {
                pending.append(child.id)
            }
        }
        return seen
    }

    static func rows(in threads: [ThreadRecord], expanded: Set<UUID>, search: String) -> [ThreadTreeRow] {
        let children = Dictionary(grouping: threads, by: \.parentID)
        let byID = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        func sorted(_ values: [ThreadRecord]) -> [ThreadRecord] {
            values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        if !query.isEmpty {
            return sorted(threads.filter {
                [$0.title, $0.summary, $0.currentState].contains { $0.localizedCaseInsensitiveContains(query) }
            }).map {
                ThreadTreeRow(thread: $0, depth: 0, hasChildren: !(children[$0.id] ?? []).isEmpty,
                              breadcrumb: path(to: $0.id, byID: byID))
            }
        }
        var pending = sorted(children[nil] ?? []).reversed().map { ($0, 0) }
        var seen = Set<UUID>()
        var rows: [ThreadTreeRow] = []
        while let (thread, depth) = pending.popLast(), seen.insert(thread.id).inserted {
            let nested = sorted(children[thread.id] ?? [])
            rows.append(ThreadTreeRow(thread: thread, depth: depth, hasChildren: !nested.isEmpty,
                                      breadcrumb: path(to: thread.id, byID: byID)))
            if expanded.contains(thread.id) {
                pending.append(contentsOf: nested.reversed().map { ($0, depth + 1) })
            }
        }
        return rows
    }
}

private enum ThreadsSheet: Identifiable {
    case createThread(UUID?), rename(UUID), createTask(UUID?, UUID?), taskDetails(UUID), linkTask(UUID), taskProgress(UUID)
    var id: String {
        switch self {
        case let .createThread(parent): "thread-\(parent?.uuidString ?? "root")"
        case let .rename(id): "rename-\(id)"
        case let .createTask(thread, parent): "task-\(thread?.uuidString ?? "inbox")-\(parent?.uuidString ?? "root")"
        case let .taskDetails(id): "task-details-\(id)"
        case let .linkTask(id): "link-\(id)"
        case let .taskProgress(id): "progress-\(id)"
        }
    }
}

@MainActor
struct ThreadsView: View {
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var threads: ThreadStore
    @ObservedObject var settings: AISettingsStore
    @ObservedObject var attachments: AttachmentStore
    @ObservedObject var coordinator: ThreadsCoordinator
    @ObservedObject var viewState: ThreadsViewState
    @State private var sheet: ThreadsSheet?
    @State private var captureFocusToken = 0
    @StateObject private var pins: ProjectPinsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(workspace: WorkspaceStore, threads: ThreadStore, settings: AISettingsStore,
         attachments: AttachmentStore, coordinator: ThreadsCoordinator, viewState: ThreadsViewState) {
        self.workspace = workspace; self.threads = threads; self.settings = settings
        self.attachments = attachments; self.coordinator = coordinator; self.viewState = viewState
        _pins = StateObject(wrappedValue: ProjectPinsStore(library: threads.directory))
    }

    private var selectedThread: ThreadRecord? {
        guard let id = coordinator.selectedThreadID else { return nil }
        return threads.threads.first { $0.id == id } ?? viewState.drafts[id]
    }
    private var rows: [ThreadTreeRow] {
        ThreadTreeProjection.rows(in: threads.threads, expanded: viewState.expandedIDs, search: viewState.search)
    }

    var body: some View {
        VStack(spacing: 0) {
            navigation
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let thread = selectedThread, !viewState.treeExpanded {
                        ThreadDetailView(thread: thread, workspace: workspace, threads: threads,
                            coordinator: coordinator, viewState: viewState,
                            addTask: { sheet = .createTask(thread.id, nil) },
                            addSubtask: { sheet = .createTask(thread.id, $0) },
                            editTask: { sheet = .taskDetails($0) },
                            openTaskHistory: { sheet = .taskProgress($0) },
                            linkTask: { sheet = .linkTask(thread.id) },
                            addChild: { sheet = .createThread(thread.id) })
                            .id(thread.id)
                            .transition(.opacity)
                    } else if viewState.treeExpanded {
                        projectBrowser
                            .transition(.opacity)
                    } else {
                        projectsLanding
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, MemoryStyle.gutter).padding(.top, 4).padding(.bottom, MemoryStyle.sectionGap)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            quickCapture
        }
        .background {
            if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
            else { Color.clear }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.9), value: coordinator.selectedThreadID)
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.9), value: viewState.treeExpanded)
        .sheet(item: $sheet) { sheetContent($0) }
        .onAppear {
            settings.refreshCredentialStatus()
            pins.seedIfNeeded(from: threads.threads)
        }
        .onChange(of: threads.threads.map(\.id)) { _, _ in
            pins.reconcile(with: threads.threads)
            pins.seedIfNeeded(from: threads.threads)
        }
        .onExitCommand {
            if !viewState.search.isEmpty { viewState.search = "" }
            else { viewState.treeExpanded = false; coordinator.selectedThreadID = nil }
        }
    }

    private var navigation: some View {
        HStack(spacing: 4) {
            if selectedThread != nil || viewState.treeExpanded {
                Button {
                    coordinator.selectedThreadID = nil
                    viewState.treeExpanded = false
                    viewState.search = ""
                } label: {
                    Label("Projects", systemImage: "chevron.left")
                        .font(MemoryStyle.body.weight(.medium)).padding(.horizontal, 8).frame(minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MemoryRowButtonStyle())
                .keyboardShortcut("[", modifiers: .command)
                .accessibilityLabel("Back to Projects")
            } else {
                Text("Projects").font(MemoryStyle.heading).padding(.leading, 8)
            }
            Spacer(minLength: 0)
            Menu {
                Button("New Project…") { sheet = .createThread(nil) }
                if let selectedThread {
                    Button("New Child Thread…") { sheet = .createThread(selectedThread.id) }
                    Button("New Task…") { sheet = .createTask(selectedThread.id, nil) }
                    Button("Rename Project…") { sheet = .rename(selectedThread.id) }
                    pinActions(selectedThread)
                }
                Button("New Inbox Task…") { sheet = .createTask(nil, nil) }
                Divider()
                Button("Reload Markdown") {
                    perform { try threads.reload(); viewState.feedback = "Markdown reloaded; local drafts are retained." }
                }
            } label: { Image(systemName: "plus").frame(width: 36, height: 36).contentShape(Rectangle()) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .help("Create and manage projects").accessibilityLabel("Create and manage projects")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private var projectsLanding: some View {
        VStack(alignment: .leading, spacing: 8) {
            if threads.threads.isEmpty {
                Text("Keep the thread of your work.").font(.headline).padding(.top, 18)
                Text("Save where you stopped. Know where to begin.")
                    .font(MemoryStyle.body).foregroundStyle(.secondary)
                Button("Create Project…") { sheet = .createThread(nil) }
                    .padding(.vertical, 8)
            } else {
                let pinned = pins.projects(in: threads.threads)
                if pinned.isEmpty {
                    Text("Pin the projects you want to come back to.")
                        .font(MemoryStyle.body).foregroundStyle(.secondary).padding(.vertical, 20)
                }
                ForEach(pinned) { thread in
                    projectRow(thread)
                        .contextMenu {
                            pinActions(thread)
                            Button("Rename…") { sheet = .rename(thread.id) }
                            Button("Open Markdown") { openMarkdown(thread.id) }
                        }
                }
            }
            Button {
                viewState.treeExpanded = true
                viewState.search = ""
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").frame(width: 18)
                    Text("All Projects")
                    Spacer()
                    Text("\(threads.threads.count)").foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right").font(MemoryStyle.metadata)
                }
                .font(MemoryStyle.body).foregroundStyle(.secondary)
                .padding(.horizontal, MemoryStyle.rowInset).frame(minHeight: 40).contentShape(Rectangle())
            }
            .buttonStyle(MemoryRowButtonStyle()).padding(.top, 8)
        }
    }

    private func projectRow(_ thread: ThreadRecord) -> some View {
        Button { openProject(thread.id) } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "folder").font(.title3).foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewState.value(for: thread).title).font(MemoryStyle.heading).lineLimit(1)
                    Text("Next: " + ProjectResumeProjection.next(thread: thread, tasks: workspace.tasks).text)
                        .font(MemoryStyle.body).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 2)
                Image(systemName: "chevron.right").font(MemoryStyle.metadata.weight(.medium)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, MemoryStyle.rowInset).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(MemoryRowButtonStyle())
        .accessibilityLabel("Open \(thread.title). Next: \(ProjectResumeProjection.next(thread: thread, tasks: workspace.tasks).text)")
    }

    private var projectBrowser: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search all projects", text: $viewState.search).textFieldStyle(.plain)
                    .accessibilityLabel("Search all projects, including archived")
                if !viewState.search.isEmpty {
                    Button { viewState.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear project search")
                }
            }
            .padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            Text("Choose up to two pins. Archived projects stay available here.")
                .font(MemoryStyle.secondary).foregroundStyle(.secondary)
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { row in treeRow(row) }
                ForEach(viewState.drafts.values.filter { draft in !threads.threads.contains { $0.id == draft.id } }
                    .sorted { $0.title < $1.title }) { draft in
                    Button { openProject(draft.id) } label: {
                        Label("\(draft.title) — local draft", systemImage: "pencil")
                            .font(MemoryStyle.secondary).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(MemoryRowButtonStyle())
                }
                if rows.isEmpty { Text("No matching projects").foregroundStyle(.secondary).padding(.vertical, 12) }
            }
        }
    }

    private func treeRow(_ row: ThreadTreeRow) -> some View {
        HStack(spacing: 0) {
            if row.hasChildren && viewState.search.isEmpty {
                Button {
                    if !viewState.expandedIDs.insert(row.id).inserted { viewState.expandedIDs.remove(row.id) }
                } label: {
                    Image(systemName: viewState.expandedIDs.contains(row.id) ? "chevron.down" : "chevron.right")
                        .font(MemoryStyle.metadata.weight(.medium)).frame(width: 36, height: 40).contentShape(Rectangle())
                }
                .buttonStyle(MemoryRowButtonStyle())
                .accessibilityLabel("\(viewState.expandedIDs.contains(row.id) ? "Collapse" : "Expand") \(row.thread.title)")
            }
            Button { openProject(row.id) } label: {
                HStack(spacing: 8) {
                    Image(systemName: statusSymbol(row.thread.status)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewState.value(for: row.thread).title).lineLimit(1)
                        if row.thread.status == .archived || !viewState.search.isEmpty {
                            Text(row.thread.status == .archived ? "Archived" : row.breadcrumb)
                                .font(MemoryStyle.metadata).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if viewState.isDirty(row.id) { Circle().fill(Color.accentColor).frame(width: 4, height: 4) }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(MemoryStyle.metadata).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 40).contentShape(Rectangle())
            }
            .buttonStyle(MemoryRowButtonStyle()).help(row.breadcrumb)
            Menu { pinActions(row.thread) } label: {
                Image(systemName: pins.contains(row.id) ? "pin.fill" : "pin")
                    .font(MemoryStyle.secondary).foregroundStyle(pins.contains(row.id) ? Color.accentColor : Color.secondary)
                    .frame(width: 36, height: 40).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .accessibilityLabel("Pin options for \(row.thread.title)")
        }
        .padding(.leading, CGFloat(min(row.depth, 3)) * 10)
        .contextMenu {
            pinActions(row.thread)
            Button("New Child Thread…") { sheet = .createThread(row.id) }
            Button("Rename…") { sheet = .rename(row.id) }
            Menu("Move to") {
                Button("Top Level") { change(row.thread) { $0.parentID = nil } }
                let excluded = ThreadTreeProjection.descendants(of: row.id, in: threads.threads)
                ForEach(threads.threads.filter { !excluded.contains($0.id) }) { parent in
                    Button(ThreadTreeProjection.path(to: parent.id, in: threads.threads)) { change(row.thread) { $0.parentID = parent.id } }
                }
            }
            Menu("Status") {
                ForEach(ThreadStatus.allCases, id: \.self) { status in
                    Button(status.rawValue.capitalized) { change(row.thread) { $0.status = status } }
                }
            }
            Button("Open Markdown") { openMarkdown(row.id) }
        }
    }

    @ViewBuilder private func pinActions(_ thread: ThreadRecord) -> some View {
        if pins.contains(thread.id) {
            Button("Unpin Project") { pins.unpin(thread.id) }
            if pins.ids.first != thread.id { Button("Move Pin First") { pins.moveFirst(thread.id) } }
            if pins.ids.last != thread.id { Button("Move Pin Last") { pins.moveLast(thread.id) } }
        } else {
            Button("Pin Project") { pins.pin(thread.id) }.disabled(pins.ids.count >= 2)
            if pins.ids.count >= 2 { Text("Unpin a project to make room") }
        }
    }

    private func openProject(_ id: UUID) {
        coordinator.selectedThreadID = id
        viewState.treeExpanded = false
    }

    private var quickCapture: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let plan = coordinator.pendingPlan {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Review proposed changes").font(MemoryStyle.secondary.weight(.medium))
                    ScrollView {
                        IntentPlanPreviewView(plan: plan, items: coordinator.pendingPreview)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                    HStack {
                        Button("Discard") {
                            coordinator.discardPending(); viewState.submittedCaptureText = nil; captureFocusToken += 1
                        }
                        Spacer()
                        Button("Apply Changes") {
                            perform {
                                try coordinator.confirmPending()
                                attachments.markSubmitted()
                                clearSubmittedCapture()
                                captureFocusToken += 1
                            }
                        }
                        .disabled(plan.needsClarification)
                    }
                    .controlSize(.small)
                }
                .padding(8).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            if let error = viewState.errorMessage ?? coordinator.errorMessage ?? attachments.errorMessage ?? threads.errorMessage ?? workspace.taskError {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).textSelection(.enabled).lineLimit(4).help(error)
                    Spacer(minLength: 0)
                    if attachments.errorMessage != nil {
                        Button { attachments.clearError() } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                            .buttonStyle(.plain).accessibilityLabel("Dismiss attachment error")
                    }
                }
                .font(MemoryStyle.secondary).foregroundStyle(.red)
            } else if let feedback = viewState.feedback ?? coordinator.feedback {
                Text(feedback).font(MemoryStyle.secondary).foregroundStyle(.secondary).lineLimit(2)
            }
            CaptureComposerView(text: $viewState.captureText, settings: settings, attachments: attachments,
                isLoading: coordinator.isLoading, hasPendingPlan: coordinator.pendingPlan != nil,
                submit: capture, cancel: { coordinator.cancel() }, focusToken: captureFocusToken)
            HStack(spacing: 8) {
                Menu("Manual") {
                    Button("New Thread…") { sheet = .createThread(nil) }
                    Button("New Task…") { sheet = .createTask(coordinator.selectedThreadID, nil) }
                }
                .fixedSize()
                Spacer()
                if coordinator.canUndo { Button("Undo Last Batch") { perform { try coordinator.undo() } } }
            }
            .font(MemoryStyle.secondary).controlSize(.small)
        }
        .padding(.horizontal, MemoryStyle.gutter).padding(.vertical, 8)
    }

    @ViewBuilder private func sheetContent(_ sheet: ThreadsSheet) -> some View {
        switch sheet {
        case let .createThread(parent):
            ThreadNameSheet(title: parent == nil ? "New Thread" : "New Child Thread", initialName: "",
                            detail: parent.flatMap { id in threads.threads.first { $0.id == id }?.title }) { title in
                let id = try coordinator.createThread(title: title, parentID: parent)
                if let parent { viewState.expandedIDs.insert(parent) }
                coordinator.selectedThreadID = id
            }
        case let .rename(id):
            if let thread = threads.threads.first(where: { $0.id == id }) {
                ThreadNameSheet(title: "Rename Thread", initialName: viewState.value(for: thread).title) { name in
                    var draft = viewState.value(for: thread)
                    draft.title = name
                    viewState.update(draft, base: thread)
                    try viewState.save(id, in: threads)
                }
            }
        case let .createTask(thread, parent):
            ThreadTaskEditor(workspace: workspace, threads: threads, coordinator: coordinator,
                             task: nil, threadID: thread, parentTaskID: parent)
        case let .taskDetails(id):
            if let task = workspace.tasks.first(where: { $0.id == id }) {
                ThreadTaskEditor(workspace: workspace, threads: threads, coordinator: coordinator,
                                 task: task, threadID: task.threadID, parentTaskID: task.parentTaskID)
            }
        case let .linkTask(thread):
            ThreadLinkTaskSheet(workspace: workspace, threadID: thread)
        case let .taskProgress(id):
            ProgressMemorySheet(target: .task(id), workspace: workspace, threads: threads,
                                coordinator: coordinator, viewState: viewState)
        }
    }

    private func capture() {
        guard settings.canUseAICapture, !coordinator.isLoading, coordinator.pendingPlan == nil,
              !attachments.isImporting, !attachments.isCaptureActive else { return }
        viewState.errorMessage = nil
        viewState.feedback = nil
        let text = viewState.captureText
        viewState.submittedCaptureText = text
        Task {
            do {
                let contexts = try attachments.beginCapture()
                defer { attachments.endCapture() }
                let inputs = contexts.map { value in
                    AIInputAttachment(name: value.name, type: value.kind, extraction: value.extraction,
                        text: value.text, notice: value.notice + (value.truncated ? " Extracted text was truncated to the attachment budget." : ""))
                }
                if await coordinator.capture(text, attachments: inputs) { clearSubmittedCapture() }
            } catch { viewState.errorMessage = error.localizedDescription }
        }
    }
    private func clearSubmittedCapture() {
        if viewState.captureText == viewState.submittedCaptureText { viewState.captureText = "" }
        viewState.submittedCaptureText = nil
    }
    private func change(_ thread: ThreadRecord, edit: (inout ThreadRecord) -> Void) {
        var draft = viewState.value(for: thread)
        edit(&draft)
        viewState.update(draft, base: thread)
        perform { try viewState.save(thread.id, in: threads) }
    }
    private func perform(_ action: () throws -> Void) {
        viewState.errorMessage = nil
        viewState.feedback = nil
        do { try action() } catch { viewState.errorMessage = error.localizedDescription }
    }
    private func openMarkdown(_ id: UUID) {
        if !NSWorkspace.shared.open(threads.fileURL(for: id)) {
            viewState.errorMessage = "macOS could not open this Markdown file. Set a default editor for .md files in Finder."
        }
    }
    private func statusSymbol(_ status: ThreadStatus) -> String {
        switch status {
        case .active: "circle.dotted"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle"
        case .archived: "archivebox"
        }
    }
}

@MainActor
private struct ThreadDetailView: View {
    let thread: ThreadRecord
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var threads: ThreadStore
    @ObservedObject var coordinator: ThreadsCoordinator
    @ObservedObject var viewState: ThreadsViewState
    let addTask: () -> Void
    let addSubtask: (UUID) -> Void
    let editTask: (UUID) -> Void
    let openTaskHistory: (UUID) -> Void
    let linkTask: () -> Void
    let addChild: () -> Void
    @State private var confirmDiscard = false
    @State private var showContext = false
    @State private var showTasks = false
    @State private var showCompletedTasks = false
    @State private var showHistory = false
    @State private var showResources = false
    @State private var showBlockers = false
    @State private var showCheckpoint = false
    @State private var editingNext = false
    @State private var nextDraft = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var nextFocused: Bool

    private var draft: ThreadRecord { viewState.value(for: thread) }
    private var tasks: [TaskItem] { workspace.tasks.filter { $0.threadID == thread.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: MemoryStyle.sectionGap) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.title).font(MemoryStyle.title).fixedSize(horizontal: false, vertical: true)
                    Menu {
                        ForEach(ThreadStatus.allCases, id: \.self) { status in
                            Button(status.rawValue.capitalized) {
                                var changed = draft; changed.status = status
                                viewState.update(changed, base: thread)
                                perform { try viewState.save(thread.id, in: threads) }
                            }
                        }
                    } label: {
                        Text(draft.status.rawValue.capitalized).font(MemoryStyle.secondary).foregroundStyle(.secondary)
                            .frame(minHeight: 24).contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Project status: \(draft.status.rawValue)")
                }
                Spacer(minLength: 0)
                ThreadMemoryActions(thread: thread, workspace: workspace, threads: threads,
                                    coordinator: coordinator, viewState: viewState)
            }
            ProjectResumeTimeline(thread: thread, tasks: workspace.tasks,
                showHistory: { showHistory.toggle() }, openTask: openTaskHistory,
                setNext: { nextDraft = draft.nextAction; editingNext = true; nextFocused = true })
            if editingNext {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("One concrete next step", text: $nextDraft, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...4).focused($nextFocused)
                        .accessibilityLabel("Next step")
                        .task { await Task.yield(); nextFocused = true }
                    HStack {
                        Button("Cancel") { editingNext = false }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Save Next Step") {
                            var changed = draft; changed.nextAction = nextDraft
                            viewState.update(changed, base: thread)
                            perform { try viewState.save(thread.id, in: threads); editingNext = false }
                        }.keyboardShortcut("s", modifiers: .command)
                    }.controlSize(.small)
                }
            }
            HStack(spacing: 6) {
                Button { showHistory.toggle() } label: {
                    Label(showHistory ? "Hide History" : "History", systemImage: "clock.arrow.circlepath")
                        .font(MemoryStyle.body).padding(.horizontal, 8).frame(minHeight: 36).contentShape(Rectangle())
                }.buttonStyle(MemoryRowButtonStyle())
                Spacer(minLength: 0)
                Button { showCheckpoint.toggle() } label: {
                    Label("Checkpoint", systemImage: "plus")
                        .font(MemoryStyle.body).padding(.horizontal, 8).frame(minHeight: 36).contentShape(Rectangle())
                }
                .buttonStyle(MemoryRowButtonStyle())
                .disabled(threads.isReadOnly || viewState.isDirty(thread.id))
                .accessibilityLabel(showCheckpoint ? "Close checkpoint editor" : "Add checkpoint")
            }
            if showCheckpoint {
                CheckpointEditor(thread: thread, tasks: tasks, threads: threads,
                    onCancel: { showCheckpoint = false }, onSaved: {
                        showCheckpoint = false; viewState.feedback = "Checkpoint saved."
                    })
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if showHistory {
                ProjectHistoryView(thread: thread, tasks: tasks)
                    .transition(.opacity)
            }
            if !draft.blockers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MemoryDisclosure("Blockers", symbol: "exclamationmark.circle", isExpanded: $showBlockers) {
                    Text(draft.blockers).font(MemoryStyle.body).textSelection(.enabled)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                MemoryDisclosure("Tasks", symbol: "checklist", detail: "\(tasks.filter { !$0.isCompleted }.count) open", isExpanded: $showTasks) {
                    taskSection
                }
                MemoryDisclosure("Project Context", symbol: "text.alignleft", isExpanded: $showContext) {
                    projectContext
                }
                MemoryDisclosure("Resources", symbol: "link", isExpanded: $showResources) {
                    VStack(alignment: .leading, spacing: 8) {
                        if resourceLinks.isEmpty { Text("No linked resources yet.").font(MemoryStyle.secondary).foregroundStyle(.secondary) }
                        ForEach(resourceLinks, id: \.absoluteString) { url in
                            Button {
                                if !NSWorkspace.shared.open(url) { viewState.errorMessage = "Could not open this resource. Check its location or update the link." }
                            } label: {
                                Label(url.isFileURL ? url.lastPathComponent : url.absoluteString, systemImage: url.isFileURL ? "doc" : "arrow.up.right")
                                    .font(MemoryStyle.body).lineLimit(2).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(MemoryRowButtonStyle()).help(url.absoluteString)
                        }
                        contextField("Links", keyPath: \.linkedResources, placeholder: "A URL, file:/// path, or Markdown link", lines: 1...4)
                        if viewState.isDirty(thread.id) { draftActions }
                    }
                }
                Button(action: addChild) {
                    Label("Add Child Thread", systemImage: "folder.badge.plus")
                        .font(MemoryStyle.secondary).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(MemoryRowButtonStyle())
            }
            if viewState.isDirty(thread.id) && !showContext && !showResources { draftActions }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.9), value: showHistory)
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.9), value: showCheckpoint)
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.9), value: taskRows.map(\.id))
        .onExitCommand {
            if showCheckpoint { showCheckpoint = false }
            else if editingNext { editingNext = false }
            else if showHistory { showHistory = false }
            else if showContext || showTasks || showResources || showBlockers {
                showContext = false; showTasks = false; showResources = false; showBlockers = false
            } else { coordinator.selectedThreadID = nil }
        }
        .confirmationDialog("Discard this local draft and load the Markdown file?", isPresented: $confirmDiscard) {
            Button("Discard Draft and Reload", role: .destructive) {
                perform { try viewState.reloadDiscardingDraft(thread.id, in: threads) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var projectContext: some View {
        VStack(alignment: .leading, spacing: 10) {
            contextField("Project title", keyPath: \.title, placeholder: "Project name", lines: 1...2)
            contextField("Current State", keyPath: \.currentState, placeholder: "Where the work stands now")
            contextField("Next Action", keyPath: \.nextAction, placeholder: "The next concrete step")
            contextField("Blockers", keyPath: \.blockers, placeholder: "What is blocking progress?")
            contextField("Legacy Resume Point", keyPath: \.resumePoint, placeholder: "Earlier saved recovery note")
            Divider()
            contextField("Summary", keyPath: \.summary, placeholder: "A short description of this Thread")
            contextField("Notes", keyPath: \.notes, placeholder: "Notes and decisions", lines: 2...8)
            if !draft.progressHistory.isEmpty {
                contextField("Earlier Markdown Notes", keyPath: \.progressHistory,
                             placeholder: "Unstructured progress notes", lines: 2...8)
            }
            Text("Notion · Not connected").font(MemoryStyle.secondary).foregroundStyle(.secondary)
                .help("Local projects work offline. The sync adapter is prepared; connection setup is not available yet.")
            Text("Last activity: \(thread.lastActivity.formatted(date: .abbreviated, time: .shortened))")
                .font(MemoryStyle.metadata).foregroundStyle(.secondary)
            if viewState.isDirty(thread.id) { draftActions }
        }
    }

    private var draftActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Unsaved draft").font(MemoryStyle.secondary).foregroundStyle(.secondary)
                Spacer()
                Button("Reload…") { confirmDiscard = true }
                Button("Save") { perform { try viewState.save(thread.id, in: threads) } }
                    .keyboardShortcut("s", modifiers: [.command])
            }
            .controlSize(.small)
            if viewState.hasConflict(thread) || viewState.errorMessage != nil {
                Text("Your draft is retained. Reload to use the file version, or keep both versions as separate Threads.")
                    .font(MemoryStyle.secondary).foregroundStyle(.secondary)
                Button("Save Local Copy") {
                    perform { coordinator.selectedThreadID = try viewState.saveLocalCopy(thread.id, in: threads) }
                }
                .controlSize(.small)
            }
        }
    }

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Tasks").font(MemoryStyle.secondary.weight(.medium)).foregroundStyle(.secondary)
                Text("\(tasks.filter { !$0.isCompleted }.count)").font(MemoryStyle.metadata).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Add Task…", action: addTask)
                    Button("Link Existing Task…", action: linkTask)
                } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .accessibilityLabel("Add or link a task")
            }
            if taskRows.isEmpty {
                Button(tasks.isEmpty ? "Add a task…" : "All tasks complete · Add next task…", action: addTask)
                    .buttonStyle(.plain).font(MemoryStyle.secondary).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(taskRows) { row in
                VStack(alignment: .leading, spacing: 0) {
                    TaskRow(task: row.task, store: workspace,
                            addSubtask: { addSubtask(row.task.id) }, editDetails: { editTask(row.task.id) },
                            openHistory: { openTaskHistory(row.task.id) })
                    if let parentTitle = row.parentTitle, tasks.first(where: { $0.id == row.task.parentTaskID })?.isCompleted == true {
                        Text("In \(parentTitle)").font(MemoryStyle.metadata).foregroundStyle(.secondary).padding(.leading, 32)
                    }
                    if row.task.dueDate != nil || row.task.priority != nil || row.depth > 3 {
                        HStack(spacing: 8) {
                            if let due = row.task.dueDate { Text(due, format: .dateTime.day().month().year()) }
                            if let priority = row.task.priority { Text("Priority \(priority)") }
                            if row.depth > 3 { Text("Level \(row.depth + 1)") }
                        }
                        .font(MemoryStyle.metadata).foregroundStyle(.secondary).padding(.leading, 32)
                    }
                }
                .padding(.leading, CGFloat(min(row.depth, 3)) * 10)
            }
            if tasks.contains(where: \.isCompleted) {
                MemoryDisclosure("Completed", symbol: "checkmark.circle", isExpanded: $showCompletedTasks) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(ThreadOverviewProjection.orderedTasks(threadID: thread.id, tasks: tasks).filter(\.isCompleted)) { task in
                            TaskRow(task: task, store: workspace,
                                addSubtask: { addSubtask(task.id) }, editDetails: { editTask(task.id) },
                                openHistory: { openTaskHistory(task.id) })
                        }
                    }
                }
            }
        }
    }

    private var taskRows: [ThreadTaskRowProjection] {
        ThreadOverviewProjection.incompleteRows(threadID: thread.id, tasks: workspace.tasks)
    }

    private func contextField(_ title: String, keyPath: WritableKeyPath<ThreadRecord, String>, placeholder: String,
                              lines: ClosedRange<Int> = 2...5) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(MemoryStyle.secondary.weight(.medium)).foregroundStyle(.secondary)
            TextField(placeholder, text: binding(keyPath), axis: .vertical)
                .textFieldStyle(.plain).lineLimit(lines)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel(title)
        }
    }
    private func binding<Value>(_ keyPath: WritableKeyPath<ThreadRecord, Value>) -> Binding<Value> {
        Binding(get: { viewState.value(for: thread)[keyPath: keyPath] }, set: { value in
            var draft = viewState.value(for: thread)
            draft[keyPath: keyPath] = value
            viewState.update(draft, base: thread)
        })
    }
    private var resourceLinks: [URL] { MemoryResourceLinks.urls(in: draft.linkedResources) }
    private func perform(_ action: () throws -> Void) {
        viewState.errorMessage = nil
        viewState.feedback = nil
        do { try action() } catch { viewState.errorMessage = error.localizedDescription }
    }
}

@MainActor
private struct ThreadNameSheet: View {
    let title: String
    let detail: String?
    let save: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var error: String?
    @FocusState private var focused: Bool

    init(title: String, initialName: String, detail: String? = nil, save: @escaping (String) throws -> Void) {
        self.title = title; self.detail = detail; self.save = save
        _name = State(initialValue: initialName)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if let detail { Text("Parent: \(detail)").font(MemoryStyle.secondary).foregroundStyle(.secondary) }
            TextField("Thread title", text: $name).focused($focused).onSubmit(submit)
            if let error { Text(error).font(MemoryStyle.secondary).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: submit).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 320).onAppear { focused = true }
    }
    private func submit() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { try save(name); dismiss() } catch { self.error = error.localizedDescription }
    }
}

@MainActor
private struct ThreadTaskEditor: View {
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var threads: ThreadStore
    @ObservedObject var coordinator: ThreadsCoordinator
    let task: TaskItem?
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var threadID: UUID?
    @State private var parentTaskID: UUID?
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var priority: Int?
    @State private var error: String?

    init(workspace: WorkspaceStore, threads: ThreadStore, coordinator: ThreadsCoordinator,
         task: TaskItem?, threadID: UUID?, parentTaskID: UUID?) {
        self.workspace = workspace; self.threads = threads; self.coordinator = coordinator; self.task = task
        _title = State(initialValue: task?.title ?? "")
        _threadID = State(initialValue: threadID)
        _parentTaskID = State(initialValue: parentTaskID)
        _hasDueDate = State(initialValue: task?.dueDate != nil)
        _dueDate = State(initialValue: task?.dueDate ?? Date())
        _priority = State(initialValue: task?.priority == 0 ? nil : task?.priority)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(task == nil ? (parentTaskID == nil ? "New Task" : "New Subtask") : "Task Details").font(.headline)
            TextField("Task title", text: $title, axis: .vertical).lineLimit(1...3)
            Picker("Thread", selection: $threadID) {
                Text("No Thread (Inbox)").tag(Optional<UUID>.none)
                ForEach(threads.threads) { thread in
                    Text(ThreadTreeProjection.path(to: thread.id, in: threads.threads)).tag(Optional(thread.id))
                }
            }
            .onChange(of: threadID) { _, _ in parentTaskID = nil }
            Picker("Parent Task", selection: $parentTaskID) {
                Text("None").tag(Optional<UUID>.none)
                ForEach(availableParents) { task in Text(task.title).tag(Optional(task.id)) }
            }
            Toggle("Due date", isOn: $hasDueDate)
            if hasDueDate { DatePicker("Date", selection: $dueDate, displayedComponents: .date) }
            Picker("Priority", selection: $priority) {
                Text("None").tag(Optional<Int>.none)
                Text("Low (1)").tag(Optional(1))
                Text("Normal (2)").tag(Optional(2))
                Text("High (3)").tag(Optional(3))
            }
            if let error { Text(error).font(MemoryStyle.secondary).foregroundStyle(.red) }
            Text("Tasks use SidePad’s existing task store.").font(MemoryStyle.secondary).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: submit).keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 340)
    }
    private var availableParents: [TaskItem] {
        var excluded = Set<UUID>()
        if let task {
            var pending = [task.id]
            while let id = pending.popLast(), excluded.insert(id).inserted {
                pending.append(contentsOf: workspace.tasks.filter { $0.parentTaskID == id }.map(\.id))
            }
        }
        return workspace.tasks.filter { $0.threadID == threadID && !excluded.contains($0.id) }
    }
    private func submit() {
        do {
            if let threadID, !threads.threads.contains(where: { $0.id == threadID }) {
                throw TaskLinkError.invalid("The selected Thread no longer exists. Choose another Thread.")
            }
            let due = hasDueDate ? Calendar.current.startOfDay(for: dueDate) : nil
            if let task {
                guard workspace.tasks.first(where: { $0.id == task.id }) == task else {
                    throw TaskLinkError.invalid("This task changed while its details were open. Close this form and reopen it to review the latest version.")
                }
                try workspace.editTask(task.id, threadID: threadID, parentTaskID: parentTaskID,
                                       dueDate: due, priority: priority)
                workspace.updateTask(task.id, title: title)
            } else {
                _ = try coordinator.addTask(title: title, threadID: threadID, parentTaskID: parentTaskID,
                                            dueDate: due, priority: priority)
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
private struct ThreadLinkTaskSheet: View {
    @ObservedObject var workspace: WorkspaceStore
    let threadID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link Existing Task").font(.headline)
            Text("Move a task and its subtasks into this Thread.").font(MemoryStyle.secondary).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(workspace.tasks.filter { $0.threadID != threadID && $0.parentTaskID == nil }) { task in
                        Button(task.title) {
                            do { try workspace.linkTask(task.id, to: threadID, parentTaskID: nil); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                        .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                    }
                }
            }
            .frame(maxHeight: 240)
            if let error { Text(error).font(MemoryStyle.secondary).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() } }
        }
        .padding(20).frame(width: 330)
    }
}
