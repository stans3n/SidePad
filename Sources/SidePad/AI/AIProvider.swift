import Foundation

/// Extracted attachment text only. The request never contains unrestricted file paths or bytes.
struct AIInputAttachment: Codable, Sendable, Equatable {
    var name: String
    var type: String
    var extraction: String
    var text: String
    var notice: String
}

struct AIParseRequest: Sendable {
    var input: String
    var contextJSON: String
    var now: Date
    var timeZone: TimeZone
    var attachments: [AIInputAttachment]

    init(input: String, contextJSON: String = "{}", now: Date = Date(), timeZone: TimeZone = .current, attachments: [AIInputAttachment] = []) {
        self.input = input
        self.contextJSON = contextJSON
        self.now = now
        self.timeZone = timeZone
        self.attachments = attachments
    }
}

protocol AIProvider: Sendable {
    /// Returns untrusted JSON. Only IntentValidator and ActionExecutor may apply it.
    func parse(_ request: AIParseRequest) async throws -> Data
}

enum AIProviderKind: String, Codable, CaseIterable, Identifiable {
    case deepSeek, codexCLI, offline
    var id: String { rawValue }
    var title: String {
        switch self {
        case .deepSeek: return "DeepSeek V4.1 Flash"
        case .codexCLI: return "Codex CLI"
        case .offline: return "离线"
        }
    }
}

enum AIProviderError: LocalizedError, Equatable {
    case missingKey, unauthorized, forbidden, rateLimited, timedOut, malformedResponse, outputTooLarge
    case serverUnavailable(Int), requestRejected(Int), networkUnavailable
    case invalidConfiguration(String), missingResource(String), keychain(Int32)
    case cliUnavailable, cliUnauthenticated, cliUnsupported(String), cliFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "请先在设置 > AI Providers 中保存 DeepSeek API Key 并测试连接。手动任务仍可使用。"
        case .unauthorized: return "DeepSeek 拒绝了 API Key（401），请更新密钥。"
        case .forbidden: return "DeepSeek 拒绝访问（403），请检查账户和模型权限。"
        case .rateLimited: return "DeepSeek 请求过于频繁（429），请稍后重试。"
        case .timedOut: return "解析超时，请重试或增加设置中的超时时间。"
        case .malformedResponse: return "AI 返回了空白、不完整或无效的 JSON；未执行任何操作。"
        case .outputTooLarge: return "AI 响应超出大小限制；未执行任何操作。"
        case .serverUnavailable(let code): return "DeepSeek 暂时不可用（\(code)），请稍后重试。"
        case .requestRejected(let code): return "DeepSeek 请求失败（\(code)），请检查 API 地址和模型。"
        case .networkUnavailable: return "无法连接 AI 服务，请检查网络后重试。手动任务仍可使用。"
        case .invalidConfiguration(let reason): return reason
        case .missingResource(let name): return "应用缺少 AI 资源：\(name)。请重新构建应用。"
        case .keychain(let status): return "无法访问 macOS 钥匙串（\(status)）；密钥未写入普通设置文件。"
        case .cliUnavailable: return "未找到 Codex CLI。请安装并登录，或在设置中填写可执行文件路径。"
        case .cliUnauthenticated: return "Codex CLI 尚未登录。请在终端运行 codex login，SidePad 不会读取或复制登录凭证。"
        case .cliUnsupported(let reason): return "此环境不能安全运行 Codex CLI：\(reason)。可使用 DeepSeek 或手动编辑。"
        case .cliFailed(let code): return "Codex CLI 执行失败（\(code)）。请检查终端中的 CLI 登录和网络状态。"
        }
    }
}

enum AIResources {
    static let maximumResponseBytes = 262_144

    static func url(_ name: String, extension ext: String) throws -> URL {
        // A signed .app keeps resources inside Contents/Resources, not its sealed root.
        if let directory = Bundle.main.resourceURL,
           let packaged = Bundle(url: directory.appendingPathComponent("SidePad_SidePad.bundle")),
           let url = packaged.url(forResource: name, withExtension: ext) { return url }
        guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {
            throw AIProviderError.missingResource("\(name).\(ext)")
        }
        return url
    }

    static func systemPrompt() throws -> String {
        let prompt = try String(contentsOf: url("IntentParser_v2", extension: "md"), encoding: .utf8)
        let schema = try String(contentsOf: url("IntentSchema_v2", extension: "json"), encoding: .utf8)
        let examples = try String(contentsOf: url("IntentExamples_v2", extension: "json"), encoding: .utf8)
        return prompt + "\n\nJSON Schema:\n" + schema + "\n\nJSON examples:\n" + examples
    }

    static func userPayload(_ request: AIParseRequest) throws -> String {
        guard !request.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.input.utf8.count <= 16_384, request.contextJSON.utf8.count <= 32_768, request.attachments.count <= 5,
              request.attachments.reduce(0, { $0 + $1.text.utf8.count }) <= 24_576,
              request.attachments.allSatisfy({ $0.name.utf8.count <= 512 && $0.type.count <= 64 && $0.extraction.count <= 128 && $0.notice.utf8.count <= 2048 }) else {
            throw AIProviderError.invalidConfiguration("输入为空或过长；请缩短输入或减少上下文。")
        }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.calendar = Calendar(identifier: .gregorian)
        day.timeZone = request.timeZone
        day.dateFormat = "yyyy-MM-dd"
        // Context and capture text are JSON string values, never prompt instructions or CLI arguments.
        var payload: [String: Any] = [
            "input": request.input, "context_json": request.contextJSON,
            "local_date": day.string(from: request.now), "time_zone": request.timeZone.identifier
        ]
        if !request.attachments.isEmpty {
            payload["attachments"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request.attachments))
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
    }

    static func checkedJSON(_ data: Data) throws -> Data {
        guard data.count <= maximumResponseBytes else { throw AIProviderError.outputTooLarge }
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw AIProviderError.malformedResponse
        }
        return data
    }
}
