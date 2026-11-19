import AppKit
import SwiftUI
import Testing
@testable import SidePad

@Suite(.serialized) @MainActor
struct PanelMaterialTests {
    @Test func materialMaskExcludesAllFourCornersAfterResize() throws {
        _ = NSApplication.shared
        for size in [NSSize(width: 280, height: 280), NSSize(width: 640, height: 500)] {
            let surface = PanelSurface(frame: NSRect(origin: .zero, size: size))
            let mask = try #require(surface.maskImage)
            let tiff = try #require(mask.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            for point in [(0, 0), (bitmap.pixelsWide - 1, 0), (0, bitmap.pixelsHigh - 1),
                          (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1)] {
                #expect(bitmap.colorAt(x: point.0, y: point.1)?.alphaComponent == 0)
            }
            #expect(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.alphaComponent == 1)
            surface.setFrameSize(NSSize(width: size.width + 50, height: size.height + 20))
            #expect(surface.maskImage === mask)
        }
    }
    @Test func hostingViewAcceptsFirstClickAndNativeSurfaceKeepsContent() {
        let host = FirstMouseHostingView(rootView: Text("Click once"))
        #expect(host.acceptsFirstMouse(for: nil))
        let surface = PanelMaterial.make(content: host)
        if #available(macOS 26, *) {
            #expect((surface as? NSGlassEffectView)?.contentView === host)
            #expect((surface as? NSGlassEffectView)?.cornerRadius == PanelMaterial.cornerRadius)
        } else { #expect(surface is PanelSurface) }
    }
}
