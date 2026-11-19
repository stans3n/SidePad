import Foundation

enum ThreadMarkdownError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let detail): return "Thread Markdown: \(detail)" }
    }
}

/// Keeps the source and ranges so editing one field never reflows unrelated prose.
struct ThreadMarkdown {
    let record: ThreadRecord
    let schemaVersion: Int
    let source: String
    private let metadata: [String: Scalar]
    private let sections: [String: Range<String.Index>]
    private let metadataEnd: String.Index
    private let newline: String
    private let hasLegacyCheckpointHeading: Bool

    private struct Line {
        var content: Range<String.Index>
        var full: Range<String.Index>
    }
    private struct Scalar {
        var value: String?
        var quoted: Bool
        var range: Range<String.Index>
    }
    private static let bodyFields: [(String, WritableKeyPath<ThreadRecord, String>)] = [
        ("Summary", \.summary), ("Current State", \.currentState), ("Next Action", \.nextAction),
        ("Blockers", \.blockers), ("Resume Point", \.resumePoint), ("Notes", \.notes),
        ("Progress History", \.progressHistory), ("Linked Resources", \.linkedResources)
    ]

    static func parse(_ source: String) throws -> ThreadMarkdown {
        let lines = lines(in: source)
        guard let first = lines.first, source[first.content] == "---",
              let end = lines.dropFirst().firstIndex(where: { source[$0.content] == "---" }) else {
            throw ThreadMarkdownError.invalid("A document must begin with a closed --- frontmatter block.")
        }
        var metadata: [String: Scalar] = [:]
        for line in lines[1..<end] {
            let text = String(source[line.content])
            if text.trimmingCharacters(in: .whitespaces).isEmpty || text.hasPrefix("#") { continue }
            guard let colon = source[line.content].firstIndex(of: ":") else {
                throw ThreadMarkdownError.invalid("Invalid frontmatter line: \(text.prefix(80))")
            }
            let key = String(source[line.content.lowerBound..<colon])
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_-]*$", options: .regularExpression) != nil else {
                throw ThreadMarkdownError.invalid("Only unindented scalar metadata keys are supported.")
            }
            guard metadata[key] == nil else {
                throw ThreadMarkdownError.invalid("Duplicate metadata key: \(key)")
            }
            metadata[key] = try scalar(in: source, range: source.index(after: colon)..<line.content.upperBound)
        }
        func required(_ key: String) throws -> String {
            guard let value = metadata[key]?.value else {
                throw ThreadMarkdownError.invalid("Missing or null metadata: \(key)")
            }
            return value
        }
        guard let schemaVersion = Int(try required("schema_version")), [1, 2].contains(schemaVersion),
              metadata["schema_version"]?.quoted == false else {
            throw ThreadMarkdownError.invalid("Only schema_version: 1 or 2 is supported.")
        }
        guard let id = UUID(uuidString: try required("id")),
              let status = ThreadStatus(rawValue: try required("status")) else {
            throw ThreadMarkdownError.invalid("Invalid Thread UUID or status.")
        }
        let title = try required("title")
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !title.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw ThreadMarkdownError.invalid("Title must be nonempty and occupy one line.")
        }
        var parentID: UUID?
        if let parent = metadata["parent_id"]?.value {
            guard let parsed = UUID(uuidString: parent) else {
                throw ThreadMarkdownError.invalid("parent_id must be a UUID or null.")
            }
            parentID = parsed
        }
        func date(_ key: String) throws -> Date {
            guard let parsed = parseDate(try required(key)) else {
                throw ThreadMarkdownError.invalid("\(key) must be an ISO 8601 timestamp with timezone.")
            }
            return parsed
        }
        let createdAt = try date("created_at")
        let updatedAt = try date("updated_at")
        let lastActivity = try metadata["last_activity"] == nil ? updatedAt : date("last_activity")
        var record = ThreadRecord(id: id, title: title, parentID: parentID, status: status,
                                  createdAt: createdAt, updatedAt: updatedAt, lastActivity: lastActivity)
        var sections: [String: Range<String.Index>] = [:]
        var active: (name: String, start: String.Index)?
        var fence: (character: Character, count: Int)?
        var hasLegacyCheckpointHeading = false
        let names = Set(bodyFields.map(\.0) + ["Progress Events"] + (schemaVersion >= 2 ? ["Checkpoints"] : []))
        for line in lines.dropFirst(end + 1) {
            let raw = String(source[line.content])
            let text = raw.trimmingCharacters(in: .whitespaces)
            if let token = fenceToken(text), raw.prefix(while: { $0 == " " }).count <= 3 {
                if let current = fence {
                    if token.character == current.character && token.count >= current.count && token.remainder.isEmpty {
                        fence = nil
                    }
                } else {
                    fence = (token.character, token.count)
                }
                continue
            }
            if fence != nil { continue }
            // H1/H2 delimit sections. H3 and deeper remain editable field content.
            guard raw.hasPrefix("# ") || raw.hasPrefix("## ") else { continue }
            if let current = active { sections[current.name] = current.start..<line.full.lowerBound }
            active = nil
            if raw.hasPrefix("## ") {
                let name = String(raw.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if schemaVersion == 1 && name == "Checkpoints" { hasLegacyCheckpointHeading = true }
                if names.contains(name) {
                    guard sections[name] == nil else {
                        throw ThreadMarkdownError.invalid("Duplicate section: \(name)")
                    }
                    active = (name, line.full.upperBound)
                }
            }
        }
        if let current = active { sections[current.name] = current.start..<source.endIndex }
        for (name, keyPath) in bodyFields {
            if let range = sections[name] {
                record[keyPath: keyPath] = String(source[range]).trimmingCharacters(in: .newlines)
            }
        }
        if let range = sections["Progress Events"] {
            record.progressEvents = try ProgressMarkdown.parse(String(source[range]))
        }
        if let range = sections["Checkpoints"] {
            record.checkpoints = try CheckpointMarkdown.parse(String(source[range]))
        }
        return ThreadMarkdown(record: record, schemaVersion: schemaVersion, source: source, metadata: metadata, sections: sections,
                              metadataEnd: lines[end].full.lowerBound,
                              newline: source.contains("\r\n") ? "\r\n" : "\n",
                              hasLegacyCheckpointHeading: hasLegacyCheckpointHeading)
    }

    /// A new document uses a predictable schema; an existing one uses surgical replacements.
    static func serialize(_ record: ThreadRecord) throws -> String {
        let fields = try metadataValues(record)
        let order = ["schema_version", "id", "parent_id", "title", "status", "created_at", "updated_at", "last_activity"]
        var text = "---\n" + order.map { "\($0): \(fields[$0]!)\n" }.joined() + "---\n\n# \(record.title)\n\n"
        text += bodyFields.map { "## \($0.0)\n\(record[keyPath: $0.1])\n\n" }.joined()
        if !record.progressEvents.isEmpty {
            text += "## Progress Events\n" + (try ProgressMarkdown.serialize(record.progressEvents)) + "\n\n"
        }
        if !record.checkpoints.isEmpty {
            text += "## Checkpoints\n" + (try CheckpointMarkdown.serialize(record.checkpoints)) + "\n\n"
        }
        try validateNarrativeRoundTrip(text, expected: record)
        return text
    }

    func updating(_ updated: ThreadRecord) throws -> String {
        if updated == record { return source }
        var before = try Self.metadataValues(record)
        var after = try Self.metadataValues(updated)
        before["schema_version"] = String(schemaVersion)
        after["schema_version"] = String(max(schemaVersion, updated.checkpoints.isEmpty ? 1 : 2))
        if schemaVersion == 1 && !updated.checkpoints.isEmpty && hasLegacyCheckpointHeading {
            throw ThreadMarkdownError.invalid("This legacy file already has a custom Checkpoints heading. Rename that heading before creating a checkpoint; its content was not changed.")
        }
        var edits: [(Range<String.Index>, String)] = []
        var missingMetadata = ""
        for key in after.keys.sorted() where before[key] != after[key] {
            if let field = metadata[key] { edits.append((field.range, after[key]!)) }
            else { missingMetadata += "\(key): \(after[key]!)\(newline)" }
        }
        if !missingMetadata.isEmpty { edits.append((metadataEnd..<metadataEnd, missingMetadata)) }
        var additions = ""
        for (name, keyPath) in Self.bodyFields where record[keyPath: keyPath] != updated[keyPath: keyPath] {
            if let range = sections[name] {
                let old = String(source[range])
                let leading = String(old.prefix(while: { $0.isNewline }))
                let trailing = String(old.reversed().prefix(while: { $0.isNewline }).reversed())
                // Whitespace within a changed field belongs to the editor; section separators survive.
                edits.append((range, leading + updated[keyPath: keyPath] + (trailing.isEmpty ? newline + newline : trailing)))
            } else {
                additions += "\(newline)## \(name)\(newline)\(updated[keyPath: keyPath])\(newline)"
            }
        }
        if record.progressEvents != updated.progressEvents {
            let events = try ProgressMarkdown.serialize(updated.progressEvents, newline: newline)
            if let range = sections["Progress Events"] {
                let old = String(source[range])
                let leading = String(old.prefix(while: { $0.isNewline }))
                let trailing = String(old.reversed().prefix(while: { $0.isNewline }).reversed())
                edits.append((range, leading + events + (trailing.isEmpty ? newline + newline : trailing)))
            } else {
                additions += "\(newline)## Progress Events\(newline)\(events)\(newline)"
            }
        }
        if record.checkpoints != updated.checkpoints {
            let checkpoints = try CheckpointMarkdown.serialize(updated.checkpoints, newline: newline)
            if let range = sections["Checkpoints"] {
                let old = String(source[range])
                let leading = String(old.prefix(while: { $0.isNewline }))
                let trailing = String(old.reversed().prefix(while: { $0.isNewline }).reversed())
                edits.append((range, leading + checkpoints + (trailing.isEmpty ? newline + newline : trailing)))
            } else {
                additions += "\(newline)## Checkpoints\(newline)\(checkpoints)\(newline)"
            }
        }
        var result = source
        for (range, text) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            result.replaceSubrange(range, with: text)
        }
        if !additions.isEmpty { result += (result.hasSuffix("\n") ? "" : newline) + additions }
        try Self.validateNarrativeRoundTrip(result, expected: updated)
        return result
    }

    private static func validateNarrativeRoundTrip(_ source: String, expected: ThreadRecord) throws {
        let actual = try parse(source).record
        for (name, keyPath) in bodyFields {
            guard actual[keyPath: keyPath] == expected[keyPath: keyPath].trimmingCharacters(in: .newlines) else {
                throw ThreadMarkdownError.invalid("\(name) contains a section boundary or an unclosed code fence. Use ### or deeper headings inside a field, and close fenced code blocks.")
            }
        }
        guard actual.checkpoints == expected.checkpoints else {
            throw ThreadMarkdownError.invalid("Checkpoints did not survive serialization.")
        }
        guard try ProgressMarkdown.serialize(actual.progressEvents) == ProgressMarkdown.serialize(expected.progressEvents) else {
            throw ThreadMarkdownError.invalid("Progress Events did not survive serialization.")
        }
    }

    private static func metadataValues(_ record: ThreadRecord) throws -> [String: String] {
        func quote(_ value: String) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
        return ["schema_version": record.checkpoints.isEmpty ? "1" : "2", "id": try quote(record.id.uuidString.lowercased()),
                "parent_id": try record.parentID.map { try quote($0.uuidString.lowercased()) } ?? "null",
                "title": try quote(record.title), "status": record.status.rawValue,
                "created_at": try quote(formatDate(record.createdAt)), "updated_at": try quote(formatDate(record.updatedAt)),
                "last_activity": try quote(formatDate(record.lastActivity))]
    }

    private static func lines(in source: String) -> [Line] {
        var lines: [Line] = []
        var start = source.startIndex
        while start < source.endIndex {
            let newline = source[start...].firstIndex(where: { $0.isNewline })
            let end = newline ?? source.endIndex
            let contentEnd = end > start && source[source.index(before: end)] == "\r" ? source.index(before: end) : end
            let fullEnd = newline.map { source.index(after: $0) } ?? source.endIndex
            lines.append(Line(content: start..<contentEnd, full: start..<fullEnd))
            start = fullEnd
        }
        return lines
    }

    private static func scalar(in source: String, range: Range<String.Index>) throws -> Scalar {
        var start = range.lowerBound
        while start < range.upperBound && (source[start] == " " || source[start] == "\t") { start = source.index(after: start) }
        guard start < range.upperBound else { throw ThreadMarkdownError.invalid("Empty metadata values must use null or quoted text.") }
        var end = range.upperBound
        let first = source[start]
        let quoted = first == "\"" || first == "'"
        if quoted {
            var cursor = source.index(after: start)
            var closed: String.Index?
            while cursor < range.upperBound {
                if first == "\"" && source[cursor] == "\\" {
                    cursor = source.index(after: cursor)
                    guard cursor < range.upperBound else { break }
                } else if source[cursor] == first {
                    let next = source.index(after: cursor)
                    if first == "'" && next < range.upperBound && source[next] == "'" { cursor = next }
                    else { closed = next; break }
                }
                cursor = source.index(after: cursor)
            }
            guard let closed else { throw ThreadMarkdownError.invalid("Unterminated quoted metadata value.") }
            let tail = source[closed..<range.upperBound]
            let trimmed = tail.trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty || (tail.first?.isWhitespace == true && trimmed.hasPrefix("#")) else {
                throw ThreadMarkdownError.invalid("Unexpected text after a quoted metadata value.")
            }
            end = closed
        } else {
            var cursor = start
            while cursor < end {
                if source[cursor] == "#" && (cursor == start || source[source.index(before: cursor)].isWhitespace) { end = cursor; break }
                cursor = source.index(after: cursor)
            }
            while end > start && source[source.index(before: end)].isWhitespace { end = source.index(before: end) }
        }
        let raw = String(source[start..<end])
        var value: String?
        if first == "\"" {
            guard let decoded = try? JSONDecoder().decode(String.self, from: Data(raw.utf8)) else {
                throw ThreadMarkdownError.invalid("Double-quoted values must use JSON-compatible string escapes.")
            }
            value = decoded
        } else if first == "'" {
            value = String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        } else {
            guard !raw.isEmpty, !"[]{}&*!|>@`%".contains(first), !raw.hasPrefix("- "),
                  !raw.hasPrefix("? "), !raw.hasPrefix(": "),
                  raw.range(of: ":[ \\t]", options: .regularExpression) == nil else {
                throw ThreadMarkdownError.invalid("Only scalar YAML is supported; quote complex text. Collections, aliases, tags, and block scalars are unsupported.")
            }
            value = raw == "null" || raw == "~" ? nil : raw
        }
        return Scalar(value: value, quoted: quoted, range: start..<end)
    }

    private static func fenceToken(_ line: String) -> (character: Character, count: Int, remainder: String)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let count = line.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        return (first, count, String(line.dropFirst(count)).trimmingCharacters(in: .whitespaces))
    }

    private static func parseDate(_ value: String) -> Date? {
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func formatDate(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }
}
