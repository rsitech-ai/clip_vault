use clipvault_sync_core::*;

#[test]
fn pair_requires_invite_secret_matching_transcript_and_nonexpired_single_use() {
    let owner = OwnerIdentity::generate();
    let mac = DeviceIdentity::generate();
    let ubuntu = DeviceIdentity::generate();
    let invite = PairInvite::new("workspace", "https://sync.example", &owner, &mac, 100);
    let join = JoinRequest::create(&invite, &ubuntu, 101).unwrap();
    let approved = join.open(&invite, &mac, 102).unwrap();
    assert_eq!(approved.member.id, ubuntu.id);
    assert_eq!(approved.words(), join.words());
    assert!(join.open(&invite, &mac, 761).is_err());
    let mut wrong = invite.clone();
    wrong.secret = secret_string();
    assert!(join.open(&wrong, &mac, 102).is_err());
    let mut changed = join.clone();
    changed.device_id = mac.id.clone();
    assert!(changed.open(&invite, &mac, 102).is_err());
    let mut used = invite;
    used.consume(102).unwrap();
    assert!(used.consume(103).is_err());
    assert!(join.open(&used, &mac, 104).is_err());
}

#[test]
fn pairing_authenticates_relay_and_expiry_transcript_with_bounded_clock_skew() {
    let owner = OwnerIdentity::generate();
    let mac = DeviceIdentity::generate();
    let linux = DeviceIdentity::generate();
    let invite = PairInvite::new("workspace", "https://sync.example", &owner, &mac, 100);
    let join = JoinRequest::create(&invite, &linux, 100).unwrap();
    assert!(join.open(&invite, &mac, 101).is_ok());
    assert!(join.open(&invite, &mac, 160).is_ok());

    let mut changed_relay = invite.clone();
    changed_relay.relay = "https://attacker.example".into();
    assert!(join.open(&changed_relay, &mac, 101).is_err());
    let mut changed_expiry = invite.clone();
    changed_expiry.expires += 1;
    assert!(join.open(&changed_expiry, &mac, 101).is_err());
    assert!(invite.validate(761).is_err());
    let mut too_far_future = invite.clone();
    too_far_future.expires = 761;
    assert!(too_far_future.validate(100).is_err());
    assert!(invite.validate(40).is_ok());
}

#[test]
fn owner_invite_clock_lead_within_sixty_seconds_is_accepted() {
    let owner = OwnerIdentity::generate();
    let mac = DeviceIdentity::generate();
    let invite = PairInvite::new("workspace", "https://sync.example", &owner, &mac, 100);
    assert!(invite.validate(40).is_ok());
    assert!(invite.validate(760).is_ok());
    assert!(invite.validate(761).is_err());
}

#[test]
fn join_request_shape_rejects_unbounded_fields_before_transport_storage() {
    let owner = OwnerIdentity::generate();
    let mac = DeviceIdentity::generate();
    let linux = DeviceIdentity::generate();
    let invite = PairInvite::new("workspace", "https://sync.example", &owner, &mac, 100);
    let request = JoinRequest::create(&invite, &linux, 101).unwrap();
    assert!(request.validate_shape().is_ok());

    let mut oversized = request.clone();
    oversized.encapsulated_key = "A".repeat(2 * 1024 * 1024);
    assert!(oversized.validate_shape().is_err());
    let mut malformed = request;
    malformed.device_id = "not-a-uuid".into();
    assert!(malformed.validate_shape().is_err());
}
