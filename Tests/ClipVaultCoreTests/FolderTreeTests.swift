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

    @Test("workspace policy uses built-in structure and rebuilds current collection metadata")
    func workspacePolicyUsesStructureAndRebuildsCurrentCollectionMetadata() throws {
        let custom = CollectionFolder(id: "custom-collections", title: "Collections")
        let customCollection = CollectionFolder(
            id: "client-folder",
            title: "Client Alpha",
            collectionID: "client-alpha"
        )
        let renamedCollection = CollectionFolder(
            id: "client-folder",
            title: "Client Work",
            collectionID: "client-alpha"
        )
        let defaultRoot = try #require(CollectionFolder.defaults.first)
        let defaultSmartNode = try #require(defaultRoot.children.first)

        #expect(!WorkspaceFolderPolicy.isProtected(custom))
        #expect(WorkspaceFolderPolicy.isProtected(defaultRoot))
        #expect(WorkspaceFolderPolicy.isProtected(defaultSmartNode))

        let initial = WorkspaceCollectionCatalog.rebuild(from: [customCollection])
        let reloaded = WorkspaceCollectionCatalog.rebuild(from: [renamedCollection])
        let afterDeletion = WorkspaceCollectionCatalog.rebuild(from: [])

        #expect(initial.first { $0.id == "client-alpha" }?.title == "Client Alpha")
        #expect(reloaded.first { $0.id == "client-alpha" }?.title == "Client Work")
        #expect(afterDeletion.contains { $0.id == "client-alpha" } == false)
        #expect(reloaded.first { $0.id == "all" }?.title == "All Clips")
    }

    @Test("both stores reject invalid hierarchy moves and protect built-in nodes")
    func bothStoresRejectInvalidHierarchyMovesAndProtectBuiltInNodes() throws {
        let inMemoryStore = InMemoryClipStore()
        try assertInvalidHierarchyOperationsAreRejected(by: inMemoryStore)
        try assertBuiltInNodesAreProtected(in: inMemoryStore)

        try withTemporarySwiftDataStore { store in
            try assertInvalidHierarchyOperationsAreRejected(by: store)
            try assertBuiltInNodesAreProtected(in: store)
        }
    }

    @Test("custom folders named Collections remain manageable in both stores")
    func customFoldersNamedCollectionsRemainManageableInBothStores() throws {
        let inMemoryStore = InMemoryClipStore()
        try assertCustomCollectionsFolderIsManageable(in: inMemoryStore)

        try withTemporarySwiftDataStore { store in
            try assertCustomCollectionsFolderIsManageable(in: store)
        }
    }

    @Test("SwiftData workspace changes persist after recreating the container")
    func swiftDataWorkspaceChangesPersistAfterRecreatingTheContainer() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("ClipVault.sqlite")
        try withSwiftDataStore(at: storeURL) { store in
            let archive = CollectionFolder(id: "swiftdata-archive", title: "Archive")
            let client = CollectionFolder(id: "swiftdata-client", title: "Client", collectionID: "swiftdata-client")
            let clip = try #require(try store.save(
                payload: ClipPayload(kind: .text, displayText: "swiftdata note", extractedText: "swiftdata note"),
                sourceApp: "Tests"
            ))

            try store.saveFolder(archive, parentID: nil, sortOrder: 10)
            try store.saveFolder(client, parentID: "swiftdata-archive", sortOrder: 0)
            try store.addClips(ids: [clip.id], toCollectionID: "swiftdata-client")
            try store.updateFolder(id: "swiftdata-client", title: "Client Work", parentID: nil)
        }

        try withSwiftDataStore(at: storeURL) { store in
            let moved = try #require(try store.folders().first { $0.id == "swiftdata-client" })
            #expect(moved.title == "Client Work")
            try store.deleteFolder(id: "swiftdata-client")
        }

        try withSwiftDataStore(at: storeURL) { store in
            #expect(!containsFolder(id: "swiftdata-client", in: try store.folders()))
            let updatedClip = try #require(try store.allClips().first)
            #expect(!updatedClip.collectionIDs.contains("swiftdata-client"))
        }
    }

    private func assertCustomCollectionsFolderIsManageable(in store: any ClipStoring) throws {
        let custom = CollectionFolder(id: "custom-collections", title: "Collections")

        try store.saveFolder(custom, parentID: Optional<String>.none, sortOrder: 99)
        try store.updateFolder(id: custom.id, title: "Client Collections", parentID: nil)
        try store.deleteFolder(id: custom.id)

        #expect(!containsFolder(id: custom.id, in: try store.folders()))
    }

    private func assertInvalidHierarchyOperationsAreRejected(by store: any ClipStoring) throws {
        let parent = CollectionFolder(id: "parent", title: "Parent")
        let child = CollectionFolder(id: "child", title: "Child")
        let collection = CollectionFolder(id: "collection", title: "Collection", collectionID: "client-alpha")

        try store.saveFolder(parent, parentID: nil, sortOrder: 20)
        try store.saveFolder(child, parentID: parent.id, sortOrder: 0)
        try store.saveFolder(collection, parentID: nil, sortOrder: 21)

        #expect(throws: FolderStoreError.notFound) {
            try store.updateFolder(id: "missing", title: "Missing", parentID: nil)
        }
        #expect(throws: FolderStoreError.notFound) {
            try store.updateFolder(id: child.id, title: child.title, parentID: "missing-parent")
        }
        #expect(throws: FolderStoreError.invalidMove) {
            try store.updateFolder(id: child.id, title: child.title, parentID: collection.id)
        }
        #expect(throws: FolderStoreError.invalidMove) {
            try store.updateFolder(id: child.id, title: child.title, parentID: child.id)
        }
        #expect(throws: FolderStoreError.invalidMove) {
            try store.updateFolder(id: parent.id, title: parent.title, parentID: child.id)
        }
    }

    private func assertBuiltInNodesAreProtected(in store: any ClipStoring) throws {
        let defaultRoot = try #require(try store.folders().first)
        let defaultSmartNode = try #require(defaultRoot.children.first)

        #expect(throws: FolderStoreError.protectedFolder) {
            try store.updateFolder(id: defaultRoot.id, title: "Renamed root", parentID: nil)
        }
        #expect(throws: FolderStoreError.protectedFolder) {
            try store.deleteFolder(id: defaultRoot.id)
        }
        #expect(throws: FolderStoreError.protectedFolder) {
            try store.updateFolder(id: defaultSmartNode.id, title: "Renamed smart node", parentID: nil)
        }
        #expect(throws: FolderStoreError.protectedFolder) {
            try store.deleteFolder(id: defaultSmartNode.id)
        }
    }

    private func withTemporarySwiftDataStore(_ body: (SwiftDataClipStore) throws -> Void) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try withSwiftDataStore(at: directory.appendingPathComponent("ClipVault.sqlite"), body)
    }

    private func withSwiftDataStore(at url: URL, _ body: (SwiftDataClipStore) throws -> Void) throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self])
        let configuration = ModelConfiguration(
            "FolderTreeTests",
            schema: schema,
            url: url
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = SwiftDataClipStore(context: ModelContext(container))
        try body(store)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipVault-FolderTreeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func containsFolder(id: String, in folders: [CollectionFolder]) -> Bool {
        folders.contains { folder in
            folder.id == id || containsFolder(id: id, in: folder.children)
        }
    }
}
