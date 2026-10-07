import AppKit
import Testing
@testable import ClipVaultCore

@Suite("Clipboard capture service")
struct ClipboardCaptureServiceTests {
    @MainActor
    @Test("a stalled payload cannot prevent a later completed capture from being saved")
    func stalledPayloadDoesNotBlockLaterCapture() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let gate = OrderedPayloadBuilderGate()
        let service = ClipboardCaptureService(pasteboard: pasteboard) { snapshot in
            await gate.build(snapshot)
        }
        var capturedTexts: [String] = []
        service.onClipCaptured = { payload, _, _ in capturedTexts.append(payload.displayText) }
        service.start(interval: 60)
        defer { service.stop() }

        pasteboard.clearContents()
        pasteboard.setString("stalled OCR", forType: .string)
        service.poll()
        await gate.waitUntilStarted("stalled OCR")
        pasteboard.clearContents()
        pasteboard.setString("fresh incoming text", forType: .string)
        service.poll()
        await gate.waitUntilStarted("fresh incoming text")
        await gate.finish("fresh incoming text")
        for _ in 0..<50 where capturedTexts.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(capturedTexts == ["fresh incoming text"])
        service.stop()
        await gate.finish("stalled OCR")
    }

    @MainActor
    @Test("capture retries declared content fulfilled after its ownership change")
    func capturesDelayedPasteboardFulfillment() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let service = ClipboardCaptureService(pasteboard: pasteboard)
        var capturedTexts: [String] = []
        service.onClipCaptured = { payload, _, _ in capturedTexts.append(payload.displayText) }
        service.start(interval: 60)
        defer { service.stop() }

        pasteboard.declareTypes([.string], owner: nil)
        let changeCount = pasteboard.changeCount
        let now = Date()
        service.poll(now: now)
        try await Task.sleep(for: .milliseconds(50))
        let text = "Delayed external clipboard fulfillment"
        pasteboard.setString(text, forType: .string)
        #expect(pasteboard.changeCount == changeCount)
        service.poll(now: now.addingTimeInterval(0.3))
        for _ in 0..<100 where capturedTexts.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(capturedTexts == [text])
    }

    @MainActor
    @Test("initially absent types or empty text can be fulfilled under the same ownership", arguments: [true, false])
    func capturesInitiallyEmptyContent(noTypes: Bool) async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let service = ClipboardCaptureService(pasteboard: pasteboard)
        var capturedTexts: [String] = []
        service.onClipCaptured = { payload, _, _ in capturedTexts.append(payload.displayText) }
        service.start(interval: 60)
        defer { service.stop() }
        pasteboard.clearContents()
        if !noTypes { pasteboard.setString("", forType: .string) }
        let changeCount = pasteboard.changeCount
        let now = Date()
        service.poll(now: now)
        pasteboard.setString("Fulfilled after empty content", forType: .string)
        #expect(pasteboard.changeCount == changeCount)
        service.poll(now: now.addingTimeInterval(0.3))
        for _ in 0..<100 where capturedTexts.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(capturedTexts == ["Fulfilled after empty content"])
    }

    @MainActor
    @Test("the timer captures delayed content once without a second ownership change")
    func timerCapturesDelayedContentOnce() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let service = ClipboardCaptureService(pasteboard: pasteboard)
        var capturedTexts: [String] = []
        service.onClipCaptured = { payload, _, _ in capturedTexts.append(payload.displayText) }
        service.start(interval: 0.025)
        defer { service.stop() }
        pasteboard.declareTypes([.string], owner: nil)
        service.poll()
        let changeCount = pasteboard.changeCount
        try await Task.sleep(for: .milliseconds(50))
        pasteboard.setString("Delayed timer content", forType: .string)
        #expect(pasteboard.changeCount == changeCount)
        for _ in 0..<100 where capturedTexts.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(capturedTexts == ["Delayed timer content"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(capturedTexts.count == 1)
    }

    @MainActor
    @Test("a superseded unfulfilled copy cannot block the next valid capture")
    func supersededDeferredReadDoesNotBlock() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let service = ClipboardCaptureService(pasteboard: pasteboard)
        var capturedTexts: [String] = []
        service.onClipCaptured = { payload, _, _ in capturedTexts.append(payload.displayText) }
        service.start(interval: 60)
        defer { service.stop() }
        pasteboard.declareTypes([.string], owner: nil)
        service.poll()
        pasteboard.clearContents()
        pasteboard.setString("New ownership", forType: .string)
        service.poll()
        for _ in 0..<100 where capturedTexts.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(capturedTexts == ["New ownership"])
    }

    @MainActor
    @Test("consuming or restarting capture cancels deferred reads")
    func deferredReadInvalidation() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let service = ClipboardCaptureService(pasteboard: pasteboard)
        var capturedTexts: [String] = []
        service.onClipCaptured = { payload, _, _ in capturedTexts.append(payload.displayText) }
        service.start(interval: 60)
        defer { service.stop() }
        let now = Date()
        pasteboard.declareTypes([.string], owner: nil)
        service.poll(now: now)
        pasteboard.setString("Self copy", forType: .string)
        service.consumeCurrentPasteboardChange()
        service.poll(now: now.addingTimeInterval(10))
        pasteboard.declareTypes([.string], owner: nil)
        service.poll(now: now.addingTimeInterval(20))
        service.stop()
        pasteboard.setString("Fulfilled while paused", forType: .string)
        service.start(interval: 60)
        service.poll(now: now.addingTimeInterval(30))
        try await Task.sleep(for: .milliseconds(50))
        #expect(capturedTexts.isEmpty)
    }

    @MainActor
    @Test("capture observes externally supplied clipboard content without rewriting it")
    func captureDoesNotRewriteExternalClipboard() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let service = ClipboardCaptureService(pasteboard: pasteboard)
        var capturedPayload: ClipPayload?
        service.onClipCaptured = { payload, _, _ in capturedPayload = payload }
        service.start(interval: 60)
        defer { service.stop() }

        let text = "External device text 📱 — zażółć gęślą jaźń\nSecond line"
        let originType = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data([1]), forType: originType)
        let changeCount = pasteboard.changeCount
        let types = pasteboard.types
        service.poll()
        for _ in 0..<100 where capturedPayload == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(capturedPayload?.displayText == text)
        #expect(pasteboard.changeCount == changeCount)
        #expect(pasteboard.types == types)
        #expect(pasteboard.string(forType: .string) == text)
        #expect(pasteboard.data(forType: originType) == Data([1]))
        service.consumeCurrentPasteboardChange()
        service.stop()
        #expect(pasteboard.changeCount == changeCount)
        #expect(pasteboard.string(forType: .string) == text)
    }

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
        service.onClipCaptured = { payload, _, _ in
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
        service.onClipCaptured = { payload, _, _ in
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
        service.onClipCaptured = { payload, _, _ in
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
    @Test("completed captures make progress independently and retain their observation times")
    func deliversCompletedCapturesWithObservationTimes() async throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ClipVaultCaptureOrderingTest-\(UUID().uuidString)")
        )
        let gate = OrderedPayloadBuilderGate()
        let service = ClipboardCaptureService(pasteboard: pasteboard) { snapshot in
            await gate.build(snapshot)
        }
        var capturedTexts: [String] = []
        var capturedDates: [Date] = []
        service.onClipCaptured = { payload, _, date in
            capturedTexts.append(payload.displayText)
            capturedDates.append(date)
        }
        service.start(interval: 60)
        defer { service.stop() }
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = firstDate.addingTimeInterval(1)

        pasteboard.clearContents()
        pasteboard.setString("first", forType: .string)
        service.poll(now: firstDate)
        await gate.waitUntilStarted("first")

        pasteboard.clearContents()
        pasteboard.setString("second", forType: .string)
        service.poll(now: secondDate)
        await gate.waitUntilStarted("second")

        await gate.finish("second")
        for _ in 0..<50 where capturedTexts.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(capturedTexts == ["second"])
        await gate.finish("first")
        for _ in 0..<20 where capturedTexts.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(capturedTexts == ["second", "first"])
        #expect(capturedDates == [secondDate, firstDate])
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
        service.onClipCaptured = { payload, _, _ in
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
        for _ in 0..<50 where capturedTexts.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(capturedTexts == ["kept"])

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

    @MainActor
    @Test("Finder file URLs take precedence over redundant image representations")
    func finderFileURLsTakePrecedenceOverImageRepresentations() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ClipVaultFinderFilePriorityTest-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        let file = URL(fileURLWithPath: "/tmp/clipvault-image.png")
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8,
            pixelsHigh: 8,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 32,
            bitsPerPixel: 32
        ))
        let tiffData = bitmap.tiffRepresentation
        pasteboard.writeObjects([file as NSURL])
        pasteboard.setData(tiffData, forType: .tiff)

        let payload = try #require(ClipboardCaptureService.payload(from: pasteboard))

        #expect(payload.kind == .file)
        #expect(payload.metadata["paths"] == file.path)
        #expect(payload.previewData == nil)
    }

    @MainActor
    @Test("web URL objects remain links rather than file paths")
    func webURLObjectsRemainLinks() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ClipVaultWebURLObjectTest-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        let url = try #require(URL(string: "https://rsitech.ai/clipvault"))
        pasteboard.writeObjects([url as NSURL])

        let payload = try #require(ClipboardCaptureService.payload(from: pasteboard))

        #expect(payload.kind == .url)
        #expect(payload.displayText == url.absoluteString)
        #expect(payload.metadata["host"] == "rsitech.ai")
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
