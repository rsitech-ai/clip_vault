import CryptoKit
import Foundation
import SwiftData
import Testing

@testable import ClipVaultCore

private func migrationAuditEncryptor() -> LocalPayloadEncryptor {
  LocalPayloadEncryptor(keyLoader: { SymmetricKey(data: Data(repeating: 0x42, count: 32)) })
}

@Suite("Clip history migration audit", .serialized)
struct ClipHistoryMigrationAuditTests {
  private func treeDigest(at root: URL) throws -> String {
    let files = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.isRegularFileKey])
    var entries: [(String, Data)] = []
    while let url = files?.nextObject() as? URL {
      guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
        continue
      }
      let relative = String(url.path.dropFirst(root.path.count + 1))
      entries.append((relative, Data(SHA256.hash(data: try Data(contentsOf: url)))))
    }
    var canonical = Data()
    for (path, digest) in entries.sorted(by: { $0.0 < $1.0 }) {
      canonical.append(contentsOf: path.utf8)
      canonical.append(0)
      canonical.append(digest)
    }
    return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
  }

  private func schemas() -> (legacy: Schema, current: Schema) {
    (
      Schema([ClipRecord.self, FolderRecord.self]),
      Schema([
        ClipRecord.self, FolderRecord.self, ClipSyncExportRecord.self, ClipSyncReceiptRecord.self,
      ])
    )
  }

  private func makeLegacyBackup() throws -> (root: URL, legacy: URL, backup: URL, ids: [String]) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let legacyURL = root.appendingPathComponent("Legacy.store")
    let ids = ["legacy-text", "legacy-code", "legacy-rtf", "legacy-image"]
    let schema = schemas().legacy
    do {
      let container = try ModelContainer(
        for: schema, configurations: [.init(schema: schema, url: legacyURL)])
      let context = ModelContext(container)
      let store = SwiftDataClipStore(context: context, encryptor: migrationAuditEncryptor())
      store.sharingEnabled = false

      let captured = Date(timeIntervalSince1970: 1_700_000_000)
      let fixtures: [(String, ClipPayload)] = [
        (
          ids[0],
          ClipPayload(
            kind: .text, displayText: "Saved note text", extractedText: "Saved note text",
            metadata: ["origin": "TextEdit"])
        ),
        (
          ids[1],
          ClipPayload(
            kind: .code, displayText: "let answer = 42", extractedText: "let answer = 42",
            metadata: ["language": "swift"])
        ),
        (
          ids[2],
          ClipPayload(
            kind: .richText, displayText: "Rich note", extractedText: "Rich note",
            metadata: ["rtf": Data("{\\rtf1 Rich note}".utf8).base64EncodedString()],
            previewData: Data("{\\rtf1 Rich note}".utf8))
        ),
        (
          ids[3],
          ClipPayload(
            kind: .image, displayText: "Image attachment", extractedText: "",
            metadata: ["format": "fixture"],
            previewData: Data((0..<2_000_000).map { UInt8($0 % 251) }))
        ),
      ]

      for (index, (_, payload)) in fixtures.enumerated() {
        let saved = try #require(
          try store.save(
            payload: payload, sourceApp: "FixtureApp",
            capturedAt: captured.addingTimeInterval(Double(index))))
        #expect(!saved.id.isEmpty)
        if index == 0 {
          _ = try store.save(
            payload: payload, sourceApp: "FixtureApp", capturedAt: captured.addingTimeInterval(10))
        }
      }

      let clips = try store.allClips()
      let textClip = try #require(clips.first(where: { $0.extractedText == "Saved note text" }))
      try store.updateTitle(id: textClip.id, title: "Pinned research note")
      try store.updateNote(id: textClip.id, note: "Private annotation")
      try store.updateTags(id: textClip.id, tags: ["migration", "important"])
      _ = try store.togglePinned(id: textClip.id)
      try store.saveFolder(
        CollectionFolder(
          id: "folder-audit", title: "Research", collectionID: "collection-audit",
          createdAt: captured),
        parentID: nil,
        sortOrder: 7
      )
    }
    let backup = try #require(try ClipStoreMigrationBackup.createOnce(beforeOpening: legacyURL))
    return (root, legacyURL, backup, ids)
  }

  private func makeLegacyPlaintextDetailsBackup() throws -> (root: URL, legacy: URL, backup: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let legacyURL = root.appendingPathComponent("LegacyPlaintext.store")
    let schema = schemas().legacy
    do {
      let container = try ModelContainer(
        for: schema, configurations: [.init(schema: schema, url: legacyURL)])
      let context = ModelContext(container)
      let encryptor = migrationAuditEncryptor()
      let store = SwiftDataClipStore(context: context, encryptor: encryptor)
      store.sharingEnabled = false
      let clip = try #require(
        try store.save(
          payload: ClipPayload(
            kind: .text, displayText: "Encrypted body", extractedText: "Encrypted body"),
          sourceApp: "Captured app",
          capturedAt: Date(timeIntervalSince1970: 1_700_000_100)))
      let record = try #require(
        context.fetch(FetchDescriptor<ClipRecord>(predicate: #Predicate { $0.id == clip.id })).first
      )
      record.encryptedListPayload = nil
      record.title = "Legacy plaintext title"
      record.preview = "Legacy plaintext preview"
      record.sourceApp = "Legacy plaintext source"
      record.userNote = "Legacy plaintext note"
      record.tagsRaw = "legacy,plaintext"

      let encodedLegacyClip = try #require(
        try store.save(
          payload: ClipPayload(
            kind: .code, displayText: "Legacy list payload", extractedText: "Legacy list payload"),
          sourceApp: "Legacy editor",
          capturedAt: Date(timeIntervalSince1970: 1_700_000_101)))
      let encodedRecord = try #require(
        context.fetch(
          FetchDescriptor<ClipRecord>(predicate: #Predicate { $0.id == encodedLegacyClip.id })
        ).first)
      let legacyList = ClipPayload(
        kind: .code, displayText: "Legacy list payload", extractedText: "Legacy list payload",
        metadata: ["legacy-list": "retained"])
      encodedRecord.encryptedListPayload = try encryptor.encrypt(JSONEncoder().encode(legacyList))

      let fallbackClip = try #require(
        try store.save(
          payload: ClipPayload(
            kind: .text, displayText: "Fallback body", extractedText: "Fallback body"),
          sourceApp: "Captured fallback app",
          capturedAt: Date(timeIntervalSince1970: 1_700_000_102)))
      let fallbackRecord = try #require(
        context.fetch(
          FetchDescriptor<ClipRecord>(predicate: #Predicate { $0.id == fallbackClip.id })
        ).first)
      fallbackRecord.encryptedListPayload = try encryptor.encrypt(
        Data("unreadable detail payload".utf8))
      fallbackRecord.title = "Fallback plaintext title"
      fallbackRecord.preview = "Fallback plaintext preview"
      fallbackRecord.sourceApp = "Fallback plaintext source"
      fallbackRecord.userNote = "Fallback plaintext note"
      fallbackRecord.tagsRaw = "fallback,legacy"
      try context.save()
    }
    let backup = try #require(try ClipStoreMigrationBackup.createOnce(beforeOpening: legacyURL))
    return (root, legacyURL, backup)
  }

  @Test("legacy snapshot verifies exact fields and external payloads after current-schema open")
  func verifiesPreservedLegacyStore() throws {
    let fixture = try makeLegacyBackup()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let backupDigestBefore = try treeDigest(at: fixture.backup.deletingLastPathComponent())
    let before = try ClipHistoryMigrationAudit.snapshot(legacyStore: fixture.backup)
    #expect(try treeDigest(at: fixture.backup.deletingLastPathComponent()) == backupDigestBefore)

    let (legacy, current) = schemas()
    #expect(legacy.entities.count == 2)
    let container = try ModelContainer(
      for: current, configurations: [.init(schema: current, url: fixture.legacy)])
    let context = ModelContext(container)
    let receipt = try ClipHistoryMigrationAudit.verify(snapshot: before, in: context)

    #expect(receipt.clipCount == before.clipCount)
    #expect(receipt.folderCount == before.folderCount)
    #expect(receipt.digest == before.digest)
    #expect(receipt.clipCount == fixture.ids.count)

    let store = SwiftDataClipStore(context: context, encryptor: migrationAuditEncryptor())
    let clips = try store.allClips()
    #expect(clips.count == fixture.ids.count)
    #expect(
      clips.contains(where: {
        $0.userNote == "Private annotation" && Set($0.tags) == Set(["migration", "important"])
          && $0.isPinned
      }))
    let image = try #require(clips.first(where: { $0.kind == .image }))
    #expect(
      try store.payload(for: image.id)?.previewData == Data((0..<2_000_000).map { UInt8($0 % 251) })
    )
    #expect(
      try store.payload(for: clips.first(where: { $0.kind == .richText })!.id)?.previewData
        == Data("{\\rtf1 Rich note}".utf8))
    #expect(
      try store.folders().contains(where: { $0.id == "folder-audit" && $0.title == "Research" }))
  }

  @Test("changed or missing legacy rows fail verification")
  func mismatchFailsVerification() throws {
    let fixture = try makeLegacyBackup()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try ClipHistoryMigrationAudit.snapshot(legacyStore: fixture.backup)
    let (_, current) = schemas()

    do {
      let container = try ModelContainer(
        for: current, configurations: [.init(schema: current, url: fixture.legacy)])
      let context = ModelContext(container)
      let clip = try #require(try context.fetch(FetchDescriptor<ClipRecord>()).first)
      clip.copyCount = (clip.copyCount ?? 0) + 100
      try context.save()
      #expect(throws: (any Error).self) {
        try ClipHistoryMigrationAudit.verify(snapshot: snapshot, in: context)
      }
    }

    let second = try makeLegacyBackup()
    defer { try? FileManager.default.removeItem(at: second.root) }
    let secondSnapshot = try ClipHistoryMigrationAudit.snapshot(legacyStore: second.backup)
    let container = try ModelContainer(
      for: current, configurations: [.init(schema: current, url: second.legacy)])
    let context = ModelContext(container)
    let clip = try #require(try context.fetch(FetchDescriptor<ClipRecord>()).first)
    context.delete(clip)
    try context.save()
    #expect(throws: (any Error).self) {
      try ClipHistoryMigrationAudit.verify(snapshot: secondSnapshot, in: context)
    }
  }

  @Test("corrupted external encrypted payload changes the verified history digest")
  func externalPayloadCorruptionFailsVerification() throws {
    let fixture = try makeLegacyBackup()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try ClipHistoryMigrationAudit.snapshot(legacyStore: fixture.backup)

    let externalDirectory = fixture.legacy.deletingLastPathComponent()
      .appendingPathComponent(".Legacy_SUPPORT/_EXTERNAL_DATA", isDirectory: true)
    let externalFiles = try FileManager.default.contentsOfDirectory(
      at: externalDirectory, includingPropertiesForKeys: nil)
    let payloadFile = try #require(
      externalFiles.first(where: { !$0.lastPathComponent.hasSuffix(".interim") }))
    var bytes = try Data(contentsOf: payloadFile)
    #expect(!bytes.isEmpty)
    bytes[bytes.startIndex] ^= 0x01
    try bytes.write(to: payloadFile, options: .atomic)

    let (_, current) = schemas()
    let container = try ModelContainer(
      for: current, configurations: [.init(schema: current, url: fixture.legacy)])
    let context = ModelContext(container)
    #expect(throws: (any Error).self) {
      try ClipHistoryMigrationAudit.verify(snapshot: snapshot, in: context)
    }
  }

  @Test("pre-marker readability check leaves legacy plaintext details and audit digest unchanged")
  func pureReadabilityCheckPreservesLegacyDetails() throws {
    let fixture = try makeLegacyPlaintextDetailsBackup()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try ClipHistoryMigrationAudit.snapshot(legacyStore: fixture.backup)

    let (_, current) = schemas()
    let container = try ModelContainer(
      for: current, configurations: [.init(schema: current, url: fixture.legacy)])
    let context = ModelContext(container)
    let store = SwiftDataClipStore(context: context, encryptor: migrationAuditEncryptor())
    #expect(try ClipHistoryMigrationAudit.verify(snapshot: snapshot, in: context).clipCount == 3)
    #expect(try store.verifyReadableHistoryForMigration() == 3)
    #expect(!context.hasChanges)
    #expect(
      try ClipHistoryMigrationAudit.verify(snapshot: snapshot, in: context).digest
        == snapshot.digest)
  }
}
