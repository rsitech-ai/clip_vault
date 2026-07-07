import ClipVaultCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: ClipVaultViewModel

    var body: some View {
        workspace
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
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } content: {
            ClipListView(model: model)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 360)
        } detail: {
            DetailWorkspaceView(model: model)
                .navigationSplitViewColumnWidth(min: 540, ideal: 680, max: 1_000)
        }
    }
}

struct DetailWorkspaceView: View {
    @Bindable var model: ClipVaultViewModel

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width < 540 {
                VSplitView {
                    ClipDetailView(model: model)
                        .frame(minHeight: 260, idealHeight: 460, maxHeight: .infinity)
                    AIActionPanel(model: model)
                        .frame(minHeight: 220, idealHeight: 340, maxHeight: .infinity)
                }
            } else {
                HSplitView {
                    ClipDetailView(model: model)
                        .frame(minWidth: 280)
                    AIActionPanel(model: model)
                        .frame(minWidth: 240, idealWidth: 320, maxWidth: 500)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
