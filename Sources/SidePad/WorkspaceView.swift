import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

enum RailMetrics {
    static let iconSize: CGFloat = 20
    static let minimumHitSize: CGFloat = 32
    static let itemHeight: CGFloat = 32
    static let visualHeight: CGFloat = 29
    static let itemSpacing: CGFloat = 2
    static let dividerPadding: CGFloat = 2
    static let verticalPadding: CGFloat = 7
    static let bottomActionPadding: CGFloat = 6
    static func requiredHeight(websiteCount: Int) -> CGFloat {
        let count = max(0, websiteCount)
        // Five fixed controls, two dividers, the bottom action and every website icon.
        return 2 * verticalPadding + bottomActionPadding + 6 * itemHeight
            + 2 * (1 + 2 * dividerPadding) + 9 * itemSpacing
            + CGFloat(count) * itemHeight + CGFloat(max(0, count - 1)) * itemSpacing
    }
    static func width(_ preference: RailWidthPreference) -> CGFloat {
        switch preference { case .minimal: minimumHitSize + 4; case .compact: 40; case .standard: 44 }
    }
    static func hit(_ preference: RailWidthPreference) -> CGFloat {
        preference == .minimal ? minimumHitSize : 38
    }
    static func visual(_ preference: RailWidthPreference) -> CGFloat {
        switch preference { case .minimal: 28; case .compact: 28; case .standard: 36 }
    }
}

private enum TaskLayout {
    static let rowSpacing: CGFloat = 2
    static let rowPadding: CGFloat = 3
    static let addPadding: CGFloat = 5
    static let sectionSpacing: CGFloat = 8
    static let todayInset: CGFloat = 7
    static let tasksInset: CGFloat = 10
    static let checkboxSpacing: CGFloat = 4
    static let iconColumnWidth: CGFloat = 36
}

enum HeaderMetrics {
    static let regularHeight: CGFloat = 28
    static let todayHeight: CGFloat = 69
}

private struct RailChevron: Shape {
    let edge: DockEdge

    func path(in rect: CGRect) -> Path {
        let tailX = edge == .right ? rect.minX + rect.width * 0.25 : rect.maxX - rect.width * 0.25
        let tipX = edge == .right ? rect.maxX - rect.width * 0.25 : rect.minX + rect.width * 0.25
        var path = Path()
        path.move(to: CGPoint(x: tailX, y: rect.minY))
        path.addLine(to: CGPoint(x: tipX, y: rect.midY))
        path.addLine(to: CGPoint(x: tailX, y: rect.maxY))
        return path
    }
}

@MainActor
final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()
    @Published private(set) var images: [String: NSImage] = [:]
    @Published private(set) var failed = Set<String>()
    private var attempted = Set<String>()

    private func cacheURL(for host: String) -> URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let safeHost = "favicon-" + host.lowercased().replacingOccurrences(of: ":", with: "_")
        return root.appendingPathComponent("SidePad/Favicons", isDirectory: true)
            .appendingPathComponent(safeHost, isDirectory: false)
    }

    func load(url: URL) {
        guard let host = url.host, attempted.insert(host).inserted else { return }
        let cached = cacheURL(for: host)
        if let cached, let data = try? Data(contentsOf: cached), let image = NSImage(data: data) {
            images[host] = image
        }
        Task {
            let origin = URL(string: "\(url.scheme ?? "https")://\(host)")!
            var candidates = [origin.appendingPathComponent("favicon.ico")]
            if let (html, response) = try? await URLSession.shared.data(for: URLRequest(url: origin, timeoutInterval: 8)),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let source = String(data: html.prefix(512_000), encoding: .utf8) {
                candidates.insert(contentsOf: Self.iconURLs(in: source, base: response.url ?? origin), at: 0)
            }
            for candidate in candidates.prefix(8) {
                guard let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: candidate, timeoutInterval: 8)),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      data.count < 1_000_000, let image = NSImage(data: data) else { continue }
                images[host] = image
                if let cached {
                    try? FileManager.default.createDirectory(at: cached.deletingLastPathComponent(),
                                                              withIntermediateDirectories: true)
                    try? data.write(to: cached, options: .atomic)
                }
                return
            }
            if images[host] == nil { failed.insert(host) }
        }
    }

    static func iconURLs(in html: String, base: URL) -> [URL] {
        guard let tags = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: .caseInsensitive),
              let attributes = try? NSRegularExpression(pattern: #"([\w-]+)\s*=\s*(["'])(.*?)\2"#,
                                                        options: .caseInsensitive) else { return [] }
        let source = html as NSString
        return tags.matches(in: html, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let tag = source.substring(with: match.range)
            let nsTag = tag as NSString
            var values: [String: String] = [:]
            for attribute in attributes.matches(in: tag, range: NSRange(location: 0, length: nsTag.length)) {
                values[nsTag.substring(with: attribute.range(at: 1)).lowercased()] =
                    nsTag.substring(with: attribute.range(at: 3))
            }
            guard values["rel"]?.lowercased().contains("icon") == true,
                  let href = values["href"]?.replacingOccurrences(of: "&amp;", with: "&"),
                  let icon = URL(string: href, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(icon.scheme?.lowercased() ?? "") else { return nil }
            return icon
        }
    }
}

struct FaviconView: View {
    let item: WebItem
    @ObservedObject private var favicons = FaviconStore.shared

    var body: some View {
        Group {
            if let host = item.url.host, let image = favicons.images[host] {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else if let host = item.url.host, !favicons.failed.contains(host) {
                Image(systemName: "globe").font(.system(size: 15)).foregroundStyle(.secondary)
            } else {
                Text(String(item.name.prefix(1)).uppercased())
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: RailMetrics.iconSize, height: RailMetrics.iconSize)
        .task(id: item.url) { favicons.load(url: item.url) }
    }
}

struct WebContainer: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct WebsiteIconTarget: NSViewRepresentable {
    let label: String
    let tooltip: String
    let leftClick: () -> Void
    let rightClick: () -> Void
    func makeNSView(context: Context) -> WebsiteIconView {
        let view = WebsiteIconView()
        view.leftClick = leftClick
        view.rightClick = rightClick
        view.setAccessibilityLabel(label)
        view.toolTip = tooltip
        return view
    }
    func updateNSView(_ view: WebsiteIconView, context: Context) {
        view.leftClick = leftClick
        view.rightClick = rightClick
        view.setAccessibilityLabel(label)
        view.toolTip = tooltip
    }
}

final class WebsiteIconView: NSButton {
    var leftClick: (() -> Void)?
    var rightClick: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        target = self
        action = #selector(open)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func open() { leftClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) { rightClick?() }
}

struct RailActionMenu: NSViewRepresentable {
    let width: CGFloat
    let interaction: (Bool) -> Void
    let addTask: () -> Void
    let addWebsite: () -> Void

    func makeNSView(context: Context) -> RailActionButton { RailActionButton() }
    func updateNSView(_ view: RailActionButton, context: Context) {
        view.interaction = interaction
        view.addTask = addTask
        view.addWebsite = addWebsite
        view.frame.size = NSSize(width: width, height: RailMetrics.itemHeight)
    }
}

final class RailActionButton: NSButton {
    var interaction: ((Bool) -> Void)?
    var addTask: (() -> Void)?
    var addWebsite: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Task or Website")?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        imagePosition = .imageOnly
        setAccessibilityLabel("Add Task or Website")
        toolTip = "Add Task or Website"
        target = self
        action = #selector(openMenu)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func openMenu() {
        let menu = NSMenu()
        let task = menu.addItem(withTitle: "Add Task", action: #selector(selectTask), keyEquivalent: "")
        let website = menu.addItem(withTitle: "Add Website", action: #selector(selectWebsite), keyEquivalent: "")
        task.target = self
        website.target = self
        interaction?(true)
        defer { interaction?(false) }
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.minY), in: self)
    }
    @objc private func selectTask() { addTask?() }
    @objc private func selectWebsite() { addWebsite?() }
}

enum WebsitePopoverLevel { case controls, settings }

enum WebsiteRailAction: Equatable {
    case controls, settings, switchAndWake
    static func resolve(current: Bool, active: Bool, rightClick: Bool) -> Self {
        if current && active { return .controls }
        return rightClick ? .settings : .switchAndWake
    }
}

struct WorkspaceView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var webContent: WebContent
    @ObservedObject var threads: ThreadStore
    @ObservedObject var aiSettings: AISettingsStore
    @ObservedObject var threadsCoordinator: ThreadsCoordinator
    @ObservedObject var threadsViewState: ThreadsViewState
    @ObservedObject var attachments: AttachmentStore
    let hide: () -> Void
    let beginMove: (NSPoint) -> Void
    let move: (NSPoint) -> Void
    let endMove: (NSPoint) -> Void
    let beginResize: (NSPoint) -> Void
    let resize: (NSPoint) -> Void
    let endResize: (NSPoint) -> Void
    let preferredTodayHeight: (CGFloat) -> Void
    let actionMenuInteraction: (Bool) -> Void
    @State private var showTaskSheet = false
    @State private var showWebsiteSheet = false
    @State private var popoverWebID: UUID?
    @State private var popoverLevel: WebsitePopoverLevel = .controls
    @State private var popoverFromHeader = false
    @State private var progressTarget: ProgressMemoryTarget?

    var body: some View {
        HStack(spacing: 0) {
            if store.side == .right { rail }
            VStack(spacing: 0) {
                header
                if let error = store.persistenceError {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .textSelection(.enabled).padding(10)
                }
                if let error = store.taskError {
                    HStack {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        Button("Dismiss") { store.taskError = nil }.controlSize(.small)
                    }.padding(10)
                }
                content
                    .disabled(store.isReadOnly)
                if store.placement != .floating && store.selection.presentation != .today { webResizeHandle }
            }
            .overlay(alignment: .bottomTrailing) {
                if store.placement == .floating { floatingResizeHandle }
            }
            .overlay(alignment: store.side == .right ? .bottomLeading : .bottomTrailing) {
                if store.placement != .floating && store.selection.presentation == .today { todayWidthResizeHandle }
            }
            if store.side == .left { rail }
        }
        .background(Color.clear)
        .sheet(isPresented: $showTaskSheet) { AddTaskView(store: store) }
        .sheet(isPresented: $showWebsiteSheet) { AddWebsiteView(store: store) }
        .sheet(item: $progressTarget) { target in
            ProgressMemorySheet(target: target, workspace: store, threads: threads,
                                coordinator: threadsCoordinator, viewState: threadsViewState)
        }
        .onChange(of: store.selection) { _, selection in
            if case let .web(id) = selection, id == popoverWebID { return }
            popoverWebID = nil
        }
    }

    private var header: some View {
        InteractionRegion(kind: .move, began: beginMove, changed: move, ended: endMove)
        .overlay(alignment: .leading) {
            if store.selection.presentation == .today {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(store.todayTasks.count)")
                            .font(.system(size: 36, weight: .semibold))
                        Text("remaining").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(store.currentDay, format: .dateTime.day().month(.wide).weekday(.wide))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, TaskLayout.todayInset)
                .padding(.top, RailMetrics.verticalPadding)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
            } else if store.selection.presentation == .web {
                Text(store.activeWebsiteTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 17)
                    .allowsHitTesting(false)
            } else if store.selection == .threads {
                Text("Threads")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .trailing) {
            if case let .web(id) = store.selection, let item = store.webItem(id: id) {
                Button { showCurrentWebsiteControls(for: item, fromHeader: true) } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 36, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Current website controls")
                .accessibilityLabel("Current website controls")
                .padding(.trailing, 10)
                .popover(isPresented: Binding(get: { popoverFromHeader && popoverWebID == id },
                                              set: { if !$0 { popoverWebID = nil } }),
                         arrowEdge: .top) { websitePopover(item) }
            }
        }
        .frame(height: store.selection.presentation == .today ? HeaderMetrics.todayHeight :
            store.selection.presentation == .web ? 32 : HeaderMetrics.regularHeight)
        .background(.ultraThinMaterial)
        .accessibilityLabel("Drag Side Pad window")
    }

    private var webResizeHandle: some View {
        ZStack {
            InteractionRegion(kind: .resize, began: beginResize, changed: resize, ended: endResize)
            Capsule().fill(Color.secondary.opacity(0.42)).frame(width: 34, height: 3)
                .allowsHitTesting(false)
        }
        .frame(height: 11)
        .background(.ultraThinMaterial)
        .help("Drag to resize workspace height")
    }

    private var todayWidthResizeHandle: some View {
        InteractionRegion(kind: .resizeWidth, began: beginResize, changed: resize, ended: endResize)
            .frame(width: 9, height: 42)
            .padding(.bottom, 8)
            .help("Drag to resize Today width")
    }

    private var floatingResizeHandle: some View {
        InteractionRegion(kind: .resize, began: beginResize, changed: resize, ended: endResize)
        .frame(width: 20, height: 20)
        .padding(3)
    }

    private var content: some View {
        Group {
            switch store.selection {
            case .today:
                TodayView(store: store, preferredHeight: preferredTodayHeight,
                          openTaskHistory: { progressTarget = .task($0) })
            case .tasks:
                TasksView(store: store, openTaskHistory: { progressTarget = .task($0) })
            case .threads:
                ThreadsView(workspace: store, threads: threads, settings: aiSettings, attachments: attachments,
                            coordinator: threadsCoordinator, viewState: threadsViewState)
            case let .web(id):
                if let item = store.webItem(id: id) {
                    WebWorkspaceView(item: item, webContent: webContent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(store.selection)
        .transition(.opacity.animation(reduceMotion ? nil : .easeInOut(duration: 0.18)))
    }

    private var rail: some View {
        VStack(spacing: RailMetrics.itemSpacing) {
            Button(action: hide) {
                RailChevron(edge: store.side)
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .frame(width: 12, height: 12)
                    .frame(width: RailMetrics.visual(store.railWidthPreference), height: RailMetrics.visualHeight)
                    .frame(width: RailMetrics.hit(store.railWidthPreference), height: RailMetrics.itemHeight)
            }
            .buttonStyle(.plain)
            .help("Hide panel")
            .accessibilityLabel("Hide panel")
            railButton(store.autoHide ? "pin.slash" : "pin.fill",
                       label: store.autoHide ? "Pin panel" : "Turn on Auto Hide",
                       selected: !store.autoHide) { store.autoHide.toggle() }
            Divider().opacity(0.55).padding(.vertical, RailMetrics.dividerPadding)
            railButton("checkmark.circle", label: "Today", selected: store.selection == .today) { store.selection = .today }
            railButton("list.bullet", label: "Tasks", selected: store.selection == .tasks) { store.selection = .tasks }
            railButton("point.3.connected.trianglepath.dotted", label: "Threads", selected: store.selection == .threads) { store.selection = .threads }
            Divider().opacity(0.55).padding(.vertical, RailMetrics.dividerPadding)
            ScrollView {
                VStack(spacing: RailMetrics.itemSpacing) {
                    ForEach(store.webItems) { item in
                        ZStack {
                            FaviconView(item: item)
                                .opacity(webContent.isActive(item.id) ? 1 : 0.44)
                                .frame(width: RailMetrics.visual(store.railWidthPreference), height: RailMetrics.visualHeight)
                                .background(store.selection == .web(item.id) ? Color.accentColor.opacity(0.2) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 11))
                                .frame(width: RailMetrics.hit(store.railWidthPreference), height: RailMetrics.itemHeight)
                            WebsiteIconTarget(label: item.name,
                                tooltip: item.name + (webContent.isActive(item.id) ? "" : " — Sleeping; click to wake"),
                                leftClick: { handleWebsiteRail(item, rightClick: false) },
                                rightClick: { handleWebsiteRail(item, rightClick: true) })
                                .frame(width: RailMetrics.hit(store.railWidthPreference), height: RailMetrics.itemHeight)
                        }
                        .frame(width: RailMetrics.hit(store.railWidthPreference), height: RailMetrics.itemHeight)
                        .accessibilityLabel(item.name)
                        .popover(isPresented: Binding(get: { !popoverFromHeader && popoverWebID == item.id },
                                                      set: { if !$0 { popoverWebID = nil } }),
                                 arrowEdge: store.side == .right ? .trailing : .leading) {
                            websitePopover(item)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            RailActionMenu(width: RailMetrics.hit(store.railWidthPreference),
                interaction: actionMenuInteraction,
                addTask: { showTaskSheet = true }, addWebsite: { showWebsiteSheet = true })
                .frame(width: RailMetrics.hit(store.railWidthPreference), height: RailMetrics.itemHeight)
                .padding(.bottom, RailMetrics.bottomActionPadding)
                .disabled(store.isReadOnly)
        }
        .padding(.vertical, RailMetrics.verticalPadding)
        .frame(width: RailMetrics.width(store.railWidthPreference))
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: store.railWidthPreference)
        .overlay(alignment: store.side == .right ? .trailing : .leading) {
            Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 0.5)
        }
    }

    private func railButton(_ symbol: String, label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: RailMetrics.visual(store.railWidthPreference), height: RailMetrics.visualHeight)
                .background(selected ? Color.accentColor.opacity(0.2) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 11))
                .frame(width: RailMetrics.hit(store.railWidthPreference), height: RailMetrics.itemHeight)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func showCurrentWebsiteControls(for item: WebItem, fromHeader: Bool = false) {
        popoverLevel = .controls
        popoverFromHeader = fromHeader
        popoverWebID = item.id
    }

    private func handleWebsiteRail(_ item: WebItem, rightClick: Bool) {
        switch WebsiteRailAction.resolve(current: store.selection == .web(item.id),
                                         active: webContent.isActive(item.id), rightClick: rightClick) {
        case .controls: showCurrentWebsiteControls(for: item)
        case .settings:
            popoverLevel = .settings
            popoverFromHeader = false
            popoverWebID = item.id
        case .switchAndWake:
            popoverWebID = nil
            store.selection = .web(item.id)
            webContent.wake(item.id, url: webContent.lastURL(for: item))
        }
    }

    @ViewBuilder private func websitePopover(_ item: WebItem) -> some View {
        if popoverLevel == .controls {
            WebControlsView(item: item, webContent: webContent,
                            showSettings: { popoverLevel = .settings })
        } else {
            WebsiteSettingsView(item: item, store: store, webContent: webContent,
                showBack: store.selection == .web(item.id),
                onBack: { popoverLevel = .controls },
                onClose: { popoverWebID = nil },
                onDelete: {
                    webContent.sleep(item.id)
                    store.deleteWebsite(item.id)
                    popoverWebID = nil
                })
        }
    }
}

private struct TaskEntryView: View {
    let title: String
    let toToday: Bool
    @ObservedObject var store: WorkspaceStore
    @State private var text = ""

    var body: some View {
        HStack(spacing: TaskLayout.checkboxSpacing) {
            Image(systemName: "plus")
                .foregroundStyle(.secondary)
                .frame(width: TaskLayout.iconColumnWidth, height: 36)
                    .contentShape(Rectangle())
            TextField(title, text: $text)
                .textFieldStyle(.plain)
                .onSubmit { store.addTask(text, toToday: toToday); text = "" }
                .accessibilityLabel(title)
        }
        .padding(.vertical, TaskLayout.addPadding)
    }
}

struct AddTaskView: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var toToday = true
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Task").font(.title2.weight(.semibold))
            TextField("Task title", text: $title)
                .focused($titleFocused)
                .onSubmit(add)
            Picker("Place in", selection: $toToday) {
                Text("Today").tag(true)
                Text("Inbox").tag(false)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add", action: add)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 330)
        .onAppear { titleFocused = true }
    }

    private func add() {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.addTask(title, toToday: toToday)
        dismiss()
    }
}

struct TaskRow: View {
    let task: TaskItem
    @ObservedObject var store: WorkspaceStore
    var addSubtask: (() -> Void)? = nil
    var editDetails: (() -> Void)? = nil
    var openHistory: (() -> Void)? = nil
    @State private var editing = false
    @State private var title = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(spacing: TaskLayout.checkboxSpacing) {
            Button { store.toggleCompleted(task.id) } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(task.isCompleted ? Color.secondary : Color.accentColor)
                    .frame(width: TaskLayout.iconColumnWidth, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isCompleted ? "Mark incomplete" : "Complete \(task.title)")
            if editing {
                TextField("Task title", text: $title)
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .onSubmit { finishEditing() }
                    .onExitCommand { editing = false; titleFocused = false }
                    .onChange(of: titleFocused) { _, focused in if !focused { finishEditing() } }
                    .onAppear { titleFocused = true }
            } else {
                if task.isCompleted {
                    titleView
                } else {
                    titleView.overlay {
                        TaskDragSurface(id: task.id, title: task.title,
                            clicked: activateTitle,
                            dragBegan: { store.draggedTaskID = task.id },
                            dragEnded: {
                                store.draggedTaskID = nil
                                store.hoveredTaskID = nil
                                store.hoveredTaskSection = nil
                            })
                    }
                }
            }
            Menu {
                Button("Edit") { beginEditing() }
                if let openHistory { Button("View Progress…", action: openHistory) }
                if let addSubtask { Button("Add Subtask", action: addSubtask) }
                if let editDetails { Button("Task Details…", action: editDetails) }
                Button(task.isToday ? "Remove from Today" : "Move to Today") { store.setToday(task.id, !task.isToday) }
                Button("Move Up") { store.moveTask(task.id, by: -1) }
                Button("Move Down") { store.moveTask(task.id, by: 1) }
                Divider()
                Button("Delete", role: .destructive) { store.deleteTask(task.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Task actions")
            .accessibilityLabel("Actions for \(task.title)")
        }
        .padding(.vertical, TaskLayout.rowPadding)
        .contextMenu {
            Button("Edit") { beginEditing() }
            if let openHistory { Button("View Progress…", action: openHistory) }
            if let addSubtask { Button("Add Subtask", action: addSubtask) }
            if let editDetails { Button("Task Details…", action: editDetails) }
            Button(task.isToday ? "Remove from Today" : "Move to Today") { store.setToday(task.id, !task.isToday) }
            Button("Move Up") { store.moveTask(task.id, by: -1) }
            Button("Move Down") { store.moveTask(task.id, by: 1) }
            Button("Delete", role: .destructive) { store.deleteTask(task.id) }
        }
    }

    private func beginEditing() { title = task.title; editing = true }
    private func activateTitle() {
        if let openHistory { openHistory() }
        else { beginEditing() }
    }
    private var titleView: some View {
        Button(action: activateTitle) {
            Text(task.title)
                .strikethrough(task.isCompleted)
                .foregroundStyle(task.isCompleted ? .secondary : .primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(openHistory == nil ? "Edit \(task.title)" : "Progress for \(task.title)")
        .help(openHistory == nil ? "Edit task" : "View progress history; use Edit in the task menu to rename")
    }
    private func finishEditing() {
        guard editing else { return }
        store.updateTask(task.id, title: title)
        editing = false
    }
}

private struct TaskDropTarget: ViewModifier {
    @ObservedObject var store: WorkspaceStore
    let toToday: Bool
    let targetID: UUID?
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .background(targeted && store.draggedTaskID != nil ? Color.accentColor.opacity(0.09) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: insertionAfterTarget ? .bottom : .top) {
                if targeted, store.draggedTaskID != nil, store.draggedTaskID != targetID {
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor)
                        .frame(height: 3).padding(.horizontal, 8)
                }
            }
            .onDrop(of: [UTType.plainText], isTargeted: $targeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                    guard let text = value as? String, let id = UUID(uuidString: text) else { return }
                    DispatchQueue.main.async {
                        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.18)) {
                            store.placeTask(id, inToday: toToday, relativeTo: targetID)
                            store.draggedTaskID = nil
                            store.hoveredTaskSection = nil
                            store.hoveredTaskID = nil
                        }
                    }
                }
                return true
            }
            .onChange(of: targeted) { _, active in
                if active {
                    store.hoveredTaskSection = toToday
                    store.hoveredTaskID = targetID
                } else if store.hoveredTaskID == targetID {
                    store.hoveredTaskID = nil
                }
            }
    }

    private var insertionAfterTarget: Bool {
        let section = toToday ? store.todayTasks : store.inboxTasks
        guard let dragged = store.draggedTaskID,
              let from = section.firstIndex(where: { $0.id == dragged }),
              let to = section.firstIndex(where: { $0.id == targetID }) else { return false }
        return from < to
    }
}

private struct TaskSection: View {
    let title: String
    let tasks: [TaskItem]
    @ObservedObject var store: WorkspaceStore
    var showHeader = true
    var dropToToday: Bool? = nil
    var openTaskHistory: ((UUID) -> Void)? = nil
    @State private var targeted = false
    private var highlighted: Bool {
        store.draggedTaskID != nil && (targeted || (dropToToday != nil && store.hoveredTaskSection == dropToToday))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TaskLayout.rowSpacing) {
            if showHeader {
                HStack {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    if title == "Completed", !tasks.isEmpty {
                        Button { store.clearCompleted() } label: {
                            Text("Clear")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Text("\(tasks.count)").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.bottom, 3)
            }
            ForEach(tasks) { task in
                TaskRow(task: task, store: store,
                        openHistory: openTaskHistory.map { action in { action(task.id) } })
                    .modifier(TaskDragAndDrop(store: store, task: task, toToday: dropToToday))
                Divider().opacity(0.4)
            }
            if tasks.isEmpty && !showHeader && dropToToday == true {
                Text("No tasks to do today")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            if let dropToToday {
                TaskEntryView(title: dropToToday ? "Add to Today" : "Add to Inbox",
                              toToday: dropToToday, store: store)
                    .overlay(alignment: .top) {
                        if highlighted, !tasks.isEmpty, store.hoveredTaskID == nil {
                            RoundedRectangle(cornerRadius: 2).fill(Color.accentColor)
                                .frame(height: 3).padding(.horizontal, 8)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, showHeader ? 8 : 0)
        .padding(.vertical, showHeader ? 8 : 3)
        .background(highlighted ? Color.accentColor.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onDrop(of: [UTType.plainText], isTargeted: $targeted) { providers in
            guard let dropToToday, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                guard let text = value as? String, let id = UUID(uuidString: text) else { return }
                DispatchQueue.main.async {
                    withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        store.placeTask(id, inToday: dropToToday)
                        store.draggedTaskID = nil
                        store.hoveredTaskSection = nil
                        store.hoveredTaskID = nil
                    }
                }
            }
            return true
        }
        .onChange(of: targeted) { _, active in
            if active { store.hoveredTaskSection = dropToToday }
            else if store.hoveredTaskSection == dropToToday { store.hoveredTaskSection = nil }
        }
    }
}

private struct TaskDragAndDrop: ViewModifier {
    @ObservedObject var store: WorkspaceStore
    let task: TaskItem
    let toToday: Bool?

    @ViewBuilder func body(content: Content) -> some View {
        if let toToday, !task.isCompleted {
            content
                .modifier(TaskDropTarget(store: store, toToday: toToday, targetID: task.id))
        } else { content }
    }
}

private struct NativePage<Content: View>: View {
    var horizontalInset: CGFloat = 26
    var verticalInset: CGFloat = 27
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, horizontalInset)
                .padding(.vertical, verticalInset)
        }
        .background(.ultraThinMaterial)
    }
}

struct TodayView: View {
    @ObservedObject var store: WorkspaceStore
    let preferredHeight: (CGFloat) -> Void
    var openTaskHistory: ((UUID) -> Void)? = nil
    @State private var taskHeight: CGFloat = 0
    @State private var navigationHeight: CGFloat = 0

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: TaskLayout.sectionSpacing) {
                    TaskSection(title: "Today", tasks: store.todayPageTasks, store: store,
                                showHeader: false, dropToToday: true, openTaskHistory: openTaskHistory)
                        .background {
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear { taskHeight = proxy.size.height }
                                    .onChange(of: proxy.size.height) { _, height in taskHeight = height }
                            }
                        }
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: TaskLayout.sectionSpacing) {
                        Divider()
                        Button { store.selection = .tasks } label: {
                            HStack {
                                Text("All Tasks")
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                    }
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { navigationHeight = proxy.size.height }
                                .onChange(of: proxy.size.height) { _, height in navigationHeight = height }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: max(0, viewport.size.height - 18), alignment: .topLeading)
                .padding(.horizontal, TaskLayout.todayInset)
                .padding(.vertical, 9)
            }
        }
        .background(.ultraThinMaterial)
        .onChange(of: taskHeight) { _, _ in reportPreferredHeight() }
        .onChange(of: navigationHeight) { _, _ in reportPreferredHeight() }
    }

    private func reportPreferredHeight() {
        guard taskHeight > 0, navigationHeight > 0 else { return }
        preferredHeight(taskHeight + navigationHeight + 2 * TaskLayout.sectionSpacing + 18)
    }
}

struct TasksView: View {
    @ObservedObject var store: WorkspaceStore
    var openTaskHistory: ((UUID) -> Void)? = nil
    var body: some View {
        NativePage(horizontalInset: TaskLayout.tasksInset, verticalInset: 13) {
            VStack(alignment: .leading, spacing: TaskLayout.sectionSpacing) {
                TaskSection(title: "Today", tasks: store.todayTasks, store: store, dropToToday: true,
                            openTaskHistory: openTaskHistory)
                Divider()
                TaskSection(title: "Inbox", tasks: store.inboxTasks, store: store, dropToToday: false,
                            openTaskHistory: openTaskHistory)
                Divider()
                TaskSection(title: "Completed", tasks: store.completedTasks, store: store,
                            openTaskHistory: openTaskHistory)
            }
        }
    }
}

struct WebWorkspaceView: View {
    let item: WebItem
    @ObservedObject var webContent: WebContent

    var body: some View {
        VStack(spacing: 0) {
            if let webView = webContent.webView, webContent.activeID == item.id {
                WebContainer(webView: webView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "moon.zzz").font(.system(size: 24)).foregroundStyle(.secondary)
                    Text("Website sleeping").foregroundStyle(.secondary)
                    Button("Wake Website") { webContent.wake(item.id, url: webContent.lastURL(for: item)) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct WebControlsView: View {
    let item: WebItem
    @ObservedObject var webContent: WebContent
    let showSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                FaviconView(item: item)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.headline)
                    Text(item.url.host ?? item.url.absoluteString).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                control("chevron.left", "Back", enabled: webContent.canGoBack) { webContent.goBack() }
                control("chevron.right", "Forward", enabled: webContent.canGoForward) { webContent.goForward() }
                control("house", "Home", enabled: webContent.webView != nil) { webContent.load(item.url) }
                control("arrow.clockwise", "Reload", enabled: webContent.webView != nil) { webContent.reload() }
                control("arrow.up.right", "Open in Default Browser") {
                    NSWorkspace.shared.open(webContent.lastURL(for: item))
                }
            }
            Toggle("Active", isOn: Binding(get: { webContent.isActive(item.id) }, set: { active in
                if active { webContent.wake(item.id, url: webContent.lastURL(for: item)) }
                else { webContent.sleep(item.id) }
            }))
            .toggleStyle(.switch)
            .controlSize(.small)
            Divider()
            Button(action: showSettings) {
                HStack { Text("Website Settings"); Spacer(); Image(systemName: "chevron.right") }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 290, alignment: .leading)
    }

    private func control(_ symbol: String, _ label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 28, height: 28) }
            .buttonStyle(.plain).disabled(!enabled).help(label).accessibilityLabel(label)
    }
}

struct WebsiteSettingsView: View {
    let item: WebItem
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var webContent: WebContent
    let showBack: Bool
    let onBack: () -> Void
    let onClose: () -> Void
    let onDelete: () -> Void
    @State private var name = ""
    @State private var url = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showBack {
                Button(action: onBack) { Label("Website Settings", systemImage: "chevron.left") }
                    .buttonStyle(.plain).font(.headline)
            } else { Text("Website Settings").font(.headline) }
            Text("Name").font(.caption).foregroundStyle(.secondary)
            TextField("Name", text: $name).disabled(item.id == WebItem.chatGPTID)
            Text("URL").font(.caption).foregroundStyle(.secondary)
            TextField("URL", text: $url)
                .textContentType(.URL)
                .disabled(item.id == WebItem.chatGPTID)
            Toggle("Auto Sleep When Inactive", isOn: Binding(
                get: { store.webItem(id: item.id)?.autoSleepWhenInactive ?? false },
                set: { store.setAutoSleep(item.id, enabled: $0) }))
            .toggleStyle(.switch)
            .controlSize(.small)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if item.id != WebItem.chatGPTID {
                HStack {
                    Button("Remove Website", role: .destructive, action: onDelete)
                    Spacer()
                    Button("Save") {
                        if let message = store.updateWebsite(item.id, name: name, urlText: url) { error = message }
                        else {
                            if let updated = store.webItem(id: item.id) {
                                webContent.rememberURL(updated.url, for: item.id)
                                if store.selection == .web(item.id) { webContent.load(updated.url) }
                            }
                            onClose()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: 290)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { name = item.name; url = item.url.absoluteString }
    }
}

struct AddWebsiteView: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var error: String?

    private var preview: WebItem? {
        let candidate = url.contains("://") ? url : "https://\(url)"
        guard let value = URL(string: candidate), value.host != nil else { return nil }
        return WebItem(name: name.isEmpty ? (value.host ?? "Website") : name, url: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Website").font(.title2.weight(.semibold))
            TextField("Name", text: $name)
            TextField("URL", text: $url)
                .textContentType(.URL)
            HStack(spacing: 10) {
                if let preview { FaviconView(item: preview) }
                Text(preview?.url.host ?? "Icon preview")
                    .foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    if let message = store.addWebsite(name: name, urlText: url) { error = message }
                    else { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 350)
    }
}
