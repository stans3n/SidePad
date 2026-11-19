import Foundation
import Testing
@testable import SidePad

struct ThreadOverviewTests {
    @Test func journeyIsDirectlyScopedAndUsesManualOrder() {
        let thread = ThreadRecord(title: "Project")
        let child = ThreadRecord(title: "Child", parentID: thread.id)
        let first = TaskItem(title: "First", sortOrder: 4, threadID: thread.id)
        let second = TaskItem(title: "Second", sortOrder: 8, threadID: thread.id)
        let third = TaskItem(title: "Third", sortOrder: 12, threadID: thread.id)
        let descendant = TaskItem(title: "Other scope", sortOrder: 0, threadID: child.id)
        let unrelated = TaskItem(title: "Inbox", sortOrder: 1)
        let tasks = [third, descendant, second, unrelated, first]
        let stations = ThreadOverviewProjection.journey(thread: thread, tasks: tasks)
        #expect(stations.map(\.task.id) == [first.id, second.id])
        #expect(stations.map(\.kind) == [.nextUp, .afterThat])
        #expect(stations.allSatisfy { $0.completedAt == nil })
        #expect(tasks.allSatisfy { !$0.isCompleted })
        #expect(ThreadOverviewProjection.journey(thread: child, tasks: tasks).map(\.task.id) == [descendant.id])
    }

    @Test func completionAndReopenImmediatelyRecomputeStations() {
        let thread = ThreadRecord(title: "Project")
        var first = TaskItem(title: "Integrate API", sortOrder: 0, threadID: thread.id)
        let second = TaskItem(title: "Test parsing", sortOrder: 1, threadID: thread.id)
        let timestamp = Date(timeIntervalSince1970: 1_000)
        first.isCompleted = true
        first.progressEvents = [ProgressEvent(timestamp: timestamp, summary: "Task completed", source: .taskChange,
            taskID: first.id, taskTitle: first.title, taskCompleted: true)]
        let completed = ThreadOverviewProjection.journey(thread: thread, tasks: [first, second])
        #expect(completed.map(\.kind) == [.lastCompleted, .nextUp])
        #expect(completed.first?.completedAt == timestamp)
        #expect(ThreadOverviewProjection.incompleteRows(threadID: thread.id, tasks: [first, second]).map(\.id) == [second.id])
        first.isCompleted = false
        first.progressEvents?.append(ProgressEvent(timestamp: timestamp.addingTimeInterval(10), summary: "Task reopened",
            source: .taskChange, taskID: first.id, taskCompleted: false))
        #expect(ThreadOverviewProjection.journey(thread: thread, tasks: [first, second]).map(\.kind) == [.nextUp, .afterThat])
    }

    @Test func latestCompletionUsesTransitionNotLaterProgressSnapshot() {
        var thread = ThreadRecord(title: "Project")
        var earlier = TaskItem(title: "Earlier", isCompleted: true, sortOrder: 20, threadID: thread.id)
        var later = TaskItem(title: "Later", isCompleted: true, sortOrder: 0, threadID: thread.id)
        earlier.progressEvents = [ProgressEvent(timestamp: Date(timeIntervalSince1970: 1_000), summary: "Task completed",
            source: .taskChange, taskID: earlier.id, taskCompleted: true)]
        later.progressEvents = [ProgressEvent(timestamp: Date(timeIntervalSince1970: 2_000), summary: "Task completed",
            source: .aiConfirmed, taskID: later.id, taskCompleted: true)]
        thread.progressEvents = [ProgressEvent(timestamp: Date(timeIntervalSince1970: 3_000), summary: "Reviewed old result",
            source: .manual, taskID: earlier.id, taskCompleted: true)]
        let stations = ThreadOverviewProjection.journey(thread: thread, tasks: [earlier, later])
        #expect(stations.count == 1)
        #expect(stations.first?.task.id == later.id)
        #expect(stations.first?.completedAt == Date(timeIntervalSince1970: 2_000))
    }

    @Test func legacyFallbackAndEmptyCountsDoNotInventDatesOrStations() {
        let thread = ThreadRecord(title: "Legacy")
        let one = TaskItem(title: "One", isCompleted: true, sortOrder: 1, threadID: thread.id)
        let two = TaskItem(title: "Two", isCompleted: true, sortOrder: 2, threadID: thread.id)
        #expect(ThreadOverviewProjection.journey(thread: thread, tasks: []).isEmpty)
        let completed = ThreadOverviewProjection.journey(thread: thread, tasks: [two, one])
        #expect(completed.count == 1)
        #expect(completed.first?.task.id == two.id)
        #expect(completed.first?.completedAt == nil)
        var open = one; open.isCompleted = false
        #expect(ThreadOverviewProjection.journey(thread: thread, tasks: [open]).map(\.kind) == [.nextUp])
        #expect(ThreadOverviewProjection.journey(thread: thread, tasks: [open, two]).map(\.kind) == [.lastCompleted, .nextUp])
    }

    @Test func incompleteSubtasksSurviveCompletedParentWithoutRepeatingParent() {
        let thread = ThreadRecord(title: "Project")
        let parent = TaskItem(title: "Parent", isCompleted: true, sortOrder: 0, threadID: thread.id)
        let child = TaskItem(title: "Child", sortOrder: 1, threadID: thread.id, parentTaskID: parent.id)
        let next = TaskItem(title: "Next", sortOrder: 2, threadID: thread.id)
        let rows = ThreadOverviewProjection.incompleteRows(threadID: thread.id, tasks: [parent, child, next])
        #expect(rows.map(\.id) == [child.id, next.id])
        #expect(rows.first?.depth == 1)
        #expect(rows.first?.parentTitle == parent.title)
        let journey = ThreadOverviewProjection.journey(thread: thread, tasks: [parent, child, next])
        #expect(journey.map(\.task.id) == [parent.id, child.id, next.id])
        #expect(Set(journey.map(\.task.id)).count == journey.count)
    }

    @Test func mixedOpenParentsAndChildrenKeepDistinctIDsAndGlobalManualJourneyOrder() {
        let thread = ThreadRecord(title: "Project")
        let parent = TaskItem(title: "Parent", sortOrder: 0, threadID: thread.id)
        let sibling = TaskItem(title: "Independent", sortOrder: 1, threadID: thread.id)
        let child = TaskItem(title: "Child", sortOrder: 2, threadID: thread.id, parentTaskID: parent.id)
        let tasks = [child, sibling, parent]
        let rows = ThreadOverviewProjection.incompleteRows(threadID: thread.id, tasks: tasks)
        #expect(rows.map(\.id) == [parent.id, child.id, sibling.id])
        #expect(Set(rows.map(\.id)).count == 3)
        let journey = ThreadOverviewProjection.journey(thread: thread, tasks: tasks)
        #expect(journey.map(\.task.id) == [parent.id, sibling.id])
        #expect(journey.map(\.kind) == [.nextUp, .afterThat])
    }

    @Test func recentActivityDeduplicatesCopiesAndGroupsConfirmedBatchFacts() {
        var thread = ThreadRecord(title: "Project")
        var task = TaskItem(title: "API", isCompleted: true, sortOrder: 0, threadID: thread.id)
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let complete = ProgressEvent(timestamp: timestamp, summary: "Task completed", source: .aiConfirmed,
            taskID: task.id, taskTitle: task.title, taskCompleted: true, rawInput: "Finished API; test next")
        let progress = ProgressEvent(timestamp: timestamp, summary: "API integrated; parsing needs testing",
            source: .aiConfirmed, rawInput: "Finished API; test next")
        let manual = ProgressEvent(timestamp: timestamp.addingTimeInterval(20), summary: "Context updated", source: .manual)
        task.progressEvents = [complete]
        thread.progressEvents = [complete, progress, manual]
        let activity = ThreadOverviewProjection.recentActivity(thread: thread, tasks: [task])
        #expect(activity.count == 2)
        #expect(activity.first?.title == "Context updated")
        #expect(activity.last?.title == progress.summary)
        #expect(activity.last?.details == ["Task completed · API"])
        #expect(ThreadOverviewProjection.recentActivity(thread: thread, tasks: [task], limit: 1).count == 1)
        #expect(ThreadOverviewProjection.recentActivity(thread: thread, tasks: [task], limit: 0).isEmpty)
    }
}
