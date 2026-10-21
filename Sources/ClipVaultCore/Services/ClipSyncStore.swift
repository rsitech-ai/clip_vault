import Foundation
import SwiftData

@Model
public final class ClipSyncExportRecord {
    @Attribute(.unique) public var id: String
    public var clipID: String
    @Attribute(.externalStorage) public var encryptedPayload: Data?
    public var cancelled: Bool
    public var failure: String?
    public var retryable: Bool = false
    public init(id: String = UUID().uuidString.lowercased(), clipID: String, encryptedPayload: Data?, failure: String? = nil, retryable: Bool = false) {
        self.id = id; self.clipID = clipID; self.encryptedPayload = encryptedPayload
        self.cancelled = false; self.failure = failure; self.retryable = retryable
    }
}
@Model
public final class ClipSyncReceiptRecord {
    @Attribute(.unique) public var id: String
    public var clipID: String
    public init(id: String, clipID: String) { self.id = id; self.clipID = clipID }
}
public struct ClipSyncExport: Sendable {
    public let id: String
    public let clipID: String
    public let payload: ClipSyncPortable
}
