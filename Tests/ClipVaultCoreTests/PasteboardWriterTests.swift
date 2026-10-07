import AppKit
import Testing
@testable import ClipVaultCore

@Suite("Pasteboard writer")
struct PasteboardWriterTests {
    @MainActor
    @Test("copy emits standard formats without replaying remote origin or privacy markers")
    func copyDoesNotReplayOriginMarkers() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let writer = ClipPayloadPasteboardWriter(pasteboard: pasteboard)
        let remoteType = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")
        let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.clearContents()
        pasteboard.setData(Data([1]), forType: remoteType)
        pasteboard.setData(Data([1]), forType: concealedType)
        let attributed = NSAttributedString(string: "Device-neutral rich text 📋")
        let data = try #require(attributed.rtf(from: NSRange(location: 0, length: attributed.length)))
        try writer.write(ClipPayload(
            kind: .richText,
            displayText: attributed.string,
            extractedText: attributed.string,
            previewData: data,
            uniformTypeIdentifiers: [remoteType.rawValue, concealedType.rawValue, NSPasteboard.PasteboardType.rtf.rawValue]
        ))

        #expect(pasteboard.string(forType: .string) == attributed.string)
        #expect(pasteboard.data(forType: .rtf) == data)
        #expect(pasteboard.data(forType: remoteType) == nil)
        #expect(pasteboard.data(forType: concealedType) == nil)
    }

    @MainActor
    @Test("writes text payloads back as strings")
    func writesText() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipVaultTextWriterTest"))
        let writer = ClipPayloadPasteboardWriter(pasteboard: pasteboard)
        let fullText = """
        let answer = 42
        // Preserve every line, emoji 📋, and non-ASCII text: zażółć gęślą jaźń.
        // This content is intentionally longer than a list preview.
        """

        try writer.write(
            ClipPayload(kind: .code, displayText: fullText, extractedText: fullText)
        )

        #expect(pasteboard.string(forType: .string) == fullText)
    }

    @MainActor
    @Test("writes image payloads back as image data")
    func writesImages() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipVaultImageWriterTest"))
        let writer = ClipPayloadPasteboardWriter(pasteboard: pasteboard)
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 8, height: 8)).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)

        try writer.write(
            ClipPayload(
                kind: .image,
                displayText: "Image",
                extractedText: "blue square",
                metadata: ["previewType": NSPasteboard.PasteboardType.tiff.rawValue],
                previewData: tiff
            )
        )

        #expect(pasteboard.data(forType: .tiff) != nil)
    }

    @MainActor
    @Test("failed image writes preserve the existing clipboard contents")
    func failedImageWritesPreserveExistingContents() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ClipVaultFailedImageWriterTest-\(UUID().uuidString)")
        )
        let writer = ClipPayloadPasteboardWriter(pasteboard: pasteboard)
        let existingText = "keep this clipboard value"
        pasteboard.clearContents()
        pasteboard.setString(existingText, forType: .string)

        #expect(throws: PasteboardWriterError.self) {
            try writer.write(
                ClipPayload(kind: .image, displayText: "Image", extractedText: "Image")
            )
        }

        #expect(pasteboard.string(forType: .string) == existingText)
    }

    @MainActor
    @Test("malformed image writes preserve the existing clipboard contents")
    func malformedImageWritesPreserveExistingContents() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ClipVaultMalformedImageWriterTest-\(UUID().uuidString)")
        )
        let writer = ClipPayloadPasteboardWriter(pasteboard: pasteboard)
        let existingText = "keep this clipboard value"
        pasteboard.clearContents()
        pasteboard.setString(existingText, forType: .string)

        #expect(throws: PasteboardWriterError.self) {
            try writer.write(
                ClipPayload(
                    kind: .image,
                    displayText: "Image",
                    extractedText: "Image",
                    metadata: ["previewType": NSPasteboard.PasteboardType.tiff.rawValue],
                    previewData: Data("not an image".utf8)
                )
            )
        }

        #expect(pasteboard.string(forType: .string) == existingText)
    }
}
