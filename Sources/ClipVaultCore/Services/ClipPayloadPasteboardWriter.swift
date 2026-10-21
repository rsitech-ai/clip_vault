import AppKit
import Foundation

public enum PasteboardWriterError: Error, LocalizedError {
    case missingImageData, attachmentRequiresSave

    public var errorDescription: String? {
        switch self {
        case .missingImageData:
            "This image clip does not have valid image data to copy."
        case .attachmentRequiresSave:
            "Save this attachment to a file before copying it in Finder."
        }
    }
}

@MainActor
public final class ClipPayloadPasteboardWriter {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func write(_ payload: ClipPayload) throws {
        if payload.kind == .file, payload.metadata["file_id"] != nil {
            throw PasteboardWriterError.attachmentRequiresSave
        }
        if payload.kind == .image {
            try writeImage(payload)
            return
        }

        pasteboard.clearContents()

        switch payload.kind {
        case .image:
            preconditionFailure("Image payloads are handled before clearing the pasteboard")
        case .file:
            if let urls = fileURLs(from: payload), !urls.isEmpty {
                pasteboard.writeObjects(urls as [NSURL])
            } else {
                pasteboard.setString(payload.displayText, forType: .string)
            }
        case .url:
            pasteboard.setString(payload.displayText, forType: .string)
            pasteboard.setString(payload.displayText, forType: .URL)
        case .richText:
            if let data = payload.previewData {
                pasteboard.setData(data, forType: .rtf)
            }
            pasteboard.setString(payload.displayText, forType: .string)
        case .text, .code, .sql, .error, .unknown:
            pasteboard.setString(payload.displayText, forType: .string)
        }
    }

    public func writePrivateText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
    }

    private func writeImage(_ payload: ClipPayload) throws {
        guard let data = payload.previewData, let image = NSImage(data: data) else {
            throw PasteboardWriterError.missingImageData
        }

        pasteboard.clearContents()
        pasteboard.writeObjects([image])

        let preferredType = payload.metadata["previewType"].map(NSPasteboard.PasteboardType.init(_:))
        if let preferredType {
            pasteboard.setData(data, forType: preferredType)
        } else if let tiff = image.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    private func fileURLs(from payload: ClipPayload) -> [URL]? {
        if let paths = payload.metadata["paths"] {
            return paths
                .split(separator: "\n")
                .map(String.init)
                .map(URL.init(fileURLWithPath:))
        }

        let textPaths = payload.displayText
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !textPaths.isEmpty else {
            return nil
        }
        return textPaths.map(URL.init(fileURLWithPath:))
    }
}
