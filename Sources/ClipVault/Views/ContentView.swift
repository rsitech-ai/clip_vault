import ClipVaultCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: ClipVaultViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarAdaptation = WorkspaceSidebarAdaptation()
    @State private var focusState = WorkspaceFocusState()
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

    @ViewBuilder
    private var workspace: some View {
        if focusState.isFocused {
            DetailWorkspaceView(
                model: model,
                isFocused: true,
                toggleFocus: toggleDetailFocus
            )
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(model: model)
                    .navigationSplitViewColumnWidth(min: 160, ideal: 210, max: 280)
            } content: {
                ClipListView(model: model)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 360)
            } detail: {
                DetailWorkspaceView(
                    model: model,
                    isFocused: false,
                    toggleFocus: toggleDetailFocus
                )
                    .navigationSplitViewColumnWidth(min: 420, ideal: 660, max: 1_000)
            }
            .onChange(of: columnVisibility) {
                if isApplyingAutomaticVisibility {
                    isApplyingAutomaticVisibility = false
                } else {
                    focusState.recordManualVisibilityChange(workspaceBrowserVisibility)
                    sidebarAdaptation.recordManualVisibilityChange()
                }
            }
        }
    }

    private func adaptSidebar(to width: CGFloat) {
        guard !focusState.isFocused else {
            return
        }
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

    private var workspaceBrowserVisibility: WorkspaceBrowserVisibility {
        switch columnVisibility {
        case .all:
            .all
        case .doubleColumn:
            .contentAndDetail
        case .detailOnly:
            .detailOnly
        default:
            .contentAndDetail
        }
    }

    private func toggleDetailFocus() {
        isApplyingAutomaticVisibility = true
        if focusState.isFocused {
            columnVisibility = navigationVisibility(for: focusState.restore())
        } else {
            columnVisibility = navigationVisibility(
                for: focusState.enterFocus(from: workspaceBrowserVisibility)
            )
        }
    }

    private func navigationVisibility(
        for visibility: WorkspaceBrowserVisibility
    ) -> NavigationSplitViewVisibility {
        switch visibility {
        case .all:
            .all
        case .contentAndDetail:
            .doubleColumn
        case .detailOnly:
            .detailOnly
        }
    }
}

struct DetailWorkspaceView: View {
    @Bindable var model: ClipVaultViewModel
    var isFocused: Bool
    var toggleFocus: () -> Void

    var body: some View {
        ClipDetailView(
            model: model,
            isFocused: isFocused,
            toggleFocus: toggleFocus
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
