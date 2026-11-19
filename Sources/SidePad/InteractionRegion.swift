import AppKit
import SwiftUI

struct InteractionRegion: NSViewRepresentable {
    enum Kind { case move, resize, resizeWidth }
    let kind: Kind
    let began: (NSPoint) -> Void
    let changed: (NSPoint) -> Void
    let ended: (NSPoint) -> Void

    func makeNSView(context: Context) -> RegionView {
        let view = RegionView()
        view.kind = kind
        view.began = began
        view.changed = changed
        view.ended = ended
        return view
    }

    func updateNSView(_ view: RegionView, context: Context) {
        view.kind = kind
        view.began = began
        view.changed = changed
        view.ended = ended
        view.window?.invalidateCursorRects(for: view)
    }
}

final class RegionView: NSView {
    var kind: InteractionRegion.Kind = .move
    var began: ((NSPoint) -> Void)?
    var changed: ((NSPoint) -> Void)?
    var ended: ((NSPoint) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        let cursor: NSCursor
        switch kind {
        case .move: cursor = .openHand
        case .resize: cursor = .resizeUpDown
        case .resizeWidth: cursor = .resizeLeftRight
        }
        addCursorRect(bounds, cursor: cursor)
    }
    override func mouseDown(with event: NSEvent) {
        if kind == .move { NSCursor.closedHand.push() }
        began?(screenPoint(for: event))
    }
    override func mouseDragged(with event: NSEvent) { changed?(screenPoint(for: event)) }
    override func mouseUp(with event: NSEvent) {
        ended?(screenPoint(for: event))
        if kind == .move { NSCursor.pop() }
    }
    private func screenPoint(for event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }
}

struct TaskDragSurface: NSViewRepresentable {
    let id: UUID
    let title: String
    let clicked: () -> Void
    let dragBegan: () -> Void
    let dragEnded: () -> Void

    func makeNSView(context: Context) -> TaskDragView {
        let view = TaskDragView()
        // The underlying SwiftUI Button provides keyboard/VoiceOver activation.
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: TaskDragView, context: Context) {
        view.id = id
        view.title = title
        view.clicked = clicked
        view.dragBegan = dragBegan
        view.dragEnded = dragEnded
    }
}

final class TaskDragView: NSView, NSDraggingSource {
    var id = UUID()
    var title = ""
    var clicked: (() -> Void)?
    var dragBegan: (() -> Void)?
    var dragEnded: (() -> Void)?
    private var mouseDownPoint: NSPoint?
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !dragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
        dragging = true
        dragBegan?()
        let item = NSDraggingItem(pasteboardWriter: id.uuidString as NSString)
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        (title as NSString).draw(in: bounds, withAttributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor
        ])
        image.unlockFocus()
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) {
        if !dragging { clicked?() }
        mouseDownPoint = nil
    }
    override func rightMouseDown(with event: NSEvent) { super.rightMouseDown(with: event) }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move]
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        mouseDownPoint = nil
        dragEnded?()
    }
}
