use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use clipvault_sync_core::*;
use clipvault_sync_relay::*;
use sha2::Digest;
use tower::ServiceExt;

fn enroll(
    store: &mut RelayStore,
    owner_auth: &Auth,
    owner: &OwnerIdentity,
    workspace: &str,
    owner_device: &DeviceIdentity,
    new_device: &DeviceIdentity,
    credential: &str,
) {
    let now = unix_time();
    let invite = PairInvite::new(workspace, "https://sync.example", owner, owner_device, now);
    store
        .register_invite(owner_auth, &invite.id, invite.expires, now)
        .unwrap();
    let request = JoinRequest::create(&invite, new_device, now).unwrap();
    store.request_join(&request, now).unwrap();
    let old = store.roster(owner_auth).unwrap();
    let mut members = old.members;
    members.push(new_device.member("Device"));
    let roster = SignedRoster::sign(workspace, old.epoch + 1, members, owner).unwrap();
    let digest = request.digest();
    let token_hash = credential_hash(credential);
    store
        .publish(
            owner_auth,
            roster,
            Some((
                &new_device.id,
                &token_hash,
                &invite.id,
                &request.id,
                &digest,
            )),
        )
        .unwrap();
}

#[test]
fn join_shape_limits_and_exact_request_retry_preserve_owner_listing() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = RelayStore::open(&dir.path().join("relay.db"), "registration").unwrap();
    let owner = OwnerIdentity::generate();
    let mac = DeviceIdentity::generate();
    let linux = DeviceIdentity::generate();
    let roster = SignedRoster::sign("space", 1, vec![mac.member("Device")], &owner).unwrap();
    store
        .bootstrap(
            roster,
            &owner.public_key(),
            &mac.id,
            &credential_hash("owner"),
        )
        .unwrap();
    let auth = store.authenticate("owner").unwrap();
    let now = unix_time();
    let invite = PairInvite::new("space", "https://sync.example", &owner, &mac, now);
    store
        .register_invite(&auth, &invite.id, invite.expires, now)
        .unwrap();
    let request = JoinRequest::create(&invite, &linux, now).unwrap();
    store.request_join(&request, now).unwrap();
    store.request_join(&request, now).unwrap();
    let mut oversized = JoinRequest::create(&invite, &DeviceIdentity::generate(), now).unwrap();
    oversized.encapsulated_key = "A".repeat(2 * 1024 * 1024);
    assert!(store.request_join(&oversized, now).is_err());
    let mut conflicting = request.clone();
    conflicting.ciphertext = "A".repeat(100);
    assert!(store.request_join(&conflicting, now).is_err());
    let visible = store.joins(&auth, now).unwrap();
    assert_eq!(visible.len(), 1);
    assert_eq!(visible[0].id, request.id);
}

#[test]
fn file_capabilities_are_authenticated_device_scoped_and_allowlisted() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = RelayStore::open(&dir.path().join("relay.db"), "registration").unwrap();
    let owner = OwnerIdentity::generate();
    let sender = DeviceIdentity::generate();
    let receiver = DeviceIdentity::generate();
    store
        .bootstrap(
            SignedRoster::sign("space", 1, vec![sender.member("Device")], &owner).unwrap(),
            &owner.public_key(),
            &sender.id,
            &credential_hash("sender"),
        )
        .unwrap();
    let auth = store.authenticate("sender").unwrap();
    enroll(
        &mut store, &auth, &owner, "space", &sender, &receiver, "receiver",
    );
    let receiver_auth = store.authenticate("receiver").unwrap();
    assert_eq!(
        store
            .capabilities(&auth)
            .unwrap()
            .iter()
            .filter(|d| d.features.contains(&"file-v1".into()))
            .count(),
        0
    );
    store
        .publish_capabilities(&auth, &["file-v1".into()])
        .unwrap();
    assert!(
        store
            .capabilities(&auth)
            .unwrap()
            .iter()
            .any(|d| d.device == sender.id && d.features == ["file-v1"])
    );
    assert!(
        !store
            .capabilities(&auth)
            .unwrap()
            .iter()
            .any(|d| d.device == receiver.id && d.features.contains(&"file-v1".into()))
    );
    assert!(
        store
            .publish_capabilities(&receiver_auth, &["future-unreviewed".into()])
            .is_err()
    );
    assert!(
        store
            .capabilities(&auth)
            .unwrap()
            .iter()
            .all(|d| !d.features.contains(&"future-unreviewed".into()))
    );
}

#[test]
fn two_clients_send_encrypted_files_both_directions_over_http_relay() {
    use std::io::Write;
    let dir = tempfile::tempdir().unwrap();
    let relay_store = RelayStore::open(&dir.path().join("http-relay.db"), "registration").unwrap();
    let (address_tx, address_rx) = std::sync::mpsc::channel();
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel();
    let server = std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async move {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            address_tx.send(listener.local_addr().unwrap()).unwrap();
            axum::serve(listener, router(relay_store))
                .with_graceful_shutdown(async {
                    let _ = stop_rx.await;
                })
                .await
                .unwrap();
        });
    });
    let relay_url = format!("http://{}", address_rx.recv().unwrap());

    let mut mac =
        SyncClient::open(DeviceStore::open(&dir.path().join("mac.db"), random_secret()).unwrap())
            .unwrap();
    let mut ubuntu = SyncClient::open(
        DeviceStore::open(&dir.path().join("ubuntu.db"), random_secret()).unwrap(),
    )
    .unwrap();
    mac.create_workspace(&relay_url, "registration", "Mac")
        .unwrap();
    let invite = mac.create_invite().unwrap();
    ubuntu.join(&invite, "Ubuntu").unwrap();
    let request = mac.pairing_requests().unwrap().pop().unwrap();
    mac.approve(&request.id, &request.words).unwrap();
    ubuntu.refresh_membership().unwrap();
    mac.tick(false).unwrap();
    ubuntu.tick(false).unwrap();

    let source = dir.path().join("payload.bin");
    let mut file = std::fs::File::create(&source).unwrap();
    let expected: Vec<u8> = (0..(2 * 1024 * 1024 + 33))
        .map(|n| (n % 251) as u8)
        .collect();
    file.write_all(&expected).unwrap();
    file.sync_all().unwrap();

    let sync_direction = |sender: &mut SyncClient,
                          receiver: &mut SyncClient,
                          source: &std::path::Path,
                          destination: &std::path::Path| {
        let descriptor = sender.stage_file(source, || false).unwrap();
        let event_id = sender
            .capture(PortableClip::attachment(&descriptor), None)
            .unwrap()
            .unwrap();
        sender.commit_file(&descriptor.id, &event_id).unwrap();
        let mut receiver_ready = false;
        let mut sender_ready = false;
        for _ in 0..64 {
            sender.tick(false).unwrap();
            receiver.tick(false).unwrap();
            sender_ready = sender
                .file_transfers()
                .unwrap()
                .iter()
                .any(|item| item.id == descriptor.id && item.status == "ready");
            receiver_ready = receiver
                .file_transfers()
                .unwrap()
                .iter()
                .any(|item| item.id == descriptor.id && item.status == "ready");
            if sender_ready && receiver_ready {
                break;
            }
        }
        assert!(receiver_ready, "receiver never verified the transfer");
        assert!(
            sender_ready,
            "sender never received authenticated ready outcome"
        );
        receiver
            .store
            .save_file(&descriptor.id, destination, || false)
            .unwrap();
        assert_eq!(std::fs::read(destination).unwrap(), expected);
        descriptor.id
    };
    let mac_transfer = sync_direction(
        &mut mac,
        &mut ubuntu,
        &source,
        &dir.path().join("mac-to-ubuntu.bin"),
    );
    sync_direction(
        &mut ubuntu,
        &mut mac,
        &source,
        &dir.path().join("ubuntu-to-mac.bin"),
    );
    assert_eq!(
        mac.file_transfers()
            .unwrap()
            .iter()
            .find(|item| item.id == mac_transfer)
            .unwrap()
            .status,
        "ready"
    );
    let pending_descriptor = mac.stage_file(&source, || false).unwrap();
    let pending_event = mac
        .capture(PortableClip::attachment(&pending_descriptor), None)
        .unwrap()
        .unwrap();
    mac.commit_file(&pending_descriptor.id, &pending_event)
        .unwrap();
    let original_id = mac.device_id().to_owned();
    mac.disconnect().unwrap();
    assert_ne!(mac.device_id(), original_id);
    assert_eq!(
        mac.file_transfers()
            .unwrap()
            .iter()
            .find(|item| item.id == pending_descriptor.id)
            .unwrap()
            .status,
        "failed"
    );
    mac.store
        .save_file(
            &pending_descriptor.id,
            &dir.path().join("retained-after-disconnect.bin"),
            || false,
        )
        .unwrap();
    mac.create_workspace(&relay_url, "registration", "Mac re-paired")
        .unwrap();
    assert!(matches!(
        mac.commit_file(&pending_descriptor.id, &pending_event),
        Err(SyncError::Membership)
    ));
    stop_tx.send(()).unwrap();
    server.join().unwrap();
}

#[test]
fn deleting_committed_outgoing_file_cancels_frames_and_persists_tombstone() {
    use rusqlite::params;

    let dir = tempfile::tempdir().unwrap();
    let relay_store =
        RelayStore::open(&dir.path().join("delete-relay.db"), "registration").unwrap();
    let (address_tx, address_rx) = std::sync::mpsc::channel();
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel();
    let server = std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async move {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            address_tx.send(listener.local_addr().unwrap()).unwrap();
            axum::serve(listener, router(relay_store))
                .with_graceful_shutdown(async {
                    let _ = stop_rx.await;
                })
                .await
                .unwrap();
        });
    });
    let relay_url = format!("http://{}", address_rx.recv().unwrap());
    let sender_path = dir.path().join("delete-sender.db");
    let sender_key = random_secret();
    let mut sender =
        SyncClient::open(DeviceStore::open(&sender_path, sender_key).unwrap()).unwrap();
    let mut receiver = SyncClient::open(
        DeviceStore::open(&dir.path().join("delete-receiver.db"), random_secret()).unwrap(),
    )
    .unwrap();
    sender
        .create_workspace(&relay_url, "registration", "Sender")
        .unwrap();
    let invite = sender.create_invite().unwrap();
    receiver.join(&invite, "Receiver").unwrap();
    let request = sender.pairing_requests().unwrap().pop().unwrap();
    sender.approve(&request.id, &request.words).unwrap();
    receiver.refresh_membership().unwrap();
    sender.tick(false).unwrap();
    receiver.tick(false).unwrap();

    let source = dir.path().join("delete-before-send.bin");
    std::fs::write(&source, vec![0x6b; 2 * 1024 * 1024 + 11]).unwrap();
    let descriptor = sender.stage_file(&source, || false).unwrap();
    let event_id = sender
        .capture(PortableClip::attachment(&descriptor), None)
        .unwrap()
        .unwrap();
    sender.commit_file(&descriptor.id, &event_id).unwrap();

    let db = rusqlite::Connection::open(&sender_path).unwrap();
    let staged_chunks: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM file_chunks WHERE transfer=?1",
            [&descriptor.id],
            |row| row.get(0),
        )
        .unwrap();
    let pending_jobs: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM file_jobs WHERE transfer=?1 AND status='pending'",
            [&descriptor.id],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(staged_chunks, i64::from(descriptor.chunk_count));
    assert_eq!(pending_jobs, i64::from(descriptor.chunk_count + 1));
    assert!(
        sender
            .store
            .history()
            .unwrap()
            .iter()
            .any(|event| { event.id == event_id && event.clip.kind == "attachment" })
    );

    sender.store.delete_file(&descriptor.id).unwrap();
    assert!(
        sender
            .store
            .history()
            .unwrap()
            .iter()
            .all(|event| event.id != event_id)
    );
    assert!(matches!(
        sender
            .store
            .save_file(&descriptor.id, &dir.path().join("deleted.bin"), || false),
        Err(SyncError::Attachment)
    ));
    let no_chunks: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM file_chunks WHERE transfer=?1",
            [&descriptor.id],
            |row| row.get(0),
        )
        .unwrap();
    let cancelled_jobs: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM file_jobs WHERE transfer=?1 AND status='cancelled'",
            [&descriptor.id],
            |row| row.get(0),
        )
        .unwrap();
    let remaining_pending_jobs: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM file_jobs WHERE transfer=?1 AND status IN ('pending','retry')",
            [&descriptor.id],
            |row| row.get(0),
        )
        .unwrap();
    let transfer_rows: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM file_transfers WHERE id=?1",
            [&descriptor.id],
            |row| row.get(0),
        )
        .unwrap();
    let tombstones: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM file_tombstones WHERE transfer=?1",
            [&descriptor.id],
            |row| row.get(0),
        )
        .unwrap();
    let removed_history: (Option<Vec<u8>>, i64, i64) = db
        .query_row(
            "SELECT payload,outgoing,applied FROM events WHERE id=?1",
            params![event_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!(no_chunks, 0);
    assert_eq!(cancelled_jobs, i64::from(descriptor.chunk_count + 1));
    assert_eq!(remaining_pending_jobs, 0);
    assert_eq!(transfer_rows, 0);
    assert_eq!(tombstones, 1);
    assert_eq!(removed_history, (None, 0, 1));
    drop(db);

    drop(sender);
    let mut reopened =
        SyncClient::open(DeviceStore::open(&sender_path, sender_key).unwrap()).unwrap();
    let db = rusqlite::Connection::open(&sender_path).unwrap();
    let reopened_tombstones: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM file_tombstones WHERE transfer=?1",
            [&descriptor.id],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(reopened_tombstones, 1);
    drop(db);
    reopened.store.delete_file(&descriptor.id).unwrap();

    // Deletion happened before the first send attempt. A subsequent network tick
    // must not recreate the transfer or deliver any staged file frame.
    reopened.tick(false).unwrap();
    receiver.tick(false).unwrap();
    assert!(
        receiver
            .file_transfers()
            .unwrap()
            .iter()
            .all(|transfer| transfer.id != descriptor.id)
    );
    assert!(
        receiver
            .store
            .history()
            .unwrap()
            .iter()
            .all(|event| { event.clip.metadata.get("file_id") != Some(&descriptor.id) })
    );
    stop_tx.send(()).unwrap();
    server.join().unwrap();
}

#[test]
fn mailbox_capacity_507_does_not_block_inbound_clip_or_file_outcome_and_retries() {
    use axum::{
        body::{Body, to_bytes},
        middleware::{self, Next},
        response::IntoResponse,
    };
    use std::sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    };

    let dir = tempfile::tempdir().unwrap();
    let relay_store =
        RelayStore::open(&dir.path().join("capacity-relay.db"), "registration").unwrap();
    let reject_next_file_post = Arc::new(AtomicBool::new(false));
    let (address_tx, address_rx) = std::sync::mpsc::channel();
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel();
    let server_gate = reject_next_file_post.clone();
    let server = std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async move {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            address_tx.send(listener.local_addr().unwrap()).unwrap();
            let app = router(relay_store).layer(middleware::from_fn(
                move |request: Request<Body>, next: Next| {
                    let gate = server_gate.clone();
                    async move {
                        if request.method() == axum::http::Method::POST
                            && request.uri().path() == "/v1/mailbox"
                        {
                            let (parts, body) = request.into_parts();
                            let bytes = to_bytes(body, 8 * 1024 * 1024).await.unwrap();
                            let is_file = serde_json::from_slice::<Envelope>(&bytes)
                                .is_ok_and(|envelope| envelope.header.message_type == "file-v1");
                            if is_file && gate.swap(false, Ordering::SeqCst) {
                                return (StatusCode::INSUFFICIENT_STORAGE, "full").into_response();
                            }
                            return next
                                .run(Request::from_parts(parts, Body::from(bytes)))
                                .await;
                        }
                        next.run(request).await
                    }
                },
            ));
            axum::serve(listener, app)
                .with_graceful_shutdown(async {
                    let _ = stop_rx.await;
                })
                .await
                .unwrap();
        });
    });
    let address = address_rx.recv().unwrap();
    let relay_url = format!("http://{address}");
    let sender_key = random_secret();
    let receiver_key = random_secret();
    let sender_path = dir.path().join("sender.db");
    let receiver_path = dir.path().join("receiver.db");
    let mut sender =
        SyncClient::open(DeviceStore::open(&sender_path, sender_key).unwrap()).unwrap();
    let mut receiver =
        SyncClient::open(DeviceStore::open(&receiver_path, receiver_key).unwrap()).unwrap();
    sender
        .create_workspace(&relay_url, "registration", "Sender")
        .unwrap();
    let invite = sender.create_invite().unwrap();
    receiver.join(&invite, "Receiver").unwrap();
    let request = sender.pairing_requests().unwrap().pop().unwrap();
    sender.approve(&request.id, &request.words).unwrap();
    receiver.refresh_membership().unwrap();
    sender.tick(false).unwrap();
    receiver.tick(false).unwrap();

    let first_source = dir.path().join("previously-sent.bin");
    std::fs::write(&first_source, b"ready outcome fixture").unwrap();
    let first = sender.stage_file(&first_source, || false).unwrap();
    let first_event = sender
        .capture(PortableClip::attachment(&first), None)
        .unwrap()
        .unwrap();
    sender.commit_file(&first.id, &first_event).unwrap();
    sender.tick(false).unwrap();
    receiver.tick(false).unwrap();
    receiver
        .capture(
            PortableClip::text("peer text arrives during backpressure", 7),
            None,
        )
        .unwrap();
    receiver.tick(false).unwrap();
    receiver.tick(false).unwrap();

    let blocked_source = dir.path().join("temporarily-blocked.bin");
    std::fs::write(&blocked_source, b"retry after capacity clears").unwrap();
    let blocked = sender.stage_file(&blocked_source, || false).unwrap();
    let blocked_event = sender
        .capture(PortableClip::attachment(&blocked), None)
        .unwrap()
        .unwrap();
    sender.commit_file(&blocked.id, &blocked_event).unwrap();

    // Existing relay quota coverage proves a full 256 MiB recipient queue returns
    // HTTP 507. This transport gate injects that exact response at one file submit
    // so this test can prove the client keeps draining its independent inbox.
    reject_next_file_post.store(true, Ordering::SeqCst);
    sender.tick(true).unwrap();
    assert!(
        sender
            .store
            .history()
            .unwrap()
            .iter()
            .any(|event| { event.clip.text == "peer text arrives during backpressure" })
    );
    assert_eq!(
        sender
            .file_transfers()
            .unwrap()
            .iter()
            .find(|file| file.id == first.id)
            .unwrap()
            .status,
        "ready",
        "authenticated file outcome was not processed after HTTP 507"
    );
    assert_eq!(
        sender
            .file_transfers()
            .unwrap()
            .iter()
            .find(|file| file.id == blocked.id)
            .unwrap()
            .status,
        "pending",
        "a capacity response must retain the transfer for retry"
    );

    // The peer's next mailbox poll acknowledges its earlier deliveries. Once the
    // bounded retry delay elapses, the retained sender frame can be submitted.
    receiver.tick(false).unwrap();
    std::thread::sleep(std::time::Duration::from_secs(2));
    sender.tick(false).unwrap();
    receiver.tick(false).unwrap();
    assert!(receiver.file_transfers().unwrap().iter().any(|file| {
        file.id == blocked.id && matches!(file.status.as_str(), "receiving" | "ready")
    }));
    stop_tx.send(()).unwrap();
    server.join().unwrap();
}

#[test]
fn old_relay_without_capabilities_keeps_text_sync_and_rejects_file_commit_locally() {
    use axum::{
        middleware::{self, Next},
        response::IntoResponse,
    };
    use std::sync::{
        Arc,
        atomic::{AtomicU16, Ordering},
    };

    let dir = tempfile::tempdir().unwrap();
    let relay_store =
        RelayStore::open(&dir.path().join("legacy-relay.db"), "registration").unwrap();
    let capability_status = Arc::new(AtomicU16::new(404));
    let server_status = capability_status.clone();
    let (address_tx, address_rx) = std::sync::mpsc::channel();
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel();
    let server = std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async move {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            address_tx.send(listener.local_addr().unwrap()).unwrap();
            let app = router(relay_store).layer(middleware::from_fn(
                move |request: Request<Body>, next: Next| {
                    let status = server_status.clone();
                    async move {
                        if request.uri().path() == "/v1/capabilities" {
                            return (
                                StatusCode::from_u16(status.load(Ordering::SeqCst)).unwrap(),
                                "legacy relay has no capability endpoint",
                            )
                                .into_response();
                        }
                        next.run(request).await
                    }
                },
            ));
            axum::serve(listener, app)
                .with_graceful_shutdown(async {
                    let _ = stop_rx.await;
                })
                .await
                .unwrap();
        });
    });
    let address = address_rx.recv().unwrap();
    let relay_url = format!("http://{address}");
    let mut mac =
        SyncClient::open(DeviceStore::open(&dir.path().join("mac.db"), random_secret()).unwrap())
            .unwrap();
    let mut ubuntu = SyncClient::open(
        DeviceStore::open(&dir.path().join("ubuntu.db"), random_secret()).unwrap(),
    )
    .unwrap();
    mac.create_workspace(&relay_url, "registration", "Mac")
        .unwrap();
    let invite = mac.create_invite().unwrap();
    ubuntu.join(&invite, "Ubuntu").unwrap();
    let request = mac.pairing_requests().unwrap().pop().unwrap();
    mac.approve(&request.id, &request.words).unwrap();
    ubuntu.refresh_membership().unwrap();

    mac.capture(PortableClip::text("Mac remains usable", 1), None)
        .unwrap();
    mac.tick(false)
        .expect("an old relay's missing capability endpoint must not stall text delivery");
    ubuntu
        .tick(false)
        .expect("the receiver must still poll its ordinary mailbox");
    assert!(
        ubuntu
            .store
            .history()
            .unwrap()
            .iter()
            .any(|event| event.clip.text == "Mac remains usable")
    );

    ubuntu
        .capture(PortableClip::text("Ubuntu remains usable", 2), None)
        .unwrap();
    ubuntu.tick(false).unwrap();
    mac.tick(false).unwrap();
    assert!(
        mac.store
            .history()
            .unwrap()
            .iter()
            .any(|event| event.clip.text == "Ubuntu remains usable")
    );

    let source = dir.path().join("local-only.bin");
    std::fs::write(&source, b"local file remains available").unwrap();
    let descriptor = mac.stage_file(&source, || false).unwrap();
    let event_id = mac
        .capture(PortableClip::attachment(&descriptor), None)
        .unwrap()
        .unwrap();
    assert!(matches!(
        mac.commit_file(&descriptor.id, &event_id),
        Err(SyncError::Unsupported)
    ));
    assert_eq!(
        mac.file_transfers()
            .unwrap()
            .iter()
            .find(|file| file.id == descriptor.id)
            .unwrap()
            .status,
        "unsupported"
    );
    mac.store
        .save_file(
            &descriptor.id,
            &dir.path().join("saved-local-only.bin"),
            || false,
        )
        .unwrap();

    capability_status.store(500, Ordering::SeqCst);
    assert!(matches!(
        mac.commit_file(&descriptor.id, &event_id),
        Err(SyncError::Relay(500))
    ));
    assert!(matches!(mac.tick(false), Err(SyncError::Relay(500))));
    stop_tx.send(()).unwrap();
    server.join().unwrap();
}

#[test]
#[ignore = "explicit 100 MiB HTTP relay and receiver restart validation"]
fn exactly_100_mib_http_transfer_resumes_after_receiver_restart_and_hashes() {
    use std::io::{Read, Write};
    const SIZE: u64 = 100 * 1024 * 1024;
    let dir = tempfile::tempdir().unwrap();
    let relay_store = RelayStore::open(&dir.path().join("large-relay.db"), "registration").unwrap();
    let (address_tx, address_rx) = std::sync::mpsc::channel();
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel();
    let server = std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async move {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            address_tx.send(listener.local_addr().unwrap()).unwrap();
            axum::serve(listener, router(relay_store))
                .with_graceful_shutdown(async {
                    let _ = stop_rx.await;
                })
                .await
                .unwrap();
        });
    });
    let relay_url = format!("http://{}", address_rx.recv().unwrap());
    let mac_key = random_secret();
    let ubuntu_key = random_secret();
    let mac_path = dir.path().join("large-mac.db");
    let ubuntu_path = dir.path().join("large-ubuntu.db");
    let mut mac = SyncClient::open(DeviceStore::open(&mac_path, mac_key).unwrap()).unwrap();
    let mut ubuntu =
        SyncClient::open(DeviceStore::open(&ubuntu_path, ubuntu_key).unwrap()).unwrap();
    mac.create_workspace(&relay_url, "registration", "Mac")
        .unwrap();
    let invite = mac.create_invite().unwrap();
    ubuntu.join(&invite, "Ubuntu").unwrap();
    let request = mac.pairing_requests().unwrap().pop().unwrap();
    mac.approve(&request.id, &request.words).unwrap();
    ubuntu.refresh_membership().unwrap();
    mac.tick(false).unwrap();
    ubuntu.tick(false).unwrap();

    let source = dir.path().join("exactly-100-mib.bin");
    let mut file = std::fs::File::create(&source).unwrap();
    let block = vec![0x6d; 1024 * 1024];
    for _ in 0..100 {
        file.write_all(&block).unwrap();
    }
    file.sync_all().unwrap();
    let descriptor = mac.stage_file(&source, || false).unwrap();
    assert_eq!(descriptor.size, SIZE);
    assert_eq!(descriptor.chunk_count, 100);
    let event_id = mac
        .capture(PortableClip::attachment(&descriptor), None)
        .unwrap()
        .unwrap();
    mac.commit_file(&descriptor.id, &event_id).unwrap();

    // Deliver the manifest, then take Ubuntu offline. The local receiving state
    // and already-encrypted chunks must survive reopening the same database.
    mac.tick(false).unwrap();
    ubuntu.tick(false).unwrap();
    drop(ubuntu);
    let mut ubuntu =
        SyncClient::open(DeviceStore::open(&ubuntu_path, ubuntu_key).unwrap()).unwrap();

    let resume_ticks = (1..=16).find(|_| {
        mac.tick(false).unwrap();
        ubuntu.tick(false).unwrap();
        ubuntu
            .file_transfers()
            .unwrap()
            .iter()
            .any(|item| item.id == descriptor.id && item.status == "ready")
    });
    assert!(
        resume_ticks.is_some(),
        "Ubuntu did not finish and verify the restarted 100 MiB receive within 16 ticks"
    );
    eprintln!(
        "Verified the restarted 100 MiB receive in {} post-restart sync ticks",
        resume_ticks.unwrap()
    );
    let destination = dir.path().join("received-100-mib.bin");
    ubuntu
        .store
        .save_file(&descriptor.id, &destination, || false)
        .unwrap();
    let mut input = std::fs::File::open(destination).unwrap();
    let mut hasher = sha2::Sha256::new();
    let mut buffer = [0u8; 1024 * 1024];
    loop {
        let count = input.read(&mut buffer).unwrap();
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    assert_eq!(hex::encode(hasher.finalize()), descriptor.sha256);
    for _ in 0..4 {
        ubuntu.tick(false).unwrap();
        mac.tick(false).unwrap();
    }
    assert_eq!(
        mac.file_transfers()
            .unwrap()
            .iter()
            .find(|item| item.id == descriptor.id)
            .unwrap()
            .status,
        "ready"
    );
    stop_tx.send(()).unwrap();
    server.join().unwrap();
}

#[test]
fn approval_consumes_invite_atomically_and_replays_only_the_same_transaction() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = RelayStore::open(&dir.path().join("relay.db"), "registration").unwrap();
    let owner = OwnerIdentity::generate();
    let mac = DeviceIdentity::generate();
    let linux = DeviceIdentity::generate();
    let mac_roster = SignedRoster::sign("space", 1, vec![mac.member("Device")], &owner).unwrap();
    store
        .bootstrap(
            mac_roster,
            &owner.public_key(),
            &mac.id,
            &credential_hash("owner"),
        )
        .unwrap();
    let auth = store.authenticate("owner").unwrap();
    let now = unix_time();
    let invite = PairInvite::new("space", "https://sync.example", &owner, &mac, now);
    store
        .register_invite(&auth, &invite.id, invite.expires, now)
        .unwrap();
    let request = JoinRequest::create(&invite, &linux, now).unwrap();
    store.request_join(&request, now).unwrap();
    let roster = SignedRoster::sign(
        "space",
        2,
        vec![mac.member("Device"), linux.member("Device")],
        &owner,
    )
    .unwrap();
    let token_hash = credential_hash("linux-token");
    let digest = request.digest();
    let enrollment = Some((
        linux.id.as_str(),
        token_hash.as_str(),
        invite.id.as_str(),
        request.id.as_str(),
        digest.as_str(),
    ));
    store.publish(&auth, roster.clone(), enrollment).unwrap();
    store.publish(&auth, roster.clone(), enrollment).unwrap();
    let second = DeviceIdentity::generate();
    let second_roster = SignedRoster::sign(
        "space",
        3,
        vec![
            mac.member("Device"),
            linux.member("Device"),
            second.member("Device"),
        ],
        &owner,
    )
    .unwrap();
    let second_hash = credential_hash("second-token");
    let changed = Some((
        second.id.as_str(),
        second_hash.as_str(),
        invite.id.as_str(),
        request.id.as_str(),
        digest.as_str(),
    ));
    assert!(store.publish(&auth, second_roster, changed).is_err());
    assert!(store.authenticate("linux-token").is_ok());
    assert!(store.authenticate("second-token").is_err());
    assert!(store.joins(&auth, now).unwrap().is_empty());
    assert!(
        store
            .register_invite(&auth, &invite.id, invite.expires, now)
            .is_err()
    );
}

#[test]
fn maintenance_retains_terminal_status_for_37_days_and_never_prunes_pending() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("relay.db");
    let mut store = RelayStore::open(&path, "registration").unwrap();
    let owner = OwnerIdentity::generate();
    let sender = DeviceIdentity::generate();
    let receiver = DeviceIdentity::generate();
    store
        .bootstrap(
            SignedRoster::sign("space", 1, vec![sender.member("Device")], &owner).unwrap(),
            &owner.public_key(),
            &sender.id,
            &credential_hash("sender"),
        )
        .unwrap();
    let auth = store.authenticate("sender").unwrap();
    enroll(
        &mut store, &auth, &owner, "space", &sender, &receiver, "receiver",
    );
    let receiver_auth = store.authenticate("receiver").unwrap();
    let base = unix_time();
    let acknowledged = ClipEvent::new(sender.id.clone(), 1, PortableClip::text("done", base));
    let acked_envelope = seal_event(
        "space",
        2,
        &sender,
        &receiver.member("Device"),
        &acknowledged,
    )
    .unwrap();
    let ack_cursor = store.submit(&auth, &acked_envelope, base).unwrap();
    store.ack(&receiver_auth, ack_cursor).unwrap();
    let terminal_at = unix_time();
    let pending_submitted_at = terminal_at + 10 * 24 * 60 * 60;
    let pending = ClipEvent::new(
        sender.id.clone(),
        2,
        PortableClip::text("still pending", pending_submitted_at),
    );
    let pending_envelope =
        seal_event("space", 2, &sender, &receiver.member("Device"), &pending).unwrap();
    let pending_cursor = store
        .submit(&auth, &pending_envelope, pending_submitted_at)
        .unwrap();

    store
        .maintain(terminal_at + TERMINAL_DELIVERY_RETENTION - 1)
        .unwrap();
    assert_eq!(
        store
            .delivery_status(
                &auth,
                &acknowledged.id,
                &receiver.id,
                terminal_at + TERMINAL_DELIVERY_RETENTION - 1
            )
            .unwrap(),
        "delivered"
    );
    assert_eq!(
        store
            .mailbox(
                &receiver_auth,
                terminal_at + TERMINAL_DELIVERY_RETENTION - 1
            )
            .unwrap()[0]
            .cursor,
        pending_cursor
    );
    store
        .maintain(terminal_at + TERMINAL_DELIVERY_RETENTION)
        .unwrap();
    assert_eq!(
        store
            .delivery_status(
                &auth,
                &acknowledged.id,
                &receiver.id,
                terminal_at + TERMINAL_DELIVERY_RETENTION
            )
            .unwrap(),
        "missing"
    );
    assert_eq!(
        store
            .mailbox(&receiver_auth, terminal_at + TERMINAL_DELIVERY_RETENTION)
            .unwrap()[0]
            .cursor,
        pending_cursor
    );

    let pending_expiry = pending_submitted_at + DELIVERY_TTL;
    store.maintain(pending_expiry).unwrap();
    assert_eq!(
        store
            .delivery_status(&auth, &pending.id, &receiver.id, pending_expiry)
            .unwrap(),
        "expired"
    );
    assert!(store.ack(&receiver_auth, pending_cursor).is_err());
    drop(store);
    let mut reopened = RelayStore::open(&path, "registration").unwrap();
    let auth = reopened.authenticate("sender").unwrap();
    assert_eq!(
        reopened
            .delivery_status(&auth, &pending.id, &receiver.id, pending_expiry)
            .unwrap(),
        "expired"
    );
}

#[test]
fn retained_delivery_metadata_has_a_hard_global_row_cap() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("relay.db");
    let mut store = RelayStore::open(&path, "registration").unwrap();
    let owner = OwnerIdentity::generate();
    let sender = DeviceIdentity::generate();
    let receiver = DeviceIdentity::generate();
    store
        .bootstrap(
            SignedRoster::sign("space", 1, vec![sender.member("Device")], &owner).unwrap(),
            &owner.public_key(),
            &sender.id,
            &credential_hash("sender"),
        )
        .unwrap();
    let auth = store.authenticate("sender").unwrap();
    enroll(
        &mut store, &auth, &owner, "space", &sender, &receiver, "receiver",
    );
    drop(store);

    let db = rusqlite::Connection::open(&path).unwrap();
    let tx = db.unchecked_transaction().unwrap();
    let now = unix_time();
    {
        let mut insert = tx.prepare("INSERT INTO deliveries(workspace,sender,recipient,event,envelope,status,created,terminal_at) VALUES('other','s','r',?1,NULL,'delivered',?2,?2)").unwrap();
        for index in 0..MAX_RETAINED_DELIVERIES {
            insert
                .execute(rusqlite::params![format!("row-{index}"), now])
                .unwrap();
        }
    }
    tx.commit().unwrap();
    drop(db);

    let mut store = RelayStore::open(&path, "registration").unwrap();
    let auth = store.authenticate("sender").unwrap();
    let event = ClipEvent::new(
        sender.id.clone(),
        1,
        PortableClip::text("one too many", unix_time()),
    );
    let envelope = seal_event("space", 2, &sender, &receiver.member("Device"), &event).unwrap();
    assert!(matches!(
        store.submit(&auth, &envelope, unix_time()),
        Err(SyncError::Capacity)
    ));
}

#[test]
fn opening_store_prunes_stale_terminal_rows_and_keeps_pending_ciphertext() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("relay.db");
    let store = RelayStore::open(&path, "registration").unwrap();
    drop(store);
    let now = unix_time();
    let db = rusqlite::Connection::open(&path).unwrap();
    db.execute("INSERT INTO deliveries(workspace,sender,recipient,event,envelope,status,created,terminal_at) VALUES('space','a','b','stale-terminal',NULL,'delivered',?1,?1)", [now - TERMINAL_DELIVERY_RETENTION - 1]).unwrap();
    db.execute("INSERT INTO deliveries(workspace,sender,recipient,event,envelope,status,created,terminal_at) VALUES('space','a','b','pending-row','ciphertext','pending',?1,NULL)", [now - DELIVERY_TTL + 3600]).unwrap();
    drop(db);
    let store = RelayStore::open(&path, "registration").unwrap();
    drop(store);
    let db = rusqlite::Connection::open(&path).unwrap();
    let retained: u64 = db
        .query_row("SELECT COUNT(*) FROM deliveries", [], |r| r.get(0))
        .unwrap();
    let pending: u64 = db
        .query_row(
            "SELECT COUNT(*) FROM deliveries WHERE status='pending' AND envelope='ciphertext'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(retained, 1);
    assert_eq!(pending, 1);
}

#[tokio::test]
async fn relay_requires_authentication_and_keeps_ciphertext_opaque() {
    let dir = tempfile::tempdir().unwrap();
    let app =
        router(RelayStore::open(&dir.path().join("relay.db"), "registration-secret").unwrap());
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/v1/roster")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    let device = DeviceIdentity::generate();
    let owner = OwnerIdentity::generate();
    let roster = SignedRoster::sign("workspace", 1, vec![device.member("Device")], &owner).unwrap();
    let body = serde_json::json!({"roster":roster,"owner_key":owner.public_key(),"owner_device":device.id,"token_hash":credential_hash("owner-token")});
    let request = |token: &str| {
        Request::builder()
            .method("POST")
            .uri("/v1/workspaces")
            .header("content-type", "application/json")
            .header("authorization", format!("Bearer {token}"))
            .body(Body::from(body.to_string()))
            .unwrap()
    };
    assert_eq!(
        app.clone()
            .oneshot(request("wrong"))
            .await
            .unwrap()
            .status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        app.clone()
            .oneshot(request("registration-secret"))
            .await
            .unwrap()
            .status(),
        StatusCode::OK
    );
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/v1/roster")
                .header("authorization", "Bearer owner-token")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = std::fs::read(dir.path().join("relay.db")).unwrap();
    assert!(!String::from_utf8_lossy(&bytes).contains("owner-token"));
}

#[test]
fn relay_enforces_membership_delivery_ack_idempotency_and_revocation() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("relay.db");
    let mut store = RelayStore::open(&path, "registration").unwrap();
    let owner = OwnerIdentity::generate();
    let mac = DeviceIdentity::generate();
    let linux = DeviceIdentity::generate();
    let stranger = DeviceIdentity::generate();
    let roster = SignedRoster::sign("space", 1, vec![mac.member("Device")], &owner).unwrap();
    store
        .bootstrap(
            roster,
            &owner.public_key(),
            &mac.id,
            &credential_hash("mac"),
        )
        .unwrap();
    let owner_auth = store.authenticate("mac").unwrap();
    enroll(
        &mut store,
        &owner_auth,
        &owner,
        "space",
        &mac,
        &linux,
        "linux",
    );
    let linux_auth = store.authenticate("linux").unwrap();
    let event = ClipEvent::new(mac.id.clone(), 1, PortableClip::text("opaque message", 1));
    let envelope = seal_event("space", 2, &mac, &linux.member("Device"), &event).unwrap();
    let cursor = store.submit(&owner_auth, &envelope, 10).unwrap();
    assert_eq!(store.submit(&owner_auth, &envelope, 11).unwrap(), cursor);
    assert!(store.submit(&linux_auth, &envelope, 10).is_err());
    assert_eq!(store.mailbox(&linux_auth, 10).unwrap().len(), 1);
    assert!(store.ack(&owner_auth, cursor).is_err());
    store.ack(&linux_auth, cursor).unwrap();
    assert_eq!(
        store
            .delivery_status(&owner_auth, &event.id, &linux.id, 12)
            .unwrap(),
        "delivered"
    );
    assert!(store.mailbox(&linux_auth, 12).unwrap().is_empty());
    let rejected = ClipEvent::new(
        mac.id.clone(),
        2,
        PortableClip::text("unusable representation", 2),
    );
    let envelope2 = seal_event("space", 2, &mac, &linux.member("Device"), &rejected).unwrap();
    let cursor2 = store.submit(&owner_auth, &envelope2, 12).unwrap();
    assert!(store.reject(&owner_auth, cursor2).is_err());
    store.reject(&linux_auth, cursor2).unwrap();
    store.reject(&linux_auth, cursor2).unwrap();
    assert_eq!(
        store
            .delivery_status(&owner_auth, &rejected.id, &linux.id, 12)
            .unwrap(),
        "rejected"
    );
    assert!(store.mailbox(&linux_auth, 12).unwrap().is_empty());
    let roster = SignedRoster::sign("space", 3, vec![mac.member("Device")], &owner).unwrap();
    store.publish(&owner_auth, roster, None).unwrap();
    assert!(store.authenticate("linux").is_err());
    assert!(store.submit(&owner_auth, &envelope, 12).is_err());
    assert!(store.authenticate(&stranger.id).is_err());
    drop(store);
    let store = RelayStore::open(&path, "registration").unwrap();
    assert!(store.authenticate("mac").is_ok());
    assert!(!String::from_utf8_lossy(&std::fs::read(path).unwrap()).contains("opaque message"));
}

#[test]
fn pending_delivery_survives_restart_is_workspace_scoped_and_expires_at_boundary() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("relay.db");
    let now = unix_time();
    let owner = OwnerIdentity::generate();
    let sender = DeviceIdentity::generate();
    let receiver = DeviceIdentity::generate();
    let mut store = RelayStore::open(&path, "registration").unwrap();
    store
        .bootstrap(
            SignedRoster::sign("first", 1, vec![sender.member("Owner")], &owner).unwrap(),
            &owner.public_key(),
            &sender.id,
            &credential_hash("first-owner"),
        )
        .unwrap();
    let sender_auth = store.authenticate("first-owner").unwrap();
    enroll(
        &mut store,
        &sender_auth,
        &owner,
        "first",
        &sender,
        &receiver,
        "first-receiver",
    );
    let receiver_auth = store.authenticate("first-receiver").unwrap();
    // Reusing a device identity in another workspace must not grant mailbox access.
    let other_owner = OwnerIdentity::generate();
    store
        .bootstrap(
            SignedRoster::sign(
                "other",
                1,
                vec![receiver.member("Other owner")],
                &other_owner,
            )
            .unwrap(),
            &other_owner.public_key(),
            &receiver.id,
            &credential_hash("other-owner"),
        )
        .unwrap();
    let other_auth = store.authenticate("other-owner").unwrap();
    let event = ClipEvent::new(
        sender.id.clone(),
        1,
        PortableClip::text("pending private clip", 10),
    );
    let envelope = seal_event("first", 2, &sender, &receiver.member("Receiver"), &event).unwrap();
    let first = store.submit(&sender_auth, &envelope, now).unwrap();
    let second_event = ClipEvent::new(
        sender.id.clone(),
        2,
        PortableClip::text("second private clip", 11),
    );
    let second_envelope = seal_event(
        "first",
        2,
        &sender,
        &receiver.member("Receiver"),
        &second_event,
    )
    .unwrap();
    let second = store
        .submit(&sender_auth, &second_envelope, now + 1)
        .unwrap();
    assert_eq!(store.mailbox(&receiver_auth, now + 1).unwrap().len(), 1);
    assert!(store.mailbox(&other_auth, now + 1).unwrap().is_empty());
    assert!(store.ack(&other_auth, first).is_err());
    assert!(store.reject(&other_auth, first).is_err());
    assert!(store.submit(&other_auth, &envelope, now + 1).is_err());
    assert_eq!(
        store
            .delivery_status(&other_auth, &event.id, &receiver.id, now + 1)
            .unwrap(),
        "missing"
    );
    drop(store);
    let mut store = RelayStore::open(&path, "registration").unwrap();
    let receiver_auth = store.authenticate("first-receiver").unwrap();
    assert_eq!(
        store
            .mailbox(&receiver_auth, now + DELIVERY_TTL - 1)
            .unwrap()[0]
            .cursor,
        first
    );
    assert_eq!(
        store.mailbox(&receiver_auth, now + DELIVERY_TTL).unwrap()[0].cursor,
        second
    );
    assert_eq!(
        store
            .delivery_status(&sender_auth, &event.id, &receiver.id, now + DELIVERY_TTL)
            .unwrap(),
        "expired"
    );
    assert!(store.ack(&receiver_auth, first).is_err());
    assert!(
        store
            .mailbox(&receiver_auth, now + DELIVERY_TTL + 1)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        store
            .submit(&sender_auth, &envelope, now + DELIVERY_TTL + 2)
            .unwrap(),
        first
    );
    assert!(
        store
            .mailbox(&receiver_auth, now + DELIVERY_TTL + 2)
            .unwrap()
            .is_empty()
    );
    let raw = std::fs::read(path).unwrap();
    assert!(!String::from_utf8_lossy(&raw).contains("private clip"));
}

#[test]
#[ignore = "writes a real 256 MiB mailbox; run explicitly for the quota gate"]
fn mailbox_quota_rejects_without_eviction_and_acknowledgement_releases_capacity() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("quota.db");
    let owner = OwnerIdentity::generate();
    let sender = DeviceIdentity::generate();
    let receiver = DeviceIdentity::generate();
    let mut store = RelayStore::open(&path, "registration").unwrap();
    store
        .bootstrap(
            SignedRoster::sign("quota", 1, vec![sender.member("Owner")], &owner).unwrap(),
            &owner.public_key(),
            &sender.id,
            &credential_hash("owner"),
        )
        .unwrap();
    let sender_auth = store.authenticate("owner").unwrap();
    enroll(
        &mut store,
        &sender_auth,
        &owner,
        "quota",
        &sender,
        &receiver,
        "receiver",
    );
    let receiver_auth = store.authenticate("receiver").unwrap();
    let mut first_cursor = None;
    let mut accepted = 0;
    // Store maintenance runs with wall-clock time on reopen; use a real timestamp
    // so this fixture continues to represent pending mailbox data after restart.
    let now = unix_time();
    let rejected = loop {
        let event = ClipEvent::new(
            sender.id.clone(),
            accepted + 1,
            PortableClip::text("fixture", 1),
        );
        let mut envelope =
            seal_event("quota", 2, &sender, &receiver.member("Receiver"), &event).unwrap();
        // The relay treats ciphertext as opaque. A paired compromised sender
        // can submit arbitrary bytes; the quota must hold without decrypting.
        envelope.ciphertext = "A".repeat(20 * 1024 * 1024);
        match store.submit(&sender_auth, &envelope, now) {
            Ok(cursor) => {
                first_cursor.get_or_insert(cursor);
                accepted += 1;
                assert!(accepted <= 12);
            }
            Err(SyncError::Capacity) => break envelope,
            Err(error) => panic!("unexpected quota result: {error}"),
        }
    };
    assert_eq!(accepted, 12);
    assert_eq!(
        store.mailbox(&receiver_auth, now + 1).unwrap()[0].cursor,
        first_cursor.unwrap()
    );
    assert_eq!(
        store
            .delivery_status(&sender_auth, &rejected.header.event, &receiver.id, now + 1)
            .unwrap(),
        "missing"
    );
    drop(store);
    let mut store = RelayStore::open(&path, "registration").unwrap();
    assert!(matches!(
        store.submit(&sender_auth, &rejected, now + 2),
        Err(SyncError::Capacity)
    ));
    store.ack(&receiver_auth, first_cursor.unwrap()).unwrap();
    assert!(store.submit(&sender_auth, &rejected, now + 2).is_ok());
}
