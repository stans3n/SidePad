import Foundation
import Combine

/// UI preferences, scoped to this Markdown library. Opening a project never changes pins.
@MainActor
final class ProjectPinsStore: ObservableObject {
    @Published private(set) var ids: [UUID]
    private let defaults: UserDefaults
    private let key: String
    private var initialized: Bool

    init(library: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "SidePad.projectPins.v1." + library.standardizedFileURL.path
        initialized = defaults.object(forKey: key) != nil
        var seen = Set<UUID>()
        ids = Array((defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:))
            .filter { seen.insert($0).inserted }.prefix(2))
    }

    func seedIfNeeded(from threads: [ThreadRecord]) {
        guard !initialized, !threads.isEmpty else { return }
        // A one-time starting selection. Later additions/activity never displace explicit choices.
        ids = Array(threads.filter { $0.parentID == nil && $0.status != .archived }.prefix(2).map(\.id))
        persist()
    }
    func reconcile(with threads: [ThreadRecord]) {
        let available = Set(threads.map(\.id))
        let remaining = ids.filter(available.contains)
        if remaining != ids { ids = remaining; persist() }
    }
    func contains(_ id: UUID) -> Bool { ids.contains(id) }
    func projects(in threads: [ThreadRecord]) -> [ThreadRecord] {
        ids.compactMap { id in threads.first { $0.id == id } }
    }
    func pin(_ id: UUID) {
        guard ids.count < 2, !ids.contains(id) else { return }
        ids.append(id); persist()
    }
    func unpin(_ id: UUID) { ids.removeAll { $0 == id }; persist() }
    func moveFirst(_ id: UUID) {
        guard ids.contains(id) else { return }; ids.removeAll { $0 == id }; ids.insert(id, at: 0); persist()
    }
    func moveLast(_ id: UUID) {
        guard ids.contains(id) else { return }; ids.removeAll { $0 == id }; ids.append(id); persist()
    }
    private func persist() { initialized = true; defaults.set(ids.map(\.uuidString), forKey: key) }
}

struct ProjectResumeStep: Equatable {
    let text: String
    var taskID: UUID? = nil
    var timestamp: Date? = nil
    var isMissing = false
}

enum ProjectResumeProjection {
    static func next(thread: ThreadRecord, tasks: [TaskItem]) -> ProjectResumeStep {
        if !thread.nextAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ProjectResumeStep(text: thread.nextAction)
        }
        if let task = ThreadOverviewProjection.orderedTasks(threadID: thread.id, tasks: tasks).first(where: { !$0.isCompleted }) {
            return ProjectResumeStep(text: task.title, taskID: task.id)
        }
        return ProjectResumeStep(text: "Set next step", isMissing: true)
    }

    static func previous(thread: ThreadRecord, tasks: [TaskItem]) -> ProjectResumeStep? {
        let scoped = tasks.filter { $0.threadID == thread.id }
        let events = thread.progressEvents + scoped.flatMap { $0.progressEvents ?? [] }
        var candidates: [ProjectResumeStep] = thread.checkpoints.map {
            ProjectResumeStep(text: $0.note, timestamp: $0.createdAt)
        }
        var seen = Set<UUID>()
        for event in events where seen.insert(event.id).inserted {
            let completed = event.taskCompleted == true && event.summary == "Task completed"
            let explicitNote = event.source != .taskChange && !["Context updated", "Task completed", "Task reopened"].contains(event.summary)
                && !event.summary.hasPrefix("Thread status changed") && !event.summary.hasPrefix("Thread created")
                && !event.summary.hasPrefix("Task created")
            guard completed || explicitNote else { continue }
            candidates.append(ProjectResumeStep(text: completed ? (event.taskTitle ?? event.summary) : event.summary,
                taskID: event.taskID, timestamp: event.timestamp))
        }
        return candidates.max { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
    }
}

/// Only explicitly supported URL schemes are opened; plain paths become file URLs.
enum MemoryResourceLinks {
    static func urls(in text: String) -> [URL] {
        let pattern = #"\]\(([^\n]+?)\)|((?:https?://|file:///|codex://)[^\s<>]+)"#
        let expression = try? NSRegularExpression(pattern: pattern)
        var values: [URL] = []
        for match in expression?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
            let range = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
            guard let swiftRange = Range(range, in: text), let url = URL(string: String(text[swiftRange])),
                  ["http", "https", "file", "codex"].contains(url.scheme?.lowercased() ?? "") else { continue }
            values.append(url)
        }
        for line in text.split(separator: "\n") {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("/") { values.append(URL(fileURLWithPath: value)) }
            else if value.hasPrefix("~/") { values.append(URL(fileURLWithPath: (value as NSString).expandingTildeInPath)) }
        }
        var seen = Set<URL>()
        return values.filter { seen.insert($0).inserted }
    }
}
