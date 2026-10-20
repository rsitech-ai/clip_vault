use clipvault_sync_core::*;
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use std::path::Path;
use subtle::ConstantTimeEq;

pub const PAIRING_CLOCK_SKEW_SECONDS: i64 = 60;
/// Terminal state remains queryable for the 30-day pending lifetime plus a
/// seven-day grace period, so a sender returning after acknowledgement sees it.
pub const TERMINAL_DELIVERY_RETENTION: i64 = DELIVERY_TTL + 7 * 24 * 60 * 60;
/// Hard ceiling across all workspaces; reaching it rejects new submissions.
pub const MAX_RETAINED_DELIVERIES: u64 = 100_000;
pub const MAX_TOTAL_PENDING_BYTES: u64 = 1024 * 1024 * 1024;
pub const MAX_ENROLLMENT_RECEIPTS: u64 = 100_000;
pub const MAX_INVITE_IDENTIFIERS: u64 = 100_000;

pub struct RelayStore {
    db: Connection,
    registration_hash: String,
}
#[derive(Clone)]
pub struct Auth {
    pub workspace: String,
    pub device: String,
    owner: bool,
}
#[derive(Serialize, Deserialize)]
pub struct MailItem {
    pub cursor: i64,
    pub envelope: Envelope,
}

impl RelayStore {
    pub fn open(path: &Path, registration_token: &str) -> Result<Self> {
        if registration_token.is_empty() {
            return Err(SyncError::Authentication);
        }
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
        db.execute_batch("PRAGMA foreign_keys=ON; PRAGMA secure_delete=ON;
            CREATE TABLE IF NOT EXISTS workspaces(id TEXT PRIMARY KEY, owner_key TEXT NOT NULL, owner_device TEXT NOT NULL, epoch INTEGER NOT NULL, roster TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS devices(workspace TEXT NOT NULL, device TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE, active INTEGER NOT NULL, PRIMARY KEY(workspace,device));
            CREATE TABLE IF NOT EXISTS invites(id TEXT PRIMARY KEY, workspace TEXT NOT NULL, expires INTEGER NOT NULL, consumed INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS joins(id TEXT PRIMARY KEY, invite TEXT NOT NULL, body TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS enrollments(invite TEXT PRIMARY KEY, request_id TEXT NOT NULL, request_digest TEXT NOT NULL, roster TEXT NOT NULL, device TEXT NOT NULL, token_hash TEXT NOT NULL, completed_at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS deliveries(cursor INTEGER PRIMARY KEY AUTOINCREMENT, workspace TEXT NOT NULL, sender TEXT NOT NULL, recipient TEXT NOT NULL, event TEXT NOT NULL, envelope TEXT, status TEXT NOT NULL, created INTEGER NOT NULL, terminal_at INTEGER, UNIQUE(workspace,event,recipient));")?;
        let has_terminal_at: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM pragma_table_info('deliveries') WHERE name='terminal_at')",
            [],
            |r| r.get(0),
        )?;
        if !has_terminal_at {
            db.execute("ALTER TABLE deliveries ADD COLUMN terminal_at INTEGER", [])?;
            db.execute(
                "UPDATE deliveries SET terminal_at=created WHERE status!='pending'",
                [],
            )?;
        }
        let has_completed_at: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM pragma_table_info('enrollments') WHERE name='completed_at')",
            [],
            |r| r.get(0),
        )?;
        if !has_completed_at {
            db.execute(
                "ALTER TABLE enrollments ADD COLUMN completed_at INTEGER NOT NULL DEFAULT 0",
                [],
            )?;
        }
        let mut store = Self {
            db,
            registration_hash: credential_hash(registration_token),
        };
        store.maintain(super::now())?;
        Ok(store)
    }
    pub fn registration_allowed(&self, token: &str) -> bool {
        bool::from(
            credential_hash(token)
                .as_bytes()
                .ct_eq(self.registration_hash.as_bytes()),
        )
    }
    pub fn authenticate(&self, token: &str) -> Result<Auth> {
        self.db.query_row("SELECT d.workspace,d.device,w.owner_device=d.device FROM devices d JOIN workspaces w ON w.id=d.workspace WHERE d.token_hash=?1 AND d.active=1",[credential_hash(token)],|r|Ok(Auth { workspace:r.get(0)?, device:r.get(1)?, owner:r.get(2)? })).optional()?.ok_or(SyncError::Authentication)
    }
    fn owner(auth: &Auth) -> Result<()> {
        if auth.owner {
            Ok(())
        } else {
            Err(SyncError::Authentication)
        }
    }
    pub fn bootstrap(
        &mut self,
        roster: SignedRoster,
        owner_key: &str,
        owner_device: &str,
        token_hash: &str,
    ) -> Result<()> {
        roster.verify(owner_key, 1)?;
        validate_hash(token_hash)?;
        if roster.epoch != 1 || roster.members.len() != 1 || roster.members[0].id != owner_device {
            return Err(SyncError::Membership);
        }
        let tx = self.db.transaction()?;
        let count: u64 = tx.query_row("SELECT COUNT(*) FROM workspaces", [], |r| r.get(0))?;
        if count >= 16 {
            return Err(SyncError::Capacity);
        }
        tx.execute(
            "INSERT INTO workspaces(id,owner_key,owner_device,epoch,roster) VALUES(?1,?2,?3,1,?4)",
            params![
                roster.workspace,
                owner_key,
                owner_device,
                serde_json::to_string(&roster)?
            ],
        )?;
        tx.execute(
            "INSERT INTO devices(workspace,device,token_hash,active) VALUES(?1,?2,?3,1)",
            params![roster.workspace, owner_device, token_hash],
        )?;
        tx.commit()?;
        Ok(())
    }
    pub fn roster(&self, auth: &Auth) -> Result<SignedRoster> {
        let data: String = self.db.query_row(
            "SELECT roster FROM workspaces WHERE id=?1",
            [&auth.workspace],
            |r| r.get(0),
        )?;
        Ok(serde_json::from_str(&data)?)
    }
    pub fn publish(
        &mut self,
        auth: &Auth,
        roster: SignedRoster,
        enrollment: Option<(&str, &str, &str, &str, &str)>,
    ) -> Result<()> {
        Self::owner(auth)?;
        if let Some((device, hash, invite_id, request_id, request_digest)) = enrollment {
            let saved: Option<(String, String, String, String, String)> = self.db.query_row(
                "SELECT request_id,request_digest,roster,device,token_hash FROM enrollments WHERE invite=?1",
                [invite_id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
            ).optional()?;
            if let Some((saved_request, saved_digest, saved_roster, saved_device, saved_hash)) =
                saved
            {
                if saved_request == request_id
                    && saved_digest == request_digest
                    && saved_roster == serde_json::to_string(&roster)?
                    && saved_device == device
                    && saved_hash == hash
                {
                    return Ok(());
                }
                return Err(SyncError::Authentication);
            }
        }
        let (owner_key, epoch): (String, u64) = self.db.query_row(
            "SELECT owner_key,epoch FROM workspaces WHERE id=?1",
            [&auth.workspace],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        if roster.workspace != auth.workspace
            || roster.epoch != epoch.checked_add(1).ok_or(SyncError::Invalid)?
        {
            return Err(SyncError::Membership);
        }
        roster.verify(&owner_key, epoch + 1)?;
        roster.member(&auth.device)?;
        let old = self.roster(auth)?;
        for member in &roster.members {
            if let Ok(previous) = old.member(&member.id) {
                if previous.public_key != member.public_key {
                    return Err(SyncError::Membership);
                }
            } else if enrollment.map(|x| x.0) != Some(member.id.as_str()) {
                return Err(SyncError::Membership);
            }
        }
        let tx = self.db.transaction()?;
        if let Some((device, hash, invite_id, request_id, request_digest)) = enrollment {
            validate_hash(hash)?;
            roster.member(device)?;
            if old.member(device).is_ok() {
                return Err(SyncError::Membership);
            }
            let join_body: String = tx.query_row(
                "SELECT body FROM joins WHERE id=?1 AND invite=?2",
                params![request_id, invite_id],
                |r| r.get(0),
            )?;
            let request: JoinRequest = serde_json::from_str(&join_body)?;
            if request.device_id != device || request.digest() != request_digest {
                return Err(SyncError::Authentication);
            }
            let invite_valid: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM invites WHERE id=?1 AND workspace=?2 AND consumed=0 AND expires>=?3)",
                params![invite_id, auth.workspace, super::now().saturating_sub(PAIRING_CLOCK_SKEW_SECONDS)],
                |r| r.get(0),
            )?;
            if !invite_valid {
                return Err(SyncError::Invitation);
            }
            tx.execute(
                "INSERT INTO devices(workspace,device,token_hash,active) VALUES(?1,?2,?3,1)",
                params![auth.workspace, device, hash],
            )?;
        }
        tx.execute(
            "UPDATE devices SET active=0 WHERE workspace=?1",
            [&auth.workspace],
        )?;
        for member in &roster.members {
            tx.execute(
                "UPDATE devices SET active=1 WHERE workspace=?1 AND device=?2",
                params![auth.workspace, member.id],
            )?;
        }
        tx.execute("UPDATE deliveries SET envelope=NULL,status='revoked',terminal_at=?2 WHERE workspace=?1 AND (recipient IN (SELECT device FROM devices WHERE workspace=?1 AND active=0) OR sender IN (SELECT device FROM devices WHERE workspace=?1 AND active=0)) AND status='pending'",params![&auth.workspace, super::now()])?;
        tx.execute(
            "UPDATE workspaces SET epoch=?2,roster=?3 WHERE id=?1",
            params![
                auth.workspace,
                roster.epoch,
                serde_json::to_string(&roster)?
            ],
        )?;
        if let Some((device, hash, invite_id, request_id, request_digest)) = enrollment {
            let receipt_count: u64 =
                tx.query_row("SELECT COUNT(*) FROM enrollments", [], |r| r.get(0))?;
            if receipt_count >= MAX_ENROLLMENT_RECEIPTS {
                return Err(SyncError::Capacity);
            }
            tx.execute(
                "INSERT INTO enrollments(invite,request_id,request_digest,roster,device,token_hash,completed_at) VALUES(?1,?2,?3,?4,?5,?6,?7)",
                params![invite_id, request_id, request_digest, serde_json::to_string(&roster)?, device, hash, super::now()],
            )?;
            let consumed = tx.execute(
                "UPDATE invites SET consumed=1 WHERE id=?1 AND workspace=?2 AND consumed=0",
                params![invite_id, auth.workspace],
            )?;
            if consumed != 1 {
                return Err(SyncError::Invitation);
            }
            tx.execute("DELETE FROM joins WHERE invite=?1", [invite_id])?;
        }
        tx.commit()?;
        Ok(())
    }
    pub fn register_invite(&mut self, auth: &Auth, id: &str, expires: i64, now: i64) -> Result<()> {
        Self::owner(auth)?;
        if expires < now - PAIRING_CLOCK_SKEW_SECONDS
            || expires > now + 600 + PAIRING_CLOCK_SKEW_SECONDS
            || uuid_invalid(id)
        {
            return Err(SyncError::Invitation);
        }
        self.db.execute("DELETE FROM joins WHERE invite IN(SELECT id FROM invites WHERE expires<=?1 OR consumed=1)",[now.saturating_sub(PAIRING_CLOCK_SKEW_SECONDS)])?;
        let count: u64 = self.db.query_row(
            "SELECT COUNT(*) FROM invites WHERE workspace=?1 AND consumed=0 AND expires>=?2",
            params![
                &auth.workspace,
                now.saturating_sub(PAIRING_CLOCK_SKEW_SECONDS)
            ],
            |r| r.get(0),
        )?;
        let lifetime_count: u64 = self
            .db
            .query_row("SELECT COUNT(*) FROM invites", [], |r| r.get(0))?;
        if count >= 4 || lifetime_count >= MAX_INVITE_IDENTIFIERS {
            return Err(SyncError::Capacity);
        }
        self.db.execute(
            "INSERT INTO invites(id,workspace,expires) VALUES(?1,?2,?3)",
            params![id, auth.workspace, expires],
        )?;
        Ok(())
    }
    pub fn request_join(&mut self, request: &JoinRequest, now: i64) -> Result<()> {
        request.validate_shape()?;
        let allowed: bool = self.db.query_row(
            "SELECT EXISTS(SELECT 1 FROM invites WHERE id=?1 AND expires>=?2 AND consumed=0)",
            params![
                request.invite_id,
                now.saturating_sub(PAIRING_CLOCK_SKEW_SECONDS)
            ],
            |r| r.get(0),
        )?;
        if !allowed {
            return Err(SyncError::Invitation);
        }
        let encoded = serde_json::to_string(request)?;
        let prior: Option<(String, String)> = self
            .db
            .query_row(
                "SELECT invite,body FROM joins WHERE id=?1",
                [&request.id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        if let Some((invite, body)) = prior {
            return if invite == request.invite_id && body == encoded {
                Ok(())
            } else {
                Err(SyncError::Authentication)
            };
        }
        let count: u64 = self.db.query_row(
            "SELECT COUNT(*) FROM joins WHERE invite=?1",
            [&request.invite_id],
            |r| r.get(0),
        )?;
        if count >= 5 {
            return Err(SyncError::Capacity);
        }
        self.db.execute(
            "INSERT OR IGNORE INTO joins(id,invite,body) VALUES(?1,?2,?3)",
            params![request.id, request.invite_id, encoded],
        )?;
        Ok(())
    }
    pub fn joins(&self, auth: &Auth, now: i64) -> Result<Vec<JoinRequest>> {
        Self::owner(auth)?;
        let mut q = self.db.prepare("SELECT j.body FROM joins j JOIN invites i ON i.id=j.invite WHERE i.workspace=?1 AND i.expires>=?2 AND i.consumed=0 LIMIT 20")?;
        q.query_map(
            params![
                auth.workspace,
                now.saturating_sub(PAIRING_CLOCK_SKEW_SECONDS)
            ],
            |r| r.get::<_, String>(0),
        )?
        .map(|r| Ok(serde_json::from_str(&r?)?))
        .collect()
    }
    pub fn consume_invite(&mut self, auth: &Auth, id: &str) -> Result<()> {
        Self::owner(auth)?;
        self.db.execute(
            "UPDATE invites SET consumed=1 WHERE workspace=?1 AND id=?2",
            params![auth.workspace, id],
        )?;
        self.db.execute("DELETE FROM joins WHERE invite IN (SELECT id FROM invites WHERE workspace=?1 AND id=?2)",params![auth.workspace,id])?;
        Ok(())
    }
    pub fn maintain(&mut self, now: i64) -> Result<()> {
        self.db.execute(
            "UPDATE deliveries SET envelope=NULL,status='expired',terminal_at=?2 WHERE status='pending' AND created<=?1",
            params![now - DELIVERY_TTL, now],
        )?;
        self.db.execute(
            "DELETE FROM deliveries WHERE status!='pending' AND terminal_at IS NOT NULL AND terminal_at<=?1",
            [now.saturating_sub(TERMINAL_DELIVERY_RETENTION)],
        )?;
        self.db.execute(
            "UPDATE invites SET consumed=1 WHERE consumed=0 AND expires<?1",
            [now.saturating_sub(PAIRING_CLOCK_SKEW_SECONDS)],
        )?;
        self.db.execute(
            "DELETE FROM joins WHERE invite IN (SELECT id FROM invites WHERE consumed=1)",
            [],
        )?;
        self.db.execute(
            "DELETE FROM enrollments WHERE completed_at<=?1",
            [now.saturating_sub(TERMINAL_DELIVERY_RETENTION)],
        )?;
        Ok(())
    }
    pub fn submit(&mut self, auth: &Auth, envelope: &Envelope, now: i64) -> Result<i64> {
        self.maintain(now)?;
        let roster = self.roster(auth)?;
        let h = &envelope.header;
        if h.version != 1
            || h.message_type != "clip"
            || h.workspace != auth.workspace
            || h.sender != auth.device
            || h.epoch != roster.epoch
            || h.sequence == 0
            || uuid_invalid(&h.event)
            || envelope.encapsulated_key.len() != 44
        {
            return Err(SyncError::Membership);
        }
        roster.member(&h.recipient)?;
        roster.member(&h.sender)?;
        let body = serde_json::to_string(envelope)?;
        if body.len() > MAX_WIRE_BYTES {
            return Err(SyncError::TooLarge);
        }
        let tx = self.db.transaction()?;
        let existing: Option<(i64,String)> = tx.query_row("SELECT cursor,sender FROM deliveries WHERE workspace=?1 AND event=?2 AND recipient=?3",params![auth.workspace,h.event,h.recipient],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
        if let Some((cursor, sender)) = existing {
            if sender != auth.device {
                return Err(SyncError::Authentication);
            }
            return Ok(cursor);
        }
        let retained: u64 = tx.query_row("SELECT COUNT(*) FROM deliveries", [], |r| r.get(0))?;
        if retained >= MAX_RETAINED_DELIVERIES {
            return Err(SyncError::Capacity);
        }
        let used:u64 = tx.query_row("SELECT COALESCE(SUM(LENGTH(envelope)),0) FROM deliveries WHERE workspace=?1 AND recipient=?2 AND status='pending'",params![auth.workspace,h.recipient],|r|r.get(0))?;
        if used.saturating_add(body.len() as u64) > MAX_QUEUE_BYTES {
            return Err(SyncError::Capacity);
        }
        let total_used: u64 = tx.query_row(
            "SELECT COALESCE(SUM(LENGTH(envelope)),0) FROM deliveries WHERE status='pending'",
            [],
            |r| r.get(0),
        )?;
        if total_used.saturating_add(body.len() as u64) > MAX_TOTAL_PENDING_BYTES {
            return Err(SyncError::Capacity);
        }
        tx.execute("INSERT INTO deliveries(workspace,sender,recipient,event,envelope,status,created) VALUES(?1,?2,?3,?4,?5,'pending',?6)",params![auth.workspace,auth.device,h.recipient,h.event,body,now])?;
        let cursor = tx.last_insert_rowid();
        tx.commit()?;
        Ok(cursor)
    }
    pub fn mailbox(&mut self, auth: &Auth, now: i64) -> Result<Vec<MailItem>> {
        self.maintain(now)?;
        // One maximum-size event per response bounds decrypted response allocations.
        let mut q=self.db.prepare("SELECT cursor,envelope FROM deliveries WHERE workspace=?1 AND recipient=?2 AND status='pending' ORDER BY cursor LIMIT 1")?;
        q.query_map(params![auth.workspace, auth.device], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
        })?
        .map(|r| {
            let (cursor, body) = r?;
            Ok(MailItem {
                cursor,
                envelope: serde_json::from_str(&body)?,
            })
        })
        .collect()
    }
    pub fn ack(&mut self, auth: &Auth, cursor: i64) -> Result<()> {
        let count=self.db.execute("UPDATE deliveries SET envelope=NULL,status='delivered',terminal_at=COALESCE(terminal_at,?4) WHERE workspace=?1 AND recipient=?2 AND cursor=?3 AND status IN ('pending','delivered')",params![auth.workspace,auth.device,cursor,super::now()])?;
        if count == 0 {
            return Err(SyncError::Authentication);
        }
        Ok(())
    }
    pub fn reject(&mut self, auth: &Auth, cursor: i64) -> Result<()> {
        let count=self.db.execute("UPDATE deliveries SET envelope=NULL,status='rejected',terminal_at=COALESCE(terminal_at,?4) WHERE workspace=?1 AND recipient=?2 AND cursor=?3 AND status IN ('pending','rejected')",params![auth.workspace,auth.device,cursor,super::now()])?;
        if count == 0 {
            return Err(SyncError::Authentication);
        }
        Ok(())
    }
    pub fn delivery_status(
        &mut self,
        auth: &Auth,
        event: &str,
        recipient: &str,
        now: i64,
    ) -> Result<String> {
        self.maintain(now)?;
        Ok(self.db.query_row("SELECT status FROM deliveries WHERE workspace=?1 AND sender=?2 AND event=?3 AND recipient=?4",params![auth.workspace,auth.device,event,recipient],|r|r.get(0)).optional()?.unwrap_or_else(||"missing".into()))
    }
}
fn validate_hash(hash: &str) -> Result<()> {
    if hash.len() != 64 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) {
        Err(SyncError::Invalid)
    } else {
        Ok(())
    }
}
fn uuid_invalid(value: &str) -> bool {
    value.len() != 36 || !value.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
}
