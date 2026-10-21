use axum::{
    body::{Body, to_bytes},
    http::{Method, Request, StatusCode},
    middleware::{self, Next},
    response::IntoResponse,
};
use clipvault_sync_core::*;
use clipvault_sync_relay::{RelayStore, router};
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicUsize, Ordering},
};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn lost_ack_response_then_receipt_eviction_does_not_stall_or_duplicate_inbox() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().to_path_buf();
    let relay_path = root.join("relay.db");
    let fail_ack = Arc::new(AtomicBool::new(false));
    let gate = fail_ack.clone();
    let relay = router(RelayStore::open(&relay_path, "registration").unwrap()).layer(
        middleware::from_fn(move |request: Request<Body>, next: Next| {
            let gate = gate.clone();
            async move {
                let lose_response = request.uri().path().starts_with("/v1/ack/")
                    && gate.swap(false, Ordering::SeqCst);
                let response = next.run(request).await;
                if lose_response {
                    StatusCode::INTERNAL_SERVER_ERROR.into_response()
                } else {
                    response
                }
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, relay).await.unwrap() });
    let result = tokio::task::spawn_blocking(move || {
        let mut sender =
            SyncClient::open(DeviceStore::open(&root.join("sender.db"), random_secret()).unwrap())
                .unwrap();
        let receiver_key = random_secret();
        let receiver_path = root.join("receiver.db");
        let mut receiver =
            SyncClient::open(DeviceStore::open(&receiver_path, receiver_key).unwrap()).unwrap();
        sender
            .create_workspace(&endpoint, "registration", "Sender")
            .unwrap();
        let words = receiver
            .join(&sender.create_invite().unwrap(), "Receiver")
            .unwrap();
        let request = sender.pairing_requests().unwrap().remove(0);
        sender.approve(&request.id, &words).unwrap();
        receiver.tick(true).unwrap();
        sender.tick(true).unwrap();
        let source = root.join("small.bin");
        let data = vec![0x39; 8192];
        std::fs::write(&source, &data).unwrap();
        let file = sender.stage_file(&source, || false).unwrap();
        let file_event = sender
            .capture(PortableClip::attachment(&file), None)
            .unwrap()
            .unwrap();
        sender.commit_file(&file.id, &file_event).unwrap();
        sender.tick(true).unwrap();
        receiver.tick(true).unwrap();
        fail_ack.store(true, Ordering::SeqCst);
        assert!(matches!(receiver.tick(true), Err(SyncError::Relay(500))));
        let db = rusqlite::Connection::open(&relay_path).unwrap();
        let deleted = db
            .execute("DELETE FROM deliveries WHERE status='delivered'", [])
            .unwrap();
        assert!(
            deleted > 0,
            "simulate reclaim of the ACK whose HTTP response was lost"
        );
        drop(receiver);
        let mut receiver =
            SyncClient::open(DeviceStore::open(&receiver_path, receiver_key).unwrap()).unwrap();
        // Backoff timing is qualified separately. Make this fault-injection
        // client due now to isolate the persisted stale-cursor recovery path.
        receiver
            .store
            .put(
                "retry-backoff",
                &serde_json::json!({"failures":0,"retry_at":0}),
            )
            .unwrap();
        let text = sender
            .capture(
                PortableClip::text("new text after reclaimed ACK", unix_time()),
                None,
            )
            .unwrap()
            .unwrap();
        sender.tick(true).unwrap();
        receiver.tick(true).unwrap();
        assert!(receiver.store.event(&text).unwrap().is_some());
        assert_eq!(
            receiver
                .store
                .history()
                .unwrap()
                .iter()
                .filter(|e| e.id == file_event)
                .count(),
            1
        );
        let destination = root.join("saved.bin");
        receiver
            .store
            .save_file(&file.id, &destination, || false)
            .unwrap();
        assert_eq!(std::fs::read(destination).unwrap(), data);
    })
    .await;
    server.abort();
    result.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn large_file_capability_rollout_preserves_small_files_and_idle_polling() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().to_path_buf();
    let relay_path = root.join("relay.db");
    let legacy = Arc::new(AtomicBool::new(true));
    let gate = legacy.clone();
    let relay = router(RelayStore::open(&relay_path, "registration").unwrap()).layer(
        middleware::from_fn(move |request: Request<Body>, next: Next| {
            let gate = gate.clone();
            async move {
                if request.method() == Method::POST && request.uri().path() == "/v1/capabilities" {
                    let (parts, body) = request.into_parts();
                    let bytes = to_bytes(body, 4096).await.unwrap();
                    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
                    if gate.load(Ordering::SeqCst)
                        && json["features"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .any(|v| v == "file-large-v1")
                    {
                        return StatusCode::BAD_REQUEST.into_response();
                    }
                    return next
                        .run(Request::from_parts(parts, Body::from(bytes)))
                        .await;
                }
                next.run(request).await
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, relay).await.unwrap() });
    let result = tokio::task::spawn_blocking(move || {
        let key = random_secret();
        let sender_path = root.join("sender.db");
        let mut sender = SyncClient::open(DeviceStore::open(&sender_path,key).unwrap()).unwrap();
        let mut receiver = SyncClient::open(DeviceStore::open(&root.join("receiver.db"),random_secret()).unwrap()).unwrap();
        sender.create_workspace(&endpoint,"registration","Sender").unwrap();
        let words = receiver.join(&sender.create_invite().unwrap(),"Receiver").unwrap();
        let request = sender.pairing_requests().unwrap().remove(0);
        sender.approve(&request.id,&words).unwrap();
        assert!(!receiver.tick(true).unwrap().continue_file_transfer);
        assert!(!sender.tick(true).unwrap().continue_file_transfer);
        let small = root.join("small.txt");
        std::fs::write(&small,b"small file survives old-relay rollout").unwrap();
        let descriptor = sender.stage_file(&small,||false).unwrap();
        let event = sender.capture(PortableClip::attachment(&descriptor),None).unwrap().unwrap();
        sender.commit_file(&descriptor.id,&event).unwrap();
        assert!(sender.tick(true).unwrap().continue_file_transfer);
        assert!(receiver.tick(true).unwrap().continue_file_transfer);
        // A short persisted grace bridges healthy batches. Once it expires,
        // pending work alone must not poll rapidly forever for an offline peer.
        sender.store.put("file-poll-until", &0_i64).unwrap();
        assert!(!sender.tick(true).unwrap().continue_file_transfer);
        for _ in 0..4 { receiver.tick(true).unwrap(); sender.tick(true).unwrap(); }
        sender.store.put("file-poll-until", &0_i64).unwrap();
        assert!(!sender.tick(true).unwrap().continue_file_transfer);
        assert_eq!(sender.file_transfers().unwrap()[0].status,"ready");
        let text_id = sender.capture(PortableClip::text("ordinary text during rollout",unix_time()),None).unwrap().unwrap();
        sender.tick(true).unwrap(); receiver.tick(true).unwrap();
        assert!(receiver.store.event(&text_id).unwrap().is_some());

        let large = root.join("large.bin");
        std::fs::File::create(&large).unwrap().set_len(100 * 1024 * 1024 + 1).unwrap();
        let descriptor = sender.stage_file(&large,||false).unwrap();
        let event = sender.capture(PortableClip::attachment(&descriptor),None).unwrap().unwrap();
        assert!(matches!(sender.commit_file(&descriptor.id,&event),Err(SyncError::Unsupported)));
        assert!(receiver.store.event(&event).unwrap().is_none());
        // Upgrade relay, but simulate a still-old peer's authenticated feature advertisement.
        legacy.store(false,Ordering::SeqCst);
        receiver.tick(true).unwrap();
        // A relay rollback can retain newer feature rows. A successful legacy
        // fallback must still forbid large files, regardless of those rows.
        legacy.store(true, Ordering::SeqCst);
        assert!(matches!(sender.commit_file(&descriptor.id,&event),Err(SyncError::Unsupported)));
        legacy.store(false, Ordering::SeqCst);
        let db = rusqlite::Connection::open(&relay_path).unwrap();
        db.execute("DELETE FROM capabilities WHERE device=?1 AND feature='file-large-v1'",[receiver.device_id()]).unwrap();
        assert!(matches!(sender.commit_file(&descriptor.id,&event),Err(SyncError::Unsupported)));
        let state = rusqlite::Connection::open(&sender_path).unwrap();
        let jobs: i64 = state.query_row("SELECT COUNT(*) FROM file_jobs WHERE transfer=?1",[&descriptor.id],|r|r.get(0)).unwrap();
        assert_eq!(jobs,0,"no large-file frames before every peer supports them");
        receiver.tick(true).unwrap();
        // An interrupted atomic job commit may skip reserved sequences, but
        // must expose neither partial jobs nor a committed transfer.
        state.execute_batch("CREATE TRIGGER fail_jobs BEFORE INSERT ON file_jobs BEGIN SELECT RAISE(ABORT,'injected'); END;").unwrap();
        assert!(sender.commit_file(&descriptor.id,&event).is_err());
        assert_eq!(state.query_row("SELECT COUNT(*) FROM file_jobs WHERE transfer=?1",[&descriptor.id],|r|r.get::<_,i64>(0)).unwrap(),0);
        state.execute_batch("DROP TRIGGER fail_jobs").unwrap();
        drop(sender);
        let mut sender = SyncClient::open(DeviceStore::open(&sender_path,key).unwrap()).unwrap();
        sender.commit_file(&descriptor.id,&event).unwrap();
        let count: i64 = state.query_row("SELECT COUNT(*) FROM file_jobs WHERE transfer=?1",[&descriptor.id],|r|r.get(0)).unwrap();
        assert_eq!(count,102);
        let (lo,hi):(u64,u64) = state.query_row("SELECT MIN(sequence),MAX(sequence) FROM file_jobs WHERE transfer=?1",[&descriptor.id],|r|Ok((r.get(0)?,r.get(1)?))).unwrap();
        assert_eq!(hi-lo+1,102);
        assert!(sender.store.next_sequence().unwrap() > hi);
        let empty = root.join("empty.bin");
        std::fs::write(&empty,[]).unwrap();
        let empty = sender.stage_file(&empty,||false).unwrap();
        let event = sender.capture(PortableClip::attachment(&empty),None).unwrap().unwrap();
        sender.set_cancel_signal(Arc::new(AtomicBool::new(true)));
        assert!(matches!(sender.commit_file(&empty.id,&event),Err(SyncError::Paused)));
        assert_eq!(state.query_row("SELECT COUNT(*) FROM file_jobs WHERE transfer=?1",[empty.id],|r|r.get::<_,u64>(0)).unwrap(),0);
    }).await;
    server.abort();
    result.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn fresh_file_chunks_skip_status_probe_but_lost_submit_is_reconciled_after_restart() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().to_path_buf();
    let probes = Arc::new(AtomicUsize::new(0));
    let submissions = Arc::new(AtomicUsize::new(0));
    let lose_submit = Arc::new(AtomicBool::new(false));
    let (probe_count, submit_count, lose) =
        (probes.clone(), submissions.clone(), lose_submit.clone());
    let relay = router(RelayStore::open(&root.join("relay.db"), "registration").unwrap()).layer(
        middleware::from_fn(move |request: Request<Body>, next: Next| {
            let (probes, submissions, lose) =
                (probe_count.clone(), submit_count.clone(), lose.clone());
            async move {
                if request.uri().path().starts_with("/v1/delivery/") {
                    probes.fetch_add(1, Ordering::SeqCst);
                }
                let submitted =
                    request.method() == Method::POST && request.uri().path() == "/v1/mailbox";
                if submitted {
                    submissions.fetch_add(1, Ordering::SeqCst);
                }
                let response = next.run(request).await;
                if submitted && lose.swap(false, Ordering::SeqCst) {
                    StatusCode::INTERNAL_SERVER_ERROR.into_response()
                } else {
                    response
                }
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, relay).await.unwrap() });
    let result = tokio::task::spawn_blocking(move || {
        let key = random_secret();
        let path = root.join("sender.db");
        let mut sender = SyncClient::open(DeviceStore::open(&path, key).unwrap()).unwrap();
        let mut receiver = SyncClient::open(
            DeviceStore::open(&root.join("receiver.db"), random_secret()).unwrap(),
        )
        .unwrap();
        sender
            .create_workspace(&endpoint, "registration", "Sender")
            .unwrap();
        let words = receiver
            .join(&sender.create_invite().unwrap(), "Receiver")
            .unwrap();
        let request = sender.pairing_requests().unwrap().remove(0);
        sender.approve(&request.id, &words).unwrap();
        receiver.tick(true).unwrap();
        sender.tick(true).unwrap();
        let source = root.join("first.bin");
        let bytes = vec![0x6d; FILE_CHUNK_BYTES + 13];
        std::fs::write(&source, &bytes).unwrap();
        let first = sender.stage_file(&source, || false).unwrap();
        let event = sender
            .capture(PortableClip::attachment(&first), None)
            .unwrap()
            .unwrap();
        sender.commit_file(&first.id, &event).unwrap();
        probes.store(0, Ordering::SeqCst);
        sender.tick(true).unwrap();
        assert_eq!(
            probes.load(Ordering::SeqCst),
            0,
            "never-attempted chunks need no delivery lookup"
        );
        assert!(
            sender.tick(true).unwrap().continue_file_transfer,
            "a brief empty mailbox must not end active-transfer polling"
        );
        assert_eq!(
            probes.load(Ordering::SeqCst),
            0,
            "successful uploads await a whole-file outcome before polling receipts"
        );
        drop(sender);
        let mut sender = SyncClient::open(DeviceStore::open(&path, key).unwrap()).unwrap();
        sender.tick(true).unwrap();
        assert_eq!(
            probes.load(Ordering::SeqCst),
            0,
            "receipt deadline survives restart"
        );
        assert!(
            sender.tick(true).unwrap().continue_file_transfer,
            "active polling grace survives FFI reopen"
        );
        sender
            .store
            .put("file-poll-until", &(unix_time() - 1))
            .unwrap();
        assert!(
            !sender.tick(true).unwrap().continue_file_transfer,
            "offline sender cannot keep rapid polling alive indefinitely"
        );
        sender.store.put("file-poll-until", &i64::MAX).unwrap();
        assert!(
            !sender.tick(true).unwrap().continue_file_transfer,
            "clock rollback cannot extend the grace indefinitely"
        );
        let state = rusqlite::Connection::open(&path).unwrap();
        state
            .execute(
                "UPDATE file_jobs SET attempted_at=?1 WHERE status='pending'",
                [unix_time() - 1],
            )
            .unwrap();
        sender.tick(true).unwrap();
        assert!(
            probes.load(Ordering::SeqCst) > 0,
            "overdue receipts are reconciled without a whole-file outcome"
        );

        for _ in 0..5 {
            receiver.tick(true).unwrap();
            sender.tick(true).unwrap();
        }
        let destination = root.join("first-saved.bin");
        receiver
            .store
            .save_file(&first.id, &destination, || false)
            .unwrap();
        assert_eq!(std::fs::read(destination).unwrap(), bytes);
        assert_eq!(sender.file_transfers().unwrap()[0].status, "ready");

        // Lose a successful manifest POST response. Its durable attempted marker
        // must force a lookup after reopening, rather than posting it twice.
        let second = sender.stage_file(&source, || false).unwrap();
        let event = sender
            .capture(PortableClip::attachment(&second), None)
            .unwrap()
            .unwrap();
        sender.commit_file(&second.id, &event).unwrap();
        lose_submit.store(true, Ordering::SeqCst);
        assert!(matches!(sender.tick(true), Err(SyncError::Relay(500))));
        let before = submissions.load(Ordering::SeqCst);
        drop(sender);
        let mut sender = SyncClient::open(DeviceStore::open(&path, key).unwrap()).unwrap();
        sender
            .store
            .put(
                "retry-backoff",
                &serde_json::json!({"failures":0,"retry_at":0}),
            )
            .unwrap();
        probes.store(0, Ordering::SeqCst);
        sender.tick(true).unwrap();
        assert!(
            probes.load(Ordering::SeqCst) > 0,
            "ambiguous submission must query durable relay state"
        );
        assert_eq!(
            submissions.load(Ordering::SeqCst) - before,
            second.chunk_count as usize,
            "only remaining chunks may be posted; accepted manifest must not be reuploaded"
        );
        for _ in 0..7 {
            receiver.tick(true).unwrap();
            sender.tick(true).unwrap();
        }
        let destination = root.join("second-saved.bin");
        receiver
            .store
            .save_file(&second.id, &destination, || false)
            .unwrap();
        assert_eq!(std::fs::read(destination).unwrap(), bytes);
        assert!(
            sender
                .file_transfers()
                .unwrap()
                .iter()
                .all(|f| f.status == "ready")
        );
    })
    .await;
    server.abort();
    result.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn fresh_file_posts_overlap_with_a_two_request_bound_and_save_exact_bytes() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().to_path_buf();
    let in_flight = Arc::new(AtomicUsize::new(0));
    let max_in_flight = Arc::new(AtomicUsize::new(0));
    let second_completed = Arc::new(tokio::sync::Notify::new());
    let file_posts = Arc::new(AtomicUsize::new(0));
    let completion_order = Arc::new(std::sync::Mutex::new(Vec::new()));
    let (active, middleware_max, gate, post_count, completions) = (
        in_flight.clone(),
        max_in_flight.clone(),
        second_completed.clone(),
        file_posts.clone(),
        completion_order.clone(),
    );
    let relay = router(RelayStore::open(&root.join("relay.db"), "registration").unwrap()).layer(
        middleware::from_fn(move |request: Request<Body>, next: Next| {
            let (active, max_active, gate, post_count, completions) = (
                active.clone(),
                middleware_max.clone(),
                gate.clone(),
                post_count.clone(),
                completions.clone(),
            );
            async move {
                if request.method() != Method::POST || request.uri().path() != "/v1/mailbox" {
                    return next.run(request).await;
                }
                let (parts, body) = request.into_parts();
                let bytes = to_bytes(body, 8 * 1024 * 1024).await.unwrap();
                let envelope: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
                let request = Request::from_parts(parts, Body::from(bytes));
                if envelope["header"]["message_type"] != "file-v1" {
                    return next.run(request).await;
                }
                // Keep the first file-v1 manifest serial. The following chunk
                // frames may then reach the relay out of sequence.
                let post_index = post_count.fetch_add(1, Ordering::SeqCst);
                if post_index == 0 {
                    return next.run(request).await;
                }
                let now = active.fetch_add(1, Ordering::SeqCst) + 1;
                max_active.fetch_max(now, Ordering::SeqCst);
                // Hold the first chunk until the second has committed. A serial
                // client fails the watchdog; correctness never depends on a
                // short sleep or on the runner's encryption/database speed.
                if post_index == 1 {
                    tokio::time::timeout(std::time::Duration::from_secs(8), gate.notified())
                        .await
                        .expect("the second chunk POST must finish while the first waits");
                }
                let response = next.run(request).await;
                completions.lock().unwrap().push(post_index);
                if post_index == 2 {
                    gate.notify_one();
                }
                active.fetch_sub(1, Ordering::SeqCst);
                response
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, relay).await.unwrap() });
    let result = tokio::task::spawn_blocking(move || {
        let mut sender =
            SyncClient::open(DeviceStore::open(&root.join("sender.db"), random_secret()).unwrap())
                .unwrap();
        let mut receiver = SyncClient::open(
            DeviceStore::open(&root.join("receiver.db"), random_secret()).unwrap(),
        )
        .unwrap();
        sender
            .create_workspace(&endpoint, "registration", "Sender")
            .unwrap();
        let words = receiver
            .join(&sender.create_invite().unwrap(), "Receiver")
            .unwrap();
        let request = sender.pairing_requests().unwrap().remove(0);
        sender.approve(&request.id, &words).unwrap();
        receiver.tick(true).unwrap();
        sender.tick(true).unwrap();

        let source = root.join("parallel.bin");
        let bytes: Vec<u8> = (0..(2 * FILE_CHUNK_BYTES + 37))
            .map(|index| (index.wrapping_mul(37) % 251) as u8)
            .collect();
        std::fs::write(&source, &bytes).unwrap();
        let file = sender.stage_file(&source, || false).unwrap();
        let event = sender
            .capture(PortableClip::attachment(&file), None)
            .unwrap()
            .unwrap();
        sender.commit_file(&file.id, &event).unwrap();
        // A tick deliberately stops after its file budget; slow debug runners
        // need not fit the manifest and every chunk into the same tick.
        for _ in 0..4 {
            sender.tick(true).unwrap();
            if file_posts.load(Ordering::SeqCst) >= 4 {
                break;
            }
        }
        assert!(
            max_in_flight.load(Ordering::SeqCst) >= 2,
            "two fresh file POSTs should overlap"
        );
        assert!(
            max_in_flight.load(Ordering::SeqCst) <= 2,
            "file POST concurrency must remain bounded at two"
        );
        assert_eq!(
            file_posts.load(Ordering::SeqCst),
            4,
            "manifest plus all three chunks, including the partial final chunk"
        );
        let completion_order = completion_order.lock().unwrap();
        assert_eq!(
            &completion_order[..2],
            &[2, 1],
            "the first two arriving chunk requests must complete in reverse arrival order"
        );
        drop(completion_order);

        for _ in 0..8 {
            receiver.tick(true).unwrap();
            sender.tick(true).unwrap();
        }
        let destination = root.join("parallel-saved.bin");
        receiver
            .store
            .save_file(&file.id, &destination, || false)
            .unwrap();
        assert_eq!(std::fs::read(destination).unwrap(), bytes);
    })
    .await;
    server.abort();
    result.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn pausing_during_parallel_file_posts_joins_both_before_tick_returns() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().to_path_buf();
    let post_count = Arc::new(AtomicUsize::new(0));
    let in_flight = Arc::new(AtomicUsize::new(0));
    let both_entered = Arc::new(tokio::sync::Notify::new());
    let release = Arc::new(tokio::sync::Semaphore::new(0));
    let (posts, active, entered, release_posts) = (
        post_count.clone(),
        in_flight.clone(),
        both_entered.clone(),
        release.clone(),
    );
    let relay = router(RelayStore::open(&root.join("relay.db"), "registration").unwrap()).layer(
        middleware::from_fn(move |request: Request<Body>, next: Next| {
            let (posts, active, entered, release_posts) = (
                posts.clone(),
                active.clone(),
                entered.clone(),
                release_posts.clone(),
            );
            async move {
                if request.method() != Method::POST || request.uri().path() != "/v1/mailbox" {
                    return next.run(request).await;
                }
                let (parts, body) = request.into_parts();
                let bytes = to_bytes(body, 8 * 1024 * 1024).await.unwrap();
                let envelope: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
                let request = Request::from_parts(parts, Body::from(bytes));
                if envelope["header"]["message_type"] != "file-v1"
                    || posts.fetch_add(1, Ordering::SeqCst) == 0
                {
                    return next.run(request).await;
                }
                let current = active.fetch_add(1, Ordering::SeqCst) + 1;
                if current == 2 {
                    entered.notify_one();
                }
                let permit = release_posts.acquire().await.unwrap();
                permit.forget();
                let response = next.run(request).await;
                active.fetch_sub(1, Ordering::SeqCst);
                response
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, relay).await.unwrap() });
    let cancelled = Arc::new(AtomicBool::new(false));
    let client_cancel = cancelled.clone();
    let tick = tokio::task::spawn_blocking(move || {
        let mut sender =
            SyncClient::open(DeviceStore::open(&root.join("sender.db"), random_secret()).unwrap())
                .unwrap();
        let mut receiver = SyncClient::open(
            DeviceStore::open(&root.join("receiver.db"), random_secret()).unwrap(),
        )
        .unwrap();
        sender
            .create_workspace(&endpoint, "registration", "Sender")
            .unwrap();
        let words = receiver
            .join(&sender.create_invite().unwrap(), "Receiver")
            .unwrap();
        let request = sender.pairing_requests().unwrap().remove(0);
        sender.approve(&request.id, &words).unwrap();
        receiver.tick(true).unwrap();
        sender.tick(true).unwrap();

        let source = root.join("paused.bin");
        std::fs::write(&source, vec![0x4b; 2 * FILE_CHUNK_BYTES + 17]).unwrap();
        let file = sender.stage_file(&source, || false).unwrap();
        let event = sender
            .capture(PortableClip::attachment(&file), None)
            .unwrap()
            .unwrap();
        sender.commit_file(&file.id, &event).unwrap();
        sender.set_cancel_signal(client_cancel);
        for _ in 0..4 {
            match sender.tick(true) {
                Err(SyncError::Paused) => return,
                Ok(_) => {}
                Err(error) => panic!("unexpected sync error: {error}"),
            }
        }
        panic!("parallel posts were not paused within four bounded ticks");
    });
    tokio::time::timeout(std::time::Duration::from_secs(30), both_entered.notified())
        .await
        .expect("two chunk uploads should be concurrently waiting");
    cancelled.store(true, Ordering::Release);
    release.add_permits(2);
    tick.await.unwrap();
    assert_eq!(in_flight.load(Ordering::SeqCst), 0);
    assert_eq!(
        post_count.load(Ordering::SeqCst),
        3,
        "manifest plus two chunks"
    );
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn parallel_file_capacity_response_blocks_more_posts_for_that_recipient() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().to_path_buf();
    let file_posts = Arc::new(AtomicUsize::new(0));
    let mailbox_polls = Arc::new(AtomicUsize::new(0));
    let pair = Arc::new(tokio::sync::Barrier::new(2));
    let (file_post_count, poll_count, pair_gate) =
        (file_posts.clone(), mailbox_polls.clone(), pair.clone());
    let relay = router(RelayStore::open(&root.join("relay.db"), "registration").unwrap()).layer(
        middleware::from_fn(move |request: Request<Body>, next: Next| {
            let (file_post_count, poll_count, pair_gate) = (
                file_post_count.clone(),
                poll_count.clone(),
                pair_gate.clone(),
            );
            async move {
                if request.method() == Method::GET && request.uri().path() == "/v1/mailbox" {
                    poll_count.fetch_add(1, Ordering::SeqCst);
                    return next.run(request).await;
                }
                if request.method() != Method::POST || request.uri().path() != "/v1/mailbox" {
                    return next.run(request).await;
                }
                let (parts, body) = request.into_parts();
                let bytes = to_bytes(body, 8 * 1024 * 1024).await.unwrap();
                let envelope: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
                if envelope["header"]["message_type"] != "file-v1" {
                    return next
                        .run(Request::from_parts(parts, Body::from(bytes)))
                        .await;
                }
                let post_index = file_post_count.fetch_add(1, Ordering::SeqCst);
                let request = Request::from_parts(parts, Body::from(bytes));
                if post_index == 0 {
                    return next.run(request).await;
                }
                let _ =
                    tokio::time::timeout(std::time::Duration::from_secs(1), pair_gate.wait()).await;
                if post_index == 1 {
                    StatusCode::INSUFFICIENT_STORAGE.into_response()
                } else {
                    next.run(request).await
                }
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, relay).await.unwrap() });
    let result = tokio::task::spawn_blocking(move || {
        let mut sender =
            SyncClient::open(DeviceStore::open(&root.join("sender.db"), random_secret()).unwrap())
                .unwrap();
        let mut receiver = SyncClient::open(
            DeviceStore::open(&root.join("receiver.db"), random_secret()).unwrap(),
        )
        .unwrap();
        sender
            .create_workspace(&endpoint, "registration", "Sender")
            .unwrap();
        let words = receiver
            .join(&sender.create_invite().unwrap(), "Receiver")
            .unwrap();
        let request = sender.pairing_requests().unwrap().remove(0);
        sender.approve(&request.id, &words).unwrap();
        receiver.tick(true).unwrap();
        sender.tick(true).unwrap();

        let source = root.join("capacity.bin");
        std::fs::write(&source, vec![0x25; 2 * FILE_CHUNK_BYTES + 31]).unwrap();
        let file = sender.stage_file(&source, || false).unwrap();
        let event = sender
            .capture(PortableClip::attachment(&file), None)
            .unwrap()
            .unwrap();
        sender.commit_file(&file.id, &event).unwrap();
        for _ in 0..4 {
            sender.tick(true).unwrap();
            if file_posts.load(Ordering::SeqCst) >= 3 {
                break;
            }
        }
        assert_eq!(
            file_posts.load(Ordering::SeqCst),
            3,
            "manifest plus both concurrent chunk submissions should be processed"
        );
        let polls_before_retry = mailbox_polls.load(Ordering::SeqCst);
        sender.tick(true).unwrap();
        assert_eq!(
            file_posts.load(Ordering::SeqCst),
            3,
            "a capacity response must defer remaining work for this recipient"
        );
        assert!(
            mailbox_polls.load(Ordering::SeqCst) > polls_before_retry,
            "file capacity must not prevent normal mailbox polling"
        );
    })
    .await;
    server.abort();
    result.unwrap();
}
