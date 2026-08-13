# Adaptive Clip Previews Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace ClipVault’s fixed, title-only 44-point rows with content-first adaptive rows that make text, code, links, files, and images recognizable while preserving all list interactions.

**Architecture:** Add two pure `ClipVaultCore` presentation helpers: `ClipRowPresentation` derives visible row strings without I/O or stored-data mutation, and `ClipResultSection` groups the already ordered search results without re-sorting them. `ClipListView` consumes those values and renders content-sized SwiftUI rows; the existing view model, persistence, search ordering, image cache, selection, copy, drag/drop, and context-menu paths remain unchanged.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI for macOS 15+, Foundation `URLComponents` and locale-aware date formatting, existing `Clip`, `SearchResult`, `ClipTimestampText`, `CachedClipImageView`, and ClipVault semantic design styles.

## Global Constraints

- The list is recognition-first; the existing detail pane remains the complete reading and editing surface.
- No persistence/schema changes, network requests, website metadata, favicons, AI summaries, new sorting/filtering, or detail/sidebar redesign.
- URL transformation is presentation-only; copying always uses the original stored payload.
- Search result order and collection counts must not change.
- Preserve single-click selection, double-click copy, Return, Command-C, arrows, context menus, drag/drop, pinning, and AI multi-selection.
- Default groups are `Today`, `Yesterday`, localized weekday within the current week, then localized abbreviated date.
- Accessibility rows grow vertically; do not use `minimumScaleFactor` or a fixed maximum row height.
- The accessibility preview is capped at 300 characters.
- Do not add a Compact or Card mode in this slice.

---

## File Structure

- Create `Sources/ClipVaultCore/Support/ClipRowPresentation.swift`: pure per-kind title, eyebrow, preview, metadata, truncation, and accessibility derivation.
- Create `Sources/ClipVaultCore/Support/ClipResultSection.swift`: pure stable time-section grouping for ordered search results.
- Create `Tests/ClipVaultCoreTests/ClipRowPresentationTests.swift`: URL, excerpt, metadata, duplication, and accessibility boundary tests.
- Create `Tests/ClipVaultCoreTests/ClipResultSectionTests.swift`: calendar label and input-order preservation tests.
- Modify `Sources/ClipVault/Views/ClipListView.swift`: sectioned list composition and adaptive row rendering only.
- Create `Tests/ClipVaultCoreTests/AdaptiveClipFixtureTests.swift`: a 580-result grouping/performance guard using deterministic fixtures.

---

### Task 1: Pure Clip Row Presentation

**Files:**
- Create: `Sources/ClipVaultCore/Support/ClipRowPresentation.swift`
- Create: `Tests/ClipVaultCoreTests/ClipRowPresentationTests.swift`

**Interfaces:**
- Consumes: `Clip`, `ClipKind`, `Locale` from `ClipVaultCore` and Foundation.
- Produces:
  - `public struct ClipRowPresentation: Equatable, Sendable`
  - `public enum ClipRowTitleTruncation: Equatable, Sendable { case tail, middle }`
  - `public init(clip: Clip, locale: Locale = .autoupdatingCurrent)`
  - Stored values `eyebrow: String?`, `title: String`, `preview: String?`, `metadata: [String]`, `titleTruncation: ClipRowTitleTruncation`, `accessibilitySummary: String`.

- [ ] **Step 1: Write failing URL presentation tests**

Create `ClipRowPresentationTests.swift` with deterministic clips and these assertions:

```swift
import Foundation
import Testing
@testable import ClipVaultCore

@Suite("Clip row presentation")
struct ClipRowPresentationTests {
    @Test("GitHub links expose host and owner repository")
    func githubRepositoryLink() {
        let clip = Clip(
            kind: .url,
            title: "https://github.com/rsitech-ai/condor",
            preview: "https://github.com/rsitech-ai/condor",
            extractedText: ""
        )
        let value = ClipRowPresentation(clip: clip, locale: Locale(identifier: "en_US_POSIX"))

        #expect(value.eyebrow == "github.com")
        #expect(value.title == "rsitech-ai / condor")
        #expect(value.preview == "https://github.com/rsitech-ai/condor")
        #expect(value.titleTruncation == .tail)
    }

    @Test("Root and malformed links fall back without mutation")
    func linkFallbacks() {
        let root = Clip(kind: .url, title: "https://www.example.com/", preview: "https://www.example.com/", extractedText: "")
        let malformed = Clip(kind: .url, title: "not a valid URL", preview: "not a valid URL", extractedText: "")

        #expect(ClipRowPresentation(clip: root).eyebrow == "example.com")
        #expect(ClipRowPresentation(clip: root).title == "example.com")
        #expect(ClipRowPresentation(clip: malformed).eyebrow == nil)
        #expect(ClipRowPresentation(clip: malformed).title == "not a valid URL")
    }
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter ClipRowPresentationTests
```

Expected: compilation fails because `ClipRowPresentation` and `ClipRowTitleTruncation` do not exist.

- [ ] **Step 3: Implement the value type and safe URL derivation**

Create `ClipRowPresentation.swift`. Use `URLComponents(string:)`, accept only lowercased `http` or `https`, strip a leading `www.` from presentation host, percent-decode path components with a fallback to the encoded component, and never promote query values. Implement the public shape exactly:

```swift
import Foundation

public enum ClipRowTitleTruncation: Equatable, Sendable {
    case tail
    case middle
}

public struct ClipRowPresentation: Equatable, Sendable {
    public var eyebrow: String?
    public var title: String
    public var preview: String?
    public var metadata: [String]
    public var titleTruncation: ClipRowTitleTruncation
    public var accessibilitySummary: String

    public init(clip: Clip, locale: Locale = .autoupdatingCurrent) {
        let link = Self.linkParts(for: clip)
        eyebrow = link?.host
        title = link?.title ?? Self.nonempty(clip.title) ?? Self.firstMeaningfulLine(in: clip.preview) ?? clip.kind.title
        preview = Self.preview(for: clip, displayedTitle: title, linkDisplayURL: link?.displayURL)
        metadata = Self.metadata(for: clip)
        titleTruncation = clip.kind == .file ? .middle : .tail
        accessibilitySummary = Self.accessibilitySummary(
            title: title,
            preview: preview,
            metadata: metadata
        )
    }
}
```

Keep `linkParts`, whitespace normalization, and line extraction private pure helpers in the same file. For GitHub, use the first two decoded path components as `owner / repository`; for other hosts use the last two non-empty components joined by ` / `, falling back to the host.

- [ ] **Step 4: Add failing text, file, metadata, and accessibility tests**

Append tests that assert:

```swift
@Test("Duplicate title preview is omitted")
func duplicatePreview() {
    let clip = Clip(kind: .text, title: "previous clipboard", preview: " previous   clipboard ", extractedText: "")
    #expect(ClipRowPresentation(clip: clip).preview == nil)
}

@Test("Text excerpt skips the displayed title line")
func textExcerpt() {
    let clip = Clip(kind: .text, title: "Edited agent handoff", preview: "Edited agent handoff\nReview the exact verified state.", extractedText: "")
    #expect(ClipRowPresentation(clip: clip).preview == "Review the exact verified state.")
}

@Test("Relevant metadata is explicit")
func metadata() {
    let clip = Clip(kind: .code, title: "Build", preview: "swift build", extractedText: "", isPinned: true, sourceApp: "Terminal", copyCount: 302)
    #expect(ClipRowPresentation(clip: clip).metadata == ["Code", "302 copies", "Pinned", "Terminal"])
}

@Test("File titles use middle truncation")
func fileTruncation() {
    let clip = Clip(kind: .file, title: "Report.pdf", preview: "/Users/s1kor/Documents/Report.pdf", extractedText: "")
    #expect(ClipRowPresentation(clip: clip).titleTruncation == .middle)
}

@Test("Accessibility preview is bounded")
func boundedAccessibility() {
    let clip = Clip(kind: .text, title: "Long", preview: String(repeating: "a", count: 500), extractedText: "")
    let value = ClipRowPresentation(clip: clip)
    #expect(value.accessibilitySummary.count < 380)
}
```

- [ ] **Step 5: Complete excerpt, metadata, and accessibility derivation**

Implement these exact rules:

- Normalize runs of whitespace to one space for comparison and list excerpts.
- Compare normalized title and preview case-insensitively; omit duplicates.
- If preview begins with a line equal to the title, select the next non-empty line.
- For images, prefer normalized `extractedText`, then `sourceApp`; for other kinds prefer `preview`, then `extractedText`.
- Metadata order is kind title, copy count only when greater than one using singular/plural, `Pinned` only when true, then non-empty source app.
- Build the accessibility summary from title, at most 300 preview characters, and metadata joined with `. `; never include decorative symbol names.

- [ ] **Step 6: Run focused and full core tests**

Run:

```bash
swift test --filter ClipRowPresentationTests
./script/test.sh
```

Expected: all new presentation tests pass; the repository suite remains green.

- [ ] **Step 7: Commit Task 1**

```bash
git add Sources/ClipVaultCore/Support/ClipRowPresentation.swift Tests/ClipVaultCoreTests/ClipRowPresentationTests.swift
git commit -m "feat: derive readable clip row content"
```

---

### Task 2: Stable Time Sections

**Files:**
- Create: `Sources/ClipVaultCore/Support/ClipResultSection.swift`
- Create: `Tests/ClipVaultCoreTests/ClipResultSectionTests.swift`

**Interfaces:**
- Consumes: ordered `[SearchResult]`, reference `Date`, `Calendar`, and `Locale`.
- Produces:
  - `public struct ClipResultSection: Identifiable, Equatable, Sendable`
  - `public var id: String`, `title: String`, `results: [SearchResult]`
  - `public static func group(_ results: [SearchResult], relativeTo: Date = Date(), calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> [ClipResultSection]`.

- [ ] **Step 1: Write failing grouping and order tests**

Create deterministic UTC tests:

```swift
import Foundation
import Testing
@testable import ClipVaultCore

@Suite("Clip result sections")
struct ClipResultSectionTests {
    @Test("Sections label calendar periods and preserve result order")
    func calendarSectionsPreserveOrder() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let now = Date(timeIntervalSince1970: 1_786_579_200) // fixed midday fixture
        let results = [
            result("today-a", now.addingTimeInterval(-60)),
            result("today-b", now.addingTimeInterval(-3_600)),
            result("yesterday", now.addingTimeInterval(-86_400)),
            result("older", now.addingTimeInterval(-8 * 86_400))
        ]

        let sections = ClipResultSection.group(results, relativeTo: now, calendar: calendar, locale: calendar.locale!)
        #expect(sections[0].title == "Today")
        #expect(sections[0].results.map(\.id) == ["today-a", "today-b"])
        #expect(sections[1].title == "Yesterday")
        #expect(sections.flatMap(\.results).map(\.id) == results.map(\.id))
    }

    private func result(_ id: String, _ date: Date) -> SearchResult {
        SearchResult(clip: Clip(id: id, createdAt: date, updatedAt: date, kind: .text, title: id, preview: id, extractedText: id), score: 0)
    }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run `swift test --filter ClipResultSectionTests`.

Expected: compilation fails because `ClipResultSection` does not exist.

- [ ] **Step 3: Implement stable single-pass grouping**

Create `ClipResultSection.swift`. Derive a stable section key and title per result, append to the last section when keys match, and otherwise create a new section. Do not sort. Compare `calendar.startOfDay(for:)` values for today/yesterday, and compare `dateInterval(of: .weekOfYear, for:)` membership for weekday labels. Use private `DateFormatter` instances configured with the passed `calendar`, `locale`, and `calendar.timeZone`: `EEEE` for weekday labels and `MMM d, yyyy` for older labels.

- [ ] **Step 4: Add boundary tests**

Add tests for empty input, a current-week weekday, two noncontiguous occurrences of the same date label, and exact input preservation. Noncontiguous identical labels must remain separate sections because merging them would reorder results.

- [ ] **Step 5: Run grouping and full tests**

```bash
swift test --filter ClipResultSectionTests
./script/test.sh
```

Expected: section tests and full suite pass.

- [ ] **Step 6: Commit Task 2**

```bash
git add Sources/ClipVaultCore/Support/ClipResultSection.swift Tests/ClipVaultCoreTests/ClipResultSectionTests.swift
git commit -m "feat: group clips by visible time period"
```

---

### Task 3: Adaptive SwiftUI Rows and Section Composition

**Files:**
- Modify: `Sources/ClipVault/Views/ClipListView.swift:14-105`
- Modify: `Sources/ClipVault/Views/ClipListView.swift:244-335`

**Interfaces:**
- Consumes: `ClipRowPresentation`, `ClipResultSection.group`, existing `SearchResult`, selection closures, cached thumbnail, and `ClipTimestampText`.
- Produces: sectioned `LazyVStack` and content-sized `ClipRowView` with unchanged public initializer.

- [ ] **Step 1: Add deterministic preview fixtures before changing layout**

Add a `#Preview("Adaptive clip rows")` block at the bottom of `ClipListView.swift` or a private fixture view in the same file with link, long text, code, SQL, file, image-without-data, pinned, 302-copy, missing-preview, and selected states. Use fixed timestamps and a local presentation-only fixture; do not initialize persistence or capture services.

- [ ] **Step 2: Replace the flat result loop with stable sections**

Inside the existing `LazyVStack`, use:

```swift
ForEach(ClipResultSection.group(model.visibleResults)) { section in
    Text(section.title)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)
        .tracking(0.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 3)

    ForEach(section.results) { result in
        // keep the existing draggable row wrapper and every gesture/menu action
    }
}
```

Do not change `moveSelection`, `selectedClipID`, `scrollTo`, gestures, keyboard modifiers, drag payload, or context-menu actions.

- [ ] **Step 3: Render the presentation hierarchy**

In `ClipRowView`, create `let presentation = ClipRowPresentation(clip: result.clip)` inside `body` and render:

```swift
HStack(alignment: .top, spacing: 10) {
    if showsSelectionControl {
        Button(action: toggleAISelection) {
            Image(systemName: isSelectedForAI ? "checkmark.circle.fill" : "circle")
                .frame(width: 20, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelectedForAI ? "Remove clip from AI selection" : "Add clip to AI selection")
    }
    thumbnail.frame(width: 38, height: 38)
    VStack(alignment: .leading, spacing: 3) {
        if let eyebrow = presentation.eyebrow {
            Text(eyebrow)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ClipVaultDesign.tint(for: result.clip.kind))
                .lineLimit(1)
        }
        Text(presentation.title)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .truncationMode(presentation.titleTruncation == .middle ? .middle : .tail)
        if let preview = presentation.preview {
            Text(preview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        if !presentation.metadata.isEmpty {
            metadataLine(presentation.metadata)
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)

    ClipTimestampText(date: result.clip.createdAt)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .monospacedDigit()
        .fixedSize(horizontal: true, vertical: false)
}
.padding(.horizontal, 8)
.padding(.vertical, 8)
.frame(minHeight: 62, alignment: .top)
```

Remove `.frame(height: 44)`, the separate bold `xN` counter, and the standalone pin icon. Render metadata joined with ` · `; hide `sourceApp` below 360 points with `ViewThatFits`, first trying all metadata and then `Array(metadata.prefix(3))`.

Add this private helper to `ClipRowView` so the call above is defined:

```swift
private func metadataLine(_ metadata: [String]) -> some View {
    ViewThatFits(in: .horizontal) {
        Text(metadata.joined(separator: " · "))
        Text(metadata.prefix(3).joined(separator: " · "))
    }
    .font(.caption2)
    .foregroundStyle(.tertiary)
    .lineLimit(1)
}
```

- [ ] **Step 4: Preserve image and selection behavior**

Keep `CachedClipImageView` and its cache key unchanged. Increase thumbnail/icon geometry from 34 to 38 points, retain kind tint, and ensure the selection-control button remains at least 28 points visually while the entire row supplies the larger pointer target. Do not put copy or pin buttons inside the row.

- [ ] **Step 5: Add explicit accessibility composition**

Apply these modifiers to the non-AI-control row content:

```swift
.accessibilityElement(children: .ignore)
.accessibilityLabel(presentation.title)
.accessibilityValue(presentation.accessibilitySummary)
.accessibilityHint("Press Return to copy this clip")
```

Keep the existing `.isSelected` trait on the outer row and the separate AI selection button label/value.

- [ ] **Step 6: Build and inspect previews**

Run:

```bash
swift build -c debug
swift build -c release -Xswiftc -warnings-as-errors
```

Expected: both builds pass without warnings. Inspect the preview at 300, 360, and 520-point list widths, Dark and Light appearances, and default plus accessibility text sizes. Fix overlap by allowing vertical growth, never by shrinking text.

- [ ] **Step 7: Commit Task 3**

```bash
git add Sources/ClipVault/Views/ClipListView.swift
git commit -m "feat: show adaptive clip previews"
```

---

### Task 4: Scale Guard, Interaction Regression, and Runtime Proof

**Files:**
- Create: `Tests/ClipVaultCoreTests/AdaptiveClipFixtureTests.swift`
- Modify only for validated defects: files from Tasks 1–3.

**Interfaces:**
- Consumes: final presentation/grouping helpers and row implementation.
- Produces: performance/order guard plus recorded runtime evidence in the PR description; no new production interface.

- [ ] **Step 1: Add a 580-result deterministic scale guard**

Create `AdaptiveClipFixtureTests.swift`:

```swift
import Foundation
import Testing
@testable import ClipVaultCore

@Suite("Adaptive clip fixture")
struct AdaptiveClipFixtureTests {
    @Test("580 visible results preserve identity and derive bounded presentation")
    func largeFixture() {
        let now = Date(timeIntervalSince1970: 1_786_579_200)
        let results = (0..<580).map { index in
            let clip = Clip(
                id: "clip-\(index)",
                createdAt: now.addingTimeInterval(TimeInterval(-index * 90)),
                updatedAt: now,
                kind: index.isMultiple(of: 5) ? .url : .text,
                title: index.isMultiple(of: 5) ? "https://github.com/rsitech-ai/project-\(index)" : "Clip \(index)",
                preview: "Preview content for clip \(index)",
                extractedText: ""
            )
            return SearchResult(clip: clip, score: Double(580 - index))
        }

        let sections = ClipResultSection.group(results, relativeTo: now)
        let presentations = results.map { ClipRowPresentation(clip: $0.clip) }
        #expect(sections.flatMap(\.results).map(\.id) == results.map(\.id))
        #expect(presentations.count == 580)
        #expect(presentations.allSatisfy { $0.accessibilitySummary.count < 380 })
    }
}
```

- [ ] **Step 2: Run the full automated matrix**

```bash
./script/test.sh
cargo fmt --manifest-path rust/SearchIndexCore/Cargo.toml --check
cargo clippy --manifest-path rust/SearchIndexCore/Cargo.toml --all-targets --all-features -- -D warnings
swift build -c release -Xswiftc -warnings-as-errors
git diff --check origin/main...HEAD
```

Expected: all shell, Rust, Swift, fixture, build, and whitespace checks pass.

- [ ] **Step 3: Exercise the real app interaction path**

Run:

```bash
./script/build_and_run.sh --verify
./script/e2e_smoke.sh
```

Then operate the staged app with an isolated QA store containing the approved screenshot examples. Verify:

- Single-click selects without copying.
- Double-click, Return, and Command-C copy.
- Up/down arrows maintain selection and scroll visibility.
- Context-menu Copy, AI selection, Pin, Move, and Delete remain present.
- Dragging a row still emits `ClipMovePayload`.
- Search and collection switches retain result order and section correctly.

- [ ] **Step 4: Capture rendered evidence**

Capture the list at 300, 360, and 520-point widths in Dark and Light modes, plus one accessibility text-size view. Inspect link, text, code, SQL, file, image, pinned, high-copy-count, long-content, missing-preview, selected, and AI-selection rows. Record any unverified VoiceOver/manual state explicitly rather than calling it passed.

- [ ] **Step 5: Review the final diff and repair only validated findings**

```bash
git diff --stat origin/main...HEAD
git diff --check origin/main...HEAD
git diff origin/main...HEAD -- Sources/ClipVaultCore/Support Sources/ClipVault/Views/ClipListView.swift Tests/ClipVaultCoreTests
git status --short --branch
```

Confirm there is no schema change, network access, search sorting change, duplicated preview, fixed row height, `minimumScaleFactor`, or unrelated sidebar/detail redesign.

- [ ] **Step 6: Commit Task 4 if the scale guard or repairs remain uncommitted**

```bash
git add Tests/ClipVaultCoreTests/AdaptiveClipFixtureTests.swift Sources/ClipVaultCore/Support Sources/ClipVault/Views/ClipListView.swift
git commit -m "test: verify adaptive clip list at scale"
```

- [ ] **Step 7: Prepare the PR handoff**

Push only after the user-authorized execution path reaches this step. The PR description must include exact local commands/results, rendered width/appearance evidence, interaction evidence, and any unavailable VoiceOver or clean-install proof. Do not claim release-ready or runtime-proven beyond the exercised staged build.

---

## Final Completion Bar

- The approved screenshot examples are recognizable from the list without opening detail.
- All pure presentation and grouping boundary tests pass.
- The full repository test/build matrix passes.
- The staged app preserves every existing list interaction.
- Rendered screenshots cover minimum, typical, wide, Dark, Light, and accessibility-size rows.
- Search order, persistence, and copied payloads are unchanged.
- Remaining manual accessibility or device evidence is named precisely.
