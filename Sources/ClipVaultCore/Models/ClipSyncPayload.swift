import AppKit
import Foundation

public enum ClipSyncError: Error, LocalizedError {
    case invalidPayload, unsupportedFile, tooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidPayload: "The shared clip has invalid or unsupported content."
        case .unsupportedFile: "File references stay on this device."
        case .tooLarge: "This clip exceeds the 10 MiB sharing limit."
        }
    }
}
public struct ClipSyncPortable: Codable, Sendable, Equatable {
    public var kind: String
    public var text: String
    public var displayText: String
    public var capturedAt: Int64
    public var sourceApp: String?
    public var sourceDevice: String?
    public var imagePNG: String?
    public var metadata: [String: String]
    public init(kind: String, text: String, displayText: String, capturedAt: Int64, sourceApp: String?, sourceDevice: String?, imagePNG: String?, metadata: [String: String]) {
        self.kind = kind; self.text = text; self.displayText = displayText
        self.capturedAt = capturedAt; self.sourceApp = sourceApp; self.sourceDevice = sourceDevice
        self.imagePNG = imagePNG; self.metadata = metadata
    }
    enum CodingKeys: String, CodingKey {
        case kind, text, metadata
        case displayText = "display_text", capturedAt = "captured_at"
        case sourceApp = "source_app", sourceDevice = "source_device", imagePNG = "image_png"
    }
    public init(payload: ClipPayload, sourceApp: String?, capturedAt: Date) throws {
        guard payload.kind != .file else { throw ClipSyncError.unsupportedFile }
        var image: String?
        if payload.kind == .image {
            guard let data = payload.previewData, data.count <= 10 * 1024 * 1024,
                  let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
                  bitmap.pixelsWide <= 16384, bitmap.pixelsHigh <= 16384,
                  bitmap.pixelsWide * bitmap.pixelsHigh <= 40_000_000,
                  let png = bitmap.representation(using: .png, properties: [:]) else { throw ClipSyncError.invalidPayload }
            image = png.base64EncodedString()
        }
        var portableMetadata = payload.metadata.filter { ["host", "language", "ocrLineCount"].contains($0.key) }
        if payload.kind == .richText, let rtf = payload.previewData { portableMetadata["rtf"] = rtf.base64EncodedString() }
        self.init(kind: payload.kind.rawValue,
                  text: payload.extractedText.isEmpty && payload.kind != .image ? payload.displayText : payload.extractedText,
                  displayText: payload.displayText, capturedAt: Int64(capturedAt.timeIntervalSince1970),
                  sourceApp: sourceApp, sourceDevice: nil, imagePNG: image, metadata: portableMetadata)
        _ = try payloadValue()
    }
    public func payloadValue() throws -> ClipPayload {
        guard let clipKind = ClipKind(rawValue: kind), clipKind != .file, capturedAt >= 0,
              metadata.count <= 32, (sourceApp?.utf8.count ?? 0) <= 256,
              (sourceDevice?.utf8.count ?? 0) <= 256 else { throw ClipSyncError.invalidPayload }
        // JSON escaping can expand otherwise small text past the FFI/wire cap.
        // Reserve space for the enclosing command and event headers.
        guard try JSONEncoder().encode(self).count <= 20 * 1024 * 1024 - 8192 else { throw ClipSyncError.tooLarge }
        guard (imagePNG?.utf8.count ?? 0) <= 20 * 1024 * 1024 else { throw ClipSyncError.tooLarge }
        let decoded = imagePNG.flatMap { Data(base64Encoded: $0) }
        let size = text.utf8.count + displayText.utf8.count + (decoded?.count ?? 0)
            + metadata.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
            + (sourceApp?.utf8.count ?? 0) + (sourceDevice?.utf8.count ?? 0)
        guard size <= 10 * 1024 * 1024 else { throw ClipSyncError.tooLarge }
        guard !SensitiveRuleEngine.default.classify(text).isExcluded,
              !SensitiveRuleEngine.default.classify(displayText).isExcluded,
              !metadata.values.contains(where: { SensitiveRuleEngine.default.classify($0).isExcluded }) else { throw ClipSyncError.invalidPayload }
        var resultMetadata = metadata
        if let sourceDevice { resultMetadata["syncSourceDevice"] = sourceDevice }
        if clipKind == .image {
            guard let decoded, decoded.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), decoded.count >= 24 else { throw ClipSyncError.invalidPayload }
            let width = decoded[16..<20].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let height = decoded[20..<24].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 40_000_000,
                  NSBitmapImageRep(data: decoded) != nil else { throw ClipSyncError.invalidPayload }
            resultMetadata["previewType"] = "public.png"
        } else if imagePNG != nil { throw ClipSyncError.invalidPayload }
        var representation = decoded
        if clipKind == .richText {
            guard let encodedRTF = metadata["rtf"], let rtf = Data(base64Encoded: encodedRTF),
                  rtf.starts(with: Array("{\\rtf".utf8)),
                  !SensitiveRuleEngine.default.classify(String(decoding: rtf, as: UTF8.self)).isExcluded else { throw ClipSyncError.invalidPayload }
            representation = rtf
        }
        return ClipPayload(kind: clipKind, displayText: displayText,
                           extractedText: text, metadata: resultMetadata, previewData: representation,
                           uniformTypeIdentifiers: clipKind == .image ? ["public.png"] : ["public.utf8-plain-text"])
    }
}
public struct ClipSyncEvent: Codable, Sendable, Equatable {
    public var id: String
    public var origin: String
    public var sequence: UInt64
    public var clip: ClipSyncPortable
    public init(id: String, origin: String, sequence: UInt64, clip: ClipSyncPortable) {
        self.id = id; self.origin = origin; self.sequence = sequence; self.clip = clip
    }
}
