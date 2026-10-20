use clipvault_sync_core::*;
use sha2::{Digest, Sha256};
use std::io::Write;

const LIMIT: u64 = 100 * 1024 * 1024;

fn new_store(path: &std::path::Path) -> DeviceStore {
    DeviceStore::open(path, random_secret()).unwrap()
}
fn digest_file(path: &std::path::Path) -> [u8; 32] {
    let mut file = std::fs::File::open(path).unwrap();
    let mut buffer = [0u8; 1024 * 1024];
    let mut hasher = Sha256::new();
    loop {
        let count = std::io::Read::read(&mut file, &mut buffer).unwrap();
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    hasher.finalize().into()
}
fn origin() -> String {
    uuid::Uuid::new_v4().to_string()
}

#[test]
fn zero_byte_file_is_staged_and_saved_with_verified_hash() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("empty.bin");
    std::fs::write(&source, []).unwrap();
    let state_path = dir.path().join("state.db");
    let key = random_secret();
    let mut store = DeviceStore::open(&state_path, key).unwrap();

    let descriptor = store.stage_file(&source, &origin(), || false).unwrap();
    assert_eq!(descriptor.size, 0);
    assert_eq!(descriptor.chunk_count, 0);
    assert_eq!(descriptor.sha256, hex::encode(Sha256::digest([])));

    let destination = dir.path().join("saved-empty.bin");
    store
        .save_file(&descriptor.id, &destination, || false)
        .unwrap();
    assert_eq!(std::fs::metadata(destination).unwrap().len(), 0);
}

#[test]
fn exactly_100_mib_streams_in_bounded_chunks_and_round_trips() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("boundary.bin");
    let mut file = std::fs::File::create(&source).unwrap();
    let block = vec![0x5a; 1024 * 1024];
    for _ in 0..100 {
        file.write_all(&block).unwrap();
    }
    file.sync_all().unwrap();
    let expected = digest_file(&source);
    let state_path = dir.path().join("state.db");
    let key = random_secret();
    let mut store = DeviceStore::open(&state_path, key).unwrap();

    let descriptor = store.stage_file(&source, &origin(), || false).unwrap();
    assert_eq!(descriptor.size, LIMIT);
    assert_eq!(descriptor.chunk_count, 100);
    drop(store);
    let store = DeviceStore::open(&state_path, key).unwrap();
    let destination = dir.path().join("round-trip.bin");
    store
        .save_file(&descriptor.id, &destination, || false)
        .unwrap();
    assert_eq!(digest_file(&destination), expected);
}

#[test]
fn rejects_empty_plus_one_limit_symlinks_and_directories_without_staging() {
    let dir = tempfile::tempdir().unwrap();
    let too_large = dir.path().join("too-large.bin");
    let file = std::fs::File::create(&too_large).unwrap();
    file.set_len(LIMIT + 1).unwrap();
    let link = dir.path().join("link.bin");
    std::os::unix::fs::symlink(&too_large, &link).unwrap();
    let mut store = new_store(&dir.path().join("state.db"));

    let origin = origin();
    assert!(matches!(
        store.stage_file(&too_large, &origin, || false),
        Err(SyncError::TooLarge)
    ));
    assert!(store.stage_file(&link, &origin, || false).is_err());
    assert!(store.stage_file(dir.path(), &origin, || false).is_err());
    assert!(store.file_transfers().unwrap().is_empty());
}

#[cfg(unix)]
#[test]
fn rejects_fifo_source_without_blocking() {
    const CHILD_MARKER: &str = "CLIPVAULT_FIFO_STAGE_TEST_CHILD";
    if std::env::var_os(CHILD_MARKER).is_some() {
        use std::ffi::CString;

        let dir = tempfile::tempdir().unwrap();
        let fifo = dir.path().join("source.pipe");
        let c_path = CString::new(fifo.as_os_str().as_encoded_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(c_path.as_ptr(), 0o600) }, 0);
        let mut store = new_store(&dir.path().join("state.db"));
        assert!(matches!(
            store.stage_file(&fifo, &origin(), || false),
            Err(SyncError::Invalid)
        ));
        assert!(store.file_transfers().unwrap().is_empty());
        assert!(store.history().unwrap().is_empty());
        return;
    }

    use std::{
        process::{Command, Stdio},
        thread,
        time::{Duration, Instant},
    };

    let mut child = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "rejects_fifo_source_without_blocking",
            "--nocapture",
        ])
        .env(CHILD_MARKER, "1")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(status.success(), "FIFO staging subprocess failed: {status}");
            break;
        }
        if Instant::now() >= deadline {
            child.kill().unwrap();
            let _ = child.wait();
            panic!("staging a FIFO source blocked past the 3-second deadline");
        }
        thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn cancellation_and_destination_collision_leave_no_partial_file() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("input.bin");
    std::fs::write(&source, vec![7u8; 3 * 1024 * 1024]).unwrap();
    let mut store = new_store(&dir.path().join("state.db"));

    let origin = origin();
    assert!(matches!(
        store.stage_file(&source, &origin, || true),
        Err(SyncError::Paused)
    ));
    assert!(store.file_transfers().unwrap().is_empty());
    let descriptor = store.stage_file(&source, &origin, || false).unwrap();
    assert!(
        store
            .save_file(&descriptor.id, std::path::Path::new("relative.bin"), || {
                false
            })
            .is_err()
    );
    let destination = dir.path().join("existing.bin");
    std::fs::write(&destination, b"keep").unwrap();
    assert!(
        store
            .save_file(&descriptor.id, &destination, || false)
            .is_err()
    );
    assert_eq!(std::fs::read(destination).unwrap(), b"keep");

    let cancelled = dir.path().join("cancelled.bin");
    assert!(matches!(
        store.save_file(&descriptor.id, &cancelled, || true),
        Err(SyncError::Paused)
    ));
    assert!(!cancelled.exists());
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 3);
}

#[test]
fn source_change_during_stream_is_discarded_and_private_data_never_enters_sqlite_plaintext() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("private-name.bin");
    std::fs::write(&source, vec![0x33; 2 * 1024 * 1024]).unwrap();
    let state = dir.path().join("state.db");
    let mut store = new_store(&state);
    let origin = origin();
    let mut changed = false;
    let result = store.stage_file(&source, &origin, || {
        if !changed {
            changed = true;
            std::fs::write(&source, vec![0x44; 2 * 1024 * 1024]).unwrap();
        }
        false
    });
    assert!(result.is_err());
    assert!(store.file_transfers().unwrap().is_empty());

    let descriptor = store.stage_file(&source, &origin, || false).unwrap();
    assert_eq!(descriptor.filename, "private-name.bin");
    drop(store);
    let database = std::fs::read(state).unwrap();
    assert!(
        !database
            .windows(b"private-name.bin".len())
            .any(|window| window == b"private-name.bin")
    );
    assert!(!database.windows(64).any(
        |window| window == b"DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"
    ));
}

#[test]
fn duplicate_save_does_not_overwrite_and_corrupt_chunk_fails_closed() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("input.bin");
    std::fs::write(&source, vec![0x11; 64]).unwrap();
    let key = random_secret();
    let state_path = dir.path().join("state.db");
    let mut store = DeviceStore::open(&state_path, key).unwrap();
    let descriptor = store.stage_file(&source, &origin(), || false).unwrap();
    let destination = dir.path().join("saved.bin");
    store
        .save_file(&descriptor.id, &destination, || false)
        .unwrap();
    assert!(
        store
            .save_file(&descriptor.id, &destination, || false)
            .is_err()
    );
    drop(store);
    let db = rusqlite::Connection::open(&state_path).unwrap();
    db.execute(
        "UPDATE file_chunks SET payload=x'00' WHERE transfer=?1 AND idx=0",
        [&descriptor.id],
    )
    .unwrap();
    drop(db);
    let store = DeviceStore::open(&state_path, key).unwrap();
    let second = dir.path().join("second.bin");
    assert!(store.save_file(&descriptor.id, &second, || false).is_err());
    assert!(!second.exists());
}

#[test]
fn typed_chunk_is_authenticated_base64_and_ordinary_attachment_event_is_rejected() {
    let sender = DeviceIdentity::generate();
    let receiver = DeviceIdentity::generate();
    let bytes = vec![0xa5; FILE_CHUNK_BYTES];
    let frame = FileFrame::Chunk(FileChunk {
        transfer: uuid::Uuid::new_v4().to_string(),
        origin: sender.id.clone(),
        index: 0,
        chunk_count: 1,
        bytes: bytes.clone(),
    });
    let encoded = serde_json::to_vec(&frame).unwrap();
    assert!(
        encoded.len() < 1_500_000,
        "base64 frame unexpectedly expanded to {} bytes",
        encoded.len()
    );
    let envelope = seal_file_frame(
        "space",
        1,
        &sender,
        &receiver.member("Device"),
        &uuid::Uuid::new_v4().to_string(),
        1,
        &frame,
    )
    .unwrap();
    let (_, _, opened) =
        open_file_frame("space", &receiver, &sender.member("Device"), &envelope).unwrap();
    assert!(matches!(opened,FileFrame::Chunk(FileChunk { bytes: actual, .. }) if actual==bytes));
    let mut tampered = envelope.clone();
    tampered.ciphertext.replace_range(
        0..1,
        if &tampered.ciphertext[..1] == "A" {
            "B"
        } else {
            "A"
        },
    );
    assert!(open_file_frame("space", &receiver, &sender.member("Device"), &tampered).is_err());

    let descriptor = FileDescriptor {
        id: uuid::Uuid::new_v4().to_string(),
        origin: sender.id.clone(),
        filename: "safe.bin".into(),
        size: 0,
        sha256: hex::encode(Sha256::digest([])),
        chunk_count: 0,
        created_at: 1,
    };
    let clip = PortableClip::attachment(&descriptor);
    clip.validate().unwrap();
    let event = ClipEvent::new(sender.id.clone(), 2, clip);
    assert!(seal_event("space", 1, &sender, &receiver.member("Device"), &event).is_err());
}
