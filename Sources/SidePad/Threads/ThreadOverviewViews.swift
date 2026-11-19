import SwiftUI

struct TaskJourneyView: View {
    let stations: [TaskJourneyStation]
    let openHistory: (UUID) -> Void
    let reopen: (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Task Journey").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if stations.isEmpty {
                Text("Add your first task to choose what comes next.")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(stations.enumerated()), id: \.element.id) { index, station in
                        stationRow(station, hasNext: index < stations.count - 1)
                            .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 3)))
                    }
                }
            }
            if !stations.isEmpty && stations.allSatisfy({ $0.kind == .lastCompleted }) {
                Text("No open tasks. Add the next step whenever you're ready.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: stations.map(\.id))
    }

    private func stationRow(_ station: TaskJourneyStation, hasNext: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            VStack(spacing: 0) {
                Image(systemName: station.kind == .lastCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: station.kind == .nextUp ? .semibold : .regular))
                    .foregroundStyle(station.kind == .nextUp ? Color.accentColor : Color.secondary)
                    .frame(width: 16, height: 20)
                if hasNext {
                    JourneyConnector().stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1,
                        dash: station.kind == .nextUp ? [3, 3] : []))
                        .frame(width: 1).frame(minHeight: 22, maxHeight: .infinity)
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(label(station.kind)).font(.system(size: 10, weight: .medium))
                    if let date = station.completedAt {
                        Text(date, format: .dateTime.month(.abbreviated).day()).font(.system(size: 10))
                    }
                }
                .foregroundStyle(.secondary)
                Button { openHistory(station.task.id) } label: {
                    Text(station.task.title)
                        .font(.system(size: 12, weight: station.kind == .nextUp ? .semibold : .regular))
                        .foregroundStyle(station.kind == .nextUp ? .primary : .secondary)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(label(station.kind)): \(station.task.title). View task history")
                .contextMenu {
                    Button("View History…") { openHistory(station.task.id) }
                    if station.task.isCompleted { Button("Reopen Task") { reopen(station.task.id) } }
                }
                if let parent = station.parentTitle {
                    Text("In \(parent)").font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .padding(.top, 2).padding(.bottom, hasNext ? 10 : 2)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
    private func label(_ kind: TaskJourneyStation.Kind) -> String {
        switch kind { case .lastCompleted: "Last Completed"; case .nextUp: "Next Up"; case .afterThat: "After That" }
    }
}

private struct JourneyConnector: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in path.move(to: CGPoint(x: rect.midX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY)) }
    }
}

struct ThreadRecentActivityView: View {
    let items: [ThreadActivityItem]
    let openHistory: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if items.isEmpty { Text("No progress events recorded yet.").font(.caption).foregroundStyle(.secondary) }
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: item.symbol).font(.caption).foregroundStyle(.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.caption).lineLimit(2)
                        Text(item.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        if !item.details.isEmpty {
                            DisclosureGroup("Details") {
                                ForEach(item.details, id: \.self) { Text($0).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            Button("Open Detailed History…", action: openHistory).font(.caption).buttonStyle(.link)
        }
        .padding(.top, 7)
    }
}
