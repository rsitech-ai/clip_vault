use clipvault_sync_core::*;
use rusqlite::Connection;

#[test]
fn staged_history_and_chunks_cancel_atomically_even_before_commit() {
    for captured in [false, true] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("client.db");
        let key = random_secret();
        let mut client = SyncClient::open(DeviceStore::open(&path, key).unwrap()).unwrap();
        let source = dir.path().join("source.txt");
        std::fs::write(&source, b"cancel this synthetic staged attachment").unwrap();
        let descriptor = client.stage_file(&source, || false).unwrap();
        let event_id = uuid::Uuid::new_v4().to_string();
        if captured {
            client
                .capture(PortableClip::attachment(&descriptor), Some(&event_id))
                .unwrap();
            let db = Connection::open(&path).unwrap();
            db.execute_batch("CREATE TRIGGER fail_hide BEFORE UPDATE OF payload ON events BEGIN SELECT RAISE(ABORT,'injected cancellation failure'); END;").unwrap();
            assert!(
                client
                    .store
                    .delete_file_with_event(&descriptor.id, &event_id)
                    .is_err()
            );
            assert!(client.store.event(&event_id).unwrap().is_some());
            let saved = dir.path().join("still-valid.txt");
            client
                .store
                .save_file(&descriptor.id, &saved, || false)
                .unwrap();
            assert_eq!(
                std::fs::read(saved).unwrap(),
                b"cancel this synthetic staged attachment"
            );
            db.execute_batch("DROP TRIGGER fail_hide").unwrap();
        }
        client
            .store
            .delete_file_with_event(&descriptor.id, &event_id)
            .unwrap();
        drop(client);
        let mut client = SyncClient::open(DeviceStore::open(&path, key).unwrap()).unwrap();
        assert!(client.store.event(&event_id).unwrap().is_none());
        assert!(client.file_transfers().unwrap().is_empty());
        client
            .store
            .delete_file_with_event(&descriptor.id, &event_id)
            .unwrap();
        let _ = client.capture(PortableClip::attachment(&descriptor), Some(&event_id));
        assert!(
            client.store.event(&event_id).unwrap().is_none(),
            "stale intent must not resurrect canceled history"
        );
        let db = Connection::open(&path).unwrap();
        assert_eq!(
            db.query_row::<usize, _, _>("SELECT COUNT(*) FROM file_chunks", [], |r| r.get(0))
                .unwrap(),
            0
        );
    }
}
