import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ProgressMemoryTarget: Identifiable {
    case thread(UUID), task(UUID)

    var id: String {
        switch self {
        case let .thread(id): "thread-\(id)"
        case let .task(id): "task-\(id)"
        }
    }
}

struct ProgressTimelineStation: Identifiable, Equatable {
    let id: String
    let timestamp: Date
    let event: ProgressEvent?

    var title: String { event?.summary ?? "Created" }
}

/// Events remain snapshots of what was recorded then. Creation never fabricates a prior state.
enum ProgressTimelineProjection {
    static func task(_ task: TaskItem, threads: [ThreadRecord]) -> [ProgressTimelineStation] {
        var events = task.progressEvents ?? []
        events.append(contentsOf: threads.flatMap(\.progressEvents).filter { $0.taskID == task.id })
        return stations(events: events, createdAt: task.createdAt, ownerID: task.id)
    }

    static func thread(_ thread: ThreadRecord) -> [ProgressTimelineStation] {
        stations(events: thread.progressEvents, createdAt: thread.createdAt, ownerID: thread.id)
    }

    static func page(_ stations: [ProgressTimelineStation], limit: Int) -> [ProgressTimelineStation] {
        Array(stations.suffix(max(0, limit)))
    }

    static func savedSnapshot(thread: ThreadRecord?, stations: [ProgressTimelineStation], taskID: UUID? = nil) -> ProgressSnapshot {
        if let taskID, let event = stations.last(where: {
            $0.event?.taskID == taskID && $0.event?.source != .taskChange
        })?.event { return event.snapshot }
        // Before its first progress log a task may start from the shared context. Subsequent
        // task snapshots remain separate; only a Thread log changes the shared narrative.
        return thread.map(ProgressSnapshot.init(thread:)) ?? ProgressSnapshot()
    }

    private static func stations(events: [ProgressEvent], createdAt: Date, ownerID: UUID) -> [ProgressTimelineStation] {
        var seen = Set<UUID>()
        var result = events.compactMap { event -> ProgressTimelineStation? in
            guard seen.insert(event.id).inserted else { return nil }
            return ProgressTimelineStation(id: event.id.uuidString, timestamp: event.timestamp, event: event)
        }
        result.append(ProgressTimelineStation(id: "created-\(ownerID)", timestamp: createdAt, event: nil))
        return result.enumerated().sorted {
            if $0.element.timestamp != $1.element.timestamp { return $0.element.timestamp < $1.element.timestamp }
            if ($0.element.event == nil) != ($1.element.event == nil) { return $0.element.event == nil }
            // Preserve recorded append order for operations sharing one timestamp.
            return $0.offset < $1.offset
        }.map(\.element)
    }
}

private enum ProgressPresentation: String, Identifiable {
    case context
    var id: String { rawValue }
}

@MainActor
struct ThreadMemoryActions: View {
    let thread: ThreadRecord
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var threads: ThreadStore
    @ObservedObject var coordinator: ThreadsCoordinator
    @ObservedObject var viewState: ThreadsViewState
    @State private var presentation: ProgressPresentation?

    var body: some View {
        Menu {
            Button("Preview Context") { presentation = .context }
            Button("Copy Context") {
                perform {
                    try ProgressContextExport.copy(coordinator.contextMarkdown(threadID: thread.id))
                    viewState.feedback = "Saved context copied."
                }
            }
            Button("Export Codex Handoff…") {
                perform {
                    let markdown = try coordinator.contextMarkdown(threadID: thread.id)
                    ProgressContextExport.save(markdown, title: thread.title) { result in
                        switch result {
                        case .success: viewState.feedback = "Handoff exported."
                        case let .failure(error): viewState.errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        } label: { Image(systemName: "ellipsis.circle").frame(width: 36, height: 36).contentShape(Rectangle()) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .accessibilityLabel("Project context and handoff export")
        .sheet(item: $presentation) { mode in
            ProgressMemorySheet(target: .thread(thread.id), workspace: workspace, threads: threads,
                coordinator: coordinator, viewState: viewState,
                startInContext: mode == .context)
        }
    }

    private func perform(_ action: () throws -> Void) {
        viewState.errorMessage = nil
        do { try action() } catch { viewState.errorMessage = error.localizedDescription }
    }
}

@MainActor
struct ProgressMemorySheet: View {
    let target: ProgressMemoryTarget
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var threads: ThreadStore
    @ObservedObject var coordinator: ThreadsCoordinator
    @ObservedObject var viewState: ThreadsViewState
    var startLogging = false
    var startInContext = false
    @Environment(\.dismiss) private var dismiss
    @State private var logDraft: ProgressLogDraft?
    @State private var context: String?
    @State private var error: String?
    @State private var feedback: String?
    @State private var showCurrentState = false

    private var task: TaskItem? {
        guard case let .task(id) = target else { return nil }
        return workspace.tasks.first { $0.id == id }
    }
    private var thread: ThreadRecord? {
        let id: UUID?
        switch target {
        case let .thread(value): id = value
        case .task: id = task?.threadID
        }
        return id.flatMap { id in threads.threads.first { $0.id == id } }
    }
    private var title: String { task?.title ?? thread?.title ?? "Progress Memory" }
    private var isMissing: Bool {
        switch target {
        case .task: task == nil
        case .thread: thread == nil
        }
    }
    private var hasContextDraft: Bool { thread.map { viewState.isDirty($0.id) } ?? false }
    private var canLog: Bool { !isMissing && !hasContextDraft && !workspace.isReadOnly && !threads.isReadOnly }
    private var stations: [ProgressTimelineStation] {
        if let task { return ProgressTimelineProjection.task(task, threads: threads.threads) }
        if let thread { return ProgressTimelineProjection.thread(thread) }
        return []
    }
    private var currentSnapshot: ProgressSnapshot {
        ProgressTimelineProjection.savedSnapshot(thread: thread, stations: stations, taskID: task?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let draft = logDraft {
                ProgressLogForm(draft: draft, workspace: workspace, threads: threads,
                    coordinator: coordinator, viewState: viewState,
                    onCancel: { logDraft = nil }, onSave: {
                        logDraft = nil
                        feedback = "Progress saved. Select a station to review its snapshot."
                    })
            } else {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline).lineLimit(2)
                        Text(task == nil ? "Thread progress" : "Task progress")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                HStack(spacing: 10) {
                    Button("Log Progress…", action: beginLog).disabled(!canLog)
                    Spacer(minLength: 0)
                    Menu("Context") {
                        Button("Preview Context") { perform { context = try contextMarkdown() } }
                        Button("Copy Context") {
                            perform { try ProgressContextExport.copy(contextMarkdown()); feedback = "Saved context copied." }
                        }
                        Button("Export Codex Handoff…") {
                            perform {
                                ProgressContextExport.save(try contextMarkdown(), title: title) { result in
                                    switch result {
                                    case .success: feedback = "Handoff exported."
                                    case let .failure(value): error = value.localizedDescription
                                    }
                                }
                            }
                        }
                    }
                    .disabled(isMissing)
                }
                .controlSize(.small)
                if hasContextDraft {
                    Text("Showing saved context. Save or discard the Thread draft before logging progress.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
                if isMissing {
                    Text("This item is no longer available. Close this view and reload the workspace.")
                        .foregroundStyle(.secondary)
                    Spacer()
                } else if let context {
                    HStack {
                        Text("Codex Handoff preview").font(.caption.weight(.semibold))
                        Spacer()
                        Button("Back to History") { self.context = nil }.controlSize(.small)
                    }
                    ScrollView {
                        Text(context).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    DisclosureGroup("Current saved state", isExpanded: $showCurrentState) {
                        ScrollView { ProgressSnapshotFields(snapshot: currentSnapshot).padding(.top, 6) }
                            .frame(maxHeight: 160)
                    }
                    .font(.caption)
                    if let task {
                        HStack {
                            Text(task.isCompleted ? "Task is currently complete" : "Task is currently open")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(task.isCompleted ? "Reopen Task" : "Complete Task") { workspace.toggleCompleted(task.id) }
                                .controlSize(.small).disabled(workspace.isReadOnly)
                        }
                    }
                    ProgressTimelineView(stations: stations)
                    if let thread, !thread.progressHistory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DisclosureGroup("Earlier Markdown notes (unstructured)") {
                            ScrollView {
                                Text(thread.progressHistory).font(.caption).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 100)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .padding(18).frame(width: 440, height: 620)
        .interactiveDismissDisabled(logDraft != nil)
        .onAppear {
            if case .thread = target { showCurrentState = true }
            if startLogging { beginLog() }
            if startInContext { perform { context = try contextMarkdown() } }
        }
    }

    private func beginLog() {
        guard canLog else { return }
        error = nil
        logDraft = ProgressLogDraft(thread: thread, task: task, snapshot: currentSnapshot)
    }
    private func contextMarkdown() throws -> String {
        switch target {
        case let .thread(id): try coordinator.contextMarkdown(threadID: id)
        case let .task(id): try coordinator.contextMarkdown(threadID: task?.threadID, taskID: id)
        }
    }
    private func perform(_ action: () throws -> Void) {
        error = nil; feedback = nil
        do { try action() } catch { self.error = error.localizedDescription }
    }
}

private struct ProgressLogDraft {
    let eventID = UUID()
    let thread: ThreadRecord?
    let task: TaskItem?
    var snapshot: ProgressSnapshot
    var summary = ""
}

@MainActor
private struct ProgressLogForm: View {
    @State var draft: ProgressLogDraft
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var threads: ThreadStore
    @ObservedObject var coordinator: ThreadsCoordinator
    @ObservedObject var viewState: ThreadsViewState
    let onCancel: () -> Void
    let onSave: () -> Void
    @State private var error: String?
    @State private var showSnapshot = false

    private var hasContextDraft: Bool { draft.thread.map { viewState.isDirty($0.id) } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Log Progress").font(.headline)
            Text(draft.task?.title ?? draft.thread?.title ?? "")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text("Record what happened, then confirm the state to keep for next time. This saves a new history entry.")
                .font(.caption).foregroundStyle(.secondary)
            if draft.task != nil && draft.thread != nil {
                Text("This saves a task snapshot. Use the Thread’s Log Progress action to update shared context.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    field("Progress note", text: $draft.summary, placeholder: "What changed or what did you learn?", lines: 3...7)
                    DisclosureGroup("Optional state and next steps", isExpanded: $showSnapshot) {
                        VStack(alignment: .leading, spacing: 10) {
                            field("Current State", text: $draft.snapshot.currentState, placeholder: "Where the work stands now")
                            field("Next Action", text: $draft.snapshot.nextAction, placeholder: "One concrete next step")
                            field("Blockers", text: $draft.snapshot.blockers, placeholder: "What is still blocked or uncertain?")
                            field("Resume Point", text: $draft.snapshot.resumePoint, placeholder: "Where to pick up next time")
                        }
                        .padding(.top, 8)
                    }
                    .font(.caption)
                }
            }
            if hasContextDraft {
                Text("A Thread context draft is open. Your progress note is retained; save or discard that draft first.")
                    .font(.caption).foregroundStyle(.red)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Confirm & Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(draft.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || hasContextDraft || workspace.isReadOnly || threads.isReadOnly)
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String,
                       lines: ClosedRange<Int> = 2...5) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField(placeholder, text: text, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(lines).accessibilityLabel(label)
        }
    }
    private func save() {
        guard !hasContextDraft else { return }
        do {
            try coordinator.logProgress(threadID: draft.task?.threadID ?? draft.thread?.id,
                taskID: draft.task?.id, summary: draft.summary, snapshot: draft.snapshot,
                expectedThread: draft.thread, expectedTask: draft.task, eventID: draft.eventID)
            onSave()
        } catch { self.error = error.localizedDescription }
    }
}

private struct ProgressTimelineView: View {
    let stations: [ProgressTimelineStation]
    @State private var selectedID: String?
    @State private var visibleLimit = 50
    private var visible: [ProgressTimelineStation] { ProgressTimelineProjection.page(stations, limit: visibleLimit) }
    private var selected: ProgressTimelineStation? { stations.first { $0.id == selectedID } ?? stations.last }
    private var selectionID: String? { selectedID ?? stations.last?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Timeline").font(.caption.weight(.semibold))
                Spacer()
                Text("\(visible.count) of \(stations.count) stations").font(.caption2).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if visible.count < stations.count {
                            Button("Load Earlier 50") { visibleLimit += 50 }
                                .buttonStyle(.plain).font(.caption).padding(.bottom, 10)
                        }
                        ForEach(visible) { station in
                            stationButton(station).id(station.id)
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(maxHeight: 200)
                .onAppear { if let last = stations.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: stations.last?.id) { old, new in
                    if selectedID == nil || selectedID == old { selectedID = new }
                    if let new { proxy.scrollTo(new, anchor: .bottom) }
                }
            }
            Divider()
            if let selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(selected.title).font(.callout.weight(.semibold)).textSelection(.enabled)
                        Text(ProgressTimestamp.format(selected.timestamp))
                            .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        if let event = selected.event {
                            Text("Source: \(sourceLabel(event.source))").font(.caption).foregroundStyle(.secondary)
                            if let title = event.taskTitle {
                                Text("Task then: \(title)").font(.caption).textSelection(.enabled)
                            }
                            if let completed = event.taskCompleted {
                                Text(completed ? "Task was complete" : "Task was open").font(.caption).foregroundStyle(.secondary)
                            }
                            if let raw = event.rawInput, !raw.isEmpty {
                                evidence("Original input", text: raw)
                            }
                            ProgressSnapshotFields(snapshot: event.snapshot)
                        } else {
                            Text("Creation time from the saved record. Earlier titles and progress were not recorded.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear { if selectedID == nil { selectedID = stations.last?.id } }
    }

    private func stationButton(_ station: ProgressTimelineStation) -> some View {
        Button { selectedID = station.id } label: {
            HStack(alignment: .top, spacing: 9) {
                ZStack(alignment: .top) {
                    Rectangle().fill(Color.secondary.opacity(0.28)).frame(width: 2)
                    Circle().fill(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 11, height: 11).padding(.top, 7)
                    Circle().stroke(selectionID == station.id ? Color.accentColor : .secondary, lineWidth: 2)
                        .frame(width: 11, height: 11).padding(.top, 7)
                    if selectionID == station.id {
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5).padding(.top, 10)
                    }
                }
                .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(station.timestamp.formatted(date: .abbreviated, time: .standard))
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(station.title).font(.caption).lineLimit(2)
                }
                .padding(.vertical, 6)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(selectionID == station.id ? Color.accentColor.opacity(0.09) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(station.timestamp.formatted(date: .complete, time: .complete)): \(station.title)")
        .accessibilityAddTraits(selectionID == station.id ? .isSelected : [])
    }
    private func evidence(_ label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.caption).textSelection(.enabled)
        }
    }
    private func sourceLabel(_ source: ProgressEventSource) -> String {
        switch source {
        case .manual: "Manual, confirmed"
        case .aiConfirmed: "AI proposal, confirmed"
        case .taskChange: "Task change"
        }
    }
}

private struct ProgressSnapshotFields: View {
    let snapshot: ProgressSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Current State", snapshot.currentState)
            field("Next Action", snapshot.nextAction)
            field("Blockers", snapshot.blockers)
            field("Resume Point", snapshot.resumePoint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func field(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text.isEmpty ? "Not recorded" : text).font(.caption).textSelection(.enabled)
        }
    }
}

@MainActor
private enum ProgressContextExport {
    static func copy(_ markdown: String) throws {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(markdown, forType: .string) else {
            throw TaskLinkError.invalid("macOS could not copy the context. Try exporting it to a Markdown file.")
        }
    }

    static func save(_ markdown: String, title: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let panel = NSSavePanel()
        panel.title = "Export Codex Handoff"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        let name = String(title.prefix(80)).components(separatedBy: CharacterSet(charactersIn: "/:\n\r")).joined(separator: "-")
        panel.nameFieldStringValue = "\(name.isEmpty ? "SidePad" : name)-handoff.md"
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try markdown.write(to: url, atomically: true, encoding: .utf8); completion(.success(())) }
            catch { completion(.failure(error)) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }
}
