import Foundation
import SwiftData
import Testing
@testable import ClipVaultCore

@Suite("Generated prompt persistence")
struct GeneratedPromptPersistenceTests {
    @Test("both stores save one encrypted Prompts clip per source")
    func bothStoresSaveGeneratedPromptBatches() throws {
        try assertGeneratedPromptBatch(in: InMemoryClipStore())
        try assertGeneratedPromptBatch(in: makeSwiftDataStoreForGeneratedPromptTests().store)
    }

    @Test("both stores reject an empty batch without mutation")
    func bothStoresRejectEmptyBatches() throws {
        try assertEmptyBatchRejected(by: InMemoryClipStore())
        try assertEmptyBatchRejected(by: makeSwiftDataStoreForGeneratedPromptTests().store)
    }

    @Test("both stores reject a late missing source without publishing earlier drafts")
    func bothStoresRejectMissingSourcesAtomically() throws {
        try assertMissingSourceRejected(by: InMemoryClipStore())
        try assertMissingSourceRejected(by: makeSwiftDataStoreForGeneratedPromptTests().store)
    }

    @Test("both stores reject a late sensitive output without publishing earlier drafts")
    func bothStoresRejectSensitiveOutputsAtomically() throws {
        try assertSensitiveOutputRejected(by: InMemoryClipStore())
        try assertSensitiveOutputRejected(by: makeSwiftDataStoreForGeneratedPromptTests().store)
    }

    @Test("both stores reject blank generated output")
    func bothStoresRejectBlankOutputs() throws {
        try assertBlankOutputRejected(by: InMemoryClipStore())
        try assertBlankOutputRejected(by: makeSwiftDataStoreForGeneratedPromptTests().store)
    }

    @Test("both stores reject output duplicated by an existing clip")
    func bothStoresRejectExistingDuplicateOutputs() throws {
        try assertExistingDuplicateRejected(by: InMemoryClipStore())
        try assertExistingDuplicateRejected(by: makeSwiftDataStoreForGeneratedPromptTests().store)
    }

    @Test("both stores reject duplicate outputs within one batch")
    func bothStoresRejectWithinBatchDuplicateOutputs() throws {
        try assertWithinBatchDuplicateRejected(by: InMemoryClipStore())
        try assertWithinBatchDuplicateRejected(by: makeSwiftDataStoreForGeneratedPromptTests().store)
    }

    @Test("both stores require the canonical Prompts destination")
    func bothStoresRequireCanonicalPromptsDestination() throws {
        try assertPromptsDestinationRequired(
            by: InMemoryClipStore(foldersForTesting: []),
            arrangeImpostor: true
        )
        try assertPromptsDestinationRequired(
            by: makeSwiftDataStoreForGeneratedPromptTests().store,
            arrangeImpostor: false
        )
    }

    @Test("SwiftData inserts the complete encrypted batch once and rolls back a failed save")
    func swiftDataGeneratedPromptSaveRollsBackAtomically() throws {
        let fixture = try makeSwiftDataStoreForGeneratedPromptTests()
        try fixture.store.reconcileWorkspaceDefaults()
        let first = try #require(try fixture.store.save(
            payload: ClipPayload(kind: .text, displayText: "Rollback first", extractedText: "Rollback first"),
            sourceApp: nil
        ))
        let second = try #require(try fixture.store.save(
            payload: ClipPayload(kind: .text, displayText: "Rollback second", extractedText: "Rollback second"),
            sourceApp: nil
        ))
        let before = try fixture.store.allClips()
        let beforeIDs = Set(before.map(\.id))
        let beforePayloads = try Dictionary(uniqueKeysWithValues: before.map { clip in
            (clip.id, try fixture.store.payload(for: clip.id))
        })
        var saveAttempts = 0
        var recordsAtSave = 0
        var insertedIDs: Set<String> = []
        let failingStore = SwiftDataClipStore(
            context: fixture.context,
            encryptor: GeneratedPromptTestEncryptor(),
            saveContext: { context in
                saveAttempts += 1
                let records = try context.fetch(FetchDescriptor<ClipRecord>())
                recordsAtSave = records.count
                insertedIDs = Set(records.map(\.id)).subtracting(beforeIDs)
                throw ForcedGeneratedPromptSaveError()
            },
            previewTransformer: { $0 }
        )

        #expect(throws: ForcedGeneratedPromptSaveError()) {
            try failingStore.saveGeneratedPrompts([
                GeneratedPromptDraft(
                    sourceClipID: first.id,
                    sourceTitle: first.title,
                    enhancedText: "Rollback enhanced first"
                ),
                GeneratedPromptDraft(
                    sourceClipID: second.id,
                    sourceTitle: second.title,
                    enhancedText: "Rollback enhanced second"
                )
            ])
        }

        #expect(saveAttempts == 1)
        #expect(recordsAtSave == before.count + 2)
        #expect(insertedIDs.count == 2)
        #expect(!fixture.context.hasChanges)
        #expect(try failingStore.allClips() == before)
        for (id, payload) in beforePayloads {
            #expect(try failingStore.payload(for: id) == payload)
        }
        for id in insertedIDs {
            #expect(try failingStore.payload(for: id) == nil)
        }
    }

    @Test("SwiftData commits generated prompt ciphertext once with no plaintext details")
    func swiftDataGeneratedPromptDetailsRemainEncrypted() throws {
        let fixture = try makeSwiftDataStoreForGeneratedPromptTests()
        try fixture.store.reconcileWorkspaceDefaults()
        let source = try #require(try fixture.store.save(
            payload: ClipPayload(kind: .text, displayText: "Canonical encrypted source", extractedText: "Canonical encrypted source"),
            sourceApp: nil
        ))
        var saveAttempts = 0
        let countedStore = SwiftDataClipStore(
            context: fixture.context,
            encryptor: GeneratedPromptTestEncryptor(),
            saveContext: { context in
                saveAttempts += 1
                try context.save()
            },
            previewTransformer: { $0 }
        )
        let outputMarker = "Encrypted generated output marker 5CA24810"

        let saved = try #require(try countedStore.saveGeneratedPrompts([
            GeneratedPromptDraft(
                sourceClipID: source.id,
                sourceTitle: "Untrusted title",
                enhancedText: outputMarker
            )
        ]).first)
        let descriptor = FetchDescriptor<ClipRecord>(
            predicate: #Predicate { record in record.id == saved.id }
        )
        let record = try #require(try fixture.context.fetch(descriptor).first)
        let ciphertext = record.encryptedPayload + (record.encryptedListPayload ?? Data())

        #expect(saveAttempts == 1)
        #expect(record.title.isEmpty)
        #expect(record.preview.isEmpty)
        #expect(record.sourceApp == nil)
        #expect(record.userNote == nil)
        #expect(record.tagsRaw == nil)
        #expect(ciphertext.range(of: Data(outputMarker.utf8)) == nil)
        #expect(ciphertext.range(of: Data(saved.title.utf8)) == nil)
        #expect(ciphertext.range(of: Data(source.id.utf8)) == nil)
        #expect(try countedStore.payload(for: saved.id)?.extractedText == outputMarker)
    }

    private func assertGeneratedPromptBatch(in store: any ClipStoring) throws {
        try store.reconcileWorkspaceDefaults()
        let first = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "First", extractedText: "First"),
            sourceApp: nil
        ))
        let second = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "Second", extractedText: "Second"),
            sourceApp: nil
        ))
        let canonicalFirstTitle = "Canonical first title"
        let canonicalSecondTitle = String(repeating: "Long source title ", count: 8)
        try store.updateTitle(id: first.id, title: canonicalFirstTitle)
        try store.updateTitle(id: second.id, title: canonicalSecondTitle)

        let saved = try store.saveGeneratedPrompts([
            GeneratedPromptDraft(
                sourceClipID: first.id,
                sourceTitle: "Untrusted first title",
                enhancedText: "Goal: Improve first"
            ),
            GeneratedPromptDraft(
                sourceClipID: second.id,
                sourceTitle: "Untrusted second title",
                enhancedText: "Goal: Improve second"
            )
        ])

        #expect(saved.count == 2)
        #expect(saved.map(\.title) == [
            String("Enhanced — \(canonicalFirstTitle)".prefix(80)),
            String("Enhanced — \(canonicalSecondTitle)".prefix(80))
        ])
        #expect(saved.allSatisfy { $0.title.count <= 80 })
        #expect(saved.allSatisfy { Set($0.collectionIDs) == ["research", "prompts"] })
        #expect(Set(saved.compactMap { $0.metadata["promptSourceClipID"] }) == [first.id, second.id])
        #expect(saved.allSatisfy { $0.sourceApp == "ClipVault AI" })
        #expect(try saved.allSatisfy { savedClip in
            try store.payload(for: savedClip.id)?.extractedText == savedClip.extractedText
        })
    }

    private func assertEmptyBatchRejected(by store: any ClipStoring) throws {
        try store.reconcileWorkspaceDefaults()
        let before = try store.allClips()

        #expect(throws: GeneratedPromptStoreError.emptyBatch) {
            try store.saveGeneratedPrompts([])
        }

        #expect(try store.allClips() == before)
    }

    private func assertMissingSourceRejected(by store: any ClipStoring) throws {
        try store.reconcileWorkspaceDefaults()
        let source = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "Present", extractedText: "Present"),
            sourceApp: nil
        ))
        let sourcePayload = try store.payload(for: source.id)
        let before = try store.allClips()

        #expect(throws: GeneratedPromptStoreError.sourceMissing("missing-source")) {
            try store.saveGeneratedPrompts([
                GeneratedPromptDraft(
                    sourceClipID: source.id,
                    sourceTitle: source.title,
                    enhancedText: "Valid but must not publish"
                ),
                GeneratedPromptDraft(
                    sourceClipID: "missing-source",
                    sourceTitle: "Missing",
                    enhancedText: "Also must not publish"
                )
            ])
        }

        #expect(try store.allClips() == before)
        #expect(try store.payload(for: source.id) == sourcePayload)
    }

    private func assertSensitiveOutputRejected(by store: any ClipStoring) throws {
        try store.reconcileWorkspaceDefaults()
        let first = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "Safe source", extractedText: "Safe source"),
            sourceApp: nil
        ))
        let second = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "Secret source", extractedText: "Secret source"),
            sourceApp: nil
        ))
        let before = try store.allClips()

        #expect(throws: GeneratedPromptStoreError.rejectedOutput(second.id)) {
            try store.saveGeneratedPrompts([
                GeneratedPromptDraft(
                    sourceClipID: first.id,
                    sourceTitle: first.title,
                    enhancedText: "Safe enhanced output"
                ),
                GeneratedPromptDraft(
                    sourceClipID: second.id,
                    sourceTitle: second.title,
                    enhancedText: "API key: sk-proj-abcdefghijklmnopqrstuvwx"
                )
            ])
        }

        #expect(try store.allClips() == before)
    }

    private func assertBlankOutputRejected(by store: any ClipStoring) throws {
        try store.reconcileWorkspaceDefaults()
        let source = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "Blank output source", extractedText: "Blank output source"),
            sourceApp: nil
        ))
        let before = try store.allClips()

        #expect(throws: GeneratedPromptStoreError.rejectedOutput(source.id)) {
            try store.saveGeneratedPrompts([
                GeneratedPromptDraft(
                    sourceClipID: source.id,
                    sourceTitle: source.title,
                    enhancedText: "  \n\t"
                )
            ])
        }

        #expect(try store.allClips() == before)
    }

    private func assertExistingDuplicateRejected(by store: any ClipStoring) throws {
        try store.reconcileWorkspaceDefaults()
        let source = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "Duplicate source", extractedText: "Duplicate source"),
            sourceApp: nil
        ))
        let existing = try #require(try store.save(
            payload: ClipPayload(
                kind: .text,
                displayText: "Already persisted enhanced output",
                extractedText: "Already persisted enhanced output"
            ),
            sourceApp: nil
        ))
        let existingPayload = try store.payload(for: existing.id)
        let before = try store.allClips()

        #expect(throws: GeneratedPromptStoreError.duplicateOutput(source.id)) {
            try store.saveGeneratedPrompts([
                GeneratedPromptDraft(
                    sourceClipID: source.id,
                    sourceTitle: source.title,
                    enhancedText: "  Already persisted enhanced output\n"
                )
            ])
        }

        #expect(try store.allClips() == before)
        #expect(try store.payload(for: existing.id) == existingPayload)
    }

    private func assertWithinBatchDuplicateRejected(by store: any ClipStoring) throws {
        try store.reconcileWorkspaceDefaults()
        let first = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "First duplicate source", extractedText: "First duplicate source"),
            sourceApp: nil
        ))
        let second = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "Second duplicate source", extractedText: "Second duplicate source"),
            sourceApp: nil
        ))
        let before = try store.allClips()

        #expect(throws: GeneratedPromptStoreError.duplicateOutput(second.id)) {
            try store.saveGeneratedPrompts([
                GeneratedPromptDraft(
                    sourceClipID: first.id,
                    sourceTitle: first.title,
                    enhancedText: "Same generated output"
                ),
                GeneratedPromptDraft(
                    sourceClipID: second.id,
                    sourceTitle: second.title,
                    enhancedText: "\nSame generated output  "
                )
            ])
        }

        #expect(try store.allClips() == before)
    }

    private func assertPromptsDestinationRequired(
        by store: any ClipStoring,
        arrangeImpostor: Bool
    ) throws {
        if arrangeImpostor {
            let root = CollectionFolder(id: "impostor-root", title: "Impostor root")
            try store.saveFolder(root, parentID: nil, sortOrder: 0)
            try store.saveFolder(
                CollectionFolder(
                    id: "impostor-prompts",
                    title: ClipCollection.prompts.title,
                    collectionID: ClipCollection.prompts.id
                ),
                parentID: root.id,
                sortOrder: 0
            )
        }
        let source = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "Orphan source", extractedText: "Orphan source"),
            sourceApp: nil
        ))
        let before = try store.allClips()

        #expect(throws: GeneratedPromptStoreError.promptsUnavailable) {
            try store.saveGeneratedPrompts([
                GeneratedPromptDraft(
                    sourceClipID: source.id,
                    sourceTitle: source.title,
                    enhancedText: "Must not publish without Prompts"
                )
            ])
        }

        #expect(try store.allClips() == before)
    }

    private func makeSwiftDataStoreForGeneratedPromptTests(
        saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> (context: ModelContext, store: SwiftDataClipStore) {
        let schema = Schema([ClipRecord.self, FolderRecord.self])
        let configuration = ModelConfiguration(
            "GeneratedPromptPersistenceTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let store = SwiftDataClipStore(
            context: context,
            encryptor: GeneratedPromptTestEncryptor(),
            saveContext: saveContext,
            previewTransformer: { $0 }
        )
        return (context, store)
    }
}

private struct GeneratedPromptTestEncryptor: PayloadEncrypting {
    private let mask: UInt8 = 0xA5

    func encrypt(_ data: Data) throws -> Data {
        Data(data.map { $0 ^ mask })
    }

    func decrypt(_ data: Data) throws -> Data {
        try encrypt(data)
    }
}

private struct ForcedGeneratedPromptSaveError: Error, Equatable {}
