import Foundation
import Testing
@testable import SidePad

/// Explicit opt-in only. Never sends real projects, attachments, or credentials to output.
@Suite(.serialized)
struct ThreadsV2LiveProbeTests {
    private actor Meter {
        var requests = 0
        var usage: [[String: Int]] = []
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            guard requests < 4 else { throw AIProviderError.invalidConfiguration("Live test request budget exhausted") }
            requests += 1
            let result = try await DeepSeekProvider.send(request)
            if let object = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
               let value = object["usage"] as? [String: Any] {
                usage.append(value.compactMapValues { $0 as? Int })
            }
            return result
        }
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SIDEPAD_LIVE_DEEPSEEK_V2"] == "1"))
    func syntheticScenariosUsingExistingConfiguration() async throws {
        let reportURL = URL(fileURLWithPath: "/private/tmp/sidepad-v2-live-report.json")
        let defaults = UserDefaults(suiteName: "local.SidePad") ?? .standard
        let settings = AISettingsStore(defaults: defaults)
        let meter = Meter()
        var outcomes: [[String: Any]] = []
        var report: [String: Any] = ["model": settings.model, "base_url": settings.baseURL,
            "selected_provider": settings.provider.rawValue, "maximum_requests": 4,
            "retry_enabled": false, "synthetic_data_only": true]
        func save() async throws {
            report["actual_requests"] = await meter.requests
            report["usage"] = await meter.usage
            report["outcomes"] = outcomes
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
        }
        let key: String
        do {
            guard let existing = try CredentialStore().readAPIKey(), !existing.isEmpty else {
                report["status"] = "not_attempted_missing_key"; try await save(); return
            }
            key = existing
        } catch {
            report["status"] = "not_attempted_keychain_unavailable"
            report["error_category"] = String(describing: type(of: error))
            try await save(); return
        }
        let provider = DeepSeekProvider(apiKey: key, baseURL: settings.baseURL, model: settings.model,
            timeout: min(60, max(30, settings.timeout)), maximumAttempts: 1, maximumOutputTokens: 2500,
            transport: { try await meter.send($0) })
        let thread = ThreadRecord(id: UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!, title: "SidePad Synthetic")
        let integration = TaskItem(id: UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!,
            title: "接入 DeepSeek API", sortOrder: 0, threadID: thread.id)
        var completed = integration; completed.isCompleted = true
        let scenarios: [(String, String, [TaskItem])] = [
            ("A_simple_creation", "添加一个任务：测试窗口缩放。", []),
            ("B_existing_completion_and_followup", "我今天完成了 DeepSeek API 的接入，但是 Codex CLI 的能力检查仍然报错，接下来需要修复这个问题并重新测试解析。", [integration]),
            ("C_completed_work_backfill", "我已经完成了设置页面的 UI 调整，接下来需要测试窗口缩放。", []),
            ("D_completed_deduplication", "DeepSeek API 的接入已经完成，接下来需要测试窗口缩放。不要重复创建已经完成的工作。", [completed])
        ]
        for (name, input, tasks) in scenarios {
            do {
                let now = Date(), zone = TimeZone(identifier: "Australia/Sydney")!
                let context = try IntentInputContext(threads: [thread], tasks: tasks, selectedThreadID: thread.id, now: now, timeZone: zone)
                let data = try await provider.parse(.init(input: input, contextJSON: try context.json(), now: now, timeZone: zone))
                let plan = try IntentValidator.decode(data)
                let prepared = try IntentValidator.prepare(plan, threads: [thread], tasks: tasks, selectedThreadID: thread.id, now: now, timeZone: zone, rawInput: input)
                let newTasks = prepared.afterTasks.filter { item in !tasks.contains { $0.id == item.id } }
                var valid = plan.schemaVersion == 2 && !plan.needsClarification
                switch name {
                case "A_simple_creation": valid = valid && newTasks.count == 1 && !newTasks[0].isCompleted
                case "B_existing_completion_and_followup":
                    valid = valid && prepared.afterTasks.first { $0.id == integration.id }?.isCompleted == true
                        && newTasks.contains { !$0.isCompleted }
                        && !newTasks.contains { $0.title == integration.title }
                        && prepared.afterThreads[0].progressEvents.count > thread.progressEvents.count
                        && prepared.afterTasks.allSatisfy { $0.dueDate == nil }
                case "C_completed_work_backfill": valid = valid && newTasks.contains { $0.isCompleted } && newTasks.contains { !$0.isCompleted }
                case "D_completed_deduplication": valid = valid && newTasks.allSatisfy { !$0.isCompleted } && !newTasks.isEmpty
                default: valid = false
                }
                outcomes.append(["scenario": name, "structured_response": true, "local_validation": true,
                    "semantic_checks": valid, "operations": plan.operations.map { $0.operation.rawValue },
                    "new_task_count": newTasks.count])
                try await save()
                if !valid { report["status"] = "stopped_semantic_failure"; try await save(); Issue.record("Live scenario failed semantic checks: \(name)"); return }
            } catch {
                outcomes.append(["scenario": name, "structured_response": false,
                    "error_category": String(describing: type(of: error)), "error": error.localizedDescription])
                report["status"] = "stopped_after_first_failure"; try await save()
                Issue.record("Live DeepSeek stopped after failure: \(name): \(error.localizedDescription)")
                return
            }
        }
        report["status"] = "passed"
        try await save()
    }
}
