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
                .navigationSplitViewColumnWidth(min: 160, ideal: 210, max: 280)
        } content: {
            ClipListView(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 360)
        } detail: {
            DetailWorkspaceView(model: model)
                .navigationSplitViewColumnWidth(min: 420, ideal: 660, max: 1_000)
        }
    }
}

struct DetailWorkspaceView: View {
    @Bindable var model: ClipVaultViewModel

    var body: some View {
        GeometryReader { proxy in
            VSplitView {
                ClipDetailView(model: model)
                    .frame(minHeight: detailMinimumHeight(for: proxy.size), idealHeight: detailIdealHeight(for: proxy.size), maxHeight: .infinity)
                AIActionPanel(model: model, placement: .inline)
                    .frame(minHeight: aiMinimumHeight(for: proxy.size), idealHeight: aiIdealHeight(for: proxy.size), maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detailMinimumHeight(for size: CGSize) -> CGFloat {
        size.height < 640 ? 190 : 280
    }

    private func detailIdealHeight(for size: CGSize) -> CGFloat {
        max(detailMinimumHeight(for: size), size.height * 0.46)
    }

    private func aiMinimumHeight(for size: CGSize) -> CGFloat {
        size.height < 640 ? 260 : 320
    }

    private func aiIdealHeight(for size: CGSize) -> CGFloat {
        max(aiMinimumHeight(for: size), size.height * 0.50)
    }
}
