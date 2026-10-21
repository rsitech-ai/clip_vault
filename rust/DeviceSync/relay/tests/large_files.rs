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
    atomic::{AtomicBool, Ordering},
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
        // The sender is waiting for ACKs; pending work alone must not request
        // rapid polling forever when a peer goes offline.
        assert!(!sender.tick(true).unwrap().continue_file_transfer);
        for _ in 0..4 { receiver.tick(true).unwrap(); sender.tick(true).unwrap(); }
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
