import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var aiSettings: AISettingsStore
    @ObservedObject var attachments: AttachmentStore

    var body: some View {
        Form {
            Section("General") {
                Picker("Default page", selection: $store.defaultPage) {
                    Text("Today").tag(DefaultPage.today)
                    Text("Last opened").tag(DefaultPage.lastOpened)
                }
            }
            Section("Panel") {
                Picker("Side", selection: $store.side) {
                    Text("Left").tag(DockEdge.left)
                    Text("Right").tag(DockEdge.right)
                }
                Toggle("Auto Hide", isOn: $store.autoHide)
                HStack {
                    Text("Hover delay")
                    Spacer()
                    Slider(value: Binding(
                        get: { store.hideUntilExternalClick ? 1.55 : store.hoverDelay },
                        set: { value in
                            store.hideUntilExternalClick = value > 1.5
                            if value <= 1.5 { store.hoverDelay = value }
                        }), in: 0...1.55, step: 0.05)
                        .frame(width: 150)
                    Text(store.hideUntilExternalClick ? "∞" : String(format: "%.2f s", store.hoverDelay))
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }
            Section("Appearance") {
                Picker("Rail Width", selection: $store.railWidthPreference) {
                    Text("Minimal").tag(RailWidthPreference.minimal)
                    Text("Compact").tag(RailWidthPreference.compact)
                    Text("Standard").tag(RailWidthPreference.standard)
                }
                .pickerStyle(.segmented)
            }
            Section("Tasks") {
                Toggle("Show completed tasks in Today", isOn: $store.showCompletedToday)
            }
            Section("Web") {
                Button("Reset Web Height") { store.webSize = nil; store.webHeightRatio = nil }
                    .disabled(store.webHeightRatio == nil && store.webSize == nil)
            }
            AISettingsView(settings: aiSettings)
            AttachmentSettingsView(store: attachments)
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 650)
    }
}
