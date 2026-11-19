import AppKit
import Combine

// Time-based state is independent of timer cadence and can be checked without moving the mouse.
struct HideDelay {
    private(set) var deadline: TimeInterval?
    mutating func shouldHide(inside: Bool, shown: Bool, docked: Bool = true, interacting: Bool = false,
                             policy: AutoHidePolicy = .delayed(0.35), now: TimeInterval) -> Bool {
        guard docked, shown, !inside, !interacting else { deadline = nil; return false }
        guard case let .delayed(duration) = policy else { deadline = nil; return false }
        if deadline == nil { deadline = now + duration }
        return now >= deadline!
    }
    func shouldHideForExternalClick(shown: Bool, docked: Bool = true,
                                    interacting: Bool, policy: AutoHidePolicy) -> Bool {
        docked && shown && !interacting && policy == .untilExternalClick
    }
}

@MainActor
final class EdgeTriggerMonitor: NSObject {
    private let controller: PanelController
    private var timer: Timer?
    private var externalClickMonitor: Any?
    private var delay = HideDelay()
    private var subscriptions = Set<AnyCancellable>()
    var isMonitoring: Bool { timer != nil }

    init(controller: PanelController) {
        self.controller = controller
        super.init()
        controller.store.$autoHide.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
            .store(in: &subscriptions)
        controller.store.$placement.dropFirst().sink { [weak self] _ in
            // Published placement arrives before the stored value changes.
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &subscriptions)
    }

    static func isAtEdge(_ point: NSPoint, screen: NSRect, usable: NSRect, side: DockEdge = .right) -> Bool {
        let horizontal = side == .right
            ? point.x >= screen.maxX - 4 && point.x < screen.maxX
            : point.x >= screen.minX && point.x < screen.minX + 4
        return horizontal && point.y >= usable.minY && point.y < usable.maxY
    }

    func start(force: Bool = false) {
        stop()
        guard controller.effectiveAutoHide else { return }
        let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        externalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleExternalClick() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let externalClickMonitor { NSEvent.removeMonitor(externalClickMonitor) }
        externalClickMonitor = nil
        delay = HideDelay()
    }

    private func handleExternalClick() {
        guard controller.effectiveAutoHide,
              delay.shouldHideForExternalClick(shown: controller.isShown,
                  docked: !controller.isFloating,
                  interacting: controller.panelInteractionActive, policy: controller.store.autoHidePolicy) else { return }
        controller.hide()
    }

    private func refresh() {
        if controller.effectiveAutoHide { start() } else { stop() }
    }

    @objc private func tick() {
        guard controller.effectiveAutoHide else { stop(); return }
        controller.rememberForegroundApplication()
        guard !controller.isAnimating else { return }
        if controller.panelInteractionActive {
            _ = delay.shouldHide(inside: true, shown: controller.isShown,
                                 interacting: true, now: ProcessInfo.processInfo.systemUptime)
            return
        }
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
        let edge = screen.map { Self.isAtEdge(point, screen: $0.frame, usable: $0.visibleFrame,
                                             side: controller.store.side) } ?? false
        if edge, !controller.isShown, let screen { controller.show(on: screen, anchorY: point.y) }
        let corridor = WindowGeometry.interactionCorridor(visible: controller.visibleFrame,
            hidden: controller.hiddenFrame, edge: controller.store.side)
        let inside = controller.isShown && corridor.contains(point)
        if delay.shouldHide(inside: inside, shown: controller.isShown, docked: !controller.isFloating,
                            policy: controller.store.autoHidePolicy,
                            now: ProcessInfo.processInfo.systemUptime) {
            controller.hide()
        }
    }
}
