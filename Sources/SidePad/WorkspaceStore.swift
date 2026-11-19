import AppKit
import Combine

enum DockEdge: String, Codable, CaseIterable { case left, right }
enum WindowPlacement: Codable, Equatable {
    case docked(edge: DockEdge)
    case floating
}
struct FloatingWindowState: Codable, Equatable {
    var frame: CGRect
    var screenIdentifier: String?
}
enum DefaultPage: String, Codable, CaseIterable { case today, lastOpened }
enum RailWidthPreference: String, Codable, CaseIterable { case minimal, compact, standard }
enum AutoHidePolicy: Equatable {
    case delayed(TimeInterval)
    case untilExternalClick
}

enum WorkspacePresentation {
    case today, tasks, threads, web

    var sizingPolicy: WorkspaceSizingPolicy {
        self == .today ? .contentFitted : .persistentUserSize
    }
}

enum WorkspaceSizingPolicy { case contentFitted, persistentUserSize }

enum WorkspaceSelection: Codable, Hashable {
    case today
    case tasks
    case threads
    case web(UUID)
}

extension WorkspaceSelection {
    var presentation: WorkspacePresentation {
        switch self {
        case .today: .today
        case .tasks: .tasks
        case .threads: .threads
        case .web: .web
        }
    }
}

struct TaskItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var isCompleted = false
    var createdAt = Date()
    var todayDate: Date?
    var sortOrder: Int
    var threadID: UUID?
    var parentTaskID: UUID?
    var dueDate: Date?
    var priority: Int?
    // Standalone notes and completion transitions remain in the existing task snapshot.
    // Linked project progress lives in Thread Markdown and is joined by this task's UUID.
    var progressEvents: [ProgressEvent]?

    var isToday: Bool { todayDate.map(Calendar.current.isDateInToday) ?? false }
}

struct WebItem: Identifiable, Codable, Equatable {
    static let chatGPTID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let chatGPT = WebItem(id: chatGPTID, name: "ChatGPT", url: URL(string: "https://chatgpt.com/")!)
    var id = UUID()
    var name: String
    var url: URL
    var autoSleepWhenInactive = false

    private enum CodingKeys: String, CodingKey { case id, name, url, autoSleepWhenInactive }
    init(id: UUID = UUID(), name: String, url: URL, autoSleepWhenInactive: Bool = false) {
        self.id = id; self.name = name; self.url = url; self.autoSleepWhenInactive = autoSleepWhenInactive
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        url = try values.decode(URL.self, forKey: .url)
        autoSleepWhenInactive = try values.decodeIfPresent(Bool.self, forKey: .autoSleepWhenInactive) ?? false
    }
}

private struct WorkspaceSnapshot: Codable {
    var side: DockEdge = .right
    var placement: WindowPlacement = .docked(edge: .right)
    var floatingWindow: FloatingWindowState?
    var webHeightRatio: Double?
    var todayHeightRatio: Double?
    var tasksHeightRatio: Double?
    var tasksSize: CGSize?
    var threadsSize: CGSize?
    var threadsHeightRatio: Double?
    var lastThreads = false
    var todayWidth: CGFloat?
    var webSize: CGSize?
    var autoHide = true
    var defaultPage: DefaultPage = .today
    var lastSelection: WorkspaceSelection = .today
    var hoverDelay = 0.35
    var hideUntilExternalClick = false
    var tasks: [TaskItem] = []
    var websites: [WebItem] = []
    var railWidthPreference: RailWidthPreference = .standard
    var showCompletedToday = true
    var chatGPTAutoSleep = false

    private enum CodingKeys: String, CodingKey {
        case side, placement, floatingWindow, webHeightRatio, todayHeightRatio, tasksHeightRatio, tasksSize, threadsSize, threadsHeightRatio, lastThreads, todayWidth, webSize,
             autoHide, defaultPage, lastSelection, hoverDelay, hideUntilExternalClick, tasks, websites, railWidthPreference,
             showCompletedToday, chatGPTAutoSleep
    }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        side = try values.decodeIfPresent(DockEdge.self, forKey: .side) ?? .right
        placement = try values.decodeIfPresent(WindowPlacement.self, forKey: .placement) ?? .docked(edge: side)
        floatingWindow = try values.decodeIfPresent(FloatingWindowState.self, forKey: .floatingWindow)
        webHeightRatio = try values.decodeIfPresent(Double.self, forKey: .webHeightRatio)
        todayHeightRatio = try values.decodeIfPresent(Double.self, forKey: .todayHeightRatio)
        tasksHeightRatio = try values.decodeIfPresent(Double.self, forKey: .tasksHeightRatio)
        tasksSize = try values.decodeIfPresent(CGSize.self, forKey: .tasksSize)
        threadsSize = try values.decodeIfPresent(CGSize.self, forKey: .threadsSize)
        threadsHeightRatio = try values.decodeIfPresent(Double.self, forKey: .threadsHeightRatio)
        lastThreads = try values.decodeIfPresent(Bool.self, forKey: .lastThreads) ?? false
        todayWidth = try values.decodeIfPresent(CGFloat.self, forKey: .todayWidth)
        webSize = try values.decodeIfPresent(CGSize.self, forKey: .webSize)
        autoHide = try values.decodeIfPresent(Bool.self, forKey: .autoHide) ?? true
        defaultPage = try values.decodeIfPresent(DefaultPage.self, forKey: .defaultPage) ?? .today
        lastSelection = try values.decodeIfPresent(WorkspaceSelection.self, forKey: .lastSelection) ?? .today
        hoverDelay = try values.decodeIfPresent(Double.self, forKey: .hoverDelay) ?? 0.35
        hideUntilExternalClick = try values.decodeIfPresent(Bool.self, forKey: .hideUntilExternalClick) ?? false
        tasks = try values.decodeIfPresent([TaskItem].self, forKey: .tasks) ?? []
        websites = try values.decodeIfPresent([WebItem].self, forKey: .websites) ?? []
        railWidthPreference = try values.decodeIfPresent(RailWidthPreference.self, forKey: .railWidthPreference) ?? .standard
        showCompletedToday = try values.decodeIfPresent(Bool.self, forKey: .showCompletedToday) ?? true
        chatGPTAutoSleep = try values.decodeIfPresent(Bool.self, forKey: .chatGPTAutoSleep) ?? false
    }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    private static let key = "SidePad.workspace.v4"
    @Published private(set) var persistenceError: String?
    @Published var taskError: String?
    var isReadOnly: Bool { persistenceError != nil }
    @Published var side: DockEdge { didSet { save() } }
    @Published var placement: WindowPlacement { didSet { save() } }
    @Published var floatingWindow: FloatingWindowState? { didSet { save() } }
    @Published var webHeightRatio: Double? { didSet { save() } }
    @Published var todayHeightRatio: Double? { didSet { save() } }
    @Published var tasksHeightRatio: Double? { didSet { save() } }
    @Published var tasksSize: CGSize? { didSet { save() } }
    @Published var threadsSize: CGSize? { didSet { save() } }
    @Published var threadsHeightRatio: Double? { didSet { save() } }
    @Published var todayWidth: CGFloat? { didSet { save() } }
    @Published var webSize: CGSize? { didSet { save() } }
    @Published var autoHide: Bool { didSet { save() } }
    @Published var defaultPage: DefaultPage { didSet { save() } }
    @Published var hoverDelay: Double { didSet { save() } }
    @Published var hideUntilExternalClick: Bool { didSet { save() } }
    @Published var selection: WorkspaceSelection { didSet { save() } }
    @Published var railWidthPreference: RailWidthPreference { didSet { save() } }
    @Published var showCompletedToday: Bool { didSet { save() } }
    @Published var chatGPTAutoSleep: Bool { didSet { save() } }
    @Published private(set) var tasks: [TaskItem] { didSet { save() } }
    @Published private(set) var websites: [WebItem] { didSet { save() } }
    @Published var draggedTaskID: UUID? = nil
    @Published var hoveredTaskSection: Bool? = nil
    @Published var hoveredTaskID: UUID? = nil
    @Published private(set) var currentDay = Calendar.current.startOfDay(for: Date())
    private var midnightTimer: Timer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        persistedData = defaults.data(forKey: Self.key)
        let snapshot: WorkspaceSnapshot
        if let data = persistedData {
            do {
                let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
                try Self.validateTasks(decoded.tasks)
                snapshot = decoded
            } catch {
                snapshot = WorkspaceSnapshot()
                persistenceError = "Task storage could not be read. The original SidePad.workspace.v4 data is preserved. Quit SidePad and restore a valid preferences backup before reopening."
            }
        } else { snapshot = WorkspaceSnapshot() }
        if case let .docked(edge) = snapshot.placement { side = edge }
        else { side = snapshot.side }
        placement = snapshot.placement
        floatingWindow = snapshot.floatingWindow
        webHeightRatio = snapshot.webHeightRatio.map {
            min(Double(WindowGeometry.maximumWebHeightRatio),
                max(Double(WindowGeometry.minimumWebHeightRatio), $0))
        }
        todayHeightRatio = snapshot.todayHeightRatio
        tasksHeightRatio = snapshot.tasksHeightRatio
        tasksSize = snapshot.tasksSize
        threadsSize = snapshot.threadsSize
        threadsHeightRatio = snapshot.threadsHeightRatio
        todayWidth = snapshot.todayWidth
        webSize = snapshot.webSize
        autoHide = snapshot.autoHide
        defaultPage = snapshot.defaultPage
        hoverDelay = min(1.5, max(0, snapshot.hoverDelay))
        hideUntilExternalClick = snapshot.hideUntilExternalClick
        tasks = snapshot.tasks
        websites = snapshot.websites.filter { $0.id != WebItem.chatGPTID }
        railWidthPreference = snapshot.railWidthPreference
        showCompletedToday = snapshot.showCompletedToday
        chatGPTAutoSleep = snapshot.chatGPTAutoSleep
        let restored: WorkspaceSelection = snapshot.lastThreads ? .threads : snapshot.lastSelection
        if snapshot.defaultPage == .lastOpened,
           case let .web(id) = restored,
           id != WebItem.chatGPTID && !snapshot.websites.contains(where: { $0.id == id }) {
            selection = .today
        } else {
            selection = snapshot.defaultPage == .today ? .today : restored
        }
        scheduleDayChange()
    }

    deinit { midnightTimer?.invalidate() }

    private let defaults: UserDefaults
    private var persistedData: Data?

    /// A second app instance or external preferences edit must not be overwritten by stale tasks.
    func verifyPersistence() throws {
        guard !isReadOnly else { throw TaskLinkError.invalid(persistenceError ?? "Task storage is read-only.") }
        guard defaults.data(forKey: Self.key) == persistedData else {
            throw TaskLinkError.invalid("Task storage changed in another instance. Reopen SidePad to load the latest saved tasks.")
        }
    }

    private func scheduleDayChange() {
        guard let midnight = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 0),
                                                       matchingPolicy: .nextTime) else { return }
        let timer = Timer(timeInterval: max(1, midnight.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.currentDay = Calendar.current.startOfDay(for: Date())
                self?.scheduleDayChange()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        midnightTimer = timer
    }

    private func save() {
        guard !isReadOnly else { return }
        do { try verifyPersistence() }
        catch { persistenceError = error.localizedDescription; return }
        let clampedWebHeight = webHeightRatio.map {
            min(Double(WindowGeometry.maximumWebHeightRatio),
                max(Double(WindowGeometry.minimumWebHeightRatio), $0))
        }
        var snapshot = WorkspaceSnapshot()
        snapshot.side = side
        snapshot.placement = placement
        snapshot.floatingWindow = floatingWindow
        snapshot.webHeightRatio = clampedWebHeight
        snapshot.todayHeightRatio = todayHeightRatio
        snapshot.tasksHeightRatio = tasksHeightRatio
        snapshot.tasksSize = tasksSize
        snapshot.threadsSize = threadsSize
        snapshot.threadsHeightRatio = threadsHeightRatio
        snapshot.todayWidth = todayWidth
        snapshot.webSize = webSize
        snapshot.autoHide = autoHide
        snapshot.defaultPage = defaultPage
        // Older SidePad builds must still decode their task snapshot after using Threads.
        snapshot.lastSelection = selection == .threads ? .tasks : selection
        snapshot.lastThreads = selection == .threads
        snapshot.hoverDelay = hoverDelay
        snapshot.hideUntilExternalClick = hideUntilExternalClick
        snapshot.tasks = tasks
        snapshot.websites = websites
        snapshot.railWidthPreference = railWidthPreference
        snapshot.showCompletedToday = showCompletedToday
        snapshot.chatGPTAutoSleep = chatGPTAutoSleep
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.key)
            persistedData = data
        }
    }

    var webItems: [WebItem] {
        var chatGPT = WebItem.chatGPT
        chatGPT.autoSleepWhenInactive = chatGPTAutoSleep
        return [chatGPT] + websites
    }
    func webItem(id: UUID) -> WebItem? { webItems.first { $0.id == id } }
    var activeWebsiteTitle: String {
        guard case let .web(id) = selection, let item = webItem(id: id) else { return "Web" }
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        if let host = item.url.host, !host.isEmpty { return host }
        return "Web"
    }
    var autoHidePolicy: AutoHidePolicy {
        hideUntilExternalClick ? .untilExternalClick : .delayed(hoverDelay)
    }
    func heightRatio(for presentation: WorkspacePresentation) -> Double? {
        switch presentation {
        case .today: todayHeightRatio
        case .tasks: tasksHeightRatio
        case .threads: threadsHeightRatio
        case .web: webHeightRatio
        }
    }
    func size(for presentation: WorkspacePresentation) -> CGSize? {
        switch presentation {
        case .today: todayWidth.map { CGSize(width: $0, height: 0) }
        case .tasks: tasksSize
        case .threads: threadsSize
        case .web: webSize
        }
    }
    func setSize(_ size: CGSize, for presentation: WorkspacePresentation) {
        guard size.width.isFinite, size.width > 0 else { return }
        if presentation == .today { todayWidth = size.width; return }
        guard size.height.isFinite, size.height > 0 else { return }
        switch presentation {
        case .today: break
        case .tasks: tasksSize = size
        case .threads: threadsSize = size
        case .web: webSize = size
        }
    }
    func setHeightRatio(_ ratio: Double, for presentation: WorkspacePresentation) {
        let clamped = min(1, max(0.25, ratio))
        switch presentation {
        case .today: todayHeightRatio = clamped
        case .tasks: tasksHeightRatio = clamped
        case .threads: threadsHeightRatio = clamped
        case .web: webHeightRatio = min(Double(WindowGeometry.maximumWebHeightRatio),
                                     max(Double(WindowGeometry.minimumWebHeightRatio), clamped))
        }
    }
    func setAutoSleep(_ id: UUID, enabled: Bool) {
        if id == WebItem.chatGPTID { chatGPTAutoSleep = enabled; return }
        guard let index = websites.firstIndex(where: { $0.id == id }) else { return }
        websites[index].autoSleepWhenInactive = enabled
    }

    var todayTasks: [TaskItem] { tasks.filter { !$0.isCompleted && $0.isToday }.sorted { $0.sortOrder < $1.sortOrder } }
    var todayPageTasks: [TaskItem] {
        tasks.filter { $0.isToday && (showCompletedToday || !$0.isCompleted) }.sorted {
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            return $0.sortOrder < $1.sortOrder
        }
    }
    var inboxTasks: [TaskItem] { tasks.filter { !$0.isCompleted && !$0.isToday }.sorted { $0.sortOrder < $1.sortOrder } }
    var completedTasks: [TaskItem] { tasks.filter(\.isCompleted).sorted { $0.sortOrder < $1.sortOrder } }

    func addTask(_ title: String, toToday: Bool) {
        guard !isReadOnly else { return }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        tasks.append(TaskItem(title: value, todayDate: toToday ? Date() : nil, sortOrder: nextOrder()))
    }

    func updateTask(_ id: UUID, title: String) {
        guard !isReadOnly else { return }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].title = value
    }

    func toggleCompleted(_ id: UUID) {
        guard !isReadOnly, let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        var updated = tasks
        updated[index].isCompleted.toggle()
        let item = updated[index]
        let event = ProgressEvent(summary: item.isCompleted ? "Task completed" : "Task reopened", source: .taskChange,
            taskID: item.id, taskTitle: item.title, taskCompleted: item.isCompleted)
        updated[index].progressEvents = (item.progressEvents ?? []) + [event]
        do { try replaceTasks(updated); taskError = nil }
        catch { taskError = "Task change was not saved: \(error.localizedDescription)" }
    }

    func setToday(_ id: UUID, _ enabled: Bool) {
        guard !isReadOnly else { return }
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        if !tasks[index].isCompleted { placeTask(id, inToday: enabled); return }
        tasks[index].todayDate = enabled ? Date() : nil
        tasks[index].sortOrder = nextOrder()
    }

    func deleteTask(_ id: UUID) { removeTasks(where: { $0.id == id }) }

    func clearCompleted() { removeTasks(where: { $0.isCompleted }) }

    private func removeTasks(where predicate: (TaskItem) -> Bool) {
        guard !isReadOnly else { return }
        let original = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var remaining = tasks.filter { !predicate($0) }
        let keptIDs = Set(remaining.map(\.id))
        for index in remaining.indices {
            var parent = remaining[index].parentTaskID
            var visited = Set<UUID>()
            while let id = parent, !keptIDs.contains(id), visited.insert(id).inserted {
                parent = original[id]?.parentTaskID
            }
            remaining[index].parentTaskID = parent.flatMap { keptIDs.contains($0) ? $0 : nil }
        }
        tasks = remaining
    }

    /// Threads uses the existing canonical task snapshot, including its ordering/completion fields.
    func replaceTasks(_ records: [TaskItem]) throws {
        try verifyPersistence()
        try Self.validateTasks(records)
        _ = try JSONEncoder().encode(records)
        tasks = records
    }

    static func validateTasks(_ records: [TaskItem]) throws {
        guard Set(records.map(\.id)).count == records.count else { throw TaskLinkError.invalid("Duplicate task ID.") }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var checked = Set<UUID>()
        var eventIDs = Set<UUID>()
        for record in records {
            guard !record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  record.priority.map({ (0...3).contains($0) }) ?? true,
                  record.dueDate.map({ $0.timeIntervalSince1970.isFinite }) ?? true else {
                throw TaskLinkError.invalid("Invalid task title, priority, or date.")
            }
            let events = record.progressEvents ?? []
            try ProgressEvent.validate(events)
            guard events.allSatisfy({ $0.taskID == record.id && eventIDs.insert($0.id).inserted }) else {
                throw TaskLinkError.invalid("Task progress must reference its owner and use unique event IDs.")
            }
            var path = Set<UUID>()
            var current: UUID? = record.id
            while let id = current, !checked.contains(id) {
                guard path.insert(id).inserted, let item = byID[id] else {
                    throw TaskLinkError.invalid("A subtask needs an existing parent in the same Thread; cycles are not allowed.")
                }
                if let parentID = item.parentTaskID {
                    guard let parent = byID[parentID], parent.threadID == item.threadID else {
                        throw TaskLinkError.invalid("A subtask needs an existing parent in the same Thread.")
                    }
                }
                current = item.parentTaskID
            }
            checked.formUnion(path)
        }
    }

    func linkTask(_ id: UUID, to threadID: UUID?, parentTaskID: UUID? = nil) throws {
        try replaceTasks(tasksLinking(id, to: threadID, parentTaskID: parentTaskID))
    }

    private func tasksLinking(_ id: UUID, to threadID: UUID?, parentTaskID: UUID?) throws -> [TaskItem] {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw TaskLinkError.invalid("Task no longer exists.") }
        var updated = tasks
        updated[index].threadID = threadID
        updated[index].parentTaskID = parentTaskID
        let children = Dictionary(grouping: tasks, by: \.parentTaskID)
        var descendants: Set<UUID> = [id]
        var pending = [id]
        while let current = pending.popLast() {
            for child in children[current] ?? [] {
                if descendants.insert(child.id).inserted { pending.append(child.id) }
            }
        }
        for index in updated.indices where descendants.contains(updated[index].id) { updated[index].threadID = threadID }
        return updated
    }

    func editTask(_ id: UUID, threadID: UUID?, parentTaskID: UUID?, dueDate: Date?, priority: Int?) throws {
        var updated = try tasksLinking(id, to: threadID, parentTaskID: parentTaskID)
        guard let index = updated.firstIndex(where: { $0.id == id }) else { throw TaskLinkError.invalid("Task no longer exists.") }
        updated[index].dueDate = dueDate
        updated[index].priority = priority == 0 ? nil : priority
        try replaceTasks(updated)
    }

    func updateTaskDetails(_ id: UUID, dueDate: Date?, priority: Int?) throws {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw TaskLinkError.invalid("Task no longer exists.") }
        var updated = tasks
        updated[index].dueDate = dueDate
        updated[index].priority = priority == 0 ? nil : priority
        try replaceTasks(updated)
    }

    /// The same ordering path serves drag placement and the existing move menu.
    func placeTask(_ id: UUID, inToday: Bool, relativeTo targetID: UUID? = nil) {
        guard !isReadOnly, targetID != id,
              let source = tasks.first(where: { $0.id == id }), !source.isCompleted else { return }
        let current = inToday ? todayTasks : inboxTasks
        guard targetID == nil || current.contains(where: { $0.id == targetID }) else { return }
        let sourceIndex = current.firstIndex(where: { $0.id == id })
        var ordered = current.map(\.id).filter { $0 != id }
        if let targetID, let targetIndex = ordered.firstIndex(of: targetID) {
            let after = sourceIndex.map { $0 < (current.firstIndex(where: { $0.id == targetID }) ?? 0) } ?? false
            ordered.insert(id, at: targetIndex + (after ? 1 : 0))
        } else {
            ordered.append(id)
        }
        let start = nextOrder()
        var updated = tasks
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        updated[index].todayDate = inToday ? Date() : nil
        // Use fresh global orders so every section remains stable after a move or restart.
        for (offset, taskID) in ordered.enumerated() {
            if let taskIndex = updated.firstIndex(where: { $0.id == taskID }) {
                updated[taskIndex].sortOrder = start + offset
            }
        }
        draggedTaskID = nil
        hoveredTaskSection = nil
        hoveredTaskID = nil
        tasks = updated
    }

    func moveTask(_ id: UUID, by offset: Int) {
        guard !isReadOnly, let item = tasks.first(where: { $0.id == id }) else { return }
        let section = item.isCompleted ? completedTasks : (item.isToday ? todayTasks : inboxTasks)
        guard let source = section.firstIndex(where: { $0.id == id }),
              section.indices.contains(source + offset) else { return }
        if !item.isCompleted {
            placeTask(id, inToday: item.isToday, relativeTo: section[source + offset].id)
        } else {
            let otherID = section[source + offset].id
            guard let first = tasks.firstIndex(where: { $0.id == id }),
                  let second = tasks.firstIndex(where: { $0.id == otherID }) else { return }
            let order = tasks[first].sortOrder
            tasks[first].sortOrder = tasks[second].sortOrder
            tasks[second].sortOrder = order
        }
    }

    func addWebsite(name: String, urlText: String) -> String? {
        guard let url = Self.websiteURL(urlText) else { return "Enter a valid HTTP or HTTPS website URL." }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        websites.append(WebItem(name: title.isEmpty ? (url.host ?? "Website") : title, url: url))
        selection = .web(websites.last!.id)
        return nil
    }

    func updateWebsite(_ id: UUID, name: String, urlText: String) -> String? {
        guard let index = websites.firstIndex(where: { $0.id == id }) else { return "Website no longer exists." }
        guard let url = Self.websiteURL(urlText) else { return "Enter a valid HTTP or HTTPS website URL." }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        websites[index].name = title.isEmpty ? (url.host ?? "Website") : title
        websites[index].url = url
        return nil
    }

    private static func websiteURL(_ urlText: String) -> URL? {
        let value = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = value.contains("://") ? value : "https://\(value)"
        guard let components = URLComponents(string: candidate),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, host.contains("."),
              let url = components.url else { return nil }
        return url
    }

    func deleteWebsite(_ id: UUID) {
        websites.removeAll { $0.id == id }
        if selection == .web(id) { selection = .today }
    }

    private func nextOrder() -> Int { (tasks.map(\.sortOrder).max() ?? -1) + 1 }
}
