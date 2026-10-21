import AppKit
import Foundation
import SwiftData
import Testing
@testable import ClipVaultCore

@Suite("File attachment boundaries")
struct ClipFileAttachmentTests {
    private func descriptor(size: UInt64 = 104_857_600, filename: String = "report.pdf") -> ClipFileDescriptor {
        ClipFileDescriptor(id: UUID().uuidString.lowercased(), origin: UUID().uuidString.lowercased(),
            filename: filename, size: size, sha256: String(repeating: "a", count: 64),
            chunkCount: UInt32((size + 1_048_575) / 1_048_576), createdAt: 100)
    }

    @Test("100 MiB is a small descriptor and round trips without file bytes or paths")
    func descriptorRoundTrip() throws {
        let file = descriptor()
        let payload = try file.payload()
        #expect(payload.kind == .file)
        #expect(payload.previewData == nil)
        #expect(payload.metadata["paths"] == nil)
        let portable = try ClipSyncPortable(payload: payload, sourceApp: "Finder", capturedAt: Date(timeIntervalSince1970: 100))
        #expect(portable.kind == "attachment")
        #expect(portable.sourceApp == nil) // Typed file frames do not carry the source application.
        #expect(try JSONEncoder().encode(portable).count < 2048)
        #expect(try portable.payloadValue().metadata["file_id"] == file.id)
        #expect(try ClipFileDescriptor.from(payload: portable.payloadValue())?.size == 104_857_600)
    }

    @Test("large and empty files are valid; unrepresentable sizes and malformed descriptors are rejected")
    func validation() throws {
        #expect(try descriptor(size: 0).payload().metadata["file_size"] == "0")
        #expect(try descriptor(filename: "Family 👨‍👩‍👧‍👦.zip").payload().displayText == "Family 👨‍👩‍👧‍👦.zip")
        #expect(try descriptor(size: 104_857_601).payload().metadata["file_size"] == "104857601")
        #expect(try descriptor(size: 2_147_483_648).payload().metadata["file_size"] == "2147483648")
        var unrepresentable = descriptor()
        unrepresentable.size = UInt64.max
        #expect(throws: ClipSyncError.self) { try unrepresentable.payload() }
        for name in ["../secret", "a/b", "a\\b", ".", "..", "", "a\u{0}b", "a\u{85}b"] {
            #expect(throws: ClipSyncError.self) { try descriptor(filename: name).payload() }
        }
        var file = descriptor()
        file.sha256 = "not a hash"
        #expect(throws: ClipSyncError.self) { try file.payload() }
        file = descriptor(); file.chunkCount = 99
        #expect(throws: ClipSyncError.self) { try file.payload() }
        var payload = try descriptor().payload()
        payload.metadata["paths"] = "/private/source.pdf"
        #expect(throws: ClipSyncError.self) { try ClipSyncPortable(payload: payload, sourceApp: nil, capturedAt: Date()) }
    }

    @Test("attachments enter the atomic outbox while legacy path references stay local")
    func outboxAndLegacyReferences() throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self, ClipSyncExportRecord.self, ClipSyncReceiptRecord.self])
        let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true)])
        let store = SwiftDataClipStore(context: ModelContext(container), encryptor: AttachmentTestEncryptor())
        store.sharingEnabled = true
        let first = try #require(try store.save(payload: descriptor().payload(), sourceApp: "Finder", capturedAt: Date()))
        #expect(try store.pendingSyncExports().count == 1)
        #expect(try store.pendingSyncExports()[0].payload.kind == "attachment")
        let export = try #require(try store.pendingSyncExports().first)
        try store.markSyncExported(id: export.id)
        try store.shareExistingClip(id: first.id)
        #expect(try store.pendingSyncExports().isEmpty)
        _ = try store.save(payload: ClipPayload(kind: .file, displayText: "/tmp/legacy.txt", extractedText: "/tmp/legacy.txt",
            metadata: ["paths": "/tmp/legacy.txt"]), sourceApp: nil, capturedAt: Date())
        #expect(try store.pendingSyncExports().isEmpty)
        #expect(try store.allClips().count == 2)
        try store.delete(id: first.id)
        #expect(try store.pendingSyncCancellations().contains(where: { $0.hasPrefix("file:") }))
    }

    @Test("pending preview attachments omit source application without changing identity")
    func previewOutboxCompatibility() throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self, ClipSyncExportRecord.self, ClipSyncReceiptRecord.self])
        let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let store = SwiftDataClipStore(context: context, encryptor: AttachmentTestEncryptor())
        var old = try ClipSyncPortable(payload: descriptor().payload(), sourceApp: nil, capturedAt: Date(timeIntervalSince1970: 100))
        old.sourceApp = "Finder"
        #expect(throws: ClipSyncError.self) { try old.payloadValue() }
        let record = ClipSyncExportRecord(clipID: UUID().uuidString, encryptedPayload: try JSONEncoder().encode(old))
        context.insert(record)
        try context.save()
        let export = try #require(try store.pendingSyncExports().first)
        #expect(export.id == record.id)
        #expect(export.payload.sourceApp == nil)
        #expect(try export.payload.payloadValue().kind == .file)
    }

    @Test("same filenames cannot conflate different attachment contents or legacy paths")
    func distinctFileIdentity() throws {
        let store = InMemoryClipStore()
        let file = descriptor()
        let first = try #require(try store.save(payload: file.payload(), sourceApp: nil, capturedAt: Date()))
        var changed = descriptor(); changed.sha256 = String(repeating: "b", count: 64)
        let second = try #require(try store.save(payload: changed.payload(), sourceApp: nil, capturedAt: Date()))
        #expect(first.id != second.id)
        let legacy = try #require(try store.save(payload: ClipPayload(kind: .file, displayText: "report.pdf", extractedText: "report.pdf"), sourceApp: nil, capturedAt: Date()))
        #expect(legacy.id != first.id)
    }

    @Test("received file descriptors remain local and must match their authenticated origin")
    func importDescriptor() throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self, ClipSyncExportRecord.self, ClipSyncReceiptRecord.self])
        let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true)])
        let store = SwiftDataClipStore(context: ModelContext(container), encryptor: AttachmentTestEncryptor())
        store.sharingEnabled = true
        let file = descriptor()
        let portable = try ClipSyncPortable(payload: file.payload(), sourceApp: "Files", capturedAt: Date(timeIntervalSince1970: 100))
        var event = ClipSyncEvent(id: UUID().uuidString.lowercased(), origin: UUID().uuidString.lowercased(), sequence: 1, clip: portable)
        #expect(throws: ClipSyncError.self) { try store.importSyncEvent(event) }
        #expect(try store.allClips().isEmpty)
        event.origin = file.origin
        let imported = try #require(try store.importSyncEvent(event))
        #expect(imported.kind == .file)
        #expect(imported.metadata["file_id"] == file.id)
        #expect(try store.pendingSyncExports().isEmpty)
    }

    @MainActor
    @Test("an attachment cannot be copied as a fabricated local file path")
    func pasteboardRequiresSave() throws {
        let pasteboard = NSPasteboard(name: .init("ClipVaultAttachmentBoundaryTest"))
        pasteboard.setString("Keep clipboard", forType: .string)
        let writer = ClipPayloadPasteboardWriter(pasteboard: pasteboard)
        #expect(throws: PasteboardWriterError.self) { try writer.write(descriptor().payload()) }
        #expect(pasteboard.string(forType: .string) == "Keep clipboard")
    }
}

private struct AttachmentTestEncryptor: PayloadEncrypting {
    func encrypt(_ data: Data) throws -> Data { data }
    func decrypt(_ data: Data) throws -> Data { data }
}
