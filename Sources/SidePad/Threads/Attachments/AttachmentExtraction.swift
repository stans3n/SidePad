import Foundation
import PDFKit
import Vision
import ImageIO
import UniformTypeIdentifiers

struct CaptureAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let typeLabel: String
    let byteCount: Int
    let extractionLabel: String
    let warning: String?
}

/// This is transient, redacted data. Paths, raw bytes, and extraction text are never persisted in the manifest.
struct AttachmentContext: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let kind: String
    let extraction: String
    let text: String
    let truncated: Bool
    var notice: String { extraction == "ocr" ? "Local OCR text only; no image layout or visual understanding." : "Untrusted extracted file text." }
}

enum AttachmentError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

enum AttachmentExtraction {
    static let extensions: Set<String> = ["txt", "md", "log", "json", "csv", "pdf", "png", "jpg", "jpeg", "heic"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic"]
    static let maximumFileBytes = 10 * 1_024 * 1_024
    static let maximumTotalBytes = 25 * 1_024 * 1_024
    static let maximumAttachments = 5
    static let maximumTextCharacters = 6_000
    static let maximumContextCharacters = 12_000
    static let maximumContextBytes = 20_000
    static var allowedContentTypes: [UTType] { extensions.sorted().compactMap { UTType(filenameExtension: $0) } }

    struct Result: Sendable {
        let text: String
        let method: String
        let truncated: Bool
        var label: String { method == "ocr" ? "Image OCR · text only" : method == "pdf" ? "PDF text" : "Text" }
    }

    static func extract(data: Data, extension ext: String) throws -> Result {
        let text: String
        let method: String
        var limited = false
        if ext == "pdf" {
            guard let document = PDFDocument(data: data), !document.isLocked else {
                throw AttachmentError.invalid("This PDF is unreadable or password protected.")
            }
            var parts: [String] = []
            var count = 0
            let pageLimit = min(document.pageCount, 50)
            for index in 0..<pageLimit {
                let page = document.page(at: index)?.string ?? ""
                parts.append(String(page.prefix(32_000)))
                count += page.count
                if count >= 32_000 { limited = true; break }
            }
            limited = limited || document.pageCount > pageLimit
            text = parts.joined(separator: "\n\n")
            method = "pdf"
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AttachmentError.invalid("This PDF has no extractable text. Scanned PDF OCR is not supported; attach a text file or screenshot instead.")
            }
        } else if imageExtensions.contains(ext) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4_096
                  ] as CFDictionary) else {
                throw AttachmentError.invalid("This image could not be read.")
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            method = "ocr"
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AttachmentError.invalid("No readable text was found in this image. Current capture supports local OCR text only, not full image understanding.")
            }
        } else {
            guard !data.isEmpty else { throw AttachmentError.invalid("This text file is empty.") }
            if let utf8 = String(data: data, encoding: .utf8) { text = utf8 }
            else if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]),
                    let utf16 = String(data: data, encoding: .utf16) { text = utf16 }
            else { throw AttachmentError.invalid("This file is not readable UTF-8 or UTF-16 text.") }
            guard !text.contains("\0") else { throw AttachmentError.invalid("This file appears to contain binary data.") }
            method = "text"
        }
        // Redact before the final context truncation so a clipped credential cannot leak through.
        let bounded = String(text.prefix(128_000))
        let redacted = redactSecrets(bounded)
        let output = String(redacted.prefix(maximumTextCharacters))
        return Result(text: output, method: method,
                      truncated: limited || text.count > 128_000 || redacted.count > maximumTextCharacters)
    }

    static func boundedText(_ text: String, characters: Int, bytes: Int) -> String {
        var output = ""
        var remaining = bytes
        for character in text.prefix(max(0, characters)) {
            let value = String(character)
            guard value.utf8.count <= remaining else { break }
            output.append(character)
            remaining -= value.utf8.count
        }
        return output
    }

    static func redactSecrets(_ text: String) -> String {
        let patterns = [
            #"(?is)-----BEGIN (?:[A-Z ]*PRIVATE KEY)-----.*?(?:-----END (?:[A-Z ]*PRIVATE KEY)-----|$)"#,
            #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#,
            #"(?i)\b(?:sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]{12,}|AKIA[A-Z0-9]{16})\b"#,
            #"(?im)([\"']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|client[_-]?secret|password|passwd|secret|token)[\"']?\s*[:=]\s*)(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\s,;\"'}]+)"#,
            #"(?i)(https?://)[^\s/@:]+:[^\s/@]+@"#
        ]
        var result = text
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let replacement = index == 3 ? "$1[REDACTED]" : index == 4 ? "$1[REDACTED]@" : "[REDACTED]"
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
        }
        return result
    }
}
