import Foundation

/// Only confirmed actions construct persisted events. AI suggestions remain in the pending plan.
enum ProgressEventSource: String, Codable, CaseIterable {
    case manual
    case aiConfirmed = "ai_confirmed"
    case taskChange = "task_change"
}

struct ProgressSnapshot: Codable, Equatable {
    var currentState: String
    var nextAction: String
    var blockers: String
    var resumePoint: String

    init(currentState: String = "", nextAction: String = "", blockers: String = "", resumePoint: String = "") {
        self.currentState = currentState
        self.nextAction = nextAction
        self.blockers = blockers
        self.resumePoint = resumePoint
    }

    init(thread: ThreadRecord) {
        self.init(currentState: thread.currentState, nextAction: thread.nextAction,
                  blockers: thread.blockers, resumePoint: thread.resumePoint)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case currentState = "current_state", nextAction = "next_action", blockers, resumePoint = "resume_point"
    }

    init(from decoder: Decoder) throws {
        try ProgressJSON.requireKnownKeys(CodingKeys.self, in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        currentState = try values.decode(String.self, forKey: .currentState)
        nextAction = try values.decode(String.self, forKey: .nextAction)
        blockers = try values.decode(String.self, forKey: .blockers)
        resumePoint = try values.decode(String.self, forKey: .resumePoint)
        try validate()
    }

    func validate() throws {
        guard [currentState, nextAction, blockers, resumePoint].allSatisfy({ $0.count <= 10_000 && !$0.contains("\0") }) else {
            throw ProgressMemoryError.invalid("Snapshot fields must be at most 10,000 characters and contain no NUL characters.")
        }
    }
}

/// Task metadata is historical evidence, never a second source for live task state.
struct ProgressEvent: Identifiable, Codable, Equatable {
    var id: UUID
    var timestamp: Date
    var summary: String
    var source: ProgressEventSource
    var taskID: UUID?
    var taskTitle: String?
    var taskCompleted: Bool?
    var snapshot: ProgressSnapshot
    var rawInput: String?

    init(id: UUID = UUID(), timestamp: Date = Date(), summary: String,
         source: ProgressEventSource = .manual, taskID: UUID? = nil,
         taskTitle: String? = nil, taskCompleted: Bool? = nil,
         snapshot: ProgressSnapshot = .init(), rawInput: String? = nil) {
        self.id = id
        self.timestamp = ProgressTimestamp.normalized(timestamp)
        self.summary = summary
        self.source = source
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.taskCompleted = taskCompleted
        self.snapshot = snapshot
        self.rawInput = rawInput
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, timestamp, summary, source, taskID = "task_id", taskTitle = "task_title"
        case taskCompleted = "task_completed", snapshot, rawInput = "raw_input"
    }

    init(from decoder: Decoder) throws {
        try ProgressJSON.requireKnownKeys(CodingKeys.self, in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        let text = try values.decode(String.self, forKey: .timestamp)
        guard let date = ProgressTimestamp.parse(text) else {
            throw ProgressMemoryError.invalid("Event timestamp must be a real ISO 8601 date with a timezone.")
        }
        timestamp = date
        summary = try values.decode(String.self, forKey: .summary)
        source = try values.decode(ProgressEventSource.self, forKey: .source)
        taskID = try values.decodeIfPresent(UUID.self, forKey: .taskID)
        taskTitle = try values.decodeIfPresent(String.self, forKey: .taskTitle)
        taskCompleted = try values.decodeIfPresent(Bool.self, forKey: .taskCompleted)
        snapshot = try values.decode(ProgressSnapshot.self, forKey: .snapshot)
        rawInput = try values.decodeIfPresent(String.self, forKey: .rawInput)
        try Self.validate([self])
    }

    func encode(to encoder: Encoder) throws {
        try Self.validate([self])
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(ProgressTimestamp.format(timestamp), forKey: .timestamp)
        try values.encode(summary, forKey: .summary)
        try values.encode(source, forKey: .source)
        try values.encodeIfPresent(taskID, forKey: .taskID)
        try values.encodeIfPresent(taskTitle, forKey: .taskTitle)
        try values.encodeIfPresent(taskCompleted, forKey: .taskCompleted)
        try values.encode(snapshot, forKey: .snapshot)
        try values.encodeIfPresent(rawInput, forKey: .rawInput)
    }

    static func validate(_ events: [ProgressEvent]) throws {
        guard events.count <= 10_000 else { throw ProgressMemoryError.invalid("A history supports at most 10,000 events.") }
        var ids = Set<UUID>()
        for event in events {
            guard ids.insert(event.id).inserted else { throw ProgressMemoryError.invalid("Duplicate progress event UUID: \(event.id)") }
            guard event.timestamp.timeIntervalSince1970.isFinite,
                  (Date(timeIntervalSince1970: -62_135_596_800)..<Date(timeIntervalSince1970: 253_402_300_800)).contains(event.timestamp) else {
                throw ProgressMemoryError.invalid("Event timestamp must be a real date in years 0001–9999.")
            }
            guard !event.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  event.summary.count <= 10_000, !event.summary.contains("\0") else {
                throw ProgressMemoryError.invalid("Progress summary must contain 1–10,000 characters and no NUL characters.")
            }
            guard event.taskID != nil || (event.taskTitle == nil && event.taskCompleted == nil) else {
                throw ProgressMemoryError.invalid("Historical task metadata needs a task UUID.")
            }
            if let title = event.taskTitle {
                guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      title.count <= 10_000, !title.contains("\0") else {
                    throw ProgressMemoryError.invalid("Historical task titles must contain 1–10,000 characters and no NUL characters.")
                }
            }
            if let rawInput = event.rawInput {
                guard rawInput.utf8.count <= 64 * 1_024, !rawInput.contains("\0") else {
                    throw ProgressMemoryError.invalid("Raw progress input must be at most 64 KiB and contain no NUL characters.")
                }
            }
            try event.snapshot.validate()
        }
    }
}

enum ProgressMemoryError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let reason): return "Progress Memory: \(reason)" }
    }
}

/// The entire section is one versioned value; free-form legacy history remains separate.
enum ProgressMarkdown {
    private struct Document: Codable {
        let schemaVersion: Int
        let events: [ProgressEvent]
        private enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion = "schema_version", events }
        init(events: [ProgressEvent]) { schemaVersion = 1; self.events = events }
        init(from decoder: Decoder) throws {
            try ProgressJSON.requireKnownKeys(CodingKeys.self, in: decoder)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
            guard schemaVersion == 1 else { throw ProgressMemoryError.invalid("Only progress schema_version 1 is supported.") }
            events = try values.decode([ProgressEvent].self, forKey: .events)
            try ProgressEvent.validate(events)
        }
    }

    static func parse(_ section: String) throws -> [ProgressEvent] {
        let normalized = section.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("```json\n"), normalized.hasSuffix("\n```"),
              normalized.utf8.count <= 5 * 1_024 * 1_024 else {
            throw ProgressMemoryError.invalid("Progress Events must contain one closed json code fence, up to 5 MiB.")
        }
        let json = String(normalized.dropFirst(8).dropLast(4))
        do { return try JSONDecoder().decode(Document.self, from: Data(json.utf8)).events }
        catch let error as ProgressMemoryError { throw error }
        catch { throw ProgressMemoryError.invalid("The Progress Events JSON is malformed or contains unsupported fields/types.") }
    }

    static func serialize(_ events: [ProgressEvent], newline: String = "\n") throws -> String {
        try ProgressEvent.validate(events)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(Document(events: events)), as: UTF8.self)
        return ("```json\n" + json + "\n```").replacingOccurrences(of: "\n", with: newline)
    }
}

private enum ProgressJSON {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    static func requireKnownKeys<Keys: CodingKey & CaseIterable>(_ keys: Keys.Type, in decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let known = Set(Keys.allCases.map(\.stringValue))
        guard container.allKeys.allSatisfy({ known.contains($0.stringValue) }) else {
            throw ProgressMemoryError.invalid("Unsupported progress data field.")
        }
    }
}

/// A value-style formatter avoids sharing mutable DateFormatters across provider/test tasks.
enum ProgressTimestamp {
    static func normalized(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }

    static func format(_ date: Date) -> String {
        // Formatting fractional Date values can truncate a representational .123 to .122.
        // Format whole seconds and the integer millisecond component separately.
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        let seconds = floor(milliseconds / 1_000)
        let fraction = Int(milliseconds - seconds * 1_000)
        let whole = Date.ISO8601FormatStyle().format(Date(timeIntervalSince1970: seconds))
        return String(whole.dropLast()) + String(format: ".%03dZ", fraction)
    }

    static func parse(_ value: String) -> Date? {
        guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$", options: .regularExpression) != nil else { return nil }
        let parts = value.split(separator: "T")
        let day = parts[0].split(separator: "-").compactMap { Int($0) }
        let time = parts[1].prefix(8).split(separator: ":").compactMap { Int($0) }
        guard day.count == 3, time.count == 3, day[0] >= 1 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: day[0], month: day[1], day: day[2], hour: time[0], minute: time[1], second: time[2])
        guard let localDate = calendar.date(from: components) else { return nil }
        let checked = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: localDate)
        guard [checked.year, checked.month, checked.day, checked.hour, checked.minute, checked.second] ==
                [day[0], day[1], day[2], time[0], time[1], time[2]].map(Optional.some) else { return nil }
        if !value.hasSuffix("Z") {
            let offset = value.suffix(5).split(separator: ":").compactMap { Int($0) }
            guard offset.count == 2, offset[0] <= 23, offset[1] <= 59 else { return nil }
        }
        let style = Date.ISO8601FormatStyle(includingFractionalSeconds: value.contains("."))
        return (try? style.parse(value)).map(normalized)
    }
}
