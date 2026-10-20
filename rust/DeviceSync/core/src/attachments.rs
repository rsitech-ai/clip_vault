//! Streamed, encrypted file attachments stored outside ordinary clip history.
use crate::{
    ClipEvent, DeviceIdentity, DeviceStore, Envelope, EnvelopeHeader, Member, PortableClip, Result,
    SyncError, SyncKem,
    identity::{decode, encode},
};
use hpke::{
    Deserializable, Kem, OpModeR, OpModeS, Serializable, aead::ChaCha20Poly1305, kdf::HkdfSha256,
};
use rand::{SeedableRng, rngs::StdRng};
use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::{File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
};
use zeroize::Zeroizing;

pub const MAX_FILE_BYTES: u64 = 100 * 1024 * 1024;
pub const FILE_CHUNK_BYTES: usize = 1024 * 1024;
pub const MAX_FILE_STORE_BYTES: u64 = 512 * 1024 * 1024;
const MAX_ACTIVE_FILES: usize = 10;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileDescriptor {
    pub id: String,
    pub origin: String,
    pub filename: String,
    pub size: u64,
    pub sha256: String,
    pub chunk_count: u32,
    pub created_at: i64,
}

impl FileDescriptor {
    pub fn validate(&self) -> Result<()> {
        let expected_count = self.size.div_ceil(FILE_CHUNK_BYTES as u64);
        if uuid::Uuid::parse_str(&self.id).is_err()
            || uuid::Uuid::parse_str(&self.origin).is_err()
            || self.filename.is_empty()
            || self.filename.len() > 255
            || self.filename == "."
            || self.filename == ".."
            || self
                .filename
                .chars()
                .any(|c| c == '/' || c == '\\' || c.is_control())
            || self.size > MAX_FILE_BYTES
            || self.sha256.len() != 64
            || !self
                .sha256
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
            || expected_count != u64::from(self.chunk_count)
            || self.created_at < 0
        {
            return Err(SyncError::Invalid);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileTransferStatus {
    pub id: String,
    pub filename: String,
    pub size: u64,
    pub transferred: u64,
    pub status: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct DeviceCapabilities {
    pub device: String,
    pub features: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileManifest {
    pub descriptor: FileDescriptor,
    pub history_event: String,
    pub history_sequence: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileChunk {
    pub transfer: String,
    pub origin: String,
    pub index: u32,
    pub chunk_count: u32,
    #[serde(with = "base64_bytes")]
    pub bytes: Vec<u8>,
}

mod base64_bytes {
    use base64::{Engine, engine::general_purpose::STANDARD};
    use serde::{Deserialize, Deserializer, Serializer};
    pub fn serialize<S: Serializer>(value: &[u8], serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&STANDARD.encode(value))
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Vec<u8>, D::Error> {
        let value = String::deserialize(deserializer)?;
        STANDARD.decode(value).map_err(serde::de::Error::custom)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileOutcome {
    pub transfer: String,
    pub origin: String,
    pub recipient: String,
    pub sha256: String,
    pub outcome: String,
}
impl FileOutcome {
    pub fn validate(&self) -> Result<()> {
        if uuid::Uuid::parse_str(&self.transfer).is_err()
            || uuid::Uuid::parse_str(&self.origin).is_err()
            || uuid::Uuid::parse_str(&self.recipient).is_err()
            || self.sha256.len() != 64
            || !self
                .sha256
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
            || !["ready", "failed", "unsupported"].contains(&self.outcome.as_str())
        {
            return Err(SyncError::Invalid);
        }
        Ok(())
    }
}

#[derive(Clone, Debug)]
pub(crate) struct FileJob {
    pub transfer: String,
    pub recipient: String,
    /// -1 denotes the manifest; non-negative values denote data chunks.
    pub index: i64,
    pub event: String,
    pub sequence: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "kind", content = "data", deny_unknown_fields)]
pub enum FileFrame {
    Manifest(FileManifest),
    Chunk(FileChunk),
    Outcome(FileOutcome),
}

const FILE_INFO: &[u8] = b"ClipVault authenticated file sharing v1";

impl FileFrame {
    pub fn message_type(&self) -> &'static str {
        match self {
            Self::Outcome(_) => "file-outcome-v1",
            _ => "file-v1",
        }
    }
    pub fn validate(&self) -> Result<()> {
        match self {
            Self::Manifest(manifest) => {
                manifest.descriptor.validate()?;
                if uuid::Uuid::parse_str(&manifest.history_event).is_err()
                    || manifest.history_sequence == 0
                {
                    return Err(SyncError::Invalid);
                }
            }
            Self::Chunk(chunk) => {
                if uuid::Uuid::parse_str(&chunk.transfer).is_err()
                    || uuid::Uuid::parse_str(&chunk.origin).is_err()
                    || chunk.chunk_count == 0
                    || chunk.chunk_count > 100
                    || chunk.index >= chunk.chunk_count
                    || chunk.bytes.is_empty()
                    || chunk.bytes.len() > FILE_CHUNK_BYTES
                    || (chunk.index + 1 < chunk.chunk_count
                        && chunk.bytes.len() != FILE_CHUNK_BYTES)
                {
                    return Err(SyncError::Invalid);
                }
            }
            Self::Outcome(outcome) => {
                outcome.validate()?;
            }
        }
        Ok(())
    }
}

pub fn seal_file_frame(
    workspace: &str,
    epoch: u64,
    sender: &DeviceIdentity,
    recipient: &Member,
    event: &str,
    sequence: u64,
    frame: &FileFrame,
) -> Result<Envelope> {
    frame.validate()?;
    recipient.validate()?;
    let valid_sender = match frame {
        FileFrame::Manifest(m) => m.descriptor.origin == sender.id,
        FileFrame::Chunk(c) => c.origin == sender.id,
        FileFrame::Outcome(o) => o.recipient == sender.id,
    };
    if !valid_sender
        || uuid::Uuid::parse_str(event).is_err()
        || sequence == 0
        || sequence > i64::MAX as u64
        || epoch == 0
        || workspace.is_empty()
        || workspace.len() > 64
    {
        return Err(SyncError::Invalid);
    }
    let header = EnvelopeHeader {
        version: 1,
        workspace: workspace.into(),
        sender: sender.id.clone(),
        recipient: recipient.id.clone(),
        event: event.into(),
        sequence,
        epoch,
        message_type: frame.message_type().into(),
    };
    let aad = serde_json::to_vec(&header)?;
    let (enc, mut context) = hpke::setup_sender::<ChaCha20Poly1305, HkdfSha256, SyncKem, _>(
        &OpModeS::Auth(sender.keypair()?),
        &recipient.key()?,
        FILE_INFO,
        &mut StdRng::from_os_rng(),
    )
    .map_err(|_| SyncError::Authentication)?;
    let plaintext = Zeroizing::new(serde_json::to_vec(frame)?);
    let ciphertext = context
        .seal(&plaintext, &aad)
        .map_err(|_| SyncError::Authentication)?;
    Ok(Envelope {
        header,
        encapsulated_key: encode(enc.to_bytes()),
        ciphertext: encode(ciphertext),
    })
}

pub fn open_file_frame(
    workspace: &str,
    recipient: &DeviceIdentity,
    sender: &Member,
    envelope: &Envelope,
) -> Result<(String, u64, FileFrame)> {
    let h = &envelope.header;
    if h.version != 1
        || h.workspace != workspace
        || h.recipient != recipient.id
        || h.sender != sender.id
        || h.epoch == 0
        || !["file-v1", "file-outcome-v1"].contains(&h.message_type.as_str())
        || envelope.ciphertext.len() > crate::MAX_WIRE_BYTES
    {
        return Err(SyncError::Invalid);
    }
    let enc = <SyncKem as Kem>::EncappedKey::from_bytes(&decode(&envelope.encapsulated_key)?)
        .map_err(|_| SyncError::Invalid)?;
    let (sk, _) = recipient.keypair()?;
    let mut context = hpke::setup_receiver::<ChaCha20Poly1305, HkdfSha256, SyncKem>(
        &OpModeR::Auth(sender.key()?),
        &sk,
        &enc,
        FILE_INFO,
    )
    .map_err(|_| SyncError::Authentication)?;
    let plaintext = Zeroizing::new(
        context
            .open(&decode(&envelope.ciphertext)?, &serde_json::to_vec(h)?)
            .map_err(|_| SyncError::Authentication)?,
    );
    if plaintext.len() > crate::MAX_WIRE_BYTES {
        return Err(SyncError::TooLarge);
    }
    let frame: FileFrame = serde_json::from_slice(&plaintext)?;
    frame.validate()?;
    if frame.message_type() != h.message_type {
        return Err(SyncError::Authentication);
    }
    match &frame {
        FileFrame::Manifest(m) if m.descriptor.origin != h.sender => {
            return Err(SyncError::Authentication);
        }
        FileFrame::Chunk(c) if c.origin != h.sender => return Err(SyncError::Authentication),
        FileFrame::Outcome(o) if o.recipient != h.sender || o.origin != h.recipient => {
            return Err(SyncError::Authentication);
        }
        _ => {}
    }
    Ok((h.event.clone(), h.sequence, frame))
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct StoredTransfer {
    pub(crate) descriptor: FileDescriptor,
    #[serde(default)]
    pub(crate) history_event: Option<String>,
    #[serde(default)]
    pub(crate) history_sequence: Option<u64>,
    #[serde(default)]
    pub(crate) outcome: Option<FileOutcome>,
}

fn context(id: &str, index: u32) -> String {
    format!("file:{id}:{index}")
}

fn source_filename(path: &Path) -> Result<String> {
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or(SyncError::Invalid)?;
    if name.is_empty()
        || name.len() > 255
        || name == "."
        || name == ".."
        || name
            .chars()
            .any(|c| c == '/' || c == '\\' || c.is_control())
    {
        return Err(SyncError::Invalid);
    }
    Ok(name.to_owned())
}

fn open_regular_nofollow(path: &Path) -> Result<(File, std::fs::Metadata)> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    }
    let file = options.open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(SyncError::Invalid);
    }
    Ok((file, metadata))
}

fn metadata_unchanged(before: &std::fs::Metadata, after: &std::fs::Metadata) -> bool {
    if before.len() != after.len() || !after.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        before.dev() == after.dev()
            && before.ino() == after.ino()
            && before.mtime() == after.mtime()
            && before.mtime_nsec() == after.mtime_nsec()
            && before.ctime() == after.ctime()
            && before.ctime_nsec() == after.ctime_nsec()
    }
    #[cfg(not(unix))]
    {
        before.modified().ok() == after.modified().ok()
    }
}

impl DeviceStore {
    /// Remove abandoned partial transfers after the relay's full retry lifetime.
    /// Completed local files are retained until the user deletes them.
    pub(crate) fn prune_incomplete_files(&mut self, now: i64) -> Result<()> {
        let cutoff = now.saturating_sub(crate::DELIVERY_TERMINAL_RETENTION);
        let mut statement = self.db.prepare(
            "SELECT id,payload,direction FROM file_transfers WHERE (state IN ('staging','receiving') OR (state='failed' AND direction='incoming')) AND created_at<?1",
        )?;
        let rows = statement
            .query_map([cutoff], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Vec<u8>>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        drop(statement);
        if rows.is_empty() {
            return Ok(());
        }
        let mut expired = Vec::with_capacity(rows.len());
        for (id, payload, direction) in rows {
            let transfer: StoredTransfer = self.unseal(&format!("file-meta:{id}"), &payload)?;
            expired.push((id, transfer.descriptor.origin, direction));
        }
        let tx = self
            .db
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let existing: u64 =
            tx.query_row("SELECT COUNT(*) FROM file_tombstones", [], |r| r.get(0))?;
        let tombstone_additions = expired
            .iter()
            .filter(|(_, _, direction)| direction == "incoming")
            .count() as u64;
        if existing.saturating_add(tombstone_additions) > 100_000 {
            return Err(SyncError::Capacity);
        }
        for (id, origin, direction) in expired {
            if direction == "incoming" {
                tx.execute(
                    "INSERT OR IGNORE INTO file_tombstones(transfer,origin,deleted_at) VALUES(?1,?2,?3)",
                    params![id, origin, now],
                )?;
            }
            tx.execute(
                "UPDATE file_jobs SET status='cancelled' WHERE transfer=?1 AND status='pending'",
                [&id],
            )?;
            tx.execute("DELETE FROM file_chunks WHERE transfer=?1", [&id])?;
            tx.execute("DELETE FROM file_targets WHERE transfer=?1", [&id])?;
            tx.execute("DELETE FROM file_transfers WHERE id=?1", [&id])?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Stage from an already user-selected path. No outbound recipient is created here.
    pub fn stage_file<F>(
        &mut self,
        path: &Path,
        origin: &str,
        mut cancelled: F,
    ) -> Result<FileDescriptor>
    where
        F: FnMut() -> bool,
    {
        if uuid::Uuid::parse_str(origin).is_err() {
            return Err(SyncError::Invalid);
        }
        let filename = source_filename(path)?;
        let (mut source, before) = open_regular_nofollow(path)?;
        if before.len() > MAX_FILE_BYTES {
            return Err(SyncError::TooLarge);
        }
        let active: usize = self.db.query_row(
            "SELECT COUNT(*) FROM file_transfers WHERE state IN ('staging','receiving','pending','sending','verifying')", [], |r| r.get(0))?;
        if active >= MAX_ACTIVE_FILES {
            return Err(SyncError::Capacity);
        }
        let id = uuid::Uuid::new_v4().to_string();
        let created_at = crate::unix_time();
        let mut hasher = Sha256::new();
        let mut remaining = before.len();
        let mut index = 0u32;
        let mut buffer = Zeroizing::new(vec![0u8; FILE_CHUNK_BYTES]);
        let initial = FileDescriptor {
            id: id.clone(),
            origin: origin.to_owned(),
            filename,
            size: before.len(),
            sha256: String::new(),
            chunk_count: 0,
            created_at,
        };
        let payload = self.seal(
            &format!("file-meta:{id}"),
            &StoredTransfer {
                descriptor: initial.clone(),
                history_event: None,
                history_sequence: None,
                outcome: None,
            },
        )?;
        let tx = self.db.transaction()?;
        tx.execute("INSERT INTO file_transfers(id,payload,direction,state,committed,event_id,transferred,created_at) VALUES(?1,?2,'outgoing','staging',0,NULL,0,?3)", params![id,payload,created_at])?;
        tx.commit()?;
        let result = (|| {
            while remaining > 0 {
                if cancelled() {
                    return Err(SyncError::Paused);
                }
                let amount = remaining.min(FILE_CHUNK_BYTES as u64) as usize;
                source.read_exact(&mut buffer[..amount])?;
                hasher.update(&buffer[..amount]);
                let encrypted = self.seal_raw(&context(&id, index), &buffer[..amount])?;
                let tx = self
                    .db
                    .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
                let used: u64 = tx.query_row(
                    "SELECT COALESCE(SUM(LENGTH(payload)),0) FROM file_chunks",
                    [],
                    |r| r.get(0),
                )?;
                if used.saturating_add(encrypted.len() as u64) > MAX_FILE_STORE_BYTES {
                    return Err(SyncError::Capacity);
                }
                tx.execute(
                    "INSERT INTO file_chunks(transfer,idx,payload) VALUES(?1,?2,?3)",
                    params![id, index, encrypted],
                )?;
                tx.execute(
                    "UPDATE file_transfers SET transferred=?2 WHERE id=?1",
                    params![id, before.len() - remaining + amount as u64],
                )?;
                tx.commit()?;
                remaining -= amount as u64;
                index = index.checked_add(1).ok_or(SyncError::Invalid)?;
            }
            if cancelled() {
                return Err(SyncError::Paused);
            }
            let mut extra = [0u8; 1];
            if source.read(&mut extra)? != 0 || !metadata_unchanged(&before, &source.metadata()?) {
                return Err(SyncError::Invalid);
            }
            let descriptor = FileDescriptor {
                id: id.clone(),
                origin: origin.to_owned(),
                filename: initial.filename.clone(),
                size: before.len(),
                sha256: hex::encode(hasher.finalize()),
                chunk_count: index,
                created_at,
            };
            descriptor.validate()?;
            let payload = self.seal(
                &format!("file-meta:{id}"),
                &StoredTransfer {
                    descriptor: descriptor.clone(),
                    history_event: None,
                    history_sequence: None,
                    outcome: None,
                },
            )?;
            self.db.execute(
                "UPDATE file_transfers SET payload=?2,state='staged',transferred=?3 WHERE id=?1",
                params![id, payload, before.len()],
            )?;
            Ok(descriptor)
        })();
        if result.is_err() {
            self.db
                .execute("DELETE FROM file_transfers WHERE id=?1", [&id])?;
        }
        result
    }

    pub(crate) fn stored_transfer(&self, id: &str) -> Result<StoredTransfer> {
        let payload: Option<Vec<u8>> = self
            .db
            .query_row(
                "SELECT payload FROM file_transfers WHERE id=?1",
                [id],
                |r| r.get(0),
            )
            .optional()?;
        let payload = payload.ok_or(SyncError::Attachment)?;
        self.unseal(&format!("file-meta:{id}"), &payload)
    }

    pub(crate) fn encrypted_file_chunk(&self, id: &str, index: u32) -> Result<Zeroizing<Vec<u8>>> {
        let payload: Option<Vec<u8>> = self
            .db
            .query_row(
                "SELECT payload FROM file_chunks WHERE transfer=?1 AND idx=?2",
                params![id, index],
                |r| r.get(0),
            )
            .optional()?;
        let payload = payload.ok_or(SyncError::Attachment)?;
        self.unseal_raw(&context(id, index), &payload)
    }

    pub fn save_file<F>(&self, id: &str, destination: &Path, mut cancelled: F) -> Result<()>
    where
        F: FnMut() -> bool,
    {
        if !destination.is_absolute() {
            return Err(SyncError::Invalid);
        }
        let transfer = self.stored_transfer(id)?;
        let (direction, state): (String, String) = self.db.query_row(
            "SELECT direction,state FROM file_transfers WHERE id=?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        if direction == "incoming" && state != "ready" {
            return Err(SyncError::Attachment);
        }
        let descriptor = transfer.descriptor;
        descriptor.validate()?;
        let parent = destination
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."));
        let filename = destination.file_name().ok_or(SyncError::Invalid)?;
        if filename.to_string_lossy().is_empty() {
            return Err(SyncError::Invalid);
        }
        let mut temp_path = PathBuf::new();
        let mut temp = None;
        for _ in 0..8 {
            let candidate = parent.join(format!(".clipvault-{}.partial", uuid::Uuid::new_v4()));
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options
                    .mode(0o600)
                    .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
            }
            match options.open(&candidate) {
                Ok(file) => {
                    temp_path = candidate;
                    temp = Some(file);
                    break;
                }
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(e.into()),
            }
        }
        let mut temp = temp.ok_or(SyncError::Storage(rusqlite::Error::InvalidQuery))?;
        let result = (|| {
            let mut hasher = Sha256::new();
            let mut total = 0u64;
            for index in 0..descriptor.chunk_count {
                if cancelled() {
                    return Err(SyncError::Paused);
                }
                let bytes = self.encrypted_file_chunk(id, index)?;
                let expected_len = (descriptor
                    .size
                    .saturating_sub(u64::from(index) * FILE_CHUNK_BYTES as u64))
                .min(FILE_CHUNK_BYTES as u64) as usize;
                if bytes.len() != expected_len {
                    return Err(SyncError::Authentication);
                }
                hasher.update(&*bytes);
                temp.write_all(&bytes)?;
                total = total.saturating_add(bytes.len() as u64);
            }
            if cancelled() {
                return Err(SyncError::Paused);
            }
            if total != descriptor.size || hex::encode(hasher.finalize()) != descriptor.sha256 {
                return Err(SyncError::Authentication);
            }
            temp.sync_all()?;
            drop(temp);
            // A hard link is an atomic no-overwrite publish on the same filesystem.
            std::fs::hard_link(&temp_path, destination)?;
            std::fs::remove_file(&temp_path)?;
            if let Ok(dir) = File::open(parent) {
                let _ = dir.sync_all();
            }
            Ok(())
        })();
        if temp_path.exists() {
            let _ = std::fs::remove_file(&temp_path);
        }
        result
    }

    pub fn file_transfers(&self) -> Result<Vec<FileTransferStatus>> {
        let mut query = self.db.prepare("SELECT id,payload,direction,state,transferred FROM file_transfers ORDER BY created_at DESC LIMIT 50")?;
        let rows = query.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, Vec<u8>>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, u64>(4)?,
            ))
        })?;
        rows.map(|row| {
            let (id, payload, direction, state, transferred) = row?;
            let transfer: StoredTransfer = self.unseal(&format!("file-meta:{id}"), &payload)?;
            let status = if state == "staging" {
                "staged"
            } else {
                state.as_str()
            };
            Ok(FileTransferStatus {
                id,
                filename: transfer.descriptor.filename,
                size: transfer.descriptor.size,
                transferred,
                status: if direction == "outgoing" && state == "staged" {
                    "staged".into()
                } else {
                    status.into()
                },
            })
        })
        .collect()
    }

    pub fn discard_file(&mut self, id: &str) -> Result<()> {
        let committed: Option<bool> = self
            .db
            .query_row(
                "SELECT committed=1 FROM file_transfers WHERE id=?1",
                [id],
                |r| r.get(0),
            )
            .optional()?;
        if committed == Some(true) {
            return Err(SyncError::Membership);
        }
        self.db
            .execute("DELETE FROM file_transfers WHERE id=?1", [id])?;
        Ok(())
    }

    pub fn discard_uncommitted_file(&mut self, id: &str) -> Result<()> {
        self.discard_file(id)
    }

    pub fn delete_file(&mut self, id: &str) -> Result<()> {
        if uuid::Uuid::parse_str(id).is_err() {
            return Err(SyncError::Invalid);
        }
        let transfer = match self.stored_transfer(id) {
            Ok(transfer) => transfer,
            Err(SyncError::Attachment) if self.is_file_tombstoned(id)? => return Ok(()),
            Err(SyncError::Attachment) => return Ok(()),
            Err(error) => return Err(error),
        };
        let now = crate::unix_time();
        let tx = self
            .db
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        tx.execute(
            "DELETE FROM file_tombstones WHERE deleted_at<?1",
            [now.saturating_sub(crate::DELIVERY_TERMINAL_RETENTION)],
        )?;
        let tombstones: u64 =
            tx.query_row("SELECT COUNT(*) FROM file_tombstones", [], |r| r.get(0))?;
        let already_tombstoned: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM file_tombstones WHERE transfer=?1)",
            [id],
            |r| r.get(0),
        )?;
        if tombstones >= 100_000 && !already_tombstoned {
            return Err(SyncError::Capacity);
        }
        let event: Option<String> = tx
            .query_row(
                "SELECT event_id FROM file_transfers WHERE id=?1",
                [id],
                |r| r.get(0),
            )
            .optional()?
            .flatten();
        tx.execute(
            "INSERT OR REPLACE INTO file_tombstones(transfer,origin,deleted_at) VALUES(?1,?2,?3)",
            params![id, transfer.descriptor.origin, now],
        )?;
        tx.execute("UPDATE file_jobs SET status='cancelled' WHERE transfer=?1 AND status IN ('pending','retry')", [id])?;
        if let Some(event) = event {
            tx.execute(
                "UPDATE events SET outgoing=0,payload=NULL,applied=1 WHERE id=?1",
                [&event],
            )?;
            tx.execute(
                "UPDATE targets SET status='cancelled' WHERE event=?1 AND status='pending'",
                [&event],
            )?;
        }
        tx.execute("DELETE FROM file_transfers WHERE id=?1", [id])?;
        tx.execute("DELETE FROM file_targets WHERE transfer=?1", [id])?;
        tx.commit()?;
        Ok(())
    }

    fn is_file_tombstoned(&self, id: &str) -> Result<bool> {
        Ok(self.db.query_row(
            "SELECT EXISTS(SELECT 1 FROM file_tombstones WHERE transfer=?1)",
            [id],
            |r| r.get(0),
        )?)
    }

    pub(crate) fn pending_file_jobs(&self, limit: usize) -> Result<Vec<FileJob>> {
        let mut query = self.db.prepare("SELECT transfer,recipient,idx,frame_event,sequence FROM file_jobs WHERE status='pending' AND (attempted_at IS NULL OR attempted_at<=?1) ORDER BY rowid LIMIT ?2")?;
        Ok(query
            .query_map(params![crate::unix_time(), limit as i64], |r| {
                Ok(FileJob {
                    transfer: r.get(0)?,
                    recipient: r.get(1)?,
                    index: r.get(2)?,
                    event: r.get(3)?,
                    sequence: r.get(4)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?)
    }

    pub(crate) fn defer_file_jobs_for_recipient(
        &mut self,
        recipient: &str,
        retry_at: i64,
    ) -> Result<()> {
        self.db.execute(
            "UPDATE file_jobs SET attempted_at=?2 WHERE recipient=?1 AND status='pending'",
            params![recipient, retry_at],
        )?;
        Ok(())
    }

    pub(crate) fn file_frame(&self, job: &FileJob) -> Result<FileFrame> {
        let transfer = self.stored_transfer(&job.transfer)?;
        if job.index == -1 {
            Ok(FileFrame::Manifest(FileManifest {
                descriptor: transfer.descriptor,
                history_event: transfer.history_event.ok_or(SyncError::Attachment)?,
                history_sequence: transfer.history_sequence.ok_or(SyncError::Attachment)?,
            }))
        } else if job.index == -2 {
            Ok(FileFrame::Outcome(
                transfer.outcome.ok_or(SyncError::Attachment)?,
            ))
        } else if job.index >= 0 {
            let index = u32::try_from(job.index).map_err(|_| SyncError::Invalid)?;
            let bytes = self.encrypted_file_chunk(&job.transfer, index)?;
            Ok(FileFrame::Chunk(FileChunk {
                transfer: job.transfer.clone(),
                origin: transfer.descriptor.origin,
                index,
                chunk_count: transfer.descriptor.chunk_count,
                bytes: bytes.to_vec(),
            }))
        } else {
            Err(SyncError::Invalid)
        }
    }

    pub(crate) fn receive_file_frame(
        &mut self,
        frame: &FileFrame,
        recipient: &str,
        sender_name: &str,
    ) -> Result<Option<ClipEvent>> {
        match frame {
            FileFrame::Manifest(manifest) => {
                let descriptor = &manifest.descriptor;
                descriptor.validate()?;
                if self.is_file_tombstoned(&descriptor.id)? {
                    return Err(SyncError::Attachment);
                }
                if descriptor.origin == recipient {
                    return Err(SyncError::Invalid);
                }
                if let Ok(existing) = self.stored_transfer(&descriptor.id) {
                    if existing.descriptor != *descriptor
                        || existing.history_event.as_deref() != Some(&manifest.history_event)
                        || existing.history_sequence != Some(manifest.history_sequence)
                    {
                        return Err(SyncError::Authentication);
                    }
                    if self.file_state(&descriptor.id)?.as_deref() == Some("ready") {
                        return self.finalize_incoming(
                            descriptor,
                            manifest.history_event.as_str(),
                            manifest.history_sequence,
                            recipient,
                            sender_name,
                        );
                    }
                    return Ok(None);
                }
                let used: u64 = self.db.query_row(
                    "SELECT COALESCE(SUM(LENGTH(payload)),0) FROM file_chunks",
                    [],
                    |r| r.get(0),
                )?;
                if used
                    .saturating_add(descriptor.size)
                    .saturating_add(descriptor.chunk_count as u64 * 28)
                    > MAX_FILE_STORE_BYTES
                {
                    return Err(SyncError::Capacity);
                }
                let active:usize=self.db.query_row("SELECT COUNT(*) FROM file_transfers WHERE state IN ('staging','receiving','pending','sending','verifying')",[],|r|r.get(0))?;
                if active >= MAX_ACTIVE_FILES {
                    return Err(SyncError::Capacity);
                }
                let payload = self.seal(
                    &format!("file-meta:{}", descriptor.id),
                    &StoredTransfer {
                        descriptor: descriptor.clone(),
                        history_event: Some(manifest.history_event.clone()),
                        history_sequence: Some(manifest.history_sequence),
                        outcome: None,
                    },
                )?;
                self.db.execute("INSERT INTO file_transfers(id,payload,direction,state,committed,event_id,transferred,created_at) VALUES(?1,?2,'incoming','receiving',1,?3,0,?4)",params![descriptor.id,payload,manifest.history_event,crate::unix_time()])?;
                if descriptor.chunk_count == 0 {
                    if descriptor.sha256 != hex::encode(Sha256::digest([])) {
                        self.fail_incoming(descriptor, recipient)?;
                        return Ok(None);
                    }
                    return self.finalize_incoming(
                        descriptor,
                        &manifest.history_event,
                        manifest.history_sequence,
                        recipient,
                        sender_name,
                    );
                }
                Ok(None)
            }
            FileFrame::Chunk(chunk) => {
                if self.is_file_tombstoned(&chunk.transfer)? {
                    return Err(SyncError::Attachment);
                }
                let transfer = self.stored_transfer(&chunk.transfer)?;
                let descriptor = &transfer.descriptor;
                if descriptor.origin != chunk.origin
                    || descriptor.chunk_count != chunk.chunk_count
                    || chunk.index >= descriptor.chunk_count
                {
                    return Err(SyncError::Authentication);
                }
                let expected = (descriptor
                    .size
                    .saturating_sub(u64::from(chunk.index) * FILE_CHUNK_BYTES as u64))
                .min(FILE_CHUNK_BYTES as u64) as usize;
                if expected == 0 || chunk.bytes.len() != expected {
                    return Err(SyncError::Invalid);
                }
                let existing: Option<Vec<u8>> = self
                    .db
                    .query_row(
                        "SELECT payload FROM file_chunks WHERE transfer=?1 AND idx=?2",
                        params![chunk.transfer, chunk.index],
                        |r| r.get(0),
                    )
                    .optional()?;
                if let Some(existing) = existing {
                    let prior =
                        self.unseal_raw(&context(&chunk.transfer, chunk.index), &existing)?;
                    if prior.as_slice() != chunk.bytes {
                        return Err(SyncError::Authentication);
                    }
                } else {
                    let encrypted =
                        self.seal_raw(&context(&chunk.transfer, chunk.index), &chunk.bytes)?;
                    let tx = self
                        .db
                        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
                    let used: u64 = tx.query_row(
                        "SELECT COALESCE(SUM(LENGTH(payload)),0) FROM file_chunks",
                        [],
                        |r| r.get(0),
                    )?;
                    if used.saturating_add(encrypted.len() as u64) > MAX_FILE_STORE_BYTES {
                        return Err(SyncError::Capacity);
                    }
                    tx.execute(
                        "INSERT INTO file_chunks(transfer,idx,payload) VALUES(?1,?2,?3)",
                        params![chunk.transfer, chunk.index, encrypted],
                    )?;
                    let total:u64=tx.query_row("SELECT COALESCE(SUM(LENGTH(payload)-28),0) FROM file_chunks WHERE transfer=?1",[&chunk.transfer],|r|r.get(0))?;
                    tx.execute(
                        "UPDATE file_transfers SET transferred=?2 WHERE id=?1",
                        params![chunk.transfer, total],
                    )?;
                    tx.commit()?;
                }
                let got: u32 = self.db.query_row(
                    "SELECT COUNT(*) FROM file_chunks WHERE transfer=?1",
                    [&chunk.transfer],
                    |r| r.get(0),
                )?;
                if got == descriptor.chunk_count {
                    let history_event = transfer.history_event.ok_or(SyncError::Attachment)?;
                    let history_sequence =
                        transfer.history_sequence.ok_or(SyncError::Attachment)?;
                    if self.verify_incoming(&chunk.transfer, descriptor).is_err() {
                        self.fail_incoming(descriptor, recipient)?;
                        return Ok(None);
                    }
                    self.set_file_state(&chunk.transfer, "ready")?;
                    return self.finalize_incoming(
                        descriptor,
                        &history_event,
                        history_sequence,
                        recipient,
                        sender_name,
                    );
                }
                Ok(None)
            }
            FileFrame::Outcome(_) => Err(SyncError::Invalid),
        }
    }

    pub(crate) fn apply_file_outcome(
        &mut self,
        outcome: &FileOutcome,
        sender: &str,
        local: &str,
    ) -> Result<()> {
        outcome.validate()?;
        if outcome.origin != local || outcome.recipient != sender {
            return Err(SyncError::Authentication);
        }
        let transfer = self.stored_transfer(&outcome.transfer)?;
        if transfer.descriptor.origin != local || transfer.descriptor.sha256 != outcome.sha256 {
            return Err(SyncError::Authentication);
        }
        let existing: Option<String> = self
            .db
            .query_row(
                "SELECT status FROM file_targets WHERE transfer=?1 AND recipient=?2",
                params![outcome.transfer, sender],
                |r| r.get(0),
            )
            .optional()?;
        if existing.is_none() {
            return Err(SyncError::Membership);
        }
        let tx = self.db.transaction()?;
        tx.execute(
            "UPDATE file_targets SET status=?3 WHERE transfer=?1 AND recipient=?2",
            params![outcome.transfer, sender, outcome.outcome],
        )?;
        let failed:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM file_targets WHERE transfer=?1 AND status IN ('failed','unsupported'))",[&outcome.transfer],|r|r.get(0))?;
        let pending: u64 = tx.query_row(
            "SELECT COUNT(*) FROM file_targets WHERE transfer=?1 AND status!='ready'",
            [&outcome.transfer],
            |r| r.get(0),
        )?;
        let next = if failed {
            "failed"
        } else if pending == 0 {
            "ready"
        } else {
            "pending"
        };
        tx.execute(
            "UPDATE file_transfers SET state=?2 WHERE id=?1",
            params![outcome.transfer, next],
        )?;
        tx.commit()?;
        Ok(())
    }

    fn verify_incoming(&self, id: &str, descriptor: &FileDescriptor) -> Result<()> {
        let mut hasher = Sha256::new();
        let mut total = 0u64;
        for index in 0..descriptor.chunk_count {
            let bytes = self.encrypted_file_chunk(id, index)?;
            let expected = (descriptor
                .size
                .saturating_sub(u64::from(index) * FILE_CHUNK_BYTES as u64))
            .min(FILE_CHUNK_BYTES as u64) as usize;
            if bytes.len() != expected {
                return Err(SyncError::Authentication);
            }
            hasher.update(&*bytes);
            total = total.saturating_add(bytes.len() as u64);
        }
        if total != descriptor.size || hex::encode(hasher.finalize()) != descriptor.sha256 {
            return Err(SyncError::Authentication);
        }
        Ok(())
    }

    fn finalize_incoming(
        &mut self,
        descriptor: &FileDescriptor,
        event_id: &str,
        sequence: u64,
        recipient: &str,
        sender_name: &str,
    ) -> Result<Option<ClipEvent>> {
        if self.file_state(&descriptor.id)?.as_deref() != Some("ready")
            && descriptor.chunk_count != 0
        {
            self.verify_incoming(&descriptor.id, descriptor)?;
        }
        let mut clip = PortableClip::attachment(descriptor);
        clip.source_device = Some(sender_name.to_owned());
        let event = ClipEvent {
            id: event_id.to_owned(),
            origin: descriptor.origin.clone(),
            sequence,
            clip,
        };
        if let Err(error) = event.validate() {
            if matches!(error, SyncError::Sensitive) {
                self.fail_incoming(descriptor, recipient)?;
                return Ok(None);
            }
            return Err(error);
        }
        self.set_file_state(&descriptor.id, "ready")?;
        let inserted = self.receive_verified_attachment(&event)?;
        self.queue_outcome(descriptor, recipient, "ready")?;
        Ok(inserted.then_some(event))
    }

    fn queue_outcome(
        &mut self,
        descriptor: &FileDescriptor,
        recipient: &str,
        outcome: &str,
    ) -> Result<()> {
        let mut transfer = self.stored_transfer(&descriptor.id)?;
        let result = FileOutcome {
            transfer: descriptor.id.clone(),
            origin: descriptor.origin.clone(),
            recipient: recipient.to_owned(),
            sha256: descriptor.sha256.clone(),
            outcome: outcome.to_owned(),
        };
        transfer.outcome = Some(result);
        let payload = self.seal(&format!("file-meta:{}", descriptor.id), &transfer)?;
        let sequence = self.next_sequence()?;
        let event = uuid::Uuid::new_v4().to_string();
        let tx = self.db.transaction()?;
        tx.execute(
            "UPDATE file_transfers SET payload=?2 WHERE id=?1",
            params![descriptor.id, payload],
        )?;
        tx.execute("INSERT OR IGNORE INTO file_jobs(transfer,recipient,idx,frame_event,sequence,status) VALUES(?1,?2,-2,?3,?4,'pending')",params![descriptor.id,descriptor.origin,event,sequence])?;
        tx.commit()?;
        Ok(())
    }

    fn fail_incoming(&mut self, descriptor: &FileDescriptor, recipient: &str) -> Result<()> {
        let now = crate::unix_time();
        let mut transfer: StoredTransfer = self.stored_transfer(&descriptor.id)?;
        if transfer.descriptor != *descriptor {
            return Err(SyncError::Authentication);
        }
        transfer.outcome = Some(FileOutcome {
            transfer: descriptor.id.clone(),
            origin: descriptor.origin.clone(),
            recipient: recipient.to_owned(),
            sha256: descriptor.sha256.clone(),
            outcome: "failed".to_owned(),
        });
        let payload = self.seal(&format!("file-meta:{}", descriptor.id), &transfer)?;
        let sequence = self.next_sequence()?;
        let event = uuid::Uuid::new_v4().to_string();
        let tx = self
            .db
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        tx.execute(
            "DELETE FROM file_tombstones WHERE deleted_at<?1",
            [now.saturating_sub(crate::DELIVERY_TERMINAL_RETENTION)],
        )?;
        let existing: u64 =
            tx.query_row("SELECT COUNT(*) FROM file_tombstones", [], |row| row.get(0))?;
        let already_tombstoned: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM file_tombstones WHERE transfer=?1)",
            [&descriptor.id],
            |row| row.get(0),
        )?;
        if existing >= 100_000 && !already_tombstoned {
            return Err(SyncError::Capacity);
        }
        tx.execute(
            "UPDATE file_transfers SET payload=?2,state='failed',created_at=?3 WHERE id=?1",
            params![descriptor.id, payload, now],
        )?;
        tx.execute(
            "INSERT OR IGNORE INTO file_jobs(transfer,recipient,idx,frame_event,sequence,status) VALUES(?1,?2,-2,?3,?4,'pending')",
            params![descriptor.id, descriptor.origin, event, sequence],
        )?;
        tx.execute(
            "DELETE FROM file_chunks WHERE transfer=?1",
            [&descriptor.id],
        )?;
        tx.execute(
            "INSERT OR IGNORE INTO file_tombstones(transfer,origin,deleted_at) VALUES(?1,?2,?3)",
            params![descriptor.id, descriptor.origin, now],
        )?;
        tx.commit()?;
        Ok(())
    }

    fn file_state(&self, id: &str) -> Result<Option<String>> {
        Ok(self
            .db
            .query_row("SELECT state FROM file_transfers WHERE id=?1", [id], |r| {
                r.get(0)
            })
            .optional()?)
    }
    fn set_file_state(&mut self, id: &str, state: &str) -> Result<()> {
        self.db.execute(
            "UPDATE file_transfers SET state=?2 WHERE id=?1",
            params![id, state],
        )?;
        Ok(())
    }

    pub(crate) fn mark_file_job(
        &mut self,
        transfer: &str,
        recipient: &str,
        index: i64,
        status: &str,
    ) -> Result<()> {
        self.db.execute(
            "UPDATE file_jobs SET status=?4 WHERE transfer=?1 AND recipient=?2 AND idx=?3",
            params![transfer, recipient, index, status],
        )?;
        if matches!(status, "failed" | "revoked") {
            self.db.execute(
                "UPDATE file_targets SET status='failed' WHERE transfer=?1 AND recipient=?2 AND status='pending'",
                params![transfer, recipient],
            )?;
            self.db.execute(
                "UPDATE file_jobs SET status='cancelled' WHERE transfer=?1 AND recipient=?2 AND status='pending'",
                params![transfer, recipient],
            )?;
        }
        let direction: String = self.db.query_row(
            "SELECT direction FROM file_transfers WHERE id=?1",
            [transfer],
            |r| r.get(0),
        )?;
        let remaining: i64 = self.db.query_row(
            "SELECT COUNT(*) FROM file_jobs WHERE transfer=?1 AND status='pending'",
            [transfer],
            |r| r.get(0),
        )?;
        if remaining == 0 && direction == "outgoing" {
            let jobs_failed:bool=self.db.query_row("SELECT EXISTS(SELECT 1 FROM file_jobs WHERE transfer=?1 AND status IN ('failed','revoked','cancelled'))",[transfer],|r|r.get(0))?;
            let target_failed:bool=self.db.query_row("SELECT EXISTS(SELECT 1 FROM file_targets WHERE transfer=?1 AND status IN ('failed','unsupported'))",[transfer],|r|r.get(0))?;
            let next = if jobs_failed || target_failed {
                "failed"
            } else {
                "pending"
            };
            self.db.execute("UPDATE file_transfers SET state=?2,transferred=(SELECT COALESCE(SUM(LENGTH(payload)-28),0) FROM file_chunks WHERE transfer=?1) WHERE id=?1", params![transfer,next])?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod unit_tests {
    use super::*;
    #[test]
    fn descriptor_rejects_path_and_malformed_hash() {
        let d = FileDescriptor {
            id: uuid::Uuid::new_v4().to_string(),
            origin: uuid::Uuid::new_v4().to_string(),
            filename: "../bad".into(),
            size: 0,
            sha256: hex::encode(Sha256::digest([])),
            chunk_count: 0,
            created_at: 1,
        };
        assert!(d.validate().is_err());
    }

    #[test]
    fn incoming_file_reorders_and_deduplicates_chunks_and_delete_is_retry_safe() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("source.bin");
        let contents = (0..(FILE_CHUNK_BYTES * 2 + 17))
            .map(|n| (n % 251) as u8)
            .collect::<Vec<_>>();
        std::fs::write(&source, &contents).unwrap();
        let sender = DeviceIdentity::generate();
        let mut sender_store =
            DeviceStore::open(&dir.path().join("sender.db"), crate::random_secret()).unwrap();
        let descriptor = sender_store
            .stage_file(&source, &sender.id, || false)
            .unwrap();
        let event_id = uuid::Uuid::new_v4().to_string();
        let manifest = FileFrame::Manifest(FileManifest {
            descriptor: descriptor.clone(),
            history_event: event_id.clone(),
            history_sequence: 7,
        });
        let receiver_identity = DeviceIdentity::generate();
        let receiver_id = receiver_identity.id.clone();
        let receiver_key = crate::random_secret();
        let receiver_path = dir.path().join("receiver.db");
        let mut receiver = DeviceStore::open(&receiver_path, receiver_key).unwrap();
        assert!(
            receiver
                .receive_file_frame(&manifest, &receiver_id, "Sender")
                .unwrap()
                .is_none()
        );
        for index in [2u32, 1, 0, 1] {
            let chunk = FileFrame::Chunk(FileChunk {
                transfer: descriptor.id.clone(),
                origin: sender.id.clone(),
                index,
                chunk_count: descriptor.chunk_count,
                bytes: sender_store
                    .encrypted_file_chunk(&descriptor.id, index)
                    .unwrap()
                    .to_vec(),
            });
            let received = receiver
                .receive_file_frame(&chunk, &receiver_id, "Sender")
                .unwrap();
            if index == 0 {
                assert!(received.is_some());
            } else {
                assert!(received.is_none());
            }
        }
        assert_eq!(receiver.file_transfers().unwrap()[0].status, "ready");
        let event = receiver
            .history()
            .unwrap()
            .into_iter()
            .find(|event| event.id == event_id)
            .unwrap();
        assert_eq!(event.clip.kind, "attachment");
        let destination = dir.path().join("received.bin");
        receiver
            .save_file(&descriptor.id, &destination, || false)
            .unwrap();
        assert_eq!(std::fs::read(destination).unwrap(), contents);
        let outcome_job = receiver
            .pending_file_jobs(10)
            .unwrap()
            .into_iter()
            .find(|job| job.index == -2)
            .unwrap();
        let outcome = receiver.file_frame(&outcome_job).unwrap();
        let envelope = seal_file_frame(
            "space",
            1,
            &receiver_identity,
            &sender.member("Sender"),
            &outcome_job.event,
            outcome_job.sequence,
            &outcome,
        )
        .unwrap();
        let (_, _, authenticated) = open_file_frame(
            "space",
            &sender,
            &receiver_identity.member("Receiver"),
            &envelope,
        )
        .unwrap();
        assert!(
            matches!(authenticated, FileFrame::Outcome(FileOutcome { outcome, .. }) if outcome == "ready")
        );
        receiver.delete_file(&descriptor.id).unwrap();
        receiver.delete_file(&descriptor.id).unwrap();
        drop(receiver);
        let mut reopened = DeviceStore::open(&receiver_path, receiver_key).unwrap();
        assert!(reopened.stored_transfer(&descriptor.id).is_err());
        reopened.delete_file(&descriptor.id).unwrap();
    }

    #[test]
    fn incomplete_retention_uses_local_receive_time_and_preserves_completed_local_files() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("source.bin");
        std::fs::write(&source, b"payload").unwrap();
        let sender = DeviceIdentity::generate();
        let mut sender_store =
            DeviceStore::open(&dir.path().join("sender.db"), crate::random_secret()).unwrap();
        let mut descriptor = sender_store
            .stage_file(&source, &sender.id, || false)
            .unwrap();
        descriptor.created_at = crate::unix_time().saturating_add(100 * 365 * 24 * 60 * 60);
        let event_id = uuid::Uuid::new_v4().to_string();
        let manifest = FileFrame::Manifest(FileManifest {
            descriptor: descriptor.clone(),
            history_event: event_id,
            history_sequence: 1,
        });
        let receiver_id = uuid::Uuid::new_v4().to_string();
        let receiver_path = dir.path().join("receiver.db");
        let mut receiver = DeviceStore::open(&receiver_path, crate::random_secret()).unwrap();
        receiver
            .receive_file_frame(&manifest, &receiver_id, "Sender")
            .unwrap();
        let received_at: i64 = receiver
            .db
            .query_row(
                "SELECT created_at FROM file_transfers WHERE id=?1",
                [&descriptor.id],
                |r| r.get(0),
            )
            .unwrap();
        assert!(received_at <= crate::unix_time() && received_at > crate::unix_time() - 5);
        let now = crate::unix_time();
        receiver
            .db
            .execute(
                "UPDATE file_transfers SET created_at=?2 WHERE id=?1",
                params![descriptor.id, now - crate::DELIVERY_TERMINAL_RETENTION - 1],
            )
            .unwrap();
        receiver.prune_incomplete_files(now).unwrap();
        assert!(receiver.stored_transfer(&descriptor.id).is_err());
        assert!(receiver.is_file_tombstoned(&descriptor.id).unwrap());
        assert!(
            receiver
                .receive_file_frame(&manifest, &receiver_id, "Sender")
                .is_err()
        );

        sender_store
            .db
            .execute(
                "UPDATE file_transfers SET created_at=?2 WHERE id=?1",
                params![descriptor.id, now - crate::DELIVERY_TERMINAL_RETENTION - 1],
            )
            .unwrap();
        sender_store.prune_incomplete_files(now).unwrap();
        assert!(sender_store.stored_transfer(&descriptor.id).is_ok());
    }

    #[test]
    fn sensitive_filename_fails_with_authenticated_outcome_without_history() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("safe.bin");
        std::fs::write(&source, b"file bytes").unwrap();
        let sender = DeviceIdentity::generate();
        let receiver = DeviceIdentity::generate();
        let mut sender_store =
            DeviceStore::open(&dir.path().join("sender.db"), crate::random_secret()).unwrap();
        let descriptor = sender_store
            .stage_file(&source, &sender.id, || false)
            .unwrap();
        let mut hostile_descriptor = descriptor.clone();
        hostile_descriptor.filename = "token=abcdefghijklmnop.bin".into();
        let history_event = uuid::Uuid::new_v4().to_string();
        let recipient = receiver.id.clone();
        let mut receiver_store =
            DeviceStore::open(&dir.path().join("receiver.db"), crate::random_secret()).unwrap();
        let manifest = FileFrame::Manifest(FileManifest {
            descriptor: hostile_descriptor.clone(),
            history_event: history_event.clone(),
            history_sequence: 1,
        });
        receiver_store
            .receive_file_frame(&manifest, &recipient, "Sender")
            .unwrap();
        let chunk = FileFrame::Chunk(FileChunk {
            transfer: hostile_descriptor.id.clone(),
            origin: sender.id.clone(),
            index: 0,
            chunk_count: hostile_descriptor.chunk_count,
            bytes: sender_store
                .encrypted_file_chunk(&descriptor.id, 0)
                .unwrap()
                .to_vec(),
        });
        assert!(
            receiver_store
                .receive_file_frame(&chunk, &recipient, "Sender")
                .unwrap()
                .is_none()
        );
        assert_eq!(receiver_store.file_transfers().unwrap()[0].status, "failed");
        assert!(
            !receiver_store
                .history()
                .unwrap()
                .iter()
                .any(|event| event.id == history_event)
        );
        let outcome_job = receiver_store
            .pending_file_jobs(10)
            .unwrap()
            .into_iter()
            .find(|job| job.index == -2)
            .unwrap();
        let frame = receiver_store.file_frame(&outcome_job).unwrap();
        let envelope = seal_file_frame(
            "space",
            1,
            &receiver,
            &sender.member("Sender"),
            &outcome_job.event,
            outcome_job.sequence,
            &frame,
        )
        .unwrap();
        let (_, _, authenticated) =
            open_file_frame("space", &sender, &receiver.member("Receiver"), &envelope).unwrap();
        assert!(
            matches!(authenticated, FileFrame::Outcome(FileOutcome { outcome, .. }) if outcome == "failed")
        );
    }

    #[test]
    fn repeated_hash_failures_release_ciphertext_and_tombstone_without_history() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("payload.bin");
        std::fs::write(&source, vec![0x5a; 1024 * 1024]).unwrap();
        let sender = DeviceIdentity::generate();
        let receiver = DeviceIdentity::generate();
        let mut sender_store =
            DeviceStore::open(&dir.path().join("sender.db"), crate::random_secret()).unwrap();
        let mut receiver_store =
            DeviceStore::open(&dir.path().join("receiver.db"), crate::random_secret()).unwrap();

        for sequence in 1..=8 {
            let staged = sender_store
                .stage_file(&source, &sender.id, || false)
                .unwrap();
            let mut descriptor = staged.clone();
            descriptor.sha256 = hex::encode(Sha256::digest(b"different file"));
            let event_id = uuid::Uuid::new_v4().to_string();
            let manifest = FileFrame::Manifest(FileManifest {
                descriptor: descriptor.clone(),
                history_event: event_id.clone(),
                history_sequence: sequence,
            });
            receiver_store
                .receive_file_frame(&manifest, &receiver.id, "Sender")
                .unwrap();
            if sequence == 1 {
                receiver_store
                    .db
                    .execute(
                        "UPDATE file_transfers SET created_at=?2 WHERE id=?1",
                        params![
                            descriptor.id,
                            crate::unix_time() - crate::DELIVERY_TERMINAL_RETENTION - 1
                        ],
                    )
                    .unwrap();
            }
            let chunk = FileFrame::Chunk(FileChunk {
                transfer: descriptor.id.clone(),
                origin: sender.id.clone(),
                index: 0,
                chunk_count: descriptor.chunk_count,
                bytes: sender_store
                    .encrypted_file_chunk(&staged.id, 0)
                    .unwrap()
                    .to_vec(),
            });
            receiver_store
                .receive_file_frame(&chunk, &receiver.id, "Sender")
                .unwrap();

            let retained_chunks: u64 = receiver_store
                .db
                .query_row(
                    "SELECT COALESCE(SUM(LENGTH(payload)),0) FROM file_chunks WHERE transfer=?1",
                    [&descriptor.id],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(retained_chunks, 0, "failed file retained encrypted chunks");
            assert_eq!(
                receiver_store
                    .file_transfers()
                    .unwrap()
                    .into_iter()
                    .find(|file| file.id == descriptor.id)
                    .unwrap()
                    .status,
                "failed"
            );
            assert!(
                !receiver_store
                    .history()
                    .unwrap()
                    .iter()
                    .any(|event| event.id == event_id)
            );
            if sequence == 1 {
                let failure_job: bool = receiver_store
                    .db
                    .query_row(
                        "SELECT EXISTS(SELECT 1 FROM file_jobs WHERE transfer=?1 AND idx=-2 AND status='pending')",
                        [&descriptor.id],
                        |row| row.get(0),
                    )
                    .unwrap();
                assert!(
                    failure_job,
                    "authenticated failure outcome was not retained"
                );
                receiver_store
                    .prune_incomplete_files(crate::unix_time())
                    .unwrap();
                assert!(
                    receiver_store
                        .file_transfers()
                        .unwrap()
                        .iter()
                        .any(|file| file.id == descriptor.id)
                );
                receiver_store
                    .db
                    .execute(
                        "UPDATE file_transfers SET created_at=?2 WHERE id=?1",
                        params![
                            descriptor.id,
                            crate::unix_time() - crate::DELIVERY_TERMINAL_RETENTION - 1
                        ],
                    )
                    .unwrap();
                receiver_store
                    .prune_incomplete_files(crate::unix_time())
                    .unwrap();
                assert!(
                    receiver_store
                        .file_transfers()
                        .unwrap()
                        .iter()
                        .all(|file| file.id != descriptor.id)
                );
                assert!(receiver_store.is_file_tombstoned(&descriptor.id).unwrap());
            }
            assert!(matches!(
                receiver_store.receive_file_frame(&manifest, &receiver.id, "Sender"),
                Err(SyncError::Attachment)
            ));
        }
    }
}
