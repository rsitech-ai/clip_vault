import Testing
@testable import ClipVaultCore

@Suite("Workspace presentation policy")
struct WorkspacePresentationPolicyTests {
    @Test("first reload snapshot exposes reconciled Prompts membership")
    func firstReloadSnapshotExposesReconciledPromptsMembership() throws {
        let legacyCollectionID = "legacy-reload-prompts"
        let store = InMemoryClipStore(foldersForTesting: [
            CollectionFolder(
                id: "legacy-reload-root",
                title: "Collections",
                children: [
                    CollectionFolder(
                        id: "legacy-reload-prompts-node",
                        title: "Prompts",
                        collectionID: legacyCollectionID
                    )
                ]
            )
        ])
        let clip = try #require(try store.save(
            payload: ClipPayload(
                kind: .text,
                displayText: "Legacy prompt",
                extractedText: "Legacy prompt"
            ),
            sourceApp: "Tests"
        ))
        try store.addClips(ids: [clip.id], toCollectionID: legacyCollectionID)

        let snapshot = try WorkspaceReloadSnapshot.load(from: store)

        let reloaded = try #require(snapshot.clips.first { $0.id == clip.id })
        #expect(reloaded.collectionIDs.contains(ClipCollection.prompts.id))
        #expect(!reloaded.collectionIDs.contains(legacyCollectionID))
        #expect(snapshot.folders.flatMap(\.children).contains {
            $0.id == "workspace-default-prompts"
                && $0.collectionID == ClipCollection.prompts.id
        })
    }

    @Test("protected Prompts remains a manual clip drop destination")
    func protectedPromptsAcceptsClipDropsWithoutBecomingManageable() throws {
        let prompts = try #require(CollectionFolder.defaults.first?.children.first {
            $0.collectionID == ClipCollection.prompts.id
        })

        #expect(WorkspaceFolderPolicy.isProtected(prompts))
        #expect(!WorkspaceFolderPolicy.canManage(prompts))
        #expect(
            WorkspaceManualDestinationPolicy.collectionID(
                for: prompts,
                collections: ClipCollection.defaults
            ) == ClipCollection.prompts.id
        )

        let smart = try #require(CollectionFolder.defaults.first?.children.first {
            $0.collectionID == "research"
        })
        #expect(WorkspaceFolderPolicy.isProtected(smart))
        #expect(
            WorkspaceManualDestinationPolicy.collectionID(
                for: smart,
                collections: ClipCollection.defaults
            ) == nil
        )
        #expect(
            ClipCollectionMoveError.invalidDestination.errorDescription
                == "Choose a manual collection as the destination."
        )
    }

    @Test("compact width begins below the reachable 900 point window minimum")
    func widthClassesUseTheCompactBreakpoint() {
        #expect(WorkspaceWidthClass(width: 899) == .compact)
        #expect(WorkspaceWidthClass(width: 900) == .regular)
    }

    @Test("automatically collapsed sidebar restores at regular width")
    func automaticSidebarCollapseRestores() {
        var adaptation = WorkspaceSidebarAdaptation()

        #expect(adaptation.update(width: 899, current: .all) == .contentAndDetail)
        #expect(adaptation.isAutomaticallyCollapsed)
        #expect(adaptation.update(width: 1_200, current: .contentAndDetail) == .all)
        #expect(!adaptation.isAutomaticallyCollapsed)
    }

    @Test("manual sidebar choice prevents automatic restoration")
    func manualSidebarChoiceIsPreserved() {
        var adaptation = WorkspaceSidebarAdaptation()
        #expect(adaptation.update(width: 899, current: .all) == .contentAndDetail)

        adaptation.recordManualVisibilityChange()

        #expect(adaptation.update(width: 1_200, current: .contentAndDetail) == nil)
        #expect(!adaptation.isAutomaticallyCollapsed)
    }

    @Test("AI expands only for a new selection or active generation")
    func aiExpansionTriggersAreIntentional() {
        #expect(AIWorkspaceDisclosurePolicy.shouldExpand(
            previousSelectionCount: 0,
            selectionCount: 1
        ))
        #expect(!AIWorkspaceDisclosurePolicy.shouldExpand(
            previousSelectionCount: 1,
            selectionCount: 2
        ))
        #expect(!AIWorkspaceDisclosurePolicy.shouldExpand(
            previousSelectionCount: 0,
            selectionCount: 0
        ))
        #expect(AIWorkspaceDisclosurePolicy.shouldExpandForGeneration(isGenerating: true))
        #expect(!AIWorkspaceDisclosurePolicy.shouldExpandForGeneration(isGenerating: false))
    }

    @Test("compact AI layout never exceeds its available height")
    func compactAIHeightIsClamped() {
        let metrics = AIWorkspaceLayoutPolicy.metrics(availableHeight: 430)

        #expect(metrics.detailMinimum + metrics.aiMinimum + metrics.dividerAllowance <= 430)
        #expect(metrics.detailMinimum >= 150)
        #expect(metrics.aiMinimum >= 210)
    }

    @Test("regular AI layout keeps comfortable minimums")
    func regularAIHeightKeepsComfortableMinimums() {
        let metrics = AIWorkspaceLayoutPolicy.metrics(availableHeight: 720)

        #expect(metrics.detailMinimum == 280)
        #expect(metrics.aiMinimum == 320)
        #expect(metrics.dividerAllowance == 8)
    }
}
