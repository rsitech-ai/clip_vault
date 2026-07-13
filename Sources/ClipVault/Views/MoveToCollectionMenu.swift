import ClipVaultCore
import SwiftUI

struct MoveToCollectionMenu: View {
    var clip: Clip
    @Bindable var model: ClipVaultViewModel
    var label: String

    var body: some View {
        Menu {
            MoveToCollectionMenuContent(
                folders: model.moveDestinationFolders,
                clip: clip,
                moveClip: model.moveClip
            )
        } label: {
            Label(label, systemImage: ClipVaultDesign.moveIcon)
        }
        .disabled(model.moveDestinationFolders.isEmpty)
        .help(
            model.moveDestinationFolders.isEmpty
                ? "Create a custom collection before moving clips."
                : "Move only this clip to a custom collection."
        )
        .accessibilityLabel(label)
        .accessibilityHint(
            model.moveDestinationFolders.isEmpty
                ? "Create a custom collection before moving clips."
                : "Choose a custom collection for this clip."
        )
    }
}

private struct MoveToCollectionMenuContent: View {
    var folders: [CollectionFolder]
    var clip: Clip
    var moveClip: (String, String) -> Bool
    var path: [String] = []

    var body: some View {
        ForEach(folders) { folder in
            destination(for: folder)
        }
    }

    @ViewBuilder
    private func destination(for folder: CollectionFolder) -> some View {
        let destinationPath = path + [folder.title]
        let spokenPath = destinationPath.joined(separator: ", ")

        if let collectionID = folder.collectionID {
            let isCurrentDestination = clip.collectionIDs.contains(collectionID)
            Button {
                _ = moveClip(clip.id, collectionID)
            } label: {
                Label(
                    folder.title,
                    systemImage: isCurrentDestination ? "checkmark" : "folder"
                )
            }
            .accessibilityLabel(spokenPath)
            .accessibilityValue(isCurrentDestination ? "Current collection" : "")
            .accessibilityHint("Move only this clip to \(spokenPath).")
            .accessibilityAddTraits(isCurrentDestination ? .isSelected : [])
        } else {
            Menu {
                MoveToCollectionMenuContent(
                    folders: folder.children,
                    clip: clip,
                    moveClip: moveClip,
                    path: destinationPath
                )
            } label: {
                Label(folder.title, systemImage: "folder")
            }
            .accessibilityLabel(spokenPath)
            .accessibilityHint("Open nested collection destinations.")
        }
    }
}
