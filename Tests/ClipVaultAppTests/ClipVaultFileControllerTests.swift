import ClipVaultCore
import Foundation
import SwiftData
import Testing
@testable import ClipVault

private actor SuspendedFileService: ClipFileServicing {
    private var pending: CheckedContinuation<ClipFileDescriptor, Never>?
    private var pendingDescriptor: ClipFileDescriptor?
    private var reads = 0
    private var discarded: [String] = []
    let descriptor = ClipFileDescriptor(id: UUID().uuidString.lowercased(), origin: UUID().uuidString.lowercased(),
        filename: "fixture.txt", size: 4, sha256: String(repeating: "a", count: 64), chunkCount: 1, createdAt: 100)
    nonisolated func captureGeneration() -> UInt64 { 0 }
    nonisolated func cancelCaptureImmediately() {}
    func stageFile(at url: URL, captureGeneration: UInt64?) async throws -> ClipFileDescriptor {
        reads += 1
        var result = descriptor
        result.id = UUID().uuidString.lowercased()
        result.filename = url.lastPathComponent
        pendingDescriptor = result
        return await withCheckedContinuation { pending = $0 }
    }
    func hasPending() -> Bool { pending != nil }
    func readCount() -> Int { reads }
    func finish() {
        if let pendingDescriptor { pending?.resume(returning: pendingDescriptor) }
        pending = nil; pendingDescriptor = nil
    }
    func discardStagedFile(id: String) { discarded.append(id) }
    func discardedIDs() -> [String] { discarded }
    func saveFile(id: String, to url: URL) async throws {}
    func fileTransfers() async throws -> [ClipFileTransferStatus] { [] }
}

private actor FailingFileService: ClipFileServicing {
    nonisolated func captureGeneration() -> UInt64 { 0 }
    nonisolated func cancelCaptureImmediately() {}
    func stageFile(at url: URL, captureGeneration: UInt64?) async throws -> ClipFileDescriptor {
        throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url.path])
    }
    func discardStagedFile(id: String) async throws {}
    func saveFile(id: String, to url: URL) async throws {}
    func fileTransfers() async throws -> [ClipFileTransferStatus] { [] }
}

private actor ImageFallbackGate {
    private var continuation: CheckedContinuation<ClipPayload?, Never>?
    private var started = false
    func build() async -> ClipPayload? {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func hasStarted() -> Bool { started }
    func finish(with payload: ClipPayload?) { continuation?.resume(returning: payload); continuation = nil }
}

private actor ImageFallbackCounter {
    private(set) var count = 0
    func build() -> ClipPayload? { count += 1; return nil }
}

private struct TestPayloadEncryptor: PayloadEncrypting {
    func encrypt(_ data: Data) throws -> Data { data }
    func decrypt(_ data: Data) throws -> Data { data }
}

@MainActor
@Suite("Mac attachment capture lifecycle")
struct ClipVaultFileControllerTests {
    @Test("a failed single-file stage uses the captured image snapshot")
    func failedSingleImageFileUsesSnapshot() async throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self])
        let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true)])
        let store = InMemoryClipStore()
        let model = ClipVaultViewModel(container: container, store: store)
        let controller = ClipVaultFileController(service: FailingFileService())
        let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
        let fallback: ClipboardCaptureService.ImageFallbackBuilder = {
            ClipPayload(kind: .image, displayText: "Image", extractedText: "",
                metadata: ["ocrStatus": "unavailable"], previewData: bytes,
                uniformTypeIdentifiers: ["public.jpeg"])
        }
        controller.capture(urls: [URL(fileURLWithPath: "/tmp/unavailable.jpg")], sourceApp: "Tests",
            capturedAt: Date(timeIntervalSince1970: 123), model: model, imageFallback: fallback)
        for _ in 0..<1000 where controller.busy { await Task.yield() }
        for _ in 0..<1000 where (try store.allClips()).isEmpty { await Task.yield() }
        let clips = try store.allClips()
        #expect(clips.count == 1)
        #expect(clips.first?.kind == .image)
        #expect(clips.first?.previewData == bytes)
        #expect(clips.first?.metadata["file_id"] == nil)
        #expect(controller.message == "Captured an image instead. Use Add File to share the original file.")
    }

    @Test("an OCR-unavailable image fallback stays local while sharing is enabled")
    func unavailableOCRFallbackRemainsLocal() async throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self, ClipSyncExportRecord.self, ClipSyncReceiptRecord.self])
        let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true)])
        let store = SwiftDataClipStore(context: ModelContext(container), encryptor: TestPayloadEncryptor())
        store.sharingEnabled = true
        let model = ClipVaultViewModel(container: container, store: store, fileService: FailingFileService())
        let controller = ClipVaultFileController(service: FailingFileService())
        let payload = ClipPayload(kind: .image, displayText: "Image", extractedText: "",
            metadata: ["ocrStatus": "unavailable"], previewData: Data([0xff, 0xd8, 0xff, 0xd9]),
            uniformTypeIdentifiers: ["public.jpeg"])
        controller.capture(urls: [URL(fileURLWithPath: "/tmp/local-only.jpg")], sourceApp: "Tests",
            capturedAt: Date(), model: model, imageFallback: { payload })
        for _ in 0..<1000 {
            if try store.allClips().count == 1, controller.message != nil { break }
            await Task.yield()
        }

        #expect(try store.allClips().count == 1)
        #expect(try store.pendingSyncExports().isEmpty)
        #expect(controller.message == "Captured an image instead. Use Add File to share the original file.")
    }

    @Test("a successful file stage does not evaluate the lazy image fallback")
    func successfulStageSkipsImageFallback() async throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self])
        let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true)])
        let store = InMemoryClipStore()
        let model = ClipVaultViewModel(container: container, store: store)
        let service = SuspendedFileService()
        let controller = ClipVaultFileController(service: service)
        let calls = ImageFallbackCounter()
        controller.capture(urls: [URL(fileURLWithPath: "/tmp/readable.jpg")], sourceApp: "Tests",
            capturedAt: Date(), model: model, imageFallback: { await calls.build() })
        for _ in 0..<1000 { if await service.hasPending() { break }; await Task.yield() }
        await service.finish()
        for _ in 0..<1000 { if !controller.busy { break }; await Task.yield() }
        #expect(await calls.count == 0)
        #expect(try store.allClips().count == 1)
    }

    @Test("capture pause while image fallback is pending prevents ingestion")
    func pausedPendingImageFallbackDoesNotPersist() async throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self])
        let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true)])
        let store = InMemoryClipStore()
        let model = ClipVaultViewModel(container: container, store: store)
        let controller = ClipVaultFileController(service: FailingFileService())
        let gate = ImageFallbackGate()
        let fallbackPayload = ClipPayload(kind: .image, displayText: "Image", extractedText: "",
            previewData: Data([0xff, 0xd8, 0xff, 0xd9]), uniformTypeIdentifiers: ["public.jpeg"])
        controller.capture(urls: [URL(fileURLWithPath: "/tmp/paused.jpg")], sourceApp: "Tests",
            capturedAt: Date(), model: model, imageFallback: { await gate.build() })
        for _ in 0..<1000 { if await gate.hasStarted() { break }; await Task.yield() }
        #expect(await gate.hasStarted())
        controller.cancelCapture()
        await gate.finish(with: fallbackPayload)
        for _ in 0..<1000 { if !controller.busy { break }; await Task.yield() }
        #expect(try store.allClips().isEmpty)
    }

    @Test("a second copied file waits for the first stage and enters history")
    func rapidCopiesAreQueued() async throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self])
        let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true)])
        let store = InMemoryClipStore()
        let model = ClipVaultViewModel(container: container, store: store)
        let service = SuspendedFileService()
        let controller = ClipVaultFileController(service: service)
        controller.capture(urls: [URL(fileURLWithPath: "/tmp/first.txt")], sourceApp: "Tests", capturedAt: Date(), model: model)
        for _ in 0..<1000 { if await service.hasPending() { break }; await Task.yield() }
        #expect(await service.hasPending())
        controller.capture(urls: [URL(fileURLWithPath: "/tmp/second.txt")], sourceApp: "Tests", capturedAt: Date(), model: model)
        for _ in 0..<100 { await Task.yield() }
        #expect(await service.readCount() == 1)
        await service.finish()
        for _ in 0..<1000 { if await service.readCount() == 2 { break }; await Task.yield() }
        #expect(await service.readCount() == 2)
        await service.finish()
        for _ in 0..<1000 { if !controller.busy { break }; await Task.yield() }
        #expect(try store.allClips().count == 2)
    }

    @Test("pause before a queued capture starts prevents any source read")
    func queuedCaptureCannotAdoptNewGeneration() async throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self])
        let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true)])
        let model = ClipVaultViewModel(container: container, store: InMemoryClipStore())
        let service = SuspendedFileService()
        let controller = ClipVaultFileController(service: service)
        controller.capture(ClipPayload(kind: .file, displayText: "fixture.txt", extractedText: "fixture.txt",
            metadata: ["captureFiles": "[\"/tmp/fixture.txt\"]"]), sourceApp: "Tests", capturedAt: Date(), model: model)
        controller.cancelCapture()
        for _ in 0..<100 { await Task.yield() }
        #expect(await service.hasPending() == false)
    }

    @Test("capture pause discards a staged file instead of saving or exporting it")
    func pausedCaptureDoesNotPersist() async throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self])
        let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true)])
        let store = InMemoryClipStore()
        let model = ClipVaultViewModel(container: container, store: store)
        let service = SuspendedFileService()
        let controller = ClipVaultFileController(service: service)
        let operation = Task { await controller.stage(urls: [URL(fileURLWithPath: "/tmp/fixture.txt")], sourceApp: "Tests", capturedAt: Date(), isCapture: true, model: model) }
        for _ in 0..<1000 { if await service.hasPending() { break }; await Task.yield() }
        #expect(await service.hasPending())
        controller.cancelCapture()
        await service.finish()
        await operation.value
        #expect(try store.allClips().isEmpty)
        #expect(await service.discardedIDs().count == 1)
    }

    @Test("explicit Add File works with background capture paused")
    func explicitFileIsLocalWithoutCapture() async throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self])
        let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true)])
        let store = InMemoryClipStore()
        let model = ClipVaultViewModel(container: container, store: store)
        let service = SuspendedFileService()
        let controller = ClipVaultFileController(service: service)
        let operation = Task { await controller.stage(urls: [URL(fileURLWithPath: "/tmp/fixture.txt")], sourceApp: "Tests", capturedAt: Date(), isCapture: false, model: model) }
        for _ in 0..<1000 { if await service.hasPending() { break }; await Task.yield() }
        #expect(await service.hasPending())
        controller.cancelCapture()
        await service.finish()
        await operation.value
        #expect(try store.allClips().count == 1)
        #expect(try store.allClips()[0].metadata["file_size"] == "4")
    }
}
