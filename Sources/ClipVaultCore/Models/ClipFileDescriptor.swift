import Foundation

/// Only this small descriptor crosses the platform store/FFI boundary.
/// File bytes remain encrypted in the portable transfer store until explicit Save.
public struct ClipFileDescriptor: Codable, Sendable, Equatable {
    // The chunk index is UInt32 on the wire. There is no smaller product size cap.
    public static let maximumBytes: UInt64 = UInt64(UInt32.max) * 1_048_576
    public var id: String
    public var origin: String
    public var filename: String
    public var size: UInt64
    public var sha256: String
    public var chunkCount: UInt32
    public var createdAt: Int64

    public init(id: String, origin: String, filename: String, size: UInt64, sha256: String, chunkCount: UInt32, createdAt: Int64) {
        self.id = id; self.origin = origin; self.filename = filename; self.size = size
        self.sha256 = sha256; self.chunkCount = chunkCount; self.createdAt = createdAt
    }
    enum CodingKeys: String, CodingKey {
        case id, origin, filename, size, sha256
        case chunkCount = "chunk_count", createdAt = "created_at"
    }

    public func validate() throws {
        guard size <= Self.maximumBytes else { throw ClipSyncError.fileTooLarge }
        guard UUID(uuidString: id) != nil, UUID(uuidString: origin) != nil,
              createdAt >= 0, chunkCount == UInt32((size + 1_048_575) / 1_048_576),
              !filename.isEmpty, filename.utf8.count <= 255,
              filename != ".", filename != "..", !filename.contains("/"), !filename.contains("\\"),
              !filename.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }),
              sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ClipSyncError.invalidPayload
        }
    }

    public func payload() throws -> ClipPayload {
        try validate()
        return ClipPayload(kind: .file, displayText: filename, extractedText: filename,
            metadata: ["file_id": id, "file_origin": origin, "file_size": String(size), "file_sha256": sha256])
    }

    public static func from(payload: ClipPayload, capturedAt: Int64 = 0) throws -> Self? {
        guard payload.kind == .file, let id = payload.metadata["file_id"] else { return nil }
        guard payload.previewData == nil, payload.metadata["paths"] == nil,
              let origin = payload.metadata["file_origin"],
              let rawSize = payload.metadata["file_size"], let size = UInt64(rawSize),
              rawSize == String(size), size <= maximumBytes,
              let hash = payload.metadata["file_sha256"] else { throw ClipSyncError.invalidPayload }
        let descriptor = Self(id: id, origin: origin, filename: payload.displayText, size: size,
            sha256: hash, chunkCount: UInt32((size + 1_048_575) / 1_048_576), createdAt: capturedAt)
        try descriptor.validate()
        return descriptor
    }
}

public struct ClipFileTransferStatus: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var filename: String
    public var size: UInt64
    public var transferred: UInt64
    public var status: String
}
