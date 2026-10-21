import Foundation
import SQLite3

/// Preserve the existing encrypted store before adding device-sync entities.
/// SQLite's backup API includes committed WAL contents without copying a live
/// database and its sidecars independently. SwiftData's external encrypted
/// payload directory is preserved too. Call before opening this app's store,
/// after the previous app instance has exited. No payloads are decrypted here.
public enum ClipStoreMigrationBackup {
    private enum Failure: Error { case snapshotUnavailable }

    /// Record only after SwiftData has opened/migrated the live store. The
    /// historical rollback copy must not become a launch dependency forever.
    public static func markCompleted(afterOpening source: URL) throws {
        let marker = source.appendingPathExtension("device-sync-v1-ready")
        try Data("1\n".utf8).write(to: marker, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }

    @discardableResult
    public static func createOnce(beforeOpening source: URL) throws -> URL? {
        let files = FileManager.default
        guard files.fileExists(atPath: source.path) else { return nil }
        if (try? Data(contentsOf: source.appendingPathExtension("device-sync-v1-ready"))) == Data("1\n".utf8) {
            return nil
        }
        let parent = source.deletingLastPathComponent().appendingPathComponent("ClipVaultBackups", isDirectory: true)
        try files.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = parent.appendingPathComponent("BeforeDeviceSync-v1", isDirectory: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        if files.fileExists(atPath: destination.path) {
            try validate(destination)
            return destination
        }
        let staging = parent.appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent(source.lastPathComponent)
        try snapshot(source: source, destination: temporary)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        for name in Set([".\(source.deletingPathExtension().lastPathComponent)_SUPPORT", ".\(source.lastPathComponent)_SUPPORT"]) {
            let assets = source.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
            if files.fileExists(atPath: assets.path) {
                let attributes = try files.attributesOfItem(atPath: assets.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw Failure.snapshotUnavailable }
                try files.copyItem(at: assets, to: staging.appendingPathComponent(name, isDirectory: true))
            }
        }
        try validate(temporary)
        // Publish only a complete, verified snapshot. An existing backup is never
        // replaced, including if another app instance wins the publication race.
        do { try files.moveItem(at: staging, to: directory) }
        catch {
            guard files.fileExists(atPath: destination.path) else { throw error }
            try validate(destination)
        }
        return destination
    }

    private static func connection(_ url: URL, flags: Int32) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw Failure.snapshotUnavailable
        }
        sqlite3_busy_timeout(db, 2_000)
        return db
    }

    private static func snapshot(source: URL, destination: URL) throws {
        let input = try connection(source, flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(input) }
        let output = try connection(destination, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        defer { sqlite3_close(output) }
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else { throw Failure.snapshotUnavailable }
        let copied = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard copied == SQLITE_DONE, finished == SQLITE_OK else { throw Failure.snapshotUnavailable }
    }

    private static func validate(_ url: URL) throws {
        let db = try connection(url, flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK else { throw Failure.snapshotUnavailable }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let result = sqlite3_column_text(statement, 0),
              String(cString: result) == "ok",
              sqlite3_step(statement) == SQLITE_DONE else { throw Failure.snapshotUnavailable }
    }
}
