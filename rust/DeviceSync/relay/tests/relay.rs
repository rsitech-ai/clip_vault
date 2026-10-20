use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use clipvault_sync_core::*;
use clipvault_sync_relay::*;
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
