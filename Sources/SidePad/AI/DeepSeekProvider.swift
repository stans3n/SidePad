import Foundation

struct DeepSeekProvider: AIProvider {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    let baseURL: String
    let model: String
    let timeout: TimeInterval
    let maximumAttempts: Int
    let maximumOutputTokens: Int
    private let apiKey: String
    private let transport: Transport
    private let sleep: Sleeper

    init(apiKey: String, baseURL: String = "https://api.deepseek.com", model: String = "deepseek-flash",
         timeout: TimeInterval = 30, maximumAttempts: Int = 3, maximumOutputTokens: Int = 8192, transport: Transport? = nil, sleep: Sleeper? = nil) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
        self.maximumAttempts = min(3, max(1, maximumAttempts))
        self.maximumOutputTokens = min(8192, max(256, maximumOutputTokens))
        self.transport = transport ?? { try await Self.send($0) }
        self.sleep = sleep ?? { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    }

    func parse(_ request: AIParseRequest) async throws -> Data {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIProviderError.missingKey }
        guard timeout.isFinite, timeout > 0, timeout <= 300,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: baseURL), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw AIProviderError.invalidConfiguration("请填写有效的 HTTPS API 地址、模型和超时时间。")
        }
        let endpoint = url.appendingPathComponent("chat/completions")
        var http = URLRequest(url: endpoint)
        http.httpMethod = "POST"
        http.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": false, "max_tokens": maximumOutputTokens,
            "thinking": ["type": "disabled"], "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": try AIResources.systemPrompt()],
                ["role": "user", "content": try AIResources.userPayload(request)]
            ]
        ])
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        for attempt in 0..<maximumAttempts {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw AIProviderError.timedOut }
            http.timeoutInterval = remaining
            let result: (Data, HTTPURLResponse)
            do {
                result = try await withThrowingTaskGroup(of: HTTPResult.self) { group in
                    let currentRequest = http
                    group.addTask { let (data, response) = try await transport(currentRequest); return HTTPResult(data: data, response: response) }
                    group.addTask { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)); throw AIProviderError.timedOut }
                    defer { group.cancelAll() }
                    let first = try await group.next()!
                    return (first.data, first.response)
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError {
                if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
                if attempt + 1 < maximumAttempts && [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) {
                    try await backoff(attempt: attempt, retryAfter: nil, deadline: deadline)
                    continue
                }
                throw error.code == .timedOut ? AIProviderError.timedOut : AIProviderError.networkUnavailable
            }
            let (data, response) = result
            guard data.count <= 1_048_576 else { throw AIProviderError.outputTooLarge }
            switch response.statusCode {
            case 200...299:
                guard let envelope = try? JSONDecoder().decode(Completion.self, from: data),
                      let choice = envelope.choices.first, choice.finish_reason == "stop",
                      let text = choice.message.content, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AIProviderError.malformedResponse
                }
                return try AIResources.checkedJSON(Data(text.utf8))
            case 401: throw AIProviderError.unauthorized
            case 403: throw AIProviderError.forbidden
            case 408, 429, 500...599:
                guard attempt + 1 < maximumAttempts else {
                    if response.statusCode == 429 { throw AIProviderError.rateLimited }
                    if response.statusCode == 408 { throw AIProviderError.timedOut }
                    throw AIProviderError.serverUnavailable(response.statusCode)
                }
                try await backoff(attempt: attempt, retryAfter: response.value(forHTTPHeaderField: "Retry-After"), deadline: deadline)
            default: throw AIProviderError.requestRejected(response.statusCode)
            }
        }
        throw AIProviderError.networkUnavailable
    }

    private func backoff(attempt: Int, retryAfter: String?, deadline: TimeInterval) async throws {
        let requested = retryAfter.flatMap(Double.init) ?? (0.35 * pow(2, Double(attempt)))
        let delay = requested.isFinite ? min(5, max(0, requested)) : 0.35
        guard ProcessInfo.processInfo.systemUptime + delay < deadline else { throw AIProviderError.timedOut }
        try await sleep(delay)
    }

    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw AIProviderError.malformedResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw AIProviderError.outputTooLarge }
            data.append(byte)
        }
        return (data, response)
    }

    private struct HTTPResult: @unchecked Sendable { let data: Data; let response: HTTPURLResponse }
    private struct Completion: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
            let finish_reason: String?
        }
        let choices: [Choice]
    }
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil) // Never forward the credential to another endpoint.
        }
    }
}
