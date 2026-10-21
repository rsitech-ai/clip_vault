use crate::{ClipEvent, MAX_QUEUE_BYTES, MAX_WIRE_BYTES, Result, SyncError, random_secret};
use chacha20poly1305::{
    ChaCha20Poly1305, KeyInit, Nonce,
    aead::{Aead, Payload},
};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Serialize, de::DeserializeOwned};
use sha2::{Digest, Sha256};
use std::path::Path;
use zeroize::Zeroizing;

const MAX_EVENT_BATCH_COUNT: usize = 16;
// The event payload budget is the portable wire limit; this small allowance
// covers event identity fields and JSON array framing.
const MAX_EVENT_BATCH_BYTES: usize = MAX_WIRE_BYTES + 1024;

pub struct DeviceStore {
    pub(crate) db: Connection,
    pub(crate) path: std::path::PathBuf,
    #[cfg(test)]
    pub(crate) file_space_override: Option<u64>,
    key: Zeroizing<[u8; 32]>,
    queue_limit: u64,
}
impl DeviceStore {
    pub fn open(path: &Path, key: [u8; 32]) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let db = Connection::open(path)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        }
        db.busy_timeout(std::time::Duration::from_secs(5))?;
        db.execute_batch("PRAGMA journal_mode=DELETE; PRAGMA foreign_keys=ON; PRAGMA secure_delete=ON;
            CREATE TABLE IF NOT EXISTS state (name TEXT PRIMARY KEY, value BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, origin TEXT NOT NULL, sequence INTEGER NOT NULL, digest BLOB NOT NULL, payload BLOB, outgoing INTEGER NOT NULL DEFAULT 0, applied INTEGER NOT NULL DEFAULT 0, UNIQUE(origin,sequence));
            CREATE TABLE IF NOT EXISTS receipts (cursor INTEGER PRIMARY KEY, event TEXT, applied INTEGER NOT NULL DEFAULT 0, acknowledged INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS targets (event TEXT NOT NULL, recipient TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', attempted_at INTEGER, PRIMARY KEY(event,recipient));")?;
        db.execute(
            "CREATE INDEX IF NOT EXISTS events_outgoing ON events(outgoing)",
            [],
        )?;
        db.execute_batch("CREATE TABLE IF NOT EXISTS file_transfers (id TEXT PRIMARY KEY, payload BLOB NOT NULL, direction TEXT NOT NULL, state TEXT NOT NULL, committed INTEGER NOT NULL DEFAULT 0, event_id TEXT, transferred INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS file_chunks (transfer TEXT NOT NULL REFERENCES file_transfers(id) ON DELETE CASCADE, idx INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(transfer,idx));
            CREATE TABLE IF NOT EXISTS file_jobs (transfer TEXT NOT NULL, recipient TEXT NOT NULL, idx INTEGER NOT NULL, frame_event TEXT NOT NULL, sequence INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'pending', attempted_at INTEGER, first_attempted_at INTEGER, PRIMARY KEY(transfer,recipient,idx), UNIQUE(frame_event,recipient));
            CREATE TABLE IF NOT EXISTS file_targets (transfer TEXT NOT NULL, recipient TEXT NOT NULL, status TEXT NOT NULL, PRIMARY KEY(transfer,recipient));
            CREATE TABLE IF NOT EXISTS file_tombstones (transfer TEXT PRIMARY KEY, origin TEXT NOT NULL, deleted_at INTEGER NOT NULL);")?;
        db.execute_batch("CREATE INDEX IF NOT EXISTS file_jobs_pending ON file_jobs(transfer,status);
            CREATE INDEX IF NOT EXISTS file_jobs_scheduling ON file_jobs(status,COALESCE(attempted_at,0));")?;
        let has_attempted: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM pragma_table_info('targets') WHERE name='attempted_at')",
            [],
            |r| r.get(0),
        )?;
        if !has_attempted {
            db.execute("ALTER TABLE targets ADD COLUMN attempted_at INTEGER", [])?;
        }
        let has_file_first_attempt: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM pragma_table_info('file_jobs') WHERE name='first_attempted_at')",
            [],
            |row| row.get(0),
        )?;
        if !has_file_first_attempt {
            let tx = db.unchecked_transaction()?;
            tx.execute(
                "ALTER TABLE file_jobs ADD COLUMN first_attempted_at INTEGER",
                [],
            )?;
            // Earlier previews did not distinguish first send from capacity
            // retry deadlines. Creation time is a conservative lower bound;
            // do not give an old frame another relay lifetime on upgrade.
            tx.execute("UPDATE file_jobs SET first_attempted_at=(SELECT created_at FROM file_transfers WHERE id=file_jobs.transfer) WHERE status='pending'", [])?;
            tx.commit()?;
        }
        let mut store = Self {
            db,
            path: path.to_path_buf(),
            #[cfg(test)]
            file_space_override: None,
            key: Zeroizing::new(key),
            queue_limit: MAX_QUEUE_BYTES,
        };
        store.prune_incomplete_files(crate::unix_time())?;
        match store.get::<String>("key-check")? {
            Some(value) if value == "ClipVault encrypted state v1" => {}
            None => store.put("key-check", &"ClipVault encrypted state v1")?,
            _ => return Err(SyncError::Authentication),
        }
        Ok(store)
    }
    pub(crate) fn seal<T: Serialize>(&self, context: &str, data: &T) -> Result<Vec<u8>> {
        let plaintext = Zeroizing::new(serde_json::to_vec(data)?);
        let nonce: [u8; 12] = random_secret()[..12]
            .try_into()
            .map_err(|_| SyncError::Invalid)?;
        let ciphertext = ChaCha20Poly1305::new((&*self.key).into())
            .encrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: &plaintext,
                    aad: context.as_bytes(),
                },
            )
            .map_err(|_| SyncError::Authentication)?;
        Ok([nonce.as_slice(), &ciphertext].concat())
    }
    pub(crate) fn unseal<T: DeserializeOwned>(&self, context: &str, blob: &[u8]) -> Result<T> {
        if blob.len() < 28 {
            return Err(SyncError::Invalid);
        }
        let plaintext = Zeroizing::new(
            ChaCha20Poly1305::new((&*self.key).into())
                .decrypt(
                    Nonce::from_slice(&blob[..12]),
                    Payload {
                        msg: &blob[12..],
                        aad: context.as_bytes(),
                    },
                )
                .map_err(|_| SyncError::Authentication)?,
        );
        Ok(serde_json::from_slice(&plaintext)?)
    }
    pub(crate) fn seal_raw(&self, context: &str, plaintext: &[u8]) -> Result<Vec<u8>> {
        let nonce: [u8; 12] = random_secret()[..12]
            .try_into()
            .map_err(|_| SyncError::Invalid)?;
        let ciphertext = ChaCha20Poly1305::new((&*self.key).into())
            .encrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: plaintext,
                    aad: context.as_bytes(),
                },
            )
            .map_err(|_| SyncError::Authentication)?;
        Ok([nonce.as_slice(), &ciphertext].concat())
    }
    pub(crate) fn unseal_raw(&self, context: &str, blob: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
        if blob.len() < 28 {
            return Err(SyncError::Invalid);
        }
        Ok(Zeroizing::new(
            ChaCha20Poly1305::new((&*self.key).into())
                .decrypt(
                    Nonce::from_slice(&blob[..12]),
                    Payload {
                        msg: &blob[12..],
                        aad: context.as_bytes(),
                    },
                )
                .map_err(|_| SyncError::Authentication)?,
        ))
    }
    pub fn put<T: Serialize>(&mut self, name: &str, value: &T) -> Result<()> {
        let blob = self.seal(name, value)?;
        self.db.execute("INSERT INTO state(name,value) VALUES(?1,?2) ON CONFLICT(name) DO UPDATE SET value=excluded.value", params![name,blob])?;
        Ok(())
    }
    pub fn get<T: DeserializeOwned>(&self, name: &str) -> Result<Option<T>> {
        let blob: Option<Vec<u8>> = self
            .db
            .query_row("SELECT value FROM state WHERE name=?1", [name], |r| {
                r.get(0)
            })
            .optional()?;
        blob.map(|b| self.unseal(name, &b)).transpose()
    }
    pub fn remove_state(&mut self, name: &str) -> Result<()> {
        self.db.execute("DELETE FROM state WHERE name=?1", [name])?;
        Ok(())
    }
    pub(crate) fn commit_bootstrap<T: Serialize>(
        &mut self,
        owner: &crate::OwnerIdentity,
        configuration: &T,
    ) -> Result<()> {
        let owner = self.seal("owner", owner)?;
        let configuration = self.seal("configuration", configuration)?;
        let tx = self.db.transaction()?;
        tx.execute("INSERT INTO state(name,value) VALUES('owner',?1) ON CONFLICT(name) DO UPDATE SET value=excluded.value", [owner])?;
        tx.execute("INSERT INTO state(name,value) VALUES('configuration',?1) ON CONFLICT(name) DO UPDATE SET value=excluded.value", [configuration])?;
        tx.execute("DELETE FROM state WHERE name='pending-bootstrap'", [])?;
        tx.commit()?;
        Ok(())
    }
    pub(crate) fn reset_pairing(&mut self, identity: &crate::DeviceIdentity) -> Result<usize> {
        let identity_blob = self.seal("identity", identity)?;
        let failure_blob = self.seal("delivery-failure", &"cancelled by disconnect")?;
        let tx = self.db.transaction()?;
        let cancelled = tx.execute(
            "UPDATE targets SET status='cancelled' WHERE status='pending'",
            [],
        )?;
        tx.execute(
            "UPDATE file_jobs SET status='cancelled' WHERE status='pending'",
            [],
        )?;
        tx.execute(
            "UPDATE file_targets SET status='failed' WHERE status='pending'",
            [],
        )?;
        tx.execute("UPDATE file_transfers SET state='failed',committed=0 WHERE direction='outgoing' AND state NOT IN ('ready','failed','unsupported')", [])?;
        tx.execute(
            "UPDATE events SET outgoing=0,applied=1 WHERE outgoing IN (0,1,2,3)",
            [],
        )?;
        tx.execute("UPDATE receipts SET applied=1,acknowledged=1", [])?;
        tx.execute(
            "DELETE FROM state WHERE name IN ('configuration','owner','invite','pending-join','pending-approval','pending-bootstrap','join-words','retry-backoff','recipient-capacity-retries')",
            [],
        )?;
        tx.execute(
            "INSERT INTO state(name,value) VALUES('identity',?1) ON CONFLICT(name) DO UPDATE SET value=excluded.value",
            [identity_blob],
        )?;
        tx.execute(
            "INSERT INTO state(name,value) VALUES('delivery-failure',?1) ON CONFLICT(name) DO UPDATE SET value=excluded.value",
            [failure_blob],
        )?;
        tx.commit()?;
        Ok(cancelled)
    }
    pub fn next_sequence(&mut self) -> Result<u64> {
        self.reserve_sequences(1)
    }
    /// Reserve a durable sequence range once, rather than fsync for every chunk.
    /// Gaps after an interrupted commit are harmless; sequence reuse is not.
    pub(crate) fn reserve_sequences(&mut self, count: u64) -> Result<u64> {
        if count == 0 {
            return Err(SyncError::Invalid);
        }
        let previous = self.get::<u64>("sequence")?.unwrap_or(0);
        let next = previous
            .checked_add(count)
            .filter(|n| *n <= i64::MAX as u64)
            .ok_or(SyncError::Invalid)?;
        self.put("sequence", &next)?;
        Ok(previous + 1)
    }
    pub fn capture(&mut self, event: &ClipEvent) -> Result<bool> {
        self.insert(event, 1, None, &[])
    }
    pub fn capture_local(&mut self, event: &ClipEvent) -> Result<bool> {
        self.insert(event, 0, None, &[])
    }
    pub fn capture_with_targets(
        &mut self,
        event: &ClipEvent,
        recipients: &[String],
    ) -> Result<bool> {
        self.insert(event, 1, None, recipients)
    }
    pub fn set_queue_limit(&mut self, bytes: u64) {
        self.queue_limit = bytes.min(MAX_QUEUE_BYTES);
    }
    /// Keep the single encrypted local-history copy, with an explicit-retry
    /// flag rather than another automatic outbox entry or payload copy.
    pub fn defer_capture(&mut self, event: &ClipEvent, _recipients: &[String]) -> Result<bool> {
        self.insert(event, 3, None, &[])
    }
    pub fn promote_deferred(&mut self) -> Result<()> {
        let tx = self.db.transaction()?;
        let legacy: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM events WHERE outgoing=2)",
            [],
            |r| r.get(0),
        )?;
        if legacy {
            // Existing active deliveries may already be on the relay. Preserve
            // them even when older deferred rows precede them in local history.
            // Only the deferred queue consumes the remaining migration budget.
            let active: u64 = tx.query_row(
                "SELECT COALESCE(SUM(LENGTH(payload)),0) FROM events WHERE outgoing=1",
                [],
                |row| row.get(0),
            )?;
            tx.execute("UPDATE events SET outgoing=3 WHERE id IN (SELECT id FROM (SELECT id,SUM(LENGTH(payload)) OVER (ORDER BY rowid) AS used FROM events WHERE outgoing=2) WHERE used>?1)", [self.queue_limit.saturating_sub(active)])?;
            tx.execute("UPDATE events SET outgoing=1 WHERE outgoing=2", [])?;
        }
        tx.commit()?;
        Ok(())
    }
    pub fn overflow_count(&self) -> Result<usize> {
        Ok(self.db.query_row(
            "SELECT COUNT(*) FROM events WHERE outgoing=3 AND payload IS NOT NULL",
            [],
            |r| r.get(0),
        )?)
    }
    pub fn retry_overflow_with_targets(&mut self, recipients: &[String]) -> Result<usize> {
        if recipients.is_empty() {
            return Err(SyncError::Membership);
        }
        let events = self.events("outgoing=3", "ASC")?;
        let mut queued = 0;
        for event in events {
            let tx = self.db.transaction()?;
            let used: u64 = tx.query_row(
                "SELECT COALESCE(SUM(LENGTH(payload)),0) FROM events WHERE outgoing IN (1,2)",
                [],
                |r| r.get(0),
            )?;
            let size: u64 = tx.query_row(
                "SELECT LENGTH(payload) FROM events WHERE id=?1 AND outgoing=3",
                [&event.id],
                |r| r.get(0),
            )?;
            if used.saturating_add(size) > self.queue_limit {
                break;
            }
            tx.execute(
                "UPDATE events SET outgoing=1 WHERE id=?1 AND outgoing=3",
                [&event.id],
            )?;
            for recipient in recipients {
                tx.execute(
                    "INSERT OR IGNORE INTO targets(event,recipient) VALUES(?1,?2)",
                    params![event.id, recipient],
                )?;
            }
            tx.commit()?;
            queued += 1;
        }
        if queued == 0 && self.overflow_count()? > 0 {
            return Err(SyncError::Capacity);
        }
        Ok(queued)
    }
    pub fn contains(&self, event: &str) -> Result<bool> {
        Ok(self.db.query_row(
            "SELECT EXISTS(SELECT 1 FROM events WHERE id=?1)",
            [event],
            |r| r.get(0),
        )?)
    }
    /// Read one authenticated history event without decrypting unrelated clips.
    pub fn event(&self, event: &str) -> Result<Option<ClipEvent>> {
        let blob: Option<Vec<u8>> = self
            .db
            .query_row(
                "SELECT payload FROM events WHERE id=?1 AND payload IS NOT NULL",
                [event],
                |r| r.get(0),
            )
            .optional()?;
        blob.map(|b| self.unseal(event, &b)).transpose()
    }
    pub fn receive(&mut self, event: &ClipEvent, cursor: i64) -> Result<bool> {
        if cursor <= 0 {
            return Err(SyncError::Invalid);
        }
        if event.clip.kind == "attachment" {
            return Err(SyncError::Invalid);
        }
        self.insert(event, 0, Some(cursor), &[])
    }
    pub(crate) fn receive_verified_attachment(&mut self, event: &ClipEvent) -> Result<bool> {
        if event.clip.kind != "attachment" {
            return Err(SyncError::Invalid);
        }
        let inserted = self.insert(event, 0, None, &[])?;
        if inserted {
            self.db.execute(
                "UPDATE events SET applied=0 WHERE id=?1 AND outgoing=0",
                [&event.id],
            )?;
        }
        Ok(inserted)
    }
    pub(crate) fn record_file_receipt(&mut self, cursor: i64, event: &str) -> Result<()> {
        let previous: Option<Option<String>> = self
            .db
            .query_row(
                "SELECT event FROM receipts WHERE cursor=?1",
                [cursor],
                |r| r.get(0),
            )
            .optional()?;
        if previous.is_some_and(|value| value.as_deref() != Some(event)) {
            return Err(SyncError::Authentication);
        }
        self.db.execute(
            "INSERT OR IGNORE INTO receipts(cursor,event,applied) VALUES(?1,?2,1)",
            params![cursor, event],
        )?;
        Ok(())
    }
    fn insert(
        &mut self,
        event: &ClipEvent,
        outgoing: i64,
        cursor: Option<i64>,
        targets: &[String],
    ) -> Result<bool> {
        event.validate()?;
        let encoded = Zeroizing::new(serde_json::to_vec(event)?);
        let digest = Sha256::digest(&*encoded).to_vec();
        let blob = self.seal(&event.id, event)?;
        let tx = self.db.transaction()?;
        let existing: Option<(Vec<u8>, bool)> = tx
            .query_row(
                "SELECT digest, (applied=1 OR payload IS NULL) FROM events WHERE id=?1",
                [&event.id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let inserted;
        let applied;
        if let Some((previous, was_applied)) = existing {
            if previous != digest {
                return Err(SyncError::Authentication);
            }
            inserted = false;
            applied = was_applied;
        } else {
            let replay: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM events WHERE origin=?1 AND sequence=?2)",
                params![event.origin, event.sequence],
                |r| r.get(0),
            )?;
            if replay {
                return Err(SyncError::Authentication);
            }
            let used: u64 = tx.query_row(
                "SELECT COALESCE(SUM(LENGTH(payload)),0) FROM events WHERE outgoing IN (1,2)",
                [],
                |r| r.get(0),
            )?;
            if outgoing == 1 && used.saturating_add(blob.len() as u64) > self.queue_limit {
                return Err(SyncError::Capacity);
            }
            tx.execute("INSERT INTO events(id,origin,sequence,digest,payload,outgoing,applied) VALUES(?1,?2,?3,?4,?5,?6,?7)", params![event.id,event.origin,event.sequence,digest,blob,outgoing,outgoing!=0 || cursor.is_none()])?;
            inserted = true;
            applied = outgoing != 0;
        }
        for recipient in targets {
            tx.execute(
                "INSERT OR IGNORE INTO targets(event,recipient) VALUES(?1,?2)",
                params![event.id, recipient],
            )?;
        }
        if let Some(cursor) = cursor {
            let previous: Option<Option<String>> = tx
                .query_row(
                    "SELECT event FROM receipts WHERE cursor=?1",
                    [cursor],
                    |r| r.get(0),
                )
                .optional()?;
            if let Some(previous) = previous
                && previous.as_deref() != Some(&event.id)
            {
                return Err(SyncError::Authentication);
            }
            tx.execute(
                "INSERT OR IGNORE INTO receipts(cursor,event,applied) VALUES(?1,?2,?3)",
                params![cursor, event.id, applied],
            )?;
        }
        tx.commit()?;
        Ok(inserted)
    }
    fn events(&self, predicate: &str, order: &str) -> Result<Vec<ClipEvent>> {
        let mut query = self.db.prepare(&format!("SELECT id,payload FROM events WHERE payload IS NOT NULL AND {predicate} ORDER BY rowid {order}"))?;
        let rows = query.query_map([], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, Vec<u8>>(1)?))
        })?;
        let mut events = Vec::new();
        let mut encoded_len = 2usize; // JSON array brackets.
        for row in rows {
            if events.len() >= MAX_EVENT_BATCH_COUNT {
                break;
            }
            let (id, blob) = row?;
            let event = self.unseal(&id, &blob)?;
            let event_len = serde_json::to_vec(&event)?.len();
            let separator_len = usize::from(!events.is_empty());
            let next_len = encoded_len
                .saturating_add(separator_len)
                .saturating_add(event_len);
            if next_len > MAX_EVENT_BATCH_BYTES {
                if events.is_empty() {
                    return Err(SyncError::TooLarge);
                }
                break;
            }
            encoded_len = next_len;
            events.push(event);
        }
        Ok(events)
    }
    pub fn history(&self) -> Result<Vec<ClipEvent>> {
        self.matching_history(2000, |_| true)
    }
    pub fn history_signature(&self) -> Result<(u64, u64)> {
        Ok(self.db.query_row(
            "SELECT COUNT(*),COALESCE(MAX(rowid),0) FROM events WHERE payload IS NOT NULL",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?)
    }
    pub fn matching_history(
        &self,
        limit: usize,
        mut matches: impl FnMut(&ClipEvent) -> bool,
    ) -> Result<Vec<ClipEvent>> {
        let mut query = self.db.prepare(
            "SELECT id,payload FROM events WHERE payload IS NOT NULL ORDER BY rowid DESC",
        )?;
        let rows = query.query_map([], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, Vec<u8>>(1)?))
        })?;
        let mut events = vec![];
        for row in rows {
            let (id, blob) = row?;
            let event = self.unseal(&id, &blob)?;
            if matches(&event) {
                events.push(event);
                if events.len() >= limit {
                    break;
                }
            }
        }
        events.sort_by(|a, b| {
            b.clip
                .captured_at
                .cmp(&a.clip.captured_at)
                .then_with(|| b.id.cmp(&a.id))
        });
        Ok(events)
    }
    pub fn pending(&self) -> Result<Vec<ClipEvent>> {
        self.events("outgoing=1", "ASC")
    }
    pub fn pending_count(&self) -> Result<usize> {
        Ok(self.db.query_row(
            "SELECT COUNT(*) FROM events WHERE outgoing IN (1,2,3)",
            [],
            |r| r.get(0),
        )?)
    }
    pub fn receipt_rejected(&self, cursor: i64) -> Result<bool> {
        Ok(self.db.query_row(
            "SELECT event IS NULL FROM receipts WHERE cursor=?1",
            [cursor],
            |r| r.get(0),
        )?)
    }
    pub fn unapplied(&self) -> Result<Vec<ClipEvent>> {
        self.events("applied=0", "ASC")
    }
    pub fn mark_applied(&mut self, event: &str) -> Result<()> {
        let tx = self.db.transaction()?;
        tx.execute("UPDATE events SET applied=1 WHERE id=?1", [event])?;
        tx.execute("UPDATE receipts SET applied=1 WHERE event=?1", [event])?;
        tx.commit()?;
        Ok(())
    }
    pub fn reject(&mut self, cursor: i64) -> Result<()> {
        self.db.execute(
            "INSERT OR IGNORE INTO receipts(cursor,event,applied) VALUES(?1,NULL,1)",
            [cursor],
        )?;
        Ok(())
    }
    pub fn reject_import(&mut self, event: &str) -> Result<()> {
        let tx = self.db.transaction()?;
        tx.execute(
            "UPDATE receipts SET event=NULL,applied=1 WHERE event=?1",
            [event],
        )?;
        tx.execute(
            "UPDATE events SET payload=NULL,applied=1 WHERE id=?1 AND outgoing=0",
            [event],
        )?;
        tx.commit()?;
        let rejected = self
            .get::<usize>("rejected")?
            .unwrap_or(0)
            .saturating_add(1);
        self.put("rejected", &rejected)
    }
    pub fn acknowledgements(&self) -> Result<Vec<i64>> {
        Ok(self
            .db
            .prepare(
                "SELECT cursor FROM receipts WHERE applied=1 AND acknowledged=0 ORDER BY cursor",
            )?
            .query_map([], |r| r.get(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?)
    }
    pub fn mark_acknowledged(&mut self, cursor: i64) -> Result<()> {
        self.db.execute(
            "UPDATE receipts SET acknowledged=1 WHERE cursor=?1 AND applied=1",
            [cursor],
        )?;
        Ok(())
    }
    pub fn delete_local(&mut self, id: &str) -> Result<()> {
        let tx = self.db.transaction()?;
        tx.execute(
            "UPDATE events SET payload=NULL,outgoing=0,applied=1 WHERE id=?1",
            [id],
        )?;
        tx.execute("UPDATE receipts SET applied=1 WHERE event=?1", [id])?;
        tx.commit()?;
        Ok(())
    }
    pub fn set_targets(&mut self, event: &str, recipients: &[String]) -> Result<()> {
        let tx = self.db.transaction()?;
        for recipient in recipients {
            tx.execute(
                "INSERT OR IGNORE INTO targets(event,recipient) VALUES(?1,?2)",
                params![event, recipient],
            )?;
        }
        tx.commit()?;
        Ok(())
    }
    pub fn targets(&self, event: &str) -> Result<Vec<String>> {
        Ok(self
            .db
            .prepare("SELECT recipient FROM targets WHERE event=?1 AND status='pending'")?
            .query_map([event], |r| r.get(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?)
    }
    pub fn target_attempted_at(&self, event: &str, recipient: &str) -> Result<Option<i64>> {
        Ok(self.db.query_row(
            "SELECT attempted_at FROM targets WHERE event=?1 AND recipient=?2",
            params![event, recipient],
            |r| r.get(0),
        )?)
    }
    pub fn mark_target_attempted(&mut self, event: &str, recipient: &str, now: i64) -> Result<()> {
        self.db.execute(
            "UPDATE targets SET attempted_at=COALESCE(attempted_at,?3) WHERE event=?1 AND recipient=?2 AND status='pending'",
            params![event, recipient, now],
        )?;
        Ok(())
    }
    pub fn target_done(&mut self, event: &str, recipient: &str, status: &str) -> Result<()> {
        let tx = self.db.transaction()?;
        tx.execute(
            "UPDATE targets SET status=?3 WHERE event=?1 AND recipient=?2",
            params![event, recipient, status],
        )?;
        tx.execute("UPDATE events SET outgoing=0 WHERE id=?1 AND NOT EXISTS(SELECT 1 FROM targets WHERE event=?1 AND status='pending')", [event])?;
        tx.commit()?;
        Ok(())
    }
}
