import AppKit
import SwiftUI

struct AttachmentSettingsView: View {
    @ObservedObject var store: AttachmentStore
    @State private var customDays = "7"
    @State private var usingCustomDays = false
    @State private var localError: String?
    @State private var confirmingCleanup = false
    private let presets = [1, 3, 7, 14, 30]

    var body: some View {
        Section("Threads Attachments") {
            VStack(alignment: .leading, spacing: 5) {
                Text("Attachment Storage Location")
                Text(store.storagePath)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(3)
                HStack {
                    Button("Choose Folder…") { chooseFolder() }
                    Button("Reset to Default") { perform { try store.resetStorageLocation() } }
                    Button("Open in Finder") { store.openStorageFolder() }
                }
                .disabled(store.isImporting || store.isCaptureActive)
                Text("New imports use this location. Existing copies remain registered in their original managed folders until expiry. Originals and Linked Resources are never removed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Automatically Delete Temporary Attachments", selection: Binding(
                get: { usingCustomDays ? -1 : store.retentionDays ?? 0 },
                set: { value in
                    usingCustomDays = value == -1
                    if value != -1 { perform { try store.setRetentionDays(value == 0 ? nil : value) } }
                }
            )) {
                Text("Never").tag(0)
                ForEach(presets, id: \.self) { day in Text("After \(day) day\(day == 1 ? "" : "s")").tag(day) }
                Text("Custom…").tag(-1)
            }
            if usingCustomDays {
                HStack {
                    TextField("Days (1–365)", text: $customDays)
                        .frame(maxWidth: 140)
                        .onSubmit { saveCustomDays() }
                    Text("days").foregroundStyle(.secondary)
                    Button("Save") { saveCustomDays() }
                }
            }
            HStack {
                Button("Clean Up Now…") { confirmingCleanup = true }
                    .disabled(store.isImporting || store.eligibleCleanupCount == 0)
                Text("\(store.eligibleCleanupCount) expired copies eligible")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Temporary copies stay local. Only bounded, redacted extracted text is sent to the selected AI provider when you submit. Images use local OCR text only.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = localError ?? store.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let message = store.cleanupMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            customDays = String(store.retentionDays ?? 7)
            usingCustomDays = store.retentionDays.map { !presets.contains($0) } ?? false
        }
        .confirmationDialog("Remove expired temporary attachments?", isPresented: $confirmingCleanup, titleVisibility: .visible) {
            Button("Remove \(store.eligibleCleanupCount) Expired Copies", role: .destructive) { store.cleanupNow() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Only registered expired SidePad copies will be removed. Original files, active captures, and permanent project resources are preserved. This cannot be undone.")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Attachment Storage Folder"
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try store.setCustomDirectory(url) }
    }

    private func saveCustomDays() {
        guard let value = Int(customDays), (1...365).contains(value) else {
            localError = "Enter a whole number between 1 and 365."
            return
        }
        perform { try store.setRetentionDays(value) }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); localError = nil }
        catch { localError = error.localizedDescription }
    }
}
