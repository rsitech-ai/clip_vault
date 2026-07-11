import Foundation
import Testing
@testable import ClipVaultCore

@Suite("Clip management")
struct ClipManagementTests {
    @Test("updates notes attached to a clip")
    func updatesClipNotes() throws {
        let store = InMemoryClipStore()
        let clip = try #require(try store.save(
            payload: ClipPayload(kind: .image, displayText: "Screenshot", extractedText: "error output"),
            sourceApp: "Tests"
        ))

        try store.updateNote(id: clip.id, note: "This screenshot shows the failing build.")

        let updated = try #require(store.allClips().first)
        #expect(updated.userNote == "This screenshot shows the failing build.")
    }

    @Test("deletes clips and their payloads")
    func deletesClips() throws {
        let store = InMemoryClipStore()
        let clip = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "temporary", extractedText: "temporary"),
            sourceApp: "Tests"
        ))

        try store.delete(id: clip.id)

        #expect(try store.allClips().isEmpty)
        #expect(try store.payload(for: clip.id) == nil)
    }

    @Test("assigns selected clips to custom collections without duplicates")
    func assignsClipsToCustomCollections() throws {
        let store = InMemoryClipStore()
        let clip = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "research note", extractedText: "research note"),
            sourceApp: "Tests"
        ))

        try store.addClips(ids: [clip.id], toCollectionID: "client-research")
        try store.addClips(ids: [clip.id], toCollectionID: "client-research")

        let updated = try #require(store.allClips().first)
        #expect(updated.collectionIDs.filter { $0 == "client-research" }.count == 1)
    }

    @Test("moving a clip replaces custom memberships and preserves smart memberships")
    func movingClipReplacesOnlyCustomMemberships() throws {
        let store = InMemoryClipStore()
        let folder = CollectionFolder(id: "work-folder", title: "Work")
        let prompts = CollectionFolder(id: "prompts-folder", title: "Prompts", collectionID: "prompts")
        let archive = CollectionFolder(id: "archive-folder", title: "Archive", collectionID: "archive")
        try store.saveFolder(folder, parentID: nil, sortOrder: 20)
        try store.saveFolder(prompts, parentID: folder.id, sortOrder: 0)
        try store.saveFolder(archive, parentID: folder.id, sortOrder: 1)

        let clip = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "Prompt", extractedText: "Prompt"),
            sourceApp: "Tests"
        ))
        try store.addClips(ids: [clip.id], toCollectionID: "archive")
        try store.addClips(ids: [clip.id], toCollectionID: "prompts")

        try store.moveClips(ids: [clip.id], toCollectionID: "prompts")

        let moved = try #require(try store.allClips().first { $0.id == clip.id })
        #expect(moved.collectionIDs == ["research", "prompts"])
    }

    @Test("moving a clip rejects a missing destination without changing memberships")
    func movingClipRejectsMissingDestination() throws {
        let store = InMemoryClipStore()
        let clip = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "Prompt", extractedText: "Prompt"),
            sourceApp: "Tests"
        ))
        try store.addClips(ids: [clip.id], toCollectionID: "archive")

        #expect(throws: ClipCollectionMoveError.destinationNotFound) {
            try store.moveClips(ids: [clip.id], toCollectionID: "missing")
        }
        #expect(try store.allClips().first?.collectionIDs == ["research", "archive"])
    }

    @Test("moving a clip rejects a built-in destination without changing memberships")
    func movingClipRejectsBuiltInDestination() throws {
        let store = InMemoryClipStore()
        let clip = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "Prompt", extractedText: "Prompt"),
            sourceApp: "Tests"
        ))
        try store.addClips(ids: [clip.id], toCollectionID: "archive")

        #expect(throws: ClipCollectionMoveError.invalidDestination) {
            try store.moveClips(ids: [clip.id], toCollectionID: "research")
        }
        #expect(try store.allClips().first?.collectionIDs == ["research", "archive"])
    }

    @Test("moving a clip to its current custom collection is idempotent")
    func movingClipToCurrentDestinationIsIdempotent() throws {
        let store = InMemoryClipStore()
        let prompts = CollectionFolder(id: "prompts-folder", title: "Prompts", collectionID: "prompts")
        try store.saveFolder(prompts, parentID: nil, sortOrder: 20)
        let clip = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "Prompt", extractedText: "Prompt"),
            sourceApp: "Tests"
        ))

        try store.moveClips(ids: [clip.id], toCollectionID: "prompts")
        try store.moveClips(ids: [clip.id], toCollectionID: "prompts")

        #expect(try store.allClips().first?.collectionIDs.filter { $0 == "prompts" }.count == 1)
    }

    @Test("in-memory clips use the same built-in collection IDs as persistent clips")
    func inMemoryClipsUseBuiltInCollectionIDs() throws {
        let expectedAssignments: [(ClipKind, [String])] = [
            (.code, ["code"]),
            (.sql, ["sql", "code"]),
            (.url, ["links"]),
            (.richText, ["drafts"]),
            (.image, ["images"]),
            (.file, ["files"]),
            (.error, ["errors", "code"]),
            (.text, ["research"]),
            (.unknown, [])
        ]

        for (kind, expectedIDs) in expectedAssignments {
            let store = InMemoryClipStore()
            let clip = try #require(try store.save(
                payload: ClipPayload(
                    kind: kind,
                    displayText: "fixture-\(kind.rawValue)",
                    extractedText: "fixture-\(kind.rawValue)"
                ),
                sourceApp: "Tests"
            ))

            #expect(clip.collectionIDs == expectedIDs)
        }
    }

    @Test("duplicate captures refresh in-memory payload-backed fields")
    func duplicateCapturesRefreshInMemoryPayloadFields() throws {
        let store = InMemoryClipStore()
        _ = try #require(try store.save(
            payload: ClipPayload(
                kind: .image,
                displayText: "First preview",
                extractedText: "stable OCR text",
                metadata: ["revision": "1"],
                previewData: Data([1])
            ),
            sourceApp: "Tests"
        ))

        let duplicate = try #require(try store.save(
            payload: ClipPayload(
                kind: .image,
                displayText: "Updated preview",
                extractedText: "stable OCR text",
                metadata: ["revision": "2"],
                previewData: Data([2])
            ),
            sourceApp: "Tests"
        ))

        #expect(duplicate.copyCount == 2)
        #expect(duplicate.preview == "Updated preview")
        #expect(duplicate.extractedText == "stable OCR text")
        #expect(duplicate.metadata == ["revision": "2"])
        #expect(duplicate.previewData == Data([2]))
    }
}
