import Testing
@testable import ClipVaultCore

@Suite("Collection folder tree")
struct FolderTreeTests {
    @Test("folders support nested children")
    func nestedFolders() {
        let root = CollectionFolder(
            title: "Projects",
            children: [
                CollectionFolder(
                    title: "ClipVault",
                    children: [CollectionFolder(title: "OCR fixes")]
                )
            ]
        )

        #expect(root.children.first?.title == "ClipVault")
        #expect(root.children.first?.children.first?.path(in: root) == "Projects / ClipVault / OCR fixes")
    }
}
