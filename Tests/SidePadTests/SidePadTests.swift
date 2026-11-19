import Testing
import AppKit
@testable import SidePad

@Suite(.serialized)
@MainActor
struct SidePadTests {
    @Test func testFramesRespectUsableAreaAndPhysicalEdge() {
        do {
            let frames = PanelController.frames(
                screen: NSRect(x: -1440, y: 200, width: 1440, height: 900),
                usable: NSRect(x: -1440, y: 250, width: 1380, height: 826))
            #expect(frames.visible.minX == -540)
            #expect(frames.visible.minY == 415)
            #expect(frames.visible.height == 661)
            #expect(frames.hidden.minX == 0)
            #expect(frames.hidden.minY == 415)
            let left = PanelController.frames(
                screen: NSRect(x: -1440, y: 200, width: 1440, height: 900),
                usable: NSRect(x: -1380, y: 250, width: 1380, height: 826), side: .left)
            #expect(left.visible.minX == -1380)
            #expect(left.hidden.minX == -1920)
            #expect(left.visible.height == 661)
        }
    }

    @Test func testTriggerAndDelayedHideCancellation() {
        do {
            let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
            let usable = NSRect(x: 0, y: 40, width: 1440, height: 830)
            #expect(EdgeTriggerMonitor.isAtEdge(NSPoint(x: 1438, y: 400), screen: screen, usable: usable))
            #expect(!(EdgeTriggerMonitor.isAtEdge(NSPoint(x: 1430, y: 400), screen: screen, usable: usable)))
            #expect(!(EdgeTriggerMonitor.isAtEdge(NSPoint(x: 1438, y: 890), screen: screen, usable: usable)))
            #expect(EdgeTriggerMonitor.isAtEdge(NSPoint(x: 2, y: 400), screen: screen, usable: usable, side: .left))
            #expect(!EdgeTriggerMonitor.isAtEdge(NSPoint(x: 8, y: 400), screen: screen, usable: usable, side: .left))
            var delay = HideDelay()
            let result1 = delay.shouldHide(inside: true, shown: true, now: 0)
            #expect(!(result1))
            #expect(delay.deadline == nil)
            let result2 = delay.shouldHide(inside: false, shown: true, now: 1)
            #expect(!(result2))
            #expect(delay.deadline == 1.35)
            let result3 = delay.shouldHide(inside: false, shown: true, now: 1.3)
            #expect(!(result3))
            let result4 = delay.shouldHide(inside: true, shown: true, now: 1.34)
            #expect(!(result4))
            #expect(delay.deadline == nil)
            let result5 = delay.shouldHide(inside: false, shown: true, now: 2)
            #expect(!(result5))
            let result6 = delay.shouldHide(inside: false, shown: true, now: 2.36)
            #expect(result6)
            let result7 = delay.shouldHide(inside: false, shown: false, now: 3)
            #expect(!(result7))
            #expect(delay.deadline == nil)
        }
    }

    @Test func testAutoHidePolicyAndInteractionSuppression() {
        var delay = HideDelay()
        let started = delay.shouldHide(inside: false, shown: true, policy: .delayed(0.5), now: 1)
        #expect(!started)
        #expect(delay.deadline == 1.5)
        let suppressed = delay.shouldHide(inside: false, shown: true, interacting: true,
                                          policy: .delayed(0.5), now: 1.6)
        #expect(!suppressed)
        #expect(delay.deadline == nil)
        let resumed = delay.shouldHide(inside: false, shown: true, policy: .delayed(0.5), now: 2)
        #expect(!resumed)
        #expect(delay.deadline == 2.5)
        let infinite = delay.shouldHide(inside: false, shown: true, policy: .untilExternalClick, now: 10)
        #expect(!infinite)
        #expect(delay.deadline == nil)
        #expect(delay.shouldHideForExternalClick(shown: true, interacting: false,
                                                 policy: .untilExternalClick))
        #expect(!delay.shouldHideForExternalClick(shown: true, interacting: true,
                                                  policy: .untilExternalClick))
        #expect(!delay.shouldHideForExternalClick(shown: true, interacting: false,
                                                  policy: .delayed(0.5)))
        let floatingHide = delay.shouldHide(inside: false, shown: true, docked: false,
                                            policy: .delayed(0.5), now: 11)
        #expect(!floatingHide)
        #expect(delay.deadline == nil)
        #expect(!delay.shouldHideForExternalClick(shown: true, docked: false,
                                                  interacting: false, policy: .untilExternalClick))
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: defaults)
        store.hoverDelay = 0.8
        store.hideUntilExternalClick = true
        #expect(WorkspaceStore(defaults: defaults).autoHidePolicy == .untilExternalClick)
        store.hideUntilExternalClick = false
        #expect(WorkspaceStore(defaults: defaults).autoHidePolicy == .delayed(0.8))
    }

    @Test func testWebsiteRailRoutingAndSleepingSettings() {
        #expect(WebsiteRailAction.resolve(current: true, active: true, rightClick: false) == .controls)
        #expect(WebsiteRailAction.resolve(current: true, active: true, rightClick: true) == .controls)
        #expect(WebsiteRailAction.resolve(current: false, active: true, rightClick: false) == .switchAndWake)
        #expect(WebsiteRailAction.resolve(current: false, active: false, rightClick: true) == .settings)
        #expect(WebsiteRailAction.resolve(current: true, active: false, rightClick: false) == .switchAndWake)
        #expect(WebsiteRailAction.resolve(current: true, active: false, rightClick: true) == .settings)
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: defaults)
        #expect(store.addWebsite(name: "Example", urlText: "example.com") == nil)
        let id = store.websites[0].id
        let content = WebContent(loadPage: false)
        content.sleep(id)
        store.selection = .today
        store.setAutoSleep(id, enabled: true)
        #expect(!content.isActive(id))
        #expect(content.webView == nil)
        #expect(store.updateWebsite(id, name: "New Name", urlText: "example.org") == nil)
        #expect(!content.isActive(id))
        let restored = WorkspaceStore(defaults: defaults)
        #expect(restored.webItem(id: id)?.name == "New Name")
        #expect(restored.webItem(id: id)?.url.host == "example.org")
        #expect(restored.webItem(id: id)?.autoSleepWhenInactive == true)
    }

    @Test func testPanelAndWebViewSurviveRepeatedShowHide() throws {
        do {
            _ = NSApplication.shared
            let threadDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SidePadPanelTests-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: threadDirectory) }
            let controller = PanelController(loadPage: false, store: WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!), threads: ThreadStore(directory: threadDirectory))
            let panel = controller.panel
            controller.store.selection = .web(WebItem.chatGPTID)
            let webView = controller.webContent.webView
            #expect(WebContent.initialURL.absoluteString == "https://chatgpt.com/")
            #expect(webView?.configuration.websiteDataStore.isPersistent == true)
            let originalSurface = panel.contentView
            if #available(macOS 26, *) { #expect(originalSurface is NSGlassEffectView) }
            else { #expect(originalSurface is NSVisualEffectView) }
            guard let screen = NSScreen.main else {
                print("WindowServer unavailable; panel show/hide assertions skipped")
                return
            }
            #expect(panel.frame == controller.hiddenFrame)
            #expect(!(panel.isVisible))
            for _ in 0..<3 {
                controller.show(on: screen, animated: false)
                controller.show(on: screen, animated: false)
                #expect(controller.isShown)
                #expect(panel.frame == controller.visibleFrame)
                controller.hide(animated: false)
                controller.hide(animated: false)
                #expect(!(controller.isShown))
                #expect(!(panel.isVisible))
                #expect(panel.frame == controller.hiddenFrame)
                #expect(controller.panel === panel)
                #expect(controller.webContent.webView === webView)
                #expect(panel.contentView === originalSurface)
            }
            controller.floatWindow(animated: false)
            #expect(controller.store.placement == .floating)
            #expect(controller.panel === panel)
            #expect(controller.webContent.webView === webView)
            controller.dock(to: .left, on: screen, animated: false)
            #expect(controller.store.placement == .docked(edge: .left))
            #expect(controller.visibleFrame.minX == screen.visibleFrame.minX)
            #expect(controller.panel === panel)
            #expect(controller.webContent.webView === webView)
            controller.hide(animated: false)
        }
    }

    @Test func testWorkspaceHeightsAndRailMapping() {
        let usable = NSRect(x: 0, y: 30, width: 1440, height: 800)
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: defaults)
        let today = WindowGeometry.dockedFrame(usable: usable, edge: .left, presentation: .today)
        let tasks = WindowGeometry.dockedFrame(usable: usable, edge: .left, presentation: .tasks)
        let web = WindowGeometry.dockedFrame(usable: usable, edge: .left, presentation: .web)
        #expect(today.height < tasks.height && tasks.height < web.height)
        store.setHeightRatio(0.5, for: .today)
        store.setHeightRatio(0.7, for: .tasks)
        store.setHeightRatio(0.8, for: .web)
        let newToday = WindowGeometry.dockedFrame(usable: usable, edge: .right, presentation: .today,
                                                  heightRatio: store.heightRatio(for: .today))
        let newTasks = WindowGeometry.dockedFrame(usable: usable, edge: .right, presentation: .tasks,
                                                  heightRatio: store.heightRatio(for: .tasks))
        #expect(newToday.height == 280) // v0.6 manual Today height is ignored by content fitting.
        #expect(newTasks.height == 560)
        #expect(WindowGeometry.dockedFrame(usable: usable, edge: .left, presentation: .web,
                                          heightRatio: store.heightRatio(for: .web)).height == web.height)
        #expect(RailMetrics.width(.minimal) == 36)
        #expect(RailMetrics.width(.compact) == 40)
        #expect(RailMetrics.width(.standard) == 44)
        #expect(RailMetrics.width(.minimal) < RailMetrics.width(.compact))
        #expect(RailMetrics.width(.compact) < RailMetrics.width(.standard))
        let small = NSRect(x: 0, y: 0, width: 300, height: 260)
        #expect(WindowGeometry.minimumSize(floating: true, usable: small) == NSSize(width: 280, height: 260))
        #expect(WindowGeometry.minimumSize(floating: false, usable: small) == NSSize(width: 280, height: 260))
        store.floatingWindow = FloatingWindowState(frame: NSRect(x: 20, y: 30, width: 420, height: 350),
                                                    screenIdentifier: "display")
        let floating = store.floatingWindow
        store.setHeightRatio(0.6, for: .today)
        #expect(store.floatingWindow == floating)
        let restored = WorkspaceStore(defaults: defaults)
        #expect(restored.todayHeightRatio == 0.6)
        #expect(restored.tasksHeightRatio == 0.7)
        #expect(restored.webHeightRatio == 0.8)
        #expect(restored.floatingWindow == floating)
    }

    @Test func testWebsiteSleepPreferenceAndRuntime() {
        _ = NSApplication.shared
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: defaults)
        #expect(store.addWebsite(name: "Example", urlText: "example.com") == nil)
        let id = store.websites[0].id
        store.setAutoSleep(id, enabled: true)
        #expect(WorkspaceStore(defaults: defaults).webItem(id: id)?.autoSleepWhenInactive == true)
        let content = WebContent(loadPage: false)
        let page = URL(string: "https://example.com/deep/page")!
        content.rememberURL(page, for: id)
        content.select(.web(id), store: store)
        #expect(content.activeID == id)
        #expect(content.webView != nil)
        content.select(.today, store: store)
        #expect(!content.isActive(id))
        #expect(content.webView == nil)
        #expect(content.lastURL(for: store.webItem(id: id)!) == page)
        content.select(.web(id), store: store)
        #expect(content.isActive(id))
        #expect(content.activeID == id)
        #expect(content.webView != nil)
        store.setAutoSleep(id, enabled: false)
        content.select(.today, store: store)
        #expect(content.isActive(id))
        #expect(content.webView != nil)
        content.sleep(id)
        #expect(content.webView == nil)
        content.wake(id, url: store.webItem(id: id)!.url)
        #expect(content.isActive(id))
        #expect(content.activeID == id)
    }

    @Test func testV04SnapshotDecodesWithoutNewFields() throws {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: defaults)
        store.addTask("Keep me", toToday: true)
        #expect(store.addWebsite(name: "Example", urlText: "example.com") == nil)
        let data = try #require(defaults.data(forKey: "SidePad.workspace.v4"))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "todayHeightRatio")
        json.removeValue(forKey: "tasksHeightRatio")
        json.removeValue(forKey: "chatGPTAutoSleep")
        json.removeValue(forKey: "hideUntilExternalClick")
        var websites = try #require(json["websites"] as? [[String: Any]])
        websites[0].removeValue(forKey: "autoSleepWhenInactive")
        json["websites"] = websites
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "SidePad.workspace.v4")
        let restored = WorkspaceStore(defaults: defaults)
        #expect(restored.tasks.map(\.title) == ["Keep me"])
        #expect(restored.websites.count == 1)
        #expect(restored.websites[0].autoSleepWhenInactive == false)
        #expect(restored.todayHeightRatio == nil)
        #expect(restored.tasksHeightRatio == nil)
        #expect(restored.autoHidePolicy == .delayed(0.35))
    }

    @Test func testTaskWebsiteAndPreferencesPersist() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: defaults)
        #expect(store.selection == .today)
        store.addTask("First", toToday: true)
        store.addTask("Second", toToday: true)
        #expect(store.todayTasks.map(\.title) == ["First", "Second"])
        store.moveTask(store.todayTasks[1].id, by: -1)
        #expect(store.todayTasks.map(\.title) == ["Second", "First"])
        store.toggleCompleted(store.todayTasks[0].id)
        #expect(store.todayTasks.count == 1)
        #expect(store.todayPageTasks.count == 2)
        #expect(store.completedTasks.count == 1)
        store.setToday(store.todayTasks[0].id, false)
        #expect(store.inboxTasks.count == 1)
        #expect(store.addWebsite(name: "Invalid", urlText: "javascript:alert(1)") != nil)
        #expect(store.addWebsite(name: "Example", urlText: "example.com") == nil)
        store.side = .left
        store.placement = .docked(edge: .left)
        store.autoHide = false
        store.defaultPage = .lastOpened
        store.railWidthPreference = .compact
        store.showCompletedToday = false
        let restored = WorkspaceStore(defaults: defaults)
        #expect(restored.side == .left)
        #expect(!restored.autoHide)
        #expect(restored.selection == store.selection)
        #expect(restored.websites.count == 1)
        #expect(restored.tasks == store.tasks)
        #expect(restored.inboxTasks.count == 1)
        #expect(restored.railWidthPreference == .compact)
        #expect(!restored.showCompletedToday)
        #expect(restored.todayPageTasks.isEmpty)
    }

    @Test func testDragPlacementAndClearCompletedPersist() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: defaults)
        store.addTask("Today A", toToday: true)
        store.addTask("Today B", toToday: true)
        store.addTask("Inbox A", toToday: false)
        store.addTask("Inbox B", toToday: false)
        let todayA = store.todayTasks[0].id
        let inboxA = store.inboxTasks[0].id
        store.placeTask(todayA, inToday: true, relativeTo: store.todayTasks[1].id)
        #expect(store.todayTasks.map(\.title) == ["Today B", "Today A"])
        store.placeTask(todayA, inToday: true, relativeTo: todayA)
        #expect(store.todayTasks.map(\.title) == ["Today B", "Today A"])
        store.placeTask(inboxA, inToday: true, relativeTo: todayA)
        #expect(store.todayTasks.map(\.title) == ["Today B", "Inbox A", "Today A"])
        store.placeTask(todayA, inToday: false)
        #expect(store.inboxTasks.map(\.title) == ["Inbox B", "Today A"])
        store.placeTask(todayA, inToday: false, relativeTo: store.inboxTasks[0].id)
        #expect(store.inboxTasks.map(\.title) == ["Today A", "Inbox B"])
        // A section-background drop uses nil target: append to the task list.
        store.placeTask(todayA, inToday: false)
        #expect(store.inboxTasks.map(\.title) == ["Inbox B", "Today A"])
        store.placeTask(store.inboxTasks[1].id, inToday: false, relativeTo: store.inboxTasks[0].id)
        #expect(store.inboxTasks.map(\.title) == ["Today A", "Inbox B"])
        store.toggleCompleted(inboxA)
        #expect(store.completedTasks.count == 1)
        let restored = WorkspaceStore(defaults: defaults)
        #expect(restored.todayTasks.map(\.title) == ["Today B"])
        #expect(restored.inboxTasks.map(\.title) == ["Today A", "Inbox B"])
        restored.clearCompleted()
        #expect(WorkspaceStore(defaults: defaults).completedTasks.isEmpty)
    }

    @Test func testIndependentPresentation() throws {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: defaults)
        store.addTask("Preserved", toToday: true)
        let screen = NSRect(x: 1600, y: 0, width: 1920, height: 1080)
        let usable = NSRect(x: 1600, y: 30, width: 1920, height: 1010)
        let today = PanelController.frames(screen: screen, usable: usable, side: .right, presentation: .today)
        let tasks = PanelController.frames(screen: screen, usable: usable, side: .right, presentation: .tasks)
        let web = PanelController.frames(screen: screen, usable: usable, side: .right, presentation: .web)
        #expect(today.visible.height < tasks.visible.height && tasks.visible.height < web.visible.height)
        #expect(today.visible.maxX == usable.maxX && tasks.visible.maxX == usable.maxX)
        #expect(today.visible.maxY == usable.maxY && web.visible.maxY == usable.maxY)
        let left = PanelController.frames(screen: screen, usable: usable, side: .left, presentation: .today)
        #expect(left.visible.minX == usable.minX)
        #expect(left.visible.height == today.visible.height)
    }

    @Test func testRevealClampDockDetectionAndFloatingRestore() {
        let screen = NSRect(x: -1440, y: 0, width: 1440, height: 900)
        let usable = NSRect(x: -1440, y: 30, width: 1440, height: 830)
        let low = PanelController.frames(screen: screen, usable: usable, side: .left,
            presentation: .today, anchorY: 35)
        #expect(low.visible.minY == usable.minY)
        let high = PanelController.frames(screen: screen, usable: usable, side: .right,
            presentation: .today, anchorY: 850)
        #expect(high.visible.maxY == usable.maxY)
        let centered = PanelController.frames(screen: screen, usable: usable, side: .right,
            presentation: .today, anchorY: 450)
        #expect(abs(centered.visible.midY - 450) < 0.001)
        #expect(WindowGeometry.dockTarget(point: NSPoint(x: -1430, y: 400),
            screen: screen, usable: usable) == .left)
        #expect(WindowGeometry.dockTarget(point: NSPoint(x: -20, y: 400),
            screen: screen, usable: usable) == .right)
        #expect(WindowGeometry.dockTarget(point: NSPoint(x: -40, y: 400),
            screen: screen, usable: usable) == nil)
        #expect(WindowGeometry.dockTarget(point: NSPoint(x: -100, y: 400),
            screen: screen, usable: usable) == nil)
        #expect(WindowGeometry.dockTarget(frame: NSRect(x: -1425, y: 200, width: 400, height: 300),
            usable: usable) == .left)
        #expect(WindowGeometry.dockTarget(frame: NSRect(x: -400, y: 200, width: 390, height: 300),
            usable: usable) == .right)
        #expect(WindowGeometry.detachThreshold > WindowGeometry.dockDetectionThreshold)
        #expect(!WindowGeometry.shouldDetach(from: NSPoint(x: -10, y: 400),
            to: NSPoint(x: -73, y: 400), edge: .right))
        #expect(WindowGeometry.shouldDetach(from: NSPoint(x: -10, y: 400),
            to: NSPoint(x: -74, y: 400), edge: .right))
        #expect(WindowGeometry.shouldDetach(from: NSPoint(x: -1430, y: 400),
            to: NSPoint(x: -1366, y: 400), edge: .left))
        #expect(!WindowGeometry.shouldDetach(from: NSPoint(x: -1430, y: 400),
            to: NSPoint(x: -1494, y: 400), edge: .left))
        let clamped = WindowGeometry.clampedFloatingFrame(
            NSRect(x: 5000, y: -1000, width: 1000, height: 500), usable: usable)
        #expect(clamped.maxX == usable.maxX)
        #expect(clamped.minY == usable.minY)
    }

    @Test func testDetachFrameKeepsDockedSize() {
        let usable = NSRect(x: 0, y: 30, width: 1200, height: 800)
        for width: CGFloat in [280, 300, 430, 550] {
            let docked = NSRect(x: usable.maxX - width, y: 200, width: width, height: 510)
            let floating = WindowGeometry.floatingFramePreservingSize(docked, usable: usable)
            #expect(floating.size == docked.size)
            #expect(WindowGeometry.clampedFloatingFrame(floating, usable: usable).size == docked.size)
            #expect(WindowGeometry.floatingFramePreservingSize(floating, usable: usable) == floating)
        }
    }

    @Test func testPlacementWebHeightAndMinimalRailPersist() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: defaults)
        store.placement = .floating
        store.side = .left
        store.floatingWindow = FloatingWindowState(frame: CGRect(x: 10, y: 20, width: 500, height: 400),
                                                    screenIdentifier: "123")
        store.webHeightRatio = 0.76
        store.railWidthPreference = .minimal
        let restored = WorkspaceStore(defaults: defaults)
        #expect(restored.placement == .floating)
        #expect(restored.side == .left)
        #expect(restored.floatingWindow == store.floatingWindow)
        #expect(restored.webHeightRatio == 0.76)
        #expect(restored.railWidthPreference == .minimal)
        store.railWidthPreference = .compact
        #expect(WorkspaceStore(defaults: defaults).railWidthPreference == .compact)
        store.railWidthPreference = .standard
        #expect(WorkspaceStore(defaults: defaults).railWidthPreference == .standard)
        let web = PanelController.frames(screen: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            usable: CGRect(x: 0, y: 20, width: 1600, height: 900), webHeightRatio: 0.76)
        #expect(web.visible.height == 684)
        let defaultWeb = PanelController.frames(screen: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            usable: CGRect(x: 0, y: 20, width: 1600, height: 900))
        #expect(defaultWeb.visible.height == 720)
        store.webHeightRatio = 2
        #expect(WorkspaceStore(defaults: defaults).webHeightRatio == 0.92)
    }

    @Test func testIndependentWorkspaceSizesAndTodayFit() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: defaults)
        store.setSize(CGSize(width: 430, height: 510), for: .tasks)
        store.setSize(CGSize(width: 550, height: 720), for: .web)
        store.setSize(CGSize(width: 900, height: 900), for: .today)
        store.selection = .tasks
        store.selection = .web(WebItem.chatGPTID)
        store.selection = .today
        let restored = WorkspaceStore(defaults: defaults)
        #expect(restored.tasksSize == CGSize(width: 430, height: 510))
        #expect(restored.webSize == CGSize(width: 550, height: 720))
        #expect(restored.todayWidth == 900)
        #expect(restored.size(for: .today)?.width == 900)
        let usable = NSRect(x: 0, y: 30, width: 1200, height: 800)
        let tasks = WindowGeometry.dockedFrame(usable: usable, edge: .right, presentation: .tasks,
                                               savedSize: restored.tasksSize)
        let web = WindowGeometry.dockedFrame(usable: usable, edge: .left, presentation: .web,
                                             savedSize: restored.webSize)
        #expect(tasks.size == CGSize(width: 430, height: 510))
        #expect(web.size == CGSize(width: 550, height: 720))
        let short = WindowGeometry.dockedFrame(usable: usable, edge: .right, presentation: .today,
                                               todayHeight: 240)
        let tall = WindowGeometry.dockedFrame(usable: usable, edge: .right, presentation: .today,
                                              todayHeight: 400)
        let overflow = WindowGeometry.dockedFrame(usable: usable, edge: .right, presentation: .today,
                                                  todayHeight: 1200)
        #expect(short.height == 240 && tall.height == 400)
        #expect(overflow.height == 788)
        #expect(restored.tasksSize == store.tasksSize && restored.webSize == store.webSize)
    }

    @Test func testTodayWidthAndWebsiteTitlePersistAcrossSelections() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: defaults)
        store.setSize(CGSize(width: 525, height: 400), for: .today)
        #expect(store.activeWebsiteTitle == "Web")
        store.selection = .web(WebItem.chatGPTID)
        #expect(store.activeWebsiteTitle == "ChatGPT")
        #expect(store.addWebsite(name: "YouTube", urlText: "youtube.com") == nil)
        let id = store.websites[0].id
        store.selection = .web(id)
        #expect(store.activeWebsiteTitle == "YouTube")
        #expect(store.updateWebsite(id, name: "  ", urlText: "example.com") == nil)
        #expect(store.activeWebsiteTitle == "example.com")
        store.selection = .web(UUID())
        #expect(store.activeWebsiteTitle == "Web")
        store.selection = .tasks
        store.selection = .today
        let restored = WorkspaceStore(defaults: defaults)
        #expect(restored.todayWidth == 525)
        let usable = NSRect(x: 0, y: 30, width: 480, height: 800)
        let frame = WindowGeometry.dockedFrame(usable: usable, edge: .right, presentation: .today,
                                               savedSize: restored.size(for: .today), todayHeight: 280)
        #expect(frame.width == 480)
    }

    @Test func testDockedFrameTracksFloatingCenterAtBothEdges() {
        let usable = NSRect(x: 20, y: 40, width: 1200, height: 800)
        for edge in DockEdge.allCases {
            for centerY: CGFloat in [70, 440, 810] {
                let frame = WindowGeometry.dockedFrame(usable: usable, edge: edge, presentation: .today,
                    anchorY: centerY, savedSize: CGSize(width: 420, height: 0), todayHeight: 310)
                #expect(frame.minY >= usable.minY && frame.maxY <= usable.maxY)
                #expect(frame.minX == (edge == .left ? usable.minX : usable.maxX - frame.width))
                #expect(abs(frame.midY - centerY) <= (centerY < usable.midY
                    ? max(0, frame.height / 2 - (centerY - usable.minY))
                    : max(0, frame.height / 2 - (usable.maxY - centerY))) + 1)
            }
        }
    }

    @Test func testTodayHeightIncludesCurrentRailAndScreenCap() {
        let usable = NSRect(x: 0, y: 30, width: 1200, height: 800)
        let emptyRail = RailMetrics.requiredHeight(websiteCount: 1)
        let loadedRail = RailMetrics.requiredHeight(websiteCount: 8)
        #expect(loadedRail > emptyRail)
        #expect(WindowGeometry.fittedTodayHeight(190, railHeight: emptyRail, usable: usable) == emptyRail)
        #expect(WindowGeometry.fittedTodayHeight(190, railHeight: loadedRail, usable: usable) == loadedRail)
        #expect(WindowGeometry.fittedTodayHeight(600, railHeight: emptyRail, usable: usable) == 600)
        #expect(WindowGeometry.fittedTodayHeight(190, railHeight: 2000, usable: usable) == 788)

        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: defaults)
        let initial = RailMetrics.requiredHeight(websiteCount: store.webItems.count)
        for n in 0..<7 { #expect(store.addWebsite(name: "Site \(n)", urlText: "site\(n).example") == nil) }
        let added = RailMetrics.requiredHeight(websiteCount: store.webItems.count)
        #expect(added > initial)
        store.deleteWebsite(store.websites[0].id)
        #expect(RailMetrics.requiredHeight(websiteCount: store.webItems.count) < added)
        let restored = WorkspaceStore(defaults: defaults)
        #expect(RailMetrics.requiredHeight(websiteCount: restored.webItems.count) ==
                RailMetrics.requiredHeight(websiteCount: store.webItems.count))
    }

    @Test func testEmptyDestinationAppendsWithoutChangingNonemptyPlacement() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: defaults)
        store.addTask("Inbox", toToday: false)
        let first = store.inboxTasks[0].id
        store.placeTask(first, inToday: true)
        #expect(store.todayTasks.map(\.title) == ["Inbox"])
        store.placeTask(first, inToday: false)
        #expect(store.inboxTasks.map(\.title) == ["Inbox"])
        store.addTask("Second", toToday: false)
        store.placeTask(store.inboxTasks[1].id, inToday: false, relativeTo: first)
        #expect(store.inboxTasks.map(\.title) == ["Second", "Inbox"])
    }

    @Test func testActionMenuHoldAndTodayResizePolicy() {
        _ = NSApplication.shared
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: defaults)
        let threadDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SidePadPanelTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: threadDirectory) }
        let controller = PanelController(loadPage: false, store: store, threads: ThreadStore(directory: threadDirectory))
        let placement = store.placement
        let delay = store.hoverDelay
        controller.setActionMenuPresented(true)
        #expect(controller.panelInteractionActive)
        #expect(!HideDelay().shouldHideForExternalClick(shown: true, interacting: controller.panelInteractionActive,
                                                        policy: .untilExternalClick))
        controller.setActionMenuPresented(false)
        #expect(!controller.panelInteractionActive)
        #expect(store.placement == placement && store.hoverDelay == delay && store.autoHide)
        store.selection = .today
        let proposal = controller.windowWillResize(controller.panel, to: NSSize(width: 510, height: 700))
        #expect(proposal.width == 510 && proposal.height == controller.panel.frame.height)
        store.selection = .tasks
        #expect(controller.windowWillResize(controller.panel, to: NSSize(width: 510, height: 700)) ==
                NSSize(width: 510, height: 700))
        store.selection = .web(WebItem.chatGPTID)
        #expect(controller.windowWillResize(controller.panel, to: NSSize(width: 520, height: 710)) ==
                NSSize(width: 520, height: 710))
        controller.setActionMenuPresented(true)
        #expect(controller.panelInteractionActive)
        #expect(controller.effectiveAutoHide)
        controller.setActionMenuPresented(false)
    }

    @Test func testFaviconLinkDiscovery() {
        let base = URL(string: "https://example.com/sub/page")!
        let html = #"<link href='/assets/site.png' rel='shortcut icon'><link rel="stylesheet" href="style.css"><link rel="apple-touch-icon" href="https://cdn.example.com/touch.png">"#
        let icons = FaviconStore.iconURLs(in: html, base: base)
        #expect(icons.map(\.absoluteString) == [
            "https://example.com/assets/site.png", "https://cdn.example.com/touch.png"
        ])
    }

    @Test func testSideAndPinChangesApplyImmediately() async {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else {
            print("WindowServer unavailable; live side/pin assertions skipped")
            return
        }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = WorkspaceStore(defaults: defaults)
        let threadDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SidePadPanelTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: threadDirectory) }
        let controller = PanelController(loadPage: false, store: store, threads: ThreadStore(directory: threadDirectory))
        let monitor = EdgeTriggerMonitor(controller: controller)
        monitor.start()
        #expect(monitor.isMonitoring)
        controller.show(on: screen, animated: false)
        store.autoHide = false
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(!monitor.isMonitoring)
        #expect(controller.isShown)
        controller.dock(to: .left, on: screen, animated: false)
        #expect(controller.panel.frame == controller.visibleFrame)
        #expect(controller.visibleFrame.minX == screen.visibleFrame.minX)
        store.autoHide = true
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(monitor.isMonitoring)
        monitor.stop()
        controller.hide(animated: false)
    }

    @Test func testLiveWorkspaceFramesAndFloatingResize() async {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else {
            print("WindowServer unavailable; live resize assertions skipped")
            return
        }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = WorkspaceStore(defaults: defaults)
        let threadDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SidePadPanelTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: threadDirectory) }
        let controller = PanelController(loadPage: false, store: store, threads: ThreadStore(directory: threadDirectory))
        controller.show(on: screen, animated: false)
        let todayHeight = controller.panel.frame.height
        store.selection = .tasks
        try? await Task.sleep(nanoseconds: 30_000_000)
        let tasksHeight = controller.panel.frame.height
        store.selection = .web(UUID())
        try? await Task.sleep(nanoseconds: 30_000_000)
        let webHeight = controller.panel.frame.height
        #expect(todayHeight < tasksHeight && tasksHeight < webHeight)
        store.selection = .today
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(controller.panel.frame.height < tasksHeight)
        #expect(store.todayHeightRatio == nil)
        store.selection = .tasks
        try? await Task.sleep(nanoseconds: 30_000_000)
        let start = NSPoint(x: controller.panel.frame.midX, y: controller.panel.frame.minY + 5)
        let resizeEnd = NSPoint(x: start.x, y: start.y - 70)
        controller.beginResize(at: start)
        #expect(controller.panelInteractionActive)
        controller.hide(animated: false)
        #expect(controller.isShown)
        controller.resize(to: resizeEnd)
        controller.endResize(at: resizeEnd)
        #expect(!controller.panelInteractionActive)
        let resizedTasks = controller.panel.frame.size
        #expect(resizedTasks.height > tasksHeight)
        controller.hide(animated: false)
        controller.show(on: screen, animated: false)
        #expect(controller.panel.frame.size == resizedTasks)
        #expect(WorkspaceStore(defaults: defaults).tasksSize == resizedTasks)
        controller.floatWindow(animated: false)
        #expect(controller.panel.styleMask.contains(.resizable))
        let manual = NSRect(x: screen.visibleFrame.minX + 80, y: screen.visibleFrame.minY + 80,
                            width: 500, height: 500)
        controller.panel.setFrame(manual, display: true)
        #expect(store.floatingWindow?.frame == controller.panel.frame)
        let floating = controller.panel.frame
        store.selection = .web(WebItem.chatGPTID)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(controller.panel.frame.size != floating.size)
        store.selection = .tasks
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(controller.panel.frame.size == floating.size)
        controller.dock(to: .left, on: screen, animated: false)
        #expect(controller.panel.frame.size == floating.size)
        #expect(controller.panel.frame.minX == screen.visibleFrame.minX)
        let docked = controller.panel.frame
        controller.floatWindow(animated: false)
        #expect(controller.panel.frame.size == docked.size)
        controller.dock(to: .left, on: screen, animated: false)
        controller.hide(animated: false)
    }

    @Test func testLiveTodayWidthSurvivesHideRevealAndWorkspaceSwitch() async {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else {
            print("WindowServer unavailable; live Today width assertions skipped")
            return
        }
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: defaults)
        let threadDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SidePadPanelTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: threadDirectory) }
        let controller = PanelController(loadPage: false, store: store, threads: ThreadStore(directory: threadDirectory))
        controller.show(on: screen, animated: false)
        let start = controller.panel.frame
        let resizedWidth = min(screen.visibleFrame.width, start.width + 55)
        controller.panel.setFrame(NSRect(x: screen.visibleFrame.maxX - resizedWidth, y: start.minY,
                                         width: resizedWidth, height: start.height), display: true)
        #expect(store.todayWidth == resizedWidth)
        controller.hide(animated: false)
        controller.show(on: screen, animated: false)
        #expect(controller.panel.frame.width == resizedWidth)
        store.selection = .tasks
        try? await Task.sleep(nanoseconds: 40_000_000)
        store.selection = .today
        try? await Task.sleep(nanoseconds: 40_000_000)
        #expect(controller.panel.frame.width == resizedWidth)
        #expect(WorkspaceStore(defaults: defaults).todayWidth == resizedWidth)
        controller.hide(animated: false)
    }
}
