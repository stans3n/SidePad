import Foundation

/// A deliberate recovery point, separate from task completion and ordinary activity.
/// Values are immutable evidence after persistence; inspecting one never restores live state.
struct ThreadCheckpoint: Identifiable, Codable, Equatable {
    let id: UUID
    let threadID: UUID
    let createdAt: Date
    let note: String
    let snapshot: ProgressSnapshot?
    let relatedTaskIDs: [UUID]
    let resources: [String]
    let origin: ProgressEventSource

    init(id: UUID = UUID(), threadID: UUID, createdAt: Date = Date(), note: String,
         snapshot: ProgressSnapshot? = nil, relatedTaskIDs: [UUID] = [],
         resources: [String] = [], origin: ProgressEventSource = .manual) {
        self.id = id
        self.threadID = threadID
        self.createdAt = ProgressTimestamp.normalized(createdAt)
        self.note = note
        self.snapshot = snapshot
        self.relatedTaskIDs = relatedTaskIDs
        self.resources = resources
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, threadID = "thread_id", createdAt = "created_at", note, snapshot
        case relatedTaskIDs = "related_task_ids", resources, origin
    }

    init(from decoder: Decoder) throws {
        try CheckpointJSON.requireKnownKeys(CodingKeys.self, in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        threadID = try values.decode(UUID.self, forKey: .threadID)
        let date = try values.decode(String.self, forKey: .createdAt)
        guard let parsed = ProgressTimestamp.parse(date) else {
            throw ProgressMemoryError.invalid("Checkpoint creation time must be a real ISO 8601 timestamp with timezone.")
        }
        createdAt = parsed
        note = try values.decode(String.self, forKey: .note)
        snapshot = try values.decodeIfPresent(ProgressSnapshot.self, forKey: .snapshot)
        relatedTaskIDs = try values.decode([UUID].self, forKey: .relatedTaskIDs)
        resources = try values.decode([String].self, forKey: .resources)
        origin = try values.decode(ProgressEventSource.self, forKey: .origin)
        try Self.validate([self])
    }

    func encode(to encoder: Encoder) throws {
        try Self.validate([self])
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(threadID, forKey: .threadID)
        try values.encode(ProgressTimestamp.format(createdAt), forKey: .createdAt)
        try values.encode(note, forKey: .note)
        try values.encodeIfPresent(snapshot, forKey: .snapshot)
        try values.encode(relatedTaskIDs, forKey: .relatedTaskIDs)
        try values.encode(resources, forKey: .resources)
        try values.encode(origin, forKey: .origin)
    }

    static func validate(_ checkpoints: [ThreadCheckpoint]) throws {
        guard checkpoints.count <= 10_000 else {
            throw ProgressMemoryError.invalid("A project supports at most 10,000 checkpoints.")
        }
        var ids = Set<UUID>()
        for checkpoint in checkpoints {
            guard ids.insert(checkpoint.id).inserted else {
                throw ProgressMemoryError.invalid("Duplicate checkpoint UUID: \(checkpoint.id)")
            }
            guard !checkpoint.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  checkpoint.note.utf8.count <= 64 * 1_024, !checkpoint.note.contains("\0") else {
                throw ProgressMemoryError.invalid("A checkpoint needs a note of at most 64 KiB without NUL characters.")
            }
            guard checkpoint.createdAt.timeIntervalSince1970.isFinite,
                  (Date(timeIntervalSince1970: -62_135_596_800)..<Date(timeIntervalSince1970: 253_402_300_800)).contains(checkpoint.createdAt) else {
                throw ProgressMemoryError.invalid("Checkpoint creation time must be a valid date in years 0001–9999.")
            }
            guard checkpoint.relatedTaskIDs.count <= 1_000,
                  Set(checkpoint.relatedTaskIDs).count == checkpoint.relatedTaskIDs.count,
                  checkpoint.resources.count <= 100,
                  checkpoint.resources.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 8_192 && !$0.contains("\0") }) else {
                throw ProgressMemoryError.invalid("Checkpoint task references must be unique (up to 1,000); resources must be nonempty references (up to 100, 8 KiB each).")
            }
            guard checkpoint.origin != .taskChange else {
                throw ProgressMemoryError.invalid("Task completion is an activity, not an explicit checkpoint.")
            }
            try checkpoint.snapshot?.validate()
        }
    }
}

/// The optional section has its own version so its representation can evolve independently.
enum CheckpointMarkdown {
    private struct Document: Codable {
        let schemaVersion: Int
        let checkpoints: [ThreadCheckpoint]
        private enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion = "schema_version", checkpoints }
        init(checkpoints: [ThreadCheckpoint]) { schemaVersion = 1; self.checkpoints = checkpoints }
        init(from decoder: Decoder) throws {
            try CheckpointJSON.requireKnownKeys(CodingKeys.self, in: decoder)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
            guard schemaVersion == 1 else { throw ProgressMemoryError.invalid("Only checkpoint schema_version 1 is supported.") }
            checkpoints = try values.decode([ThreadCheckpoint].self, forKey: .checkpoints)
            try ThreadCheckpoint.validate(checkpoints)
        }
    }

    static func parse(_ section: String) throws -> [ThreadCheckpoint] {
        let normalized = section.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("```json\n"), normalized.hasSuffix("\n```"), normalized.utf8.count <= 5 * 1_024 * 1_024 else {
            throw ProgressMemoryError.invalid("Checkpoints must contain one closed json code fence, up to 5 MiB.")
        }
        let json = String(normalized.dropFirst(8).dropLast(4))
        do { return try JSONDecoder().decode(Document.self, from: Data(json.utf8)).checkpoints }
        catch let error as ProgressMemoryError { throw error }
        catch { throw ProgressMemoryError.invalid("The Checkpoints JSON is malformed or contains unsupported fields/types.") }
    }

    static func serialize(_ checkpoints: [ThreadCheckpoint], newline: String = "\n") throws -> String {
        try ThreadCheckpoint.validate(checkpoints)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(Document(checkpoints: checkpoints)), as: UTF8.self)
        return ("```json\n" + json + "\n```").replacingOccurrences(of: "\n", with: newline)
    }
}

private enum CheckpointJSON {
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
            throw ProgressMemoryError.invalid("Unsupported checkpoint data field.")
        }
    }
}
