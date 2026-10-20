//! Blocking network client. Invoke on a worker thread, never a platform UI thread.
use crate::*;
use reqwest::{Method, blocking::Client};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use std::io::Read;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use zeroize::Zeroize;

#[derive(Clone, Serialize, Deserialize)]
struct Configuration {
    workspace: String,
    relay: String,
    owner_key: String,
    credential: String,
    roster: Option<SignedRoster>,
    enabled: bool,
    awaiting_approval: bool,
    name: String,
}

#[derive(Clone, Serialize, Deserialize)]
struct PendingJoin {
    request: JoinRequest,
    invite_id: String,
    workspace: String,
    relay: String,
    owner_key: String,
    credential: String,
    name: String,
    #[serde(default = "default_enabled")]
    enabled: bool,
}

fn default_enabled() -> bool {
    true
}
impl Drop for PendingJoin {
    fn drop(&mut self) {
        self.credential.zeroize();
    }
}

#[derive(Clone, Serialize, Deserialize)]
struct PendingApproval {
    invite_id: String,
    request_id: String,
    request_digest: String,
    words: String,
    device: String,
    token_hash: String,
    roster: SignedRoster,
}
impl Drop for Configuration {
    fn drop(&mut self) {
        self.credential.zeroize();
    }
}

#[derive(Clone, Default, Serialize, Deserialize)]
pub struct ClientStatus {
    pub state: String,
    pub device_id: String,
    pub is_owner: bool,
    pub enabled: bool,
    pub pending: usize,
    pub rejected: usize,
    pub members: Vec<Member>,
    pub requests: Vec<PairRequestView>,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct PairRequestView {
    pub id: String,
    pub device_id: String,
    pub words: String,
}
#[derive(Deserialize)]
struct MailItem {
    cursor: i64,
    envelope: Envelope,
}

#[derive(Default, Serialize, Deserialize)]
struct RetryBackoff {
    failures: u32,
    retry_at: i64,
}

pub struct SyncClient {
    pub store: DeviceStore,
    identity: DeviceIdentity,
    configuration: Option<Configuration>,
    http: Client,
    cancelled: Arc<AtomicBool>,
}
pub fn validate_endpoint(endpoint: &str) -> Result<url::Url> {
    let url = url::Url::parse(endpoint).map_err(|_| SyncError::Invalid)?;
    let loopback = match url.host() {
        Some(url::Host::Ipv4(ip)) => ip.is_loopback(),
        Some(url::Host::Ipv6(ip)) => ip.is_loopback(),
        _ => false,
    };
    if (url.scheme() != "https" && !(url.scheme() == "http" && loopback))
        || url.host().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(SyncError::Invalid);
    }
    Ok(url)
}
pub fn unix_time() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

fn is_terminal_approval_error(error: &SyncError) -> bool {
    matches!(error, SyncError::Relay(400 | 403 | 410 | 422))
}

impl SyncClient {
    pub fn open(mut store: DeviceStore) -> Result<Self> {
        let identity = match store.get("identity")? {
            Some(identity) => identity,
            None => {
                let id = DeviceIdentity::generate();
                store.put("identity", &id)?;
                id
            }
        };
        let pending_join = store.get::<PendingJoin>("pending-join")?;
        let configuration = match store.get::<Configuration>("configuration")? {
            Some(configuration) if configuration.awaiting_approval => pending_join
                .as_ref()
                .map(|pending| Self::configuration_for_pending_join(pending, configuration.enabled))
                .or(Some(configuration)),
            Some(configuration) => Some(configuration),
            None => pending_join
                .as_ref()
                .map(|pending| Self::configuration_for_pending_join(pending, pending.enabled)),
        };
        let http = Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(std::time::Duration::from_secs(5))
            .timeout(std::time::Duration::from_secs(12))
            .build()
            .map_err(|_| SyncError::Network)?;
        Ok(Self {
            store,
            identity,
            configuration,
            http,
            cancelled: Arc::new(AtomicBool::new(false)),
        })
    }
    pub fn set_cancel_signal(&mut self, signal: Arc<AtomicBool>) {
        self.cancelled = signal;
    }
    pub fn device_id(&self) -> &str {
        &self.identity.id
    }
    pub fn sharing_enabled(&self) -> bool {
        self.configuration.as_ref().is_some_and(|cfg| cfg.enabled)
    }
    fn configuration_for_pending_join(pending: &PendingJoin, enabled: bool) -> Configuration {
        Configuration {
            workspace: pending.workspace.clone(),
            relay: pending.relay.clone(),
            owner_key: pending.owner_key.clone(),
            credential: pending.credential.clone(),
            roster: None,
            enabled,
            awaiting_approval: true,
            name: pending.name.clone(),
        }
    }
    fn request<T: DeserializeOwned>(
        &self,
        relay: &str,
        method: Method,
        path: &str,
        credential: Option<&str>,
        body: Option<&serde_json::Value>,
    ) -> Result<T> {
        if self.cancelled.load(Ordering::Acquire) {
            return Err(SyncError::Paused);
        }
        let base = validate_endpoint(relay)?;
        let url = base.join(path).map_err(|_| SyncError::Invalid)?;
        if url.origin() != base.origin() {
            return Err(SyncError::Invalid);
        }
        let mut request = self.http.request(method, url);
        if let Some(credential) = credential {
            request = request.bearer_auth(credential);
        }
        if let Some(body) = body {
            request = request.json(body);
        }
        let response = request.send().map_err(|_| SyncError::Network)?;
        if self.cancelled.load(Ordering::Acquire) {
            return Err(SyncError::Paused);
        }
        let status = response.status();
        if !status.is_success() {
            return Err(SyncError::Relay(status.as_u16()));
        }
        if response
            .content_length()
            .is_some_and(|l| l > (MAX_WIRE_BYTES + 8192) as u64)
        {
            return Err(SyncError::TooLarge);
        }
        let mut bytes = zeroize::Zeroizing::new(Vec::new());
        response
            .take((MAX_WIRE_BYTES + 8193) as u64)
            .read_to_end(&mut bytes)
            .map_err(|_| SyncError::Network)?;
        if bytes.len() > MAX_WIRE_BYTES + 8192 {
            return Err(SyncError::TooLarge);
        }
        Ok(serde_json::from_slice(&bytes)?)
    }
    fn auth_request<T: DeserializeOwned>(
        &self,
        method: Method,
        path: &str,
        body: Option<&serde_json::Value>,
    ) -> Result<T> {
        let cfg = self.configuration.as_ref().ok_or(SyncError::Membership)?;
        self.request(&cfg.relay, method, path, Some(&cfg.credential), body)
    }
    fn persist(&mut self) -> Result<()> {
        self.store.put("configuration", &self.configuration)
    }
    pub fn create_workspace(&mut self, relay: &str, registration: &str, name: &str) -> Result<()> {
        validate_endpoint(relay)?;
        if self.configuration.is_some() || name.is_empty() || name.len() > 128 {
            return Err(SyncError::Invalid);
        }
        let owner = OwnerIdentity::generate();
        let workspace = uuid::Uuid::new_v4().to_string();
        let credential = secret_string();
        let roster =
            SignedRoster::sign(&workspace, 1, vec![self.identity.member("Device")], &owner)?;
        let _:bool=self.request(relay,Method::POST,"/v1/workspaces",Some(registration),Some(&serde_json::json!({"roster":roster,"owner_key":owner.public_key(),"owner_device":self.identity.id,"token_hash":credential_hash(&credential)})))?;
        self.store.put("owner", &owner)?;
        self.configuration = Some(Configuration {
            workspace,
            relay: relay.into(),
            owner_key: owner.public_key(),
            credential,
            roster: Some(roster),
            enabled: true,
            awaiting_approval: false,
            name: name.into(),
        });
        self.persist()
    }
    pub fn join(&mut self, code: &str, name: &str) -> Result<String> {
        if name.is_empty() || name.len() > 128 {
            return Err(SyncError::Invalid);
        }
        let invite = PairInvite::from_code(code, unix_time())?;
        validate_endpoint(&invite.relay)?;
        if self
            .configuration
            .as_ref()
            .is_some_and(|configuration| !configuration.awaiting_approval)
        {
            // A fresh invitation can replace an abandoned, unapproved join, but never an
            // established membership. Local clip history is independent of this state.
            return Err(SyncError::Invalid);
        }
        let existing = self.store.get::<PendingJoin>("pending-join")?;
        let matching = existing.as_ref().is_some_and(|pending| {
            pending.invite_id == invite.id
                && pending.relay == invite.relay
                && pending.workspace == invite.workspace
                && pending.owner_key == invite.owner_key
        });
        let pending = if matching {
            existing.expect("matching pending join exists")
        } else {
            // A new valid invitation is an explicit abandonment of the old unapproved
            // request. The replacement credential and request are durable before POST.
            let enabled = self
                .configuration
                .as_ref()
                .is_none_or(|configuration| configuration.enabled)
                && !self.cancelled.load(Ordering::Acquire);
            let request = JoinRequest::create(&invite, &self.identity, unix_time())?;
            let pending = PendingJoin {
                credential: request.credential()?.to_string(),
                request,
                invite_id: invite.id.clone(),
                workspace: invite.workspace.clone(),
                relay: invite.relay.clone(),
                owner_key: invite.owner_key.clone(),
                name: name.into(),
                enabled,
            };
            self.store.put("pending-join", &pending)?;
            self.configuration = Some(Self::configuration_for_pending_join(&pending, enabled));
            self.persist()?;
            pending
        };
        let _: bool = self.request(
            &invite.relay,
            Method::POST,
            "/v1/joins",
            None,
            Some(&serde_json::to_value(&pending.request)?),
        )?;
        let words = pending.request.words();
        self.store.put("join-words", &words)?;
        Ok(words)
    }
    pub fn set_enabled(&mut self, enabled: bool) -> Result<()> {
        if enabled && self.cancelled.load(Ordering::Acquire) {
            return Err(SyncError::Paused);
        }
        if let Some(cfg) = &mut self.configuration {
            cfg.enabled = enabled;
            self.persist()?;
        }
        if let Some(mut pending) = self.store.get::<PendingJoin>("pending-join")? {
            pending.enabled = enabled;
            self.store.put("pending-join", &pending)?;
        }
        self.store.put("retry-backoff", &RetryBackoff::default())?;
        Ok(())
    }
    /// Clear pairing credentials and rotate the local device identity while preserving clip history.
    /// Pending deliveries are marked cancelled so a later pairing cannot silently resume them.
    pub fn disconnect(&mut self) -> Result<usize> {
        let identity = DeviceIdentity::generate();
        let cancelled = self.store.reset_pairing(&identity)?;
        self.identity = identity;
        self.configuration = None;
        Ok(cancelled)
    }
    pub fn refresh_membership(&mut self) -> Result<()> {
        let roster: SignedRoster = self.auth_request(Method::GET, "/v1/roster", None)?;
        let cfg = self.configuration.as_mut().ok_or(SyncError::Membership)?;
        if roster.workspace != cfg.workspace {
            return Err(SyncError::Membership);
        }
        roster.verify(&cfg.owner_key, cfg.roster.as_ref().map_or(1, |r| r.epoch))?;
        if roster.member(&self.identity.id)?.public_key != self.identity.member("Device").public_key
        {
            return Err(SyncError::Membership);
        }
        if let Some(old) = &cfg.roster
            && old.epoch == roster.epoch
            && serde_json::to_vec(old)? != serde_json::to_vec(&roster)?
        {
            return Err(SyncError::Membership);
        }
        cfg.roster = Some(roster);
        cfg.awaiting_approval = false;
        self.persist()
    }
    pub fn create_invite(&mut self) -> Result<String> {
        self.refresh_membership()?;
        if let Some(pending) = self.store.get::<PendingApproval>("pending-approval")?
            && let Err(error) = self.finish_pending_approval(&pending)
            && !is_terminal_approval_error(&error)
        {
            return Err(error);
        }
        if let Some(invite) = self.store.get::<PairInvite>("invite")?
            && !invite.used
            && invite.validate(unix_time()).is_ok()
        {
            // Reuse the live local invite so creating again cannot orphan requests already
            // encrypted to it at the relay.
            return invite.code();
        }
        let owner: OwnerIdentity = self.store.get("owner")?.ok_or(SyncError::Membership)?;
        let cfg = self.configuration.as_ref().ok_or(SyncError::Membership)?;
        let invite = PairInvite::new(
            &cfg.workspace,
            &cfg.relay,
            &owner,
            &self.identity,
            unix_time(),
        );
        let _: bool = self.auth_request(
            Method::POST,
            "/v1/invites",
            Some(&serde_json::json!({"id":invite.id,"expires":invite.expires})),
        )?;
        self.store.put("invite", &invite)?;
        invite.code()
    }
    pub fn pairing_requests(&self) -> Result<Vec<PairRequestView>> {
        let Some(invite) = self.store.get::<PairInvite>("invite")? else {
            return Ok(vec![]);
        };
        if invite.validate(unix_time()).is_err() {
            return Ok(vec![]);
        }
        let requests: Vec<JoinRequest> = self.auth_request(Method::GET, "/v1/joins", None)?;
        let mut valid = vec![];
        for request in requests {
            if request.open(&invite, &self.identity, unix_time()).is_ok() {
                valid.push(PairRequestView {
                    id: request.id.clone(),
                    device_id: request.device_id.clone(),
                    words: request.words(),
                });
            }
        }
        Ok(valid)
    }
    fn finish_pending_approval(&mut self, pending: &PendingApproval) -> Result<()> {
        let result: Result<bool> = self.auth_request(
            Method::POST,
            "/v1/roster",
            Some(&serde_json::json!({
                "roster": pending.roster,
                "device": pending.device,
                "token_hash": pending.token_hash,
                "invite_id": pending.invite_id,
                "request_id": pending.request_id,
                "request_digest": pending.request_digest
            })),
        );
        if let Err(error) = result {
            if is_terminal_approval_error(&error) {
                self.store.remove_state("pending-approval")?;
            }
            return Err(error);
        }
        if let Some(mut invite) = self.store.get::<PairInvite>("invite")?
            && invite.id == pending.invite_id
        {
            invite.used = true;
            self.store.put("invite", &invite)?;
        }
        self.refresh_membership()?;
        self.store.remove_state("pending-approval")?;
        Ok(())
    }
    pub fn approve(&mut self, id: &str, words: &str) -> Result<()> {
        if let Some(pending) = self.store.get::<PendingApproval>("pending-approval")? {
            if pending.request_id == id && pending.words == words {
                return self.finish_pending_approval(&pending);
            }
            // Resolve an ambiguous prior response by replaying its exact signed transaction.
            // A definite terminal rejection releases the slot so this explicit new approval
            // can be built against the current roster and invitation.
            if let Err(error) = self.finish_pending_approval(&pending)
                && !is_terminal_approval_error(&error)
            {
                return Err(error);
            }
        }
        let pending = {
            self.refresh_membership()?;
            let invite: PairInvite = self.store.get("invite")?.ok_or(SyncError::Invitation)?;
            let requests: Vec<JoinRequest> = self.auth_request(Method::GET, "/v1/joins", None)?;
            let request = requests
                .iter()
                .find(|r| r.id == id)
                .ok_or(SyncError::Invitation)?;
            let approved = request.open(&invite, &self.identity, unix_time())?;
            if approved.words() != words {
                return Err(SyncError::Authentication);
            }
            let owner: OwnerIdentity = self.store.get("owner")?.ok_or(SyncError::Membership)?;
            let cfg = self.configuration.as_ref().ok_or(SyncError::Membership)?;
            let old = cfg.roster.as_ref().ok_or(SyncError::Membership)?;
            let mut members = old.members.clone();
            members.push(approved.member.clone());
            let roster = SignedRoster::sign(&cfg.workspace, old.epoch + 1, members, &owner)?;
            let approved_words = approved.words();
            let pending = PendingApproval {
                invite_id: invite.id.clone(),
                request_id: request.id.clone(),
                request_digest: approved.request_digest,
                words: approved_words,
                device: approved.member.id,
                token_hash: approved.credential_hash,
                roster,
            };
            // Persist the exact signed transaction so a lost HTTP response can be replayed.
            self.store.put("pending-approval", &pending)?;
            pending
        };
        self.finish_pending_approval(&pending)
    }
    pub fn remove_device(&mut self, id: &str) -> Result<()> {
        if id == self.identity.id {
            return Err(SyncError::Membership);
        }
        self.refresh_membership()?;
        let owner: OwnerIdentity = self.store.get("owner")?.ok_or(SyncError::Membership)?;
        let cfg = self.configuration.as_ref().ok_or(SyncError::Membership)?;
        let old = cfg.roster.as_ref().ok_or(SyncError::Membership)?;
        old.member(id)?;
        let roster = SignedRoster::sign(
            &cfg.workspace,
            old.epoch + 1,
            old.members.iter().filter(|m| m.id != id).cloned().collect(),
            &owner,
        )?;
        let _: bool = self.auth_request(
            Method::POST,
            "/v1/roster",
            Some(&serde_json::json!({"roster":roster})),
        )?;
        self.refresh_membership()
    }
    pub fn capture(
        &mut self,
        mut clip: PortableClip,
        event_id: Option<&str>,
    ) -> Result<Option<String>> {
        if let Some(id) = event_id
            && self.store.contains(id)?
        {
            return Ok(Some(id.into()));
        }
        clip.validate()?;
        if let Some(cfg) = &self.configuration {
            clip.source_device = Some(cfg.name.clone());
        }
        let mut event = ClipEvent::new(self.identity.id.clone(), self.store.next_sequence()?, clip);
        if let Some(id) = event_id {
            event.id = id.into();
        }
        let recipients: Vec<String> = self
            .configuration
            .as_ref()
            .filter(|c| c.enabled)
            .and_then(|c| c.roster.as_ref())
            .map_or(vec![], |r| {
                r.members
                    .iter()
                    .filter(|m| m.id != self.identity.id)
                    .map(|m| m.id.clone())
                    .collect()
            });
        if recipients.is_empty() {
            self.store.capture_local(&event)?;
        } else {
            match self.store.capture_with_targets(&event, &recipients) {
                Ok(_) => {}
                Err(SyncError::Capacity) => {
                    self.store.defer_capture(&event, &recipients)?;
                }
                Err(error) => return Err(error),
            }
        }
        Ok(Some(event.id))
    }
    pub fn status(&self) -> Result<ClientStatus> {
        let retry = self
            .store
            .get::<RetryBackoff>("retry-backoff")?
            .unwrap_or_default();
        let enabled = self.configuration.as_ref().is_some_and(|cfg| cfg.enabled);
        Ok(ClientStatus {
            state: if !enabled {
                "Sharing off"
            } else if (1..=60).contains(&retry.retry_at.saturating_sub(unix_time())) {
                "Retry scheduled; local history retained"
            } else {
                "Ready"
            }
            .into(),
            device_id: self.identity.id.clone(),
            is_owner: self.store.get::<OwnerIdentity>("owner")?.is_some(),
            enabled,
            pending: self.store.pending_count()?,
            rejected: self.store.get::<usize>("rejected")?.unwrap_or(0),
            members: self
                .configuration
                .as_ref()
                .and_then(|c| c.roster.as_ref())
                .map_or(vec![], |r| r.members.clone()),
            requests: vec![],
        })
    }
    pub fn tick(&mut self, auto_apply: bool) -> Result<ClientStatus> {
        // Keep retry state encrypted and durable: the Mac C bridge reopens the
        // client between calls, and a process restart must not hammer the relay.
        let retry = self
            .store
            .get::<RetryBackoff>("retry-backoff")?
            .unwrap_or_default();
        let remaining = retry.retry_at.saturating_sub(unix_time());
        if self.configuration.as_ref().is_some_and(|cfg| cfg.enabled)
            && !self.cancelled.load(Ordering::Acquire)
            && (1..=60).contains(&remaining)
        {
            let mut status = self.status()?;
            status.state = "Retry scheduled; local history retained".into();
            return Ok(status);
        }
        // A wall-clock change cannot defer a retry indefinitely: deadlines more
        // than the maximum interval away are treated as due.
        let result = self.tick_ready(auto_apply);
        if matches!(
            &result,
            Err(SyncError::Network | SyncError::Relay(429 | 500..=599))
        ) {
            let failures = retry.failures.saturating_add(1).min(5);
            let delay = (5_i64 << (failures - 1)).min(60);
            self.store.put(
                "retry-backoff",
                &RetryBackoff {
                    failures,
                    retry_at: unix_time().saturating_add(delay),
                },
            )?;
        } else if result.is_ok() && (retry.failures > 0 || retry.retry_at != 0) {
            self.store.put("retry-backoff", &RetryBackoff::default())?;
        }
        result
    }

    fn tick_ready(&mut self, auto_apply: bool) -> Result<ClientStatus> {
        let mut status = self.status()?;
        if !status.enabled {
            return Ok(status);
        }
        if let Err(error) = self.refresh_membership() {
            if matches!(error, SyncError::Relay(401))
                && self
                    .configuration
                    .as_ref()
                    .is_some_and(|c| c.awaiting_approval)
            {
                status.state = "Waiting for owner approval".into();
                return Ok(status);
            }
            return Err(error);
        }
        // Snapshot configuration only after refresh. Every network cycle binds current membership.
        let cfg = self.configuration.clone().ok_or(SyncError::Membership)?;
        let roster = cfg.roster.as_ref().ok_or(SyncError::Membership)?;
        self.store.promote_deferred()?;
        for event in self.store.pending()?.into_iter().take(16) {
            for recipient_id in self.store.targets(&event.id)? {
                let Ok(recipient) = roster.member(&recipient_id) else {
                    self.store
                        .target_done(&event.id, &recipient_id, "revoked")?;
                    continue;
                };
                let state: String = self.auth_request(
                    Method::GET,
                    &format!("/v1/delivery/{}/{}", event.id, recipient_id),
                    None,
                )?;
                match state.as_str() {
                    "missing" => {
                        if self
                            .store
                            .target_attempted_at(&event.id, &recipient_id)?
                            .is_some_and(|first| {
                                unix_time().saturating_sub(first) > DELIVERY_MAX_RETRY_AGE
                            })
                        {
                            self.store
                                .target_done(&event.id, &recipient_id, "expired")?;
                            self.store.put("delivery-failure", &"expired")?;
                            continue;
                        }
                        self.store
                            .mark_target_attempted(&event.id, &recipient_id, unix_time())?;
                        let envelope = seal_event(
                            &cfg.workspace,
                            roster.epoch,
                            &self.identity,
                            recipient,
                            &event,
                        )?;
                        let _: i64 = self.auth_request(
                            Method::POST,
                            "/v1/mailbox",
                            Some(&serde_json::to_value(envelope)?),
                        )?;
                    }
                    "delivered" => self
                        .store
                        .target_done(&event.id, &recipient_id, "delivered")?,
                    "expired" | "revoked" | "rejected" => {
                        self.store.put("delivery-failure", &state)?;
                        self.store.target_done(&event.id, &recipient_id, &state)?;
                    }
                    "pending" => {}
                    _ => return Err(SyncError::Invalid),
                }
            }
        }
        for cursor in self.store.acknowledgements()? {
            let endpoint = if self.store.receipt_rejected(cursor)? {
                "reject"
            } else {
                "ack"
            };
            let _: bool =
                self.auth_request(Method::POST, &format!("/v1/{endpoint}/{cursor}"), None)?;
            self.store.mark_acknowledged(cursor)?;
        }
        let mailbox: Vec<MailItem> = self.auth_request(Method::GET, "/v1/mailbox", None)?;
        for item in mailbox {
            let result = match classify_incoming(roster, &self.identity, &item.envelope) {
                Incoming::Event(event) => Ok(*event),
                Incoming::Deferred => {
                    status.state = "Waiting for a newer membership record".into();
                    return Ok(status);
                }
                Incoming::Rejected => Err(SyncError::Authentication),
            };
            match result {
                Ok(event) => {
                    if let Err(error) = self.store.receive(&event, item.cursor) {
                        if matches!(error, SyncError::Authentication | SyncError::Invalid) {
                            self.store.reject(item.cursor)?;
                            continue;
                        } else {
                            return Err(error);
                        }
                    }
                    if auto_apply {
                        self.store.mark_applied(&event.id)?;
                    }
                }
                Err(_) => {
                    self.store.reject(item.cursor)?;
                    let rejected = self
                        .store
                        .get::<usize>("rejected")?
                        .unwrap_or(0)
                        .saturating_add(1);
                    self.store.put("rejected", &rejected)?;
                }
            }
        }
        status = self.status()?;
        status.requests = self.pairing_requests()?;
        status.state = if status.pending > 0 {
            "Pending delivery"
        } else {
            "Up to date"
        }
        .into();
        if let Some(failure) = self.store.get::<String>("delivery-failure")? {
            status.state = format!("Delivery {failure}; local history retained");
        }
        if status.rejected > 0 {
            status.state = format!(
                "{}; {} incoming messages rejected",
                status.state, status.rejected
            );
        }
        Ok(status)
    }
}

pub enum Incoming {
    Event(Box<ClipEvent>),
    Deferred,
    Rejected,
}
pub fn classify_incoming(
    roster: &SignedRoster,
    identity: &DeviceIdentity,
    envelope: &Envelope,
) -> Incoming {
    if envelope.header.epoch > roster.epoch {
        return Incoming::Deferred;
    }
    match roster
        .member(&envelope.header.sender)
        .and_then(|sender| open_event(&roster.workspace, identity, sender, envelope))
    {
        Ok(event) => Incoming::Event(Box::new(event)),
        Err(_) => Incoming::Rejected,
    }
}
