import AppKit
import Testing
@testable import ClipVaultCore

@Suite("Pasteboard writer")
struct PasteboardWriterTests {
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
}
