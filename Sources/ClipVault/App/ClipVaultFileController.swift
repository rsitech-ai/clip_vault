import AppKit
import ClipVaultCore
import Foundation
import Observation

@MainActor
@Observable
final class ClipVaultFileController {
    var busy = false
    var activity: String?
    var message: String?
    var transfers: [ClipFileTransferStatus] = []
    private let service: any ClipFileServicing
    private var captureGeneration: UInt64 = 0
    private struct PendingCapture {
        var urls: [URL]
        var sourceApp: String?
        var capturedAt: Date
        var generation: UInt64
        var engineGeneration: UInt64
        weak var model: ClipVaultViewModel?
    }
    private var pendingCaptures: [PendingCapture] = []
    private var drainingCaptures = false

    init(service: any ClipFileServicing = ClipSyncService()) { self.service = service }

    func cancelCapture() {
        captureGeneration &+= 1
        service.cancelCaptureImmediately()
        pendingCaptures.removeAll()
    }

    func addFiles(model: ClipVaultViewModel) {
        guard !busy else { return }
        busy = true
        let panel = NSOpenPanel()
        panel.title = "Add Files to ClipVault"
        panel.message = "Choose up to 10 files, each up to 100 MiB. Paired devices receive the actual files. File contents are not screened for sensitive information."
        panel.prompt = "Add Files"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        NSApp.activate()
        panel.begin { [weak self, weak model] response in
            guard let self else { return }
            self.busy = false
            guard response == .OK, let model else { self.drainCaptures(); return }
            let urls = panel.urls
            Task { await self.stage(urls: urls, sourceApp: "ClipVault", capturedAt: Date(), isCapture: false, model: model) }
        }
    }

    func capture(_ payload: ClipPayload, sourceApp: String?, capturedAt: Date, model: ClipVaultViewModel) {
        guard let encoded = payload.metadata["captureFiles"], encoded.utf8.count <= 64 * 1024,
              let data = encoded.data(using: .utf8), let paths = try? JSONDecoder().decode([String].self, from: data) else {
            message = "Could not read the file selection. Use Add File to choose it again."
            return
        }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        capture(urls: urls, sourceApp: sourceApp, capturedAt: capturedAt, model: model)
    }

    func capture(urls: [URL], sourceApp: String?, capturedAt: Date, model: ClipVaultViewModel) {
        guard !urls.isEmpty, urls.count <= 10 else { message = "Choose up to 10 files at a time."; return }
        guard pendingCaptures.reduce(0, { $0 + $1.urls.count }) + urls.count <= 10 else {
            message = "The file capture queue is full. Copy the remaining files again after it finishes."
            return
        }
        pendingCaptures.append(PendingCapture(urls: urls, sourceApp: sourceApp, capturedAt: capturedAt,
            generation: captureGeneration, engineGeneration: service.captureGeneration(), model: model))
        drainCaptures()
    }

    private func drainCaptures() {
        guard !busy, !drainingCaptures, !pendingCaptures.isEmpty else { return }
        drainingCaptures = true
        Task {
            defer { drainingCaptures = false; drainCaptures() }
            while !busy, !pendingCaptures.isEmpty {
                let pending = pendingCaptures.removeFirst()
                guard pending.generation == captureGeneration, let model = pending.model else { continue }
                await stage(urls: pending.urls, sourceApp: pending.sourceApp, capturedAt: pending.capturedAt,
                    isCapture: true, model: model, observedGeneration: pending.generation,
                    engineGeneration: pending.engineGeneration)
            }
        }
    }

    func stage(urls: [URL], sourceApp: String?, capturedAt: Date, isCapture: Bool, model: ClipVaultViewModel,
               observedGeneration: UInt64? = nil, engineGeneration expectedEngineGeneration: UInt64? = nil) async {
        let version = observedGeneration ?? captureGeneration
        guard !isCapture || version == captureGeneration else { return }
        guard !busy else { message = "A file operation is in progress. Try again when it finishes."; return }
        guard !urls.isEmpty, urls.count <= 10 else { message = "Choose up to 10 files at a time."; return }
        let engineGeneration = isCapture ? (expectedEngineGeneration ?? service.captureGeneration()) : nil
        busy = true; message = nil
        defer { busy = false; activity = nil; drainCaptures() }
        for url in urls {
            guard !isCapture || version == captureGeneration else { return }
            activity = "Adding \(url.lastPathComponent)…"
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let file = try await service.stageFile(at: url, captureGeneration: engineGeneration)
                guard !isCapture || version == captureGeneration else {
                    try await service.discardStagedFile(id: file.id)
                    return
                }
                // Ingest synchronously validates and durably saves the local
                // descriptor/outbox before its next background export can run.
                if !model.ingest(payload: try file.payload(), sourceApp: sourceApp, capturedAt: capturedAt) {
                    try await service.discardStagedFile(id: file.id)
                    message = "The file could not be added. Its source is unchanged."
                }
            } catch {
                if isCapture && version != captureGeneration { return }
                message = isCapture
                    ? "Could not add \(url.lastPathComponent). Use Add File to grant access, or check the 100 MiB limit. \(error.localizedDescription)"
                    : "Could not add \(url.lastPathComponent). \(error.localizedDescription)"
            }
        }
        await refresh()
    }

    func save(_ clip: Clip) {
        guard !busy, let id = clip.metadata["file_id"] else { return }
        busy = true
        let panel = NSSavePanel()
        panel.title = "Save Attachment"
        panel.nameFieldStringValue = clip.preview
        panel.canCreateDirectories = true
        panel.message = "Choose an unused filename. ClipVault verifies the complete file before saving."
        NSApp.activate()
        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { self.busy = false; self.drainCaptures(); return }
            Task {
                self.busy = true; self.message = nil; self.activity = "Saving \(clip.preview)…"
                defer { self.busy = false; self.activity = nil; self.drainCaptures() }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    try await self.service.saveFile(id: id, to: url)
                    self.message = "Saved \(clip.preview)."
                } catch { self.message = "Could not save the file. \(error.localizedDescription)" }
            }
        }
    }

    func refresh() async {
        do { transfers = try await service.fileTransfers() }
        catch { message = error.localizedDescription }
    }

    func transfer(id: String) -> ClipFileTransferStatus? { transfers.first { $0.id == id } }

    func statusTitle(_ status: String) -> String {
        switch status {
        case "staged": "Available on this Mac"
        case "pending", "sending": "Sharing with paired devices"
        case "receiving": "Receiving file"
        case "verifying": "Verifying file"
        case "ready": "Ready to save"
        case "unsupported": "Update the other device to share this file"
        case "failed": "File transfer failed"
        case "paused": "Sharing paused"
        default: "File transfer needs attention"
        }
    }
}
