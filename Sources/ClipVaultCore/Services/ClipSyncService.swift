import Foundation

@_silgen_name("cv_sync_execute")
private func cv_sync_execute(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> UnsafeMutablePointer<CChar>?
@_silgen_name("cv_sync_free")
private func cv_sync_free(_ value: UnsafeMutablePointer<CChar>?)
@_silgen_name("cv_sync_pause")
private func cv_sync_pause()
@_silgen_name("cv_sync_resume")
private func cv_sync_resume()

public struct ClipSyncMember: Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var publicKey: String
    enum CodingKeys: String, CodingKey { case id, name; case publicKey = "public_key" }
}
public struct ClipSyncPairRequest: Codable, Sendable, Identifiable {
    public var id: String
    public var deviceID: String
    public var words: String
    enum CodingKeys: String, CodingKey { case id, words; case deviceID = "device_id" }
}
public struct ClipSyncStatus: Codable, Sendable {
    public var state: String
    public var deviceID: String
    public var isOwner: Bool
    public var enabled: Bool
    public var pending: Int
    public var rejected: Int
    public var members: [ClipSyncMember]
    public var requests: [ClipSyncPairRequest]
    public init() {
        state = "Sharing off"; deviceID = ""; isOwner = false; enabled = false
        pending = 0; rejected = 0; members = []; requests = []
    }
    enum CodingKeys: String, CodingKey {
        case state, enabled, pending, rejected, members, requests
        case deviceID = "device_id", isOwner = "is_owner"
    }
}
public struct ClipSyncServiceError: Error, LocalizedError, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public protocol ClipSyncServicing: Sendable {
    func pauseImmediately()
    func resumeImmediately()
    func status() async throws -> ClipSyncStatus
    func tick() async throws -> ClipSyncStatus
    func imports() async throws -> [ClipSyncEvent]
    func export(_ record: ClipSyncExport) async throws
    func markApplied(id: String) async throws
    func rejectImport(id: String) async throws
    func cancel(id: String) async throws
    func setEnabled(_ enabled: Bool) async throws
    func create(relay: String, registration: String, name: String) async throws
    func join(code: String, name: String) async throws -> String
    func invite() async throws -> String
    func approve(id: String, words: String) async throws
    func remove(id: String) async throws
    func disconnect() async throws -> Int
    func retryOverflow() async throws -> Int
}

public extension ClipSyncServicing {
    func retryOverflow() async throws -> Int {
        throw ClipSyncServiceError(message: "Retrying local shares is unavailable in this sync engine.")
    }
}

/// Serial background execution keeps SQLite, Keychain, and blocking HTTP off the UI actor.
public final class ClipSyncService: ClipSyncServicing, @unchecked Sendable {
    private let namespace: String
    private let directory: URL
    private let queue = DispatchQueue(label: "com.andrzej.ClipVault.device-sync", qos: .utility)
    public init(namespace: String = Bundle.main.bundleIdentifier ?? "com.andrzej.ClipVault", directory: URL? = nil) {
        self.namespace = namespace
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipVault/DeviceSync", isDirectory: true)
    }

    public func call<Result: Decodable & Sendable, Payload: Encodable & Sendable>(
        _ action: String, payload: Payload, as type: Result.Type
    ) async throws -> Result {
        let input = try JSONEncoder().encode(ClipSyncCommand(namespace: namespace, directory: directory.path, action: action, payload: payload))
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let output = try input.withUnsafeBytes { bytes -> Data in
                        guard let raw = cv_sync_execute(bytes.bindMemory(to: UInt8.self).baseAddress, input.count) else {
                            throw ClipSyncServiceError(message: "The sync engine could not return a response.")
                        }
                        defer { cv_sync_free(raw) }
                        return Data(bytes: raw, count: strlen(raw))
                    }
                    let response = try JSONDecoder().decode(ClipSyncResponse<Result>.self, from: output)
                    guard response.ok, let value = response.value else {
                        throw ClipSyncServiceError(message: response.error ?? "The sync operation failed.")
                    }
                    continuation.resume(returning: value)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func status() async throws -> ClipSyncStatus { try await call("status", payload: [String: String](), as: ClipSyncStatus.self) }
    public func pauseImmediately() { cv_sync_pause() }
    public func resumeImmediately() { cv_sync_resume() }
    public func tick() async throws -> ClipSyncStatus { try await call("tick", payload: [String: String](), as: ClipSyncStatus.self) }
    public func imports() async throws -> [ClipSyncEvent] { try await call("imports", payload: [String: String](), as: [ClipSyncEvent].self) }
    public func export(_ record: ClipSyncExport) async throws {
        struct Capture: Encodable, Sendable { var id: String; var clip: ClipSyncPortable }
        _ = try await call("capture", payload: Capture(id: record.id, clip: record.payload), as: String.self)
    }
    public func markApplied(id: String) async throws { _ = try await call("applied", payload: ["id": id], as: Bool.self) }
    public func rejectImport(id: String) async throws { _ = try await call("reject_import", payload: ["id": id], as: Bool.self) }
    public func cancel(id: String) async throws { _ = try await call("delete", payload: ["id": id], as: Bool.self) }
    public func setEnabled(_ enabled: Bool) async throws { _ = try await call("enable", payload: ["enabled": enabled], as: Bool.self) }
    public func create(relay: String, registration: String, name: String) async throws {
        _ = try await call("create", payload: ["relay": relay, "registration": registration, "name": name], as: Bool.self)
    }
    public func join(code: String, name: String) async throws -> String {
        try await call("join", payload: ["code": code, "name": name], as: String.self)
    }
    public func invite() async throws -> String {
        try await call("invite", payload: [String: String](), as: String.self)
    }
    public func approve(id: String, words: String) async throws {
        _ = try await call("approve", payload: ["id": id, "words": words], as: Bool.self)
    }
    public func disconnect() async throws -> Int {
        try await call("disconnect", payload: [String: String](), as: Int.self)
    }
    public func remove(id: String) async throws {
        _ = try await call("remove", payload: ["id": id], as: Bool.self)
    }
    public func retryOverflow() async throws -> Int {
        try await call("retry_overflow", payload: [String: String](), as: Int.self)
    }
}

private struct ClipSyncCommand<Body: Encodable>: Encodable {
    var namespace: String; var directory: String; var action: String; var payload: Body
}
private struct ClipSyncResponse<Value: Decodable>: Decodable {
    var ok: Bool; var value: Value?; var error: String?
}
