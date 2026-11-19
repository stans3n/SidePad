import AppKit
import Combine
import Foundation
import Darwin
import UniformTypeIdentifiers

@MainActor
final class AttachmentStore: ObservableObject {
    @Published private(set) var pending: [CaptureAttachment] = []
    @Published private(set) var isImporting = false
    @Published private(set) var isCaptureActive = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var storagePath = ""
    @Published private(set) var retentionDays: Int?
    @Published private(set) var cleanupMessage: String?

    static var allowedContentTypes: [UTType] { AttachmentExtraction.allowedContentTypes }
    private static let customFolder = "SidePad Temporary Attachments"
    private static let ownerFilename = ".sidepad-attachment-owner"
    private static let retentionKey = "SidePad.attachments.retentionDays"

    struct Location: Codable {
        var id: UUID
        var path: String
        var bookmark: Data?
        var isDefault: Bool
    }
    struct Record: Codable {
        var id: UUID
        var locationID: UUID
        var filename: String
        var name: String
        var importedAt: Date
        var byteCount: Int
        var inode: UInt64
        var device: Int32
        var temporary = true
        var unavailableAt: Date?
    }
    struct Manifest: Codable {
        var schemaVersion = 1
        var selectedLocation: UUID
        var locations: [Location]
        var records: [Record] = []
        var lastCleanup: Date?
    }

    let directory: URL
    private let defaults: UserDefaults
    private let fileManager = FileManager.default
    private var manifest: Manifest?
    private var contexts: [UUID: AttachmentContext] = [:]
    private var activeIDs = Set<UUID>()
    private var cleanupTimer: Timer?
    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    init(defaults: UserDefaults = .standard, defaultDirectory: URL? = nil) {
        self.defaults = defaults
        self.directory = (defaultDirectory ?? ThreadStore.defaultDirectory.appendingPathComponent("Attachments", isDirectory: true)).standardizedFileURL
        if let saved = defaults.object(forKey: Self.retentionKey) as? Int {
            retentionDays = saved == 0 ? nil : (1...365).contains(saved) ? saved : 7
        } else { retentionDays = 7 }
        do {
            try prepareStateDirectory()
            if fileManager.fileExists(atPath: manifestURL.path) {
                try requireRegularFile(manifestURL)
                let data = try boundedRead(manifestURL, limit: 8 * 1_024 * 1_024)
                guard data.count <= 8 * 1_024 * 1_024 else { throw AttachmentError.invalid("Attachment manifest is too large; storage was left unchanged.") }
                let decoded = try JSONDecoder().decode(Manifest.self, from: data)
                guard decoded.schemaVersion == 1,
                      Set(decoded.locations.map(\.id)).count == decoded.locations.count,
                      Set(decoded.records.map(\.id)).count == decoded.records.count,
                      decoded.locations.contains(where: { $0.id == decoded.selectedLocation }) else {
                    throw AttachmentError.invalid("Attachment manifest is invalid; storage was left unchanged.")
                }
                manifest = decoded
            } else {
                let location = try createLocation(at: directory.appendingPathComponent("Files", isDirectory: true), bookmark: nil, isDefault: true)
                manifest = Manifest(selectedLocation: location.id, locations: [location])
                try persist()
            }
            refreshStoragePath()
        } catch { errorMessage = error.localizedDescription }
        // No filesystem polling. A daily tick only checks eligible registered copies.
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.cleanupIfDue() }
        }
    }

    deinit { cleanupTimer?.invalidate() }

    func clearError() { errorMessage = nil }

    func importFiles(_ urls: [URL]) async {
        guard !isImporting && !isCaptureActive else { return }
        guard pending.count + urls.count <= AttachmentExtraction.maximumAttachments else {
            errorMessage = "Attach up to five files per capture."
            return
        }
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }
        var failures: [String] = []
        for url in urls {
            do {
                guard url.isFileURL else { throw AttachmentError.invalid("Only local files can be attached.") }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let ext = url.pathExtension.lowercased()
                guard AttachmentExtraction.extensions.contains(ext) else {
                    throw AttachmentError.invalid("Unsupported file type. Use TXT, MD, LOG, JSON, CSV, PDF, PNG, JPG or HEIC.")
                }
                try requireRegularFile(url)
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= AttachmentExtraction.maximumFileBytes else {
                    throw AttachmentError.invalid("Each attachment must be 10 MB or smaller.")
                }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: AttachmentExtraction.maximumFileBytes + 1) ?? Data()
                try await importData(data, name: url.lastPathComponent, extension: ext)
            } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    func importPastedImage(_ data: Data) async {
        guard !isImporting && !isCaptureActive else { return }
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }
        do { try await importData(data, name: "Pasted image.png", extension: "png") }
        catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func pasteFromClipboard() async -> Bool {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            await importFiles(urls)
            return true
        }
        if let png = board.data(forType: .png) {
            await importPastedImage(png)
            return true
        }
        if let tiff = board.data(forType: .tiff) {
            guard tiff.count <= AttachmentExtraction.maximumFileBytes,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                errorMessage = "The clipboard image is too large or unreadable."
                return true
            }
            await importPastedImage(png)
            return true
        }
        return false
    }

    private func importData(_ data: Data, name: String, extension ext: String) async throws {
        guard pending.count < AttachmentExtraction.maximumAttachments else { throw AttachmentError.invalid("Attach up to five files per capture.") }
        guard data.count <= AttachmentExtraction.maximumFileBytes else { throw AttachmentError.invalid("Each attachment must be 10 MB or smaller.") }
        guard pending.reduce(0, { $0 + $1.byteCount }) + data.count <= AttachmentExtraction.maximumTotalBytes else {
            throw AttachmentError.invalid("Attachments must total 25 MB or less per capture.")
        }
        guard let selected = manifest?.selectedLocation, let location = manifest?.locations.first(where: { $0.id == selected }) else {
            throw AttachmentError.invalid("Attachment storage is unavailable. Check Threads Attachments in Settings.")
        }
        try withLocation(location) { _ in }
        // Native parsing stays off the UI thread. The bytes are transient and never logged.
        let extraction = try await Task.detached(priority: .userInitiated) {
            try AttachmentExtraction.extract(data: data, extension: ext)
        }.value
        try Task.checkCancellation()
        let id = UUID()
        let filename = id.uuidString.lowercased() + "." + ext
        let record: Record = try withLocation(location) { folder in
            let url = folder.appendingPathComponent(filename)
            try data.write(to: url, options: [.withoutOverwriting])
            do {
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                let info = try identity(url)
                return Record(id: id, locationID: location.id, filename: filename, name: name,
                              importedAt: Date(), byteCount: data.count, inode: UInt64(info.st_ino), device: info.st_dev)
            } catch {
                // This exact freshly created filename is the only rollback target.
                try? fileManager.removeItem(at: url)
                throw error
            }
        }
        manifest?.records.append(record)
        do { try persist() }
        catch {
            manifest?.records.removeAll { $0.id == id }
            try? removeRegisteredFile(record, location: location)
            throw error
        }
        contexts[id] = AttachmentContext(id: id, name: AttachmentExtraction.boundedText(AttachmentExtraction.redactSecrets(name), characters: 180, bytes: 512),
                                         kind: ext, extraction: extraction.method, text: extraction.text, truncated: extraction.truncated)
        pending.append(CaptureAttachment(id: id, name: name, typeLabel: ext.uppercased(), byteCount: data.count,
                                         extractionLabel: extraction.label,
                                         warning: extraction.truncated ? "Extracted text was shortened to the attachment limit." : nil))
    }

    func remove(id: UUID) {
        guard !activeIDs.contains(id), !isCaptureActive else { return }
        pending.removeAll { $0.id == id }
        contexts.removeValue(forKey: id)
    }

    func clearPending() {
        guard !isCaptureActive else { return }
        pending.removeAll()
        contexts.removeAll()
    }

    func beginCapture() throws -> [AttachmentContext] {
        guard !isImporting, !isCaptureActive else { throw AttachmentError.invalid("Wait for the current import or capture to finish.") }
        var budget = AttachmentExtraction.maximumContextCharacters
        var byteBudget = AttachmentExtraction.maximumContextBytes
        let result = pending.compactMap { attachment -> AttachmentContext? in
            guard let context = contexts[attachment.id] else { return nil }
            let text = AttachmentExtraction.boundedText(context.text, characters: budget, bytes: byteBudget)
            budget -= text.count
            byteBudget -= text.utf8.count
            return AttachmentContext(id: context.id, name: context.name, kind: context.kind,
                                     extraction: context.extraction, text: text,
                                     truncated: context.truncated || text.count < context.text.count)
        }
        activeIDs = Set(pending.map(\.id))
        isCaptureActive = true
        return result
    }

    func endCapture() { activeIDs.removeAll(); isCaptureActive = false }
    func markSubmitted() { endCapture(); clearPending() }

    func setRetentionDays(_ value: Int?) throws {
        guard value == nil || (1...365).contains(value!) else { throw AttachmentError.invalid("Retention must be between 1 and 365 days.") }
        retentionDays = value
        defaults.set(value ?? 0, forKey: Self.retentionKey)
        cleanupMessage = "Retention updated. Eligible copies are removed during the next daily cleanup, or with Clean Up Now."
    }

    func setCustomDirectory(_ parent: URL) throws {
        guard !isImporting, !isCaptureActive else { throw AttachmentError.invalid("Finish the current capture or import before changing storage.") }
        guard parent.isFileURL else { throw AttachmentError.invalid("Choose a local folder.") }
        let access = parent.startAccessingSecurityScopedResource()
        defer { if access { parent.stopAccessingSecurityScopedResource() } }
        try requireDirectory(parent)
        let canonical = parent.standardizedFileURL.resolvingSymlinksInPath()
        let folder = canonical.appendingPathComponent(Self.customFolder, isDirectory: true)
        let bookmark: Data?
        do { bookmark = try parent.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) }
        catch {
            if CodexCLIProvider.isAppSandboxed { throw AttachmentError.invalid("Could not save folder access. Select the folder again.") }
            bookmark = nil
        }
        guard var updated = manifest else { throw AttachmentError.invalid("Attachment manifest is unavailable; existing files were left unchanged.") }
        var registeredIndex = updated.locations.firstIndex(where: { $0.path == folder.path })
        if registeredIndex == nil, fileManager.fileExists(atPath: folder.path) {
            try requireDirectory(folder)
            let marker = folder.appendingPathComponent(Self.ownerFilename)
            try requireRegularFile(marker)
            let owner = String(decoding: try boundedRead(marker, limit: 36), as: UTF8.self)
            registeredIndex = updated.locations.firstIndex { !$0.isDefault && $0.id.uuidString == owner }
        }
        if let index = registeredIndex {
            // Reselecting a moved folder recovers its existing registrations and refreshes access.
            updated.locations[index].path = folder.path
            updated.locations[index].bookmark = bookmark
            try withLocation(updated.locations[index]) { _ in }
            updated.selectedLocation = updated.locations[index].id
        } else {
            let location = try createLocation(at: folder, bookmark: bookmark, isDefault: false)
            updated.locations.append(location)
            updated.selectedLocation = location.id
        }
        let previous = manifest
        manifest = updated
        do { try persist(); refreshStoragePath(); errorMessage = nil }
        catch { manifest = previous; throw error }
    }

    func resetStorageLocation() throws {
        guard !isImporting, !isCaptureActive else { throw AttachmentError.invalid("Finish the current capture or import before changing storage.") }
        guard let location = manifest?.locations.first(where: \.isDefault) else { throw AttachmentError.invalid("Default attachment location is unavailable.") }
        try withLocation(location) { _ in }
        let previous = manifest?.selectedLocation
        manifest?.selectedLocation = location.id
        do { try persist(); refreshStoragePath(); errorMessage = nil }
        catch { if let previous { manifest?.selectedLocation = previous }; throw error }
    }

    func openStorageFolder() {
        do {
            guard let location = selectedLocation else { throw AttachmentError.invalid("Attachment storage is unavailable.") }
            _ = try withLocation(location) { url in NSWorkspace.shared.open(url) }
        } catch { errorMessage = error.localizedDescription }
    }

    var eligibleCleanupCount: Int { eligibleRecords(now: Date()).count }
    var registeredAttachmentCount: Int { manifest?.records.filter { $0.unavailableAt == nil }.count ?? 0 }

    func cleanupIfDue(now: Date = Date()) {
        guard let manifest, manifest.lastCleanup.map({ now.timeIntervalSince($0) >= 86_400 }) ?? true else { return }
        cleanupNow(now: now)
    }

    func cleanupNow(now: Date = Date()) {
        guard !isImporting else { return }
        var removed = 0
        var failures = 0
        for record in eligibleRecords(now: now) {
            guard let location = manifest?.locations.first(where: { $0.id == record.locationID }) else { failures += 1; continue }
            do {
                try removeRegisteredFile(record, location: location)
                if let index = manifest?.records.firstIndex(where: { $0.id == record.id }) { manifest?.records[index].unavailableAt = now }
                removed += 1
            } catch { failures += 1 }
        }
        manifest?.lastCleanup = now
        do { if manifest != nil { try persist() } }
        catch { errorMessage = error.localizedDescription }
        cleanupMessage = "\(removed) expired temporary attachment\(removed == 1 ? "" : "s") removed."
        if failures > 0 { errorMessage = "\(failures) attachment\(failures == 1 ? "" : "s") could not be cleaned safely. Check folder access; files were left in place." }
    }

    private func eligibleRecords(now: Date) -> [Record] {
        guard let days = retentionDays else { return [] }
        let protected = activeIDs.union(pending.map(\.id))
        return manifest?.records.filter {
            $0.temporary && $0.unavailableAt == nil && !protected.contains($0.id) &&
            now.timeIntervalSince($0.importedAt) >= Double(days) * 86_400
        } ?? []
    }

    private var selectedLocation: Location? { manifest?.locations.first { $0.id == manifest?.selectedLocation } }
    private func refreshStoragePath() {
        guard let location = selectedLocation else { storagePath = directory.path; return }
        storagePath = (try? withLocation(location) { $0.standardizedFileURL.path }) ?? location.path
    }

    private func prepareStateDirectory() throws {
        try requireNoUserSymlinks(directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try requireDirectory(directory)
    }

    private func createLocation(at folder: URL, bookmark: Data?, isDefault: Bool) throws -> Location {
        let id = UUID()
        if fileManager.fileExists(atPath: folder.path) {
            // Never adopt an existing directory, even if it has a plausible name or marker.
            throw AttachmentError.invalid("The managed attachment folder already exists but is not registered. Choose another parent folder; existing contents were left unchanged.")
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try requireDirectory(folder)
        try Data(id.uuidString.utf8).write(to: folder.appendingPathComponent(Self.ownerFilename), options: [.withoutOverwriting])
        return Location(id: id, path: folder.path, bookmark: bookmark, isDefault: isDefault)
    }

    private func persist() throws {
        guard let manifest else { throw AttachmentError.invalid("Attachment storage is unavailable.") }
        try requireDirectory(directory)
        if fileManager.fileExists(atPath: manifestURL.path) { try requireRegularFile(manifestURL) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    }

    private func withLocation<T>(_ location: Location, body: (URL) throws -> T) throws -> T {
        let folder: URL
        var scopedParent: URL?
        if let bookmark = location.bookmark {
            var stale = false
            let parent = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw AttachmentError.invalid("Attachment folder access has expired. Choose that folder again in Settings.") }
            if parent.startAccessingSecurityScopedResource() { scopedParent = parent }
            folder = parent.appendingPathComponent(Self.customFolder, isDirectory: true)
        } else { folder = URL(fileURLWithPath: location.path, isDirectory: true) }
        defer { scopedParent?.stopAccessingSecurityScopedResource() }
        try requireDirectory(folder)
        let marker = folder.appendingPathComponent(Self.ownerFilename)
        try requireRegularFile(marker)
        guard try boundedRead(marker, limit: 36) == Data(location.id.uuidString.utf8) else {
            throw AttachmentError.invalid("Attachment folder ownership could not be verified. Files were left unchanged.")
        }
        return try body(folder)
    }

    private func boundedRead(_ url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw AttachmentError.invalid("Attachment metadata exceeds its size limit; storage was left unchanged.") }
        return data
    }

    private func requireDirectory(_ url: URL) throws {
        try requireNoUserSymlinks(url)
        let info = try identity(url)
        guard info.st_mode & S_IFMT == S_IFDIR else { throw AttachmentError.invalid("Attachment storage folder is missing or unavailable.") }
    }

    private func requireNoUserSymlinks(_ url: URL) throws {
        // Foundation collapses /private/var to /var for existing URLs. Comparing resolved
        // path strings therefore falsely rejects valid roots after relaunch; inspect each component.
        let systemAliases = ["/var": "/private/var", "/tmp": "/private/tmp", "/etc": "/private/etc"]
        var prefix = ""
        for component in (url.path as NSString).pathComponents where component != "/" {
            prefix += "/" + component
            var info = stat()
            if lstat(prefix, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
                let target = try fileManager.destinationOfSymbolicLink(atPath: prefix)
                guard let expected = systemAliases[prefix], target == expected || target == String(expected.dropFirst()) else {
                    throw AttachmentError.invalid("Symbolic links are not allowed in managed attachment paths.")
                }
            }
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        let info = try identity(url)
        guard info.st_mode & S_IFMT == S_IFREG else { throw AttachmentError.invalid("Only regular files are supported; symbolic links are not allowed.") }
    }

    private func identity(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        return info
    }

    private func removeRegisteredFile(_ record: Record, location: Location) throws {
        let ext = (record.filename as NSString).pathExtension
        guard record.temporary, record.filename == record.id.uuidString.lowercased() + "." + ext,
              AttachmentExtraction.extensions.contains(ext), record.locationID == location.id else {
            throw AttachmentError.invalid("Invalid attachment registration; no file was removed.")
        }
        try withLocation(location) { folder in
            // The directory descriptor and unlinkat prevent a file symlink from redirecting deletion.
            let directoryFD = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard directoryFD >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            defer { close(directoryFD) }
            let ownerFD = openat(directoryFD, Self.ownerFilename, O_RDONLY | O_NOFOLLOW)
            guard ownerFD >= 0 else { throw AttachmentError.invalid("Attachment folder ownership is unavailable.") }
            defer { close(ownerFD) }
            var markerBytes = [UInt8](repeating: 0, count: 37)
            let markerCount = read(ownerFD, &markerBytes, markerBytes.count)
            guard markerCount == 36, Data(markerBytes.prefix(36)) == Data(location.id.uuidString.utf8) else {
                throw AttachmentError.invalid("Attachment folder ownership changed; no file was removed.")
            }
            var info = stat()
            if fstatat(directoryFD, record.filename, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { return }
                throw CocoaError(.fileWriteUnknown)
            }
            guard info.st_mode & S_IFMT == S_IFREG, UInt64(info.st_ino) == record.inode, info.st_dev == record.device else {
                throw AttachmentError.invalid("Attachment identity changed; the file was left unchanged.")
            }
            guard unlinkat(directoryFD, record.filename, 0) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        }
    }
}
