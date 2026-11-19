import Foundation
import Testing
@testable import SidePad

@MainActor
struct ProjectMemoryViewTests {
    @Test func pinsKeepExplicitOrderAndEmptyChoiceAcrossRestart() {
        let suite = "SidePad.Pins.Test.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = URL(fileURLWithPath: "/tmp/pins-test-\(UUID())")
        let one = ThreadRecord(title: "One")
        let two = ThreadRecord(title: "Two")
        let three = ThreadRecord(title: "Three")
        let archived = ThreadRecord(title: "Archived", status: .archived)
        let pins = ProjectPinsStore(library: library, defaults: defaults)
        pins.seedIfNeeded(from: [one, two, three, archived])
        #expect(pins.ids == [one.id, two.id])
        pins.pin(three.id)
        #expect(pins.ids == [one.id, two.id])
        pins.moveFirst(two.id)
        pins.seedIfNeeded(from: [three, two, one])
        #expect(pins.ids == [two.id, one.id])
        #expect(ProjectPinsStore(library: library, defaults: defaults).ids == [two.id, one.id])
        pins.unpin(one.id); pins.unpin(two.id)
        let restarted = ProjectPinsStore(library: library, defaults: defaults)
        restarted.seedIfNeeded(from: [one, two])
        #expect(restarted.ids.isEmpty)
        #expect(ProjectPinsStore(library: library.appendingPathComponent("other"), defaults: defaults).ids.isEmpty)
    }

    @Test func pinnedRemovalDoesNotSubstituteRecentlyOpenedProject() {
        let suite = "SidePad.Pins.Test.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let pins = ProjectPinsStore(library: URL(fileURLWithPath: "/tmp/pins-\(UUID())"), defaults: defaults)
        let one = ThreadRecord(title: "One"), two = ThreadRecord(title: "Two"), three = ThreadRecord(title: "Three")
        pins.seedIfNeeded(from: [one, two, three])
        pins.reconcile(with: [two, three])
        pins.seedIfNeeded(from: [three, two])
        #expect(pins.ids == [two.id])
        pins.pin(three.id)
        #expect(pins.projects(in: [three, two]).map(\.id) == [two.id, three.id])
    }

    @Test func resumeDoesNotFabricatePreviousAndPrefersExplicitNext() {
        var thread = ThreadRecord(title: "Project")
        let task = TaskItem(title: "First task", sortOrder: 0, threadID: thread.id)
        let legacyDone = TaskItem(title: "Legacy done", isCompleted: true, sortOrder: 1, threadID: thread.id)
        #expect(ProjectResumeProjection.previous(thread: thread, tasks: [task, legacyDone]) == nil)
        #expect(ProjectResumeProjection.next(thread: thread, tasks: [task]).taskID == task.id)
        thread.nextAction = "Review the recorded result"
        #expect(ProjectResumeProjection.next(thread: thread, tasks: [task]).text == thread.nextAction)
        #expect(ProjectResumeProjection.next(thread: thread, tasks: [task]).taskID == nil)
        thread.nextAction = ""
        #expect(ProjectResumeProjection.next(thread: thread, tasks: []).isMissing)
    }

    @Test func checkpointAndTaskActivitiesRemainDistinctAndInspectionDoesNotMutate() {
        var thread = ThreadRecord(title: "Project", createdAt: Date(timeIntervalSince1970: 50))
        var task = TaskItem(title: "Implementation", isCompleted: true, sortOrder: 0, threadID: thread.id)
        let completion = ProgressEvent(timestamp: Date(timeIntervalSince1970: 100), summary: "Task completed",
            source: .taskChange, taskID: task.id, taskTitle: task.title, taskCompleted: true)
        task.progressEvents = [completion]
        thread.progressEvents = [completion]
        let checkpoint = ThreadCheckpoint(threadID: thread.id, createdAt: Date(timeIntervalSince1970: 200),
            note: "Stopped after reviewing the first result", snapshot: .init(nextAction: "Review another result"))
        thread.checkpoints = [checkpoint]
        let before = thread
        let entries = ProjectHistoryProjection.entries(thread: thread, tasks: [task])
        #expect(entries.count == 3)
        #expect(entries.map(\.kind) == ["Checkpoint", "Task completed", "Created"])
        #expect(entries.first?.checkpoint?.snapshot?.nextAction == "Review another result")
        #expect(ProjectResumeProjection.previous(thread: thread, tasks: [task])?.text == checkpoint.note)
        #expect(thread == before)
        #expect(thread.nextAction.isEmpty)
    }

    @Test func resourceLinksSupportFilePathsAndRejectUnsafeSchemes() {
        let urls = MemoryResourceLinks.urls(in: "[Notes](file:///tmp/notes.md)\n[Repo](https://github.com/example/repo)\n/tmp/My Project\n[unsafe](javascript:alert(1))\nhttps://github.com/example/repo")
        #expect(urls.count == 3)
        #expect(urls.filter(\.isFileURL).count == 2)
        #expect(urls.allSatisfy { ["file", "https"].contains($0.scheme ?? "") })
        #expect(urls.contains { $0.path == "/tmp/My Project" })
    }
}
