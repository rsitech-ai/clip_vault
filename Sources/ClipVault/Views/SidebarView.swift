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
        HStack(spacing: 10) {
            Menu {
                Button {
                    prompt = SidebarPrompt(kind: .folder, parentID: nil)
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }

                Button {
                    prompt = SidebarPrompt(kind: .collection, parentID: model.folders.first?.id)
                } label: {
                    Label("New Collection", systemImage: "tray.full")
                }
            } label: {
                Label("Add", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.button)
            .controlSize(.small)
            .help("Add a folder or collection")
            .accessibilityLabel("Add workspace item")
            .accessibilityHint("Creates a folder or collection.")

            Spacer(minLength: 0)

            Circle()
                .fill(model.isCapturing ? .green : .secondary)
                .frame(width: 8, height: 8)
            Text(compactCaptureStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(model.captureStatus)
        }
        .padding(.horizontal, ClipVaultDesign.compactPadding)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var compactCaptureStatus: String {
        if model.isCapturing {
            return "Capturing"
        }
        return model.hasCaptureConsent ? "Paused" : "Consent"
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
    @State private var isMoveDropTargeted = false

    @ViewBuilder
    var body: some View {
        if let customCollectionID {
            customCollectionDropTarget(collectionID: customCollectionID) {
                nodeContent.contextMenu {
                    folderActions
                }
            }
        } else if showsManagementMenu {
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

    private var customCollectionID: String? {
        guard model.canManageWorkspaceFolder(folder) else { return nil }
        let collectionID = folder.collectionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let collectionID, !collectionID.isEmpty else { return nil }
        return collectionID
    }

    private func customCollectionDropTarget<Content: View>(
        collectionID: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isMoveDropTargeted ? Color.accentColor.opacity(0.16) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(
                        isMoveDropTargeted ? Color.accentColor : Color.clear,
                        lineWidth: 1.5
                    )
            }
            .dropDestination(for: ClipMovePayload.self) { payloads, _ in
                guard payloads.count == 1, let payload = payloads.first else {
                    return false
                }
                return model.moveClip(id: payload.clipID, toCollectionID: collectionID)
            } isTargeted: { isTargeted in
                isMoveDropTargeted = isTargeted
            }
            .accessibilityHint(moveDropAccessibilityHint)
    }

    private var moveDropAccessibilityHint: String {
        if isMoveDropTargeted {
            return "Drop the clip to move it to \(folder.title)."
        }
        return rowAccessibilityHint
    }

    private var folderLabel: some View {
        Label {
            Text(folder.title)
                .lineLimit(1)
        } icon: {
            Image(systemName: folderIconName)
                .foregroundStyle(iconColor)
        }
    }

    private var folderIconName: String {
        if isMoveDropTargeted {
            return "tray.and.arrow.down.fill"
        }
        return folder.collectionID == nil ? "folder" : "tray.full"
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
        folder.collectionID == "errors"
            ? .red
            : folder.collectionID == nil ? .secondary : .accentColor
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
