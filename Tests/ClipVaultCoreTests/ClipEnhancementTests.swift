import Testing
@testable import ClipVaultCore

@Suite("Clip enhancement features")
struct ClipEnhancementTests {
    @Test("duplicate saves increment copy count instead of adding clutter")
    func duplicateSaveIncrementsCopyCount() throws {
        let store = InMemoryClipStore()
        let payload = ClipPayload(kind: .text, displayText: "same", extractedText: "same")

        _ = try store.save(payload: payload, sourceApp: "Tests")
        _ = try store.save(payload: payload, sourceApp: "Tests")

        let clips = try store.allClips()
        #expect(clips.count == 1)
        #expect(clips.first?.copyCount == 2)
    }

    @Test("title overrides and tags update clips")
    func titleAndTagsUpdate() throws {
        let store = InMemoryClipStore()
        let clip = try #require(try store.save(
            payload: ClipPayload(kind: .image, displayText: "Image with 8 text lines", extractedText: "ocr"),
            sourceApp: "Tests"
        ))

        try store.updateTitle(id: clip.id, title: "Stripe error screenshot")
        try store.updateTags(id: clip.id, tags: ["stripe", " error ", "stripe"])

        let updated = try #require(try store.allClips().first)
        #expect(updated.title == "Stripe error screenshot")
        #expect(updated.tags == ["error", "stripe"])
    }

    @Test("folders persist through the store boundary")
    func foldersPersist() throws {
        let store = InMemoryClipStore()
        let parent = try #require(try store.folders().first?.id)
        let folder = CollectionFolder(title: "Screenshots")

        try store.saveFolder(folder, parentID: parent, sortOrder: 99)

        let root = try #require(try store.folders().first)
        #expect(root.children.contains { $0.title == "Screenshots" })
    }
}
