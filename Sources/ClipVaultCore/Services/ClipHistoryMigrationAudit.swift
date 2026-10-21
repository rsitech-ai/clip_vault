import CryptoKit
import Foundation
import SwiftData

/// Verifies that opening the device-sync schema preserved the complete local
/// history represented by the pre-sync two-entity store.
public enum ClipHistoryMigrationAudit {
  private static let batchSize = 128
  private static let legacySchema = Schema([ClipRecord.self, FolderRecord.self])

  public struct Snapshot: Codable, Sendable, Equatable {
    public let clipCount: Int
    public let folderCount: Int
    /// SHA-256 over every legacy model field, including the stored encrypted
    /// payload bytes. The receipt contains no clip text or payload content.
    public let digest: String
  }

  public struct Receipt: Codable, Sendable, Equatable {
    public let clipCount: Int
    public let folderCount: Int
    public let digest: String
  }

  public enum AuditError: Error, LocalizedError, Equatable {
    case invalidSnapshot
    case contextHasChanges
    case mismatch

    public var errorDescription: String? {
      switch self {
      case .invalidSnapshot:
        "The history migration snapshot is invalid."
      case .contextHasChanges:
        "History migration must be verified before the current store is modified."
      case .mismatch:
        "The current store does not exactly match the preserved history snapshot."
      }
    }
  }

  /// Reads a pre-device-sync store through SwiftData's read-only configuration.
  /// SwiftData resolves external-storage payloads before their exact bytes are
  /// included in the digest. The backup and its support directory are untouched.
  public static func snapshot(legacyStore: URL) throws -> Snapshot {
    let configuration = ModelConfiguration(
      "ClipHistoryMigrationAudit",
      schema: legacySchema,
      url: legacyStore,
      allowsSave: false
    )
    let container = try ModelContainer(for: legacySchema, configurations: [configuration])
    let context = ModelContext(container)
    context.autosaveEnabled = false
    let digest = try digest(in: context)
    return Snapshot(
      clipCount: digest.clipCount, folderCount: digest.folderCount, digest: digest.value)
  }

  /// Compare the post-open current schema against the immutable legacy snapshot.
  /// Call before reconciliation, pruning, or other writes to the current context.
  public static func verify(snapshot: Snapshot, in context: ModelContext) throws -> Receipt {
    guard isValidDigest(snapshot.digest), snapshot.clipCount >= 0, snapshot.folderCount >= 0 else {
      throw AuditError.invalidSnapshot
    }
    guard !context.hasChanges else { throw AuditError.contextHasChanges }
    let actual = try digest(in: context)
    guard actual.clipCount == snapshot.clipCount,
      actual.folderCount == snapshot.folderCount,
      actual.value == snapshot.digest
    else {
      throw AuditError.mismatch
    }
    return Receipt(
      clipCount: actual.clipCount, folderCount: actual.folderCount, digest: actual.value)
  }

  private struct DigestResult {
    var clipCount: Int
    var folderCount: Int
    var value: String
  }

  private struct StreamHasher {
    private var hasher = SHA256()

    mutating func append(_ bytes: Data) {
      appendLength(bytes.count)
      hasher.update(data: bytes)
    }

    mutating func appendRaw(_ bytes: Data) {
      hasher.update(data: bytes)
    }

    mutating func append(_ value: String) {
      append(Data(value.utf8))
    }

    mutating func append(_ value: Bool) {
      appendRaw(Data([value ? 1 : 0]))
    }

    mutating func append(_ value: Int) {
      appendRaw(Data(Int64(value).bigEndianBytes))
    }

    mutating func append(_ value: UInt64) {
      appendRaw(Data(value.bigEndianBytes))
    }

    mutating func append(_ value: Date) {
      appendRaw(Data(value.timeIntervalSinceReferenceDate.bitPattern.bigEndianBytes))
    }

    mutating func appendOptional(_ value: String?) {
      guard let value else {
        appendRaw(Data([0]))
        return
      }
      appendRaw(Data([1]))
      append(value)
    }

    mutating func appendOptional(_ value: Int?) {
      guard let value else {
        appendRaw(Data([0]))
        return
      }
      appendRaw(Data([1]))
      append(value)
    }

    mutating func finish() -> Data {
      Data(hasher.finalize())
    }

    private mutating func appendLength(_ count: Int) {
      appendRaw(Data(UInt64(count).bigEndianBytes))
    }
  }

  private static func digest(in context: ModelContext) throws -> DigestResult {
    var aggregate = StreamHasher()
    aggregate.append("ClipVault legacy history snapshot v1")

    let clipCount = try count(ClipRecord.self, in: context)
    let folderCount = try count(FolderRecord.self, in: context)
    aggregate.append(clipCount)
    aggregate.append(folderCount)

    var clipOffset = 0
    while true {
      var descriptor = FetchDescriptor<ClipRecord>(sortBy: [SortDescriptor(\.id)])
      descriptor.fetchLimit = batchSize
      descriptor.fetchOffset = clipOffset
      let batch = try context.fetch(descriptor)
      if batch.isEmpty { break }
      for record in batch {
        aggregate.appendRaw(Data([0x43]))
        aggregate.appendRaw(clipDigest(record))
      }
      clipOffset += batch.count
    }

    var folderOffset = 0
    while true {
      var descriptor = FetchDescriptor<FolderRecord>(sortBy: [SortDescriptor(\.id)])
      descriptor.fetchLimit = batchSize
      descriptor.fetchOffset = folderOffset
      let batch = try context.fetch(descriptor)
      if batch.isEmpty { break }
      for record in batch {
        aggregate.appendRaw(Data([0x46]))
        aggregate.appendRaw(folderDigest(record))
      }
      folderOffset += batch.count
    }

    return DigestResult(
      clipCount: clipCount,
      folderCount: folderCount,
      value: "sha256:" + aggregate.finish().map { String(format: "%02x", $0) }.joined()
    )
  }

  private static func count<Model: PersistentModel>(_ type: Model.Type, in context: ModelContext)
    throws -> Int
  {
    try context.fetchCount(FetchDescriptor<Model>())
  }

  private static func clipDigest(_ record: ClipRecord) -> Data {
    var hash = StreamHasher()
    hash.append("ClipRecord-v1")
    hash.append(record.id)
    hash.append(record.createdAt)
    hash.append(record.updatedAt)
    hash.append(record.kindRaw)
    hash.append(record.title)
    hash.append(record.preview)
    hash.append(record.isPinned)
    hash.append(record.collectionIDsRaw)
    hash.append(record.pinboardIDsRaw)
    hash.appendOptional(record.sourceApp)
    hash.append(record.fingerprintValue)
    hash.appendOptional(record.userNote)
    hash.appendOptional(record.tagsRaw)
    hash.appendOptional(record.copyCount)
    hash.append(record.encryptedPayload)
    switch record.encryptedListPayload {
    case .some(let payload):
      hash.appendRaw(Data([1]))
      hash.append(payload)
    case .none:
      hash.appendRaw(Data([0]))
    }
    return hash.finish()
  }

  private static func folderDigest(_ record: FolderRecord) -> Data {
    var hash = StreamHasher()
    hash.append("FolderRecord-v1")
    hash.append(record.id)
    hash.append(record.title)
    hash.appendOptional(record.collectionID)
    hash.appendOptional(record.parentID)
    hash.append(record.createdAt)
    hash.append(record.sortOrder)
    return hash.finish()
  }

  private static func isValidDigest(_ digest: String) -> Bool {
    guard digest.hasPrefix("sha256:") else { return false }
    let bytes = digest.dropFirst("sha256:".count)
    return bytes.count == 64
      && bytes.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0)
      }
  }
}

extension FixedWidthInteger {
  fileprivate var bigEndianBytes: [UInt8] {
    withUnsafeBytes(of: bigEndian) { Array($0) }
  }
}
