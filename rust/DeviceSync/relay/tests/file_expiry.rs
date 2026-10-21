use clipvault_sync_core::*;
use clipvault_sync_relay::{RelayStore, router};
use rusqlite::{Connection, params};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn pruned_file_delivery_is_not_resubmitted_after_first_attempt_expires() {
    check_expired_file(false).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn legacy_file_jobs_migrate_without_restarting_expired_delivery() {
    check_expired_file(true).await;
}

async fn check_expired_file(legacy_schema: bool) {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().to_path_buf();
    let relay_path = root.join("relay.db");
    let relay = router(RelayStore::open(&relay_path, "registration").unwrap());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, relay).await.unwrap() });
    let result = tokio::task::spawn_blocking(move || {
        let key = random_secret();
        let sender_path = root.join("sender.db");
        let open = || SyncClient::open(DeviceStore::open(&sender_path, key).unwrap()).unwrap();
        let mut sender = open();
        let mut receiver = SyncClient::open(
            DeviceStore::open(&root.join("receiver.db"), random_secret()).unwrap(),
        )
        .unwrap();
        sender.create_workspace(&endpoint, "registration", "Sender").unwrap();
        let words = receiver.join(&sender.create_invite().unwrap(), "Receiver").unwrap();
        let request = sender.pairing_requests().unwrap().remove(0);
        sender.approve(&request.id, &words).unwrap();
        receiver.tick(false).unwrap();
        sender.tick(false).unwrap();
        let source = root.join("expired.bin");
        std::fs::write(&source, b"keep the local copy after expiry").unwrap();
        let descriptor = sender.stage_file(&source, || false).unwrap();
        let event = sender.capture(PortableClip::attachment(&descriptor), None).unwrap().unwrap();
        sender.commit_file(&descriptor.id, &event).unwrap();
        sender.tick(false).unwrap();
        drop(sender);

        // Model a long offline sender and the relay's documented terminal-state
        // pruning. Operational timestamps alone are changed, never ciphertext.
        let old = unix_time() - DELIVERY_MAX_RETRY_AGE - 10;
        let db = Connection::open(&sender_path).unwrap();
        let has_first_attempt: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM pragma_table_info('file_jobs') WHERE name='first_attempted_at')",
            [], |row| row.get(0),
        ).unwrap();
        if legacy_schema {
            assert!(has_first_attempt);
            db.execute("ALTER TABLE file_jobs DROP COLUMN first_attempted_at", []).unwrap();
            db.execute("UPDATE file_transfers SET created_at=?1 WHERE id=?2", params![old, descriptor.id]).unwrap();
        } else if has_first_attempt {
            db.execute("UPDATE file_jobs SET first_attempted_at=?1 WHERE transfer=?2", params![old,descriptor.id]).unwrap();
        }
        db.execute("UPDATE file_jobs SET attempted_at=?1 WHERE transfer=?2", params![old,descriptor.id]).unwrap();
        drop(db);
        let db = Connection::open(&relay_path).unwrap();
        db.execute("UPDATE deliveries SET status='expired',envelope=NULL,created=?1,terminal_at=?1", [old]).unwrap();
        drop(db);
        RelayStore::open(&relay_path, "registration").unwrap().maintain(unix_time()).unwrap();
        let mut sender = open();
        sender.tick(false).unwrap();
        let db = Connection::open(&relay_path).unwrap();
        let retained: usize = db.query_row("SELECT COUNT(*) FROM deliveries", [], |row| row.get(0)).unwrap();
        assert_eq!(retained, 0, "expired frames must not restart their relay lifetime");
        assert_eq!(sender.file_transfers().unwrap().iter().find(|f| f.id == descriptor.id).unwrap().status, "failed");
        let saved = root.join("retained.bin");
        sender.store.save_file(&descriptor.id, &saved, || false).unwrap();
        assert_eq!(std::fs::read(saved).unwrap(), b"keep the local copy after expiry");
    }).await;
    server.abort();
    result.unwrap();
}
