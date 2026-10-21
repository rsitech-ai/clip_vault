use axum::{
    body::Body,
    http::{Method, Request},
    middleware::{self, Next},
};
use clipvault_sync_core::*;
use clipvault_sync_relay::{RelayStore, router};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn slow_mailbox_download_does_not_spend_the_frame_processing_budget() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().to_path_buf();
    let relay_path = root.join("relay.db");
    let delay_next_poll = Arc::new(AtomicBool::new(false));
    let gate = delay_next_poll.clone();
    let app = router(RelayStore::open(&relay_path, "registration").unwrap()).layer(
        middleware::from_fn(move |request: Request<Body>, next: Next| {
            let gate = gate.clone();
            async move {
                if request.method() == Method::GET
                    && request.uri().path() == "/v1/mailbox"
                    && gate.swap(false, Ordering::SeqCst)
                {
                    // Below the request timeout, above the receiver's two-second
                    // frame-processing budget: model a slower but healthy link.
                    tokio::time::sleep(std::time::Duration::from_millis(2200)).await;
                }
                next.run(request).await
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
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
        receiver.tick(false).unwrap();
        sender.tick(false).unwrap();
        let source = root.join("mailbox-fixture.bin");
        let data = vec![0x6d; 8 * 1024];
        std::fs::write(&source, &data).unwrap();
        let descriptor = sender.stage_file(&source, || false).unwrap();
        let event = sender
            .capture(PortableClip::attachment(&descriptor), None)
            .unwrap()
            .unwrap();
        sender.commit_file(&descriptor.id, &event).unwrap();
        sender.tick(false).unwrap();
        // Enqueue text after the two file frames. The platform's tick(false)
        // intentionally stops at an ordinary clip until its history import;
        // placing it last exercises the real platform path without that stop
        // hiding the unrelated processing-budget defect.
        let text = sender
            .capture(
                PortableClip::text("text behind file frames", unix_time()),
                None,
            )
            .unwrap()
            .unwrap();
        sender.tick(false).unwrap();
        let db = rusqlite::Connection::open(&relay_path).unwrap();
        let count: usize = db
            .query_row(
                "SELECT COUNT(*) FROM deliveries WHERE recipient=?1 AND status='pending'",
                [receiver.device_id()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            count, 3,
            "one bounded response must contain all queued frames and text"
        );
        drop(db);
        delay_next_poll.store(true, Ordering::SeqCst);
        receiver.tick(false).unwrap();
        assert!(
            receiver
                .file_transfers()
                .unwrap()
                .iter()
                .any(|f| f.id == descriptor.id && f.status == "ready"),
            "a slow download must not discard the remaining already-fetched frames"
        );
        assert!(
            receiver
                .store
                .unapplied()
                .unwrap()
                .iter()
                .any(|e| e.id == text)
        );
        let destination = root.join("saved.bin");
        receiver
            .store
            .save_file(&descriptor.id, &destination, || false)
            .unwrap();
        assert_eq!(std::fs::read(destination).unwrap(), data);
    })
    .await;
    server.abort();
    result.unwrap();
}
