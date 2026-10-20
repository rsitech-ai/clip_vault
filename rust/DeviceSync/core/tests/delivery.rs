use clipvault_sync_core::*;

#[test]
fn capacity_failure_retains_local_content_and_deferred_targets() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = DeviceStore::open(&dir.path().join("capacity.db"), random_secret()).unwrap();
    let sender = DeviceIdentity::generate();
    let recipient = DeviceIdentity::generate();
    let event = ClipEvent::new(sender.id.clone(), 1, PortableClip::text("keep local", 1));
    store.set_queue_limit(1);
    assert!(matches!(
        store.capture_with_targets(&event, std::slice::from_ref(&recipient.id)),
        Err(SyncError::Capacity)
    ));
    store
        .defer_capture(&event, std::slice::from_ref(&recipient.id))
        .unwrap();
    assert_eq!(store.history().unwrap().len(), 1);
    assert_eq!(store.pending_count().unwrap(), 1);
    assert!(store.pending().unwrap().is_empty());
    store.set_queue_limit(MAX_QUEUE_BYTES);
    store.promote_deferred().unwrap();
    assert_eq!(store.pending().unwrap().len(), 1);
    assert_eq!(
        store.targets(&event.id).unwrap(),
        vec![recipient.id.clone()]
    );
}

#[test]
fn rejected_platform_import_is_durable_and_does_not_block_next_item() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = DeviceStore::open(&dir.path().join("reject.db"), random_secret()).unwrap();
    let sender = DeviceIdentity::generate();
    let event = ClipEvent::new(
        sender.id.clone(),
        1,
        PortableClip::text("unusable on this platform", 1),
    );
    store.receive(&event, 1).unwrap();
    store.reject_import(&event.id).unwrap();
    assert!(store.unapplied().unwrap().is_empty());
    assert_eq!(store.acknowledgements().unwrap(), vec![1]);
    assert!(store.receipt_rejected(1).unwrap());
    let next = ClipEvent::new(
        sender.id.clone(),
        2,
        PortableClip::text("next valid clip", 2),
    );
    assert!(store.receive(&next, 2).unwrap());
}

#[test]
fn work_queues_are_oldest_first_and_count_all_pending_events() {
    let dir = tempfile::tempdir().unwrap();
    let sender = DeviceIdentity::generate();
    let mut store = DeviceStore::open(&dir.path().join("queue.db"), random_secret()).unwrap();
    let first = ClipEvent::new(sender.id.clone(), 1, PortableClip::text("oldest", 1));
    store.capture(&first).unwrap();
    for sequence in 2..=2002 {
        store
            .capture(&ClipEvent::new(
                sender.id.clone(),
                sequence,
                PortableClip::text("later", sequence as i64),
            ))
            .unwrap();
    }
    assert_eq!(store.pending().unwrap().first().unwrap().id, first.id);
    assert_eq!(store.pending_count().unwrap(), 2002);
    let older = store
        .matching_history(10, |event| event.clip.text == "oldest")
        .unwrap();
    assert_eq!(older.len(), 1);
}

#[test]
fn pending_and_unapplied_batches_are_byte_bounded_and_drain_oldest_first() {
    let dir = tempfile::tempdir().unwrap();
    let mut store =
        DeviceStore::open(&dir.path().join("large-batches.db"), random_secret()).unwrap();
    let sender = DeviceIdentity::generate();
    let recipient = DeviceIdentity::generate();
    let recipients = vec![recipient.id.clone()];
    let payload = "x".repeat(1024 * 1024);
    let mut outbound_ids = Vec::new();
    let mut inbound_ids = Vec::new();
    for sequence in 1..=11 {
        let outgoing = ClipEvent::new(
            sender.id.clone(),
            sequence,
            PortableClip::text(&payload, sequence as i64),
        );
        store.capture_with_targets(&outgoing, &recipients).unwrap();
        outbound_ids.push(outgoing.id);

        let incoming = ClipEvent::new(
            recipient.id.clone(),
            sequence,
            PortableClip::text(&payload, sequence as i64),
        );
        store.receive(&incoming, 100 + sequence as i64).unwrap();
        inbound_ids.push(incoming.id);
    }

    assert_eq!(store.pending_count().unwrap(), 11);
    let first_pending = store.pending().unwrap();
    assert!(!first_pending.is_empty());
    assert!(first_pending.len() < outbound_ids.len());
    assert!(serde_json::to_vec(&first_pending).unwrap().len() <= MAX_WIRE_BYTES + 1024);
    let mut drained_outbound = Vec::new();
    let mut batch = first_pending.clone();
    while !batch.is_empty() {
        assert!(serde_json::to_vec(&batch).unwrap().len() <= MAX_WIRE_BYTES + 1024);
        assert!(batch.iter().all(|event| outbound_ids.contains(&event.id)));
        for event in &batch {
            drained_outbound.push(event.id.clone());
            store
                .target_done(&event.id, &recipient.id, "delivered")
                .unwrap();
        }
        batch = store.pending().unwrap();
    }
    assert_eq!(drained_outbound.len(), outbound_ids.len());
    assert_eq!(store.pending_count().unwrap(), 0);

    let first_unapplied = store.unapplied().unwrap();
    assert!(!first_unapplied.is_empty());
    assert!(first_unapplied.len() < inbound_ids.len());
    assert!(serde_json::to_vec(&first_unapplied).unwrap().len() <= MAX_WIRE_BYTES + 1024);
    let mut drained_inbound = Vec::new();
    let mut batch = first_unapplied.clone();
    while !batch.is_empty() {
        assert!(serde_json::to_vec(&batch).unwrap().len() <= MAX_WIRE_BYTES + 1024);
        assert!(batch.iter().all(|event| inbound_ids.contains(&event.id)));
        for event in &batch {
            drained_inbound.push(event.id.clone());
            store.mark_applied(&event.id).unwrap();
        }
        batch = store.unapplied().unwrap();
    }
    assert_eq!(drained_inbound.len(), inbound_ids.len());
    assert!(store.unapplied().unwrap().is_empty());
}

#[test]
fn disconnect_rotates_identity_cancels_delivery_and_preserves_local_history() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("disconnect.db");
    let key = random_secret();
    let mut client = SyncClient::open(DeviceStore::open(&path, key).unwrap()).unwrap();
    let old_identity = client.device_id().to_string();
    let recipient = DeviceIdentity::generate();
    let outbound = ClipEvent::new(
        old_identity.clone(),
        1,
        PortableClip::text("pending local delivery", 1),
    );
    client
        .store
        .capture_with_targets(&outbound, std::slice::from_ref(&recipient.id))
        .unwrap();
    let incoming = ClipEvent::new(
        recipient.id.clone(),
        1,
        PortableClip::text("unapplied local history", 2),
    );
    client.store.receive(&incoming, 7).unwrap();

    assert_eq!(client.disconnect().unwrap(), 1);
    assert_ne!(client.device_id(), old_identity);
    assert_eq!(client.store.pending_count().unwrap(), 0);
    assert!(client.store.pending().unwrap().is_empty());
    assert!(client.store.unapplied().unwrap().is_empty());
    assert_eq!(client.store.history().unwrap().len(), 2);
    assert!(!client.status().unwrap().enabled);
    let new_identity = client.device_id().to_string();

    drop(client);
    let reopened = SyncClient::open(DeviceStore::open(&path, key).unwrap()).unwrap();
    assert_eq!(reopened.device_id(), new_identity);
    assert_eq!(reopened.store.history().unwrap().len(), 2);
    assert!(!reopened.status().unwrap().enabled);
}

#[test]
fn encrypted_capture_survives_restart_and_cancel_prevents_resurrection() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("clips.db");
    let key = random_secret();
    let identity = DeviceIdentity::generate();
    let event = ClipEvent::new(
        identity.id.clone(),
        1,
        PortableClip::text("private delivery fixture", 1),
    );
    {
        let mut store = DeviceStore::open(&path, key).unwrap();
        assert!(store.capture(&event).unwrap());
        assert!(!store.capture(&event).unwrap());
        assert_eq!(store.pending().unwrap().len(), 1);
    }
    let bytes = std::fs::read(&path).unwrap();
    assert!(!String::from_utf8_lossy(&bytes).contains("private delivery fixture"));
    let mut store = DeviceStore::open(&path, key).unwrap();
    assert_eq!(store.history().unwrap()[0], event);
    store.delete_local(&event.id).unwrap();
    assert!(store.pending().unwrap().is_empty());
    assert!(!store.receive(&event, 1).unwrap());
    assert!(store.history().unwrap().is_empty());
    assert!(DeviceStore::open(&path, random_secret()).is_err());
}

#[test]
fn import_and_ack_are_durable_and_idempotent() {
    let dir = tempfile::tempdir().unwrap();
    let key = random_secret();
    let path = dir.path().join("clips.db");
    let sender = DeviceIdentity::generate();
    let event = ClipEvent::new(sender.id.clone(), 3, PortableClip::text("inbound clip", 20));
    let mut store = DeviceStore::open(&path, key).unwrap();
    assert!(store.receive(&event, 4).unwrap());
    assert!(!store.receive(&event, 4).unwrap());
    assert!(store.pending().unwrap().is_empty());
    assert_eq!(store.unapplied().unwrap().len(), 1);
    assert!(store.acknowledgements().unwrap().is_empty());
    store.mark_applied(&event.id).unwrap();
    assert_eq!(store.acknowledgements().unwrap(), vec![4]);
    drop(store);
    let mut store = DeviceStore::open(&path, key).unwrap();
    assert_eq!(store.acknowledgements().unwrap(), vec![4]);
    store.mark_acknowledged(4).unwrap();
    assert!(store.acknowledgements().unwrap().is_empty());
    assert_eq!(store.history().unwrap().len(), 1);
}

#[test]
fn identity_and_sequences_are_transactional_and_payload_collision_is_rejected() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = DeviceStore::open(&dir.path().join("state.db"), random_secret()).unwrap();
    assert_eq!(store.next_sequence().unwrap(), 1);
    assert_eq!(store.next_sequence().unwrap(), 2);
    store
        .put("settings", &vec!["private state".to_string()])
        .unwrap();
    assert_eq!(
        store.get::<Vec<String>>("settings").unwrap().unwrap(),
        vec!["private state"]
    );
    let sender = DeviceIdentity::generate();
    let event = ClipEvent::new(sender.id.clone(), 3, PortableClip::text("first", 20));
    store.receive(&event, 1).unwrap();
    let mut collision = event.clone();
    collision.clip.text = "replacement".into();
    assert!(store.receive(&collision, 2).is_err());
}

#[test]
fn capture_and_recipient_snapshot_are_atomic_and_sequence_replay_is_rejected() {
    let dir = tempfile::tempdir().unwrap();
    let key = random_secret();
    let path = dir.path().join("atomic.db");
    let sender = DeviceIdentity::generate();
    let recipient = DeviceIdentity::generate();
    let event = ClipEvent::new(sender.id.clone(), 1, PortableClip::text("queued", 1));
    let mut store = DeviceStore::open(&path, key).unwrap();
    store
        .capture_with_targets(&event, std::slice::from_ref(&recipient.id))
        .unwrap();
    drop(store);
    let mut store = DeviceStore::open(&path, key).unwrap();
    assert_eq!(
        store.targets(&event.id).unwrap(),
        vec![recipient.id.clone()]
    );
    let mut collision = event.clone();
    collision.id = uuid::Uuid::new_v4().to_string();
    assert!(matches!(
        store.receive(&collision, 2),
        Err(SyncError::Authentication)
    ));
}
