import Foundation
import Testing
@testable import SidePad

@Suite(.serialized)
@MainActor
struct ThreadStorageTests {
    private let date = Date(timeIntervalSince1970: 1_792_281_600)

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sidepad-thread-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func markdownRoundTripPreservesUnknownContentAndCRLF() throws {
        let record = ThreadRecord(title: "项目: '研究' \"A\"", createdAt: date,
                                  currentState: "正在检查。", notes: "  Preserve indent  \n\n```md\n## Summary\nnot a section\n```")
        var source = try ThreadMarkdown.serialize(record)
        source = source.replacingOccurrences(of: "schema_version: 1", with: "schema_version: 1 # keep this comment\ncustom_label: 'handwritten: yes' # keep this too")
        source += "## My independent section\n\nUntouched **prose**, spacing   \n"
        source = source.replacingOccurrences(of: "\n", with: "\r\n")
        let parsed = try ThreadMarkdown.parse(source)
        #expect(parsed.record.title == record.title)
        #expect(parsed.record.notes.contains("## Summary"))
        #expect(try parsed.updating(parsed.record) == source)
        var changed = parsed.record
        changed.currentState = "新的状态。"
        #expect(try parsed.updating(changed) == source.replacingOccurrences(of: "正在检查。", with: "新的状态。"))
    }

    @Test func changedMetadataKeepsCommentsUnknownFieldsAndBody() throws {
        let record = ThreadRecord(title: "Original", createdAt: date)
        let source = try ThreadMarkdown.serialize(record)
            .replacingOccurrences(of: "title: \"Original\"", with: "title: 'Original'   # an annotation")
        let parsed = try ThreadMarkdown.parse(source)
        var changed = parsed.record
        changed.title = "Renamed"
        let output = try parsed.updating(changed)
        #expect(output == source.replacingOccurrences(of: "title: 'Original'", with: "title: \"Renamed\""))
        #expect(output.contains("# Original")) // The optional authored heading is prose, not metadata.
    }

    @Test func metadataRejectsAmbiguousOrUnsupportedYAML() throws {
        let valid = try ThreadMarkdown.serialize(ThreadRecord(title: "Safe", createdAt: date))
        let invalid = [
            valid.replacingOccurrences(of: "schema_version: 1", with: "schema_version: 99"),
            valid.replacingOccurrences(of: "schema_version: 1", with: "schema_version: \"1\""),
            valid.replacingOccurrences(of: "status: active", with: "status: invented"),
            valid.replacingOccurrences(of: "title: \"Safe\"", with: "title: null"),
            valid.replacingOccurrences(of: "title: \"Safe\"", with: "title: \"Safe\"\ntitle: \"duplicate\""),
            valid.replacingOccurrences(of: "title: \"Safe\"", with: "title: \"Safe\"oops"),
            valid.replacingOccurrences(of: "title: \"Safe\"", with: "title: |\n  multiline"),
            valid.replacingOccurrences(of: "status: active", with: "status: active\nunknown: [unsafe, structured]"),
            valid.replacingOccurrences(of: "status: active", with: "status: active\nunknown: &anchor yes"),
            valid.replacingOccurrences(of: "parent_id: null", with: "parent_id: not-a-uuid"),
            valid.replacingOccurrences(of: "created_at: \"", with: "created_at: \"invalid"),
            valid + "\n## Notes\nduplicate\n"
        ]
        for source in invalid { #expect(throws: (any Error).self) { _ = try ThreadMarkdown.parse(source) } }
        for timestamp in ["2026-02-30T00:00:00Z", "2026-10-18T24:00:00Z", "2026-10-18T00:00:00+99:00"] {
            let malformedDate = valid.replacingOccurrences(of: "created_at: \"[^\"]+\"", with: "created_at: \"\(timestamp)\"", options: .regularExpression)
            #expect(throws: (any Error).self) { _ = try ThreadMarkdown.parse(malformedDate) }
        }
    }

    @Test func optionalMetadataAndMissingSectionsCanBeAddedWithoutRewritingProse() throws {
        let id = UUID()
        let source = "---\nid: '\(id)'\nschema_version: 1\ntitle: Minimal\nstatus: active\ncreated_at: '2026-10-18T00:00:00Z'\nupdated_at: '2026-10-18T00:00:00Z'\n---\nCustom intro.\n"
        let parsed = try ThreadMarkdown.parse(source)
        #expect(parsed.record.parentID == nil)
        #expect(parsed.record.lastActivity == parsed.record.updatedAt)
        var updated = parsed.record
        updated.notes = "New note"
        updated.parentID = UUID()
        let output = try parsed.updating(updated)
        #expect(output.contains("---\nCustom intro.\n\n## Notes\nNew note\n"))
        #expect(try ThreadMarkdown.parse(output).record.parentID == updated.parentID)
    }

    @Test func hierarchyPersistsAcrossRestartAndUndoRemovesCreatedFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ThreadStore(directory: directory)
        let parent = ThreadRecord(title: "SidePad", createdAt: date, summary: "工作上下文")
        let child = ThreadRecord(title: "Threads", parentID: parent.id, createdAt: date, notes: "手动笔记")
        try store.commit([parent, child])
        let reopened = ThreadStore(directory: directory)
        #expect(reopened.errorMessage == nil)
        #expect(Set(reopened.threads.map(\.id)) == [parent.id, child.id])
        #expect(reopened.threads.first(where: { $0.id == child.id }) == child)
        #expect(reopened.fileURL(for: child.id).lastPathComponent == child.id.uuidString.lowercased() + ".md")
        try store.commit([parent])
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: child.id).path))
        #expect(ThreadStore(directory: directory).threads == [parent])
    }

    @Test func externalChangesConflictThenExplicitReloadPreservesEditedContent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ThreadStore(directory: directory)
        let record = ThreadRecord(title: "Original", createdAt: date, notes: "Original note")
        try store.save(record)
        let url = store.fileURL(for: record.id)
        let external = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "Original note", with: "External note") + "\n## Custom\nKeep me.\n"
        try external.write(to: url, atomically: true, encoding: .utf8)
        var draft = record
        draft.notes = "Unsaved draft"
        #expect(throws: ThreadStoreError.self) { try store.save(draft) }
        #expect(store.threads[0].notes == "Original note")
        #expect(try String(contentsOf: url, encoding: .utf8) == external)
        try store.reload()
        #expect(store.threads[0].notes == "External note")
        var refreshed = store.threads[0]
        refreshed.nextAction = "Next step"
        try store.save(refreshed)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("## Custom\nKeep me."))
    }

    @Test func externalAdditionAndRemovalBothBlockStaleCommits() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ThreadStore(directory: directory)
        let record = ThreadRecord(title: "Existing", createdAt: date)
        try store.save(record)
        let added = ThreadRecord(title: "Externally added", createdAt: date)
        try ThreadMarkdown.serialize(added).write(to: store.fileURL(for: added.id), atomically: true, encoding: .utf8)
        #expect(throws: ThreadStoreError.self) { try store.save(record) }
        try store.reload()
        #expect(store.threads.count == 2)
        try FileManager.default.removeItem(at: store.fileURL(for: added.id))
        #expect(throws: ThreadStoreError.self) { try store.commit([record]) }
        try store.reload()
        #expect(store.threads == [record])
    }

    @Test func invalidFilesBlockWritesWithoutOverwritingAndReloadCanRecover() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = ThreadRecord(title: "Recoverable", createdAt: date)
        let url = directory.appendingPathComponent(record.id.uuidString.lowercased() + ".md")
        let broken = "---\nid: bad\n---\nNever overwrite this content."
        try broken.write(to: url, atomically: true, encoding: .utf8)
        let store = ThreadStore(directory: directory)
        #expect(store.isReadOnly)
        #expect(store.threads.isEmpty)
        #expect(throws: ThreadStoreError.self) { try store.save(record) }
        #expect(try String(contentsOf: url, encoding: .utf8) == broken)
        try ThreadMarkdown.serialize(record).write(to: url, atomically: true, encoding: .utf8)
        try store.reload()
        #expect(!store.isReadOnly)
        #expect(store.threads == [record])
    }

    @Test func duplicateIDsCyclesOrphansAndInvalidFilenamesAreRejected() throws {
        let root = ThreadRecord(title: "Root", createdAt: date)
        let child = ThreadRecord(title: "Child", parentID: root.id, createdAt: date)
        var cycle = root
        cycle.parentID = child.id
        #expect(throws: ThreadStoreError.self) { try ThreadStore.validateHierarchy([root, root]) }
        #expect(throws: ThreadStoreError.self) { try ThreadStore.validateHierarchy([child]) }
        #expect(throws: ThreadStoreError.self) { try ThreadStore.validateHierarchy([cycle, child]) }
        cycle.parentID = cycle.id
        #expect(throws: ThreadStoreError.self) { try ThreadStore.validateHierarchy([cycle]) }
        var nested = [root]
        for index in 0..<200 { nested.append(ThreadRecord(title: "Level \(index)", parentID: nested.last!.id, createdAt: date)) }
        try ThreadStore.validateHierarchy(nested)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try ThreadMarkdown.serialize(root).write(to: directory.appendingPathComponent("renamed.md"), atomically: true, encoding: .utf8)
        #expect(ThreadStore(directory: directory).isReadOnly)
    }

    @Test func batchFailureRestoresExactOriginalBytesAndModel() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ThreadStore(directory: directory)
        let root = ThreadRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "Root", createdAt: date)
        let child = ThreadRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "Child", parentID: root.id, createdAt: date)
        try store.commit([root, child])
        let originalRoot = try Data(contentsOf: store.fileURL(for: root.id))
        let originalChild = try Data(contentsOf: store.fileURL(for: child.id))
        var updated = root
        updated.notes = "Would change"
        let added = ThreadRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, title: "Added", createdAt: date)
        store.writeFailureInjector = { index in if index == 2 { throw CocoaError(.fileWriteNoPermission) } }
        #expect(throws: (any Error).self) { try store.commit([updated, added]) }
        #expect(try Data(contentsOf: store.fileURL(for: root.id)) == originalRoot)
        #expect(try Data(contentsOf: store.fileURL(for: child.id)) == originalChild)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: added.id).path))
        #expect(store.threads == [root, child])
        #expect(!store.isReadOnly)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
        store.writeFailureInjector = nil
        try store.commit([updated, added])
        #expect(store.threads == [updated, added])
    }

    @Test func rollbackNeverOverwritesAConcurrentExternalEdit() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ThreadStore(directory: directory)
        let root = ThreadRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "Root", createdAt: date)
        try store.save(root)
        var updated = root
        updated.notes = "Application edit"
        var external = root
        external.notes = "External edit during transaction"
        let externalText = try ThreadMarkdown.serialize(external)
        let url = store.fileURL(for: root.id)
        let added = ThreadRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "Added", createdAt: date)
        store.writeFailureInjector = { index in
            if index == 1 {
                try externalText.write(to: url, atomically: true, encoding: .utf8)
                throw CocoaError(.fileWriteUnknown)
            }
        }
        #expect(throws: ThreadStoreError.self) { try store.commit([updated, added]) }
        #expect(try String(contentsOf: url, encoding: .utf8) == externalText)
        #expect(store.isReadOnly)
        let reopened = ThreadStore(directory: directory)
        #expect(reopened.isReadOnly)
        #expect(reopened.errorMessage?.contains("recovery") == true)
        let journal = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first(where: { $0.lastPathComponent.hasPrefix(".thread-transaction-") }))
        #expect(FileManager.default.fileExists(atPath: journal.appendingPathComponent("before/" + url.lastPathComponent).path))
    }

    @Test func symbolicLinksDoNotReadOrOverwriteOutsideTheThreadDirectory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let record = ThreadRecord(title: "Outside", createdAt: date)
        let target = outside.appendingPathComponent("original.md")
        let text = try ThreadMarkdown.serialize(record)
        try text.write(to: target, atomically: true, encoding: .utf8)
        let link = directory.appendingPathComponent(record.id.uuidString.lowercased() + ".md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = ThreadStore(directory: directory)
        #expect(store.isReadOnly)
        #expect(throws: ThreadStoreError.self) { try store.save(record) }
        #expect(try String(contentsOf: target, encoding: .utf8) == text)
    }

    @Test func rejectedSectionInjectionCannotPartiallyWriteABatch() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ThreadStore(directory: directory)
        let record = ThreadRecord(title: "Existing", createdAt: date)
        try store.save(record)
        let before = try Data(contentsOf: store.fileURL(for: record.id))
        var injected = record
        injected.notes = "## Summary\nAmbiguous section boundary"
        #expect(throws: (any Error).self) { try store.commit([injected, ThreadRecord(title: "New", createdAt: date)]) }
        for content in ["Intro\n## Custom\nWould silently truncate Notes", "# Unfenced title", "```\nUnclosed fence"] {
            injected.notes = content
            #expect(throws: (any Error).self) { try store.save(injected) }
            #expect(throws: (any Error).self) { _ = try ThreadMarkdown.serialize(injected) }
        }
        #expect(try Data(contentsOf: store.fileURL(for: record.id)) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    }
}
