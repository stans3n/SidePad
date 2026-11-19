import Foundation
import Testing
@testable import SidePad

@Suite(.serialized)
struct ProgressTimelineTests {
    @Test func taskTimelineRetainsHistoryAcrossThreadMovesAndDeduplicatesCopies() throws {
        var task = TaskItem(title: "Current title", sortOrder: 0)
        task.createdAt = Date(timeIntervalSince1970: 1_000)
        let original = ProgressEvent(timestamp: Date(timeIntervalSince1970: 1_010), summary: "First experiment",
            source: .manual, taskID: task.id, taskTitle: "Original title", taskCompleted: false,
            snapshot: ProgressSnapshot(currentState: "Baseline measured", nextAction: "Check the boundary"),
            rawInput: "Baseline done; boundary result is still uncertain.")
        let latest = ProgressEvent(timestamp: Date(timeIntervalSince1970: 1_030), summary: "Review completed",
            source: .aiConfirmed, taskID: task.id, taskTitle: task.title, taskCompleted: false,
            snapshot: ProgressSnapshot(currentState: "Reviewed", nextAction: "Write the report"))
        let unrelated = ProgressEvent(summary: "Someone else's work", taskID: UUID())
        let oldThread = ThreadRecord(title: "Old project", progressEvents: [original, unrelated])
        let newThread = ThreadRecord(title: "New project", currentState: "A later project state", progressEvents: [latest])
        task.threadID = newThread.id
        task.progressEvents = [original]
        let stations = ProgressTimelineProjection.task(task, threads: [newThread, oldThread])
        #expect(stations.count == 3)
        #expect(stations.map(\.timestamp) == [task.createdAt, original.timestamp, latest.timestamp])
        let firstEvent = try #require(stations[1].event)
        #expect(firstEvent.taskTitle == "Original title")
        #expect(firstEvent.snapshot.currentState == "Baseline measured")
        #expect(firstEvent.snapshot.nextAction == "Check the boundary")
        #expect(firstEvent.rawInput == original.rawInput)
        #expect(firstEvent.source == .manual)
        #expect(stations[2].event?.source == .aiConfirmed)
    }

    @Test func legacyTaskCreationDoesNotInventHistoricalStateOrTitle() {
        var task = TaskItem(title: "Renamed before tracking", sortOrder: 0)
        task.createdAt = Date(timeIntervalSince1970: 1_000)
        let stations = ProgressTimelineProjection.task(task, threads: [])
        #expect(stations.count == 1)
        #expect(stations[0].timestamp == task.createdAt)
        #expect(stations[0].title == "Created")
        #expect(stations[0].event == nil)
        #expect(ProgressTimelineProjection.page(stations, limit: 0).isEmpty)
    }

    @Test func tasksSharingThreadKeepTheirOwnSnapshotsAndCompletionRetainsLastProgress() {
        var task = TaskItem(title: "Check result", sortOrder: 0)
        task.createdAt = Date(timeIntervalSince1970: 1_000)
        let historical = ProgressEvent(timestamp: Date(timeIntervalSince1970: 1_010), summary: "Initial result",
            taskID: task.id, snapshot: ProgressSnapshot(currentState: "Old result", nextAction: "Verify"))
        let completion = ProgressEvent(timestamp: Date(timeIntervalSince1970: 1_020), summary: "Completed",
            source: .taskChange, taskID: task.id, taskTitle: task.title, taskCompleted: true)
        let thread = ThreadRecord(title: "Research", currentState: "Revised result", nextAction: "Publish",
                                  progressEvents: [historical])
        task.threadID = thread.id
        task.progressEvents = [completion]
        let linked = ProgressTimelineProjection.task(task, threads: [thread])
        #expect(ProgressTimelineProjection.savedSnapshot(thread: thread, stations: linked, taskID: task.id) == historical.snapshot)
        #expect(linked.first { $0.event?.id == historical.id }?.event?.snapshot.currentState == "Old result")

        var another = TaskItem(title: "Write report", sortOrder: 1)
        another.threadID = thread.id
        let anotherHistory = ProgressTimelineProjection.task(another, threads: [thread])
        #expect(ProgressTimelineProjection.savedSnapshot(thread: thread, stations: anotherHistory, taskID: another.id) == ProgressSnapshot(thread: thread))
        let ownProgress = ProgressEvent(summary: "Drafted report", taskID: another.id,
            snapshot: ProgressSnapshot(currentState: "Draft complete", nextAction: "Proofread"))
        another.progressEvents = [ownProgress]
        let recorded = ProgressTimelineProjection.task(another, threads: [thread])
        #expect(ProgressTimelineProjection.savedSnapshot(thread: thread, stations: recorded, taskID: another.id) == ownProgress.snapshot)
        #expect(ProgressTimelineProjection.savedSnapshot(thread: thread, stations: ProgressTimelineProjection.thread(thread)) == ProgressSnapshot(thread: thread))

        task.threadID = nil
        task.progressEvents = [historical, completion]
        let standalone = ProgressTimelineProjection.task(task, threads: [])
        #expect(ProgressTimelineProjection.savedSnapshot(thread: nil, stations: standalone, taskID: task.id) == historical.snapshot)
    }

    @Test func sameTimeEventsHaveStableIdentityAndPaginationKeepsChronologicalOrder() {
        let date = Date(timeIntervalSince1970: 2_000)
        let first = ProgressEvent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                  timestamp: date, summary: "A")
        let second = ProgressEvent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                                   timestamp: date, summary: "B")
        let thread = ThreadRecord(title: "Equal clocks", createdAt: date, progressEvents: [second, first])
        let stations = ProgressTimelineProjection.thread(thread)
        #expect(stations.first?.event == nil)
        #expect(stations.dropFirst().compactMap(\.event).map(\.id) == [second.id, first.id])
        #expect(ProgressTimelineProjection.page(stations, limit: 1).first?.event?.id == first.id)
        #expect(ProgressTimelineProjection.page(stations, limit: 10) == stations)
    }

    @Test func tenThousandEventHistoryProjectsAndPagesWithinInteractiveBudget() {
        let created = Date(timeIntervalSince1970: 1_000)
        let events = (1...10_000).map { index in
            ProgressEvent(timestamp: created.addingTimeInterval(Double(index)), summary: "Progress \(index)",
                          snapshot: ProgressSnapshot(currentState: "State \(index)", nextAction: "Step \(index + 1)"))
        }
        let thread = ThreadRecord(title: "Long research history", createdAt: created,
                                  progressEvents: Array(events.reversed()))
        let started = Date()
        let stations = ProgressTimelineProjection.thread(thread)
        let recent = ProgressTimelineProjection.page(stations, limit: 50)
        let expanded = ProgressTimelineProjection.page(stations, limit: 100)
        let elapsed = Date().timeIntervalSince(started)
        #expect(stations.count == 10_001)
        #expect(recent.count == 50)
        #expect(recent.first?.event?.summary == "Progress 9951")
        #expect(recent.last?.event?.snapshot.currentState == "State 10000")
        #expect(Array(expanded.suffix(50)) == recent)
        #expect(Set(expanded.map(\.id)).count == expanded.count)
        #expect(elapsed < 3)
        print("10,000-event timeline projection and two pages: \(elapsed) s")
    }
}
