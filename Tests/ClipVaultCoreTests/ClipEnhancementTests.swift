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

    @Test("recopying an existing payload makes it the most recent clip")
    func duplicateSaveRefreshesCaptureRecency() async throws {
        let store = InMemoryClipStore()
        let firstPayload = ClipPayload(
            kind: .text,
            displayText: "recopied payload",
            extractedText: "recopied payload",
            metadata: ["revision": "1"]
        )
        let first = try #require(try store.save(payload: firstPayload, sourceApp: "First App"))
        try await Task.sleep(for: .milliseconds(10))
        _ = try store.save(
            payload: ClipPayload(kind: .text, displayText: "newer payload", extractedText: "newer payload"),
            sourceApp: "Second App"
        )
        try await Task.sleep(for: .milliseconds(10))

        let recopied = try #require(try store.save(
            payload: ClipPayload(
                kind: .text,
                displayText: "recopied payload",
                extractedText: "recopied payload",
                metadata: ["revision": "2"]
            ),
            sourceApp: "Third App"
        ))

        let clips = try store.allClips()
        let storedPayload = try #require(try store.payload(for: first.id))
        #expect(clips.count == 2)
        #expect(recopied.id == first.id)
        #expect(recopied.copyCount == 2)
        #expect(clips.first?.id == first.id)
        #expect(storedPayload.metadata == ["revision": "2"])
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
