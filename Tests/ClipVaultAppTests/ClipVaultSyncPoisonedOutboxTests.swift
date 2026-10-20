import ClipVaultCore
import Foundation
import SwiftData
import Testing
@testable import ClipVault

private actor PoisonedOutboxSyncService: ClipSyncServicing {
    private(set) var tickCount = 0
    private(set) var exportedText: [String] = []
    private(set) var appliedIDs: [String] = []
    let incoming = ClipSyncEvent(id: UUID().uuidString.lowercased(), origin: UUID().uuidString.lowercased(), sequence: 1,
        clip: ClipSyncPortable(kind: "text", text: "Inbound survives poison", displayText: "Inbound survives poison", capturedAt: 100,
            sourceApp: nil, sourceDevice: "Ubuntu", imagePNG: nil, metadata: [:]))

    nonisolated func pauseImmediately() {}
    nonisolated func resumeImmediately() {}
    func status() async throws -> ClipSyncStatus { var value = ClipSyncStatus(); value.enabled = true; return value }
    func tick() async throws -> ClipSyncStatus { tickCount += 1; return try await status() }
    func export(_ record: ClipSyncExport) async throws { exportedText.append(record.payload.text) }
    func imports() async throws -> [ClipSyncEvent] { [incoming] }
    func markApplied(id: String) async throws { appliedIDs.append(id) }
    func rejectImport(id: String) async throws {}
    func cancel(id: String) async throws {}
    func setEnabled(_ enabled: Bool) async throws {}
    func create(relay: String, registration: String, name: String) async throws {}
    func join(code: String, name: String) async throws -> String { "" }
    func invite() async throws -> String { "" }
    func approve(id: String, words: String) async throws {}
    func remove(id: String) async throws {}
    func disconnect() async throws -> Int { 0 }
    func observations() -> (Int, [String], [String]) { (tickCount, exportedText, appliedIDs) }
}

private struct PoisonedOutboxEncryptor: PayloadEncrypting {
    func encrypt(_ data: Data) throws -> Data { data }
    func decrypt(_ data: Data) throws -> Data { data }
}

private struct PoisonedOutboxFileService: ClipFileServicing {
    func captureGeneration() -> UInt64 { 0 }
    func cancelCaptureImmediately() {}
    func stageFile(at url: URL, captureGeneration: UInt64?) async throws -> ClipFileDescriptor { throw ClipSyncError.invalidPayload }
    func discardStagedFile(id: String) async throws {}
    func saveFile(id: String, to url: URL) async throws {}
    func fileTransfers() async throws -> [ClipFileTransferStatus] { [] }
}

@MainActor
@Suite("Poisoned outbox controller recovery")
struct ClipVaultSyncPoisonedOutboxTests {
    @Test("a corrupt export does not prevent healthy export or inbound synchronization")
    func poisonedOutboxDoesNotStopSyncCycle() async throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self, ClipSyncExportRecord.self, ClipSyncReceiptRecord.self])
        let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let store = SwiftDataClipStore(context: context, encryptor: PoisonedOutboxEncryptor())
        store.sharingEnabled = true
        let poison = ClipSyncExportRecord(id: "000-poison", clipID: "missing-clip", encryptedPayload: Data("bad export".utf8))
        context.insert(poison)
        try context.save()
        _ = try store.save(payload: ClipPayload(kind: .text, displayText: "Healthy outgoing", extractedText: "Healthy outgoing"), sourceApp: nil, capturedAt: Date())

        let model = ClipVaultViewModel(container: container, store: store, fileService: PoisonedOutboxFileService())
        let service = PoisonedOutboxSyncService()
        let controller = ClipVaultSyncController(service: service)
        controller.status.enabled = true
        controller.start(model: model, store: store)
        await controller.synchronize()

        let (ticks, exported, applied) = await service.observations()
        #expect(ticks == 1)
        #expect(exported == ["Healthy outgoing"])
        #expect(applied == [service.incoming.id])
        #expect(try store.allClips().contains(where: { $0.preview == "Inbound survives poison" }))
        #expect(poison.failure?.contains("queued share") == true)
        #expect(controller.message?.contains("remain local") == true)
    }
}
