import Foundation

struct ThreadTaskRowProjection: Identifiable {
    let task: TaskItem
    let depth: Int
    let parentTitle: String?
    var id: UUID { task.id }
}

struct TaskJourneyStation: Identifiable, Equatable {
    enum Kind: String { case lastCompleted, nextUp, afterThat }
    let kind: Kind
    let task: TaskItem
    let completedAt: Date?
    let parentTitle: String?
    var id: String { kind.rawValue + task.id.uuidString }
}

struct ThreadActivityItem: Identifiable {
    let id: String
    let timestamp: Date
    let title: String
    let symbol: String
    let details: [String]
}

/// Read-only projections over the existing task order and saved progress records.
/// Descendant Threads are deliberately excluded from the selected Thread's scope.
enum ThreadOverviewProjection {
    static func orderedTasks(threadID: UUID, tasks: [TaskItem]) -> [TaskItem] {
        tasks.filter { $0.threadID == threadID }.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func incompleteRows(threadID: UUID, tasks: [TaskItem]) -> [ThreadTaskRowProjection] {
        let scoped = orderedTasks(threadID: threadID, tasks: tasks)
        let byID = Dictionary(uniqueKeysWithValues: scoped.map { ($0.id, $0) })
        let children = Dictionary(grouping: scoped, by: \.parentTaskID)
        var pending = scoped.filter { $0.parentTaskID == nil || byID[$0.parentTaskID!] == nil }
            .reversed().map { ($0, 0) }
        var seen = Set<UUID>()
        var result: [ThreadTaskRowProjection] = []
        while let (task, depth) = pending.popLast() {
            guard seen.insert(task.id).inserted else { continue }
            if !task.isCompleted {
                result.append(ThreadTaskRowProjection(task: task, depth: depth,
                    parentTitle: task.parentTaskID.flatMap { byID[$0]?.title }))
            }
            pending.append(contentsOf: (children[task.id] ?? []).reversed().map { ($0, depth + 1) })
        }
        return result
    }

    static func journey(thread: ThreadRecord, tasks: [TaskItem]) -> [TaskJourneyStation] {
        let scoped = orderedTasks(threadID: thread.id, tasks: tasks)
        let byID = Dictionary(uniqueKeysWithValues: scoped.map { ($0.id, $0) })
        var completionDates: [UUID: Date] = [:]
        for event in thread.progressEvents + scoped.flatMap({ $0.progressEvents ?? [] }) {
            guard let taskID = event.taskID, byID[taskID] != nil, event.taskCompleted == true,
                  (event.source == .taskChange || (event.source == .aiConfirmed && event.summary == "Task completed")) else { continue }
            completionDates[taskID] = max(completionDates[taskID] ?? .distantPast, event.timestamp)
        }
        func completionDate(_ task: TaskItem) -> Date? { completionDates[task.id] }
        let completed = scoped.filter(\.isCompleted)
        // Historical transition dates outrank legacy records. The fallback uses only
        // persisted manual order and never presents a guessed completion date.
        let latest = completed.max { left, right in
            let a = completionDate(left), b = completionDate(right)
            if a != b { return (a ?? .distantPast) < (b ?? .distantPast) }
            if left.sortOrder != right.sortOrder { return left.sortOrder < right.sortOrder }
            return left.id.uuidString < right.id.uuidString
        }
        var result: [TaskJourneyStation] = []
        if let latest {
            result.append(TaskJourneyStation(kind: .lastCompleted, task: latest,
                completedAt: completionDate(latest), parentTitle: latest.parentTaskID.flatMap { byID[$0]?.title }))
        }
        for (index, task) in scoped.filter({ !$0.isCompleted }).prefix(2).enumerated() {
            result.append(TaskJourneyStation(kind: index == 0 ? .nextUp : .afterThat,
                task: task, completedAt: nil, parentTitle: task.parentTaskID.flatMap { byID[$0]?.title }))
        }
        return result
    }

    static func recentActivity(thread: ThreadRecord, tasks: [TaskItem], limit: Int = 12) -> [ThreadActivityItem] {
        let scoped = orderedTasks(threadID: thread.id, tasks: tasks)
        var seen = Set<UUID>()
        let events = (thread.progressEvents + scoped.flatMap { $0.progressEvents ?? [] }).filter { seen.insert($0.id).inserted }
        var groups: [(key: String, events: [ProgressEvent])] = []
        var groupIndices: [String: Int] = [:]
        for event in events {
            // A confirmed batch can save both a state transition and a progress note.
            // Keep one activity row, with each distinct fact available in its details.
            let key: String
            if event.source == .aiConfirmed, let raw = event.rawInput, !raw.isEmpty {
                key = "batch-\(event.timestamp.timeIntervalSince1970)-\(raw)"
            } else { key = event.id.uuidString }
            if let index = groupIndices[key] { groups[index].events.append(event) }
            else { groupIndices[key] = groups.count; groups.append((key, [event])) }
        }
        return groups.map { group in
            let first = group.events[0]
            let representative = group.events.first { $0.taskID == nil && $0.summary != "Context updated" } ?? first
            let title = group.events.count > 1 ? representative.summary : activityTitle(first)
            var detailSeen = Set<String>()
            let details = group.events.map(activityTitle).filter { $0 != title && detailSeen.insert($0).inserted }
            return ThreadActivityItem(id: first.id.uuidString, timestamp: first.timestamp, title: title,
                symbol: symbol(representative), details: details)
        }.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
            return $0.id < $1.id
        }.prefix(max(0, limit)).map { $0 }
    }

    private static func activityTitle(_ event: ProgressEvent) -> String {
        guard let title = event.taskTitle, !title.isEmpty else { return event.summary }
        return "\(event.summary) · \(title)"
    }
    private static func symbol(_ event: ProgressEvent) -> String {
        if event.summary == "Task completed" { return "checkmark.circle" }
        if event.summary == "Task reopened" { return "arrow.uturn.backward.circle" }
        if event.summary.localizedCaseInsensitiveContains("created") { return "plus.circle" }
        if event.summary.localizedCaseInsensitiveContains("context") { return "text.alignleft" }
        if event.summary.localizedCaseInsensitiveContains("status") { return "circle.dotted" }
        return "text.bubble"
    }
}
