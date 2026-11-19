import Foundation
import Testing
@testable import SidePad

@Suite(.serialized)
@MainActor
struct CaptureConfirmationTests {
    @MainActor
    private struct Fixture {
        let directory: URL
        let suiteName: String
        let defaults: UserDefaults
        let workspace: WorkspaceStore
        let threads: ThreadStore
        let coordinator: ThreadsCoordinator

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("SidePadCapture-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            suiteName = "SidePadCaptureTests." + UUID().uuidString
            defaults = UserDefaults(suiteName: suiteName)!
            workspace = WorkspaceStore(defaults: defaults)
            threads = ThreadStore(directory: directory)
            let settings = AISettingsStore(defaults: defaults)
            settings.provider = .offline
            coordinator = ThreadsCoordinator(workspace: workspace, threads: threads, settings: settings)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        var markdownFiles: [URL] {
            get throws {
                try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "md" }
            }
        }
    }

    @Test func highConfidenceOfflineThreadWaitsForExplicitConfirmation() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let before = fixture.defaults.data(forKey: "SidePad.workspace.v4")
        #expect(await fixture.coordinator.captureLegacyOffline("项目：Launch plan") == false)
        let plan = try #require(fixture.coordinator.pendingPlan)
        #expect(plan.confidence == 1)
        #expect(fixture.threads.threads.isEmpty && fixture.workspace.tasks.isEmpty)
        #expect(try fixture.markdownFiles.isEmpty)
        #expect(fixture.defaults.data(forKey: "SidePad.workspace.v4") == before)

        try fixture.coordinator.confirmPending()
        #expect(fixture.threads.threads.map(\.title) == ["Launch plan"])
        #expect(fixture.coordinator.pendingPlan == nil)
        let first = try #require(fixture.threads.threads.first)
        try fixture.coordinator.confirmPending()
        #expect(fixture.threads.threads.count == 1 && fixture.threads.threads[0].id == first.id)
        #expect(try fixture.markdownFiles.count == 1)
        try fixture.coordinator.undo()
        #expect(fixture.threads.threads.isEmpty && fixture.workspace.tasks.isEmpty)
    }

    @Test func discardAndCancelNeverApplyPendingCreations() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        _ = await fixture.coordinator.captureLegacyOffline("项目：Discard this")
        #expect(fixture.coordinator.pendingPlan != nil)
        fixture.coordinator.discardPending()
        try fixture.coordinator.confirmPending()
        #expect(fixture.threads.threads.isEmpty)

        _ = await fixture.coordinator.captureLegacyOffline("task: Cancel this")
        #expect(fixture.coordinator.pendingPlan != nil)
        fixture.coordinator.cancel()
        #expect(fixture.coordinator.pendingPlan == nil)
        try fixture.coordinator.confirmPending()
        #expect(fixture.workspace.tasks.isEmpty)
        #expect(try fixture.markdownFiles.isEmpty)
    }

    @Test func confirmedTaskCannotBeCreatedAgainByRepeatedCapture() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        _ = await fixture.coordinator.captureLegacyOffline("task: Review the release")
        #expect(fixture.workspace.tasks.isEmpty)
        #expect(fixture.coordinator.pendingSummary.contains("Review the release"))
        try fixture.coordinator.confirmPending()
        let first = try #require(fixture.workspace.tasks.first)
        try fixture.coordinator.confirmPending()
        #expect(fixture.workspace.tasks.count == 1)

        _ = await fixture.coordinator.captureLegacyOffline("task: REVIEW   THE RELEASE")
        #expect(fixture.coordinator.pendingPlan == nil)
        #expect(fixture.coordinator.errorMessage != nil)
        #expect(fixture.workspace.tasks.map(\.id) == [first.id])
        let restarted = WorkspaceStore(defaults: fixture.defaults)
        #expect(restarted.tasks.map(\.id) == [first.id])
    }

    @Test func confirmationRejectsTaskChangesSinceThePreview() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        _ = await fixture.coordinator.captureLegacyOffline("task: Proposed task")
        #expect(fixture.coordinator.pendingPlan != nil)
        fixture.workspace.addTask("Keep manual work", toToday: true)
        #expect(throws: IntentError.stale) { try fixture.coordinator.confirmPending() }
        #expect(fixture.workspace.tasks.map(\.title) == ["Keep manual work"])
        #expect(try fixture.markdownFiles.isEmpty)
    }

    @Test func confirmationPreservesAnExternalMarkdownEditAndCreatesNoTask() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let thread = ThreadRecord(title: "Existing")
        try fixture.threads.save(thread)
        fixture.coordinator.selectedThreadID = thread.id
        _ = await fixture.coordinator.captureLegacyOffline("task: Proposed task")
        #expect(fixture.coordinator.pendingPlan != nil)
        let url = fixture.threads.fileURL(for: thread.id)
        let edited = try String(contentsOf: url, encoding: .utf8) + "\nExternal editor note\n"
        try edited.write(to: url, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) { try fixture.coordinator.confirmPending() }
        #expect(fixture.workspace.tasks.isEmpty)
        #expect(try String(contentsOf: url, encoding: .utf8) == edited)
    }

    @Test func ambiguousOfflineInputHasNoPreviewAndNoWrites() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        _ = await fixture.coordinator.captureLegacyOffline("更新项目并删除所有任务")
        #expect(fixture.coordinator.pendingPlan == nil)
        #expect(fixture.coordinator.errorMessage != nil)
        #expect(fixture.workspace.tasks.isEmpty && fixture.threads.threads.isEmpty)
        #expect(try fixture.markdownFiles.isEmpty)
    }
}
