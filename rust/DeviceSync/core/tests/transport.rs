use clipvault_sync_core::*;

#[test]
fn newer_membership_is_deferred_without_ack_or_rejection() {
    let owner = OwnerIdentity::generate();
    let sender = DeviceIdentity::generate();
    let receiver = DeviceIdentity::generate();
    let roster =
        SignedRoster::sign("workspace", 1, vec![receiver.member("Device")], &owner).unwrap();
    let event = ClipEvent::new(
        sender.id.clone(),
        1,
        PortableClip::text("valid future clip", 1),
    );
    let envelope = seal_event("workspace", 2, &sender, &receiver.member("Device"), &event).unwrap();
    assert!(matches!(
        classify_incoming(&roster, &receiver, &envelope),
        Incoming::Deferred
    ));
    let newer = SignedRoster::sign(
        "workspace",
        2,
        vec![receiver.member("Device"), sender.member("Device")],
        &owner,
    )
    .unwrap();
    assert!(matches!(
        classify_incoming(&newer, &receiver, &envelope),
        Incoming::Event(_)
    ));
}
#[test]
fn endpoint_policy_rejects_remote_http_credentials_and_nonorigin_urls() {
    assert!(validate_endpoint("https://sync.example").is_ok());
    assert!(validate_endpoint("http://127.0.0.1:9999").is_ok());
    assert!(validate_endpoint("http://[::1]:9999").is_ok());
    for endpoint in [
        "http://sync.example",
        "https://user:pass@sync.example",
        "file:///tmp/socket",
        "https://sync.example/path",
        "https://sync.example?token=x",
        "https://sync.example#fragment",
        "http://127.0.0.1.evil.example",
    ] {
        assert!(validate_endpoint(endpoint).is_err(), "{endpoint}");
    }
}

#[test]
fn disabled_client_never_connects_and_capture_does_not_export_existing_history() {
    let dir = tempfile::tempdir().unwrap();
    let store = DeviceStore::open(&dir.path().join("client.db"), random_secret()).unwrap();
    let mut client = SyncClient::open(store).unwrap();
    assert_eq!(client.tick(false).unwrap().state, "Sharing off");
    assert!(
        client
            .capture(PortableClip::text("local-only", 1), None)
            .unwrap()
            .is_some()
    );
    assert!(client.store.pending().unwrap().is_empty());
    assert_eq!(client.store.history().unwrap().len(), 1);
}
