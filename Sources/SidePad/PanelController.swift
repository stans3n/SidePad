import AppKit
import Combine
import QuartzCore
import SwiftUI

final class SidePadPanel: NSPanel {
    var onInteraction: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) { onInteraction?() }
        super.sendEvent(event)
    }
}

private enum DragPhase {
    case idle
    case docked(start: NSPoint, frame: NSRect, edge: DockEdge)
    case floating(start: NSPoint, frame: NSRect)
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let panel: SidePadPanel
    let webContent: WebContent
    let store: WorkspaceStore
    let threads: ThreadStore
    let aiSettings: AISettingsStore
    let attachments: AttachmentStore
    let threadsCoordinator: ThreadsCoordinator
    let threadsViewState: ThreadsViewState
    private(set) var isShown = false
    private(set) var isAnimating = false
    private(set) var visibleFrame: NSRect = .zero
    private(set) var hiddenFrame: NSRect = .zero
    var isFloating: Bool { store.placement == .floating }
    var effectiveAutoHide: Bool { store.autoHide && !isFloating }
    var isMovingWindow: Bool {
        if case .idle = dragPhase { return false }
        return true
    }
    var panelInteractionActive: Bool { isMovingWindow || resizeStart != nil || isActionMenuPresented || panel.attachedSheet != nil }
    private(set) var isActionMenuPresented = false
    private var activeScreen: NSScreen?
    private var revealAnchorY: CGFloat?
    private var previousApplication: NSRunningApplication?
    private var interacted = false
    private var subscriptions = Set<AnyCancellable>()
    private var dragPhase: DragPhase = .idle
    private var preview: NSWindow?
    private var previewTarget: (screen: NSScreen, edge: DockEdge, frame: NSRect)?
    private var resizeStart: (point: NSPoint, frame: NSRect)?
    private var todayPreferredHeight: CGFloat?
    private var applyingWorkspaceFrame = false

    init(loadPage: Bool = true, store: WorkspaceStore? = nil, threads: ThreadStore? = nil, aiSettings: AISettingsStore? = nil, attachments: AttachmentStore? = nil) {
        self.store = store ?? WorkspaceStore()
        self.threads = threads ?? ThreadStore()
        self.aiSettings = aiSettings ?? AISettingsStore()
        self.attachments = attachments ?? AttachmentStore()
        threadsCoordinator = ThreadsCoordinator(workspace: self.store, threads: self.threads, settings: self.aiSettings)
        threadsViewState = ThreadsViewState()
        webContent = WebContent(loadPage: false)
        panel = SidePadPanel(contentRect: .zero, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.contentMinSize = NSSize(width: 280, height: 280)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovable = false
        panel.animationBehavior = .none
        let host = FirstMouseHostingView(rootView: WorkspaceView(store: self.store, webContent: webContent,
            threads: self.threads, aiSettings: self.aiSettings, threadsCoordinator: threadsCoordinator,
            threadsViewState: threadsViewState, attachments: self.attachments,
            hide: { [weak self] in self?.hideFromRail() },
            beginMove: { [weak self] in self?.beginMove(at: $0) },
            move: { [weak self] in self?.move(to: $0) },
            endMove: { [weak self] in self?.endMove(at: $0) },
            beginResize: { [weak self] in self?.beginResize(at: $0) },
            resize: { [weak self] in self?.resize(to: $0) },
            endResize: { [weak self] in self?.endResize(at: $0) },
            preferredTodayHeight: { [weak self] in self?.setTodayPreferredHeight($0) },
            actionMenuInteraction: { [weak self] in self?.setActionMenuPresented($0) }))
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = PanelMaterial.make(content: host)
        panel.initialFirstResponder = host
        panel.onInteraction = { [weak self] in
            guard let self else { return }
            self.rememberForegroundApplication()
            self.interacted = true
            NSApp.activate(ignoringOtherApps: true)
            self.panel.makeKey()
        }
        activeScreen = self.store.placement == .floating
            ? WindowGeometry.restorationScreen(for: self.store.floatingWindow) : NSScreen.main
        if isFloating, let legacySize = self.store.floatingWindow?.frame.size,
           self.store.size(for: self.store.selection.presentation) == nil {
            self.store.setSize(legacySize, for: self.store.selection.presentation)
        }
        if let screen = activeScreen {
            if isFloating {
                setContentMinimumSize(WindowGeometry.minimumSize(floating: true, usable: screen.visibleFrame,
                    presentation: self.store.selection.presentation))
                let initial = self.store.floatingWindow?.frame ?? WindowGeometry.dockedFrame(
                    usable: screen.visibleFrame, edge: self.store.side,
                    presentation: self.store.selection.presentation,
                    heightRatio: self.store.heightRatio(for: self.store.selection.presentation))
                panel.setFrame(WindowGeometry.clampedFloatingFrame(initial, usable: screen.visibleFrame,
                    presentation: self.store.selection.presentation), display: false)
            } else { configureDocked(on: screen) }
        }
        self.store.$side.dropFirst().sink { [weak self] edge in
            DispatchQueue.main.async {
                guard let self, !self.isFloating else { return }
                guard self.store.placement != .docked(edge: edge) else { return }
                self.store.placement = .docked(edge: edge)
                if let screen = self.activeScreen { self.configureDocked(on: screen, animated: self.isShown) }
            }
        }.store(in: &subscriptions)
        self.store.$autoHide.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.effectiveAutoHide, !self.isShown else { return }
                self.show(on: self.activeScreen, animated: true)
            }
        }.store(in: &subscriptions)
        self.store.$selection.dropFirst().sink { [weak self] selection in
            self?.webContent.select(selection, store: self?.store)
            DispatchQueue.main.async {
                guard let self, let screen = self.activeScreen else { return }
                if self.isFloating { self.configureFloatingWorkspace(on: screen) }
                else { self.configureDocked(on: screen) }
            }
        }.store(in: &subscriptions)
        self.store.$websites.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.store.selection.presentation == .today,
                      let screen = self.activeScreen else { return }
                if self.isFloating { self.configureFloatingWorkspace(on: screen) }
                else { self.configureDocked(on: screen) }
            }
        }.store(in: &subscriptions)
        self.store.$webHeightRatio.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.isFloating, self.store.selection.presentation == .web,
                      let screen = self.activeScreen else { return }
                self.configureDocked(on: screen)
            }
        }.store(in: &subscriptions)
        for publisher in [self.store.$tasksSize.eraseToAnyPublisher(),
                          self.store.$threadsSize.eraseToAnyPublisher(),
                          self.store.$webSize.eraseToAnyPublisher()] {
            publisher.dropFirst().sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, !self.panelInteractionActive, let screen = self.activeScreen else { return }
                    if self.isFloating { self.configureFloatingWorkspace(on: screen) }
                    else { self.configureDocked(on: screen) }
                }
            }.store(in: &subscriptions)
        }
        for publisher in [self.store.$todayHeightRatio.eraseToAnyPublisher(),
                          self.store.$threadsHeightRatio.eraseToAnyPublisher(),
                          self.store.$tasksHeightRatio.eraseToAnyPublisher()] {
            publisher.dropFirst().sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, !self.isFloating, let screen = self.activeScreen else { return }
                    self.configureDocked(on: screen)
                }
            }.store(in: &subscriptions)
        }
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.handleDisplayChange() } }
            .store(in: &subscriptions)
        if loadPage { webContent.select(self.store.selection, store: self.store) }
        if !effectiveAutoHide { show(on: activeScreen, animated: false) }
    }

    static func frames(screen: NSRect, usable: NSRect, side: DockEdge = .right,
                       presentation: WorkspacePresentation = .web, webHeightRatio: Double? = nil,
                       anchorY: CGFloat? = nil, savedSize: CGSize? = nil,
                       todayHeight: CGFloat? = nil) -> (visible: NSRect, hidden: NSRect) {
        let visible = WindowGeometry.dockedFrame(usable: usable, edge: side,
            presentation: presentation, heightRatio: webHeightRatio, anchorY: anchorY,
            savedSize: savedSize, todayHeight: todayHeight)
        return (visible, WindowGeometry.hiddenFrame(visible, screen: screen, edge: side))
    }

    private func configureDocked(on screen: NSScreen, animated: Bool = false, targetFrame: NSRect? = nil) {
        activeScreen = screen
        setContentMinimumSize(WindowGeometry.minimumSize(floating: false, usable: screen.visibleFrame,
            presentation: store.selection.presentation))
        let frames = Self.frames(screen: screen.frame, usable: screen.visibleFrame, side: store.side,
            presentation: store.selection.presentation,
            webHeightRatio: store.heightRatio(for: store.selection.presentation),
            anchorY: revealAnchorY, savedSize: store.size(for: store.selection.presentation),
            todayHeight: todayPanelHeight)
        visibleFrame = targetFrame ?? frames.visible
        hiddenFrame = WindowGeometry.hiddenFrame(visibleFrame, screen: screen.frame, edge: store.side)
        transition(to: isShown ? visibleFrame : hiddenFrame, animated: animated) {}
    }

    func toggleVisibility(on screen: NSScreen? = nil) {
        if isShown { hide() }
        else { show(on: isFloating ? activeScreen : (screen ?? activeScreen)) }
    }

    func rememberForegroundApplication() {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApplication = app }
    }

    func show(on screen: NSScreen? = nil, anchorY: CGFloat? = nil, animated: Bool = true) {
        guard !isShown, !isAnimating else { return }
        if !isFloating, let screen = screen ?? activeScreen ?? NSScreen.main {
            revealAnchorY = anchorY
            configureDocked(on: screen)
        }
        rememberForegroundApplication()
        interacted = false
        isShown = true
        panel.orderFrontRegardless()
        if !isFloating { transition(to: visibleFrame, animated: animated) {} }
    }

    func hide(animated: Bool = true) {
        guard isShown, !isAnimating, !panelInteractionActive else { return }
        isShown = false
        revealAnchorY = nil
        let finish: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            let restore = self.interacted && NSApp.isActive
            self.panel.orderOut(nil)
            if restore, let app = self.previousApplication, !app.isTerminated { app.activate(options: []) }
            self.interacted = false
        }
        if isFloating { finish() }
        else { transition(to: hiddenFrame, animated: animated, completion: finish) }
    }

    private func hideFromRail() {
        if !isFloating { store.autoHide = true }
        hide()
    }

    func floatWindow(animated: Bool = true) {
        guard !isFloating else { return }
        let screen = activeScreen ?? NSScreen.main ?? NSScreen.screens.first
        var frame = panel.frame
        if let usable = screen?.visibleFrame {
            frame = WindowGeometry.floatingFramePreservingSize(frame, usable: usable)
        }
        activeScreen = screen
        store.placement = .floating
        if let screen {
            let minimum = WindowGeometry.minimumSize(floating: true, usable: screen.visibleFrame,
                presentation: store.selection.presentation)
            setContentMinimumSize(NSSize(width: min(minimum.width, frame.width),
                                         height: min(minimum.height, frame.height)))
        }
        revealAnchorY = nil
        transition(to: frame, animated: animated && isShown) {}
        saveFloatingFrame(frame, screen: screen)
        if !isShown { show(on: screen, animated: false) }
    }

    func dock(to edge: DockEdge, on screen: NSScreen? = nil, animated: Bool = true,
              targetFrame: NSRect? = nil) {
        clearPreview()
        guard let screen = screen ?? activeScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let floatingCenterY = isFloating ? panel.frame.midY : nil
        if isFloating { saveFloatingFrame(panel.frame, screen: activeScreen) }
        store.side = edge
        store.placement = .docked(edge: edge)
        setContentMinimumSize(WindowGeometry.minimumSize(floating: false, usable: screen.visibleFrame,
            presentation: store.selection.presentation))
        revealAnchorY = targetFrame?.midY ?? floatingCenterY
        activeScreen = screen
        configureDocked(on: screen, animated: animated && isShown, targetFrame: targetFrame)
        if !isShown { show(on: screen, animated: animated) }
    }

    func resetWebHeight() { store.webSize = nil; store.webHeightRatio = nil }

    func beginMove(at point: NSPoint) {
        dragPhase = isFloating ? .floating(start: point, frame: panel.frame)
            : .docked(start: point, frame: panel.frame, edge: store.side)
    }

    func move(to point: NSPoint) {
        switch dragPhase {
        case .idle: return
        case let .docked(start, frame, edge):
            let inward = edge == .right ? start.x - point.x : point.x - start.x
            if inward > 0 {
                panel.setFrame(frame.offsetBy(dx: point.x - start.x, dy: point.y - start.y), display: true)
            } else {
                panel.setFrame(frame, display: true)
            }
            guard WindowGeometry.shouldDetach(from: start, to: point, edge: edge) else { return }
            floatWindow(animated: false)
            let size = panel.frame.size
            let newFrame = NSRect(x: point.x - (start.x - frame.minX),
                y: point.y + (frame.maxY - start.y) - size.height,
                width: size.width, height: size.height)
            panel.setFrame(newFrame, display: true)
            dragPhase = .floating(start: point, frame: newFrame)
            updatePreview(at: point)
        case let .floating(start, frame):
            panel.setFrame(frame.offsetBy(dx: point.x - start.x, dy: point.y - start.y), display: true)
            updatePreview(at: point)
        }
    }

    func endMove(at point: NSPoint) {
        defer { dragPhase = .idle; clearPreview() }
        if case .docked = dragPhase {
            transition(to: visibleFrame, animated: true) {}
            return
        }
        guard case .floating = dragPhase else { return }
        updatePreview(at: point)
        if let target = previewTarget {
            dock(to: target.edge, on: target.screen, targetFrame: target.frame)
            return
        }
        if let screen = WindowGeometry.screen(containing: point) ?? activeScreen ?? NSScreen.main {
            activeScreen = screen
            let frame = WindowGeometry.clampedFloatingFrame(panel.frame, usable: screen.visibleFrame,
                presentation: store.selection.presentation)
            panel.setFrame(frame, display: true)
            saveFloatingFrame(frame, screen: screen)
        }
    }

    private func updatePreview(at point: NSPoint) {
        guard let screen = WindowGeometry.screen(containing: point),
              let edge = WindowGeometry.dockTarget(frame: panel.frame, usable: screen.visibleFrame)
                ?? WindowGeometry.dockTarget(point: point, screen: screen.frame,
                                             usable: screen.visibleFrame) else {
            clearPreview(); return
        }
        let frame = WindowGeometry.dockedFrame(usable: screen.visibleFrame, edge: edge,
            presentation: store.selection.presentation,
            heightRatio: store.heightRatio(for: store.selection.presentation),
            anchorY: panel.frame.midY,
            savedSize: store.size(for: store.selection.presentation), todayHeight: todayPanelHeight)
        if preview == nil {
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let surface = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
            surface.material = .hudWindow
            surface.blendingMode = .behindWindow
            surface.wantsLayer = true
            surface.layer?.cornerRadius = 20
            surface.layer?.borderWidth = 1.5
            surface.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.65).cgColor
            surface.autoresizingMask = [.width, .height]
            window.contentView = surface
            preview = window
        }
        preview?.setFrame(frame, display: true)
        preview?.orderFrontRegardless()
        panel.orderFrontRegardless()
        previewTarget = (screen, edge, frame)
    }

    private func clearPreview() { preview?.orderOut(nil); previewTarget = nil }

    private func preferredSize(for presentation: WorkspacePresentation, usable: NSRect?) -> CGSize {
        let available = usable ?? activeScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if presentation == .today {
            return CGSize(width: store.todayWidth ?? WindowGeometry.todayWidth,
                          height: WindowGeometry.fittedTodayHeight(todayPreferredHeight ?? 280,
                              railHeight: RailMetrics.requiredHeight(websiteCount: store.webItems.count), usable: available))
        }
        if let size = store.size(for: presentation) { return size }
        return WindowGeometry.dockedFrame(usable: available, edge: store.side,
            presentation: presentation, heightRatio: store.heightRatio(for: presentation)).size
    }

    private func configureFloatingWorkspace(on screen: NSScreen) {
        let presentation = store.selection.presentation
        setContentMinimumSize(WindowGeometry.minimumSize(floating: true, usable: screen.visibleFrame,
            presentation: presentation))
        var frame = panel.frame
        frame.size = preferredSize(for: presentation, usable: screen.visibleFrame)
        frame.origin.y = panel.frame.maxY - frame.height
        frame = WindowGeometry.clampedFloatingFrame(frame, usable: screen.visibleFrame,
            presentation: presentation)
        guard abs(frame.width - panel.frame.width) > 1 || abs(frame.height - panel.frame.height) > 1 else { return }
        applyingWorkspaceFrame = true
        panel.setFrame(frame, display: true)
        applyingWorkspaceFrame = false
        saveFloatingFrame(frame, screen: screen)
    }

    private func setTodayPreferredHeight(_ contentHeight: CGFloat) {
        guard contentHeight.isFinite, contentHeight > 0 else { return }
        let preferred = contentHeight + HeaderMetrics.todayHeight
        guard abs((todayPreferredHeight ?? 0) - preferred) > 1 else { return }
        todayPreferredHeight = preferred
        guard store.selection.presentation == .today, !panelInteractionActive,
              let screen = activeScreen else { return }
        if isFloating { configureFloatingWorkspace(on: screen) }
        else { configureDocked(on: screen) }
    }

    private var todayPanelHeight: CGFloat {
        max(todayPreferredHeight ?? 280, RailMetrics.requiredHeight(websiteCount: store.webItems.count))
    }

    func setActionMenuPresented(_ presented: Bool) { isActionMenuPresented = presented }

    func beginResize(at point: NSPoint) { resizeStart = (point, panel.frame) }

    func resize(to point: NSPoint) {
        guard let start = resizeStart,
              let screen = WindowGeometry.screen(containing: start.point) ?? activeScreen else { return }
        var frame = start.frame
        let minimumHeight = isFloating ? WindowGeometry.minimumFloatingSize.height
            : screen.visibleFrame.height * (store.selection.presentation == .web
                ? WindowGeometry.minimumWebHeightRatio : 0.25)
        let maximumHeight = isFloating ? screen.visibleFrame.height
            : screen.visibleFrame.height * WindowGeometry.maximumWebHeightRatio
        let height = min(maximumHeight, start.frame.maxY - screen.visibleFrame.minY,
            max(minimumHeight, start.frame.height + start.point.y - point.y))
        if store.selection.presentation != .today {
            frame.origin.y = start.frame.maxY - height
            frame.size.height = height
        }
        if isFloating {
            frame.size.width = min(screen.visibleFrame.width,
                max(WindowGeometry.minimumFloatingSize.width, start.frame.width + point.x - start.point.x))
        } else {
            let delta = store.side == .right ? start.point.x - point.x : point.x - start.point.x
            frame.size.width = min(screen.visibleFrame.width, max(280, start.frame.width + delta))
            frame.origin.x = store.side == .right ? screen.visibleFrame.maxX - frame.width : screen.visibleFrame.minX
        }
        panel.setFrame(frame, display: true)
    }

    func endResize(at point: NSPoint) {
        guard resizeStart != nil else { return }
        resize(to: point)
        resizeStart = nil
        if store.selection.presentation == .today { store.todayWidth = panel.frame.width }
        if isFloating {
            if let screen = WindowGeometry.screen(containing: point) ?? activeScreen {
                activeScreen = screen
                panel.setFrame(WindowGeometry.clampedFloatingFrame(panel.frame, usable: screen.visibleFrame,
                    presentation: store.selection.presentation), display: true)
                saveFloatingFrame(panel.frame, screen: screen)
                store.setSize(panel.frame.size, for: store.selection.presentation)
            }
        } else if let screen = activeScreen {
            revealAnchorY = panel.frame.midY
            store.setSize(panel.frame.size, for: store.selection.presentation)
            if store.selection.presentation != .today {
                store.setHeightRatio(Double(panel.frame.height / screen.visibleFrame.height),
                                     for: store.selection.presentation)
            }
            configureDocked(on: screen)
        }
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard store.selection.presentation == .today, !applyingWorkspaceFrame, !isAnimating else { return frameSize }
        return NSSize(width: frameSize.width, height: panel.frame.height)
    }

    private func saveFloatingFrame(_ frame: NSRect, screen: NSScreen?) {
        store.floatingWindow = FloatingWindowState(frame: frame,
            screenIdentifier: screen.flatMap(WindowGeometry.screenIdentifier))
    }

    private func setContentMinimumSize(_ size: NSSize) {
        let wasApplying = applyingWorkspaceFrame
        applyingWorkspaceFrame = true
        panel.contentMinSize = size
        applyingWorkspaceFrame = wasApplying
    }

    func windowDidResize(_ notification: Notification) {
        guard isShown, resizeStart == nil, !isMovingWindow, !isAnimating, !applyingWorkspaceFrame else { return }
        if !isFloating {
            store.setSize(panel.frame.size, for: store.selection.presentation)
            return
        }
        saveFloatingFrame(panel.frame, screen: panel.screen ?? activeScreen)
        if store.selection.presentation == .today { store.todayWidth = panel.frame.width; return }
        store.setSize(panel.frame.size, for: store.selection.presentation)
    }

    func windowDidMove(_ notification: Notification) {
        guard isFloating, !isMovingWindow, !isAnimating else { return }
        saveFloatingFrame(panel.frame, screen: panel.screen ?? activeScreen)
    }

    private func handleDisplayChange() {
        if isFloating {
            guard let screen = WindowGeometry.restorationScreen(for: store.floatingWindow) else { return }
            activeScreen = screen
            setContentMinimumSize(WindowGeometry.minimumSize(floating: true, usable: screen.visibleFrame,
                presentation: store.selection.presentation))
            let frame = WindowGeometry.clampedFloatingFrame(panel.frame, usable: screen.visibleFrame,
                presentation: store.selection.presentation)
            applyingWorkspaceFrame = true
            panel.setFrame(frame, display: true)
            applyingWorkspaceFrame = false
            saveFloatingFrame(frame, screen: screen)
        } else if let screen = activeScreen.flatMap({ current in NSScreen.screens.first(where: {
            WindowGeometry.screenIdentifier($0) == WindowGeometry.screenIdentifier(current) }) })
            ?? NSScreen.main ?? NSScreen.screens.first {
            configureDocked(on: screen)
        }
    }

    private func transition(to frame: NSRect, animated: Bool,
                            completion: @escaping @MainActor @Sendable () -> Void) {
        guard animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            applyingWorkspaceFrame = true
            panel.setFrame(frame, display: true)
            applyingWorkspaceFrame = false
            completion()
            return
        }
        isAnimating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor in self?.isAnimating = false; completion() }
        })
    }
}
