# Clip Move and Sidebar Drag-and-Drop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user move exactly one clip to a custom collection through a hierarchical menu or by dragging its row onto a sidebar collection.

**Architecture:** Add one transactional `ClipStoring.moveClips` operation that preserves built-in smart memberships and replaces custom memberships. A single view-model method wraps that operation; reusable destination-menu content and sidebar drop handlers both call it. A ClipVault-owned `Transferable` carries only the internal clip ID.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Observation, CoreTransferable, UniformTypeIdentifiers, Swift Testing, macOS 15+

## Global Constraints

- A move replaces all custom collection memberships with exactly one custom destination.
- Built-in kind-derived collection memberships remain unchanged.
- Dragging always moves only the dragged row; AI selection never expands move scope.
- Plain folders and built-in smart collections are invalid destinations.
- The drag payload contains only a ClipVault clip identifier.
- Menu-based moving remains the complete keyboard and accessibility path.
- No new package dependency is permitted.
- Preserve unrelated release-hardening changes already present in the worktree.

---

## File Structure

- `Sources/ClipVaultCore/Services/ClipStore.swift`: store contract, move errors, SwiftData and in-memory transactional implementations.
- `Sources/ClipVaultCore/Models/ClipMovePayload.swift`: validated app-owned transferable containing one clip ID.
- `Sources/ClipVault/App/ClipVaultViewModel.swift`: shared single-clip move entry point and destination-tree projection.
- `Sources/ClipVault/Views/MoveToCollectionMenu.swift`: recursive menu presentation shared by row and detail actions.
- `Sources/ClipVault/Views/ClipListView.swift`: row context-menu action and draggable payload.
- `Sources/ClipVault/Views/ClipDetailView.swift`: detail-toolbar move menu.
- `Sources/ClipVault/Views/SidebarView.swift`: custom-collection drop destinations and target highlighting.
- `Tests/ClipVaultCoreTests/ClipManagementTests.swift`: in-memory move and payload behavior.
- `Tests/ClipVaultCoreTests/FolderTreeTests.swift`: SwiftData parity, invalid-target, persistence, and rollback behavior.
- `docs/production-plan.md`: dated implementation and verification record.

---

### Task 1: Define Exclusive Move Semantics in the Store Contract

**Files:**
- Modify: `Sources/ClipVaultCore/Services/ClipStore.swift:98-112,395-416,842-913`
- Test: `Tests/ClipVaultCoreTests/ClipManagementTests.swift:35-55`

**Interfaces:**
- Produces: `InMemoryClipStore.moveClips(ids:toCollectionID:) throws`
- Produces: `ClipCollectionMoveError: Error, LocalizedError, Equatable`
- Consumes: `ClipCollection.defaults`, `CollectionFolder`, `Clip.collectionIDs`

- [ ] **Step 1: Write the failing in-memory behavior test**

Add a custom folder and two custom collections, assign a text clip to both, then move it:

```swift
@Test("moving a clip replaces custom memberships and preserves smart memberships")
func movingClipReplacesOnlyCustomMemberships() throws {
    let store = InMemoryClipStore()
    let folder = CollectionFolder(id: "work-folder", title: "Work")
    let prompts = CollectionFolder(id: "prompts-folder", title: "Prompts", collectionID: "prompts")
    let archive = CollectionFolder(id: "archive-folder", title: "Archive", collectionID: "archive")
    try store.saveFolder(folder, parentID: nil, sortOrder: 20)
    try store.saveFolder(prompts, parentID: folder.id, sortOrder: 0)
    try store.saveFolder(archive, parentID: folder.id, sortOrder: 1)

    let clip = try #require(try store.save(
        payload: ClipPayload(kind: .text, displayText: "Prompt", extractedText: "Prompt"),
        sourceApp: "Tests"
    ))
    try store.addClips(ids: [clip.id], toCollectionID: "archive")
    try store.addClips(ids: [clip.id], toCollectionID: "prompts")

    try store.moveClips(ids: [clip.id], toCollectionID: "prompts")

    let moved = try #require(try store.allClips().first { $0.id == clip.id })
    #expect(moved.collectionIDs == ["research", "prompts"])
}
```

- [ ] **Step 2: Run the test to verify RED**

Run: `swift test --filter ClipManagementTests.movingClipReplacesOnlyCustomMemberships`

Expected: compilation fails because `InMemoryClipStore` has no `moveClips` member.

- [ ] **Step 3: Add stable errors**

Add beside `FolderStoreError` without changing the `ClipStoring` protocol yet; Task 2 promotes the concrete method into the protocol when SwiftData conformance is implemented:

```swift
public enum ClipCollectionMoveError: Error, LocalizedError, Equatable {
    case noClips
    case clipNotFound
    case destinationNotFound
    case invalidDestination

    public var errorDescription: String? {
        switch self {
        case .noClips: "Choose a clip to move."
        case .clipNotFound: "The clip is no longer available."
        case .destinationNotFound: "The destination collection no longer exists."
        case .invalidDestination: "Choose a custom collection as the destination."
        }
    }
}
```

- [ ] **Step 4: Implement the minimal in-memory move**

Add a recursive destination lookup and the protocol method:

```swift
public func moveClips(ids: [String], toCollectionID collectionID: String) throws {
    let requestedIDs = Set(ids)
    guard !requestedIDs.isEmpty else { throw ClipCollectionMoveError.noClips }

    let destination = collectionID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !destination.isEmpty,
          allFolders(in: storedFolders).contains(where: { $0.collectionID == destination }) else {
        throw ClipCollectionMoveError.destinationNotFound
    }
    guard !ClipCollection.defaults.contains(where: { $0.id == destination }) else {
        throw ClipCollectionMoveError.invalidDestination
    }

    let indexes = clips.indices.filter { requestedIDs.contains(clips[$0].id) }
    guard indexes.count == requestedIDs.count else { throw ClipCollectionMoveError.clipNotFound }
    let builtInIDs = Set(ClipCollection.defaults.map(\.id))

    for index in indexes {
        let preserved = clips[index].collectionIDs.filter { builtInIDs.contains($0) }
        clips[index].collectionIDs = preserved + [destination]
        clips[index].updatedAt = Date()
    }
}
```

- [ ] **Step 5: Verify GREEN and add invalid/idempotent coverage one test at a time**

Run after each added assertion group:

`swift test --filter ClipManagementTests`

Add tests that verify:

```swift
#expect(throws: ClipCollectionMoveError.destinationNotFound) {
    try store.moveClips(ids: [clip.id], toCollectionID: "missing")
}
#expect(throws: ClipCollectionMoveError.invalidDestination) {
    try store.moveClips(ids: [clip.id], toCollectionID: "research")
}
try store.moveClips(ids: [clip.id], toCollectionID: "prompts")
#expect(try store.allClips().first?.collectionIDs.filter { $0 == "prompts" }.count == 1)
```

Expected: all `ClipManagementTests` pass and rejected moves leave memberships unchanged.

- [ ] **Step 6: Commit the store contract slice**

```bash
git add Sources/ClipVaultCore/Services/ClipStore.swift Tests/ClipVaultCoreTests/ClipManagementTests.swift
git commit -m "feat: add exclusive clip collection moves"
```

---

### Task 2: Implement SwiftData Parity and Rollback

**Files:**
- Modify: `Sources/ClipVaultCore/Services/ClipStore.swift:258-293,395-416,674-712`
- Test: `Tests/ClipVaultCoreTests/FolderTreeTests.swift:216-270`

**Interfaces:**
- Consumes: `InMemoryClipStore.moveClips(ids:toCollectionID:) throws`
- Produces: `ClipStoring.moveClips(ids:toCollectionID:) throws`
- Consumes: `ClipCollectionMoveError`
- Produces: SwiftData behavior identical to `InMemoryClipStore`

- [ ] **Step 1: Write the failing SwiftData persistence test**

Create a temporary store with a custom destination, move a clip, reopen the container, and assert the persisted memberships:

```swift
@Test("SwiftData clip moves preserve smart memberships across relaunch")
func swiftDataClipMovePersists() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("ClipVault.sqlite")
    var clipID = ""

    try withSwiftDataStore(at: storeURL) { store in
        let destination = CollectionFolder(
            id: "prompts-folder",
            title: "Prompts",
            collectionID: "prompts"
        )
        try store.saveFolder(destination, parentID: nil, sortOrder: 20)
        let clip = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "Prompt", extractedText: "Prompt"),
            sourceApp: "Tests"
        ))
        clipID = clip.id
        try store.moveClips(ids: [clip.id], toCollectionID: "prompts")
    }

    try withSwiftDataStore(at: storeURL) { store in
        let moved = try #require(try store.allClips().first { $0.id == clipID })
        #expect(moved.collectionIDs == ["research", "prompts"])
    }
}
```

- [ ] **Step 2: Run the persistence test to verify RED**

Run: `swift test --filter FolderTreeTests.swiftDataClipMovePersists`

Expected: test fails because the SwiftData method is not implemented.

- [ ] **Step 3: Implement transactional SwiftData moving**

Add the completed interface to `ClipStoring`, then use the injected save closure so rollback is testable:

```swift
func moveClips(ids: [String], toCollectionID collectionID: String) throws
```

Implement SwiftData conformance:

```swift
public func moveClips(ids: [String], toCollectionID collectionID: String) throws {
    try withFolderRollback {
        let requestedIDs = Set(ids)
        guard !requestedIDs.isEmpty else { throw ClipCollectionMoveError.noClips }

        let destination = collectionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderRecords = try context.fetch(FetchDescriptor<FolderRecord>())
        guard folderRecords.contains(where: { $0.collectionID == destination }) else {
            throw ClipCollectionMoveError.destinationNotFound
        }
        guard !ClipCollection.defaults.contains(where: { $0.id == destination }) else {
            throw ClipCollectionMoveError.invalidDestination
        }

        let records = try context.fetch(FetchDescriptor<ClipRecord>())
            .filter { requestedIDs.contains($0.id) }
        guard records.count == requestedIDs.count else { throw ClipCollectionMoveError.clipNotFound }
        let builtInIDs = Set(ClipCollection.defaults.map(\.id))

        for record in records {
            let preserved = split(record.collectionIDsRaw).filter { builtInIDs.contains($0) }
            record.collectionIDsRaw = (preserved + [destination]).joined(separator: ",")
            record.updatedAt = Date()
        }
        try saveFolderContext(context)
    }
}
```

- [ ] **Step 4: Run the persistence test to verify GREEN**

Run: `swift test --filter FolderTreeTests.swiftDataClipMovePersists`

Expected: PASS after reopening the SQLite store.

- [ ] **Step 5: Add and run the rollback test**

Use the existing failing-save initializer:

```swift
let failingStore = SwiftDataClipStore(context: context, saveContext: { _ in
    throw ForcedSaveError()
})
#expect(throws: ForcedSaveError()) {
    try failingStore.moveClips(ids: [clipID], toCollectionID: "prompts")
}
#expect(!context.hasChanges)
```

Reopen `storeURL` through `withSwiftDataStore` and assert the clip still has its original memberships.

Run: `swift test --filter FolderTreeTests`

Expected: every folder-tree test passes, including disk-state rollback.

- [ ] **Step 6: Commit SwiftData parity**

```bash
git add Sources/ClipVaultCore/Services/ClipStore.swift Tests/ClipVaultCoreTests/FolderTreeTests.swift
git commit -m "test: verify persistent clip moves"
```

---

### Task 3: Add a Private Transferable Clip Identifier

**Files:**
- Create: `Sources/ClipVaultCore/Models/ClipMovePayload.swift`
- Test: `Tests/ClipVaultCoreTests/ClipMovePayloadTests.swift`

**Interfaces:**
- Produces: `ClipMovePayload: Codable, Hashable, Sendable, Transferable`
- Produces: `ClipMovePayload.contentType`
- Consumes: one nonempty `clipID: String`

- [ ] **Step 1: Write the failing payload tests**

```swift
import Foundation
import Testing
@testable import ClipVaultCore

@Suite("Clip move payload")
struct ClipMovePayloadTests {
    @Test("payload round-trips only the clip identifier")
    func payloadRoundTrips() throws {
        let payload = try #require(ClipMovePayload(clipID: "clip-123"))
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ClipMovePayload.self, from: data)

        #expect(decoded == payload)
        #expect(String(decoding: data, as: UTF8.self) == #"{"clipID":"clip-123"}"#)
    }

    @Test("decoding rejects an empty clip identifier")
    func rejectsEmptyIdentifier() {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                ClipMovePayload.self,
                from: Data(#"{"clipID":"   "}"#.utf8)
            )
        }
    }

    @Test("payload rejects oversized and non-ASCII identifiers")
    func rejectsMalformedIdentifiers() {
        #expect(ClipMovePayload(clipID: String(repeating: "a", count: 129)) == nil)
        #expect(ClipMovePayload(clipID: "clip/../../secret") == nil)
        #expect(ClipMovePayload(clipID: "clip-ą") == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify RED**

Run: `swift test --filter ClipMovePayloadTests`

Expected: compilation fails because `ClipMovePayload` does not exist.

- [ ] **Step 3: Implement the transferable**

```swift
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

public struct ClipMovePayload: Codable, Hashable, Sendable, Transferable {
    public static let contentType = UTType(exportedAs: "com.andrzej.ClipVault.clip-move")
    public let clipID: String

    public init?(clipID: String) {
        guard let validated = Self.validated(clipID) else { return nil }
        self.clipID = validated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let clipID = try container.decode(String.self, forKey: .clipID)
        guard let validated = Self.validated(clipID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .clipID,
                in: container,
                debugDescription: "Clip ID is malformed."
            )
        }
        self.clipID = validated
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
    }

    private static func validated(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...128).contains(value.utf8.count) else { return nil }
        let allowedPunctuation: Set<UInt8> = [45, 46, 95]
        guard value.utf8.allSatisfy({ byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || allowedPunctuation.contains(byte)
        }) else { return nil }
        return value
    }
}
```

- [ ] **Step 4: Run payload and full core tests**

Run: `swift test --filter ClipMovePayloadTests && swift test`

Expected: payload tests pass; the full Swift suite remains green.

- [ ] **Step 5: Commit the payload slice**

```bash
git add Sources/ClipVaultCore/Models/ClipMovePayload.swift Tests/ClipVaultCoreTests/ClipMovePayloadTests.swift
git commit -m "feat: add private clip move payload"
```

---

### Task 4: Add the Shared View-Model Move and Hierarchical Menus

**Files:**
- Modify: `Sources/ClipVault/App/ClipVaultViewModel.swift:499-516`
- Create: `Sources/ClipVault/Views/MoveToCollectionMenu.swift`
- Modify: `Sources/ClipVault/Views/ClipListView.swift:44-57`
- Modify: `Sources/ClipVault/Views/ClipDetailView.swift:93-121`

**Interfaces:**
- Produces: `ClipVaultViewModel.moveClip(id:toCollectionID:) -> Bool`
- Produces: `ClipVaultViewModel.moveDestinationFolders: [CollectionFolder]`
- Produces: `MoveToCollectionMenuContent`
- Consumes: `ClipStoring.moveClips(ids:toCollectionID:)`

- [ ] **Step 1: Add destination projection and the single-clip operation**

```swift
var moveDestinationFolders: [CollectionFolder] {
    folders.compactMap(moveDestinationBranch)
}

@discardableResult
func moveClip(id: String, toCollectionID collectionID: String) -> Bool {
    guard let store else {
        captureStatus = "Clip storage is unavailable."
        updateDockTile()
        return false
    }
    guard let destination = collections.first(where: { $0.id == collectionID && !$0.isSmart }) else {
        captureStatus = ClipCollectionMoveError.destinationNotFound.localizedDescription
        updateDockTile()
        return false
    }

    do {
        try store.moveClips(ids: [id], toCollectionID: collectionID)
        reload()
        captureStatus = "Moved to \(destination.title)"
        updateDockTile()
        return true
    } catch {
        Self.logFailure(operation: "move_clip_collection", error: error)
        captureStatus = error.localizedDescription
        updateDockTile()
        return false
    }
}

private func moveDestinationBranch(_ folder: CollectionFolder) -> CollectionFolder? {
    let children = folder.children.compactMap(moveDestinationBranch)
    if let collectionID = folder.collectionID,
       !ClipCollection.defaults.contains(where: { $0.id == collectionID }) {
        return folder
    }
    guard !children.isEmpty else { return nil }
    var branch = folder
    branch.children = children
    return branch
}
```

- [ ] **Step 2: Build reusable recursive menu content**

Create `MoveToCollectionMenuContent` with `clip`, `model`, and a recursive `destination(_:)` view builder. Custom collections use a `Button`; folders use nested `Menu` values. Use `checkmark` for a current custom membership and `tray.full` otherwise:

```swift
Button {
    model.moveClip(id: clip.id, toCollectionID: collectionID)
} label: {
    Label(
        folder.title,
        systemImage: clip.collectionIDs.contains(collectionID) ? "checkmark" : "tray.full"
    )
}
.accessibilityHint("Move this clip to \(folder.title)")
```

The outer menu is disabled when `model.moveDestinationFolders.isEmpty` and exposes the help text `Create a custom collection before moving clips.`

- [ ] **Step 3: Add the row context-menu action**

Insert before Pin/Delete in `ClipListView`:

```swift
Menu("Move to Collection") {
    MoveToCollectionMenuContent(clip: result.clip, model: model)
}
.disabled(model.moveDestinationFolders.isEmpty)
```

- [ ] **Step 4: Add the detail-toolbar action**

Insert beside Copy and Pin in `ClipDetailHeader.actionButtons`:

```swift
Menu {
    MoveToCollectionMenuContent(clip: clip, model: model)
} label: {
    Label("Move", systemImage: "folder")
}
.clipVaultGlassButtonStyle()
.help("Move this clip to a custom collection")
.disabled(model.moveDestinationFolders.isEmpty)
```

- [ ] **Step 5: Build with warnings as errors**

Run: `swift build -c release -Xswiftc -warnings-as-errors`

Expected: Release build succeeds without warnings; menus compile for macOS 15.

- [ ] **Step 6: Commit the shared menu path**

```bash
git add Sources/ClipVault/App/ClipVaultViewModel.swift Sources/ClipVault/Views/MoveToCollectionMenu.swift Sources/ClipVault/Views/ClipListView.swift Sources/ClipVault/Views/ClipDetailView.swift
git commit -m "feat: add move to collection menus"
```

---

### Task 5: Add Single-Clip Drag and Sidebar Drop Targets

**Files:**
- Modify: `Sources/ClipVault/Views/ClipListView.swift:26-62`
- Modify: `Sources/ClipVault/Views/SidebarView.swift:105-180`

**Interfaces:**
- Consumes: `ClipMovePayload`
- Consumes: `ClipVaultViewModel.moveClip(id:toCollectionID:) -> Bool`
- Produces: one-row drag behavior and custom-collection-only drop behavior

- [ ] **Step 1: Make each clip row draggable**

Attach the payload to the rendered `ClipRowView`, not to AI selection state. Add a small `View` helper that applies `.draggable` only when the stored identifier passes `ClipMovePayload` validation, avoiding a force unwrap for legacy data:

```swift
@ViewBuilder
private func draggableClipRow<Content: View>(
    clip: Clip,
    @ViewBuilder content: () -> Content
) -> some View {
    if let payload = ClipMovePayload(clipID: clip.id) {
        content().draggable(payload) {
            Label(clip.title, systemImage: ClipVaultDesign.icon(for: clip.kind))
                .padding(8)
                .clipVaultGlassCapsule(tint: .accentColor.opacity(0.14))
        }
    } else {
        content()
    }
}
```

- [ ] **Step 2: Add destination state and a valid-target branch**

Add to `FolderNodeView`:

```swift
@State private var isMoveDropTargeted = false

private var customCollectionID: String? {
    guard model.canManageWorkspaceFolder(folder),
          let collectionID = folder.collectionID else { return nil }
    return collectionID
}
```

Render the existing managed node with `.dropDestination` only when `customCollectionID` is nonnil. Keep plain folders and built-ins on the unmodified branch.

- [ ] **Step 3: Handle exactly one dragged payload**

```swift
.dropDestination(for: ClipMovePayload.self) { payloads, _ in
    guard let collectionID = customCollectionID,
          payloads.count == 1,
          let payload = payloads.first else {
        return false
    }
    return model.moveClip(id: payload.clipID, toCollectionID: collectionID)
} isTargeted: { isTargeted in
    isMoveDropTargeted = isTargeted
}
```

This code never reads `selectedClipIDs`, which enforces the approved single-row scope.

- [ ] **Step 4: Add non-color-only target feedback**

Apply a rounded highlight to the collection row while targeted and update its accessibility hint:

```swift
.background {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(isMoveDropTargeted ? Color.accentColor.opacity(0.18) : Color.clear)
}
.overlay {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(isMoveDropTargeted ? Color.accentColor : Color.clear, lineWidth: 1)
}
```

When targeted, the accessibility hint is `Drop to move this clip to <collection>`; otherwise retain the existing navigation hint.

- [ ] **Step 5: Run static and full automated verification**

Run:

```bash
./script/test.sh
swift build -c release -Xswiftc -warnings-as-errors
git diff --check
```

Expected: Rust 3/3 and the expanded Swift suite pass; Release build and whitespace check pass.

- [ ] **Step 6: Commit drag and drop**

```bash
git add Sources/ClipVault/Views/ClipListView.swift Sources/ClipVault/Views/SidebarView.swift
git commit -m "feat: move clips with sidebar drag and drop"
```

---

### Task 6: Native Interaction, Persistence, Logs, and Documentation

**Files:**
- Modify: `docs/production-plan.md`

**Interfaces:**
- Consumes: completed menu and drag/drop flows
- Produces: current runtime evidence and durable verification record

- [ ] **Step 1: Rebuild and launch the exact staged app**

Run:

```bash
./script/build_and_run.sh --verify
```

Expected: the staged ClipVault PID matches `captureReadyProcessID` and the user's consent preference is restored after verification.

- [ ] **Step 2: Exercise menu moves with synthetic clips and collections**

Create nested custom collections `Move QA → Source` and `Move QA → Destination`. Use a synthetic clip named `Clip move QA <timestamp>`.

Verify in the running app:

- row context menu shows the hierarchical destination and current checkmark;
- detail toolbar exposes the same move choices;
- moving from Source to Destination removes Source membership;
- All Clips and the automatic smart collection still contain the clip;
- relaunch preserves Destination membership.

- [ ] **Step 3: Exercise single-row drag/drop**

Add the synthetic clip and another clip to AI selection. Drag only the synthetic row onto Destination.

Verify:

- Destination highlights during hover;
- the dragged clip moves;
- the other AI-selected clip does not move;
- Source's filtered list removes the moved row;
- plain folder `Move QA` and built-in smart collections reject the drop.

- [ ] **Step 4: Verify accessibility and keyboard parity**

Inspect the native accessibility tree and verify:

- row and detail **Move to Collection** controls have labels and help;
- hierarchical destinations expose their titles and selected state;
- every drag outcome can be completed from the menu without pointer dragging;
- target feedback retains a textual collection label and a drop hint.

- [ ] **Step 5: Re-run E2E and inspect fresh logs**

Run:

```bash
./script/e2e_smoke.sh
./script/e2e_smoke.sh
```

Then inspect the exact app PID with a bounded unified-log predicate for warning, error, fault, crash, assertion, and `operation_failed` rows.

Expected: both E2E runs pass; no app-owned error/fault or repeated runtime warning is present.

- [ ] **Step 6: Record the evidence and remove synthetic QA data**

Append a dated `2026-07-11` row to `docs/production-plan.md` naming the exact commands, test counts, menu/drag scenarios, persistence result, accessibility result, and log result. Delete only the synthetic `Move QA` clips and folders through confirmed app controls.

- [ ] **Step 7: Run final verification and commit documentation**

Run:

```bash
./script/test.sh
swift test --sanitize=address
swift build -c release -Xswiftc -warnings-as-errors
cargo fmt --manifest-path rust/SearchIndexCore/Cargo.toml -- --check
cargo clippy --manifest-path rust/SearchIndexCore/Cargo.toml --all-targets -- -D warnings
cargo audit --file rust/SearchIndexCore/Cargo.lock
git diff --check
```

Expected: all commands exit zero.

```bash
git add docs/production-plan.md
git commit -m "docs: record clip move verification"
```

---

## Completion Gate

- Every task commit contains only its declared files.
- Both store implementations pass the same move behavior.
- SwiftData rollback and relaunch persistence are proven.
- Context menu, detail menu, and drag/drop call the same view-model operation.
- Drag scope is one clip regardless of AI selection.
- Invalid destinations never mutate membership.
- Full tests, ASan, Release warnings, Rust checks, two E2E runs, native accessibility inspection, and PID-scoped logs are clean.
- No release package, App Store upload, merge, or production tag is performed as part of this feature plan.
