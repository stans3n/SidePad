import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The text remains a native multiline field. Window observation only changes its
/// focus appearance; it never activates the panel or changes auto-hide behavior.
@MainActor
struct CaptureComposerView: View {
    @Binding var text: String
    @ObservedObject var settings: AISettingsStore
    @ObservedObject var attachments: AttachmentStore
    let isLoading: Bool
    let hasPendingPlan: Bool
    let submit: () -> Void
    let cancel: () -> Void
    var focusToken = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var focused: Bool
    @State private var isKeyWindow = false
    @State private var fieldHeight: CGFloat = 18
    @State private var showFilePicker = false
    @State private var dropTargeted = false
    @State private var importError: String?

    private var highlighted: Bool { (focused && isKeyWindow) || dropTargeted }
    private var disabled: Bool { isLoading || attachments.isImporting || attachments.isCaptureActive }
    private var canSubmit: Bool {
        settings.canUseAICapture && !disabled && !hasPendingPlan && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var radius: CGFloat { fieldHeight > 27 ? 14 : 22 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let importError {
                HStack(alignment: .top, spacing: 5) {
                    Text(importError).font(MemoryStyle.secondary).foregroundStyle(.red).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { self.importError = nil } label: { Image(systemName: "xmark").font(MemoryStyle.metadata) }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss file import error")
                }
            }
            if !attachments.pending.isEmpty { attachmentChips }
            HStack(alignment: .center, spacing: 5) {
                attachButton
                TextField("Add a task or update progress...", text: $text, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...4).font(MemoryStyle.body)
                    .focused($focused).disabled(isLoading)
                    .padding(.horizontal, 4).padding(.vertical, 4)
                    .accessibilityLabel("Add a task or update progress")
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: CaptureFieldHeight.self, value: geometry.size.height)
                    })
                    .onKeyPress(.return, phases: [.down, .repeat]) { press in
                        handleReturn(press)
                    }
                    .onPasteCommand(of: [.fileURL, .image]) { _ in
                        guard !disabled && !hasPendingPlan else { return }
                        Task { _ = await attachments.pasteFromClipboard() }
                    }
                submitButton
            }
            .padding(.horizontal, 5).padding(.vertical, 5)
            .background(Color(nsColor: .textBackgroundColor).opacity(reduceTransparency ? 1 : (highlighted ? 0.72 : 0.4)), in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(
                highlighted ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.12), lineWidth: highlighted ? 1.3 : 1))
            .shadow(color: highlighted ? Color.accentColor.opacity(0.11) : .clear, radius: 4)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: highlighted)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: radius)
            .onPreferenceChange(CaptureFieldHeight.self) { fieldHeight = $0 }
            .background(CaptureWindowObserver { isKeyWindow = $0 }.frame(width: 0, height: 0))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: importDroppedFiles)
            if focused || !text.isEmpty || isLoading || !settings.canUseAICapture {
                HStack(spacing: 6) {
                    providerMenu
                    Spacer(minLength: 0)
                    if isLoading { ProgressView().controlSize(.small) }
                    if !settings.canUseAICapture {
                        Button("Set up AI", action: openSettings).font(MemoryStyle.metadata).buttonStyle(.link)
                            .help(settings.captureAvailabilityMessage).accessibilityLabel(settings.captureAvailabilityMessage)
                    }
                }
                .padding(.horizontal, 5)
            }
            if !attachments.pending.isEmpty {
                Text("Extracted text is sent to the selected provider only when you submit.")
                    .font(MemoryStyle.metadata).foregroundStyle(.secondary)
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: AttachmentStore.allowedContentTypes,
                      allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls):
                importError = nil
                Task { await attachments.importFiles(urls) }
            case let .failure(error):
                let value = error as NSError
                if value.domain != NSCocoaErrorDomain || value.code != NSUserCancelledError {
                    importError = "Could not open the selected files: \(error.localizedDescription)"
                }
            }
        }
        .onChange(of: isLoading) { wasLoading, loading in if wasLoading && !loading { focused = true } }
        .onChange(of: focusToken) { _, _ in focused = true }
        .onExitCommand { focused = false }
    }

    private var attachButton: some View {
        Menu {
            Button("Attach Files…") { showFilePicker = true }
            Button("Paste File or Image") { Task { _ = await attachments.pasteFromClipboard() } }
            Divider()
            Button("Configure AI Providers…", action: openSettings)
        } label: {
            Image(systemName: "plus").font(.system(size: 14, weight: .medium))
                .frame(width: 36, height: 36).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: 36, height: 36)
        .disabled(disabled || hasPendingPlan)
        .help("Attach up to five files or images").accessibilityLabel("Attachments and capture options")
    }

    @ViewBuilder private var submitButton: some View {
        if isLoading {
            Button(action: cancel) {
                Image(systemName: "stop.circle").font(.system(size: 21)).frame(width: 36, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(MemoryRowButtonStyle()).help("Cancel capture").accessibilityLabel("Cancel capture")
        } else {
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 23))
                    .foregroundStyle(canSubmit ? Color.accentColor : Color.secondary.opacity(0.55))
                    .frame(width: 36, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(MemoryRowButtonStyle()).disabled(!canSubmit)
            .keyboardShortcut(focused ? KeyboardShortcut(.return, modifiers: .command) : nil)
            .help("Review proposed changes (Command-Return)").accessibilityLabel("Review proposed changes")
        }
    }

    private var providerMenu: some View {
        Menu {
            Button { selectProvider(.deepSeek) } label: {
                if settings.provider == .deepSeek { Label(deepSeekLabel, systemImage: "checkmark") }
                else { Text(deepSeekLabel) }
            }
            Button { selectProvider(.codexCLI) } label: {
                if settings.provider == .codexCLI { Label("Codex CLI", systemImage: "checkmark") }
                else { Text("Codex CLI") }
            }
            Divider()
            Button("Configure Providers…", action: openSettings)
        } label: {
            HStack(spacing: 4) {
                Text(providerLabel).font(MemoryStyle.secondary).lineLimit(1)
                Image(systemName: "chevron.down").font(MemoryStyle.metadata)
            }
            .foregroundStyle(.secondary).padding(.horizontal, 3).frame(height: 25)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(disabled || hasPendingPlan || settings.isTesting)
        .help(settings.provider == .deepSeek ? "DeepSeek model: \(settings.model)" : "Choose an AI provider or configure it in Settings")
        .accessibilityLabel("AI model: \(providerLabel)")
        .accessibilityValue(settings.provider == .deepSeek ? settings.model : settings.provider.title)
    }

    private var deepSeekLabel: String {
        settings.model.localizedCaseInsensitiveContains("flash") ? "DeepSeek Flash" : "DeepSeek"
    }
    private var providerLabel: String {
        switch settings.provider {
        case .deepSeek: deepSeekLabel
        case .codexCLI: "Codex CLI"
        case .offline: "Choose model"
        }
    }
    private func selectProvider(_ provider: AIProviderKind) {
        guard provider != settings.provider else { return }
        settings.provider = provider
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                ForEach(attachments.pending) { attachment in
                    HStack(spacing: 5) {
                        Image(systemName: attachment.extractionLabel.localizedCaseInsensitiveContains("ocr") ? "photo" : "doc")
                            .font(MemoryStyle.secondary).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.name).font(MemoryStyle.metadata).lineLimit(1).truncationMode(.middle)
                            Text(attachment.extractionLabel).font(MemoryStyle.metadata).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: 125, alignment: .leading)
                        Button { attachments.remove(id: attachment.id) } label: {
                            Image(systemName: "xmark").font(MemoryStyle.metadata).frame(width: 17, height: 22)
                        }
                        .buttonStyle(.plain).disabled(disabled || hasPendingPlan)
                        .accessibilityLabel("Remove \(attachment.name)")
                    }
                    .padding(.leading, 6).padding(.trailing, 3).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    .help([attachment.name, attachment.typeLabel, attachment.warning].compactMap { $0 }.joined(separator: " · "))
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func importDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        guard !disabled && !hasPendingPlan else { return false }
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        importError = nil
        Task {
            var urls: [URL] = []
            for provider in files {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let url = item as? URL { continuation.resume(returning: url) }
                        else if let data = item as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                        else { continuation.resume(returning: nil) }
                    }
                }
                if let url { urls.append(url) }
            }
            if !urls.isEmpty { await attachments.importFiles(urls) }
            if urls.count != files.count {
                importError = "Some dropped files could not be read. Try Attach Files to select them again."
            }
        }
        return true
    }
    private func handleReturn(_ press: KeyPress) -> KeyPress.Result {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
              !editor.hasMarkedText() else { return .ignored }
        if press.modifiers.contains(.command) {
            if canSubmit { submit() }
            return .handled
        }
        // SwiftUI's vertical TextField is still backed by an AppKit field editor.
        // Bypass its Return-to-commit action, preserving native cursor/selection,
        // undo, and multiline editing. Marked text stays with the input method.
        editor.insertNewlineIgnoringFieldEditor(nil)
        return .handled
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettings")), to: NSApp.delegate, from: nil)
    }
}

private struct CaptureFieldHeight: PreferenceKey {
    static let defaultValue: CGFloat = 18
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct CaptureWindowObserver: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> WindowView { WindowView(changed: changed) }
    func updateNSView(_ view: WindowView, context: Context) { view.changed = changed }

    final class WindowView: NSView {
        var changed: (Bool) -> Void
        private var observations: [NSObjectProtocol] = []
        init(changed: @escaping (Bool) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observations.forEach(NotificationCenter.default.removeObserver)
            observations.removeAll()
            guard let window else { changed(false); return }
            DispatchQueue.main.async { [weak self, weak window] in self?.changed(window?.isKeyWindow == true) }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                    self?.changed(window?.isKeyWindow == true)
                })
            }
        }
        deinit { observations.forEach(NotificationCenter.default.removeObserver) }
    }
}
