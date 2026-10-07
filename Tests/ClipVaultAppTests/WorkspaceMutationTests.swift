import ClipVaultCore
import SwiftData
import Testing
@testable import ClipVault

@Suite("Workspace mutations")
@MainActor
struct WorkspaceMutationTests {
    @Test("sidebar assignment removes the clip from the source collection immediately")
    func sidebarMoveRefreshesSourceAndDestination() throws {
        let (model, store, clip) = try fixture()
        model.selectedCollectionID = "source"
        model.selectedClipID = clip.id

        model.moveSelectedClips(toCollectionID: "destination")

        #expect(model.visibleResults.isEmpty)
        #expect(model.workspaceSections.isEmpty)
        #expect(model.selectedClipID == nil)
        #expect(!model.selectedClipIDs.contains(clip.id))
        model.selectedCollectionID = "destination"
        #expect(model.visibleResults.map(\.id) == [clip.id])
        #expect(try store.allClips().first?.collectionIDs == ["research", "destination"])
        #expect(model.menuBarResults.map(\.id) == [clip.id])
    }

    @Test("moving a batch replaces membership for every selected clip")
    func sidebarMovesWholeSelection() throws {
        let (model, store, first) = try fixture()
        let second = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "Second fixture", extractedText: "Second fixture"),
            sourceApp: "Tests"
        ))
        _ = try store.addClips(ids: [second.id], toCollectionID: "source")
        #expect(model.reload())
        model.selectedCollectionID = "source"
        model.selectedClipIDs = [first.id, second.id]

        model.moveSelectedClips(toCollectionID: "destination")

        #expect(model.visibleResults.isEmpty)
        #expect(model.selectedClipIDs.isEmpty)
        #expect(try store.allClips().allSatisfy { $0.collectionIDs == ["research", "destination"] })
    }

    @Test("blank titles never diverge between the workspace and saved store")
    func blankTitlePreservesSavedTitle() throws {
        let (model, store, clip) = try fixture()

        model.updateTitle(for: clip, title: " \n ")

        #expect(model.selectedClip?.title == clip.title)
        #expect(try store.allClips().first?.title == clip.title)
        #expect(model.captureStatus != "Title saved")
    }

    @Test("mutations without ready storage do not report success or change clips")
    func unavailableStoragePreservesWorkspace() throws {
        let (readyModel, _, clip) = try fixture()
        let model = ClipVaultViewModel(container: readyModel.container, store: nil)
        model.clips = [clip]
        model.selectedClipID = clip.id

        model.updateTitle(for: clip, title: "Unsaved title")
        model.updateNote(for: clip, note: "Unsaved note")
        model.updateTags(for: clip, tagsText: "unsaved")
        model.delete(clip)

        #expect(model.clips == [clip])
        #expect(model.captureStatus == "Storage is not ready. Try again.")
    }

    private func fixture() throws -> (ClipVaultViewModel, InMemoryClipStore, Clip) {
        let schema = Schema([ClipRecord.self, FolderRecord.self])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let store = InMemoryClipStore()
        try store.saveFolder(
            CollectionFolder(title: "Source", collectionID: "source"), parentID: nil, sortOrder: 20
        )
        try store.saveFolder(
            CollectionFolder(title: "Destination", collectionID: "destination"), parentID: nil, sortOrder: 21
        )
        let clip = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "Audit fixture", extractedText: "Audit fixture"),
            sourceApp: "Tests"
        ))
        _ = try store.addClips(ids: [clip.id], toCollectionID: "source")
        let model = ClipVaultViewModel(container: container, store: store)
        #expect(model.reload())
        return (model, store, clip)
    }
}
