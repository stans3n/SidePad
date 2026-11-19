import Foundation
import Testing
@testable import SidePad

@Suite(.serialized)
@MainActor
struct ProviderReadinessTests {
    @Test func verificationIsRequiredPersistedAndInvalidatedByChangesOrFailure() throws {
        let name = "SidePad.Readiness." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AISettingsStore(defaults: defaults)
        #expect(!settings.canUseAICapture)
        settings.provider = .codexCLI
        #expect(!settings.canUseAICapture)
        settings.recordCaptureSuccess()
        #expect(settings.canUseAICapture)
        #expect(AISettingsStore(defaults: defaults).canUseAICapture)
        settings.codexPath = "/different/configuration"
        #expect(!settings.canUseAICapture)
        settings.recordCaptureSuccess()
        settings.recordCaptureFailure(AIProviderError.cliUnsupported("Synthetic test failure"))
        #expect(!settings.canUseAICapture)
        settings.recordCaptureSuccess()
        settings.recordCaptureFailure(CancellationError())
        #expect(settings.canUseAICapture)
        settings.provider = .offline
        settings.recordCaptureSuccess()
        #expect(!settings.canUseAICapture)
    }

    @Test func oldVerificationExpiresAndAStoredKeyFlagDoesNotEnableCapture() throws {
        let name = "SidePad.Readiness." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AISettingsStore(defaults: defaults)
        settings.provider = .codexCLI
        settings.recordCaptureSuccess()
        defaults.set(Date().addingTimeInterval(-86_401), forKey: "SidePad.ai.verifiedAt")
        #expect(!AISettingsStore(defaults: defaults).canUseAICapture)
        settings.provider = .deepSeek
        settings.recordCaptureSuccess()
        #expect(!settings.canUseAICapture) // No current Keychain availability check.
    }

    @Test func liveProbeOptionsBoundRequestsAndOutput() async throws {
        actor Counter {
            var count = 0
            var tokens: Int?
            func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
                count += 1
                tokens = (try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])?["max_tokens"] as? Int
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
            }
        }
        let counter = Counter()
        let provider = DeepSeekProvider(apiKey: "synthetic-test-only", maximumAttempts: 1, maximumOutputTokens: 1536,
            transport: { try await counter.respond($0) })
        await #expect(throws: AIProviderError.serverUnavailable(503)) { _ = try await provider.parse(.init(input: "Add task: Test")) }
        #expect(await counter.count == 1)
        #expect(await counter.tokens == 1536)
    }
}
