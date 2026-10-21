import AppKit
import Dispatch
import Foundation
import UniformTypeIdentifiers
import Vision

@MainActor
public final class ClipboardCaptureService {
    typealias PayloadBuilder = @Sendable (PasteboardSnapshot) async -> ClipPayload?
    public typealias ImageFallbackBuilder = @Sendable () async -> ClipPayload?
    private static let maximumFallbackImageBytes = 8 * 1024 * 1024

    public var onClipCaptured: (@MainActor (ClipPayload, String?, Date) -> Void)?
    public var onFilesCaptured: (@MainActor ([URL], String?, Date, ImageFallbackBuilder?) -> Void)?
    public var onFileCaptureError: (@MainActor (String) -> Void)?
    public private(set) var isRunning = false

    private let pasteboard: NSPasteboard
    private let payloadBuilder: PayloadBuilder
    private var timer: Timer?
    private var lastChangeCount: Int
    private var lifecycleGeneration: UInt = 0
    private var deferredRead: DeferredPasteboardRead?
    // Vision performs synchronous work and can wait for system services. Keep it
    // off Swift's cooperative executor so it cannot starve unrelated captures.
    nonisolated private static let payloadQueue = DispatchQueue(
        label: "com.andrzej.ClipVault.clipboard-payload",
        qos: .utility,
        attributes: .concurrent
    )
    nonisolated private static let imageTextRecognition = BoundedTextRecognition()

    public convenience init(pasteboard: NSPasteboard = .general) {
        self.init(pasteboard: pasteboard) { snapshot in
            await withCheckedContinuation { continuation in
                Self.payloadQueue.async {
                    continuation.resume(returning: Self.payload(from: snapshot))
                }
            }
        }
    }

    init(pasteboard: NSPasteboard, payloadBuilder: @escaping PayloadBuilder) {
        self.pasteboard = pasteboard
        self.payloadBuilder = payloadBuilder
        self.lastChangeCount = pasteboard.changeCount
    }

    public func start(interval: TimeInterval = 0.25) {
        guard !isRunning else {
            return
        }

        lastChangeCount = pasteboard.changeCount
        lifecycleGeneration &+= 1
        deferredRead = nil
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        lifecycleGeneration &+= 1
        deferredRead = nil
    }

    public func consumeCurrentPasteboardChange() {
        lastChangeCount = pasteboard.changeCount
        deferredRead = nil
    }

    public func poll(now: Date = Date()) {
        guard isRunning else { return }
        let changeCount = pasteboard.changeCount
        let ownershipChanged = changeCount != lastChangeCount
        guard ownershipChanged || deferredRead?.isDue(changeCount: changeCount, now: now) == true else {
            return
        }

        if ownershipChanged { deferredRead = nil }
        lastChangeCount = changeCount
        guard !Self.hasPrivateMarker(pasteboard) else { deferredRead = nil; return }
        let snapshot = Self.snapshot(from: pasteboard)
        guard pasteboard.changeCount == changeCount else {
            deferredRead = nil
            return
        }
        if let error = snapshot.fileSelectionError {
            deferredRead = nil
            onFileCaptureError?(error)
            return
        }
        if !snapshot.hasReadableContent {
            // Ownership can change before a promised/remote representation is fulfilled.
            // A clear may also precede type declaration under the same ownership.
            if snapshot.hasSupportedRepresentation || snapshot.uniformTypeIdentifiers.isEmpty {
                deferredRead = DeferredPasteboardRead(
                    changeCount: changeCount,
                    attempt: (deferredRead?.attempt ?? -1) + 1,
                    now: now
                )
            } else {
                deferredRead = nil
            }
            return
        }
        deferredRead = nil
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        if let onFilesCaptured, !snapshot.fileURLs.isEmpty {
            // Preserve URLs supplied by AppKit: rebuilding a URL from its path
            // would discard any security-scope information attached to it.
            let imageFallback: ImageFallbackBuilder?
            if snapshot.fileURLs.count == 1, snapshot.hasFallbackImage {
                imageFallback = { [snapshot, payloadBuilder] in
                    var imageSnapshot = snapshot
                    imageSnapshot.fileURLs = []
                    imageSnapshot.filePaths = []
                    guard let payload = await payloadBuilder(imageSnapshot), payload.kind == .image else { return nil }
                    return payload
                }
            } else {
                imageFallback = nil
            }
            onFilesCaptured(snapshot.fileURLs, sourceApp, now, imageFallback)
            return
        }
        let generation = lifecycleGeneration
        let payloadBuilder = payloadBuilder
        Task { @MainActor [weak self, snapshot, sourceApp] in
            let payload = await payloadBuilder(snapshot)

            guard let self,
                  self.isRunning,
                  self.lifecycleGeneration == generation else {
                return
            }
            if let payload {
                // Completion order must not become a dependency between copies.
                // The store uses observation time to retain chronological history.
                self.onClipCaptured?(payload, sourceApp, now)
            }
        }
    }

    public static func payload(from pasteboard: NSPasteboard) -> ClipPayload? {
        guard !hasPrivateMarker(pasteboard) else { return nil }
        return payload(from: snapshot(from: pasteboard))
    }

    private static func hasPrivateMarker(_ pasteboard: NSPasteboard) -> Bool {
        let privateTypes = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "application/x-clipvault-copy"]
        return pasteboard.availableType(from: privateTypes.map { NSPasteboard.PasteboardType($0) }) != nil
    }

    private static func snapshot(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let types = pasteboard.types?.map(\.rawValue) ?? []
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue),
           let count = pasteboard.pasteboardItems?.count, count > 10 {
            // Reject the selection using item metadata before asking AppKit to
            // materialize every promised URL. Keep AppKit's security-scoped URL
            // reader for selections within the limit.
            return PasteboardSnapshot(uniformTypeIdentifiers: types, string: nil, urlString: nil,
                rtfData: nil, tiffData: nil, pngData: nil, objectImageData: nil,
                filePaths: [], fileSelectionError: "Choose up to 10 files at a time.")
        }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        // Keep one extra URL so the controller can report the ten-file limit
        // without building path metadata for an unbounded selection.
        let fileURLs = Array(urls.lazy.filter(\.isFileURL).prefix(11))
        if !fileURLs.isEmpty {
            // A file URL with a remote authority is not permission to read the
            // same path on this laptop. Never discard that authority into a path.
            guard fileURLs.allSatisfy({ $0.host == nil || $0.host == "" || $0.host == "localhost" }) else {
                return PasteboardSnapshot(uniformTypeIdentifiers: types, string: nil, urlString: nil,
                    rtfData: nil, tiffData: nil, pngData: nil, objectImageData: nil, filePaths: [])
            }
            let representations = fileURLs.count == 1 ? imageRepresentations(from: pasteboard) : nil
            return PasteboardSnapshot(
                uniformTypeIdentifiers: types,
                string: nil,
                urlString: nil,
                rtfData: nil,
                tiffData: representations?.tiff,
                pngData: representations?.png,
                jpegData: representations?.jpeg,
                objectImageData: nil,
                filePaths: fileURLs.map(\.path),
                fileURLs: fileURLs
            )
        }
        let objectImageData = (pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage)?.tiffRepresentation

        return PasteboardSnapshot(
            uniformTypeIdentifiers: types,
            string: pasteboard.string(forType: .string),
            urlString: pasteboard.string(forType: .URL),
            rtfData: pasteboard.data(forType: .rtf),
            tiffData: pasteboard.data(forType: .tiff),
            pngData: pasteboard.data(forType: NSPasteboard.PasteboardType("public.png")),
            jpegData: pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg")),
            objectImageData: objectImageData,
            filePaths: fileURLs.map(\.path)
        )
    }

    private static func imageRepresentations(from pasteboard: NSPasteboard) -> (tiff: Data?, png: Data?, jpeg: Data?)? {
        let candidates: [(NSPasteboard.PasteboardType, String)] = [
            (NSPasteboard.PasteboardType("public.jpeg"), "jpeg"),
            (NSPasteboard.PasteboardType("public.png"), "png"),
            (.tiff, "tiff")
        ]
        for (type, format) in candidates {
            guard let data = pasteboard.data(forType: type), !data.isEmpty,
                  data.count <= maximumFallbackImageBytes else { continue }
            switch format {
            case "jpeg": return (nil, nil, data)
            case "png": return (nil, data, nil)
            default: return (data, nil, nil)
            }
        }
        return nil
    }

    nonisolated static func payload(
        from snapshot: PasteboardSnapshot,
        textRecognition: BoundedTextRecognition = imageTextRecognition,
        recognizeText: @escaping @Sendable (Data) -> String? = { recognizeText(inImageData: $0) }
    ) -> ClipPayload? {
        if !snapshot.filePaths.isEmpty {
            let text = snapshot.filePaths.joined(separator: "\n")
            let encodedPaths = (try? JSONEncoder().encode(snapshot.filePaths)).flatMap { String(data: $0, encoding: .utf8) }
            return ClipPayload(
                kind: .file,
                displayText: text,
                extractedText: text,
                metadata: ["count": "\(snapshot.filePaths.count)", "paths": text, "captureFiles": encodedPaths ?? "[]"],
                uniformTypeIdentifiers: snapshot.uniformTypeIdentifiers
            )
        }

        if let imagePayload = imagePayload(from: snapshot, textRecognition: textRecognition, recognizeText: recognizeText) {
            return imagePayload
        }

        if let urlString = snapshot.urlString,
           let url = URL(string: urlString) {
            return ClipPayload(
                kind: .url,
                displayText: url.absoluteString,
                extractedText: url.absoluteString,
                metadata: ["host": url.host() ?? ""],
                uniformTypeIdentifiers: snapshot.uniformTypeIdentifiers
            )
        }

        if let rtfData = snapshot.rtfData,
           let attributed = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
            let text = attributed.string
            return ClipPayload(
                kind: .richText,
                displayText: text,
                extractedText: text,
                previewData: rtfData,
                uniformTypeIdentifiers: snapshot.uniformTypeIdentifiers
            )
        }

        if let string = snapshot.string {
            return textPayload(from: string, uniformTypeIdentifiers: snapshot.uniformTypeIdentifiers)
        }

        return nil
    }

    nonisolated private static func imagePayload(
        from snapshot: PasteboardSnapshot,
        textRecognition: BoundedTextRecognition,
        recognizeText: @escaping @Sendable (Data) -> String?
    ) -> ClipPayload? {
        let imageData: [(Data?, String)] = [
            (snapshot.tiffData, NSPasteboard.PasteboardType.tiff.rawValue),
            (snapshot.pngData, "public.png"),
            (snapshot.jpegData, "public.jpeg"),
            (snapshot.objectImageData, NSPasteboard.PasteboardType.tiff.rawValue)
        ]

        for (candidateData, rawType) in imageData {
            if let data = candidateData, NSImage(data: data) != nil {
                let recognized = textRecognition.recognize(data, operation: recognizeText)
                let ocr = recognized ?? ""
                let lineCount = ocr.split(whereSeparator: \.isNewline).count
                return ClipPayload(
                    kind: .image,
                    displayText: lineCount > 0 ? "Image • \(lineCount) OCR lines" : "Image",
                    extractedText: ocr,
                    metadata: ["previewType": rawType, "ocrLineCount": "\(lineCount)", "ocrStatus": recognized == nil ? "unavailable" : "complete"],
                    previewData: data,
                    uniformTypeIdentifiers: snapshot.uniformTypeIdentifiers
                )
            }
        }

        return nil
    }

    nonisolated private static func textPayload(from text: String, uniformTypeIdentifiers: [String]) -> ClipPayload {
        let kind = classifyText(text)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata: [String: String]
        if kind == .url, let url = URL(string: trimmed) {
            metadata = ["host": url.host() ?? ""]
        } else {
            metadata = [:]
        }
        return ClipPayload(
            kind: kind,
            displayText: text,
            extractedText: text,
            metadata: metadata,
            uniformTypeIdentifiers: uniformTypeIdentifiers
        )
    }

    nonisolated private static func classifyText(_ text: String) -> ClipKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if URL(string: trimmed)?.scheme?.hasPrefix("http") == true {
            return .url
        }

        if lower.contains("select ") || lower.contains(" from ") || lower.contains(" where ") {
            return .sql
        }

        if lower.contains("error:") || lower.contains("exception") || lower.contains("traceback") {
            return .error
        }

        if trimmed.contains("{") && trimmed.contains("}")
            || trimmed.contains("func ")
            || trimmed.contains("class ")
            || trimmed.contains("import ")
            || trimmed.contains("let ")
            || trimmed.contains("var ") {
            return .code
        }

        return .text
    }

    nonisolated private static func recognizeText(inImageData data: Data) -> String? {
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.01
        request.recognitionLanguages = ["en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage)
        do {
            try handler.perform([request])
            return request.results?
                .compactMap { observation in
                    let candidate = observation.topCandidates(1).first
                    guard let candidate, candidate.confidence >= 0.45 else {
                        return nil
                    }
                    return candidate.string
                }
                .joined(separator: "\n") ?? ""
        } catch {
            return nil
        }
    }
}

private struct DeferredPasteboardRead {
    let changeCount: Int
    let attempt: Int
    let nextAttemptAt: Date

    init(changeCount: Int, attempt: Int, now: Date) {
        self.changeCount = changeCount
        self.attempt = min(attempt, 3)
        nextAttemptAt = now.addingTimeInterval(0.25 * pow(2, Double(self.attempt)))
    }

    func isDue(changeCount: Int, now: Date) -> Bool {
        self.changeCount == changeCount && now >= nextAttemptAt
    }
}

struct PasteboardSnapshot: Sendable {
    var uniformTypeIdentifiers: [String]
    var string: String?
    var urlString: String?
    var rtfData: Data?
    var tiffData: Data?
    var pngData: Data?
    var jpegData: Data? = nil
    var objectImageData: Data?
    var filePaths: [String]
    var fileURLs: [URL] = []
    var fileSelectionError: String? = nil

    var hasReadableContent: Bool {
        string?.isEmpty == false || urlString?.isEmpty == false || !filePaths.isEmpty
            || [rtfData, tiffData, pngData, jpegData, objectImageData].contains { $0?.isEmpty == false }
    }

    var hasFallbackImage: Bool {
        [tiffData, pngData, jpegData, objectImageData].contains { $0?.isEmpty == false }
    }

    var hasSupportedRepresentation: Bool {
        uniformTypeIdentifiers.contains { rawType in
            guard let type = UTType(rawType) else { return false }
            return type.conforms(to: .plainText) || type.conforms(to: .rtf)
                || type.conforms(to: .url) || type.conforms(to: .image)
        }
    }
}
