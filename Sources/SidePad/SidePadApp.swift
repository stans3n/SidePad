import AppKit
import SwiftUI

@main
@MainActor
final class SidePadApp: NSObject, NSApplicationDelegate {
    private var controller: PanelController?
    private var monitor: EdgeTriggerMonitor?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?

    static func main() {
        let app = NSApplication.shared
        let delegate = SidePadApp()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Native responder-chain commands are necessary for WebKit editing shortcuts.
        let menu = NSMenu(title: "Side Pad")
        let appMenu = NSMenu(title: "Side Pad")
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Side Pad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(title: "Side Pad", action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"),
                                     ("Copy", "copy:", "c"), ("Paste", "paste:", "v"),
                                     ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        let isDemo = Bundle.main.object(forInfoDictionaryKey: "SidePadDemo") as? Bool == true
        // Optional per-demo appearance supports visual QA without changing macOS settings.
        if isDemo, let appearance = Bundle.main.object(forInfoDictionaryKey: "SidePadDemoAppearance") as? String {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        let controller = isDemo ? ThreadsDemo.makeController() : PanelController()
        self.controller = controller
        controller.attachments.cleanupIfDue()
        monitor = EdgeTriggerMonitor(controller: controller)
        monitor?.start()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let icon = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Side Pad")
            icon?.isTemplate = true
            button.image = icon
            button.toolTip = "Side Pad"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        if isDemo { controller.show(animated: false) }
        NSLog("Side Pad started")
    }

    @objc private func statusItemClicked() {
        guard let controller else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            guard let button = statusItem?.button else { return }
            let menu = NSMenu(title: "Side Pad")
            func add(_ title: String, _ action: Selector, checked: Bool = false) {
                let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
                item.target = self
                item.state = checked ? .on : .off
            }
            add(controller.isShown ? "Hide Side Pad" : "Show Side Pad", #selector(togglePanel))
            menu.addItem(.separator())
            add("Today", #selector(openToday), checked: controller.store.selection == .today)
            add("Tasks", #selector(openTasks), checked: controller.store.selection == .tasks)
            add("Threads", #selector(openThreads), checked: controller.store.selection == .threads)
            add("ChatGPT", #selector(openChatGPT), checked: controller.store.selection == .web(WebItem.chatGPTID))
            menu.addItem(.separator())
            let dockLeft = menu.addItem(withTitle: "Dock to Left", action: #selector(dockLeft), keyEquivalent: "")
            dockLeft.target = self
            dockLeft.isEnabled = controller.store.placement != .docked(edge: .left)
            let dockRight = menu.addItem(withTitle: "Dock to Right", action: #selector(dockRight), keyEquivalent: "")
            dockRight.target = self
            dockRight.isEnabled = controller.store.placement != .docked(edge: .right)
            let float = menu.addItem(withTitle: "Float Window", action: #selector(floatWindow), keyEquivalent: "")
            float.target = self
            float.isEnabled = !controller.isFloating
            menu.addItem(.separator())
            add("Pin", #selector(pinPanel), checked: !controller.store.autoHide)
            add("Auto Hide", #selector(autoHidePanel), checked: controller.store.autoHide)
            menu.addItem(.separator())
            add("Settings…", #selector(showSettings))
            add("Quit Side Pad", #selector(quitSidePad))
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 2), in: button)
        } else {
            controller.toggleVisibility(on: statusItem?.button?.window?.screen)
        }
    }

    @objc private func togglePanel() { controller?.toggleVisibility(on: statusItem?.button?.window?.screen) }
    @objc private func openToday() { select(.today) }
    @objc private func openTasks() { select(.tasks) }
    @objc private func openThreads() { select(.threads) }
    @objc private func openChatGPT() { select(.web(WebItem.chatGPTID)) }
    @objc private func dockLeft() { controller?.dock(to: .left) }
    @objc private func dockRight() { controller?.dock(to: .right) }
    @objc private func floatWindow() { controller?.floatWindow() }
    @objc private func pinPanel() { controller?.store.autoHide = false }
    @objc private func autoHidePanel() { controller?.store.autoHide = true }
    @objc private func quitSidePad() { NSApp.terminate(nil) }

    private func select(_ selection: WorkspaceSelection) {
        guard let controller else { return }
        controller.store.selection = selection
        if !controller.isShown { controller.toggleVisibility(on: statusItem?.button?.window?.screen) }
    }

    @objc private func showSettings() {
        guard let controller else { return }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 650),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Side Pad Settings"
            window.contentView = NSHostingView(rootView: SettingsView(store: controller.store, aiSettings: controller.aiSettings, attachments: controller.attachments))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.threadsCoordinator.cancel()
        controller?.aiSettings.cancelTest()
        monitor?.stop()
        NSLog("Side Pad stopped")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller, !controller.threadsViewState.drafts.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Save your Thread drafts before quitting?"
        alert.informativeText = "Unsaved context is kept while you switch workspaces. Save it to Markdown to keep it after quitting."
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard Drafts")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do {
                for id in Array(controller.threadsViewState.drafts.keys) {
                    controller.threadsCoordinator.selectedThreadID = id
                    try controller.threadsViewState.save(id, in: controller.threads)
                }
                return .terminateNow
            } catch {
                controller.threadsViewState.errorMessage = error.localizedDescription
                select(.threads)
                return .terminateCancel
            }
        case .alertThirdButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
    }
}
