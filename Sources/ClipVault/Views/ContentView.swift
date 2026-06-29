import ClipVaultCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: ClipVaultViewModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 160, ideal: 220, max: 300)
        } content: {
            ClipListView(model: model)
                .navigationSplitViewColumnWidth(min: 260, ideal: 360, max: 500)
        } detail: {
            DetailWorkspaceView(model: model)
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
}

struct DetailWorkspaceView: View {
    @Bindable var model: ClipVaultViewModel

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width < 680 {
                VStack(spacing: 0) {
                    ClipDetailView(model: model)
                        .frame(minHeight: 300)
                    Divider()
                    AIActionPanel(model: model)
                        .frame(height: 260)
                }
            } else {
                HSplitView {
                    ClipDetailView(model: model)
                        .frame(minWidth: 300)
                    AIActionPanel(model: model)
                        .frame(minWidth: 240, idealWidth: 320, maxWidth: 420)
                }
            }
        }
    }
}
