import Foundation
import Testing
@testable import SidePad

@Suite(.serialized)
@MainActor
struct ProgressStorageTests {
    private let date = Date(timeIntervalSince1970: 1_792_281_600)

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sidepad-progress-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func event(_ summary: String = "Ran V2; boundary accuracy is still unverified.", taskID: UUID? = nil) -> ProgressEvent {
        ProgressEvent(timestamp: date, summary: summary, taskID: taskID,
                      taskTitle: taskID == nil ? nil : "Check boundary accuracy", taskCompleted: taskID == nil ? nil : false,
                      snapshot: ProgressSnapshot(currentState: "V2 finished", nextAction: "Compare B0 and V2",
                                                 blockers: "Accuracy not checked", resumePoint: "Open the saved result"),
                      rawInput: "V2 跑完了，明天对比 B0。")
    }

    private func section(_ object: [String: Any]) throws -> String {
        "```json\n" + String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) + "\n```"
    }

    @Test func legacyMarkdownGainsEventsWithoutRewritingHistoryOrUnknownProse() throws {
        let record = ThreadRecord(title: "Legacy", createdAt: date,
                                  progressHistory: "- A handwritten entry without a reliable timestamp.\n  Preserve its spacing.")
        let legacy = (try ThreadMarkdown.serialize(record) + "## My evidence\nKeep this **exactly**.  \n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        let parsed = try ThreadMarkdown.parse(legacy)
        #expect(parsed.record.progressEvents.isEmpty)
        #expect(try parsed.updating(parsed.record) == legacy)
        #expect(!legacy.contains("## Progress Events"))
        var updated = parsed.record
        updated.progressEvents = [event("Literal user input:\n## Summary\n```json\nDo not turn this into a section.\n```")]
        let appended = try parsed.updating(updated)
        #expect(appended.hasPrefix(legacy))
        #expect(appended.contains("## Progress Events\r\n```json\r\n"))
        let reopened = try ThreadMarkdown.parse(appended)
        #expect(reopened.record.progressEvents == updated.progressEvents)
        #expect(reopened.record.progressHistory == parsed.record.progressHistory)
        #expect(try reopened.updating(reopened.record) == appended)
    }

    @Test func typedHistoryPersistsSnapshotAndDeletedTaskIdentityAcrossRestart() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let taskID = UUID() // No live TaskItem is required to keep historical evidence.
        let recorded = event(taskID: taskID)
        let thread = ThreadRecord(title: "Research", createdAt: date, currentState: "A newer current state", progressEvents: [recorded])
        let store = ThreadStore(directory: path)
        try store.save(thread)
        let restarted = ThreadStore(directory: path)
        let restored = try #require(restarted.threads.first)
        #expect(restored.progressEvents == [recorded])
        #expect(restored.currentState == "A newer current state")
        #expect(restored.progressEvents[0].snapshot.currentState == "V2 finished")
        #expect(restored.progressEvents[0].taskID == taskID)
        #expect(restored.progressEvents[0].taskTitle == "Check boundary accuracy")
        #expect(restored.progressEvents[0].source == .manual)
    }

    @Test func fractionalTimestampsEncodeAndDecodeWithoutDrift() throws {
        for fraction in [0.123456, 0.999999, 0.001001, 0.456789] {
            let original = ProgressEvent(timestamp: date.addingTimeInterval(fraction), summary: "Precise station time")
            let decoded = try JSONDecoder().decode(ProgressEvent.self, from: JSONEncoder().encode(original))
            #expect(decoded == original)
            let document = ThreadRecord(title: "Timing", createdAt: date, progressEvents: [original])
            #expect(try ThreadMarkdown.parse(ThreadMarkdown.serialize(document)).record.progressEvents == [original])
        }
    }

    @Test func malformedVersionFieldsDatesTypesAndDuplicateEventsAreRejected() throws {
        let validEvent = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(event())) as? [String: Any])
        var unknownEvent = validEvent
        unknownEvent["confirmed"] = false
        var invalidDate = validEvent
        invalidDate["timestamp"] = "2026-02-30T00:00:00Z"
        var invalidSource = validEvent
        invalidSource["source"] = "unreviewed_ai"
        var wrongType = validEvent
        wrongType["task_completed"] = "yes"
        var unknownSnapshot = validEvent
        unknownSnapshot["snapshot"] = ["current_state": "x", "next_action": "", "blockers": "", "resume_point": "", "invented": "field"]
        let invalid: [[String: Any]] = [
            ["schema_version": 2, "events": [validEvent]],
            ["schema_version": 1, "events": [validEvent], "extra": true],
            ["schema_version": 1, "events": [validEvent, validEvent]],
            ["schema_version": 1, "events": [unknownEvent]],
            ["schema_version": 1, "events": [invalidDate]],
            ["schema_version": 1, "events": [invalidSource]],
            ["schema_version": 1, "events": [wrongType]],
            ["schema_version": 1, "events": [unknownSnapshot]]
        ]
        for value in invalid {
            let malformed = try section(value)
            #expect(throws: (any Error).self) { _ = try ProgressMarkdown.parse(malformed) }
        }
        for malformed in ["", "[]", "```json\n{}", "```json\n{}\n```\nUnmodeled data", "```json\n{not json}\n```"] {
            #expect(throws: (any Error).self) { _ = try ProgressMarkdown.parse(malformed) }
        }
        #expect(throws: (any Error).self) { try ProgressEvent.validate(Array(repeating: event(), count: 10_001)) }
        #expect(throws: (any Error).self) { try ProgressEvent.validate([event(String(repeating: "x", count: 10_001))]) }
        var invalidTimestamp = event()
        invalidTimestamp.timestamp = Date(timeIntervalSince1970: .infinity)
        #expect(throws: (any Error).self) { _ = try JSONEncoder().encode(invalidTimestamp) }
    }

    @Test func malformedExternalEventKeepsLastValidHistoryAndRecoversAfterRepair() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ThreadStore(directory: path)
        let original = ThreadRecord(title: "Recoverable events", createdAt: date, progressEvents: [event()])
        try store.save(original)
        let file = store.fileURL(for: original.id)
        let validBytes = try Data(contentsOf: file)
        let broken = String(decoding: validBytes, as: UTF8.self).replacingOccurrences(of: "\"schema_version\" : 1", with: "\"schema_version\" : 99")
        try broken.write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try store.reload() }
        #expect(store.isReadOnly)
        #expect(store.threads == [original])
        #expect(throws: (any Error).self) { try store.save(original) }
        #expect(try String(contentsOf: file, encoding: .utf8) == broken)
        try validBytes.write(to: file, options: .atomic)
        try store.reload()
        #expect(!store.isReadOnly)
        #expect(store.threads == [original])
    }

    @Test func failedEventBatchRestoresExactHistoryBytesAndDuplicateAppendWritesNothing() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ThreadStore(directory: path)
        let original = ThreadRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "History", createdAt: date, progressEvents: [event()])
        let other = ThreadRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "Other", createdAt: date)
        try store.commit([original, other])
        let bytes = try Data(contentsOf: store.fileURL(for: original.id))
        var changed = original
        changed.progressEvents.append(event("A second station"))
        var changedOther = other
        changedOther.currentState = "Would update"
        store.writeFailureInjector = { index in if index == 1 { throw CocoaError(.fileWriteNoPermission) } }
        #expect(throws: (any Error).self) { try store.commit([changed, changedOther]) }
        #expect(try Data(contentsOf: store.fileURL(for: original.id)) == bytes)
        #expect(store.threads == [original, other])
        store.writeFailureInjector = nil
        changed.progressEvents = [original.progressEvents[0], original.progressEvents[0]]
        #expect(throws: (any Error).self) { try store.save(changed) }
        #expect(try Data(contentsOf: store.fileURL(for: original.id)) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: path.path).count == 2)
        // A local conflict copy can preserve event identities; it is the same historical evidence.
        var copy = original
        copy.id = UUID()
        copy.title = "History (local copy)"
        try store.save(copy)
        #expect(store.threads.count == 3)
        let copiedBytes = try Data(contentsOf: store.fileURL(for: copy.id))
        copy.progressEvents[0].summary = "Conflicting evidence under the same event UUID"
        #expect(throws: ThreadStoreError.self) { try store.save(copy) }
        #expect(try Data(contentsOf: store.fileURL(for: copy.id)) == copiedBytes)
        // External conflicting copies also fail closed when reopening.
        try ThreadMarkdown.serialize(copy).write(to: store.fileURL(for: copy.id), atomically: true, encoding: .utf8)
        #expect(ThreadStore(directory: path).isReadOnly)
    }

    @Test func verifyingPersistedEvidenceDoesNotReloadOrRewriteExternalChanges() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ThreadStore(directory: path)
        let original = ThreadRecord(title: "Evidence", createdAt: date, progressEvents: [event()])
        try store.save(original)
        try store.verifyUnchanged()
        let file = store.fileURL(for: original.id)
        let bytes = try Data(contentsOf: file)
        let external = String(decoding: bytes, as: UTF8.self) + "\n## External evidence\nPreserve me.\n"
        try external.write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: ThreadStoreError.self) { try store.verifyUnchanged() }
        #expect(store.threads == [original])
        #expect(try String(contentsOf: file, encoding: .utf8) == external)
        try FileManager.default.removeItem(at: file)
        #expect(throws: ThreadStoreError.self) { try store.verifyUnchanged() }
        #expect(store.threads == [original])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func longHistoryLoadsAppendsAndNoOpCommitDoesNotRewriteFiles() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let events = (0..<5_000).map { index in
            ProgressEvent(timestamp: date.addingTimeInterval(Double(index)), summary: "Completed step \(index)",
                          snapshot: ProgressSnapshot(currentState: "State \(index)", nextAction: "Check step \(index + 1)"))
        }
        let original = ThreadRecord(title: "5,000 stations", createdAt: date, progressEvents: events)
        let clock = ContinuousClock()
        let start = clock.now
        let store = ThreadStore(directory: path)
        try store.save(original)
        let restarted = ThreadStore(directory: path)
        #expect(!restarted.isReadOnly)
        #expect(restarted.threads.first?.progressEvents == events)
        var updated = try #require(restarted.threads.first)
        updated.progressEvents.append(event("Latest station"))
        try restarted.save(updated)
        let file = restarted.fileURL(for: original.id)
        let bytes = try Data(contentsOf: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let noOpStart = clock.now
        for _ in 0..<5 { try restarted.commit(restarted.threads) }
        let noOpElapsed = noOpStart.duration(to: clock.now)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == attributes[.modificationDate] as? Date)
        #expect(restarted.threads.first?.progressEvents.count == 5_001)
        let elapsed = start.duration(to: clock.now)
        print("Progress storage benchmark: 5,000 events, \(bytes.count) bytes; create/reopen/append + five no-ops \(elapsed); no-ops \(noOpElapsed)")
        // Broad guard against accidental quadratic work, not a machine-specific latency promise.
        #expect(elapsed < .seconds(30))
        #expect(noOpElapsed < .seconds(3))
    }
}
