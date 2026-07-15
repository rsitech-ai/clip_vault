import AppKit
import Foundation
import UniformTypeIdentifiers
import Vision

@MainActor
public final class ClipboardCaptureService {
    typealias PayloadBuilder = @Sendable (PasteboardSnapshot) async -> ClipPayload?

    public var onClipCaptured: (@MainActor (ClipPayload, String?) -> Void)?
    public private(set) var isRunning = false

    private let pasteboard: NSPasteboard
    private let payloadBuilder: PayloadBuilder
    private var timer: Timer?
    private var lastChangeCount: Int
    private var lifecycleGeneration: UInt = 0

    public convenience init(pasteboard: NSPasteboard = .general) {
        self.init(pasteboard: pasteboard) { snapshot in
            await Task.detached(priority: .utility) {
                Self.payload(from: snapshot)
            }.value
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
    }

    public func consumeCurrentPasteboardChange() {
        lastChangeCount = pasteboard.changeCount
    }

    public func poll() {
        guard isRunning, pasteboard.changeCount != lastChangeCount else {
            return
        }

        lastChangeCount = pasteboard.changeCount
        let snapshot = Self.snapshot(from: pasteboard)
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        let generation = lifecycleGeneration
        let payloadBuilder = payloadBuilder
        Task { @MainActor [weak self, snapshot, sourceApp] in
            let payload = await payloadBuilder(snapshot)

            guard let self,
                  self.isRunning,
                  self.lifecycleGeneration == generation,
                  let payload else {
                return
            }
            self.onClipCaptured?(payload, sourceApp)
        }
    }

    public static func payload(from pasteboard: NSPasteboard) -> ClipPayload? {
        payload(from: snapshot(from: pasteboard))
    }

    private static func snapshot(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let types = pasteboard.types?.map(\.rawValue) ?? []
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        let objectImageData = (pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage)?.tiffRepresentation

        return PasteboardSnapshot(
            uniformTypeIdentifiers: types,
            string: pasteboard.string(forType: .string),
            urlString: pasteboard.string(forType: .URL),
            rtfData: pasteboard.data(forType: .rtf),
            tiffData: pasteboard.data(forType: .tiff),
            pngData: pasteboard.data(forType: NSPasteboard.PasteboardType("public.png")),
            objectImageData: objectImageData,
            filePaths: fileURLs.map(\.path)
        )
    }

    nonisolated private static func payload(from snapshot: PasteboardSnapshot) -> ClipPayload? {
        if let imagePayload = imagePayload(from: snapshot) {
            return imagePayload
        }

        if !snapshot.filePaths.isEmpty {
            let text = snapshot.filePaths.joined(separator: "\n")
            return ClipPayload(
                kind: .file,
                displayText: text,
                extractedText: text,
                metadata: ["count": "\(snapshot.filePaths.count)", "paths": text],
                uniformTypeIdentifiers: snapshot.uniformTypeIdentifiers
            )
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

    nonisolated private static func imagePayload(from snapshot: PasteboardSnapshot) -> ClipPayload? {
        let imageData: [(Data?, String)] = [
            (snapshot.tiffData, NSPasteboard.PasteboardType.tiff.rawValue),
            (snapshot.pngData, "public.png"),
            (snapshot.objectImageData, NSPasteboard.PasteboardType.tiff.rawValue)
        ]

        for (candidateData, rawType) in imageData {
            if let data = candidateData, NSImage(data: data) != nil {
                let ocr = recognizeText(inImageData: data)
                let lineCount = ocr.split(whereSeparator: \.isNewline).count
                return ClipPayload(
                    kind: .image,
                    displayText: lineCount > 0 ? "Image • \(lineCount) OCR lines" : "Image",
                    extractedText: ocr,
                    metadata: ["previewType": rawType, "ocrLineCount": "\(lineCount)"],
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

    nonisolated private static func recognizeText(inImageData data: Data) -> String {
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return ""
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
            return ""
        }
    }
}

struct PasteboardSnapshot: Sendable {
    var uniformTypeIdentifiers: [String]
    var string: String?
    var urlString: String?
    var rtfData: Data?
    var tiffData: Data?
    var pngData: Data?
    var objectImageData: Data?
    var filePaths: [String]
}
