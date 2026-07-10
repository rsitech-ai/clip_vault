import ClipVaultCore
import SwiftUI

struct SidebarView: View {
    @Bindable var model: ClipVaultViewModel
    @State private var prompt: SidebarPrompt?
    @State private var deleteCandidate: CollectionFolder?

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("Workspace") {
                    ForEach(model.folders) { folder in
                        FolderNodeView(
                            folder: folder,
                            depth: 0,
                            model: model,
                            prompt: { action in
                                prompt = action
                            },
                            delete: { folder in
                                deleteCandidate = folder
                            }
                        )
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            sidebarFooter
        }
        .sheet(item: $prompt) { request in
            SidebarFolderEditorSheet(model: model, request: request) {
                prompt = nil
            }
        }
        .confirmationDialog(deleteDialogTitle, isPresented: Binding(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } }
        ), titleVisibility: .visible) {
            if let deleteCandidate {
                Button(deleteButtonTitle(for: deleteCandidate), role: .destructive) {
                    model.deleteFolder(deleteCandidate)
                    self.deleteCandidate = nil
                }
            }
            Button("Cancel", role: .cancel) {
                deleteCandidate = nil
            }
        } message: {
            Text("This removes the workspace folder or collection only. Clips stay in ClipVault.")
        }
    }

    private var sidebarFooter: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    prompt = SidebarPrompt(kind: .folder, parentID: nil)
                } label: {
                    Label("Folder", systemImage: "folder.badge.plus")
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                }
                .help("Create a new folder")
                .accessibilityLabel("Create a new folder")
                .accessibilityHint("Opens the new folder form at the workspace root.")

                Button {
                    prompt = SidebarPrompt(kind: .collection, parentID: model.folders.first?.id)
                } label: {
                    Label("Collection", systemImage: "plus")
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                }
                .help("Create a new collection")
                .accessibilityLabel("Create a new collection")
                .accessibilityHint("Opens the new collection form inside Collections.")
            }
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.medium))
            .controlSize(.small)

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
        .clipVaultGlassSurface(cornerRadius: 0)
    }

    private var deleteDialogTitle: String {
        guard let deleteCandidate else {
            return "Remove Workspace Folder?"
        }
        return deleteCandidate.collectionID == nil ? "Remove Folder?" : "Remove Collection?"
    }

    private func deleteButtonTitle(for folder: CollectionFolder) -> String {
        folder.collectionID == nil ? "Remove Folder" : "Remove Collection"
    }
}

private struct FolderNodeView: View {
    var folder: CollectionFolder
    var depth: Int
    @Bindable var model: ClipVaultViewModel
    var prompt: (SidebarPrompt) -> Void
    var delete: (CollectionFolder) -> Void
    @State private var isExpanded = true

    @ViewBuilder
    var body: some View {
        if showsManagementMenu {
            nodeContent.contextMenu {
                folderActions
            }
        } else {
            nodeContent
        }
    }

    private var nodeContent: some View {
        Group {
            if folder.children.isEmpty {
                rowContent
            } else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    ForEach(folder.children) { child in
                        FolderNodeView(folder: child, depth: depth + 1, model: model, prompt: prompt, delete: delete)
                    }
                } label: {
                    rowContent
                }
            }
        }
        .padding(.leading, CGFloat(depth) * 6)
    }

    private var rowContent: some View {
        HStack(spacing: 6) {
            if folder.collectionID == nil && folder.children.isEmpty {
                folderLabel
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Empty folder. Use the Manage menu to add or edit items.")
            } else {
                Button {
                    activateFolder()
                } label: {
                    folderLabel
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(folder.title)
                .accessibilityHint(rowAccessibilityHint)
            }

            if showsManagementMenu {
                Menu {
                    folderActions
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
                .help("Manage \(folder.title)")
                .accessibilityLabel("Manage \(folder.title)")
                .accessibilityHint(managementAccessibilityHint)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var showsManagementMenu: Bool {
        folder.collectionID == nil || model.canManageWorkspaceFolder(folder)
    }

    private var folderLabel: some View {
        Label {
            Text(folder.title)
                .lineLimit(1)
        } icon: {
            Image(systemName: folder.collectionID == nil ? "folder" : "tray.full")
                .foregroundStyle(iconColor)
        }
    }

    private func activateFolder() {
        if let collectionID = folder.collectionID {
            model.selectedCollectionID = collectionID
        } else if !folder.children.isEmpty {
            isExpanded.toggle()
        }
    }

    private var rowAccessibilityHint: String {
        if folder.collectionID != nil {
            return "Show clips in this collection"
        }
        return isExpanded ? "Collapse this folder" : "Expand this folder"
    }

    private var managementAccessibilityHint: String {
        guard model.canManageWorkspaceFolder(folder) else {
            return "Opens actions to add a subfolder or collection."
        }
        if folder.collectionID == nil {
            return "Opens actions to add, edit, or remove this folder."
        }
        return "Opens actions to add clips, edit, or remove this collection."
    }

    @ViewBuilder
    private var folderActions: some View {
        if folder.collectionID == nil {
            Button("New Subfolder") {
                prompt(SidebarPrompt(kind: .folder, parentID: folder.id))
            }
            Button("New Collection") {
                prompt(SidebarPrompt(kind: .collection, parentID: folder.id))
            }
        }
        if model.canManageWorkspaceFolder(folder),
           let collectionID = folder.collectionID {
            Button("Add Selected Clips Here") {
                model.addSelectedClips(toCollectionID: collectionID)
            }
        }
        if model.canManageWorkspaceFolder(folder) {
            Divider()
            Button(folder.collectionID == nil ? "Edit Folder..." : "Edit Collection...") {
                prompt(SidebarPrompt(kind: .edit, parentID: model.parentFolderID(for: folder.id), folder: folder))
            }
            Button(folder.collectionID == nil ? "Remove Folder..." : "Remove Collection...", role: .destructive) {
                delete(folder)
            }
        }
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

private struct SidebarFolderEditorSheet: View {
    @Bindable var model: ClipVaultViewModel
    var request: SidebarPrompt
    var close: () -> Void
    @State private var name: String
    @State private var parentSelectionID: String

    init(model: ClipVaultViewModel, request: SidebarPrompt, close: @escaping () -> Void) {
        self.model = model
        self.request = request
        self.close = close
        _name = State(initialValue: request.initialName)
        _parentSelectionID = State(initialValue: request.parentID ?? FolderParentOption.rootID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.title)
                .font(.headline)

            Form {
                TextField(request.namePrompt, text: $name)

                Picker("Location", selection: $parentSelectionID) {
                    ForEach(parentOptions) { option in
                        Text(option.title)
                            .tag(option.id)
                    }
                }
                .help("Choose where this workspace item should live.")
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", role: .cancel) {
                    close()
                }
                Spacer()
                Button(request.primaryActionTitle) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var parentOptions: [FolderParentOption] {
        model.folderParentOptions(excluding: request.editingFolderID)
    }

    private var selectedParentID: String? {
        parentSelectionID == FolderParentOption.rootID ? nil : parentSelectionID
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        switch request.kind {
        case .folder:
            model.createFolder(title: name, parentFolderID: selectedParentID)
        case .collection:
            model.createCollection(title: name, parentFolderID: selectedParentID)
        case .edit:
            if let folder = request.folder {
                model.updateFolder(id: folder.id, title: name, parentFolderID: selectedParentID)
            }
        }
        close()
    }
}

struct SidebarPrompt: Identifiable {
    enum Kind {
        case folder
        case collection
        case edit
    }

    var id = UUID()
    var kind: Kind
    var parentID: String?
    var folder: CollectionFolder?

    var title: String {
        switch kind {
        case .folder:
            "New Folder"
        case .collection:
            "New Collection"
        case .edit:
            folder?.collectionID == nil ? "Edit Folder" : "Edit Collection"
        }
    }

    var namePrompt: String {
        isCollectionEditor ? "Collection name" : "Folder name"
    }

    var primaryActionTitle: String {
        kind == .edit ? "Update" : "Create"
    }

    var initialName: String {
        folder?.title ?? ""
    }

    var editingFolderID: String? {
        folder?.id
    }

    private var isCollectionEditor: Bool {
        switch kind {
        case .folder:
            false
        case .collection:
            true
        case .edit:
            folder?.collectionID != nil
        }
    }
}
