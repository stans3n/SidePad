import SwiftUI

struct AISettingsView: View {
    @ObservedObject var settings: AISettingsStore
    @State private var keyInput = ""
    @State private var credentialError: String?

    var body: some View {
        Section("AI Providers") {
            Picker("解析服务", selection: $settings.provider) {
                ForEach(AIProviderKind.allCases) { provider in Text(provider.title).tag(provider) }
            }
            .disabled(settings.isTesting)
            switch settings.provider {
            case .deepSeek:
                TextField("API 地址", text: $settings.baseURL)
                    .textContentType(.URL)
                TextField("模型 ID", text: $settings.model)
                Text("DeepSeek V4.1 Flash · 默认 deepseek-flash")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("DeepSeek API Key", text: $keyInput)
                    .textContentType(.password)
                HStack {
                    Label(settings.apiKeyConfigured ? "已配置" : "未配置", systemImage: settings.apiKeyConfigured ? "key.fill" : "key")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("保存密钥") {
                        do { try settings.saveAPIKey(keyInput); keyInput = ""; credentialError = nil }
                        catch { credentialError = error.localizedDescription }
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || settings.isTesting)
                    Button("移除", role: .destructive) {
                        do { try settings.removeAPIKey(); keyInput = ""; credentialError = nil }
                        catch { credentialError = error.localizedDescription }
                    }
                    .disabled(!settings.apiKeyConfigured || settings.isTesting)
                }
                Text("密钥仅保存在 macOS 钥匙串。解析会发送当前输入、所选项目的精简上下文及提交时的附件提取文本。")
                    .font(.caption).foregroundStyle(.secondary)
            case .codexCLI:
                TextField("Codex 可执行文件路径（留空自动检测）", text: $settings.codexPath)
                    .textContentType(.URL)
                Text("复用本机 codex login；受限临时目录中解析，不复制登录凭证。App Sandbox 或缺少安全选项时不可用。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("检查 CLI 和登录状态") { settings.checkCodex() }
                    .disabled(settings.isTesting)
            case .offline:
                Text("旧版离线解析保留用于兼容；新的 AI Quick Capture 需要已验证的 DeepSeek 或 Codex CLI。手动创建和完成任务始终可用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if settings.provider != .offline {
                HStack {
                    Text("超时")
                    Slider(value: $settings.timeout, in: 5...120, step: 5)
                        .frame(maxWidth: 160)
                    Text("\(Int(settings.timeout)) 秒").monospacedDigit()
                }
                HStack {
                    Button("测试连接") { settings.testConnection() }
                        .disabled(settings.isTesting)
                    if settings.isTesting {
                        ProgressView().controlSize(.small)
                        Button("取消") { settings.cancelTest() }
                    }
                }
                Text("连接测试仅发送示例文本，不会创建任务；服务商可能计入用量。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(settings.captureAvailabilityMessage).font(.caption).foregroundStyle(.secondary)
            if let message = credentialError ?? settings.status {
                Text(message).font(.caption).textSelection(.enabled)
            }
        }
        .onAppear { settings.refreshCredentialStatus() }
        .onDisappear { keyInput = ""; settings.cancelTest() }
    }
}
