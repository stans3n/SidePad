import Foundation
import Security
import Darwin

struct CodexCLIProvider: AIProvider {
    struct Invocation: Sendable {
        let executable: URL
        let arguments: [String]
        let directory: URL
        let input: Data
        let timeout: TimeInterval
        var outputLimit = 524_288
    }
    struct Result: Sendable { let status: Int32; let stdout: Data; let stderr: Data }
    typealias Runner = @Sendable (Invocation) async throws -> Result

    var executablePath: String
    var timeout: TimeInterval
    private let runner: Runner

    init(executablePath: String = "", timeout: TimeInterval = 30, runner: Runner? = nil) {
        self.executablePath = executablePath
        self.timeout = timeout
        self.runner = runner ?? { try await CodexSubprocess.run($0) }
    }

    static var isAppSandboxed: Bool {
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil { return true }
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return entitlements["com.apple.security.app-sandbox"] as? Bool == true
    }

    static func discoverExecutable(configuredPath: String = "") -> URL? {
        let fm = FileManager.default
        let custom = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            let expanded = NSString(string: custom).expandingTildeInPath
            guard expanded.hasPrefix("/"), fm.isExecutableFile(atPath: expanded) else { return nil }
            return URL(fileURLWithPath: expanded)
        }
        let home = fm.homeDirectoryForCurrentUser
        var paths = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        paths += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).appendingPathComponent("codex") }
            .first { fm.isExecutableFile(atPath: $0.path) }
    }

    func checkAvailability() async throws -> String {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, _) = try await capabilities(directory: directory)
        return "已检测到 Codex CLI 和登录状态；请用“测试连接”验证受限解析。"
    }

    func parse(_ request: AIParseRequest) async throws -> Data {
        guard timeout.isFinite, timeout > 0, timeout <= 300 else {
            throw AIProviderError.invalidConfiguration("Codex 超时时间必须在 0–300 秒之间。")
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (executable, disabledFeatures) = try await capabilities(directory: directory)
        let workingDirectory = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: false)
        let instructions = directory.appendingPathComponent("instructions.md")
        try Data(AIResources.systemPrompt().utf8).write(to: instructions, options: .atomic)
        let output = directory.appendingPathComponent("intent.json")
        let arguments = try Self.parsingArguments(directory: workingDirectory, instructions: instructions,
                                                  output: output, disabledFeatures: disabledFeatures)
        let result = try await runner(Invocation(executable: executable, arguments: arguments, directory: workingDirectory,
                                                input: Data(try AIResources.userPayload(request).utf8), timeout: timeout))
        try Task.checkCancellation()
        guard result.status == 0 else {
            let diagnostic = String(decoding: result.stderr, as: UTF8.self)
            if diagnostic.contains("unknown configuration field") || diagnostic.contains("Unknown feature") {
                throw AIProviderError.cliUnsupported("当前 CLI 不支持所需的工具禁用配置；未降低安全限制")
            }
            throw AIProviderError.cliFailed(result.status)
        }
        // Tool attempts are a protocol violation even when the CLI sandbox denied them.
        for line in String(decoding: result.stdout, as: UTF8.self).split(separator: "\n") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let item = event["item"] as? [String: Any], let type = item["type"] as? String else { continue }
            guard ["agent_message", "reasoning"].contains(type) else {
                throw AIProviderError.cliUnsupported("CLI 尝试使用解析范围之外的工具")
            }
        }
        guard let size = try? output.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), size.isRegularFile == true,
              let count = size.fileSize else { throw AIProviderError.malformedResponse }
        guard count <= AIResources.maximumResponseBytes else { throw AIProviderError.outputTooLarge }
        return try AIResources.checkedJSON(Data(contentsOf: output))
    }

    private func temporaryDirectory() throws -> URL {
        guard !Self.isAppSandboxed else {
            throw AIProviderError.cliUnsupported("当前 SidePad 使用 App Sandbox，外部 CLI 功能未开放")
        }
        // Managed configuration can add compulsory hooks or MCP servers. This prototype refuses it.
        let managedFiles = ["/etc/codex/config.toml", "/etc/codex/managed_config.toml", "/etc/codex/requirements.toml",
                            "/Library/Managed Preferences/com.openai.codex.plist",
                            "/Library/Managed Preferences/com.openai.chat.plist"]
        if managedFiles.contains(where: FileManager.default.fileExists(atPath:)) {
            throw AIProviderError.cliUnsupported("检测到受管理的 Codex 配置，无法确认工具已全部关闭")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SidePad-Intent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    private func capabilities(directory: URL) async throws -> (URL, [String]) {
        guard let executable = Self.discoverExecutable(configuredPath: executablePath) else { throw AIProviderError.cliUnavailable }
        func run(_ args: [String]) async throws -> Result {
            try await runner(Invocation(executable: executable, arguments: args, directory: directory, input: Data(),
                                        timeout: min(max(timeout, 0.05), 8), outputLimit: 131_072))
        }
        let help = try await run(["exec", "--help"])
        let helpText = String(decoding: help.stdout, as: UTF8.self)
        let required = ["--output-schema", "--output-last-message", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--sandbox", "--strict-config"]
        guard help.status == 0, required.allSatisfy(helpText.contains) else {
            throw AIProviderError.cliUnsupported("CLI 缺少结构化输出或配置隔离选项，请更新 Codex")
        }
        let featureResult = try await run(["features", "list"])
        let features = String(decoding: featureResult.stdout, as: UTF8.self).split(separator: "\n").compactMap { line -> String? in
            let values = line.split(whereSeparator: { $0.isWhitespace })
            guard let key = values.first, let enabled = values.last, ["true", "false"].contains(enabled),
                  key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
            return String(key)
        }
        guard featureResult.status == 0, ["shell_tool", "apps", "plugins", "hooks", "memories", "multi_agent"].allSatisfy(features.contains) else {
            throw AIProviderError.cliUnsupported("无法确认 CLI 的工具禁用能力")
        }
        // Audited 0.142.0 still exposes view_image with every listed feature disabled.
        // Never rely on a prompt to prevent local-file reads. Unknown versions fail closed.
        guard features.contains("view_image") else {
            throw AIProviderError.cliUnsupported("此 CLI 缺少本地图像工具的禁用能力，无法保证只读取提供的上下文")
        }
        let auth = try await run(["login", "status"])
        let authText = String(decoding: auth.stdout + auth.stderr, as: UTF8.self)
        guard auth.status == 0, authText.contains("Logged in") else { throw AIProviderError.cliUnauthenticated }
        return (executable, features)
    }

    static func parsingArguments(directory: URL, instructions: URL, output: URL, disabledFeatures: [String]) throws -> [String] {
        let encodedPath = String(decoding: try JSONEncoder().encode(instructions.path), as: UTF8.self)
        var args = ["exec", "--strict-config", "--ignore-user-config", "--ignore-rules", "--ephemeral",
                    "--sandbox", "read-only", "--skip-git-repo-check", "--color", "never", "--json",
                    "--cd", directory.path, "--output-schema", try AIResources.url("IntentSchema_v2", extension: "json").path,
                    "--output-last-message", output.path]
        // Disable every feature known to this binary, including newly introduced tool families.
        for feature in disabledFeatures { args += ["--disable", feature] }
        for value in ["approval_policy=\"never\"", "web_search=\"disabled\"", "features.view_image=false",
                      "mcp_servers={}", "skills.bundled.enabled=false", "skills.include_instructions=false",
                      "project_doc_max_bytes=0", "history.persistence=\"none\"", "notify=[]",
                      "model_instructions_file=\(encodedPath)"] { args += ["-c", value] }
        args.append("-") // User content is written only to stdin.
        return args
    }
}

/// Bounded pipes on a background queue keep UI responsive and cancellation independent of child behavior.
enum CodexSubprocess {
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }

    static func run(_ invocation: CodexCLIProvider.Invocation) async throws -> CodexCLIProvider.Result {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try execute(invocation, cancellation: cancellation)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private static func execute(_ invocation: CodexCLIProvider.Invocation, cancellation: Cancellation) throws -> CodexCLIProvider.Result {
        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.directory
        // Retain authentication location, not tokens; never inherit API keys or injected CLI/app-server overrides.
        let inherited = ProcessInfo.processInfo.environment
        let allowed = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL", "CODEX_HOME"]
        process.environment = Dictionary(uniqueKeysWithValues: allowed.compactMap { key in inherited[key].map { (key, $0) } })
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        defer {
            for handle in [input.fileHandleForReading, input.fileHandleForWriting, output.fileHandleForReading,
                           output.fileHandleForWriting, errors.fileHandleForReading, errors.fileHandleForWriting] { try? handle.close() }
        }
        guard !cancellation.cancelled else { throw CancellationError() }
        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let inputFD = input.fileHandleForWriting.fileDescriptor
        let outputFD = output.fileHandleForReading.fileDescriptor
        let errorFD = errors.fileHandleForReading.fileDescriptor
        for fd in [inputFD, outputFD, errorFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        _ = fcntl(inputFD, F_SETNOSIGPIPE, 1)
        let deadline = ProcessInfo.processInfo.systemUptime + invocation.timeout
        var inputOffset = 0, inputClosed = false
        var stdout = Data(), stderr = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)

        func drain(_ fd: Int32, into data: inout Data) throws {
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count <= 0 { return }
                guard data.count + count <= invocation.outputLimit else { throw AIProviderError.outputTooLarge }
                data.append(buffer, count: count)
            }
        }
        do {
            while true {
                if cancellation.cancelled { throw CancellationError() }
                if ProcessInfo.processInfo.systemUptime >= deadline { throw AIProviderError.timedOut }
                try drain(outputFD, into: &stdout)
                try drain(errorFD, into: &stderr)
                if !process.isRunning { break }
                if !inputClosed {
                    if inputOffset < invocation.input.count {
                        let count = invocation.input.withUnsafeBytes { bytes in
                            Darwin.write(inputFD, bytes.baseAddress!.advanced(by: inputOffset), invocation.input.count - inputOffset)
                        }
                        if count > 0 { inputOffset += count }
                        else if count < 0 && errno != EAGAIN && errno != EINTR { inputOffset = invocation.input.count }
                    }
                    if inputOffset == invocation.input.count {
                        try? input.fileHandleForWriting.close()
                        inputClosed = true
                    }
                }
                var fds = [pollfd(fd: outputFD, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: errorFD, events: Int16(POLLIN), revents: 0)]
                _ = poll(&fds, nfds_t(fds.count), 20)
            }
            process.waitUntilExit()
            try drain(outputFD, into: &stdout)
            try drain(errorFD, into: &stderr)
            return CodexCLIProvider.Result(status: process.terminationStatus, stdout: stdout, stderr: stderr)
        } catch {
            if process.isRunning {
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.25
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(10_000) }
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            throw error
        }
    }
}
