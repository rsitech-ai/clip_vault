import ClipVaultCore
import Foundation
import Testing
@testable import ClipVault

private actor SuspendedOverflowRetryService: ClipSyncServicing {
    private var enabled = true
    private var retryContinuation: CheckedContinuation<Int, Error>?
    private var retryCalls = 0

    nonisolated func pauseImmediately() {}
    nonisolated func resumeImmediately() {}
    func status() async throws -> ClipSyncStatus {
        var value = ClipSyncStatus()
        value.enabled = enabled
        value.state = enabled ? "Sharing on" : "Sharing off"
        return value
    }
    func tick() async throws -> ClipSyncStatus { try await status() }
    func imports() async throws -> [ClipSyncEvent] { [] }
    func export(_ record: ClipSyncExport) async throws {}
    func markApplied(id: String) async throws {}
    func rejectImport(id: String) async throws {}
    func cancel(id: String) async throws {}
    func setEnabled(_ enabled: Bool) async throws { self.enabled = enabled }
    func create(relay: String, registration: String, name: String) async throws {}
    func join(code: String, name: String) async throws -> String { "" }
    func invite() async throws -> String { "" }
    func approve(id: String, words: String) async throws {}
    func remove(id: String) async throws {}
    func disconnect() async throws -> Int { enabled = false; return 0 }
    func retryOverflow() async throws -> Int {
        retryCalls += 1
        return try await withCheckedThrowingContinuation { retryContinuation = $0 }
    }
    func retryStarted() -> Bool { retryContinuation != nil }
    func finishRetry(_ count: Int) { retryContinuation?.resume(returning: count); retryContinuation = nil }
    func observations() -> (Int, Bool) { (retryCalls, enabled) }
}

@MainActor
@Suite("Mac overflow retry action")
struct ClipVaultSyncOverflowRetryTests {
    @Test("a pause invalidates a suspended explicit overflow retry response")
    func staleRetryResponseCannotUndoPause() async throws {
        let service = SuspendedOverflowRetryService()
        let controller = ClipVaultSyncController(service: service)
        controller.status.enabled = true
        controller.status.state = "Sharing backlog full — retry local shares"

        controller.retryOverflow()
        for _ in 0..<1_000 {
            if await service.retryStarted() { break }
            await Task.yield()
        }
        #expect(await service.retryStarted())

        controller.setEnabled(false)
        #expect(controller.status.enabled == false)
        await service.finishRetry(4)
        for _ in 0..<1_000 {
            if !controller.busy { break }
            await Task.yield()
        }

        let (retryCalls, persistedEnabled) = await service.observations()
        #expect(retryCalls == 1)
        #expect(persistedEnabled == false)
        #expect(controller.status.enabled == false)
        #expect(controller.message == nil)
    }

    @Test("overflow retry does not run while sharing is disabled")
    func retryRequiresSharingEnabled() async {
        let service = SuspendedOverflowRetryService()
        let controller = ClipVaultSyncController(service: service)
        controller.status.enabled = false
        controller.status.state = "Sharing backlog full"

        controller.retryOverflow()
        await Task.yield()

        let (retryCalls, persistedEnabled) = await service.observations()
        #expect(retryCalls == 0)
        #expect(persistedEnabled)
        #expect(controller.status.enabled == false)
    }
}
