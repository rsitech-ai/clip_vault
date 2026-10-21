import ClipVaultCore
import Foundation
import Testing
import SwiftData
@testable import ClipVault

private actor SuspendedSyncService: ClipSyncServicing {
    private var firstStatus: CheckedContinuation<ClipSyncStatus, Never>?
    private var count = 0
    private var enabled = false
    private var suspendedEnable: CheckedContinuation<Void, Never>?
    private let suspendEnable: Bool
    init(suspendEnable: Bool = false) { self.suspendEnable = suspendEnable }
    func hasSuspendedEnable() -> Bool { suspendedEnable != nil }
    func finishEnable() { suspendedEnable?.resume(); suspendedEnable = nil }
    func persistedEnabled() -> Bool { enabled }
    nonisolated func pauseImmediately() {}
    nonisolated func resumeImmediately() {}
    func status() async throws -> ClipSyncStatus {
        count += 1
        if count == 1 { return await withCheckedContinuation { firstStatus = $0 } }
        var result = ClipSyncStatus(); result.enabled = enabled; return result
    }
    func hasSuspendedStatus() -> Bool { firstStatus != nil }
    func statusCount() -> Int { count }
    func finishOldStatus() {
        var result = ClipSyncStatus(); result.enabled = true
        firstStatus?.resume(returning: result); firstStatus = nil
    }
    func setEnabled(_ enabled: Bool) async throws {
        if enabled && suspendEnable {
            await withCheckedContinuation { suspendedEnable = $0 }
        }
        self.enabled = enabled
    }
    func tick() async throws -> ClipSyncStatus { try await status() }
    func imports() async throws -> [ClipSyncEvent] { [] }
    func export(_ record: ClipSyncExport) async throws {}
    func markApplied(id: String) async throws {}
    func rejectImport(id: String) async throws {}
    func cancel(id: String) async throws {}
    func create(relay: String, registration: String, name: String) async throws {}
    func join(code: String, name: String) async throws -> String { "comparison" }
    func invite() async throws -> String { "invitation" }
    func approve(id: String, words: String) async throws {}
    func remove(id: String) async throws {}
    func disconnect() async throws -> Int { enabled = false; return 0 }
}

@MainActor
@Suite("Mac sharing consent races")
struct ClipVaultSyncControllerTests {
    @Test("consent writes persist in user order even when enabling is suspended")
    func consentWritesAreOrdered() async throws {
        let service = SuspendedSyncService(suspendEnable: true)
        let controller = ClipVaultSyncController(service: service)
        controller.setEnabled(true)
        for _ in 0..<1_000 {
            if await service.hasSuspendedEnable() { break }
            await Task.yield()
        }
        #expect(await service.hasSuspendedEnable())
        controller.setEnabled(false)
        for _ in 0..<100 { await Task.yield() }
        await service.finishEnable()
        // The first status call is deliberately suspended as well. It must not
        // prevent the later pause from being persisted.
        for _ in 0..<1_000 {
            if await service.statusCount() >= 2 { break }
            await Task.yield()
        }
        #expect(await service.statusCount() >= 2)
        #expect(await service.persistedEnabled() == false)
        await service.finishOldStatus()
        #expect(controller.status.enabled == false)
    }

    @Test("upgraded history cannot be pruned before its retention review")
    func historyCleanupHold() throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self])
        let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true)])
        let store = InMemoryClipStore()
        let old = try #require(try store.save(payload: ClipPayload(kind: .text, displayText: "Preserve previous history", extractedText: "Preserve previous history"), sourceApp: nil, capturedAt: Date(timeIntervalSince1970: 100)))
        let model = ClipVaultViewModel(container: container, store: store)
        model.historyRetentionReviewPending = true
        #expect(model.reload())
        model.pruneExpiredClips(retentionDays: 7)
        #expect(model.clips.contains(where: { $0.id == old.id }))
        #expect(try store.allClips().count == 1)
    }

    @Test("an old enable response cannot reverse a later pause")
    func staleEnableResponse() async throws {
        let service = SuspendedSyncService()
        let controller = ClipVaultSyncController(service: service)
        controller.setEnabled(true)
        for _ in 0..<1_000 {
            if await service.hasSuspendedStatus() { break }
            await Task.yield()
        }
        #expect(await service.hasSuspendedStatus())
        controller.setEnabled(false)
        for _ in 0..<1_000 {
            if await service.statusCount() >= 2 { break }
            await Task.yield()
        }
        #expect(await service.statusCount() >= 2)
        await service.finishOldStatus()
        for _ in 0..<100 { await Task.yield() }
        #expect(controller.status.enabled == false)
    }

    @Test("a setup operation's old status cannot reverse a later pause")
    func staleSetupResponse() async throws {
        let service = SuspendedSyncService()
        let controller = ClipVaultSyncController(service: service)
        controller.create(relay: "https://example.test", registration: "test-only", name: "Test")
        for _ in 0..<1_000 {
            if await service.hasSuspendedStatus() { break }
            await Task.yield()
        }
        #expect(await service.hasSuspendedStatus())
        controller.setEnabled(false)
        for _ in 0..<1_000 {
            if await service.statusCount() >= 2 { break }
            await Task.yield()
        }
        await service.finishOldStatus()
        for _ in 0..<100 { await Task.yield() }
        #expect(controller.status.enabled == false)
    }
}
