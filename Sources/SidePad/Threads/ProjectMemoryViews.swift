import AppKit
import SwiftUI

/// macOS hierarchy: system title, 13-point body/heading, and subordinate native labels.
/// Spacing is an app convention; Apple HIG does not mandate a universal 8-point grid.
enum MemoryStyle {
    static let title = Font.title2.weight(.semibold)
    static let heading = Font.headline
    static let body = Font.body
    static let secondary = Font.callout
    static let metadata = Font.caption
    static let gutter: CGFloat = 16
    static let rowInset: CGFloat = 8
    static let sectionGap: CGFloat = 16
    static let controlHeight: CGFloat = 36
}

/// A single quiet interaction treatment for project, history, and disclosure rows.
struct MemoryRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MemoryRowBody(configuration: configuration)
    }
    private struct MemoryRowBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.1 : (hovered ? 0.045 : 0)),
                            in: RoundedRectangle(cornerRadius: 9))
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovered)
        }
    }
}

struct MemoryDisclosure<Content: View>: View {
    let title: String
    let symbol: String
    var detail: String?
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, symbol: String, detail: String? = nil, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.symbol = symbol; self.detail = detail
        _isExpanded = isExpanded; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol).frame(width: 18)
                    Text(title)
                    Spacer(minLength: 2)
                    if let detail { Text(detail).font(MemoryStyle.metadata) }
                    Image(systemName: "chevron.right").font(MemoryStyle.metadata.weight(.medium))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(MemoryStyle.secondary).foregroundStyle(.secondary).padding(.horizontal, MemoryStyle.rowInset)
                .frame(maxWidth: .infinity, minHeight: 36).contentShape(Rectangle())
            }
            .buttonStyle(MemoryRowButtonStyle())
            .accessibilityLabel(title).accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                content().padding(.top, 4).padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.9), value: isExpanded)
    }
}

struct ProjectResumeTimeline: View {
    let thread: ThreadRecord
    let tasks: [TaskItem]
    let showHistory: () -> Void
    let openTask: (UUID) -> Void
    let setNext: () -> Void
    private var previous: ProjectResumeStep? { ProjectResumeProjection.previous(thread: thread, tasks: tasks) }
    private var next: ProjectResumeStep { ProjectResumeProjection.next(thread: thread, tasks: tasks) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let previous {
                station(title: "Previous", text: previous.text, completed: true, connected: true, date: previous.timestamp) {
                    showHistory()
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "circle.dashed").font(.system(size: 13)).foregroundStyle(.tertiary).frame(width: 18, height: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Previous").font(MemoryStyle.secondary).foregroundStyle(.secondary)
                        Text("No checkpoint or completed step recorded.").font(MemoryStyle.body).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, MemoryStyle.rowInset).padding(.vertical, 8)
            }
            station(title: "Next Step", text: next.text, completed: false, connected: false, date: nil) {
                if let taskID = next.taskID { openTask(taskID) } else { setNext() }
            }
        }
    }

    private func station(title: String, text: String, completed: Bool, connected: Bool, date: Date?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 4) {
                    Image(systemName: completed ? "circle.fill" : "circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(completed ? Color.secondary : Color.accentColor)
                        .frame(width: 18, height: 20)
                    if connected { Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1).frame(minHeight: 24) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title).font(MemoryStyle.secondary.weight(.medium)).foregroundStyle(.secondary)
                        Spacer(minLength: 2)
                        if let date { Text(date, format: .dateTime.month(.abbreviated).day()).font(MemoryStyle.metadata).foregroundStyle(.tertiary) }
                    }
                    Text(text).font(MemoryStyle.body.weight(completed ? .regular : .medium))
                        .foregroundStyle(completed ? .secondary : .primary)
                        .lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.bottom, connected ? 12 : 4)
            }
            .padding(.horizontal, MemoryStyle.rowInset).padding(.top, 4).padding(.bottom, 4)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(MemoryRowButtonStyle()).help(text)
        .accessibilityLabel("\(title): \(text)")
    }
}

struct ProjectHistoryEntry: Identifiable {
    let id: String
    let timestamp: Date
    let title: String
    let kind: String
    let symbol: String
    let event: ProgressEvent?
    let checkpoint: ThreadCheckpoint?
}

enum ProjectHistoryProjection {
    static func entries(thread: ThreadRecord, tasks: [TaskItem]) -> [ProjectHistoryEntry] {
        var seen = Set<UUID>()
        let events = (thread.progressEvents + tasks.filter { $0.threadID == thread.id }.flatMap { $0.progressEvents ?? [] })
            .filter { seen.insert($0.id).inserted }
        var entries = events.map { event in
            let completion = event.taskCompleted == true && event.summary == "Task completed"
            return ProjectHistoryEntry(id: "event-\(event.id)", timestamp: event.timestamp,
                title: event.taskTitle.map { "\(event.summary) · \($0)" } ?? event.summary,
                kind: completion ? "Task completed" : (event.taskID != nil ? "Task activity" : "Project update"),
                symbol: completion ? "checkmark.circle.fill" : "text.bubble", event: event, checkpoint: nil)
        }
        entries += thread.checkpoints.map { checkpoint in
            ProjectHistoryEntry(id: "checkpoint-\(checkpoint.id)", timestamp: checkpoint.createdAt,
                title: checkpoint.note, kind: "Checkpoint", symbol: "bookmark.fill", event: nil, checkpoint: checkpoint)
        }
        entries.append(ProjectHistoryEntry(id: "created-\(thread.id)", timestamp: thread.createdAt,
            title: "Project created", kind: "Created", symbol: "plus.circle", event: nil, checkpoint: nil))
        return entries.enumerated().sorted {
            if $0.element.timestamp != $1.element.timestamp { return $0.element.timestamp > $1.element.timestamp }
            return $0.offset > $1.offset
        }.map(\.element)
    }
}

struct ProjectHistoryView: View {
    let thread: ThreadRecord
    let tasks: [TaskItem]
    @State private var selectedID: String?
    @State private var limit = 50
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var entries: [ProjectHistoryEntry] { ProjectHistoryProjection.entries(thread: thread, tasks: tasks) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("History").font(MemoryStyle.heading)
                Spacer()
                Text("\(entries.count) entries").font(MemoryStyle.metadata).foregroundStyle(.secondary)
            }.padding(.bottom, 4)
            ForEach(Array(entries.prefix(limit))) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    Button { selectedID = selectedID == entry.id ? nil : entry.id } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: entry.symbol).font(MemoryStyle.secondary).foregroundStyle(.secondary).frame(width: 18).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.title).font(MemoryStyle.body).lineLimit(selectedID == entry.id ? nil : 2)
                                Text("\(entry.kind) · \(entry.timestamp.formatted(date: .abbreviated, time: .shortened))")
                                    .font(MemoryStyle.metadata).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(MemoryStyle.metadata).foregroundStyle(.secondary)
                                .rotationEffect(.degrees(selectedID == entry.id ? 90 : 0)).padding(.top, 5)
                        }
                        .padding(8).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(MemoryRowButtonStyle())
                        .accessibilityValue(selectedID == entry.id ? "Expanded" : "Collapsed")
                    if selectedID == entry.id { evidence(entry).padding(.leading, 34).padding(.bottom, 12).transition(.opacity) }
                }
            }
            if entries.count > limit {
                Button("Load Earlier 50") { limit += 50 }
                    .frame(maxWidth: .infinity, minHeight: 36).buttonStyle(.borderless)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.9), value: selectedID)
    }

    @ViewBuilder private func evidence(_ entry: ProjectHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ProgressTimestamp.format(entry.timestamp)).font(MemoryStyle.metadata).foregroundStyle(.secondary).textSelection(.enabled)
            if let checkpoint = entry.checkpoint {
                Text("Saved checkpoint · \(checkpoint.origin.rawValue)").font(MemoryStyle.secondary).foregroundStyle(.secondary)
                if let snapshot = checkpoint.snapshot { MemorySnapshotView(snapshot: snapshot) }
                if !checkpoint.relatedTaskIDs.isEmpty {
                    Text("Related tasks: \(checkpoint.relatedTaskIDs.map(\.uuidString).joined(separator: ", "))")
                        .font(MemoryStyle.metadata).foregroundStyle(.secondary).textSelection(.enabled)
                }
                ForEach(MemoryResourceLinks.urls(in: checkpoint.resources.joined(separator: "\n")), id: \.absoluteString) { url in
                    Link(url.isFileURL ? url.lastPathComponent : url.absoluteString, destination: url)
                        .font(MemoryStyle.secondary).lineLimit(2)
                }
            } else if let event = entry.event {
                Text("Recorded activity · \(event.source.rawValue)").font(MemoryStyle.secondary).foregroundStyle(.secondary)
                if let completed = event.taskCompleted {
                    Text(completed ? "Task was complete" : "Task was open").font(MemoryStyle.secondary).foregroundStyle(.secondary)
                }
                MemorySnapshotView(snapshot: event.snapshot)
                if let raw = event.rawInput, !raw.isEmpty {
                    Text("Original input").font(MemoryStyle.secondary.weight(.medium))
                    Text(raw).font(MemoryStyle.secondary).textSelection(.enabled)
                }
            } else {
                Text("Creation time from the saved record. No earlier state was recorded.").font(MemoryStyle.secondary).foregroundStyle(.secondary)
            }
        }
    }
}

struct MemorySnapshotView: View {
    let snapshot: ProgressSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Current State", snapshot.currentState)
            field("Next Step", snapshot.nextAction)
            field("Blockers", snapshot.blockers)
            field("Legacy Resume Point", snapshot.resumePoint)
            if [snapshot.currentState, snapshot.nextAction, snapshot.blockers, snapshot.resumePoint].allSatisfy(\.isEmpty) {
                Text("No state fields were recorded for this entry.").font(MemoryStyle.secondary).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private func field(_ title: String, _ value: String) -> some View {
        if !value.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(MemoryStyle.secondary.weight(.medium)).foregroundStyle(.secondary)
                Text(value).font(MemoryStyle.secondary).textSelection(.enabled)
            }
        }
    }
}

@MainActor
struct CheckpointEditor: View {
    let thread: ThreadRecord
    let tasks: [TaskItem]
    @ObservedObject var threads: ThreadStore
    let onCancel: () -> Void
    let onSaved: () -> Void
    @State private var expectedThread: ThreadRecord
    @State private var note = ""
    @State private var nextAction: String
    @State private var currentState: String
    @State private var blockers: String
    @State private var resources = ""
    @State private var relatedTaskIDs = Set<UUID>()
    @State private var showDetails = false
    @State private var error: String?
    @State private var checkpointID = UUID()
    @FocusState private var focused: Bool

    init(thread: ThreadRecord, tasks: [TaskItem], threads: ThreadStore, onCancel: @escaping () -> Void, onSaved: @escaping () -> Void) {
        self.thread = thread; self.tasks = tasks; self.threads = threads
        self.onCancel = onCancel; self.onSaved = onSaved
        _expectedThread = State(initialValue: thread)
        _nextAction = State(initialValue: thread.nextAction)
        _currentState = State(initialValue: thread.currentState)
        _blockers = State(initialValue: thread.blockers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where did you stop?").font(MemoryStyle.heading)
            TextField("A short note for next time…", text: $note, axis: .vertical)
                .font(MemoryStyle.body).textFieldStyle(.roundedBorder).lineLimit(2...5).focused($focused)
                .accessibilityLabel("Checkpoint note")
            MemoryDisclosure("More details", symbol: "slider.horizontal.3", isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 10) {
                    field("Next Step", text: $nextAction)
                    field("Current State", text: $currentState)
                    field("Blockers", text: $blockers)
                    field("Resources", text: $resources)
                    if !tasks.isEmpty {
                        Text("Related tasks").font(MemoryStyle.secondary.weight(.medium)).foregroundStyle(.secondary)
                        ForEach(tasks) { task in
                            Toggle(task.title, isOn: Binding(get: { relatedTaskIDs.contains(task.id) }, set: {
                                if $0 { relatedTaskIDs.insert(task.id) } else { relatedTaskIDs.remove(task.id) }
                            })).font(MemoryStyle.secondary).toggleStyle(.checkbox)
                        }
                    }
                }
            }
            if let error { Text(error).font(MemoryStyle.secondary).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Checkpoint", action: save).keyboardShortcut(.return, modifiers: .command)
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || threads.isReadOnly)
            }.controlSize(.small)
        }
        .padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .task {
            // Focus after SwiftUI has mounted the newly inserted native field.
            await Task.yield()
            focused = true
        }
    }
    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(MemoryStyle.secondary.weight(.medium)).foregroundStyle(.secondary)
            TextField(label, text: text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4).accessibilityLabel(label)
        }
    }
    private func save() {
        do {
            _ = try threads.addCheckpoint(threadID: thread.id, note: note,
                nextAction: nextAction == expectedThread.nextAction ? nil : nextAction,
                currentState: currentState == expectedThread.currentState ? nil : currentState,
                blockers: blockers == expectedThread.blockers ? nil : blockers,
                resources: resources.split(separator: "\n").map(String.init),
                relatedTaskIDs: relatedTaskIDs.sorted { $0.uuidString < $1.uuidString },
                expectedThread: expectedThread, checkpointID: checkpointID)
            onSaved()
        } catch { self.error = error.localizedDescription }
    }
}
