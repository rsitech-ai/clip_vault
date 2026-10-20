import Foundation
import OSLog

@_silgen_name("cv_sync_file_generation")
private func cv_sync_file_generation() -> UInt64
@_silgen_name("cv_sync_cancel_file_capture")
private func cv_sync_cancel_file_capture()

public protocol ClipFileServicing: Sendable {
    func captureGeneration() -> UInt64
    func cancelCaptureImmediately()
    func stageFile(at url: URL, captureGeneration: UInt64?) async throws -> ClipFileDescriptor
    func discardStagedFile(id: String) async throws
    func saveFile(id: String, to url: URL) async throws
    func fileTransfers() async throws -> [ClipFileTransferStatus]
}

extension ClipSyncService: ClipFileServicing {
    public func captureGeneration() -> UInt64 { cv_sync_file_generation() }
    public func cancelCaptureImmediately() { cv_sync_cancel_file_capture() }

    public func stageFile(at url: URL, captureGeneration: UInt64? = nil) async throws -> ClipFileDescriptor {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { throw ClipSyncError.invalidPayload }
        struct Stage: Encodable, Sendable { var path: String; var generation: UInt64? }
        return try await call("file_stage", payload: Stage(path: url.path, generation: captureGeneration), as: ClipFileDescriptor.self)
    }
    public func discardStagedFile(id: String) async throws {
        _ = try await call("file_discard", payload: ["id": id], as: Bool.self)
    }
    public func saveFile(id: String, to url: URL) async throws {
        guard url.isFileURL else { throw ClipSyncError.invalidPayload }
        // A Save-panel grant covers its exact URL, not arbitrary sibling files.
        // Ask Foundation for private scratch space on that volume, let the core
        // stream and verify there, then publish to the selected URL atomically.
        let scratch = try FileManager.default.url(for: .itemReplacementDirectory,
            in: .userDomainMask, appropriateFor: url, create: true)
        defer {
            do { try FileManager.default.removeItem(at: scratch) }
            catch {
                Logger(subsystem: "com.andrzej.ClipVault", category: "Files")
                    .warning("Attachment temporary directory cleanup failed: \(error.localizedDescription, privacy: .private)")
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.path)
        let verified = scratch.appendingPathComponent("verified-attachment")
        _ = try await call("file_save", payload: ["id": id, "path": verified.path], as: Bool.self)
        try ClipFilePublisher.publish(verifiedFile: verified, to: url)
    }
    public func fileTransfers() async throws -> [ClipFileTransferStatus] {
        try await call("file_transfers", payload: [String: String](), as: [ClipFileTransferStatus].self)
    }
}
