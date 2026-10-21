import AppKit
import Dispatch
import Foundation
import Testing
@testable import ClipVaultCore

@Suite("Bounded image text recognition")
struct BoundedTextRecognitionTests {
    @Test("a stalled recognizer times out, admits no more work, and recovers after completion")
    func stalledRecognitionIsBounded() throws {
        let recognition = BoundedTextRecognition(timeout: .milliseconds(30))
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let result = recognition.recognize(Data([1])) { _ in
            release.wait()
            return "late OCR result"
        }
        #expect(result == nil)
        // A busy recognizer must not start a second underlying operation.
        let second = recognition.recognize(Data([2])) { _ in
            Issue.record("Recognition started while the previous request was still blocked")
            return "unexpected"
        }
        #expect(second == nil)
        release.signal()
        // Completion releases admission before another operation can return.
        for _ in 0..<100 {
            if recognition.recognize(Data([3]), operation: { _ in "recovered" }) == "recovered" {
                finished.signal()
                break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        #expect(finished.wait(timeout: .now()) == .success)
    }

    @Test("successful OCR and empty OCR remain distinct from unavailable OCR")
    func successfulRecognition() {
        let recognition = BoundedTextRecognition(timeout: .seconds(1))
        #expect(recognition.recognize(Data(), operation: { _ in "recognized text" }) == "recognized text")
        #expect(recognition.recognize(Data(), operation: { _ in "" }) == "")
        #expect(recognition.recognize(Data(), operation: { _ in nil }) == nil)
    }

    @Test("a timed out image keeps its bytes and can still be exported")
    func imageSurvivesOCRTimeout() throws {
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGPQbD/+HwAEywJ3k0b7vgAAAABJRU5ErkJggg=="))
        let snapshot = PasteboardSnapshot(uniformTypeIdentifiers: ["public.png"], string: nil,
            urlString: nil, rtfData: nil, tiffData: nil, pngData: png, objectImageData: nil, filePaths: [])
        let recognition = BoundedTextRecognition(timeout: .milliseconds(20))
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let candidate = ClipboardCaptureService.payload(from: snapshot,
            textRecognition: recognition, recognizeText: { _ in release.wait(); return "late" })
        let payload = try #require(candidate)
        #expect(payload.kind == .image)
        #expect(payload.displayText == "Image")
        #expect(payload.previewData == png)
        #expect(payload.extractedText.isEmpty)
        #expect(payload.metadata["ocrStatus"] == "unavailable")
        let portable = try ClipSyncPortable(payload: payload, sourceApp: nil, capturedAt: Date())
        #expect(portable.kind == "image")
        #expect(portable.imagePNG != nil)
    }
}
