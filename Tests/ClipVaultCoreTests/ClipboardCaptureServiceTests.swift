import AppKit
import Testing
@testable import ClipVaultCore

@Suite("Clipboard capture service")
struct ClipboardCaptureServiceTests {
    @MainActor
    @Test("parses URL strings as URL payloads")
    func parsesURLStrings() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipVaultURLCaptureTest"))
        pasteboard.clearContents()
        pasteboard.setString("https://rsitech.ai/clipvault", forType: .string)

        let payload = try #require(ClipboardCaptureService.payload(from: pasteboard))
        #expect(payload.kind == .url)
        #expect(payload.metadata["host"] == "rsitech.ai")
    }

    @MainActor
    @Test("parses rich text payloads")
    func parsesRichText() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipVaultRTFCaptureTest"))
        pasteboard.clearContents()
        let attributed = NSAttributedString(string: "formatted clipboard note")
        let data = try #require(attributed.rtf(from: NSRange(location: 0, length: attributed.length)))
        pasteboard.setData(data, forType: .rtf)

        let payload = try #require(ClipboardCaptureService.payload(from: pasteboard))
        #expect(payload.kind == .richText)
        #expect(payload.extractedText == "formatted clipboard note")
        #expect(payload.previewData == data)
    }

    @MainActor
    @Test("parses file URLs with reversible path metadata")
    func parsesFileURLs() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipVaultFileCaptureTest"))
        pasteboard.clearContents()
        let first = URL(fileURLWithPath: "/tmp/clipvault-a.txt")
        let second = URL(fileURLWithPath: "/tmp/clipvault-b.txt")
        pasteboard.writeObjects([first as NSURL, second as NSURL])

        let payload = try #require(ClipboardCaptureService.payload(from: pasteboard))
        #expect(payload.kind == .file)
        #expect(payload.metadata["count"] == "2")
        #expect(payload.metadata["paths"] == "/tmp/clipvault-a.txt\n/tmp/clipvault-b.txt")
    }
}
