import ClipVaultCore
import SwiftUI

struct SidebarView: View {
    @Bindable var model: ClipVaultViewModel
    @State private var draftName = ""
    @State private var prompt: SidebarPrompt?

    var body: some View {
        List {
            Section("Workspace") {
                ForEach(model.folders) { folder in
                    FolderNodeView(folder: folder, depth: 0, model: model) { action in
                        draftName = ""
                        prompt = action
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        draftName = ""
                        prompt = SidebarPrompt(kind: .folder, parentID: nil)
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    .help("Create a new folder")
                    .accessibilityLabel("Create a new folder")
                    Button {
                        draftName = ""
                        prompt = SidebarPrompt(kind: .collection, parentID: model.folders.first?.id)
                    } label: {
                        Label("New Collection", systemImage: "plus")
                    }
                    .help("Create a new collection")
                    .accessibilityLabel("Create a new collection")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)

                HStack(spacing: 8) {
                    Circle()
                        .fill(model.isCapturing ? .green : .secondary)
                        .frame(width: 8, height: 8)
                    Text(model.captureStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .alert(prompt?.title ?? "New", isPresented: Binding(
            get: { prompt != nil },
            set: { if !$0 { prompt = nil } }
        )) {
            TextField("Name", text: $draftName)
            Button("Create") {
                if prompt?.kind == .folder {
                    model.createFolder(title: draftName, parentFolderID: prompt?.parentID)
                } else {
                    model.createCollection(title: draftName, parentFolderID: prompt?.parentID)
                }
                prompt = nil
            }
            Button("Cancel", role: .cancel) {
                prompt = nil
            }
        }
    }

}

private struct FolderNodeView: View {
    var folder: CollectionFolder
    var depth: Int
    @Bindable var model: ClipVaultViewModel
    var prompt: (SidebarPrompt) -> Void

    var body: some View {
        DisclosureGroup(isExpanded: .constant(depth < 1 || !folder.children.isEmpty)) {
            ForEach(folder.children) { child in
                FolderNodeView(folder: child, depth: depth + 1, model: model, prompt: prompt)
            }
        } label: {
            Button {
                if let collectionID = folder.collectionID {
                    model.selectedCollectionID = collectionID
                }
            } label: {
                Label {
                    Text(folder.title)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: folder.collectionID == nil ? "folder" : "tray.full")
                        .foregroundStyle(iconColor)
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("New Subfolder") {
                    prompt(SidebarPrompt(kind: .folder, parentID: folder.id))
                }
                Button("New Collection") {
                    prompt(SidebarPrompt(kind: .collection, parentID: folder.id))
                }
                if let collectionID = folder.collectionID {
                    Button("Add Selected Clips Here") {
                        model.addSelectedClips(toCollectionID: collectionID)
                    }
                }
            }
        }
        .padding(.leading, CGFloat(depth) * 6)
    }

    private var iconColor: Color {
        switch folder.collectionID {
        case "code", "sql": .blue
        case "errors": .red
        case "links": .teal
        case "images": .pink
        default: .secondary
        }
    }
}

struct SidebarPrompt: Identifiable {
    enum Kind {
        case folder
        case collection
    }

    var id = UUID()
    var kind: Kind
    var parentID: String?

    var title: String {
        kind == .folder ? "New Folder" : "New Collection"
    }
}
