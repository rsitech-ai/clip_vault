use axum::{
    body::{Body, to_bytes},
    http::{Method, Request, StatusCode},
    middleware::{self, Next},
    response::IntoResponse,
};
use clipvault_sync_core::*;
use clipvault_sync_relay::{RelayStore, router};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicUsize, Ordering},
};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn full_text_recipient_does_not_block_other_peer_inbox_or_ack_after_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().to_path_buf();
    let full_target = Arc::new(Mutex::new(None::<(String, String)>));
    let attempts = Arc::new(AtomicUsize::new(0));
    let gate = full_target.clone();
    let counted = attempts.clone();
    let app = router(RelayStore::open(&root.join("relay.db"), "registration").unwrap()).layer(
        middleware::from_fn(move |request: Request<Body>, next: Next| {
            let gate = gate.clone();
            let attempts = counted.clone();
            async move {
                if request.method() == Method::POST && request.uri().path() == "/v1/mailbox" {
                    let (parts, body) = request.into_parts();
                    let bytes = to_bytes(body, 8 * 1024 * 1024).await.unwrap();
                    let blocked = serde_json::from_slice::<Envelope>(&bytes).is_ok_and(|e| {
                        e.header.message_type == "clip"
                            && gate.lock().unwrap().as_ref().is_some_and(|(from, to)| {
                                &e.header.sender == from && &e.header.recipient == to
                            })
                    });
                    if blocked {
                        attempts.fetch_add(1, Ordering::SeqCst);
                        return StatusCode::INSUFFICIENT_STORAGE.into_response();
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
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let result = tokio::task::spawn_blocking(move || {
        let key = random_secret();
        let open_sender =
            || SyncClient::open(DeviceStore::open(&root.join("sender.db"), key).unwrap()).unwrap();
        let mut sender = open_sender();
        let mut full =
            SyncClient::open(DeviceStore::open(&root.join("full.db"), random_secret()).unwrap())
                .unwrap();
        let mut healthy =
            SyncClient::open(DeviceStore::open(&root.join("healthy.db"), random_secret()).unwrap())
                .unwrap();
        sender
            .create_workspace(&endpoint, "registration", "Sender")
            .unwrap();
        for device in [&mut full, &mut healthy] {
            let words = device
                .join(&sender.create_invite().unwrap(), "Peer")
                .unwrap();
            let request = sender.pairing_requests().unwrap().remove(0);
            sender.approve(&request.id, &words).unwrap();
            device.tick(true).unwrap();
        }
        let ack_event = full
            .capture(PortableClip::text("pending ack", 1), None)
            .unwrap()
            .unwrap();
        full.tick(true).unwrap();
        sender.tick(false).unwrap();
        sender.store.mark_applied(&ack_event).unwrap();
        healthy
            .capture(PortableClip::text("independent inbox", 2), None)
            .unwrap();
        healthy.tick(true).unwrap();
        *full_target.lock().unwrap() = Some((sender.device_id().into(), full.device_id().into()));
        for text in ["pending first", "pending second"] {
            sender.capture(PortableClip::text(text, 3), None).unwrap();
        }
        sender
            .tick(true)
            .expect("capacity must not abort the independent inbox cycle");
        assert!(
            sender
                .store
                .history()
                .unwrap()
                .iter()
                .any(|e| e.clip.text == "independent inbox")
        );
        full.tick(true).unwrap();
        assert!(
            !full
                .store
                .pending()
                .unwrap()
                .iter()
                .any(|e| e.id == ack_event),
            "the sender must flush its existing ACK"
        );
        healthy.tick(true).unwrap();
        for text in ["pending first", "pending second"] {
            assert!(
                healthy
                    .store
                    .history()
                    .unwrap()
                    .iter()
                    .any(|e| e.clip.text == text)
            );
        }
        assert_eq!(
            attempts.load(Ordering::SeqCst),
            1,
            "backpressure must suppress later posts to the same recipient in this tick"
        );
        drop(sender);
        let mut sender = open_sender();
        sender.tick(true).unwrap();
        assert_eq!(
            attempts.load(Ordering::SeqCst),
            1,
            "recipient retry delay must survive reopen"
        );
        *full_target.lock().unwrap() = None;
        std::thread::sleep(std::time::Duration::from_secs(3));
        for _ in 0..4 {
            sender.tick(true).unwrap();
            full.tick(true).unwrap();
            healthy.tick(true).unwrap();
        }
        for text in ["pending first", "pending second"] {
            assert_eq!(
                full.store
                    .history()
                    .unwrap()
                    .iter()
                    .filter(|e| e.clip.text == text)
                    .count(),
                1
            );
        }
        assert!(sender.store.pending().unwrap().is_empty());
    })
    .await;
    server.abort();
    result.unwrap();
}
