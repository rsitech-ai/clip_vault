# Contributing to ClipVault

ClipVault welcomes focused bug fixes, tests, documentation improvements, and narrowly scoped product changes. The project is pre-1.0, so discuss substantial behavior or architecture changes in an issue before investing in an implementation.

## Before you start

You need:

- an Apple-silicon Mac running macOS 15 or later;
- Xcode 26 or later and the macOS command-line tools;
- Swift 6;
- Rust 1.85 or later.

Clone the repository and verify the baseline:

```bash
git clone https://github.com/rsitech-ai/clip_vault.git
cd clip_vault
./script/test.sh
```

The Swift package links a local Rust library. Use `./script/test.sh` or build the Rust release target before invoking `swift test` directly.

## Working on a change

1. Create a focused branch from current `main`.
2. Preserve existing behavior unless the issue defines a correction.
3. Add a failing regression test before changing product behavior or fixing a bug.
4. Keep clipboard content, encryption keys, local paths, signing identities, and personal data out of source, fixtures, screenshots, and logs.
5. Run the smallest focused test while iterating, then the complete verification relevant to the diff.

For product behavior and bug fixes, use a red-green-refactor cycle. Configuration and documentation changes should have deterministic validation instead of speculative tests.

## Required checks

Run this before opening a pull request:

```bash
./script/test.sh
cargo fmt --manifest-path rust/SearchIndexCore/Cargo.toml --check
cargo clippy --manifest-path rust/SearchIndexCore/Cargo.toml --all-targets --all-features -- -D warnings
cargo audit --file rust/SearchIndexCore/Cargo.lock
swift build -c release -Xswiftc -warnings-as-errors
git diff --check
```

For capture, encryption, persistence, Keychain, pasteboard, prompt generation, packaging, or UI changes, also run the applicable integration or E2E script and describe the exact result in the pull request.

## Pull requests

Keep each pull request reviewable:

- explain the user-visible outcome and why it is needed;
- link the issue when one exists;
- list exact verification commands and results;
- call out privacy, security, migration, compatibility, and documentation impact;
- include screenshots only for actual UI changes, using sanitized sample data;
- do not mix unrelated cleanup into a behavior change.

CI must pass on the exact pull-request head before merge. A hosted job that never starts because of account infrastructure is an external blocker, not a passing check.

Unless explicitly marked otherwise, contributions intentionally submitted for inclusion are licensed under the Apache License 2.0, consistent with [LICENSE](LICENSE).

## Reporting problems

Use the issue forms for reproducible bugs and feature requests. Do not include clipboard contents, credentials, private logs, personal data, or proprietary material in public issues. Follow [SECURITY.md](SECURITY.md) for vulnerabilities.
