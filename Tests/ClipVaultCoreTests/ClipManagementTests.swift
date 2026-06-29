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
}
