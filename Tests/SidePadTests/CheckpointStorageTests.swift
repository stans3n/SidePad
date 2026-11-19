import Foundation
import Testing
@testable import SidePad

@Suite(.serialized)
@MainActor
struct CheckpointStorageTests {
    private let date = Date(timeIntervalSince1970: 1_792_281_600)
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sidepad-checkpoint-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func shortOfflineCheckpointPersistsOriginalNoteAndSnapshotWithoutTaskActivity() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ThreadStore(directory: path)
        let original = ThreadRecord(title: "Project", createdAt: date, currentState: "Timeline working",
                                    nextAction: "Try inactive clicks", resumePoint: "Legacy recovery note")
        try store.save(original)
        let note = "  完成时间线。\nNext time: check inactive clicks.  "
        let taskID = UUID()
        let checkpoint = try store.addCheckpoint(threadID: original.id, note: note,
            resources: ["file:///tmp/project.md", "https://github.com/example/project/pull/1"],
            relatedTaskIDs: [taskID], expectedThread: original, now: date.addingTimeInterval(1))
        let restarted = ThreadStore(directory: path)
        let restored = try #require(restarted.threads.first)
        #expect(restored.checkpoints == [checkpoint])
        #expect(checkpoint.note == note)
        #expect(Data(checkpoint.note.utf8) == Data(note.utf8))
        #expect(checkpoint.threadID == original.id)
        #expect(checkpoint.origin == .manual)
        #expect(checkpoint.snapshot == ProgressSnapshot(thread: original))
        #expect(checkpoint.relatedTaskIDs == [taskID])
        #expect(restored.resumePoint == original.resumePoint)
        #expect(restored.progressEvents.isEmpty)
    }

    @Test func firstCheckpointMigratesExactlyOnceAndBacksUpOriginalLegacyBytes() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let original = ThreadRecord(title: "Legacy", createdAt: date,
            resumePoint: "Do not relabel this as a timestamped checkpoint", progressHistory: "Undated original history")
        let source = (try ThreadMarkdown.serialize(original) + "## Custom section\nKeep **all** spacing.  \n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        let file = path.appendingPathComponent(original.id.uuidString.lowercased() + ".md")
        try Data(source.utf8).write(to: file)
        let store = ThreadStore(directory: path)
        #expect(try Data(contentsOf: file) == Data(source.utf8))
        #expect(store.threads.first?.checkpoints.isEmpty == true)
        let first = try store.addCheckpoint(threadID: original.id, note: "A real new checkpoint", now: date.addingTimeInterval(10))
        let upgraded = try String(contentsOf: file, encoding: .utf8)
        #expect(upgraded.contains("schema_version: 2\r\n"))
        #expect(upgraded.contains("## Custom section\r\nKeep **all** spacing.  \r\n"))
        #expect(upgraded.contains("## Checkpoints\r\n```json\r\n"))
        let backups = path.appendingPathComponent(".schema-backups")
        let files = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        #expect(try Data(contentsOf: #require(files.first)) == Data(source.utf8))
        try store.addCheckpoint(threadID: original.id, note: "Second checkpoint", now: date.addingTimeInterval(20))
        let reopened = ThreadStore(directory: path)
        #expect(reopened.threads.first?.checkpoints.first == first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).count == 1)
        let bytes = try Data(contentsOf: file)
        try reopened.save(#require(reopened.threads.first))
        #expect(try Data(contentsOf: file) == bytes)
        #expect(reopened.threads.first?.resumePoint == original.resumePoint)
    }

    @Test func ordinaryLegacyEditsDoNotMigrateOrInventCheckpointFacts() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ThreadStore(directory: path)
        var original = ThreadRecord(title: "Legacy", createdAt: date, resumePoint: "Undated old note")
        try store.save(original)
        original.nextAction = "Review"
        try store.save(original)
        #expect(try ThreadMarkdown.parse(String(contentsOf: store.fileURL(for: original.id), encoding: .utf8)).schemaVersion == 1)
        #expect(!FileManager.default.fileExists(atPath: path.appendingPathComponent(".schema-backups").path))
        #expect(store.threads.first?.checkpoints.isEmpty == true)
    }

    @Test func customCheckpointHeadingIsPreservedAndMigrationFailsSafely() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let original = ThreadRecord(title: "Custom", createdAt: date)
        let source = try ThreadMarkdown.serialize(original) + "## Checkpoints\nHandwritten custom content\n"
        let file = path.appendingPathComponent(original.id.uuidString.lowercased() + ".md")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let store = ThreadStore(directory: path)
        #expect(!store.isReadOnly)
        #expect(throws: (any Error).self) { try store.addCheckpoint(threadID: original.id, note: "New checkpoint") }
        #expect(try String(contentsOf: file, encoding: .utf8) == source)
    }

    @Test func contextChangesSnapshotAndLegacyResumeRemainsUntouched() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ThreadStore(directory: path)
        let original = ThreadRecord(title: "Project", createdAt: date, currentState: "Before", nextAction: "Old next", blockers: "Blocked", resumePoint: "Original")
        try store.save(original)
        let checkpoint = try store.addCheckpoint(threadID: original.id, note: "Ready for next session",
            nextAction: "Check resize", currentState: "After", blockers: "", now: date.addingTimeInterval(1))
        let saved = try #require(store.threads.first)
        #expect(saved.nextAction == "Check resize")
        #expect(saved.currentState == "After")
        #expect(saved.blockers.isEmpty)
        #expect(saved.resumePoint == "Original")
        #expect(checkpoint.snapshot == ProgressSnapshot(thread: saved))
        #expect(original.currentState == "Before")
    }

    @Test func retriesAreIdempotentAndConflictingCheckpointIDsAreRejected() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ThreadStore(directory: path)
        let original = ThreadRecord(title: "Retry", createdAt: date)
        try store.save(original)
        let id = UUID()
        let first = try store.addCheckpoint(threadID: original.id, note: "Saved once", checkpointID: id, now: date)
        let file = store.fileURL(for: original.id)
        let bytes = try Data(contentsOf: file)
        let retried = try store.addCheckpoint(threadID: original.id, note: "Saved once", expectedThread: original,
                                              checkpointID: id, now: date.addingTimeInterval(100))
        #expect(retried == first)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(throws: ThreadStoreError.self) { try store.addCheckpoint(threadID: original.id, note: "Different", checkpointID: id) }
        #expect(store.threads.first?.checkpoints.count == 1)
    }

    @Test func externalAndStaleDraftEditsAreNeverOverwritten() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ThreadStore(directory: path)
        let original = ThreadRecord(title: "Conflict", createdAt: date)
        try store.save(original)
        var current = original
        current.nextAction = "A newer action"
        try store.save(current)
        #expect(throws: ThreadStoreError.self) {
            try store.addCheckpoint(threadID: original.id, note: "Stale draft", nextAction: "Old draft", expectedThread: original)
        }
        let file = store.fileURL(for: original.id)
        let external = try String(contentsOf: file, encoding: .utf8) + "\n## External\nKeep this\n"
        try external.write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: ThreadStoreError.self) { try store.addCheckpoint(threadID: original.id, note: "Will not save") }
        #expect(try String(contentsOf: file, encoding: .utf8) == external)
        try store.reload()
        try store.addCheckpoint(threadID: original.id, note: "After review", expectedThread: #require(store.threads.first))
        #expect(try String(contentsOf: file, encoding: .utf8).contains("## External\nKeep this\n"))
    }

    @Test func savedCheckpointsAndActivitySnapshotsCannotBeRewrittenThroughStore() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ThreadStore(directory: path)
        let activity = ProgressEvent(timestamp: date, summary: "Completed task", source: .taskChange)
        let original = ThreadRecord(title: "Evidence", createdAt: date, progressEvents: [activity])
        try store.save(original)
        let checkpoint = try store.addCheckpoint(threadID: original.id, note: "Saved state", now: date)
        var edited = try #require(store.threads.first)
        let bytes = try Data(contentsOf: store.fileURL(for: original.id))
        edited.checkpoints = [ThreadCheckpoint(id: checkpoint.id, threadID: original.id, createdAt: date, note: "Altered")]
        #expect(throws: ThreadStoreError.self) { try store.save(edited) }
        edited.checkpoints = []
        #expect(throws: ThreadStoreError.self) { try store.save(edited) }
        #expect(throws: ThreadStoreError.self) { try store.commit([], allowActivityRemoval: true) }
        edited = try #require(store.threads.first)
        edited.progressEvents[0].snapshot.currentState = "False historical state"
        #expect(throws: ThreadStoreError.self) { try store.save(edited) }
        edited = try #require(store.threads.first)
        edited.progressEvents = []
        #expect(throws: ThreadStoreError.self) { try store.save(edited) }
        #expect(try Data(contentsOf: store.fileURL(for: original.id)) == bytes)
    }

    @Test func checkpointFailureRollsBackOriginalBytesWhileRetainingMigrationBackup() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ThreadStore(directory: path)
        let original = ThreadRecord(title: "Failure", createdAt: date)
        try store.save(original)
        let file = store.fileURL(for: original.id)
        let bytes = try Data(contentsOf: file)
        store.writeFailureInjector = { _ in throw CocoaError(.fileWriteNoPermission) }
        #expect(throws: (any Error).self) { try store.addCheckpoint(threadID: original.id, note: "Not committed") }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(store.threads == [original])
        #expect(try FileManager.default.contentsOfDirectory(atPath: path.path).allSatisfy { !$0.hasPrefix(".thread-transaction-") })
        store.writeFailureInjector = nil
        try store.addCheckpoint(threadID: original.id, note: "Retry succeeds")
        #expect(try FileManager.default.contentsOfDirectory(atPath: path.appendingPathComponent(".schema-backups").path).count == 1)
    }

    @Test func malformedCheckpointVersionAndUnknownFieldsFailClosed() throws {
        let checkpoint = ThreadCheckpoint(threadID: UUID(), createdAt: date, note: "Valid")
        let source = try CheckpointMarkdown.serialize([checkpoint])
        #expect(try CheckpointMarkdown.parse(source) == [checkpoint])
        #expect(throws: (any Error).self) { try CheckpointMarkdown.parse(source.replacingOccurrences(of: "\"schema_version\" : 1", with: "\"schema_version\" : 99")) }
        #expect(throws: (any Error).self) { try CheckpointMarkdown.parse(source.replacingOccurrences(of: "\"origin\" : \"manual\"", with: "\"invented\" : true, \"origin\" : \"manual\"")) }
        #expect(throws: (any Error).self) { try ThreadCheckpoint.validate([checkpoint, checkpoint]) }
        #expect(throws: (any Error).self) { try ThreadCheckpoint.validate([ThreadCheckpoint(threadID: UUID(), note: " ")]) }
        #expect(throws: (any Error).self) { try ThreadCheckpoint.validate([ThreadCheckpoint(threadID: UUID(), note: "Completion", origin: .taskChange)]) }
    }

    @Test func handoffIncludesCheckpointEvidenceAndEscapesUntrustedMarkdown() throws {
        let id = UUID()
        let checkpoint = ThreadCheckpoint(threadID: id, createdAt: date, note: "Literal\n```\n## User heading",
            snapshot: ProgressSnapshot(currentState: "Saved", nextAction: "Resume here"),
            relatedTaskIDs: [UUID()], resources: ["file:///tmp/project.md"])
        let thread = ThreadRecord(id: id, title: "Handoff", createdAt: date, currentState: "Newer live state", checkpoints: [checkpoint])
        let exported = HandoffMarkdown.render(thread: thread, task: nil, threads: [thread], tasks: [], directory: URL(fileURLWithPath: "/tmp"), now: date)
        #expect(exported.contains("## Checkpoints"))
        #expect(exported.contains(checkpoint.id.uuidString.lowercased()))
        #expect(exported.contains("````text\nLiteral\n```\n## User heading\n````"))
        #expect(exported.contains("Newer live state"))
        #expect(exported.contains("Resume here"))
        #expect(exported.contains("file:///tmp/project.md"))
    }
    @Test func externalHistoryLossRetainsLoadedEvidenceAndRecoveryBytes() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ThreadStore(directory: path)
        let original = ThreadRecord(title: "History", createdAt: date,
            progressEvents: [ProgressEvent(timestamp: date, summary: "Original activity")])
        try store.save(original)
        try store.addCheckpoint(threadID: original.id, note: "Original checkpoint", now: date)
        let saved = try #require(store.threads.first)
        let file = store.fileURL(for: original.id)
        let bytes = try Data(contentsOf: file)
        var external = saved
        external.progressEvents = []
        external.checkpoints = []
        let edited = try ThreadMarkdown.serialize(external)
        try edited.write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: ThreadStoreError.self) { try store.reload() }
        #expect(store.isReadOnly)
        #expect(store.threads == [saved])
        #expect(try String(contentsOf: file, encoding: .utf8) == edited)
        let recovery = try FileManager.default.contentsOfDirectory(at: path.appendingPathComponent(".history-recovery"), includingPropertiesForKeys: nil)
        #expect(recovery.count == 1)
        #expect(try Data(contentsOf: #require(recovery.first)) == bytes)
        try bytes.write(to: file, options: .atomic)
        try store.reload()
        #expect(!store.isReadOnly)
        #expect(store.threads == [saved])
        try FileManager.default.removeItem(at: file)
        #expect(throws: ThreadStoreError.self) { try store.reload() }
        #expect(store.threads == [saved])
    }

    @Test func conflictCopyKeepsHistoricalIdentityAndSourceProvenance() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ThreadStore(directory: path)
        let original = ThreadRecord(title: "Original", createdAt: date)
        try store.save(original)
        let checkpoint = try store.addCheckpoint(threadID: original.id, note: "Source checkpoint", now: date)
        let base = try #require(store.threads.first)
        let viewState = ThreadsViewState()
        var draft = base
        draft.notes = "A local draft"
        viewState.update(draft, base: base)
        let originalFile = store.fileURL(for: original.id)
        let external = try String(contentsOf: originalFile, encoding: .utf8) + "\n## Unknown section\nExternal prose\n"
        try external.write(to: originalFile, atomically: true, encoding: .utf8)
        let copyID = try viewState.saveLocalCopy(original.id, in: store)
        let copied = try #require(store.threads.first { $0.id == copyID })
        #expect(copied.checkpoints == [checkpoint])
        #expect(copied.checkpoints.first?.threadID == original.id)
        #expect(copied.id != original.id)
        #expect(try String(contentsOf: originalFile, encoding: .utf8) == external)
        let new = try store.addCheckpoint(threadID: copyID, note: "A new checkpoint on the recovery copy")
        #expect(new.threadID == copyID)
        #expect(ThreadStore(directory: path).threads.count == 2)
    }

    @Test func fencedCheckpointHeadingAndUnicodeNoteDoNotChangeAuthoredBytes() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ThreadStore(directory: path)
        let original = ThreadRecord(title: "Unicode", createdAt: date, notes: "```text\n## Checkpoints\nThis is an example, not a section.\n```")
        try store.save(original)
        let note = "  e\u{301} — 中文\r\n  Fin  "
        let checkpoint = try store.addCheckpoint(threadID: original.id, note: note, now: date.addingTimeInterval(0.123456))
        let loaded = try #require(ThreadStore(directory: path).threads.first)
        #expect(Data(try #require(loaded.checkpoints.first).note.utf8) == Data(note.utf8))
        #expect(loaded.checkpoints.first?.createdAt == checkpoint.createdAt)
        #expect(loaded.notes == original.notes)
    }

    @Test func confirmedIntentUndoRemovesOnlyItsNewActivityAndKeepsCheckpointEvidence() throws {
        let path = try directory()
        let suite = "sidepad-checkpoint-undo-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: path) }
        let workspace = WorkspaceStore(defaults: defaults)
        let threads = ThreadStore(directory: path)
        let settings = AISettingsStore(defaults: defaults)
        let coordinator = ThreadsCoordinator(workspace: workspace, threads: threads, settings: settings)
        let original = ThreadRecord(title: "Undo", createdAt: date)
        try threads.save(original)
        let checkpoint = try threads.addCheckpoint(threadID: original.id, note: "Retain this", now: date)
        let before = try #require(threads.threads.first)
        try coordinator.logProgress(threadID: original.id, taskID: nil, summary: "New activity",
            snapshot: .init(currentState: "New state"), expectedThread: before, expectedTask: nil)
        #expect(threads.threads.first?.progressEvents.count == 1)
        try coordinator.undo()
        #expect(threads.threads.first?.progressEvents.isEmpty == true)
        #expect(threads.threads.first?.checkpoints == [checkpoint])
        #expect(threads.threads.first?.currentState == before.currentState)
    }

}
