import Foundation
import SwiftData
import Testing
@testable import ClipVaultCore

@Suite("Clip mutation rollback", .serialized)
@MainActor
struct ClipMutationRollbackTests {
    @Test("failed clip edits leave no pending changes or disk updates", arguments: ["pin", "title", "note", "tags", "delete", "capture", "duplicate"])
    func failedMutationRollsBack(operation: String) throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self])
        let container = try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let healthy = SwiftDataClipStore(context: context, encryptor: PassThroughEncryptor())
        let first = try #require(try healthy.save(
            payload: ClipPayload(kind: .text, displayText: "First fixture", extractedText: "First fixture"),
            sourceApp: "Tests"
        ))
        let second = try #require(try healthy.save(
            payload: ClipPayload(kind: .text, displayText: "Second fixture", extractedText: "Second fixture"),
            sourceApp: "Tests"
        ))
        let original = try healthy.allClips()
        let failing = SwiftDataClipStore(context: context, encryptor: PassThroughEncryptor(), saveContext: { _ in
            throw SimulatedSaveFailure.failed
        })

        #expect(throws: SimulatedSaveFailure.self) {
            switch operation {
            case "pin": _ = try failing.togglePinned(id: first.id)
            case "title": try failing.updateTitle(id: first.id, title: "Changed")
            case "note": try failing.updateNote(id: first.id, note: "Changed")
            case "tags": try failing.updateTags(id: first.id, tags: ["changed"])
            case "capture":
                _ = try failing.save(
                    payload: ClipPayload(kind: .text, displayText: "New fixture", extractedText: "New fixture"),
                    sourceApp: "Tests"
                )
            case "duplicate":
                _ = try failing.save(
                    payload: ClipPayload(kind: .text, displayText: "First fixture", extractedText: "First fixture"),
                    sourceApp: "Tests"
                )
            default: try failing.delete(ids: [first.id, second.id])
            }
        }
        #expect(!context.hasChanges)
        #expect(try healthy.allClips() == original)
        let reopened = SwiftDataClipStore(context: ModelContext(container), encryptor: PassThroughEncryptor())
        #expect(try reopened.allClips() == original)
    }

    @Test("batch delete uses one save and removes only requested clips")
    func batchDeleteCommitsOnce() throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self])
        let container = try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let healthy = SwiftDataClipStore(context: context, encryptor: PassThroughEncryptor())
        let clips = try (0..<4).map { index in
            try #require(try healthy.save(
                payload: ClipPayload(kind: .text, displayText: "Fixture \(index)", extractedText: "Fixture \(index)"),
                sourceApp: "Tests"
            ))
        }
        var saves = 0
        let store = SwiftDataClipStore(context: context, encryptor: PassThroughEncryptor(), saveContext: {
            saves += 1
            try $0.save()
        })
        try store.delete(ids: [clips[0].id, clips[1].id, clips[0].id])
        #expect(saves == 1)
        #expect(Set(try store.allClips().map(\.id)) == [clips[2].id, clips[3].id])
        #expect(saves == 1)
        #expect(!context.hasChanges)
    }
}

private enum SimulatedSaveFailure: Error { case failed }
private struct PassThroughEncryptor: PayloadEncrypting {
    func encrypt(_ data: Data) throws -> Data { data }
    func decrypt(_ data: Data) throws -> Data { data }
}
