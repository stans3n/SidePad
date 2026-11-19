import Foundation
import Testing
@testable import SidePad

@MainActor
private final class MemoryLocalFixture: ProjectMemoryRepository {
    var document = ProjectMemoryDocument(thread: ThreadRecord(title: "测试 project", nextAction: "Review UI"), tasks: [])
    var generation = 0
    func snapshot(threadID: UUID) throws -> ProjectMemorySnapshot {
        guard threadID == document.threadID else { throw MemorySyncError.missingProject }
        return ProjectMemorySnapshot(document: document, revision: "local-\(generation)")
    }
    func applyReviewed(_ document: ProjectMemoryDocument, expectedRevision: String) throws -> ProjectMemorySnapshot {
        guard expectedRevision == "local-\(generation)" else { throw MemorySyncError.localChanged }
        self.document = document; generation += 1
        return try snapshot(threadID: document.threadID)
    }
}

@MainActor
private final class MemoryRemoteFixture: MemoryRemoteRepository {
    var page = RemoteMemoryPage(pageID: UUID(), markdown: "")
    var writes = 0
    var loseNextWriteResponse = false
    func retrieve(pageID: UUID) async throws -> RemoteMemoryPage { page }
    func replace(pageID: UUID, expected: RemoteMemoryPage, markdown: String) async throws -> RemoteMemoryPage {
        guard pageID == page.pageID, expected.revision == page.revision else { throw MemorySyncError.remoteChanged }
        writes += 1; page.markdown = markdown
        if loseNextWriteResponse { loseNextWriteResponse = false; throw MemorySyncError.uncertainWrite }
        return page
    }
}

@MainActor
private final class NotionTransportFixture: NotionHTTPTransport {
    var replies: [(Int, Data, [String: String])] = []
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.networkConnectionLost) }
        let value = replies.removeFirst()
        return (value.1, HTTPURLResponse(url: request.url!, statusCode: value.0, httpVersion: nil, headerFields: value.2)!)
    }
}

@Suite(.serialized)
@MainActor
struct MemorySyncTests {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("sidepad-sync-" + UUID().uuidString) }
    private func response(_ page: RemoteMemoryPage, truncated: Bool = false, warnings: Bool = false) throws -> Data {
        var result: [String: Any] = ["object": "page_markdown", "id": page.pageID.uuidString, "markdown": page.markdown,
            "truncated": truncated, "unknown_block_ids": []]
        if warnings { result["warnings"] = [["code": "content_changed", "message": "Changed"]] }
        return try JSONSerialization.data(withJSONObject: result)
    }

    @Test func portableDocumentPreservesUnicodeFencesAndRejectsUnknownProse() throws {
        var value = ProjectMemoryDocument(thread: ThreadRecord(title: "项目", notes: "```json\n\"text\"\n```\n四个 ````"), tasks: [])
        let markdown = try value.markdown()
        #expect(try ProjectMemoryDocument.parse(markdown) == value)
        #expect(throws: MemorySyncError.invalidDocument) { try ProjectMemoryDocument.parse(markdown + "\nExternal prose") }
        let unsupported = markdown.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 1, \"custom\": true")
        #expect(throws: MemorySyncError.invalidDocument) { try ProjectMemoryDocument.parse(unsupported) }
        value.schemaVersion = 2
        #expect(throws: MemorySyncError.invalidDocument) { try value.markdown() }
    }

    @Test func initialSyncRequiresConfirmationThenDetectsBothChangedConflict() async throws {
        let url = directory(); defer { try? FileManager.default.removeItem(at: url) }
        let local = MemoryLocalFixture(), remote = MemoryRemoteFixture()
        let journal = try MemorySyncJournal(directory: url)
        let engine = ProjectMemorySync(local: local, remote: remote, journal: journal)
        try await engine.link(threadID: local.document.threadID, pageID: remote.page.pageID)
        let preview = try await engine.prepare(threadID: local.document.threadID)
        #expect(preview.disposition == .initialReview); #expect(remote.writes == 0)
        try await engine.confirmPush(preview)
        #expect(remote.writes == 1)
        #expect(try await engine.prepare(threadID: local.document.threadID).disposition == .upToDate)
        local.generation += 1; local.document.nextAction = "Local change"
        var edited = try ProjectMemoryDocument.parse(remote.page.markdown); edited.nextAction = "Remote change"
        remote.page.markdown = try edited.markdown()
        let conflict = try await engine.prepare(threadID: local.document.threadID)
        #expect(conflict.disposition == .conflict)
        await #expect(throws: MemorySyncError.remoteChanged) { try await engine.confirmPush(conflict) }
        await #expect(throws: MemorySyncError.localChanged) { try await engine.confirmImport(conflict) }
        #expect(remote.writes == 1); #expect(local.document.nextAction == "Local change")
        let reopened = try MemorySyncJournal(directory: url)
        #expect(reopened.mapping(for: local.document.threadID)?.review?.remoteMarkdown == remote.page.markdown)
    }

    @Test func explicitMergeKeepsUploadAsSeparateConfirmation() async throws {
        let url = directory(); defer { try? FileManager.default.removeItem(at: url) }
        let local = MemoryLocalFixture(), remote = MemoryRemoteFixture()
        let engine = ProjectMemorySync(local: local, remote: remote, journal: try MemorySyncJournal(directory: url))
        try await engine.link(threadID: local.document.threadID, pageID: remote.page.pageID)
        let initial = try await engine.prepare(threadID: local.document.threadID)
        try await engine.confirmPush(initial)
        local.generation += 1; local.document.currentState = "Local progress"
        var edited = local.document; edited.nextAction = "Remote next step"
        remote.page.markdown = try edited.markdown()
        let conflict = try await engine.prepare(threadID: local.document.threadID)
        var merged = conflict.local.document; merged.nextAction = edited.nextAction
        try await engine.confirmReconciliation(conflict, merged: merged)
        #expect(remote.writes == 1)
        #expect(local.document.currentState == "Local progress")
        #expect(local.document.nextAction == "Remote next step")
        let reviewed = try await engine.prepare(threadID: local.document.threadID)
        #expect(reviewed.disposition == .initialReview)
        try await engine.confirmPush(reviewed)
        #expect(remote.writes == 2)
    }

    @Test func remoteChangeNeedsExplicitImportAndStalePreviewCannotWrite() async throws {
        let url = directory(); defer { try? FileManager.default.removeItem(at: url) }
        let local = MemoryLocalFixture(), remote = MemoryRemoteFixture()
        let engine = ProjectMemorySync(local: local, remote: remote, journal: try MemorySyncJournal(directory: url))
        try await engine.link(threadID: local.document.threadID, pageID: remote.page.pageID)
        try await engine.confirmPush(engine.prepare(threadID: local.document.threadID))
        var edited = local.document; edited.nextAction = "Reviewed remote next step"
        remote.page.markdown = try edited.markdown()
        let preview = try await engine.prepare(threadID: local.document.threadID)
        #expect(preview.disposition == .remoteChanges)
        #expect(local.document.nextAction == "Review UI")
        try await engine.confirmImport(preview)
        #expect(local.document.nextAction == edited.nextAction)
        local.generation += 1
        let push = try await engine.prepare(threadID: local.document.threadID)
        local.generation += 1
        await #expect(throws: MemorySyncError.localChanged) { try await engine.confirmPush(push) }
        #expect(remote.writes == 1)
    }

    @Test func lostWriteResponseReconcilesAfterRestartWithoutDuplicateWrite() async throws {
        let url = directory(); defer { try? FileManager.default.removeItem(at: url) }
        let local = MemoryLocalFixture(), remote = MemoryRemoteFixture()
        let engine = ProjectMemorySync(local: local, remote: remote, journal: try MemorySyncJournal(directory: url))
        try await engine.link(threadID: local.document.threadID, pageID: remote.page.pageID)
        let preview = try await engine.prepare(threadID: local.document.threadID)
        remote.loseNextWriteResponse = true
        await #expect(throws: MemorySyncError.uncertainWrite) { try await engine.confirmPush(preview) }
        let reopened = try MemorySyncJournal(directory: url)
        #expect(reopened.mapping(for: local.document.threadID)?.pendingWrite != nil)
        let resumed = ProjectMemorySync(local: local, remote: remote, journal: reopened)
        #expect(try await resumed.prepare(threadID: local.document.threadID).disposition == .upToDate)
        #expect(reopened.mapping(for: local.document.threadID)?.pendingWrite == nil)
        #expect(remote.writes == 1)
    }

    @Test func externalMetadataChangesAreNotOverwritten() throws {
        let url = directory(); defer { try? FileManager.default.removeItem(at: url) }
        let a = try MemorySyncJournal(directory: url), b = try MemorySyncJournal(directory: url)
        let mapping = MemorySyncMapping(threadID: UUID(), pageID: UUID())
        try a.save(mapping)
        #expect(throws: MemorySyncError.metadataChanged) { try b.save(MemorySyncMapping(threadID: UUID(), pageID: UUID())) }
        try b.reload(); #expect(b.mapping(for: mapping.threadID) == mapping)
        #expect(throws: MemorySyncError.alreadyLinked) { try b.save(MemorySyncMapping(threadID: UUID(), pageID: mapping.pageID)) }
    }

    @Test func localImportPreservesEvidenceTasksAndAuthoredUnknownSections() throws {
        let url = directory(), name = "MemorySyncTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: url) }
        let store = ThreadStore(directory: url), workspace = WorkspaceStore(defaults: defaults)
        let event = ProgressEvent(summary: "Original fact")
        let thread = ThreadRecord(title: "Original", resumePoint: "Legacy note", progressEvents: [event])
        try store.save(thread)
        let file = store.fileURL(for: thread.id)
        var source = try String(contentsOf: file, encoding: .utf8)
        source += "\n## Independent prose\n\nKeep this exactly.\n"
        try source.write(to: file, atomically: true, encoding: .utf8); try store.reload()
        workspace.addTask("Independent task", toToday: false)
        let tasks = workspace.tasks
        let repository = LocalMarkdownMemoryRepository(threads: store, workspace: workspace)
        let before = try repository.snapshot(threadID: thread.id)
        var incoming = before.document; incoming.nextAction = "A reviewed update"
        _ = try repository.applyReviewed(incoming, expectedRevision: before.revision)
        #expect(store.threads[0].progressEvents.first == event)
        #expect(store.threads[0].progressEvents.count == 2)
        #expect(store.threads[0].resumePoint == "Legacy note")
        #expect(workspace.tasks == tasks)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("Keep this exactly."))
        #expect(throws: MemorySyncError.localChanged) { try repository.applyReviewed(incoming, expectedRevision: before.revision) }
    }

    @Test func transportUsesVersionAndV2AndHonoursRetryAfter() async throws {
        let fixture = NotionTransportFixture(), page = RemoteMemoryPage(pageID: UUID(), markdown: "")
        fixture.replies = [(429, Data("{}".utf8), ["Retry-After": "7"]), (200, try response(page), [:])]
        var delays: [Double] = []
        let client = NotionMarkdownClient(transport: fixture, token: { "fixture-token" }, sleep: { delays.append($0) })
        #expect(try await client.retrieve(pageID: page.pageID) == page)
        #expect(delays == [7]); #expect(fixture.requests.count == 2)
        #expect(fixture.requests[0].value(forHTTPHeaderField: "Notion-Version") == "2026-03-11")
        #expect(fixture.requests[0].url?.query == "markdown_version=v2")
    }

    @Test func unavailableCredentialsNeverSendRequest() async throws {
        let fixture = NotionTransportFixture()
        let client = NotionMarkdownClient(transport: fixture, token: { nil })
        await #expect(throws: MemorySyncError.notConnected) { try await client.retrieve(pageID: UUID()) }
        #expect(fixture.requests.isEmpty)
    }

    @Test func incompleteAndWarningResponsesAreNotSuccess() async throws {
        for warnings in [false, true] {
            let fixture = NotionTransportFixture(), page = RemoteMemoryPage(pageID: UUID(), markdown: "")
            fixture.replies = [(200, try response(page, truncated: !warnings, warnings: warnings), [:])]
            let client = NotionMarkdownClient(transport: fixture, token: { "fixture-token" })
            await #expect(throws: warnings ? MemorySyncError.remoteWarnings : .incompleteRemote) {
                try await client.retrieve(pageID: page.pageID)
            }
        }
    }

    @Test func writeUsesExactMatchAndDoesNotRetryAmbiguousServerFailure() async throws {
        let fixture = NotionTransportFixture()
        let document = ProjectMemoryDocument(thread: ThreadRecord(title: "Before"), tasks: [])
        let page = RemoteMemoryPage(pageID: UUID(), markdown: try document.markdown())
        fixture.replies = [(200, try response(page), [:]), (503, Data("{}".utf8), [:])]
        let client = NotionMarkdownClient(transport: fixture, token: { "fixture-token" }, sleep: { _ in })
        var next = document; next.nextAction = "Next"
        await #expect(throws: MemorySyncError.uncertainWrite) {
            try await client.replace(pageID: page.pageID, expected: page, markdown: next.markdown())
        }
        #expect(fixture.requests.count == 2)
        let body = try #require(JSONSerialization.jsonObject(with: fixture.requests[1].httpBody!) as? [String: Any])
        #expect(body["type"] as? String == "update_content")
        #expect(body["allow_async"] as? Bool == false)
        let update = try #require(body["update_content"] as? [String: Any])
        let operations = try #require(update["content_updates"] as? [[String: String]])
        #expect(operations.first?["old_str"] == page.markdown)
        #expect(update["allow_deleting_content"] as? Bool == false)
    }

    @Test func emptyPageUsesNonDestructiveAppend() async throws {
        let fixture = NotionTransportFixture()
        let empty = RemoteMemoryPage(pageID: UUID(), markdown: "")
        let value = ProjectMemoryDocument(thread: ThreadRecord(title: "New"), tasks: [])
        let saved = RemoteMemoryPage(pageID: empty.pageID, markdown: try value.markdown())
        fixture.replies = [(200, try response(empty), [:]), (200, try response(saved), [:])]
        let client = NotionMarkdownClient(transport: fixture, token: { "fixture-token" })
        #expect(try await client.replace(pageID: empty.pageID, expected: empty, markdown: value.markdown()) == saved)
        let body = try #require(JSONSerialization.jsonObject(with: fixture.requests[1].httpBody!) as? [String: Any])
        #expect(body["type"] as? String == "insert_content")
    }
}
