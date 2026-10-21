# File transfer performance and image recovery — 2026-10-21

This follow-up starts from main `1259d008e11f65de95db3493f7a9f823168b18ac`.
It preserves the existing encrypted chunk format, pairing identities, relay URL,
SQLite durability settings, local history, disk reservations and file size handling.
There is no new transport or peer-discovery service.

## Findings and changes

1. New file frames queried delivery state before their first POST. The durable
   first-attempt marker already proves whether an upload could have occurred.
   Never-attempted frames now skip GET. Ambiguous POST responses still query the
   relay after reopening, and retries retain stable frame IDs and sequences.
2. Successful uploads were immediately checked again on the next tick. They now
   await the authenticated whole-file outcome, with per-frame status reconciliation
   after 30 seconds if needed. The deadline persists across process/FFI reopen;
   expiration and backward clock changes permit recovery. A missing outcome can
   delay recognition of a chunk rejection by up to 30 seconds.
3. An empty mailbox between sender batches switched receivers from 250 ms to a
   five-second idle interval. A ten-second grace after actual file progress now
   keeps polling through that gap. It is persisted because the Mac bridge reopens
   its client per command. Idle peers, pause, network backoff and large clock
   changes cannot keep rapid polling alive indefinitely. Each progress tick adds
   one small encrypted state write; an offline peer can cause about 40 extra polls.
4. Tailscale Serve forwards all devices through loopback, making them share the
   proxy's old 20 requests/second allowance. The proxy now permits 100 requests/s
   overall, burst 50. Join/bootstrap retain their separate 20 requests/s, burst 50.
   Four concurrent requests, the 21 MiB request bound, the 8 KiB join bound,
   timeouts, authentication, private HTTPS ingress and service memory limits stay.
5. The proxy unnecessarily spooled ciphertext requests/responses to temporary
   files. It now streams both directions. The relay still commits ciphertext
   before acknowledging submission. The production Axum listener enables
   TCP_NODELAY for small ACK/delivery responses.
6. Relay expiration and receipt-retention cleanup had no matching indexes. Both
   queries ran on POST, mailbox reads and receipt checks, repeatedly traversing
   large pending ciphertext rows to reach metadata after the envelope. Partial
   indexes on pending creation time and terminal time now seek only due rows.
   A recipient/cursor index streams oldest pending mailbox rows without sorting
   ciphertext into a temporary B-tree.
   Existing databases create them on open; expiry/retention rules, secure deletion
   and journal/fsync settings are unchanged.
7. Fresh chunks now overlap in pairs over the existing authenticated POST route.
   Attempt markers are durable before workers start; manifests/outcomes and
   ambiguous retries stay serial. Threads never access SQLite, all are joined
   before result handling or exit, and every sibling response is handled even
   after a 507 or cancellation. Existing frame/time/queue limits remain.
   Tests exposed and corrected a blocked-recipient loop that initially failed to
   advance, plus an incorrect fixture POST count. Credential copies are zeroized.
8. The Mac bridge reopens a client per command, discarding the transport pool.
   A process-wide HTTP client now reuses connections; only successful construction
   is cached. Identity, keys, configuration and cancellation remain per instance,
   and authentication remains per request. Two-workspace pairing tests and a TCP
   accept-count regression cover reuse without crossing authentication boundaries.
9. A copied image could offer an inaccessible file URL alongside usable image
   bytes. File staging still takes precedence. A single background file capture
   now retains the first advertised JPEG/PNG/TIFF representation up to 8 MiB
   (JPEG first), and lazily rescues an image if staging fails. It uses the same
   observation's bytes and rechecks capture generation after awaiting OCR.
   Explicit Add File, multiple files and private markers do not use this fallback.
   Successful fallback says an image was captured, rather than implying that the
   original file was shared. Existing OCR privacy and image export limits remain.
   The 8 MiB bound limits retained data; AppKit materializes a representation before
   its size can be checked. The private original IMG_5587.jpeg was not inspected.

Primary references: [Axum ListenerExt](https://docs.rs/axum/0.8.9/axum/serve/trait.ListenerExt.html),
[nginx streaming](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_request_buffering),
[nginx multiple rate limits and empty keys](https://nginx.org/en/docs/http/ngx_http_limit_req_module.html#limit_req_zone),
[Apple NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard),
[SQLite partial indexes](https://www.sqlite.org/partialindex.html),
[SQLite query planning](https://www.sqlite.org/queryplanner.html),
[reqwest connection-pool reuse](https://docs.rs/reqwest/0.12.28/reqwest/blocking/struct.Client.html),
[Rust scoped-thread joining](https://doc.rust-lang.org/std/thread/fn.scope.html).

## Measurements and evidence boundaries

Measurements use controlled nonsecret fixtures. Rates are MiB/s, not advertised
Wi-Fi link speeds. Native installed-app checks and isolated engine probes are
separate claims. Raw socket or SSH-tunnel measurements do not establish app speed.

| Check | Observation |
|---|---|
| Local HTTP, 100 MiB, restart and saved hash | Initial baseline 20.90 s; proves software overhead without a LAN hop |
| Paired local runs, NODELAY in both, before fresh-GET skip | 23.755 / 22.500 s |
| Same paired runs after fresh-GET skip | 21.600 / 19.290 s; about 13% higher aggregate throughput in this small sample |
| Razer proxy via authenticated SSH forward, 64 MiB, saved bytes/hash | Buffered/20r: 38.968 s; streaming/100r: 31.844 s (about 22% higher throughput); later polling-grace change not included |
| Private raw Tailscale TCP, 64 MiB | 15.95 MiB/s |
| Direct same-LAN TCP, 64 MiB | 22.80 MiB/s; both Wi-Fi endpoints reported 866.7 Mb/s negotiated rates |
| Isolated engines on main Mac, Razer and Sii | Unicode text on all six routes; saved files on all six routes; 128 MiB main fanout, 32 MiB Razer fanout, 2 MiB Sii fanout, exact receiver sizes/SHA-256; Sii engine reopened mid-transfer |
| CABI-like reopen per tick, 32 MiB via Razer SSH-forwarded proxy, ABBA, exact saved hashes | No pool: 16.971 / 15.920 s; shared pool: 14.193 / 15.266 s; about 12% higher aggregate throughput. Diagnostic, not native-app speed |
| Local HTTP final uploader, 100 MiB, restart and saved hash | 11.73 s (initial baseline 20.90 s); about 1.78 times the throughput in these runs |
| Razer isolated mailbox, 96 MiB queued, reading 16 chunks | Before: 54.56 ms / 58.8 MB cached reads / 15.1 MB temporary writes. Indexed: 13.41 ms / 16.8 MB reads / zero temporary writes; same oldest 16 cursors |
| Razer isolated cleanup, 96 MiB queued, 24 maintenance calls | Before: 1.6658 s / 4,838,224,365 cached read bytes / 1,181,233 read syscalls. Indexed: 0.000656 s / 4,597 bytes / 27 read syscalls. Measures cleanup only, not end-to-end throughput |
| Native installed build 16, same 128 MiB fanout as build 14 | 115 MiB progress window: build 14, 34.830 s (3.302 MiB/s); build 16, 23.618 s (4.869 MiB/s), about 48% higher sustained throughput. Razer verified the full file; main UI reported all-recipient Ready to save |
| Local HTTP final pool, 600 MiB, restart and saved hash | Passed; 60.44 s test runtime, receiver reopened mid-transfer and completed in 46 post-restart ticks |
| Native installed build 15, paired uploads, 600 MiB | Razer verified-ready 275.112 s from pre-Add monitor; text copy and brief diagnostics ran during transfer. Both recipients later reported ready. This did not demonstrate a native speed gain, despite passing software/connection-overlap gates |
| Native installed build 14 with all three relay indexes, actual 600 MiB fanout | Razer verified-ready at 231.235 s from pre-Add monitor start (about 20 s before Add); steady transfer remained around 3 MiB/s. Indexes removed database waste but did not establish a user-visible throughput gain |
| Native installed build 14 before expiry indexes, actual 600 MiB fanout | Razer verified-ready at 207.010 s from pre-Add monitor start; about 3 MiB/s steady progress, confirming earlier changes alone did not satisfy the speed request |
| Native installed build 13, before polling grace | 128 MiB reached verified-ready on Razer in 53.621 s from pre-Add monitor start; recurring idle gaps visible; main UI later reported all-recipient ready |

The three-host engine benchmark used SSH forwards and a synchronization barrier;
its throughput is not presented as installed-app speed. The final run used the final source on all three hosts, while an earlier run
also covered mixed-version interoperability. The receiving Save/hash checks apply to the isolated engines' real file API, not to
remote mouse clicks in the installed GUIs.

## Regression and protection checks

- Real HTTP RED/GREEN: no fresh-frame probes; no immediate redundant receipt
  probes; lost successful POST response reconciles after reopen without reupload;
  complete saved bytes; sender receives ready outcome.
- Persisted poll grace survives reopen, expires, rejects a far-future deadline,
  and leaves overdue receipt recovery working. Capability rollout and idle tests
  preserve old-relay/old-peer behavior.
- Production listener test verifies TCP_NODELAY on accepted sockets.
- Maintenance regression fails before indexing (2,064 VM steps for 512 live
  chunks), then passes with bounded work. Existing-database reopen installs
  indexes; exact expiration and terminal-retention boundaries preserve live data.
  Mailbox regression fails before indexing (one temporary sort), then streams the
  same oldest 16 rows with no sort and bounded VM work.
- Snapshot/lifecycle tests cover JPEG bytes after a later clipboard change,
  private/multi-file rejection, successful staging avoiding fallback, failure
  recovery, pause during OCR, and the persistent store's OCR-unavailable local-only
  policy. No automatic sharing bypass was introduced.
- Isolated deployed nginx: unauthenticated roster 401, 8,193-byte JSON join 413,
  declared 22 MiB mailbox body 413. A 100-request join burst produced 51 validation
  rejections and 49 rate rejections; the setup limiter remains enforced.
- Live signed Mac fallback: a controlled unavailable file URL plus a 60,266-byte
  JPEG produced a new image/OCR row. The main history count grew from 936 to 939
  with test/user captures and survived both app replacements. Existing Mac legacy
  history was not decrypted or read through the command line.

## Validation and rollout

The first relay-only maintenance attempt missed the proxy's `Requires` dependency.
Stopping the relay also stopped its proxy, so the health gate failed and restored
the previous relay binary/database. The corrected updater restarts and recovers
both units; its health gate, all three index checks and SQLite `quick_check` passed.
Root-only rollback was retained, with pairing secret and client history unchanged.

Final signed build 16 was installed and launched on both Macs, and Ubuntu
0.2.0~preview8 on Razer. Both Mac executable hashes match, and strict code-signature
verification passed. The main history count grew to 949 and survived replacements. Controlled Unicode
text copied through the installed Mac app during the 600 MiB transfer had delivered
receipts from both other devices. A later image displayed the existing OCR-unavailable
local-only policy; no automatic export is claimed for that image. The earlier
controlled unavailable-file/JPEG fallback remains the successful image recovery
proof. Real-user clipboard changes can interleave with controlled GUI captures;
no private payload was decrypted or used as a test fixture.

### Final cross-device and service gates

The final source was rerun in isolated encrypted engines on the three actual
hosts. All six Unicode text routes passed. Every host sent a file and each other
host saved it through the real receive/save API; all six sizes and SHA-256 hashes
matched. The Sii engine closed and reopened during the main Mac's 128 MiB fanout.
These engine paths use separate test identities and history, leaving the installed
apps' keys and private history untouched.

| Sender | Receivers | Saved bytes at each receiver | SHA-256 at both receivers |
|---|---|---:|---|
| Main Mac | Razer, Sii | 134217728 | `2756163a8e1be2bbefaf11f51b6d360e782b5de25a97a5ce1d987fb0c1874e39` |
| Razer | Main Mac, Sii | 33554432 | `a725f69c89b0aeba23bbd8e8a374fe9161be462a6e5069fc58f0251ff6c5e47b` |
| Sii | Main Mac, Razer | 2097152 | `67c082ebaf8f24d2ad6f6e1ca6e37cbe7ff17f3dcde39ecd6a4ed311c6210fb7` |

The final native build-16 128 MiB transfer used the existing paired apps and
private HTTPS relay. Razer first reported 13 MiB at monitor time 40.625 s, reached
128 MiB at 64.243 s and verified-ready at 66.604 s. The comparable build-14 progress
window was 18.549 to 53.379 s. Only these equal 115 MiB windows are used for the
48% figure: the monitors started at different times before Add File. Native GUI
completion reported Ready to save, which requires both authenticated recipient
outcomes. This is a short controlled sample, not a guaranteed rate or a long-term
uptime claim. Transfer speed still depends on Wi-Fi and recipients; the unchanged
wire format base64-encodes both chunk bytes and encrypted envelopes, and sending
to two devices uploads two separately encrypted copies. Raw TCP speeds therefore
cannot be compared directly to useful file throughput.

Final executable identities:

- Both Macs, build 16: `c21e4e95c067f66e9dfc7d2c674bfbcb68977665900f58483c7889a47e373b23`.
- Ubuntu preview 8 client: `8bad3f6c7fa28c058670530d3bd5ddcf75839c593e5de3925ee31b229026c97e`.
- Relay: `4ee7d2f11086fd88be4aa1b2c1fae7fff0ba9cf6feb892503062c2fbbbc35506`.
- Proxy configuration: `5e06fc260e3dad923efb164ced8d2d70ee7b8c046ae5756a0af480664f7e9436`.

The client, relay and proxy are active, with zero automatic restarts and exit
status zero in the final service receipts. Ubuntu's capture extension is ACTIVE.
Private HTTPS health returned `ok`. No warning-priority client/relay/proxy journal
entries occurred in the final update/transfer window. Mac framework diagnostics
and headless renderer warnings are classified separately below. The main app is
left capturing, on All Clips with search cleared. Activity Monitor was restored
to its prior CPU view and the temporary process filter cleared.

### Commands and review

Passed on the final production source (the later CI correction changes only a
test's wall-time assertions):

- `./script/test.sh`: Rust SearchIndexCore 4 tests; Swift core 269 tests in 31
  suites; app 22 tests in 6 suites.
- `cargo test --release --workspace --locked` and
  `cargo clippy --release --workspace --all-targets --locked -- -D warnings`,
  with `--manifest-path rust/DeviceSync/Cargo.toml`, on native macOS and Linux AMD64.
- `cargo test --release --locked -p clipvault-sync-relay --test relay six_hundred_mib_http_transfer_exceeds_old_cache_cap_and_hashes -- --ignored --nocapture`:
  final 600 MiB HTTP, restart, Save and exact-hash gate passed.
- The 100 MiB restart/hash and 256 MiB relay-quota gates also passed. Focused
  transport reuse/authentication tests passed 5/5, parallel upload tests 6/6.
- `./script/build_and_run.sh --stage`: signed bundle staged, then installed and
  launched at the canonical location on both Macs with signature/hash checks.
- `script/smoke_linux_ui.sh` against the final preview-8 package on Ubuntu 26:
  exact text/PNG Copy, URI-list and native picker staging, exact attachment Save,
  capture toggle and rejection of untrusted D-Bus callers passed. Python 3,
  clipboard path entry and picker focus checks make this harness reproducible.
- Final three-host engine script: six exact text routes, six receiver Save/hash
  routes and Sii mid-transfer reopen passed.
- Independent source review passed the final transport pool, concurrency,
  durable-attempt/retry/capacity/cancel paths and Swift privacy/lifecycle recovery.

An initial Linux CI debug run failed the capacity test's first-tick `<1s` assertion.
This was a test defect (CODE_FAILURE): the timed region included multi-megabyte
cryptography, database writes and scheduling. Both unsupported timing bounds were
removed. Exact POST counts, capacity backoff and continued mailbox polling remain
asserted, and the corrected debug test passed. The next CI run reached an existing
FIFO test whose three-second watchdog included subprocess startup and encrypted
store creation while other large fixtures competed for disk. Its watchdog is now
30 seconds, preserving detection of an indefinite FIFO open (PRE_EXISTING test
threshold defect, addressed in this PR). CI must pass on the exact final PR head
before merge. No production code or installed binary changed for these test fixes.
The following CI run also demonstrated that a valid two-second send budget can
leave the final partial chunk for a later tick. The overlap/capacity/pause tests
now allow up to four bounded ticks; exact counts, maximum two requests and saved
bytes remain asserted. A notification after the second arriving request commits
replaces a sleep for reverse-completion ordering, with a deadlock watchdog below
the client's request timeout (CODE_FAILURE test assumption, corrected).

Earlier validation setup failures were INFRA_FAILURE: a corrupted fresh macOS
Cargo cache, absent Python in the headless smoke image, and stale headless Xvfb
state. Corrected setup and fresh runs passed. Headless Mesa DRI3 and GDK frame
timing warnings remain environment observations; they did not fail functional
smoke checks. Mac unified logs contain existing AppKit negative-view-geometry
diagnostics (also 90 width and 90 height entries in the pre-follow-up baseline
window), a BaseBoard task-port diagnostic, and Sii's GenerativeModels unavailable-
reason diagnostics. No ClipVault subsystem error/fault was observed in the final
window, and the tested picker, transfer and Save flows completed. These framework
messages remain disclosed; this report does not claim warning-free OS logs.
No Docker Desktop restart or desktop logout was used.

Raw logs, progress receipts, benchmark data, source census and rollback bundles
remain in the ignored audit artifacts, retained in the primary checkout after
worktree cleanup. No credentials or private clipboard payloads are committed.
