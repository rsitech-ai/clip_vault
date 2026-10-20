import Foundation
import SQLite3
import SwiftData
import Testing
@testable import ClipVaultCore

@Model
final class MigrationBackupBlobFixture {
    @Attribute(.externalStorage) var bytes: Data
    init(bytes: Data) { self.bytes = bytes }
}

@Suite("Existing history migration backup")
struct ClipStoreMigrationBackupTests {
    private func execute(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
    }

    private func count(_ url: URL) throws -> Int32 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM receipts", -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CocoaError(.fileReadCorruptFile) }
        return sqlite3_column_int(statement, 0)
    }

    @Test("snapshot includes committed WAL, excludes uncommitted writes, and is never overwritten")
    func walSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("ClipVault.store")
        var db: OpaquePointer?
        #expect(sqlite3_open(source.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try execute(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE receipts(id INTEGER); INSERT INTO receipts VALUES(1); BEGIN; INSERT INTO receipts VALUES(2);")
        let backup = try #require(try ClipStoreMigrationBackup.createOnce(beforeOpening: source))
        #expect(try count(backup) == 1)
        try execute(db, "COMMIT; INSERT INTO receipts VALUES(3);")
        #expect(try count(source) == 3)
        #expect(try ClipStoreMigrationBackup.createOnce(beforeOpening: source) == backup)
        #expect(try count(backup) == 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: backup.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("failed snapshot does not publish a backup; repair allows a later snapshot")
    func failedSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("ClipVault.store")
        try Data("invalid SQLite input".utf8).write(to: source)
        #expect(throws: (any Error).self) { try ClipStoreMigrationBackup.createOnce(beforeOpening: source) }
        try FileManager.default.removeItem(at: source)
        var db: OpaquePointer?
        #expect(sqlite3_open(source.path, &db) == SQLITE_OK)
        try execute(db, "CREATE TABLE receipts(id INTEGER); INSERT INTO receipts VALUES(1)")
        sqlite3_close(db)
        let backup = try #require(try ClipStoreMigrationBackup.createOnce(beforeOpening: source))
        #expect(try count(backup) == 1)
    }

    @Test("a damaged old backup cannot block a healthy store after migration completes")
    func damagedBackupAfterMigration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("ClipVault.store")
        var db: OpaquePointer?
        #expect(sqlite3_open(source.path, &db) == SQLITE_OK)
        try execute(db, "CREATE TABLE receipts(id INTEGER); INSERT INTO receipts VALUES(1)")
        sqlite3_close(db)
        let backup = try #require(try ClipStoreMigrationBackup.createOnce(beforeOpening: source))
        try Data("damaged snapshot".utf8).write(to: backup)
        #expect(throws: (any Error).self) { try ClipStoreMigrationBackup.createOnce(beforeOpening: source) }
        try ClipStoreMigrationBackup.markCompleted(afterOpening: source)
        #expect(try ClipStoreMigrationBackup.createOnce(beforeOpening: source) == nil)
        #expect(try count(source) == 1)
    }

    @Test("a fresh installation creates no backup")
    func noExistingStore() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("ClipVault.store")
        #expect(try ClipStoreMigrationBackup.createOnce(beforeOpening: source) == nil)
        #expect(!FileManager.default.fileExists(atPath: source.deletingLastPathComponent().path))
    }

    @Test("a SwiftData snapshot restores external binary payloads independently of the original store")
    func externalPayload() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Legacy.store")
        let schema = Schema([MigrationBackupBlobFixture.self])
        let payload = Data(repeating: 0x42, count: 2_000_000)
        do {
            let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, url: source)])
            let context = ModelContext(container)
            context.insert(MigrationBackupBlobFixture(bytes: payload))
            try context.save()
        }
        let backup = try #require(try ClipStoreMigrationBackup.createOnce(beforeOpening: source))
        let originals = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix("_SUPPORT") }
        #expect(!originals.isEmpty)
        for original in originals { try files.moveItem(at: original, to: original.appendingPathExtension("held-aside")) }
        let restored = try ModelContainer(for: schema, configurations: [.init(schema: schema, url: backup)])
        let records = try ModelContext(restored).fetch(FetchDescriptor<MigrationBackupBlobFixture>())
        #expect(records.count == 1)
        #expect(records.first?.bytes == payload)
    }
}
