import ClipVaultCore
import Foundation
import SwiftData
import Testing
@testable import ClipVault

private struct UnsupportedFileError: Error, LocalizedError {
    var errorDescription: String? { "Other device needs an update" }
}

private actor UnsupportedFileSyncService: ClipSyncServicing {
    private var ticks = 0
    private var exportedText = false
    let incoming = ClipSyncEvent(id: UUID().uuidString.lowercased(), origin: UUID().uuidString.lowercased(), sequence: 1,
        clip: ClipSyncPortable(kind: "text", text: "Incoming still works", displayText: "Incoming still works", capturedAt: 100,
            sourceApp: nil, sourceDevice: nil, imagePNG: nil, metadata: [:]))
    func observations() -> (Int, Bool) { (ticks, exportedText) }
    nonisolated func pauseImmediately() {}
    nonisolated func resumeImmediately() {}
    func status() async throws -> ClipSyncStatus { var status = ClipSyncStatus(); status.enabled = true; return status }
    func tick() async throws -> ClipSyncStatus { ticks += 1; return try await status() }
    func export(_ record: ClipSyncExport) async throws {
        if record.payload.kind == "attachment" { throw UnsupportedFileError() }
        exportedText = true
    }
    func imports() async throws -> [ClipSyncEvent] { [incoming] }
    func markApplied(id: String) async throws {}
    func rejectImport(id: String) async throws {}
    func cancel(id: String) async throws {}
    func setEnabled(_ enabled: Bool) async throws {}
    func create(relay: String, registration: String, name: String) async throws {}
    func join(code: String, name: String) async throws -> String { "" }
    func invite() async throws -> String { "" }
    func approve(id: String, words: String) async throws {}
    func remove(id: String) async throws {}
    func disconnect() async throws -> Int { 0 }
}
private struct ResilienceEncryptor: PayloadEncrypting {
    func encrypt(_ data: Data) throws -> Data { data }
    func decrypt(_ data: Data) throws -> Data { data }
}
private struct NoopFileStatusService: ClipFileServicing {
    func captureGeneration() -> UInt64 { 0 }
    func cancelCaptureImmediately() {}
    func stageFile(at url: URL, captureGeneration: UInt64?) async throws -> ClipFileDescriptor { throw UnsupportedFileError() }
    func discardStagedFile(id: String) async throws {}
    func saveFile(id: String, to url: URL) async throws { throw UnsupportedFileError() }
    func fileTransfers() async throws -> [ClipFileTransferStatus] { [] }
}

@MainActor
@Suite("Sharing failure isolation")
struct ClipVaultSyncResilienceTests {
    @Test("an unsupported file stays queued while ordinary exports and imports continue")
    func fileFailureDoesNotBlockSync() async throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self, ClipSyncExportRecord.self, ClipSyncReceiptRecord.self])
        let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true)])
        let store = SwiftDataClipStore(context: ModelContext(container), encryptor: ResilienceEncryptor())
        store.sharingEnabled = true
        let file = ClipFileDescriptor(id: UUID().uuidString.lowercased(), origin: UUID().uuidString.lowercased(),
            filename: "fixture.bin", size: 1, sha256: String(repeating: "a", count: 64), chunkCount: 1, createdAt: 100)
        _ = try store.save(payload: file.payload(), sourceApp: nil, capturedAt: Date())
        _ = try store.save(payload: ClipPayload(kind: .text, displayText: "Outgoing still works", extractedText: "Outgoing still works"), sourceApp: nil, capturedAt: Date())
        let model = ClipVaultViewModel(container: container, store: store, fileService: NoopFileStatusService())
        let service = UnsupportedFileSyncService()
        let controller = ClipVaultSyncController(service: service)
        controller.status.enabled = true
        controller.start(model: model, store: store)
        await controller.synchronize()
        let (ticks, textWasExported) = await service.observations()
        #expect(ticks > 0)
        #expect(textWasExported)
        #expect(try store.allClips().contains(where: { $0.preview == "Incoming still works" }))
        #expect(try store.pendingSyncExports().count == 1)
        #expect(controller.message?.contains("waiting") == true)
    }
}
