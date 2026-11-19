import Foundation
import Combine

@MainActor
final class AISettingsStore: ObservableObject {
    @Published var provider: AIProviderKind { didSet { defaults.set(provider.rawValue, forKey: prefix + "provider"); invalidateVerification() } }
    @Published var baseURL: String { didSet { defaults.set(baseURL, forKey: prefix + "baseURL"); invalidateVerification() } }
    @Published var model: String { didSet { defaults.set(model, forKey: prefix + "model"); invalidateVerification() } }
    @Published var timeout: Double { didSet { defaults.set(timeout, forKey: prefix + "timeout"); invalidateVerification() } }
    @Published var codexPath: String { didSet { defaults.set(codexPath, forKey: prefix + "codexPath"); invalidateVerification() } }
    @Published private(set) var apiKeyConfigured = false
    @Published private(set) var status: String?
    @Published private(set) var isTesting = false
    private let defaults: UserDefaults
    private let credentials = CredentialStore()
    private let prefix = "SidePad.ai."
    private var testTask: Task<Void, Never>?
    @Published private(set) var verifiedAt: Date?
    private var verifiedConfiguration: String?
    private var configurationRevision = UUID()

    private var configuration: String {
        [provider.rawValue, baseURL, model, String(timeout), codexPath].joined(separator: "\n")
    }

    var canUseAICapture: Bool {
        guard provider != .offline, !isTesting, verifiedConfiguration == configuration,
              let verifiedAt, (0..<86_400).contains(Date().timeIntervalSince(verifiedAt)) else { return false }
        return provider != .deepSeek || apiKeyConfigured
    }

    var captureAvailabilityMessage: String {
        if isTesting { return "Checking provider…" }
        if provider == .offline { return "Choose DeepSeek or Codex CLI in Settings. Manual tasks remain available." }
        if canUseAICapture { return "\(provider.title) · Connection verified" }
        return "Check the \(provider.title) connection in Settings to enable AI capture."
    }

    private func invalidateVerification() {
        configurationRevision = UUID()
        verifiedAt = nil; verifiedConfiguration = nil
        defaults.removeObject(forKey: prefix + "verifiedAt")
        defaults.removeObject(forKey: prefix + "verifiedConfiguration")
    }

    func recordCaptureSuccess() {
        verifiedAt = Date(); verifiedConfiguration = configuration
        defaults.set(verifiedAt, forKey: prefix + "verifiedAt")
        defaults.set(configuration, forKey: prefix + "verifiedConfiguration")
    }

    func recordCaptureFailure(_ error: Error) {
        guard !(error is CancellationError) else { return }
        if error is AIProviderError || error is URLError {
            invalidateVerification()
            status = error.localizedDescription
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        provider = defaults.string(forKey: prefix + "provider").flatMap(AIProviderKind.init(rawValue:)) ?? .deepSeek
        baseURL = defaults.string(forKey: prefix + "baseURL") ?? "https://api.deepseek.com"
        model = defaults.string(forKey: prefix + "model") ?? "deepseek-flash"
        let savedTimeout = defaults.double(forKey: prefix + "timeout")
        timeout = savedTimeout.isFinite && savedTimeout >= 5 && savedTimeout <= 120 ? savedTimeout : 30
        codexPath = defaults.string(forKey: prefix + "codexPath") ?? ""
        verifiedAt = defaults.object(forKey: prefix + "verifiedAt") as? Date
        verifiedConfiguration = defaults.string(forKey: prefix + "verifiedConfiguration")
        // Keychain is queried when AI settings open, avoiding a credential prompt at app launch.
    }

    func refreshCredentialStatus() {
        do { apiKeyConfigured = try credentials.hasAPIKey(); if !apiKeyConfigured && provider == .deepSeek { invalidateVerification() } }
        catch { status = error.localizedDescription }
    }

    func saveAPIKey(_ key: String) throws {
        try credentials.saveAPIKey(key)
        invalidateVerification()
        apiKeyConfigured = true
        status = "API Key 已保存到 macOS 钥匙串。"
    }

    func removeAPIKey() throws {
        try credentials.removeAPIKey()
        invalidateVerification()
        apiKeyConfigured = false
        status = "API Key 已从 macOS 钥匙串删除。"
    }

    func makeProvider() throws -> any AIProvider {
        switch provider {
        case .deepSeek:
            guard let key = try credentials.readAPIKey(), !key.isEmpty else { throw AIProviderError.missingKey }
            return DeepSeekProvider(apiKey: key, baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                                    model: model.trimmingCharacters(in: .whitespacesAndNewlines), timeout: timeout)
        case .codexCLI: return CodexCLIProvider(executablePath: codexPath, timeout: timeout)
        case .offline: throw AIProviderError.invalidConfiguration("离线解析由 Threads 工作区直接提供。")
        }
    }

    func testConnection() {
        guard !isTesting else { return }
        isTesting = true
        status = nil
        let testedConfiguration = configuration
        let testedRevision = configurationRevision
        testTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isTesting = false; self.testTask = nil }
            do {
                if self.provider == .offline { self.status = "离线模式无需网络或密钥。"; return }
                let provider = try self.makeProvider()
                let result = try await provider.parse(AIParseRequest(input: "Add a standalone task titled Connection test. Do not use any tools.", contextJSON: "{\"threads\":[],\"tasks\":[]}"))
                let plan = try IntentValidator.decode(result)
                _ = try IntentValidator.prepare(plan, threads: [], tasks: [], selectedThreadID: nil)
                guard testedConfiguration == self.configuration, testedRevision == self.configurationRevision, !Task.isCancelled else { return }
                self.recordCaptureSuccess()
                self.status = "连接成功，已收到有效的结构化响应；未创建任何任务。"
            } catch is CancellationError { self.status = "连接测试已取消。" }
            catch {
                if testedRevision == self.configurationRevision { self.recordCaptureFailure(error); self.status = error.localizedDescription }
            }
        }
    }

    func checkCodex() {
        guard !isTesting else { return }
        isTesting = true
        status = nil
        let testedConfiguration = configuration
        let testedRevision = configurationRevision
        testTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isTesting = false; self.testTask = nil }
            do {
                let message = try await CodexCLIProvider(executablePath: codexPath, timeout: timeout).checkAvailability()
                guard testedConfiguration == self.configuration, testedRevision == self.configurationRevision, !Task.isCancelled else { return }
                self.recordCaptureSuccess()
                self.status = message
            }
            catch is CancellationError { self.status = "检查已取消。" }
            catch {
                if testedRevision == self.configurationRevision { self.recordCaptureFailure(error); self.status = error.localizedDescription }
            }
        }
    }

    func cancelTest() { testTask?.cancel() }
}
