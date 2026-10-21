# Encrypted file sharing and a simpler Ubuntu interface

Approved scope (expanded 2026-10-21): actual files copied on macOS or Ubuntu,
without a fixed product size cap. Available disk space determines practical capacity. A receiving device offers
an explicit Save action. Never open or execute a received file automatically.
This extends `linux-encrypted-sync.md`; ordinary clips retain their 10 MiB cap.

## Transfer contract

- Reuse the authenticated HPKE envelope and opaque relay. Introduce a separate
  versioned file frame (manifest, chunk, outcome), rather than extending ordinary
  clip payloads with large binary data. Chunks contain at most 1 MiB of bytes.
- A manifest binds transfer UUID, sender identity, sanitized base filename,
  byte length, chunk count, SHA-256 and creation time. The empty file has zero
  chunks. No source path travels to peers. A chunk binds the same transfer and
  origin, its index, and bytes. Exact length/count and the final whole-file hash
  must match before a descriptor enters visible history or Save is enabled.
- Use separate encrypted transfer/chunk storage. No plaintext staging, whole-file
  JSON, binary data in SwiftData, or chunk rows in normal history. Stream reads,
  hashing and encryption with bounded buffers. The source is opened without
  following symlinks, verified as a regular file, and checked for changes. Reject
  directories, named pipes and files outside the wire representation. Open Unix sources with
  O_NONBLOCK before checking the opened descriptor is a regular file, so a FIFO
  cannot stall the worker before validation. Bound each copy to ten files. Replace
  the former 512 MiB local cache cap with free-disk checks, unfinished-transfer
  reservations, encryption/storage overhead and 1 GiB headroom. The u32 chunk
  count represents up to (2^32-1) MiB, about 4 PiB; this is a wire-format bound,
  not an advertised storage guarantee. Mid-receive storage failure discards the
  partial transfer and returns an authenticated failure without publishing history.
- Stage chunks incrementally in short transactions. Only a final, short commit
  makes a complete outgoing transfer eligible. Cancellation/consent generation
  is checked during reads and before that commit. Retry reads immutable encrypted
  staging, never the original source path. A failed/unsupported send retains a
  readable local copy and a visible status; it never silently drops a partial file.
- Advertise file-v1 and file-large-v1 support through an authenticated device capability endpoint;
  do not change the existing signed roster or ordinary clip serialization.
  Files above the former 100 MiB limit use authenticated file-large-v1 frames.
  Keep a file local until every paired member and the current relay advertise the
  required support (including an old-relay fallback that preserves small-file
  and ordinary-clip compatibility); retain its
  retry marker with an explicit update-needed status. An unsupported file must
  never prevent ordinary exports, mailbox draining or incoming history imports.
  A relay lie about capability
  can cause a visible failure, but cannot forge an authenticated ready outcome.
  Files selected while sharing is off or before any peer is paired stay local,
  matching ordinary clip capture; enabling sharing does not enqueue old history.
  Older clients keep receiving ordinary clips. Both clients and the relay need
  updating to use attachments; unknown/unsupported status is explicit.
- Acknowledge manifest/chunk frames after durable encrypted staging, including an
  early manifest. Withholding its ACK would block the relay's oldest-item mailbox.
  Send an authenticated ready/failure outcome separately. Relay ACK is staging,
  ready is complete hash verification, and Save is a later local user action.
- Existing relay TTL, replay protection, membership checks, rejection, backoff and
  quotas apply per frame. Drain receive/ACK work with count/byte/time bounds and
  pause checks; send ordinary clips first and use a bounded file-frame budget.
  Capacity failures retain/retry staged work. Recipient backoff excludes its jobs
  before the bounded SQL job selection, so one full recipient cannot starve
  others or require rewriting every chunk job. Reserve outbound sequence ranges
  once and insert file jobs transactionally with bounded memory.
- Enforce incoming aggregate capacity before accepting a frame. Garbage-collect
  incomplete `staging`/`receiving` transfers after 30 days and discard cancelled staging;
  retain completed chunks while their history descriptor exists. Deleting a
  descriptor cancels outstanding sends and removes its local encrypted chunks.
  Revocation cancels pending recipient work; no new frames go to revoked peers.
  A complete local `staged` transfer is retained even before sharing is committed:
  its descriptor may already be in the platform history while sharing is off.
  Explicit discard removes abandoned completed staging. Completed local chunks
  consume actual disk space until their descriptor is removed; crash-orphaned
  staged data is retained for explicit recovery/discard.
- Save streams decrypted chunks to a private 0600 temporary file on the selected
  volume, rechecks length/hash, flushes/syncs, then publishes without silently
  overwriting an existing file. Remove the temporary file on error/cancellation.
  Sanitize the suggested filename; received names never control directory paths.
  On macOS use the OS item-replacement directory appropriate for the Save-panel
  URL, then an exclusive atomic rename to that exact URL: the sandbox grant does
  not cover arbitrary sibling temporary files. The portable store's temporary
  publish currently requires hard-link support (validated APFS/ext4).

Active progress polls again after 250 ms instead of waiting five seconds. Idle,
failed and backoff polls retain the existing interval. Keep the bounded HTTP,
frame-count, byte and processing-time budgets. Start the receive processing
clock after the mailbox HTTP request returns, so download time does not discard
the rest of a healthy response. Retain the existing private relay transport;
there is no new peer-discovery service or second file server.

Relay quotas remain 256 MiB pending ciphertext per recipient and 1 GiB total.
An indexed integer byte count replaces repeated scans of queued ciphertext.
At 100,000 delivery rows, reclaim at most 1,024 oldest acknowledged receipts per
submission, preserving pending/rejected/revoked/expired rows. A missing positive
cursor ACK/REJECT retry succeeds idempotently, including after receipt eviction
and recipient restart. The 37-day retention is a maximum under row pressure.

## Platform flow

macOS: retain existing local file-reference clips and old history unchanged.
New attachment descriptors are small encrypted local payloads referring to the
portable store. File-URL clipboard capture attempts only normally authorized
access. Security scope/coordinated reading do not grant access on their own;
inaccessible files use an explicit Add File Open panel. Saving uses NSSavePanel
and the user-selected read-write sandbox entitlement. Stage before creating the
local descriptor/outbox; validate capture generation again before activating
outbound work. Explicit Add File remains usable without background capture.
Rapid file copies wait in a bounded ten-file metadata queue while one stage or
Save operation runs; capture pause invalidates in-flight staging and queued URLs.
Queue overflow reports an actionable retry message instead of reading more data.

Ubuntu: support bounded local `text/uri-list` in the GTK clipboard and GNOME
bridge. Parse URIs once; accept only file URLs with empty/localhost authority;
never fetch remote URLs. An explicit Add File picker also works while GNOME's
extension awaits a fresh desktop session. Retain GTK's native file chooser
through its asynchronous response; it supports the existing GTK 4.8 package
floor without enabling the newer FileDialog binding. Save is explicit.

## Ubuntu interface

Keep the native GTK/libadwaita system. History and search own the main window;
show a compact capture control and a short sharing status. Put setup instructions,
platform diagnostics and privacy detail in Settings. Show actionable errors near
the affected control. No permanent multi-paragraph technical text above history.

Rows use a full-width title and snippet, then short time/source/type metadata.
Date section headers own dates. Use compact icon actions with accessible names,
confirmation for deletion, and a clear empty state. Files show filename, size,
transfer state/progress and Save only when verified. Settings show the current
state first: paired devices for an existing workspace; separate Join and Create
paths for an unpaired device. Keep comparison-code approval and destructive
disconnect confirmation. Never hide consent or error states in the simplification.

## Acceptance and evidence

Test zero bytes, the legacy 100 MiB boundary and one byte above, files above
the former 512 MiB local-store cap, multiple files, source changes,
symlinks/directories/nonlocal URIs, duplicate/reordered/missing/corrupt chunks,
restart/resume, pause/revoke, queue exhaustion and save cancellation/collision.
Prove ordinary clip compatibility and unchanged legacy history. Measure large-file
RSS and duration. Test actual small, 100 MiB and larger files between the installed apps
with matching SHA-256 in each direction, including an offline receiver. Capture
fresh synthetic Ubuntu before/after screenshots and launch the rebuilt Mac app.
Report physical GNOME capture separately: the user's current session must not be
closed remotely. Keep PR #27 draft and main unchanged until required gates pass.

## Primary API references

- [Apple sandbox file access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [User-selected read-write entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.files.user-selected.read-write)
- [Mutter selection transfer](https://gnome.pages.gitlab.gnome.org/mutter/meta/method.Selection.transfer_async.html)
- [GTK asynchronous Save dialog](https://docs.gtk.org/gtk4/method.FileDialog.save.html)
- [Local file URI rules](https://www.rfc-editor.org/info/rfc8089/)

- [Linux open flags and FIFO behavior](https://man7.org/linux/man-pages/man2/open.2.html)
