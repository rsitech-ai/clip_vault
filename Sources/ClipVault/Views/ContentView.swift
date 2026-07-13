import ClipVaultCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: ClipVaultViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarAdaptation = WorkspaceSidebarAdaptation()
    @State private var isApplyingAutomaticVisibility = false

    var body: some View {
        workspace
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            adaptSidebar(to: width)
        }
        .background {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.055), Color.clear],
                startPoint: .topLeading,
                endPoint: .center
            )
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
        .captureConsentDisclosure(model: model)
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
        Group {
            if isAIExpanded {
                GeometryReader { proxy in
                    let metrics = AIWorkspaceLayoutPolicy.metrics(
                        availableHeight: Double(proxy.size.height)
                    )
                    VSplitView {
                        ClipDetailView(model: model)
                            .frame(
                                minHeight: CGFloat(metrics.detailMinimum),
                                idealHeight: max(CGFloat(metrics.detailMinimum), proxy.size.height * 0.46),
                                maxHeight: .infinity
                            )
                        AIActionPanel(model: model, placement: .inline) {
                            setAIExpanded(false)
                        }
                        .frame(
                            minHeight: CGFloat(metrics.aiMinimum),
                            idealHeight: max(CGFloat(metrics.aiMinimum), proxy.size.height * 0.50),
                            maxHeight: .infinity
                        )
                    }
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
