# On-Device Prompt Enhancer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an on-device Enhance Prompt action that creates one validated prompt per source clip and atomically saves the batch to a protected default Prompts collection.

**Architecture:** Add protected manual-collection semantics and additive workspace reconciliation at the storage boundary, then add atomic generated-prompt persistence. Keep generation in a focused `PromptEnhancing` service with a deterministic validator and sequential batch runner; the app view model owns task lifecycle and SwiftUI renders the resulting states.

**Tech Stack:** Swift 6.3, SwiftUI, SwiftData, Apple Foundation Models, Swift Testing, SwiftPM, existing Rust SearchIndexCore, shell verification scripts, macOS 27 runtime verification.

## Global Constraints

- Support macOS 15+ and availability-gate Apple Foundation Models at macOS 26+.
- Generate one enhanced prompt per source clip; never combine selected clips.
- Use Apple Foundation Models on-device only. Add no OpenAI SDK, API key, network entitlement, cloud fallback, analytics, or clipboard-content transmission.
- Preserve every source clip and current selection. Generate and validate the full batch before one atomic persistence call.
- On unavailability, cancellation, generation, validation, encryption, duplicate, or persistence failure, save zero generated prompts and name the failed source without exposing prompt text.
- Prompts uses canonical collection ID `prompts`; its node is protected, but its membership is manual and valid for menu and drag/drop moves.
- Generated text uses existing encrypted payload/list-detail storage and sensitive-content rules.
- Preserve the eight historical untracked `audits/` directories. Do not push, merge, upload, revoke consent, or delete real clips.

---

### Task 1: Protected Manual Prompts Collection And Workspace Reconciliation

**Files:**
- Modify: `Sources/ClipVaultCore/Models/Clip.swift:163-242`
- Modify: `Sources/ClipVaultCore/Services/ClipStore.swift:96-250,330-760,899-1190`
- Modify: `Tests/ClipVaultCoreTests/FolderTreeTests.swift`

**Interfaces:**
- Produces: `ClipCollection.prompts`, `ClipCollection.smartCollectionIDs`, and `ClipStoring.reconcileWorkspaceDefaults()`.
- Produces: canonical folder node ID `workspace-default-prompts` and manual destination semantics used by Tasks 2, 4, and 5.
- Consumes: existing `WorkspaceFolderPolicy`, `CollectionFolder.defaults`, and store rollback paths.

- [ ] **Step 1: Add failing default and move-semantics tests**

Add tests that require one protected manual Prompts collection and distinguish smart from manual memberships:

```swift
@Test("Prompts is a protected default manual collection")
func promptsIsProtectedDefaultManualCollection() throws {
    let prompts = try #require(ClipCollection.defaults.first { $0.id == "prompts" })
    #expect(prompts.title == "Prompts")
    #expect(prompts.systemImage == "text.quote")
    #expect(!prompts.isSmart)

    let node = try #require(CollectionFolder.defaults.first?.children.first {
        $0.collectionID == "prompts"
    })
    #expect(WorkspaceFolderPolicy.isProtected(node))
}

@Test("moving between manual collections removes Prompts but preserves smart membership")
func movingOutOfPromptsUsesManualMembershipSemantics() throws {
    let store = InMemoryClipStore()
    let destination = CollectionFolder(
        id: "client-folder",
        title: "Client",
        collectionID: "client"
    )
    try store.saveFolder(destination, parentID: CollectionFolder.defaults[0].id, sortOrder: 20)
    let clip = try #require(try store.save(
        payload: ClipPayload(kind: .text, displayText: "Prompt", extractedText: "Prompt"),
        sourceApp: nil
    ))
    try store.addClips(ids: [clip.id], toCollectionID: "prompts")

    try store.moveClips(ids: [clip.id], toCollectionID: "client")

    let moved = try #require(try store.allClips().first { $0.id == clip.id })
    #expect(Set(moved.collectionIDs) == ["research", "client"])
}
```

- [ ] **Step 2: Add failing reconciliation tests for both stores**

Create legacy fixtures with a custom `Prompts` collection and clips assigned to it. Require `reconcileWorkspaceDefaults()` to produce one canonical node, transfer membership, remove only duplicate nodes, remain idempotent, and roll back a forced SwiftData save failure.

Add this exact internal fixture initializer to `InMemoryClipStore` so tests can install a legacy folder tree without expanding public API:

```swift
init(
    foldersForTesting: [CollectionFolder],
    sensitiveRules: SensitiveRuleEngine = .default,
    index: any SearchIndexing = RustSearchIndexCore()
) {
    self.storedFolders = foldersForTesting
    self.sensitiveRules = sensitiveRules
    self.index = index
}
```

```swift
@Test("legacy Prompts collections merge into the protected canonical collection")
func legacyPromptsCollectionsAreAdopted() throws {
    let legacy = CollectionFolder(
        id: "legacy-prompts-node",
        title: " prompts ",
        collectionID: "legacy-prompts"
    )
    let store = InMemoryClipStore(foldersForTesting: [
        CollectionFolder(id: "legacy-root", title: "Collections", children: [legacy])
    ])
    let clip = try #require(try store.save(
        payload: ClipPayload(kind: .text, displayText: "Draft", extractedText: "Draft"),
        sourceApp: nil
    ))
    try store.addClips(ids: [clip.id], toCollectionID: "legacy-prompts")

    try store.reconcileWorkspaceDefaults()
    try store.reconcileWorkspaceDefaults()

    let promptNodes = flattenForTesting(try store.folders()).filter { $0.collectionID == "prompts" }
    #expect(promptNodes.count == 1)
    #expect(!flattenForTesting(try store.folders()).contains { $0.id == legacy.id })
    let migrated = try #require(try store.allClips().first { $0.id == clip.id })
    #expect(migrated.collectionIDs.contains("prompts"))
    #expect(!migrated.collectionIDs.contains("legacy-prompts"))
}
```

- [ ] **Step 3: Run the focused suite and verify RED**

Run: `swift test --filter FolderTreeTests`

Expected: compile failures for missing `ClipCollection.prompts`, `reconcileWorkspaceDefaults()`, and the legacy-fixture initializer.

- [ ] **Step 4: Add canonical collection and smart/manual helpers**

Add the exact collection and stable folder identifiers inside the existing `ClipCollection` declaration (extensions cannot add stored static properties):

```swift
public static let prompts = ClipCollection(
    id: "prompts",
    title: "Prompts",
    systemImage: "text.quote",
    kind: nil,
    isSmart: false
)

public static var smartCollectionIDs: Set<String> {
    Set(defaults.filter(\.isSmart).map(\.id))
}
```

Append `.prompts` to `ClipCollection.defaults`, and create its default folder with ID `workspace-default-prompts`. Change move validation to reject only destination IDs in `smartCollectionIDs`, and preserve only those smart IDs when replacing manual membership.

- [ ] **Step 5: Implement additive reconciliation transactionally**

Insert this exact requirement in `ClipStoring`:

```swift
func reconcileWorkspaceDefaults() throws
```

For each store, ensure one canonical Prompts node under the built-in Collections root, find other manual nodes whose trimmed title compares equal to `Prompts` case-insensitively, replace their collection IDs on every clip, remove adopted nodes, and publish/save once. SwiftData wraps the entire operation in `withFolderRollback`; the in-memory implementation stages `clips` and `storedFolders` copies before assignment. `folders()` invokes reconciliation before returning records.

- [ ] **Step 6: Verify focused and parent gates GREEN**

Run:

```bash
swift test --filter FolderTreeTests
./script/test.sh
```

Expected: all commands exit zero; the complete suite remains at least 77 Swift tests and 4 Rust tests.

- [ ] **Step 7: Commit the collection slice**

```bash
git add Sources/ClipVaultCore/Models/Clip.swift Sources/ClipVaultCore/Services/ClipStore.swift Tests/ClipVaultCoreTests/FolderTreeTests.swift
git commit -m "feat: add protected Prompts collection"
```

---

### Task 2: Atomic Generated-Prompt Batch Persistence

**Files:**
- Create: `Tests/ClipVaultCoreTests/GeneratedPromptPersistenceTests.swift`
- Modify: `Sources/ClipVaultCore/Services/ClipStore.swift`

**Interfaces:**
- Produces: `GeneratedPromptDraft`, `GeneratedPromptStoreError`, and `ClipStoring.saveGeneratedPrompts(_:) throws -> [Clip]`.
- Consumes: Task 1 canonical `prompts` destination and smart/manual membership policy.
- Later consumers: Task 3 batch runner produces `GeneratedPromptDraft`; Task 4 persists it.

- [ ] **Step 1: Add failing success and rollback tests for both stores**

```swift
@Suite("Generated prompt persistence")
struct GeneratedPromptPersistenceTests {
    @Test("both stores save one encrypted Prompts clip per source")
    func bothStoresSaveGeneratedPromptBatches() throws {
        try assertGeneratedPromptBatch(in: InMemoryClipStore())
        try assertGeneratedPromptBatch(in: makeSwiftDataStoreForGeneratedPromptTests())
    }

    private func assertGeneratedPromptBatch(in store: any ClipStoring) throws {
        try store.reconcileWorkspaceDefaults()
        let first = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "First", extractedText: "First"),
            sourceApp: nil
        ))
        let second = try #require(try store.save(
            payload: ClipPayload(kind: .text, displayText: "Second", extractedText: "Second"),
            sourceApp: nil
        ))

        let saved = try store.saveGeneratedPrompts([
            GeneratedPromptDraft(sourceClipID: first.id, sourceTitle: first.title, enhancedText: "Goal: Improve first"),
            GeneratedPromptDraft(sourceClipID: second.id, sourceTitle: second.title, enhancedText: "Goal: Improve second")
        ])

        #expect(saved.count == 2)
        #expect(saved.allSatisfy { $0.collectionIDs.contains("prompts") })
        #expect(Set(saved.compactMap { $0.metadata["promptSourceClipID"] }) == [first.id, second.id])
        #expect(saved.allSatisfy { $0.sourceApp == "ClipVault AI" })
    }
}
```

Add separate tests requiring zero new clips for an empty batch, missing source, sensitive output, duplicate output against the store, duplicate output within the batch, and a forced SwiftData save error.

- [ ] **Step 2: Run the new suite and verify RED**

Run: `swift test --filter GeneratedPromptPersistenceTests`

Expected: compile failures for the missing draft, error, and store API.

- [ ] **Step 3: Define the batch types and protocol operation**

```swift
public struct GeneratedPromptDraft: Hashable, Sendable {
    public var sourceClipID: String
    public var sourceTitle: String
    public var enhancedText: String

    public init(sourceClipID: String, sourceTitle: String, enhancedText: String) {
        self.sourceClipID = sourceClipID
        self.sourceTitle = sourceTitle
        self.enhancedText = enhancedText
    }
}

public enum GeneratedPromptStoreError: Error, LocalizedError, Equatable {
    case emptyBatch
    case promptsUnavailable
    case sourceMissing(String)
    case rejectedOutput(String)
    case duplicateOutput(String)

    public var errorDescription: String? {
        switch self {
        case .emptyBatch: "No enhanced prompts were produced."
        case .promptsUnavailable: "The Prompts collection is unavailable."
        case .sourceMissing: "A source clip is no longer available."
        case .rejectedOutput: "An enhanced prompt could not be saved safely."
        case .duplicateOutput: "An identical enhanced prompt already exists."
        }
    }
}
```

Add `func saveGeneratedPrompts(_ drafts: [GeneratedPromptDraft]) throws -> [Clip]` to `ClipStoring`.

- [ ] **Step 4: Implement one-commit persistence in both stores**

Validate all sources, output text, sensitive classification, fingerprints, and the canonical destination before mutation. Resolve every source from the store and derive `Enhanced — <source title>` from that canonical stored clip title, never from `draft.sourceTitle`; cap the result to 80 characters. Create normal `.text` payloads with metadata `promptSourceClipID`, source app `ClipVault AI`, `research` smart membership, and `prompts` manual membership. SwiftData inserts every encrypted record then calls the injected save closure once; on error call `context.rollback()`. In memory, mutate local copies and assign them back only after all drafts succeed.

- [ ] **Step 5: Verify atomic persistence GREEN**

Run:

```bash
swift test --filter GeneratedPromptPersistenceTests
swift test --filter ClipStorageEncryptionTests
./script/test.sh
```

Expected: all commands exit zero; forced failures leave both clip count and payload lookup unchanged.

- [ ] **Step 6: Commit the persistence slice**

```bash
git add Sources/ClipVaultCore/Services/ClipStore.swift Tests/ClipVaultCoreTests/GeneratedPromptPersistenceTests.swift
git commit -m "feat: save generated prompts atomically"
```

---

### Task 3: Dedicated On-Device Enhancer, Validator, And Batch Runner

**Files:**
- Create: `Sources/ClipVaultCore/Services/PromptEnhancer.swift`
- Create: `Tests/ClipVaultCoreTests/PromptEnhancerTests.swift`

**Interfaces:**
- Produces: `PromptEnhancing`, `FoundationModelsPromptEnhancer`, `PromptEnhancementValidator`, `PromptEnhancementBatchRunner`, `PromptEnhancementProgress`, and `PromptEnhancementError`.
- Produces: `[GeneratedPromptDraft]` from Task 2 for Task 4.
- Consumes: `AIAvailability`, `Clip`, and `GeneratedPromptDraft`.

- [ ] **Step 1: Add failing validator and batch-runner tests**

Cover empty source, empty output, normalized equality, known commentary wrapper, sensitive output, dropped numbers/URLs/emails/quoted literals/identifiers, stable source order, one call per source, progress from 1 through N, first-failure stop, and cancellation.

```swift
@Test("batch runner produces one draft per source in source order")
func batchRunnerProducesSeparateDrafts() async throws {
    let enhancer = ScriptedPromptEnhancer(outputs: [
        "one": "Goal: Produce one result.",
        "two": "Goal: Produce two results."
    ])
    let runner = PromptEnhancementBatchRunner(enhancer: enhancer)
    let sources = [
        Clip(id: "one", kind: .text, title: "One", preview: "one", extractedText: "one"),
        Clip(id: "two", kind: .text, title: "Two", preview: "two", extractedText: "two")
    ]
    let recorder = PromptProgressRecorder()

    let drafts = try await runner.run(sources: sources) { update in
        await recorder.append(update)
    }
    let progress = await recorder.values()

    #expect(drafts.map(\.sourceClipID) == ["one", "two"])
    #expect(progress == [
        PromptEnhancementProgress(current: 1, total: 2, sourceTitle: "One"),
        PromptEnhancementProgress(current: 2, total: 2, sourceTitle: "Two")
    ])
}

private actor PromptProgressRecorder {
    private var storage: [PromptEnhancementProgress] = []

    func append(_ value: PromptEnhancementProgress) {
        storage.append(value)
    }

    func values() -> [PromptEnhancementProgress] {
        storage
    }
}
```

Implement `ScriptedPromptEnhancer` as an immutable `Sendable` struct whose output map and availability are fixed at initialization.

- [ ] **Step 2: Run the new suite and verify RED**

Run: `swift test --filter PromptEnhancerTests`

Expected: compile failure because the prompt-enhancement types do not exist.

- [ ] **Step 3: Implement deterministic contracts and validation**

Define:

```swift
public protocol PromptEnhancing: Sendable {
    func availability() -> AIAvailability
    func enhance(_ source: Clip) async throws -> String
}

public struct PromptEnhancementProgress: Equatable, Sendable {
    public var current: Int
    public var total: Int
    public var sourceTitle: String
}

public enum PromptEnhancementError: Error, LocalizedError, Equatable {
    case emptySelection
    case unavailable(String)
    case emptySource(String)
    case emptyOutput(String)
    case unchangedOutput(String)
    case commentaryWrapper(String)
    case sensitiveOutput(String)
    case droppedValue(String)

    public var errorDescription: String? {
        switch self {
        case .emptySelection: "Select one or more prompt clips first."
        case .unavailable(let reason): reason
        case .emptySource(let title): "\(title) has no text to enhance."
        case .emptyOutput(let title): "\(title) produced an empty result."
        case .unchangedOutput(let title): "\(title) is already well structured."
        case .commentaryWrapper(let title): "\(title) produced commentary instead of a prompt."
        case .sensitiveOutput(let title): "\(title) produced content ClipVault cannot save safely."
        case .droppedValue(let title): "\(title) did not preserve required source values."
        }
    }
}
```

`PromptEnhancementValidator` normalizes line whitespace and blank lines, rejects known wrapper prefixes, applies `SensitiveRuleEngine`, and compares deterministic token sets extracted with regular expressions for URLs, emails, numbers, quoted literals, and identifier-like values.

- [ ] **Step 4: Implement the sequential batch runner**

```swift
public struct PromptEnhancementBatchRunner: Sendable {
    private let enhancer: any PromptEnhancing
    private let validator: PromptEnhancementValidator

    public init(
        enhancer: any PromptEnhancing,
        validator: PromptEnhancementValidator = PromptEnhancementValidator()
    ) {
        self.enhancer = enhancer
        self.validator = validator
    }

    public func availability() -> AIAvailability {
        enhancer.availability()
    }

    public func run(
        sources: [Clip],
        progress: @Sendable (PromptEnhancementProgress) async -> Void
    ) async throws -> [GeneratedPromptDraft] {
        guard !sources.isEmpty else { throw PromptEnhancementError.emptySelection }
        let availability = enhancer.availability()
        guard availability.isAvailable else {
            throw PromptEnhancementError.unavailable(
                availability.reason ?? "Apple Intelligence is unavailable."
            )
        }

        var drafts: [GeneratedPromptDraft] = []
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            await progress(PromptEnhancementProgress(
                current: index + 1,
                total: sources.count,
                sourceTitle: source.title
            ))
            let output = try await enhancer.enhance(source)
            let validated = try validator.validate(output: output, source: source)
            drafts.append(GeneratedPromptDraft(
                sourceClipID: source.id,
                sourceTitle: source.title,
                enhancedText: validated
            ))
        }
        try Task.checkCancellation()
        return drafts
    }
}
```

- [ ] **Step 5: Implement the Foundation Models provider with no fallback**

On macOS 26+, create a fresh `LanguageModelSession` for each source. Instructions require preservation, outcome-first structure, relevant-only sections, no commentary, and no invented requirements. Use trimmed `extractedText`, with trimmed `preview` as the only fallback; if both are empty, throw `.emptySource(source.title)` before opening a model session. On older macOS or unavailable Apple Intelligence, throw `.unavailable`; do not call `LocalClipAIActionProvider`.

- [ ] **Step 6: Verify enhancer behavior GREEN**

Run:

```bash
swift test --filter PromptEnhancerTests
swift test --filter AIActionProviderTests
swift build -Xswiftc -warnings-as-errors
```

Expected: all commands exit zero; deterministic tests require no Apple Intelligence session.

- [ ] **Step 7: Commit the enhancer slice**

```bash
git add Sources/ClipVaultCore/Services/PromptEnhancer.swift Tests/ClipVaultCoreTests/PromptEnhancerTests.swift
git commit -m "feat: add on-device prompt enhancer"
```

---

### Task 4: View-Model Workflow, Cancellation, And Open Prompts

**Files:**
- Modify: `Sources/ClipVault/App/ClipVaultViewModel.swift:20-190,660-735`
- Modify: `Sources/ClipVaultCore/Services/PromptEnhancer.swift`
- Modify: `Tests/ClipVaultCoreTests/PromptEnhancerTests.swift`

**Interfaces:**
- Consumes: Task 3 `PromptEnhancementBatchRunner` and Task 2 `saveGeneratedPrompts(_:)`.
- Produces: `PromptEnhancementState`, `runPromptEnhancement()`, `cancelPromptEnhancement()`, `openPrompts()`, and `canEnhancePrompts` for Task 5.

- [ ] **Step 1: Add failing workflow-state tests in the core runner suite**

Add the shared state type to `PromptEnhancer.swift` so its cancellation and success semantics remain testable outside the executable target:

```swift
public enum PromptEnhancementState: Equatable, Sendable {
    case idle
    case enhancing(current: Int, total: Int, sourceTitle: String)
    case saving(total: Int)
    case success(count: Int)
    case failed(sourceTitle: String?, message: String)
    case cancelled
}
```

Add exact computed-semantics tests:

```swift
#expect(PromptEnhancementState.enhancing(current: 1, total: 2, sourceTitle: "One").allowsCancellation)
#expect(!PromptEnhancementState.saving(total: 2).allowsCancellation)
#expect(PromptEnhancementState.success(count: 2).savedCount == 2)
#expect(PromptEnhancementState.cancelled.savedCount == nil)
```

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter PromptEnhancerTests`

Expected: compile failure for the missing state type and computed properties.

- [ ] **Step 3: Add view-model dependencies and observable state**

Add:

```swift
private let promptEnhancementRunner: PromptEnhancementBatchRunner
private var promptEnhancementTask: Task<Void, Never>?
var promptEnhancementState: PromptEnhancementState = .idle

var promptEnhancerAvailability: AIAvailability {
    promptEnhancementRunner.availability()
}

var canEnhancePrompts: Bool {
    !isGenerating && !promptEnhancementSources.isEmpty && promptEnhancerAvailability.isAvailable
}

private var promptEnhancementSources: [Clip] {
    selectedClips.isEmpty ? selectedClip.map { [$0] } ?? [] : selectedClips
}
```

Initialize the runner with `FoundationModelsPromptEnhancer`. Keep the current production initializer call site unchanged by providing the dependency as a default argument.

Implement `allowsCancellation` so only `.enhancing` returns true, and `savedCount` so only `.success(count:)` returns its count.

- [ ] **Step 4: Implement run, cancel, and navigation actions**

`runPromptEnhancement()` snapshots sources before creating the task, resets the old AI result/error, sets `isGenerating`, forwards progress to `promptEnhancementState`, awaits every draft, checks cancellation, sets `.saving`, calls `store.saveGeneratedPrompts` once, reloads, explicitly restores the source selection snapshot, then publishes `.success(count:)`. Catch `CancellationError` as `.cancelled`; catch other errors as `.failed` without calling persistence again. Always clear `isGenerating` and the retained task. At the start of ordinary `runAIAction(_:)`, reset `promptEnhancementState = .idle` so the two result surfaces are mutually exclusive.

Map typed enhancer errors to their associated source title. For all other errors, use the current progress source title when available. The visible failure must have the stable form `Couldn’t enhance “<title>.” <reason> Nothing was saved.` or, when no source has started, `<reason> Nothing was saved.` Log only the private underlying error; never include source text in state or logs.

```swift
func cancelPromptEnhancement() {
    guard case .enhancing = promptEnhancementState else { return }
    promptEnhancementTask?.cancel()
}

func openPrompts() {
    guard case .success = promptEnhancementState,
          collections.contains(where: { $0.id == ClipCollection.prompts.id }) else {
        return
    }
    selectedCollectionID = ClipCollection.prompts.id
}
```

- [ ] **Step 5: Verify workflow compilation and parent gates GREEN**

Run:

```bash
swift test --filter PromptEnhancerTests
swift build -Xswiftc -warnings-as-errors
./script/test.sh
```

Expected: all commands exit zero; source selection tests in the runner remain deterministic.

- [ ] **Step 6: Commit the workflow slice**

```bash
git add Sources/ClipVault/App/ClipVaultViewModel.swift Sources/ClipVaultCore/Services/PromptEnhancer.swift Tests/ClipVaultCoreTests/PromptEnhancerTests.swift
git commit -m "feat: orchestrate prompt enhancement batches"
```

---

### Task 5: AI Workspace Controls And Accessible Result States

**Files:**
- Modify: `Sources/ClipVault/Views/AIActionPanel.swift:1-420`
- Modify: `Sources/ClipVault/Views/ClipVaultDesign.swift:1-90`

**Interfaces:**
- Consumes: Task 4 state and actions.
- Produces: full/compact Enhance Prompt buttons and progress/cancel/success/failure states.

- [ ] **Step 1: Introduce the button references and verify the compiler catches missing design tokens**

Add the full and compact button calls using `ClipVaultDesign.enhancePromptIcon` and `ClipVaultDesign.enhancePromptTint`, then run a build before defining those tokens.

Run: `swift build -Xswiftc -warnings-as-errors`

Expected: compile failure naming the missing design-token members.

- [ ] **Step 2: Add the shared visual tokens**

```swift
static let enhancePromptIcon = "wand.and.stars"
static let enhancePromptTint = Color.purple
```

Use the existing glass action-group treatment; do not add a nested glass surface or animated decoration.

- [ ] **Step 3: Add full and compact Enhance Prompt controls**

The expanded grid button uses `Label("Enhance Prompt", systemImage: ClipVaultDesign.enhancePromptIcon)`. The compact toolbar uses icon-only layout with accessibility label `Enhance Prompt` and hint `Creates one improved prompt per source clip and saves the completed batch to Prompts.` Both call `model.runPromptEnhancement()` and use `model.canEnhancePrompts` for enablement.

Help text resolves in this order: current generation in progress, no source clip, Apple Intelligence reason, then the normal action explanation.

- [ ] **Step 4: Render prompt-enhancement result states before ordinary AI results**

Add a focused `promptEnhancementResult` view:

```swift
@ViewBuilder
private var promptEnhancementResult: some View {
    switch model.promptEnhancementState {
    case .idle:
        EmptyView()
    case .enhancing(let current, let total, let sourceTitle):
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: Double(current), total: Double(total))
            Text("Enhancing \(current) of \(total)")
            Text(sourceTitle).font(.caption).foregroundStyle(.secondary)
            Button("Cancel") { model.cancelPromptEnhancement() }
        }
    case .saving(let total):
        ProgressView("Saving \(total) enhanced prompts")
    case .success(let count):
        VStack(alignment: .leading, spacing: 10) {
            Label("\(count) enhanced prompts saved to Prompts", systemImage: "checkmark.circle.fill")
            Button("Open Prompts") { model.openPrompts() }
                .clipVaultGlassButtonStyle(prominent: true)
        }
    case .failed(_, let message):
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
    case .cancelled:
        Text("Prompt enhancement cancelled. Nothing was saved.")
            .foregroundStyle(.secondary)
    }
}
```

Ensure state is conveyed by text and the progress group exposes current/total accessibility values.

- [ ] **Step 5: Compile and statically inspect the UI**

Run:

```bash
swift build -Xswiftc -warnings-as-errors
rg -n "Enhance Prompt|Open Prompts|Prompt enhancement cancelled" Sources/ClipVault/Views/AIActionPanel.swift
rg -n "wand.and.stars" Sources/ClipVault/Views/ClipVaultDesign.swift
git diff --check
```

Expected: build and checks pass; the action appears exactly once in each full/compact control path.

- [ ] **Step 6: Commit the UI slice**

```bash
git add Sources/ClipVault/Views/AIActionPanel.swift Sources/ClipVault/Views/ClipVaultDesign.swift
git commit -m "feat: add Enhance Prompt workspace action"
```

---

### Task 6: Full Verification, Migration Smoke, And Signed Rebuild

**Files:**
- Modify: `docs/superpowers/plans/2026-07-13-on-device-prompt-enhancer.md` only to record actual results.
- Modify: `/Users/s1kor/.codex/PLANS.md` progress log outside the repository.

**Interfaces:**
- Consumes: final source, tests, and exact `dist/ClipVault.app`.
- Produces: final gate evidence and weakest truthful readiness label.

- [x] **Step 1: Run complete automated gates**

Run:

```bash
./script/test.sh
swift build -c release -Xswiftc -warnings-as-errors
cargo fmt --manifest-path rust/SearchIndexCore/Cargo.toml -- --check
cargo clippy --manifest-path rust/SearchIndexCore/Cargo.toml --all-targets --all-features -- -D warnings
cargo test --manifest-path rust/SearchIndexCore/Cargo.toml
for file in script/*.sh script/lib/*.sh; do bash -n "$file"; done
```

Expected: every command exits zero.

- [x] **Step 2: Rebuild and verify the exact signed app**

Run:

```bash
./script/build_and_run.sh --verify
./script/e2e_smoke.sh
codesign --verify --deep --strict --verbose=2 dist/ClipVault.app
plutil -lint dist/ClipVault.app/Contents/Info.plist
plutil -lint dist/ClipVault.app/Contents/Resources/PrivacyInfo.xcprivacy
otool -L dist/ClipVault.app/Contents/MacOS/ClipVault
```

Expected: every command exits zero and the exact process remains alive.

- [x] **Step 3: Exercise live single-source and multi-source success**

Use synthetic prompt clips only. Verify the full and compact controls, one generated result per source, sequential progress, success count, Open Prompts navigation, editable/copyable generated clips, original preservation, relaunch persistence, and `promptSourceClipID` through the existing E2E app-owned store probe in a disposable probe build.

- [x] **Step 4: Exercise cancel, unavailable, failure, and migration paths**

Use deterministic test fixtures for unavailable/failure paths and a disposable app data container for migration. Confirm cancellation and every failure save zero outputs; confirm a legacy custom Prompts collection becomes one protected canonical manual collection with memberships intact and no duplicate after a second relaunch. Do not modify the user's real clips or consent.

- [x] **Step 5: Inspect accessibility, layout, performance, and logs**

At minimum and regular window widths, inspect labels, hints, disabled reasons, progress values, keyboard reachability, selection continuity, idle CPU/RSS, and unified logs. Require no new invalid-symbol, nested-glass, negative-geometry during ordinary interaction, save, migration, encryption, or crash signatures. Keep known macOS 27 Core Spotlight/Metal and accessibility-capture-only signals separate.

- [x] **Step 6: Review and commit final evidence-only edits**

Run `git status --short`, `git diff --check`, inspect the complete branch diff, update this plan and the HQ progress log with actual results, and commit only the plan result if it changed. Never stage historical `audits/` directories.

#### Task 6 Result — 2026-07-13

- Complete gates passed: 142 Swift tests in 17 suites, 4 Rust tests, strict release warnings, rustfmt, strict Clippy, and syntax checks for 17 shell scripts. Focused suites passed 12 generated-prompt persistence, 27 folder/migration, and 45 prompt-workflow tests.
- The exact Apple Development-signed `/Users/s1kor/dev/andrzej/ClipVault/dist/ClipVault.app` passed launch verification, E2E smoke, strict code-signature verification, plist/privacy lint, and linkage inspection. Final signed runtime PID was 78870.
- A signed disposable E2E build verified live one-source and two-source success, ordered progress, live cancel with zero saved outputs, live validator failure with zero saved outputs, Open Prompts navigation, normal generated-clip controls, original/selection preservation, and relaunch persistence. Exact `promptSourceClipID` remains integration-test evidence because the stock E2E store probe exposes only row/copy counts.
- Prompts protection, manual Move/drop destination policy, legacy adoption, idempotence, encryption, atomicity, and rollback are green through native menu inspection and focused SwiftData coverage. No real clip, consent, permission, or Apple account state was changed.
- Runtime review found a real persisted-expanded cold-launch fault: two `glassEffect() tried to update multiple times per frame` entries without AX capture. Bisection isolated launch-visible inline native-glass controls; commit `4269960` switched only that path to the existing material-backed surface while preserving 34/30-point sizing, tints, help, and AX semantics, and added a static shell policy. Four subsequent signed persisted-expanded cold launches recorded zero glass faults.
- Compact 900x572 and regular 1224x768 AX checks passed. Final idle samples for PID 78870 were 0.0%, 0.1%, and 0.0% CPU at 197,168 KB RSS. Ordinary final-launch errors were limited to the known host Core Spotlight `CSIndexErrorDomain -1000` diagnostic.
- Weakest truthful label: **repo-ready and interaction-clean for the on-device prompt enhancer; blocked:external for complete all-controls keyboard-focus proof**. The host has full-control keyboard navigation disabled, so Shift-Tab entered text fields but could not prove every button without changing a system setting. No release-candidate or upload claim is made.
- Full evidence: `.superpowers/sdd/task-6-report.md` (ignored, local audit artifact). Historical untracked `audits/` directories remain untouched.
