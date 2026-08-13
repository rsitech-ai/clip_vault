# Clip Performance and Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Release-build clip switching immediate, add subtle accessible button press feedback, merge the reviewed work through a PR to `main`, replace the installed app safely, clean obsolete artifacts/worktrees, and publish the latest downloadable release when distribution gates pass.

**Architecture:** Add deterministic cached section and ID-index projections to `ClipVaultCore`, refresh them only when their source inputs change, and make `ClipListView` consume the cached section projection. Add one reusable SwiftUI press style that scales pointer-pressed buttons to `0.98` for approximately 120 ms while respecting Reduce Motion; do not animate clip navigation. Harden and merge through GitHub, then rebuild and distribute version `0.1.1` build `3` from merged `main` unless existing release metadata discovered before packaging establishes a newer version.

**Tech Stack:** Swift 6, SwiftUI/Observation, Swift Testing, Rust/Cargo, SwiftPM, Git/GitHub CLI, macOS codesign/notarytool, existing ClipVault packaging scripts; no new dependencies.

## Global Constraints

- Preserve clip order, identity, search ranking, storage, capture, encryption, AI, tags, notes, and multi-selection semantics.
- Selection-only changes must not regroup visible results or construct date formatters.
- Do not animate clip switching, keyboard commands, scrolling, width, height, padding, or layout position.
- Pointer press feedback is `scaleEffect(0.98)` with an interruptible ease-out response near 120 ms; Reduce Motion omits the scale.
- Do not force-push or bypass required checks.
- Replace `/Applications/ClipVault.app` only after merged-main artifact verification; move the old bundle to Trash.
- Remove only verified obsolete generated artifacts and clean, unneeded linked worktrees; preserve user data, source-controlled release history, credentials, and unrelated changes.
- Publish a downloadable binary only if Developer ID signing, notarization, stapling, Gatekeeper, checksum, and required runtime proof pass; otherwise report `blocked:external` without weakening the gate.

---

### Task 1: Cache Clip Sections and Selected-Clip Lookup

**Files:**
- Create: `Sources/ClipVaultCore/Support/ClipWorkspaceProjection.swift`
- Create: `Tests/ClipVaultCoreTests/ClipWorkspaceProjectionTests.swift`
- Modify: `Sources/ClipVault/App/ClipVaultViewModel.swift`
- Modify: `Sources/ClipVault/Views/ClipListView.swift`
- Modify: `Sources/ClipVaultCore/Support/ClipResultSection.swift`

**Interfaces:**
- Produces: `ClipWorkspaceProjection.sections`, `clip(id:)`, and `refresh(results:clips:relativeTo:)`.
- Consumes: `[SearchResult]`, `[Clip]`, calendar day, locale, and existing stable clip IDs.

- [ ] **Step 1: Write failing projection tests**

```swift
@Test("selection lookup is indexed and sections remain stable without source refresh")
func indexedLookupAndStableSections() {
    let now = Date(timeIntervalSince1970: 1_786_579_200)
    let clips = (0..<585).map { makeClip(id: "clip-\($0)", createdAt: now) }
    let results = clips.map { SearchResult(clip: $0, score: 1) }
    var projection = ClipWorkspaceProjection()

    #expect(projection.refresh(results: results, clips: clips, relativeTo: now))
    let initialGeneration = projection.generation
    #expect(projection.clip(id: "clip-584")?.id == "clip-584")
    #expect(!projection.refresh(results: results, clips: clips, relativeTo: now))
    #expect(projection.generation == initialGeneration)
}

@Test("a calendar-day change refreshes relative section labels")
func dayBoundaryRefreshesSections() {
    // Build one result whose Today label becomes Yesterday after midnight.
}
```

- [ ] **Step 2: Verify RED**

Run `swift test --filter ClipWorkspaceProjectionTests`.

Expected: compilation fails because `ClipWorkspaceProjection` does not exist.

- [ ] **Step 3: Implement the minimal projection**

Create a value-semantic projection with private source fingerprints, a `[String: Clip]` index, cached sections, and a test-visible `generation`. Refresh returns `false` when result IDs/content timestamps, clip IDs/update timestamps, and calendar day are unchanged. Do not use SwiftUI or persistence APIs in this type.

Update section grouping so one weekday formatter and one dated formatter are created per grouping call and passed to `sectionLabel` rather than created for each result.

- [ ] **Step 4: Integrate the projection**

In `ClipVaultViewModel`, refresh the projection only from existing clip/search refresh boundaries. Expose `workspaceSections` and resolve `selectedClip` through the index. In `ClipListView`, replace `ClipResultSection.group(model.visibleResults)` with `model.workspaceSections`.

Do not refresh the projection from `selectedClipID.didSet`.

- [ ] **Step 5: Verify GREEN and measure the invariant**

Run:

```bash
swift test --filter ClipWorkspaceProjectionTests
swift test --filter WorkspacePresentationPolicyTests
swift build -c release -Xswiftc -warnings-as-errors
```

Expected: projection tests pass and selecting a clip cannot increment projection generation.

- [ ] **Step 6: Commit Task 1**

```bash
git add Sources/ClipVaultCore/Support/ClipWorkspaceProjection.swift Tests/ClipVaultCoreTests/ClipWorkspaceProjectionTests.swift Sources/ClipVault/App/ClipVaultViewModel.swift Sources/ClipVault/Views/ClipListView.swift Sources/ClipVaultCore/Support/ClipResultSection.swift
git commit -m "perf: cache clip workspace projections"
```

---

### Task 2: Add Crisp Accessible Button Press Feedback

**Files:**
- Modify: `Sources/ClipVault/Views/ClipVaultGlass.swift`
- Modify: `Sources/ClipVault/Views/AIActionPanel.swift`
- Modify: `Sources/ClipVault/Views/ClipDetailView.swift`
- Modify: `script/test_ai_workspace_glass_policy.sh`

**Interfaces:**
- Produces: `ClipVaultPressButtonStyle` and `View.clipVaultPressFeedback()` where appropriate.
- Consumes: `ButtonStyle.Configuration.isPressed` and `accessibilityReduceMotion`.

- [ ] **Step 1: Add a failing source-policy assertion**

Extend the source-policy script to require:

```text
scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
animation(.easeOut(duration: 0.12), value: configuration.isPressed)
```

and reject press feedback on `ClipListView` row selection or keyboard handlers.

- [ ] **Step 2: Verify RED**

Run `bash script/test_ai_workspace_glass_policy.sh`.

Expected: failure because the reusable press style is missing.

- [ ] **Step 3: Implement the press style**

Add a primitive/plain-compatible button style that preserves the caller's label and native/material surface, applies only transform scale, and omits movement under Reduce Motion. Apply it to custom AI command buttons and other plain custom buttons. For native glass/bordered buttons, add feedback only if composition does not replace the native button style; otherwise retain native pressed behavior.

- [ ] **Step 4: Motion review and GREEN verification**

Run the policy script and review the diff against these exact findings:

| Before | After | Why |
| --- | --- | --- |
| No custom feedback on plain material buttons | `scaleEffect(0.98)` on pointer press, 120 ms ease-out | Confirms press without delaying action |
| Potential navigation animation | No selection/detail transition | Clip switching is high frequency and must remain immediate |
| Unconditional movement | No scale under Reduce Motion | Preserves accessible non-motion feedback |

Verdict must be **Approve** before proceeding.

- [ ] **Step 5: Commit Task 2**

```bash
git add Sources/ClipVault/Views/ClipVaultGlass.swift Sources/ClipVault/Views/AIActionPanel.swift Sources/ClipVault/Views/ClipDetailView.swift script/test_ai_workspace_glass_policy.sh
git commit -m "feat: add crisp button press feedback"
```

---

### Task 3: Measure and Harden the Performance Candidate

**Files:**
- Modify only exact files required by measured defects.
- Update: `docs/release/0.1.1/TEST_EVIDENCE.md` during release documentation task, not before evidence exists.

**Interfaces:**
- Consumes the optimized Release build.
- Produces exact before/after method and interaction evidence; no unsupported frame-time claim.

- [ ] **Step 1: Build and stage the Release candidate**

```bash
cargo fmt --check --manifest-path rust/SearchIndexCore/Cargo.toml
cargo clippy --manifest-path rust/SearchIndexCore/Cargo.toml --all-targets --all-features -- -D warnings
./script/test.sh
swift build -c release -Xswiftc -warnings-as-errors
./script/build_and_run.sh --verify
```

- [ ] **Step 2: Reproduce identical switching interactions**

In the staged Release app, rapidly switch among adjacent text, link, SQL/code, historical, and image clips using pointer and keyboard. Confirm detail content changes without an intermediate empty state and section generation remains stable during selection-only changes.

If perceptible delay remains, capture a SwiftUI/Time Profiler trace before making another production change. Form one trace-backed hypothesis and use a new failing test for the next fix.

- [ ] **Step 3: Review motion in the real app**

Verify plain custom buttons compress subtly and release immediately, clip navigation does not animate, keyboard actions do not animate, rapid presses remain interruptible, and Reduce Motion removes scaling.

- [ ] **Step 4: Run the complete candidate matrix**

```bash
./script/e2e_smoke.sh
git diff --check origin/main...HEAD
git status --short
```

Exercise Focus/Restore, inline AI result/dismissal, long text, links, code/SQL, image/OCR, notes/tags, capture, dedupe, persistence, and restart.

- [ ] **Step 5: Commit any bounded measurement fixes**

Use a focused commit only when files changed; do not create an empty verification commit.

---

### Task 4: Prepare Version 0.1.1 Release Documentation and Artifact Gates

**Files:**
- Create: `docs/release/0.1.1/RELEASE_NOTES.md`
- Create: `docs/release/0.1.1/RELEASE_STATUS.md`
- Create: `docs/release/0.1.1/TEST_EVIDENCE.md`
- Create: `docs/release/0.1.1/RELEASE_MANIFEST.json`
- Modify version defaults in `script/build_and_run.sh`, `script/package_direct_download.sh`, `script/package_app_store.sh`, `script/app_store_check.sh`, `script/upload_app_store.sh`, and `script/validate_app_store_package.sh` from `0.1.0`/`2` to `0.1.1`/`3`.
- Modify: `Sources/ClipVault/Views/SettingsView.swift` fallback version.
- Modify matching shell tests that assert the version/build defaults.

**Interfaces:**
- Produces version `0.1.1` build `3`, release notes, evidence, manifest, and existing-script packaging inputs.

- [ ] **Step 1: Write failing version-default tests**

Update shell tests to require `0.1.1` and build `3`, then run `./script/test_shell.sh` and confirm RED against old defaults.

- [ ] **Step 2: Update version defaults and documentation**

Describe the adaptive clip list, unified detail workspace, focus mode, inline AI, switching optimization, and press feedback. Record exact passed/blocked gates; do not copy stale 0.1.0 claims.

- [ ] **Step 3: Verify GREEN**

Run `./script/test_shell.sh`, `./script/test.sh`, and a staged `APP_VERSION=0.1.1 APP_BUILD=3 ./script/build_and_run.sh --verify`. Confirm plist values exactly.

- [ ] **Step 4: Test direct-download preflight**

Discover the installed Developer ID identity and notary profiles without exposing credentials. Run fail-closed `package_direct_download.sh --preflight` with the exact configured identity/profile when available.

Expected outcomes:

- PASS: proceed to real signed/notarized package after merge.
- Exit 2 for missing/invalid profile: record `blocked:external`; do not publish an unnotarized downloadable binary.

- [ ] **Step 5: Commit Task 4**

```bash
git add docs/release/0.1.1 Sources/ClipVault/Views/SettingsView.swift script
git commit -m "docs: prepare ClipVault 0.1.1 release"
```

Stage exact version/release files only; exclude generated `dist` contents.

---

### Task 5: PR Hardening, Publication, and Merge

**Files:**
- No planned source edits unless review or CI finds a defect.

**Interfaces:**
- Produces a reviewed, green PR merged to `main`.

- [ ] **Step 1: Synchronize and inspect the actual diff**

```bash
git fetch --prune origin
git status --short
git log --oneline --decorate origin/main..HEAD
git diff --stat origin/main...HEAD
git diff --check origin/main...HEAD
```

If `origin/main` moved, compare and merge/rebase only with a non-destructive strategy that preserves all branch commits; never force-push.

- [ ] **Step 2: Run final fresh verification**

Run Rust format/Clippy, `./script/test.sh`, debug build, warnings-as-errors Release build, staged verification, E2E, and rendered smoke. Review every changed file and all generated release claims.

- [ ] **Step 3: Push and create a ready PR**

```bash
git push -u origin feat/andrzej_adaptive_clip_previews
gh pr create --base main --head feat/andrzej_adaptive_clip_previews --title "Improve ClipVault browsing and detail workspace" --body-file <prepared-template-file>
```

Use the repository PR template and include exact verification and limitations.

- [ ] **Step 4: Review PR and CI**

Run `gh pr diff`, inspect requested reviewers/comments, and `gh pr checks --watch`. Address actionable findings with focused commits and rerun affected gates. Ship decision must be `ready` with no unresolved important findings.

- [ ] **Step 5: Merge through the PR**

Use the repository-supported merge method. Do not bypass rules. Fetch/read back `origin/main`, PR merged state, and exact merge commit SHA.

---

### Task 6: Rebuild from Main, Install, Clean, and Publish

**Files / systems:**
- `main` checkout
- `/Applications/ClipVault.app`
- generated `dist` release artifacts
- Git worktree registrations
- GitHub Releases

**Interfaces:**
- Consumes merged `origin/main` and configured distribution credentials.
- Produces verified installed version `0.1.1 (3)` and, only when notarization gates pass, a canonical downloadable GitHub Release.

- [ ] **Step 1: Build from exact merged main**

Check out/update `main`, verify it equals `origin/main`, rerun full tests, and build/stage version `0.1.1` build `3`. Record SHA before packaging.

- [ ] **Step 2: Build the direct-download artifact when preflight passes**

Run the existing package script with exact Developer ID identity and notary profile. Verify nested signatures, hardened runtime, notarization Accepted response, stapling, `spctl`, archive contents, and SHA-256.

If preflight remains blocked, stop binary publication and report the exact missing profile; continue only with the locally verified installed build if its signing/TCC boundary is acceptable and explicit.

- [ ] **Step 3: Replace the installed app recoverably**

Quit ClipVault, resolve `/Applications/ClipVault.app`, move the old bundle to Trash, copy the merged-main verified app into `/Applications`, and verify bundle identifier, version/build, signing identity, nested dylib, launch, persistence, clip switching, Focus/Restore, and capture permission state.

- [ ] **Step 4: Publish downloadable release only after all gates pass**

Create annotated tag `v0.1.1` at the exact merged-main SHA and GitHub Release `v0.1.1` with release notes, notarized zip, and checksum. Verify tag target, asset download URL, downloaded checksum, and release visibility.

- [ ] **Step 5: Clean obsolete artifacts and worktrees**

Enumerate first. Move obsolete generated local release bundles/zips to Trash while preserving the latest artifact. Remove only clean, inactive linked worktrees; the current repository is currently the sole registered worktree, so no worktree removal is expected unless new stale entries appear. Run `git worktree prune` and verify final registrations.

- [ ] **Step 6: Final readback**

Report exact main SHA, PR URL, release/tag URL or `blocked:external`, installed app identity/version/signature, artifact path/checksum, cleanup actions and recoverability, and any unresolved TCC/notarization boundary.

---

## Completion Bar

- Clip switching no longer recomputes section grouping on selection-only changes and is interaction-proven in a staged Release build.
- Press feedback passes the motion review and Reduce Motion check.
- PR is reviewed, required CI is green, and work is merged to `main` without bypass.
- Installed `/Applications/ClipVault.app` is replaced recoverably and verified from merged source.
- Obsolete artifacts and unnecessary worktrees are cleaned without touching user data or source history.
- The release is downloadable only if signed/notarized/stapled/Gatekeeper/checksum gates pass; otherwise the exact external blocker is reported.
