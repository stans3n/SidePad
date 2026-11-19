import SwiftUI

struct IntentPlanPreviewView: View {
    let plan: IntentPlan
    let items: [IntentPreviewItem]
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let clarification = plan.clarification, !clarification.isEmpty {
                Label(clarification, systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 7) {
                    if item.depth > 0 {
                        Text("└").font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    Image(systemName: symbol(item.kind)).font(.caption)
                        .foregroundStyle(item.kind == .completedTask ? Color.green : Color.accentColor)
                        .frame(width: 15).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(item.title).font(.caption.weight(.medium)).textSelection(.enabled)
                            Spacer(minLength: 0)
                            Text(label(item.kind)).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        if !item.breadcrumb.isEmpty {
                            Text(item.breadcrumb).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if !item.details.isEmpty { Text(item.details).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
                        ForEach(item.contextChanges) { change in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(change.label).font(.caption2.weight(.medium))
                                Text("Before: \(change.before.isEmpty ? "Not recorded" : change.before)")
                                    .foregroundStyle(.secondary).lineLimit(3)
                                Text("After: \(change.after.isEmpty ? "Cleared" : change.after)").lineLimit(4)
                            }
                            .font(.caption2).textSelection(.enabled).padding(.top, 2)
                        }
                    }
                }
                .padding(.leading, CGFloat(min(item.depth, 4)) * 9)
            }
            DisclosureGroup("Advanced Details", isExpanded: $showAdvanced) {
                Text(json).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var json: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(plan)).map { String(decoding: $0, as: UTF8.self) } ?? "Plan unavailable"
    }
    private func symbol(_ kind: IntentPreviewItem.Kind) -> String {
        switch kind {
        case .newThread: "folder.badge.plus"
        case .newTask: "circle"
        case .completedTask: "checkmark.circle.fill"
        case .reopenedTask: "arrow.uturn.backward.circle"
        case .progress: "text.bubble"
        case .context: "text.alignleft"
        case .threadStatus: "circle.dotted"
        }
    }
    private func label(_ kind: IntentPreviewItem.Kind) -> String {
        switch kind {
        case .newThread: "New Thread"
        case .newTask: "New Task"
        case .completedTask: "Completed"
        case .reopenedTask: "Reopened"
        case .progress: "Progress"
        case .context: "Context"
        case .threadStatus: "Status"
        }
    }
}
