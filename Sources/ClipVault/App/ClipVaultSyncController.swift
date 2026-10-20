import ClipVaultCore
import Foundation
import Observation

@MainActor
@Observable
final class ClipVaultSyncController {
    var status = ClipSyncStatus()
    var message: String?
    var pairingCode: String?
    var busy = false
    private let service: any ClipSyncServicing
    private var task: Task<Void, Never>?
    private weak var model: ClipVaultViewModel?
    private var syncStore: SwiftDataClipStore?
    private var generation = 0
    private var mutationTail: Task<String?, Error>?

    private func enqueueMutation(_ operation: @escaping @MainActor () async throws -> String?) -> Task<String?, Error> {
        let previous = mutationTail
        let next = Task { @MainActor in
            _ = try? await previous?.value
            return try await operation()
        }
        mutationTail = next
        return next
    }

    func restoreConsent() async throws {
        let version = generation
        let current = try await service.status()
        guard version == generation else { return }
        status = current
        updateCapturePolicy()
    }

    init(service: any ClipSyncServicing = ClipSyncService()) { self.service = service }

    func start(model: ClipVaultViewModel, store: SwiftDataClipStore) {
        guard task == nil else { return }
        self.model = model; syncStore = store
        updateCapturePolicy()
        task = Task { [weak self] in
            while !Task.isCancelled {
                if let self {
                    await self.cleanUpLocalCopies()
                    if self.status.enabled, !self.busy { await self.synchronize() }
                } else { return }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func cleanUpLocalCopies() async {
        guard !busy, let syncStore else { return }
        busy = true
        defer { busy = false }
        do {
            for id in try syncStore.pendingSyncCancellations() {
                try await service.cancel(id: id)
                try syncStore.completeSyncCancellation(id: id)
            }
        } catch { message = error.localizedDescription }
    }

    private func updateCapturePolicy() {
        syncStore?.sharingEnabled = status.enabled && status.members.count > 1
    }

    func synchronize() async {
        guard !busy, status.enabled, let syncStore else { return }
        busy = true
        let operation = generation
        defer { busy = false }
        do {
            // Cancel local deletions before flushing new exports.
            for id in try syncStore.pendingSyncCancellations() {
                guard operation == generation, status.enabled else { return }
                try await service.cancel(id: id)
                try syncStore.completeSyncCancellation(id: id)
            }
            try syncStore.retrySyncExports()
            for export in try syncStore.pendingSyncExports() {
                guard operation == generation, status.enabled else { return }
                try await service.export(export)
                try syncStore.markSyncExported(id: export.id)
            }
            guard operation == generation, status.enabled else { return }
            let current = try await service.tick()
            guard operation == generation, status.enabled else { return }
            status = current
            var imported = false
            for event in try await service.imports() {
                guard operation == generation, status.enabled else { return }
                do {
                    if try syncStore.importSyncEvent(event) != nil { imported = true }
                    try await service.markApplied(id: event.id)
                } catch is ClipSyncError {
                    // Invalid platform payloads are rejected durably. Storage failures remain
                    // unacknowledged so retry can recover without losing data.
                    try await service.rejectImport(id: event.id)
                }
            }
            if imported { _ = model?.reload() }
            updateCapturePolicy()
            let failures = try syncStore.syncExportFailures()
            message = failures.isEmpty ? nil : "\(failures.count) clips remain local: \(failures[0])"
        } catch { message = error.localizedDescription }
    }

    func setEnabled(_ enabled: Bool) {
        // Invalidate any in-flight UI work immediately. The engine observes the persisted flag
        // before its next cycle; an HTTP request already accepted cannot be undone.
        generation += 1
        let operation = generation
        if enabled { service.resumeImmediately() }
        else { service.pauseImmediately() }
        status.enabled = enabled
        updateCapturePolicy()
        let write = enqueueMutation { [service] in
            try await service.setEnabled(enabled)
            return nil
        }
        Task {
            do {
                _ = try await write.value
                let current = try await service.status()
                guard operation == generation else { return }
                status = current; updateCapturePolicy()
            } catch {
                guard operation == generation else { return }
                status.enabled = false
                service.pauseImmediately()
                updateCapturePolicy()
                message = error.localizedDescription
            }
        }
    }

    func create(relay: String, registration: String, name: String) {
        guard !busy else { return }
        service.resumeImmediately() // Explicit workspace setup consent.
        perform { [service] in
            try await service.create(relay: relay, registration: registration, name: name)
            return nil
        }
    }
    func join(code: String, name: String) {
        guard !busy else { return }
        service.resumeImmediately() // Explicit pairing consent after a local reset.
        perform { [service] in try await service.join(code: code, name: name) }
    }
    func invite() {
        guard status.enabled else { return }
        perform { [service] in try await service.invite() }
    }
    func copyInvitation() { if let pairingCode { model?.copyPrivateSyncInvitation(pairingCode) } }
    func approve(_ request: ClipSyncPairRequest) {
        guard status.enabled else { return }
        perform { [service] in
            try await service.approve(id: request.id, words: request.words)
            return nil
        }
    }
    func remove(id: String) {
        guard status.enabled else { return }
        perform { [service] in
            try await service.remove(id: id)
            return nil
        }
    }
    func disconnect() {
        guard !busy else { return }
        generation += 1
        let version = generation
        service.pauseImmediately()
        status.enabled = false
        updateCapturePolicy()
        busy = true
        let write = enqueueMutation { [service, syncStore] in
            // Persist pause before touching the platform outbox. A SwiftData
            // failure must not leave the Rust configuration enabled on reopen.
            try await service.setEnabled(false)
            try syncStore?.cancelAllSyncExports()
            return String(try await service.disconnect())
        }
        Task {
            defer { busy = false }
            do {
                let cancelled = try await write.value ?? "0"
                let current = try await service.status()
                guard version == generation else { return }
                status = current
                pairingCode = nil
                message = "Disconnected locally; \(cancelled) pending recipient deliveries cancelled. Local history is preserved. Remove this device on the owner to revoke its old membership."
                updateCapturePolicy()
            } catch { message = error.localizedDescription }
        }
    }

    func shareSelected() {
        guard status.enabled, status.members.count > 1, let clip = model?.selectedClip, let syncStore else { return }
        do { try syncStore.shareExistingClip(id: clip.id) }
        catch { message = error.localizedDescription }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> String?) {
        guard !busy else { return }
        let version = generation
        busy = true; message = nil
        let write = enqueueMutation(operation)
        Task {
            defer { busy = false }
            do {
                let code = try await write.value
                let current = try await service.status()
                guard version == generation else { return }
                pairingCode = code
                status = current
                updateCapturePolicy()
            } catch {
                guard version == generation else { return }
                message = error.localizedDescription
            }
        }
    }
}
