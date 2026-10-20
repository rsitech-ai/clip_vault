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

@MainActor
@Suite("Mac attachment capture lifecycle")
struct ClipVaultFileControllerTests {
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
