import AppKit
import SwiftUI

/// Explicit click-through for the first deliberate click, without synthesising or
/// forwarding another event. WebKit keeps its own responder and keyboard handling.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One native surface owns the whole panel. No opaque container behind its corners.
@MainActor
enum PanelMaterial {
    static let cornerRadius: CGFloat = 20

    static func make(content: NSView) -> NSView {
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        content.layer?.cornerRadius = cornerRadius
        content.layer?.masksToBounds = true
        content.autoresizingMask = [.width, .height]
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            // AppKit requires contentView: arbitrary subviews can sit behind glass.
            glass.contentView = content
            return glass
        }
        let surface = PanelSurface(frame: .zero)
        content.frame = surface.bounds
        surface.addSubview(content)
        return surface
    }
}

/// A layer corner radius only clips ordinary subviews, not the WindowServer
/// backdrop produced by NSVisualEffectView. maskImage clips that material too.
final class PanelSurface: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = PanelMaterial.cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        updateOutline()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { updateOutline() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateOutline()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
    }
    private func updateOutline() {
        maskImage = Self.roundedMask(size: bounds.size)
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        window?.invalidateShadow()
    }
    // One small stretchable mask, reused throughout resizing. AppKit stretches
    // only its opaque centre; all four corner alpha shapes remain unchanged.
    private static let standardMask = makeMask(size: NSSize(width: 41, height: 41), radius: 20)
    static func roundedMask(size: NSSize) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        if size.width >= 41 && size.height >= 41 { return standardMask }
        return makeMask(size: size, radius: min(PanelMaterial.cornerRadius, min(size.width, size.height) / 2))
    }
    private static func makeMask(size: NSSize, radius: CGFloat) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        return image
    }
}
