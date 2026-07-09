import Testing
import Foundation
import SwiftData
@testable import ClipVaultCore

@Suite("Collection folder tree")
struct FolderTreeTests {
    @Test("folders support nested children")
    func nestedFolders() {
        let root = CollectionFolder(
            title: "Projects",
            children: [
                CollectionFolder(
                    title: "ClipVault",
                    children: [CollectionFolder(title: "OCR fixes")]
                )
            ]
        )

        #expect(root.children.first?.title == "ClipVault")
        #expect(root.children.first?.children.first?.path(in: root) == "Projects / ClipVault / OCR fixes")
    }

    @Test("custom folders can be renamed and moved")
    func customFoldersCanBeRenamedAndMoved() throws {
        let store = InMemoryClipStore()
        let archive = CollectionFolder(id: "archive", title: "Archive")
        let clients = CollectionFolder(id: "clients", title: "Clients")

        try store.saveFolder(archive, parentID: Optional<String>.none, sortOrder: 10)
        try store.saveFolder(clients, parentID: nil, sortOrder: 11)

        try store.updateFolder(id: "clients", title: "Customers", parentID: "archive")

        let folders = try store.folders()
        let archiveFolder = try #require(folders.first { $0.id == "archive" })
        let movedFolder = try #require(archiveFolder.children.first { $0.id == "clients" })
        #expect(movedFolder.title == "Customers")
    }

    @Test("deleting a custom folder removes nested collection assignments but keeps clips")
    func deletingCustomFolderRemovesCollectionAssignmentsButKeepsClips() throws {
        let store = InMemoryClipStore()
        let folder = CollectionFolder(id: "client-folder", title: "Client Folder")
        let collection = CollectionFolder(id: "client-alpha-folder", title: "Client Alpha", collectionID: "client-alpha")
        let clip = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "client note", extractedText: "client note"),
            sourceApp: "Tests"
        ))

        try store.saveFolder(folder, parentID: nil, sortOrder: 10)
        try store.saveFolder(collection, parentID: "client-folder", sortOrder: 0)
        try store.addClips(ids: [clip.id], toCollectionID: "client-alpha")

        try store.deleteFolder(id: "client-folder")

        let updatedClip = try #require(try store.allClips().first)
        #expect(updatedClip.id == clip.id)
        #expect(!updatedClip.collectionIDs.contains("client-alpha"))
        #expect(!containsFolder(id: "client-folder", in: try store.folders()))
        #expect(!containsFolder(id: "client-alpha-folder", in: try store.folders()))
    }

    @Test("default workspace folders are protected")
    func defaultWorkspaceFoldersAreProtected() throws {
        let store = InMemoryClipStore()
        let defaultCollection = try #require(try store.folders().first?.children.first)

        #expect(throws: FolderStoreError.protectedFolder) {
            try store.updateFolder(id: defaultCollection.id, title: "Mine", parentID: nil)
        }
        #expect(throws: FolderStoreError.protectedFolder) {
            try store.deleteFolder(id: defaultCollection.id)
        }
    }

    @Test("custom folders can use built-in titles")
    func customFoldersCanUseBuiltInTitles() throws {
        let store = InMemoryClipStore()
        let custom = CollectionFolder(id: "custom-collections", title: "Collections")

        try store.saveFolder(custom, parentID: Optional<String>.none, sortOrder: 99)
        try store.updateFolder(id: custom.id, title: "Client Collections", parentID: nil)
        try store.deleteFolder(id: custom.id)

        #expect(!containsFolder(id: custom.id, in: try store.folders()))
    }

    @Test("SwiftData folder edits persist through the store boundary")
    func swiftDataFolderEditsPersistThroughStoreBoundary() throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self])
        let configuration = ModelConfiguration(
            "FolderTreeTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = SwiftDataClipStore(context: ModelContext(container))
        let archive = CollectionFolder(id: "swiftdata-archive", title: "Archive")
        let client = CollectionFolder(id: "swiftdata-client", title: "Client", collectionID: "swiftdata-client")
        let clip = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "swiftdata note", extractedText: "swiftdata note"),
            sourceApp: "Tests"
        ))

        try store.saveFolder(archive, parentID: nil, sortOrder: 10)
        try store.saveFolder(client, parentID: "swiftdata-archive", sortOrder: 0)
        try store.addClips(ids: [clip.id], toCollectionID: "swiftdata-client")

        try store.updateFolder(id: "swiftdata-client", title: "Client Work", parentID: Optional<String>.none)

        let moved = try #require(try store.folders().first { $0.id == "swiftdata-client" })
        #expect(moved.title == "Client Work")

        try store.deleteFolder(id: "swiftdata-client")

        let updatedClip = try #require(try store.allClips().first)
        #expect(updatedClip.id == clip.id)
        #expect(!updatedClip.collectionIDs.contains("swiftdata-client"))
    }

    private func containsFolder(id: String, in folders: [CollectionFolder]) -> Bool {
        folders.contains { folder in
            folder.id == id || containsFolder(id: id, in: folder.children)
        }
    }
}
