import AppKit

enum WindowGeometry {
    static let dockWidth: CGFloat = 480
    static let todayWidth: CGFloat = 390
    static let todayMinimumHeight: CGFloat = 170
    static let todaySafetyMargin: CGFloat = 12
    static let defaultWebHeightRatio: CGFloat = 0.80
    static let minimumWebHeightRatio: CGFloat = 0.40
    static let maximumWebHeightRatio: CGFloat = 0.92
    static let detachThreshold: CGFloat = 64
    static let dockDetectionThreshold: CGFloat = 32
    static let minimumFloatingSize = NSSize(width: 280, height: 280)

    static func minimumSize(floating: Bool, usable: NSRect,
                            presentation: WorkspacePresentation = .web) -> NSSize {
        NSSize(width: min(usable.width, floating ? minimumFloatingSize.width : 280),
               height: min(usable.height, presentation == .today ? todayMinimumHeight : 280))
    }

    static func fittedTodayHeight(_ preferred: CGFloat, railHeight: CGFloat = 0, usable: NSRect) -> CGFloat {
        min(max(todayMinimumHeight, usable.height - todaySafetyMargin),
            max(min(todayMinimumHeight, usable.height), preferred, railHeight))
    }

    static func dockedFrame(usable: NSRect, edge: DockEdge, presentation: WorkspacePresentation,
                            heightRatio: Double? = nil, anchorY: CGFloat? = nil,
                            savedSize: CGSize? = nil, todayHeight: CGFloat? = nil) -> NSRect {
        let preferredWidth = savedSize?.width ?? (presentation == .today ? todayWidth : dockWidth)
        let width = min(usable.width, max(min(280, usable.width), preferredWidth))
        let height: CGFloat
        switch presentation {
        case .today:
            height = fittedTodayHeight(todayHeight ?? 280, usable: usable)
        case .tasks:
            height = savedSize?.height ?? heightRatio.map { usable.height * CGFloat($0) }
                ?? min(usable.height, min(680, max(440, usable.height * 0.62)))
        case .threads:
            height = savedSize?.height ?? heightRatio.map { usable.height * CGFloat($0) }
                ?? min(usable.height, min(760, max(560, usable.height * 0.75)))
        case .web:
            let ratio = min(maximumWebHeightRatio, max(minimumWebHeightRatio,
                CGFloat(heightRatio ?? Double(defaultWebHeightRatio))))
            height = savedSize?.height ?? min(usable.height, max(min(320, usable.height), usable.height * ratio))
        }
        let boundedHeight = presentation == .today ? height : min(usable.height, max(min(280, usable.height), height))
        let x = edge == .right ? usable.maxX - width : usable.minX
        let y = min(usable.maxY - boundedHeight, max(usable.minY, anchorY.map { $0 - boundedHeight / 2 } ?? usable.maxY - boundedHeight))
        return NSRect(x: x, y: y, width: width, height: boundedHeight).integral
    }

    static func hiddenFrame(_ visible: NSRect, screen: NSRect, edge: DockEdge) -> NSRect {
        NSRect(x: edge == .right ? screen.maxX : screen.minX - visible.width,
               y: visible.minY, width: visible.width, height: visible.height)
    }

    static func interactionCorridor(visible: NSRect, hidden: NSRect, edge: DockEdge) -> NSRect {
        if edge == .right {
            return NSRect(x: visible.minX, y: visible.minY,
                          width: max(visible.width, hidden.minX - visible.minX), height: visible.height)
        }
        return NSRect(x: hidden.maxX, y: visible.minY,
                      width: max(visible.width, visible.maxX - hidden.maxX), height: visible.height)
    }

    static func shouldDetach(from start: NSPoint, to point: NSPoint, edge: DockEdge) -> Bool {
        let inward = edge == .right ? start.x - point.x : point.x - start.x
        return inward >= detachThreshold
    }

    static func clampedFloatingFrame(_ frame: NSRect, usable: NSRect,
                                     presentation: WorkspacePresentation = .web) -> NSRect {
        let width = min(usable.width, max(min(minimumFloatingSize.width, usable.width), frame.width))
        let minimumHeight = presentation == .today ? todayMinimumHeight : minimumFloatingSize.height
        let height = min(usable.height, max(min(minimumHeight, usable.height), frame.height))
        return NSRect(x: min(usable.maxX - width, max(usable.minX, frame.minX)),
                      y: min(usable.maxY - height, max(usable.minY, frame.minY)),
                      width: width, height: height)
    }

    static func floatingFramePreservingSize(_ frame: NSRect, usable: NSRect) -> NSRect {
        NSRect(x: min(max(usable.minX, usable.maxX - frame.width), max(usable.minX, frame.minX)),
               y: min(max(usable.minY, usable.maxY - frame.height), max(usable.minY, frame.minY)),
               width: frame.width, height: frame.height)
    }

    static func dockTarget(point: NSPoint, screen: NSRect, usable: NSRect) -> DockEdge? {
        guard point.y >= usable.minY, point.y <= usable.maxY,
              point.x >= screen.minX, point.x <= screen.maxX else { return nil }
        let left = point.x - screen.minX
        let right = screen.maxX - point.x
        guard min(left, right) <= dockDetectionThreshold else { return nil }
        return left <= right ? .left : .right
    }

    static func dockTarget(frame: NSRect, usable: NSRect) -> DockEdge? {
        guard frame.midY >= usable.minY, frame.midY <= usable.maxY else { return nil }
        let left = abs(frame.minX - usable.minX)
        let right = abs(frame.maxX - usable.maxX)
        guard min(left, right) <= dockDetectionThreshold else { return nil }
        return left <= right ? .left : .right
    }

    static func screenIdentifier(_ screen: NSScreen) -> String? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
    }

    static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    static func restorationScreen(for state: FloatingWindowState?) -> NSScreen? {
        if let id = state?.screenIdentifier,
           let match = NSScreen.screens.first(where: { screenIdentifier($0) == id }) { return match }
        if let frame = state?.frame,
           let match = NSScreen.screens.max(by: { $0.visibleFrame.intersection(frame).area < $1.visibleFrame.intersection(frame).area }),
           match.visibleFrame.intersects(frame) { return match }
        return NSScreen.main ?? NSScreen.screens.first
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
