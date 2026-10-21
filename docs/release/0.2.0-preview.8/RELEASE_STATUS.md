# ClipVault 0.2.0-preview.8 release status

Date: 2026-10-21. This is an experimental source/Linux publication candidate.
Publication is complete only after the annotated tag, GitHub prerelease, assets
and downloaded checksums are read back successfully. This document records the
gates; the GitHub release is the publication receipt.

| Lane | Gate and evidence |
|---|---|
| Source and Linux preview | Runtime implementation merged in PR #28 at `242b64eb25e423552ae149243831d954bcc60eed`; exact-main CI run `39610331605` passed. Release-metadata changes require their own reviewed PR and exact-head CI before tagging its merged main commit. |
| Ubuntu client | `0.2.0~preview8`, AMD64. Final executable SHA-256 `8bad3f6c7fa28c058670530d3bd5ddcf75839c593e5de3925ee31b229026c97e`. Ubuntu 26.10/GNOME 51 target, active Wayland capture extension, plus isolated GTK Copy/Save smoke. Public package adds project license/NOTICE files; executable and runtime payload are unchanged. |
| Linux relay | AMD64 executable SHA-256 `4ee7d2f11086fd88be4aa1b2c1fae7fff0ba9cf6feb892503062c2fbbbc35506`; same executable deployed and checked healthy. Requires a separately configured private service, provisioning secret and bounded TLS proxy; no credentials or user state are distributed. |
| Existing Mac installations | Version 0.2.0 build 16, valid Developer ID signatures, matching executable SHA-256 `c21e4e95c067f66e9dfc7d2c674bfbcb68977665900f58483c7889a47e373b23`. Already installed on both target Macs; history and pairing retained. This is local deployment evidence. |
| Public Mac download | BLOCKED: the `clipvault-notary` profile could not authenticate because no corresponding Keychain password item exists. No notarization/stapling or clean-machine Gatekeeper proof exists for this candidate. Signed local ZIPs are not public release assets. |
| Mac App Store | Outside this publication: no upload or store submission is performed. |

## Runtime acceptance

The [performance and recovery audit](../../verification/file-transfer-performance.md)
records the source census, independent review, Mac/Linux checks, six directed text
routes, six file Save/size/SHA-256 routes on actual hosts, mid-transfer restart,
600 MiB HTTP integrity gate, native GUI Save, services and retained rollback.
The 4.869 versus 3.302 MiB/s native result uses equal 115 MiB progress windows;
it is a short controlled measurement rather than a guaranteed transfer rate.
No private clipboard history, pairing material or relay secret is included.

## Publication checks

- Retain the approved Apache-2.0 license, NOTICE and third-party notices.
- Review the release diff and scan the exact candidate's source/history for secrets.
- Verify the active main ruleset and private vulnerability reporting; do not infer
  protection from the legacy branch-protection endpoint alone.
- Pass exact-head hosted checks before merging the release-preparation PR.
- Tag only the reviewed merged main commit, without moving any existing tag.
- Publish source and the validated Linux assets as a **prerelease**; include
  checksums and the actual Ubuntu/GNOME/CPU limits in its notes.
- Read back tag target, release state, asset names/sizes and downloaded SHA-256.

The public Mac lane remains a separate blocked gate. Do not describe this
prerelease as a notarized Mac download or a stable cross-platform release.

## Release-preparation validation

The shell packaging/policy lane passes after aligning defaults. The repacked
Ubuntu package installs in the isolated Ubuntu 26.10 AMD64 image, retains the
exact deployed executable hash and carries project license/NOTICE files. This
container normally excludes documentation through dpkg filters; the license
installation check explicitly includes the package documentation paths.

A full-main-history Gitleaks run scanned 110 commits and returned seven findings:
five fields in the public HPKE known-answer fixture, plus two historical synthetic
repeated-hex token literals in exclusion tests. Retained vector fields match the
`hpke` 0.13.0 distributed test vector. All seven were reviewed as non-live test
data; the raw scanner exit remains a finding result, not an unqualified clean
scan. Exact-candidate scanning and publication readback remain final release gates.
Private vulnerability reporting and the active main ruleset were verified. GitHub
secret-scanning/push-protection settings were disabled at readback; this release
does not change those security settings or claim they are enabled.
