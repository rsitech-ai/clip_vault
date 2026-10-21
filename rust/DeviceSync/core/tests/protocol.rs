use clipvault_sync_core::*;

#[test]
fn sensitive_rules_cover_all_swift_aws_prefixes() {
    for prefix in [
        "A3TA", "AKIA", "AGPA", "AIDA", "AROA", "AIPA", "ANPA", "ANVA",
    ] {
        assert!(sensitive(&format!("{prefix}{}", "A".repeat(16))));
    }
}

fn clip() -> PortableClip {
    PortableClip::text("A private clip from another device", 1_792_483_200)
}

#[test]
fn authenticated_text_and_image_round_trip() {
    let sender = DeviceIdentity::generate();
    let receiver = DeviceIdentity::generate();
    let event = ClipEvent::new(sender.id.clone(), 1, clip());
    let envelope = seal_event("workspace", 1, &sender, &receiver.member("Laptop"), &event).unwrap();
    let wire = serde_json::to_vec(&envelope).unwrap();
    assert!(!String::from_utf8_lossy(&wire).contains("private clip"));
    assert_eq!(
        open_event("workspace", &receiver, &sender.member("Mac"), &envelope).unwrap(),
        event
    );
    let mut image = clip();
    image.kind = "image".into();
    image.image_png = Some("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGPQbD/+HwAEywJ3k0b7vgAAAABJRU5ErkJggg==".into());
    let event = ClipEvent::new(sender.id.clone(), 2, image);
    let envelope = seal_event("workspace", 1, &sender, &receiver.member("Laptop"), &event).unwrap();
    assert_eq!(
        open_event("workspace", &receiver, &sender.member("Mac"), &envelope).unwrap(),
        event
    );
}

#[test]
fn wrong_identity_tampering_and_context_are_rejected() {
    let sender = DeviceIdentity::generate();
    let receiver = DeviceIdentity::generate();
    let other = DeviceIdentity::generate();
    let event = ClipEvent::new(sender.id.clone(), 1, clip());
    let envelope = seal_event("workspace", 4, &sender, &receiver.member("Laptop"), &event).unwrap();
    assert!(open_event("workspace", &other, &sender.member("Mac"), &envelope).is_err());
    assert!(open_event("workspace", &receiver, &other.member("Mac"), &envelope).is_err());
    assert!(open_event("wrong", &receiver, &sender.member("Mac"), &envelope).is_err());
    let mut changed = envelope.clone();
    changed.header.sequence += 1;
    assert!(open_event("workspace", &receiver, &sender.member("Mac"), &changed).is_err());
    changed = envelope.clone();
    changed.ciphertext.push('A');
    assert!(open_event("workspace", &receiver, &sender.member("Mac"), &changed).is_err());
}

#[test]
fn signed_membership_rejects_rollback_and_modification() {
    let owner = OwnerIdentity::generate();
    let device = DeviceIdentity::generate();
    let mut roster =
        SignedRoster::sign("workspace", 2, vec![device.member("Mac")], &owner).unwrap();
    roster.verify(&owner.public_key(), 2).unwrap();
    assert!(roster.verify(&owner.public_key(), 3).is_err());
    assert!(roster.member("missing").is_err());
    roster.members[0].name = "Changed".into();
    assert!(roster.verify(&owner.public_key(), 1).is_err());
}

#[test]
fn payload_bounds_secrets_and_invalid_images_are_rejected() {
    let mut item = clip();
    item.text = "x".repeat(MAX_PAYLOAD_BYTES + 1);
    assert!(item.validate().is_err());
    assert!(
        PortableClip::text("-----BEGIN PRIVATE KEY-----", 0)
            .validate()
            .is_err()
    );
    item = clip();
    item.kind = "image".into();
    item.image_png = Some("invalid".into());
    assert!(item.validate().is_err());
    item = clip();
    item.captured_at = -1;
    assert!(item.validate().is_err());
}

#[test]
fn sensitive_text_in_decoded_rtf_comments_is_rejected() {
    let mut item = PortableClip::text("hello", 1);
    item.kind = "richText".into();
    item.metadata.insert(
        "rtf".into(),
        "e1xydGYxe1wqXGNvbW1lbnQgcGFzc3dvcmQ9c2VjcmV0MTIzNDV9IGhlbGxvfQ==".into(),
    );
    assert!(matches!(item.validate(), Err(SyncError::Sensitive)));
}
