import Testing
@testable import ClipVaultCore

@Suite("Workspace presentation policy")
struct WorkspacePresentationPolicyTests {
    @Test("compact width begins below 1040 points")
    func widthClassesUseTheCompactBreakpoint() {
        #expect(WorkspaceWidthClass(width: 1_039) == .compact)
        #expect(WorkspaceWidthClass(width: 1_040) == .regular)
    }

    @Test("automatically collapsed sidebar restores at regular width")
    func automaticSidebarCollapseRestores() {
        var adaptation = WorkspaceSidebarAdaptation()

        #expect(adaptation.update(width: 900, current: .all) == .contentAndDetail)
        #expect(adaptation.isAutomaticallyCollapsed)
        #expect(adaptation.update(width: 1_200, current: .contentAndDetail) == .all)
        #expect(!adaptation.isAutomaticallyCollapsed)
    }

    @Test("manual sidebar choice prevents automatic restoration")
    func manualSidebarChoiceIsPreserved() {
        var adaptation = WorkspaceSidebarAdaptation()
        #expect(adaptation.update(width: 900, current: .all) == .contentAndDetail)

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
}
