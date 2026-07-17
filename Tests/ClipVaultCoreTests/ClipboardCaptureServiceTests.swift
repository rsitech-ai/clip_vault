import AppKit
import Testing
@testable import ClipVaultCore

@Suite("Clipboard capture service")
struct ClipboardCaptureServiceTests {
    @MainActor
    @Test("default monitoring captures full copied text promptly")
    func defaultMonitoringCapturesExactTextPromptly() async throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ClipVaultDefaultMonitoringTest-\(UUID().uuidString)")
        )
        let service = ClipboardCaptureService(pasteboard: pasteboard)
        let expected = """
        First line copied from an external Copy button.
        Second line preserves emoji 🧪 and non-ASCII text: zażółć gęślą jaźń.
        Third line must not be truncated when the payload is captured.
        """
        var capturedPayload: ClipPayload?
        service.onClipCaptured = { payload, _ in
            capturedPayload = payload
        }
        service.start()
        defer { service.stop() }

        pasteboard.clearContents()
        pasteboard.setString(expected, forType: .string)
        for _ in 0..<13 where capturedPayload == nil {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(capturedPayload?.displayText == expected)
        #expect(capturedPayload?.extractedText == expected)
    }

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
    @Test("captures are delivered in clipboard change order when payload work completes out of order")
    func deliversCapturesInClipboardOrder() async throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ClipVaultCaptureOrderingTest-\(UUID().uuidString)")
        )
        let gate = OrderedPayloadBuilderGate()
        let service = ClipboardCaptureService(pasteboard: pasteboard) { snapshot in
            await gate.build(snapshot)
        }
        var capturedTexts: [String] = []
        service.onClipCaptured = { payload, _ in
            capturedTexts.append(payload.displayText)
        }
        service.start(interval: 60)
        defer { service.stop() }

        pasteboard.clearContents()
        pasteboard.setString("first", forType: .string)
        service.poll()
        await gate.waitUntilStarted("first")

        pasteboard.clearContents()
        pasteboard.setString("second", forType: .string)
        service.poll()
        await gate.waitUntilStarted("second")

        await gate.finish("second")
        await Task.yield()
        await gate.finish("first")
        for _ in 0..<20 where capturedTexts.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(capturedTexts == ["first", "second"])
    }

    @MainActor
    @Test("an ignored payload does not block a later valid capture")
    func ignoredPayloadDoesNotBlockLaterCapture() async throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ClipVaultIgnoredCaptureOrderingTest-\(UUID().uuidString)")
        )
        let gate = OrderedPayloadBuilderGate()
        let service = ClipboardCaptureService(pasteboard: pasteboard) { snapshot in
            await gate.build(snapshot)
        }
        var capturedTexts: [String] = []
        service.onClipCaptured = { payload, _ in
            capturedTexts.append(payload.displayText)
        }
        service.start(interval: 60)
        defer { service.stop() }

        pasteboard.clearContents()
        pasteboard.setString("ignored", forType: .string)
        service.poll()
        await gate.waitUntilStarted("ignored")

        pasteboard.clearContents()
        pasteboard.setString("kept", forType: .string)
        service.poll()
        await gate.waitUntilStarted("kept")

        await gate.finish("kept")
        await Task.yield()
        #expect(capturedTexts.isEmpty)

        await gate.finishWithoutPayload("ignored")
        for _ in 0..<20 where capturedTexts.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(capturedTexts == ["kept"])
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

private actor OrderedPayloadBuilderGate {
    private var started: Set<String> = []
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var buildContinuations: [String: CheckedContinuation<ClipPayload?, Never>] = [:]

    func build(_ snapshot: PasteboardSnapshot) async -> ClipPayload? {
        let text = snapshot.string ?? ""
        started.insert(text)
        for waiter in startWaiters.removeValue(forKey: text) ?? [] {
            waiter.resume()
        }
        return await withCheckedContinuation { continuation in
            buildContinuations[text] = continuation
        }
    }

    func waitUntilStarted(_ text: String) async {
        guard !started.contains(text) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[text, default: []].append(continuation)
        }
    }

    func finish(_ text: String) {
        buildContinuations.removeValue(forKey: text)?.resume(
            returning: ClipPayload(kind: .text, displayText: text, extractedText: text)
        )
    }

    func finishWithoutPayload(_ text: String) {
        buildContinuations.removeValue(forKey: text)?.resume(returning: nil)
    }
}
