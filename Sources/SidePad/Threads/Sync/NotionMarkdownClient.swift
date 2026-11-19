import Foundation
import Security

struct RemoteMemoryPage: Equatable {
    var pageID: UUID
    var markdown: String
    var revision: String { MemoryRevision.hash(markdown) }
}

@MainActor
protocol MemoryRemoteRepository: AnyObject {
    func retrieve(pageID: UUID) async throws -> RemoteMemoryPage
    /// Re-checks the preview and uses exact-match editing. Notion does not offer an atomic ETag contract.
    func replace(pageID: UUID, expected: RemoteMemoryPage, markdown: String) async throws -> RemoteMemoryPage
}

@MainActor
protocol NotionHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionNotionTransport: NotionHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MemorySyncError.invalidResponse }
        return (data, http)
    }
}

/// An injectable token source keeps credentials out of Markdown, sync metadata, prompts and logs.
struct NotionKeychainCredentials {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.SidePad.Notion", kSecAttrAccount as String: "integration",
         kSecAttrSynchronizable as String: false]
    }
    func read() throws -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { throw MemorySyncError.notConnected }
        return token
    }
    func save(_ token: String) throws {
        guard !token.isEmpty, token.utf8.count <= 8_192,
              !token.contains(where: { $0.isWhitespace || $0 == "\0" }) else { throw MemorySyncError.notConnected }
        let values = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var value = query
            value[kSecValueData as String] = Data(token.utf8)
            value[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(value as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MemorySyncError.notConnected }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MemorySyncError.notConnected }
    }
}

/// No requests happen until explicitly invoked by a sync controller. No background timer or polling.
@MainActor
final class NotionMarkdownClient: MemoryRemoteRepository {
    static let apiVersion = "2026-03-11"
    private let transport: any NotionHTTPTransport
    private let token: () throws -> String?
    private let sleep: (Double) async throws -> Void
    private let maximumAttempts: Int

    init(transport: (any NotionHTTPTransport)? = nil,
         token: @escaping () throws -> String? = { try NotionKeychainCredentials().read() },
         maximumAttempts: Int = 3,
         sleep: @escaping (Double) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) {
        self.transport = transport ?? URLSessionNotionTransport(); self.token = token; self.maximumAttempts = max(1, min(5, maximumAttempts))
        self.sleep = sleep
    }

    func retrieve(pageID: UUID) async throws -> RemoteMemoryPage {
        var request = try request(pageID: pageID, method: "GET")
        request.url = URL(string: request.url!.absoluteString + "?markdown_version=v2")!
        return try decode(try await perform(request), pageID: pageID)
    }

    func replace(pageID: UUID, expected: RemoteMemoryPage, markdown: String) async throws -> RemoteMemoryPage {
        guard expected.pageID == pageID else { throw MemorySyncError.identityChanged }
        let latest = try await retrieve(pageID: pageID)
        guard latest.revision == expected.revision else { throw MemorySyncError.remoteChanged }
        var request = try request(pageID: pageID, method: "PATCH")
        let command: [String: Any]
        if expected.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Append rather than replace an empty page: a concurrent first edit must survive.
            command = ["type": "insert_content", "insert_content": ["content": markdown, "position": ["type": "end"]],
                       "markdown_version": "v2", "allow_async": false]
        } else {
            command = ["type": "update_content", "update_content": ["content_updates": [
                ["old_str": expected.markdown, "new_str": markdown]], "allow_deleting_content": false],
                       "markdown_version": "v2", "allow_async": false]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: command)
        guard request.httpBody!.count <= 450_000 else { throw MemorySyncError.requestTooLarge }
        let result = try decode(try await perform(request), pageID: pageID)
        // Any extra content, parser alteration or concurrent appended text becomes a review, never success.
        guard let wanted = try? ProjectMemoryDocument.parse(markdown),
              let actual = try? ProjectMemoryDocument.parse(result.markdown), wanted == actual else {
            throw MemorySyncError.uncertainWrite
        }
        return result
    }

    private func request(pageID: UUID, method: String) throws -> URLRequest {
        guard let key = try token(), !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0 == "\0" }) else {
            throw MemorySyncError.notConnected
        }
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/pages/\(pageID.uuidString.lowercased())/markdown")!)
        request.httpMethod = method; request.timeoutInterval = 30
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        for attempt in 0..<maximumAttempts {
            try Task.checkCancellation()
            let data: Data
            let response: HTTPURLResponse
            do { (data, response) = try await transport.send(request) }
            catch is CancellationError { throw CancellationError() }
            catch {
                if request.httpMethod != "GET" { throw MemorySyncError.uncertainWrite }
                guard attempt + 1 < maximumAttempts else { throw MemorySyncError.retryLimit }
                try await sleep(pow(2, Double(attempt))); continue
            }
            let code = response.statusCode
            if code == 200 { return data }
            if code == 401 || code == 403 || code == 404 { throw MemorySyncError.permissionDenied }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let additional = json?["additional_data"] as? [String: Any]
            if code == 429, additional?["rate_limit_reason"] as? String == "public_api_request_blocked" {
                throw MemorySyncError.http(code)
            }
            let rateLimited = code == 429 || code == 529
            let retryableRead = request.httpMethod == "GET" && [500, 502, 503, 504].contains(code)
            if rateLimited || retryableRead {
                guard attempt + 1 < maximumAttempts else { throw MemorySyncError.retryLimit }
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After") ?? additional?["retry_after"] as? String
                let serverDelay = retryAfter.flatMap(Double.init) ?? 0
                // Long workspace throttles are surfaced instead of holding the interface for minutes.
                guard serverDelay.isFinite, serverDelay <= 60 else { throw MemorySyncError.retryLimit }
                try await sleep(max(max(0, serverDelay), pow(2, Double(attempt))))
                continue
            }
            if request.httpMethod != "GET", code >= 500 || code == 202 { throw MemorySyncError.uncertainWrite }
            throw MemorySyncError.http(code)
        }
        throw MemorySyncError.retryLimit
    }

    private func decode(_ data: Data, pageID: UUID) throws -> RemoteMemoryPage {
        struct Response: Decodable {
            var object: String; var id: UUID; var markdown: String; var truncated: Bool
            var unknown_block_ids: [UUID]
            var warnings: [Warning]?
        }
        struct Warning: Decodable { var code: String }
        guard data.count <= 1_000_000,
              let result = try? JSONDecoder().decode(Response.self, from: data),
              result.object == "page_markdown", result.id == pageID else { throw MemorySyncError.invalidResponse }
        guard !result.truncated, result.unknown_block_ids.isEmpty,
              !result.markdown.contains("<unknown") else { throw MemorySyncError.incompleteRemote }
        guard result.warnings?.isEmpty != false else { throw MemorySyncError.remoteWarnings }
        return RemoteMemoryPage(pageID: result.id, markdown: result.markdown)
    }
}
