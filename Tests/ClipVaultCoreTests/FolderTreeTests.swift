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

    @Test("same-title custom collection IDs stay distinct and readable")
    func sameTitleCustomCollectionIDsStayDistinctAndReadable() throws {
        let firstUUID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let secondUUID = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))

        let firstID = WorkspaceCollectionID.make(for: "Client / Work", uuid: firstUUID)
        let secondID = WorkspaceCollectionID.make(for: "Client / Work", uuid: secondUUID)

        #expect(firstID.hasPrefix("client-work-"))
        #expect(firstID != secondID)
        #expect(!ClipCollection.defaults.contains { $0.id == firstID })
        #expect(!ClipCollection.defaults.contains { $0.id == secondID })
    }

    @Test("distinct custom collection IDs isolate assignment cleanup in both stores")
    func distinctCustomCollectionIDsIsolateAssignmentCleanupInBothStores() throws {
        let inMemoryStore = InMemoryClipStore()
        try assertDistinctCustomCollectionAssignmentsAreIsolated(in: inMemoryStore)

        try withTemporarySwiftDataStore { store in
            try assertDistinctCustomCollectionAssignmentsAreIsolated(in: store)
        }
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

    @Test("both stores reject invalid folder creates without persisting them")
    func bothStoresRejectInvalidFolderCreatesWithoutPersistingThem() throws {
        try assertInvalidFolderCreatesAreRejected(by: InMemoryClipStore())

        try withTemporarySwiftDataStore { store in
            try assertInvalidFolderCreatesAreRejected(by: store)
        }
    }

    @Test("both stores reject non-leaf folder creates without stripping children")
    func bothStoresRejectNonLeafFolderCreates() throws {
        try assertNonLeafFolderCreateIsRejected(by: InMemoryClipStore())

        try withTemporarySwiftDataStore { store in
            try assertNonLeafFolderCreateIsRejected(by: store)
        }
    }

    @Test("recursive deletion retains clips and unrelated assignments in both stores")
    func recursiveDeletionRetainsClipsAndUnrelatedAssignmentsInBothStores() throws {
        let inMemoryStore = InMemoryClipStore()
        let inMemoryClipID = try arrangeRecursiveDeletion(in: inMemoryStore)
        try assertRecursiveDeletionResult(in: inMemoryStore, clipID: inMemoryClipID)

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("ClipVault.sqlite")
        var swiftDataClipID = ""

        try withSwiftDataStore(at: storeURL) { store in
            swiftDataClipID = try arrangeRecursiveDeletion(in: store)
        }

        try withSwiftDataStore(at: storeURL) { reopenedStore in
            try assertRecursiveDeletionResult(in: reopenedStore, clipID: swiftDataClipID)
        }
    }

    @Test("SwiftData default seeding builds one transaction and rolls back a failed save")
    func swiftDataDefaultSeedingBuildsOneTransactionAndRollsBackFailedSave() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try makeSwiftDataContainer(
            at: directory.appendingPathComponent("ClipVault.sqlite")
        )
        let context = ModelContext(container)
        var saveAttempts = 0
        var recordsAtSave = 0
        let store = SwiftDataClipStore(context: context, saveContext: { context in
            saveAttempts += 1
            recordsAtSave = try context.fetch(FetchDescriptor<FolderRecord>()).count
            throw ForcedSaveError()
        })

        #expect(throws: ForcedSaveError()) {
            _ = try store.folders()
        }

        #expect(saveAttempts == 1)
        #expect(recordsAtSave == 1 + ClipCollection.defaults.count)
        #expect(!context.hasChanges)
        #expect(try context.fetch(FetchDescriptor<FolderRecord>()).isEmpty)
    }

    @Test("SwiftData folder mutations roll back failed saves and leave disk unchanged")
    func swiftDataFolderMutationsRollBackFailedSavesAndLeaveDiskUnchanged() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("ClipVault.sqlite")
        var clipID = ""

        try withSwiftDataStore(at: storeURL) { store in
            let parent = CollectionFolder(id: "rollback-parent", title: "Parent")
            let collection = CollectionFolder(
                id: "rollback-collection-folder",
                title: "Collection",
                collectionID: "rollback-collection"
            )
            let clip = try #require(try store.save(
                payload: ClipPayload(kind: .text, displayText: "rollback note", extractedText: "rollback note"),
                sourceApp: "Tests"
            ))
            clipID = clip.id

            try store.saveFolder(parent, parentID: nil, sortOrder: 40)
            try store.saveFolder(collection, parentID: parent.id, sortOrder: 0)
            try store.addClips(ids: [clip.id], toCollectionID: "rollback-collection")
        }

        var saveAttempts = 0
        do {
            let container = try makeSwiftDataContainer(at: storeURL)
            let context = ModelContext(container)
            let failingStore = SwiftDataClipStore(context: context, saveContext: { _ in
                saveAttempts += 1
                throw ForcedSaveError()
            })

            #expect(throws: ForcedSaveError()) {
                try failingStore.updateFolder(
                    id: "rollback-collection-folder",
                    title: "Changed",
                    parentID: nil
                )
            }
            #expect(!context.hasChanges)

            #expect(throws: ForcedSaveError()) {
                try failingStore.saveFolder(
                    CollectionFolder(id: "rollback-created", title: "Created"),
                    parentID: nil,
                    sortOrder: 41
                )
            }
            #expect(!context.hasChanges)

            #expect(throws: ForcedSaveError()) {
                try failingStore.deleteFolder(id: "rollback-parent")
            }
            #expect(!context.hasChanges)
            #expect(saveAttempts == 3)
        }

        try withSwiftDataStore(at: storeURL) { reopenedStore in
            let folders = try reopenedStore.folders()
            let parent = try #require(folders.first { $0.id == "rollback-parent" })
            let collection = try #require(parent.children.first { $0.id == "rollback-collection-folder" })
            #expect(collection.title == "Collection")
            #expect(!containsFolder(id: "rollback-created", in: folders))

            let clip = try #require(try reopenedStore.allClips().first { $0.id == clipID })
            #expect(clip.collectionIDs.contains("rollback-collection"))
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

    private func assertDistinctCustomCollectionAssignmentsAreIsolated(in store: any ClipStoring) throws {
        let firstID = WorkspaceCollectionID.make(
            for: "Client / Work",
            uuid: try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        )
        let secondID = WorkspaceCollectionID.make(
            for: "Client / Work",
            uuid: try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        )
        let firstFolder = CollectionFolder(id: "first-client-folder", title: "Client / Work", collectionID: firstID)
        let secondFolder = CollectionFolder(id: "second-client-folder", title: "Client / Work", collectionID: secondID)
        let clip = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "shared client note", extractedText: "shared client note"),
            sourceApp: "Tests"
        ))

        try store.saveFolder(firstFolder, parentID: nil, sortOrder: 20)
        try store.saveFolder(secondFolder, parentID: nil, sortOrder: 21)
        try store.addClips(ids: [clip.id], toCollectionID: firstID)
        try store.addClips(ids: [clip.id], toCollectionID: secondID)

        try store.deleteFolder(id: firstFolder.id)

        let updatedClip = try #require(try store.allClips().first)
        #expect(!updatedClip.collectionIDs.contains(firstID))
        #expect(updatedClip.collectionIDs.contains(secondID))
        #expect(!containsFolder(id: firstFolder.id, in: try store.folders()))
        #expect(containsFolder(id: secondFolder.id, in: try store.folders()))
    }

    private func assertInvalidFolderCreatesAreRejected(by store: any ClipStoring) throws {
        let parent = CollectionFolder(id: "create-parent", title: "Parent")
        let collectionParent = CollectionFolder(
            id: "create-collection-parent",
            title: "Collection",
            collectionID: "create-collection"
        )
        try store.saveFolder(parent, parentID: nil, sortOrder: 20)
        try store.saveFolder(collectionParent, parentID: nil, sortOrder: 21)

        let blank = CollectionFolder(id: "blank-create", title: "  \n ")
        #expect(throws: FolderStoreError.emptyTitle) {
            try store.saveFolder(blank, parentID: nil, sortOrder: 22)
        }

        let unknownParent = CollectionFolder(id: "unknown-parent-create", title: "Unknown Parent")
        #expect(throws: FolderStoreError.notFound) {
            try store.saveFolder(unknownParent, parentID: "missing-parent", sortOrder: 0)
        }

        let selfParent = CollectionFolder(id: "self-parent-create", title: "Self Parent")
        #expect(throws: FolderStoreError.invalidMove) {
            try store.saveFolder(selfParent, parentID: selfParent.id, sortOrder: 0)
        }

        let collectionChild = CollectionFolder(id: "collection-child-create", title: "Collection Child")
        #expect(throws: FolderStoreError.invalidMove) {
            try store.saveFolder(collectionChild, parentID: collectionParent.id, sortOrder: 0)
        }

        let rejectedIDs = [blank.id, unknownParent.id, selfParent.id, collectionChild.id]
        let folders = try store.folders()
        for rejectedID in rejectedIDs {
            #expect(!containsFolder(id: rejectedID, in: folders))
        }
    }

    private func assertNonLeafFolderCreateIsRejected(by store: any ClipStoring) throws {
        let child = CollectionFolder(id: "nested-create-child", title: "Child")
        let parent = CollectionFolder(
            id: "nested-create-parent",
            title: "Parent",
            children: [child]
        )

        #expect(throws: FolderStoreError.nonLeafCreate) {
            try store.saveFolder(parent, parentID: nil, sortOrder: 22)
        }

        let folders = try store.folders()
        #expect(!containsFolder(id: parent.id, in: folders))
        #expect(!containsFolder(id: child.id, in: folders))
        #expect(parent.children.map(\.id) == [child.id])
    }

    private func arrangeRecursiveDeletion(in store: any ClipStoring) throws -> String {
        let parent = CollectionFolder(id: "recursive-parent", title: "Parent")
        let nested = CollectionFolder(id: "recursive-nested", title: "Nested")
        let removedCollection = CollectionFolder(
            id: "recursive-removed-folder",
            title: "Removed Collection",
            collectionID: "recursive-removed"
        )
        let retainedCollection = CollectionFolder(
            id: "recursive-retained-folder",
            title: "Retained Collection",
            collectionID: "recursive-retained"
        )
        let clip = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "recursive note", extractedText: "recursive note"),
            sourceApp: "Tests"
        ))

        try store.saveFolder(parent, parentID: nil, sortOrder: 30)
        try store.saveFolder(nested, parentID: parent.id, sortOrder: 0)
        try store.saveFolder(removedCollection, parentID: nested.id, sortOrder: 0)
        try store.saveFolder(retainedCollection, parentID: nil, sortOrder: 31)
        try store.addClips(ids: [clip.id], toCollectionID: "recursive-removed")
        try store.addClips(ids: [clip.id], toCollectionID: "recursive-retained")

        try store.deleteFolder(id: parent.id)
        return clip.id
    }

    private func assertRecursiveDeletionResult(in store: any ClipStoring, clipID: String) throws {
        let folders = try store.folders()
        #expect(!containsFolder(id: "recursive-parent", in: folders))
        #expect(!containsFolder(id: "recursive-nested", in: folders))
        #expect(!containsFolder(id: "recursive-removed-folder", in: folders))
        #expect(containsFolder(id: "recursive-retained-folder", in: folders))

        let clip = try #require(try store.allClips().first { $0.id == clipID })
        #expect(!clip.collectionIDs.contains("recursive-removed"))
        #expect(clip.collectionIDs.contains("recursive-retained"))
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
        let container = try makeSwiftDataContainer(at: url)
        let store = SwiftDataClipStore(context: ModelContext(container))
        try body(store)
    }

    private func makeSwiftDataContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema([ClipRecord.self, FolderRecord.self])
        let configuration = ModelConfiguration(
            "FolderTreeTests",
            schema: schema,
            url: url
        )
        return try ModelContainer(for: schema, configurations: [configuration])
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

private struct ForcedSaveError: Error, Equatable {}
