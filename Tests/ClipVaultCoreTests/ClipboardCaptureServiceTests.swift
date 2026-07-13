import AppKit
import Testing
@testable import ClipVaultCore

@Suite("Clipboard capture service")
struct ClipboardCaptureServiceTests {
    @MainActor
    @Test("starting capture ignores clipboard content copied while capture was stopped")
    func startRebaselinesPasteboard() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipVaultStartBaselineTest"))
        let service = ClipboardCaptureService(pasteboard: pasteboard)
        var capturedPayloads: [ClipPayload] = []
        service.onClipCaptured = { payload, _ in
            capturedPayloads.append(payload)
        }

        pasteboard.clearContents()
        pasteboard.setString("copied before consent", forType: .string)
        service.start(interval: 60)
        service.poll()
        try await Task.sleep(for: .milliseconds(100))
        service.stop()

        #expect(capturedPayloads.isEmpty)
    }

    @MainActor
    @Test("stopping and restarting capture invalidates payload work already in flight")
    func stopInvalidatesInFlightPayload() async {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipVaultStopInvalidationTest"))
        let gate = PayloadBuilderGate()
        let service = ClipboardCaptureService(pasteboard: pasteboard) { _ in
            await gate.build()
        }
        var capturedPayloads: [ClipPayload] = []
        service.onClipCaptured = { payload, _ in
            capturedPayloads.append(payload)
        }
        service.start(interval: 60)
        pasteboard.clearContents()
        pasteboard.setString("copied while running", forType: .string)

        service.poll()
        await gate.waitUntilStarted()
        service.stop()
        service.start(interval: 60)
        await gate.finish(
            with: ClipPayload(kind: .text, displayText: "late", extractedText: "late")
        )
        await Task.yield()
        service.stop()

        #expect(capturedPayloads.isEmpty)
    }

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

private actor PayloadBuilderGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var buildContinuation: CheckedContinuation<ClipPayload?, Never>?

    func build() async -> ClipPayload? {
        started = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
        return await withCheckedContinuation { continuation in
            buildContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish(with payload: ClipPayload?) {
        buildContinuation?.resume(returning: payload)
        buildContinuation = nil
    }
}
