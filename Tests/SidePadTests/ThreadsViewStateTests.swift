import Foundation
import Testing
@testable import SidePad

@Suite(.serialized)
@MainActor
struct ThreadsViewStateTests {
    @Test func deepTreeCollapseAndSearchKeepFullBreadcrumb() {
        var records: [ThreadRecord] = [ThreadRecord(title: "Root")]
        for level in 1...12 {
            records.append(ThreadRecord(title: "Level \(level)", parentID: records.last!.id))
        }
        let expanded = Set(records.map(\.id))
        let all = ThreadTreeProjection.rows(in: records, expanded: expanded, search: "")
        #expect(all.count == 13)
        #expect(all.last?.depth == 12)
        #expect(all.last?.breadcrumb.hasPrefix("Root › Level 1 ›") == true)
        #expect(ThreadTreeProjection.rows(in: records, expanded: [], search: "").count == 1)
        let match = ThreadTreeProjection.rows(in: records, expanded: [], search: "Level 12")
        #expect(match.count == 1)
        #expect(match.first?.thread.id == records.last?.id)
        #expect(match.first?.breadcrumb == all.last?.breadcrumb)
        #expect(ThreadTreeProjection.descendants(of: records[1].id, in: records).count == 12)
    }

    @Test func reloadedExternalEditCannotBeOverwrittenByStaleDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ThreadStore(directory: directory)
        try store.save(ThreadRecord(title: "Research", notes: "Original notes"))
        let original = try #require(store.threads.first)
        let state = ThreadsViewState()
        var draft = original
        draft.notes = "Local unsaved notes"
        state.update(draft, base: original)
        var external = original
        external.notes = "External editor notes"
        try ThreadMarkdown.serialize(external).write(to: store.fileURL(for: original.id), atomically: true, encoding: .utf8)
        try store.reload()
        #expect(state.isDirty(original.id))
        #expect(state.hasConflict(try #require(store.threads.first)))
        #expect(throws: (any Error).self) { try state.save(original.id, in: store) }
        #expect(store.threads.first?.notes == "External editor notes")
        #expect(state.drafts[original.id]?.notes == "Local unsaved notes")
    }

    @Test func keepLocalCopyPreservesExternalBytesAndClearsOnlyOriginalDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ThreadStore(directory: directory)
        try store.save(ThreadRecord(title: "Research"))
        let original = try #require(store.threads.first)
        let state = ThreadsViewState()
        var draft = original
        draft.currentState = "Local progress"
        state.update(draft, base: original)
        let url = store.fileURL(for: original.id)
        let externalSource = try String(contentsOf: url, encoding: .utf8) + "\n## My custom heading\nExternal prose stays verbatim.\n"
        try externalSource.write(to: url, atomically: true, encoding: .utf8)
        let copiedID = try state.saveLocalCopy(original.id, in: store)
        #expect(copiedID != original.id)
        #expect(store.threads.count == 2)
        #expect(store.threads.first { $0.id == copiedID }?.currentState == "Local progress")
        #expect(try String(contentsOf: url, encoding: .utf8) == externalSource)
        #expect(!state.isDirty(original.id))
        let reopened = ThreadStore(directory: directory)
        #expect(reopened.threads.count == 2)
    }

    @Test func savingContextRecordsOneHistoricalSnapshotButNotesDoNotCreateFakeProgress() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ThreadStore(directory: directory)
        try store.save(ThreadRecord(title: "Research", currentState: "Baseline", nextAction: "Measure"))
        let original = try #require(store.threads.first)
        let state = ThreadsViewState()
        var draft = original
        draft.currentState = "Measured"
        draft.nextAction = "Inspect outliers"
        state.update(draft, base: original)
        try state.save(original.id, in: store)
        let saved = try #require(store.threads.first)
        #expect(saved.progressEvents.count == 1)
        #expect(saved.progressEvents[0].source == .manual)
        #expect(saved.progressEvents[0].snapshot.currentState == "Measured")
        #expect(saved.progressEvents[0].snapshot.nextAction == "Inspect outliers")
        #expect(!state.isDirty(original.id))
        try state.save(original.id, in: store)
        #expect(store.threads.first?.progressEvents.count == 1)

        var notesOnly = saved
        notesOnly.notes = "A reference to read later"
        state.update(notesOnly, base: saved)
        try state.save(saved.id, in: store)
        #expect(store.threads.first?.progressEvents == saved.progressEvents)
        #expect(ThreadStore(directory: directory).threads.first?.progressEvents == saved.progressEvents)
    }

    @Test func failedContextSaveRetainsDraftAndDoesNotAppendDuplicateHistoryOnRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ThreadStore(directory: directory)
        try store.save(ThreadRecord(title: "Research"))
        let original = try #require(store.threads.first)
        let state = ThreadsViewState()
        var draft = original
        draft.currentState = "Local result"
        state.update(draft, base: original)
        let url = store.fileURL(for: original.id)
        let originalBytes = try Data(contentsOf: url)
        let external = try String(contentsOf: url, encoding: .utf8) + "\nExternal note.\n"
        try external.write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try state.save(original.id, in: store) }
        #expect(state.drafts[original.id]?.progressEvents.isEmpty == true)
        #expect(state.isDirty(original.id))
        try originalBytes.write(to: url, options: .atomic)
        try state.save(original.id, in: store)
        #expect(store.threads.first?.progressEvents.count == 1)
    }

    @Test func broadThreadLibraryKeepsBreadcrumbsWithoutRebuildingAnIndexPerRow() {
        let root = ThreadRecord(title: "Root")
        let records = [root] + (0..<2_000).map { ThreadRecord(title: "Thread \($0)", parentID: root.id) }
        let started = Date()
        let rows = ThreadTreeProjection.rows(in: records, expanded: [root.id], search: "")
        let elapsed = Date().timeIntervalSince(started)
        #expect(rows.count == 2_001)
        #expect(rows.dropFirst().allSatisfy { $0.breadcrumb.hasPrefix("Root › Thread ") })
        #expect(elapsed < 3)
        print("2,001-thread tree projection: \(elapsed) s")
    }
}
