import ClipVaultCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: ClipVaultViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarAdaptation = WorkspaceSidebarAdaptation()
    @State private var isApplyingAutomaticVisibility = false

    var body: some View {
        GeometryReader { proxy in
            workspace
                .task(id: WorkspaceWidthClass(width: proxy.size.width)) {
                    await Task.yield()
                    adaptSidebar(to: proxy.size.width)
                }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search clips")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.toggleCapture()
                } label: {
                    Label(model.isCapturing ? "Pause Capture" : "Start Capture", systemImage: model.isCapturing ? "pause.circle" : "play.circle")
                }
                .help(model.isCapturing ? "Pause clipboard capture" : "Start clipboard capture")

                Button {
                    model.reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh clips from storage")
            }
        }
    }

    private var workspace: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 160, ideal: 210, max: 280)
        } content: {
            ClipListView(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 360)
        } detail: {
            DetailWorkspaceView(model: model)
                .navigationSplitViewColumnWidth(min: 420, ideal: 660, max: 1_000)
        }
        .onChange(of: columnVisibility) {
            if isApplyingAutomaticVisibility {
                isApplyingAutomaticVisibility = false
            } else {
                sidebarAdaptation.recordManualVisibilityChange()
            }
        }
    }

    private func adaptSidebar(to width: CGFloat) {
        guard let target = sidebarAdaptation.update(
            width: width,
            current: workspaceSidebarState
        ) else {
            return
        }

        isApplyingAutomaticVisibility = true
        columnVisibility = target == .all ? .all : .doubleColumn
    }

    private var workspaceSidebarState: WorkspaceSidebarState {
        columnVisibility == .all ? .all : .contentAndDetail
    }
}

struct DetailWorkspaceView: View {
    @Bindable var model: ClipVaultViewModel
    @AppStorage("aiWorkspaceExpanded") private var isAIExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            if isAIExpanded {
                VSplitView {
                    ClipDetailView(model: model)
                        .frame(minHeight: detailMinimumHeight(for: proxy.size), idealHeight: detailIdealHeight(for: proxy.size), maxHeight: .infinity)
                    AIActionPanel(model: model, placement: .inline) {
                        setAIExpanded(false)
                    }
                    .frame(minHeight: aiMinimumHeight(for: proxy.size), idealHeight: aiIdealHeight(for: proxy.size), maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    ClipDetailView(model: model)
                        .frame(maxHeight: .infinity)
                    Divider()
                    AIWorkspaceShelf(model: model) {
                        setAIExpanded(true)
                    }
                    .frame(height: 48)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.selectedClipIDs.count) { previousCount, selectionCount in
            if AIWorkspaceDisclosurePolicy.shouldExpand(
                previousSelectionCount: previousCount,
                selectionCount: selectionCount
            ) {
                setAIExpanded(true)
            }
        }
        .onChange(of: model.isGenerating) { _, isGenerating in
            if AIWorkspaceDisclosurePolicy.shouldExpandForGeneration(isGenerating: isGenerating) {
                setAIExpanded(true)
            }
        }
    }

    private func detailMinimumHeight(for size: CGSize) -> CGFloat {
        size.height < 640 ? 190 : 280
    }

    private func detailIdealHeight(for size: CGSize) -> CGFloat {
        max(detailMinimumHeight(for: size), size.height * 0.46)
    }

    private func aiMinimumHeight(for size: CGSize) -> CGFloat {
        // Preserve the result canvas without crowding compact-height windows.
        size.height < 640 ? 270 : 320
    }

    private func aiIdealHeight(for size: CGSize) -> CGFloat {
        max(aiMinimumHeight(for: size), size.height * 0.50)
    }

    private func setAIExpanded(_ isExpanded: Bool) {
        guard isAIExpanded != isExpanded else { return }
        if reduceMotion {
            isAIExpanded = isExpanded
        } else {
            withAnimation(.easeOut(duration: 0.16)) {
                isAIExpanded = isExpanded
            }
        }
    }
}
