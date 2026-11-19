import Foundation
import Testing
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Darwin
@testable import SidePad

@Suite(.serialized)
@MainActor
struct AttachmentTests {
    @MainActor
    private struct Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        var storage: URL { root.appendingPathComponent("managed", isDirectory: true) }
        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("sidepad-attachment-tests-" + UUID().uuidString, isDirectory: true)
            suite = "SidePadAttachmentTests." + UUID().uuidString
            defaults = UserDefaults(suiteName: suite)!
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func clean() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        func file(_ name: String, data: Data) throws -> URL {
            let url = root.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
        func store() -> AttachmentStore { AttachmentStore(defaults: defaults, defaultDirectory: storage) }
        func manifest() throws -> AttachmentStore.Manifest {
            try JSONDecoder().decode(AttachmentStore.Manifest.self, from: Data(contentsOf: storage.appendingPathComponent("manifest.json")))
        }
        func updateManifest(_ edit: (inout AttachmentStore.Manifest) -> Void) throws {
            var value = try manifest()
            edit(&value)
            try JSONEncoder().encode(value).write(to: storage.appendingPathComponent("manifest.json"), options: .atomic)
        }
        func managedURL(_ record: AttachmentStore.Record) throws -> URL {
            let location = try #require(manifest().locations.first { $0.id == record.locationID })
            return URL(fileURLWithPath: location.path).appendingPathComponent(record.filename)
        }
    }

    @Test func textImportUsesCopiesRedactsSecretsAndKeepsExtractionTransient() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let source = "Build failed at step 4\napi_key=sk-synthetic_secret_1234\npassword=\"a b c\"\n{\"client_secret\":\"space sensitive secret\"}"
        let file = try fixture.file("build.log", data: Data(source.utf8))
        let store = fixture.store()
        await store.importFiles([file])
        #expect(store.errorMessage == nil)
        #expect(store.pending.count == 1)
        let payload = try #require(store.beginCapture().first)
        #expect(payload.text.contains("Build failed at step 4"))
        #expect(!payload.text.contains("synthetic_secret"))
        #expect(!payload.text.contains("a b c"))
        #expect(!payload.text.contains("space sensitive secret"))
        #expect(payload.text.contains("[REDACTED]"))
        let manifest = try fixture.manifest()
        #expect(manifest.records.count == 1)
        let copy = try fixture.managedURL(manifest.records[0])
        #expect(copy != file)
        #expect(try Data(contentsOf: copy) == Data(source.utf8))
        let persisted = try String(contentsOf: fixture.storage.appendingPathComponent("manifest.json"), encoding: .utf8)
        #expect(!persisted.contains("Build failed"))
        #expect(!persisted.contains("synthetic_secret"))
        store.endCapture()
        store.remove(id: payload.id)
        #expect(store.pending.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == source)
    }

    @Test func rejectsUnsupportedOversizedBinaryAndCountLimit() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let store = fixture.store()
        let unsupported = try fixture.file("program.exe", data: Data("hello".utf8))
        await store.importFiles([unsupported])
        #expect(store.pending.isEmpty)
        #expect(store.errorMessage?.contains("Unsupported") == true)
        let large = try fixture.file("large.txt", data: Data(repeating: 65, count: AttachmentExtraction.maximumFileBytes + 1))
        await store.importFiles([large])
        #expect(store.errorMessage?.contains("10 MB") == true)
        let binary = try fixture.file("binary.txt", data: Data([0, 0, 0, 0]))
        await store.importFiles([binary])
        #expect(store.pending.isEmpty)
        let normal = try fixture.file("normal.txt", data: Data("safe text".utf8))
        await store.importFiles(Array(repeating: normal, count: 6))
        #expect(store.pending.isEmpty)
        #expect(store.errorMessage?.contains("five") == true)
    }

    @Test func totalImportAndChineseContextBudgetsAreBounded() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let store = fixture.store()
        let large = try fixture.file("large.txt", data: Data(repeating: 65, count: 9 * 1_024 * 1_024))
        await store.importFiles([large, large, large])
        #expect(store.pending.count == 2)
        #expect(store.errorMessage?.contains("25 MB") == true)
        store.clearPending()
        let chinese = try fixture.file("chinese.md", data: Data(String(repeating: "界", count: 8_000).utf8))
        await store.importFiles([chinese, chinese, chinese])
        let contexts = try store.beginCapture()
        #expect(contexts.count == 3)
        #expect(contexts.reduce(0) { $0 + $1.text.count } <= 12_000)
        #expect(contexts.reduce(0) { $0 + $1.text.utf8.count } <= 20_000)
        #expect(contexts.allSatisfy { $0.truncated })
        #expect(!contexts.contains { $0.text.contains("�") })
        store.endCapture()
    }

    @Test func customLocationResetAndRetentionSurviveRelaunch() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let store = fixture.store()
        let originalPath = store.storagePath
        let parent = fixture.root.appendingPathComponent("custom")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try store.setCustomDirectory(parent)
        #expect(store.storagePath.hasSuffix("SidePad Temporary Attachments"))
        try store.setRetentionDays(19)
        let file = try fixture.file("input.txt", data: Data("context".utf8))
        await store.importFiles([file])
        store.clearPending()
        let reopened = fixture.store()
        #expect(reopened.errorMessage == nil)
        #expect(reopened.storagePath == store.storagePath)
        #expect(reopened.retentionDays == 19)
        #expect(reopened.registeredAttachmentCount == 1)
        try reopened.resetStorageLocation()
        #expect(reopened.storagePath == originalPath)
        #expect(try fixture.manifest().locations.count == 2)
        #expect(try fixture.manifest().records.count == 1)
        #expect(throws: (any Error).self) { try reopened.setRetentionDays(0) }
        #expect(throws: (any Error).self) { try reopened.setRetentionDays(366) }
    }

    @Test func reselectingMovedCustomFolderPreservesRegistrationsAndCleanup() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let store = fixture.store()
        let oldParent = fixture.root.appendingPathComponent("old-parent")
        let newParent = fixture.root.appendingPathComponent("new-parent")
        try FileManager.default.createDirectory(at: oldParent, withIntermediateDirectories: true)
        try store.setCustomDirectory(oldParent)
        let original = try fixture.file("original.txt", data: Data("original".utf8))
        await store.importFiles([original])
        store.clearPending()
        let before = try fixture.manifest()
        try FileManager.default.moveItem(at: oldParent, to: newParent)
        try store.setCustomDirectory(newParent)
        #expect(URL(fileURLWithPath: store.storagePath).standardizedFileURL.path.hasPrefix(newParent.standardizedFileURL.path + "/"))
        #expect(try fixture.manifest().selectedLocation == before.selectedLocation)
        #expect(try fixture.manifest().records.first?.id == before.records.first?.id)
        let managed = try fixture.managedURL(before.records[0])
        #expect(FileManager.default.fileExists(atPath: managed.path))
        try store.resetStorageLocation()
        store.cleanupNow(now: Date().addingTimeInterval(8 * 86_400))
        #expect(!FileManager.default.fileExists(atPath: managed.path))
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test func cleanupExpiresOnlyRegisteredTemporaryCopiesAndPreservesMetadata() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let store = fixture.store()
        let original = try fixture.file("original.txt", data: Data("original content".utf8))
        await store.importFiles([original, original])
        store.clearPending()
        let records = try fixture.manifest().records
        let expired = try fixture.managedURL(records[0])
        let permanent = try fixture.managedURL(records[1])
        let unrelated = expired.deletingLastPathComponent().appendingPathComponent("personal.txt")
        try Data("do not remove".utf8).write(to: unrelated)
        try fixture.updateManifest { value in
            value.records[0].importedAt = .distantPast
            value.records[1].importedAt = .distantPast
            value.records[1].temporary = false
        }
        let reopened = fixture.store()
        #expect(reopened.errorMessage == nil)
        #expect(FileManager.default.fileExists(atPath: expired.path)) // Initializing alone never cleans user storage.
        reopened.cleanupIfDue()
        #expect(!FileManager.default.fileExists(atPath: expired.path))
        #expect(FileManager.default.fileExists(atPath: permanent.path))
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(try fixture.manifest().records[0].unavailableAt != nil)
        #expect(try fixture.manifest().records.count == 2)
        #expect(try fixture.manifest().lastCleanup != nil)
    }

    @Test func pendingAndActiveCapturesAreProtectedAndNeverRetentionPersists() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let store = fixture.store()
        let file = try fixture.file("input.txt", data: Data("keep me".utf8))
        await store.importFiles([file])
        let record = try #require(fixture.manifest().records.first)
        let managed = try fixture.managedURL(record)
        let future = Date().addingTimeInterval(400 * 86_400)
        store.cleanupNow(now: future)
        #expect(FileManager.default.fileExists(atPath: managed.path))
        _ = try store.beginCapture()
        store.remove(id: record.id)
        store.clearPending()
        #expect(store.pending.count == 1)
        store.cleanupNow(now: future)
        #expect(FileManager.default.fileExists(atPath: managed.path))
        store.markSubmitted()
        try store.setRetentionDays(nil)
        store.cleanupNow(now: future)
        #expect(FileManager.default.fileExists(atPath: managed.path))
        #expect(fixture.store().retentionDays == nil)
        try store.setRetentionDays(1)
        store.cleanupNow(now: future)
        #expect(!FileManager.default.fileExists(atPath: managed.path))
    }

    @Test func missingFilesAreGracefulAndMissingFolderIsReported() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let store = fixture.store()
        let original = try fixture.file("input.txt", data: Data("keep".utf8))
        await store.importFiles([original])
        store.clearPending()
        let record = try #require(fixture.manifest().records.first)
        let file = try fixture.managedURL(record)
        try FileManager.default.removeItem(at: file)
        store.cleanupNow(now: Date().addingTimeInterval(8 * 86_400))
        #expect(try fixture.manifest().records[0].unavailableAt != nil)
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        await store.importFiles([original])
        #expect(store.pending.isEmpty)
        #expect(store.errorMessage != nil)
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test func symlinkInputsManifestStorageAndCleanupCannotReachOutside() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let original = try fixture.file("original.txt", data: Data("protected".utf8))
        let link = fixture.root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let store = fixture.store()
        await store.importFiles([link])
        #expect(store.pending.isEmpty)
        #expect(store.errorMessage?.contains("symbolic") == true)
        await store.importFiles([original])
        store.clearPending()
        let record = try #require(fixture.manifest().records.first)
        let managed = try fixture.managedURL(record)
        try FileManager.default.removeItem(at: managed)
        try FileManager.default.createSymbolicLink(at: managed, withDestinationURL: original)
        store.cleanupNow(now: Date().addingTimeInterval(8 * 86_400))
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(store.errorMessage?.contains("cleaned safely") == true)
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let storageLink = fixture.root.appendingPathComponent("storage-link")
        try FileManager.default.createSymbolicLink(at: storageLink, withDestinationURL: outside)
        let rejected = AttachmentStore(defaults: fixture.defaults, defaultDirectory: storageLink)
        #expect(rejected.errorMessage?.contains("Symbolic") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        let manifestURL = fixture.storage.appendingPathComponent("manifest.json")
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: original)
        #expect(fixture.store().errorMessage != nil)
        #expect(try String(contentsOf: original, encoding: .utf8) == "protected")
    }

    @Test func pathTraversalAndReplacedFileRegistrationsAreRejected() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let store = fixture.store()
        let original = try fixture.file("original.txt", data: Data("protected".utf8))
        await store.importFiles([original, original])
        store.clearPending()
        let records = try fixture.manifest().records
        let replaced = try fixture.managedURL(records[1])
        // Atomic replacement has a different identity; it is no longer the registered copy.
        try Data("externally replaced".utf8).write(to: replaced, options: .atomic)
        try fixture.updateManifest { manifest in
            manifest.records[0].filename = "../../original.txt"
            manifest.records[0].importedAt = .distantPast
            manifest.records[1].importedAt = .distantPast
        }
        let reopened = fixture.store()
        #expect(reopened.errorMessage == nil)
        reopened.cleanupNow()
        #expect(reopened.errorMessage?.contains("cleaned safely") == true)
        #expect(try String(contentsOf: replaced, encoding: .utf8) == "externally replaced")
        #expect(try String(contentsOf: original, encoding: .utf8) == "protected")
    }

    @Test func readOnlyDirectoryRejectsImportWithoutTouchingOriginal() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let store = fixture.store()
        let original = try fixture.file("input.txt", data: Data("original".utf8))
        try #require(store.errorMessage == nil)
        try #require(!store.storagePath.isEmpty)
        let folder = URL(fileURLWithPath: store.storagePath)
        try #require(folder.standardizedFileURL.path.hasPrefix(fixture.root.standardizedFileURL.path + "/"))
        let permissions = try #require(FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: folder.path) }
        await store.importFiles([original])
        if geteuid() != 0 {
            #expect(store.pending.isEmpty)
            #expect(store.errorMessage != nil)
        }
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
    }

    @Test func pdfTextExtractionAndEmptyPDFError() throws {
        let text = try AttachmentExtraction.extract(data: makePDF(text: "Synthetic PDF attachment"), extension: "pdf")
        #expect(text.method == "pdf")
        #expect(text.text.contains("Synthetic PDF attachment"))
        #expect(throws: (any Error).self) { _ = try AttachmentExtraction.extract(data: makePDF(text: nil), extension: "pdf") }
    }

    @Test func nativeOCRIsExplicitlyTextOnly() throws {
        let extracted = try AttachmentExtraction.extract(data: makeImage(), extension: "png")
        #expect(extracted.method == "ocr")
        #expect(extracted.label.contains("text only"))
        #expect(extracted.text.uppercased().contains("SIDEPAD"))
    }

    private func makePDF(text: String?) throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        if let text { draw(text, context: context, size: 20, position: CGPoint(x: 50, y: 700)) }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private func makeImage() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 1_000, height: 200, bitsPerComponent: 8, bytesPerRow: 4_000,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1_000, height: 200))
        draw("SIDEPAD TEST 123", context: context, size: 52, position: CGPoint(x: 40, y: 85))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func draw(_ text: String, context: CGContext, size: CGFloat, position: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        context.textPosition = position
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
    }
}
