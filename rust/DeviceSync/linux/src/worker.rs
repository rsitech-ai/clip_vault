use clipvault_linux::policy::{CaptureGate, CapturePolicy};
use clipvault_sync_core::*;
use std::path::PathBuf;
use std::sync::{
    Arc,
    atomic::AtomicBool,
    mpsc::{self, Receiver, Sender},
};

const PENDING_FILE_COMMITS_KEY: &str = "linux-pending-file-commits";

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
struct PendingFileCommit {
    file_id: String,
    event_id: String,
    // Older retry markers only recorded the file/event pair. New markers keep
    // the attachment descriptor until its local history event is durable.
    #[serde(default)]
    clip: Option<PortableClip>,
    #[serde(default)]
    retry_at: i64,
}

pub enum Work {
    Capture(PortableClip, bool, u64),
    Copied(PortableClip),
    CaptureConsent(bool),
    Search(String),
    More,
    Create(String, String, String),
    Join(String, String),
    Invite,
    Approve(String, String),
    Remove(String),
    Enabled(bool),
    RetryOverflow,
    Delete(String),
    StageFiles(Vec<PathBuf>, Option<u64>),
    SaveFile(String, PathBuf),
    FileSelectionError(String),
    Disconnect,
}
#[derive(Clone)]
pub struct Snapshot {
    pub history: Arc<Vec<ClipEvent>>,
    pub status: ClientStatus,
    pub message: Option<String>,
    pub pairing: Option<String>,
    pub file_transfers: Vec<FileTransferStatus>,
}
pub fn start(
    capturing: Arc<CaptureGate>,
    cancelled: Arc<AtomicBool>,
) -> (Sender<Work>, Receiver<Snapshot>) {
    let (tx, rx) = mpsc::channel();
    let (result_tx, result_rx) = mpsc::channel();
    std::thread::spawn(move || {
        let path = glib::user_data_dir().join("clipvault");
        let mut client = loop {
            match platform_key("com.andrzej.ClipVault.linux")
                .and_then(|key| DeviceStore::open(&path.join("clips.sqlite"), key))
                .and_then(SyncClient::open)
            {
                Ok(client) => break client,
                Err(error) => {
                    let _ = result_tx.send(Snapshot {
                        history: Arc::new(vec![]),
                        status: ClientStatus::default(),
                        message: Some(error.to_string()),
                        pairing: None,
                        file_transfers: vec![],
                    });
                    if matches!(
                        rx.recv_timeout(std::time::Duration::from_secs(5)),
                        Err(mpsc::RecvTimeoutError::Disconnected)
                    ) {
                        return;
                    }
                }
            }
        };
        client.set_cancel_signal(cancelled.clone());
        let mut policy = CapturePolicy::default();
        policy.enabled = client
            .store
            .get::<bool>("capture-consent")
            .ok()
            .flatten()
            .unwrap_or(false);
        capturing.restore(policy.enabled);
        let (mut pending_file_commits, pending_file_commit_error) = match client.store.get::<Vec<
            PendingFileCommit,
        >>(
            PENDING_FILE_COMMITS_KEY,
        ) {
            Ok(commits) => (commits.unwrap_or_default(), None),
            Err(error) => (vec![], Some(error.to_string())),
        };
        let mut last_tick = std::time::Instant::now() - std::time::Duration::from_secs(6);
        let mut request_cache = vec![];
        let mut message = pending_file_commit_error;
        let mut pairing = None;
        let mut query = String::new();
        let mut display_limit = 100;
        let mut previous_signature = None;
        let mut history = Arc::new(vec![]);
        loop {
            let command = rx.recv_timeout(std::time::Duration::from_secs(1));
            let is_stage_files = matches!(&command, Ok(Work::StageFiles(_, _)));
            let is_save_file = matches!(&command, Ok(Work::SaveFile(_, _)));
            let rejected_file_count = matches!(
                &command,
                Ok(Work::StageFiles(paths, _)) if paths.len() > 10
            );
            let foreground_message = match &command {
                Ok(Work::StageFiles(paths, _)) if !paths.is_empty() => Some(format!(
                    "Adding {} file{}…",
                    paths.len(),
                    if paths.len() == 1 { "" } else { "s" }
                )),
                Ok(Work::SaveFile(_, _)) => Some("Saving verified file…".to_string()),
                _ => None,
            };
            if let Some(message) = foreground_message {
                let _ = result_tx.send(Snapshot {
                    history: history.clone(),
                    status: client.status().unwrap_or_default(),
                    message: Some(message),
                    pairing: None,
                    file_transfers: client.file_transfers().unwrap_or_default(),
                });
            }
            // The UI closes the network gate before queuing its persisted
            // preference. A capture racing that queued command must stay local.
            if cancelled.load(std::sync::atomic::Ordering::Acquire)
                && client.sharing_enabled()
                && let Err(error) = client.set_enabled(false)
            {
                message = Some(error.to_string());
            }
            let admin_paused =
                cancelled.load(std::sync::atomic::Ordering::Acquire) || !client.sharing_enabled();
            let result: Result<()> = match command {
                Ok(Work::Capture(clip, marked, capture_token)) => {
                    accept_capture(&mut policy, &capturing, &clip, marked, capture_token)
                        .and_then(|accept| {
                        if accept {
                            client.capture(clip, None).map(|_| ())
                        } else {
                            Ok(())
                        }
                    })
                }
                Ok(Work::Copied(clip)) => policy.copied(&clip),
                Ok(Work::Search(text)) => {
                    query = text;
                    display_limit = 100;
                    previous_signature = None;
                    Ok(())
                }
                Ok(Work::More) => {
                    display_limit += 100;
                    previous_signature = None;
                    Ok(())
                }
                Ok(Work::CaptureConsent(enabled)) => {
                    let effective = enabled && capturing.enabled();
                    policy.enabled = effective;
                    client.store.put("capture-consent", &effective)
                }
                Ok(Work::Disconnect) => {
                    clear_pending_file_commits(&mut client.store, &mut pending_file_commits)
                        .and_then(|()| client.disconnect())
                        .map(|count| {
                            request_cache.clear();
                            pairing = None;
                            message = Some(format!("Disconnected locally; {count} pending recipient deliveries cancelled. History kept. Remove this device on the owner to revoke its old membership."));
                        })
                }
                Ok(Work::Create(relay, registration, name)) => {
                    client.create_workspace(&relay, &registration, &name)
                }
                Ok(Work::Join(code, name)) => client.join(&code, &name).map(|words| {
                    pairing = Some(format!(
                        "Compare this code on the owner device, then approve there:\n{words}"
                    ));
                }),
                Ok(Work::Invite | Work::Approve(_, _) | Work::Remove(_)) if admin_paused => {
                    Err(SyncError::Paused)
                }
                Ok(Work::Invite) => client.create_invite().map(|code| {
                    pairing = Some(code);
                }),
                Ok(Work::Approve(id, words)) => client.approve(&id, &words),
                Ok(Work::Remove(id)) => client.remove_device(&id),
                Ok(Work::Enabled(enabled)) => client
                    .set_enabled(enabled && !cancelled.load(std::sync::atomic::Ordering::Acquire)),
                Ok(Work::RetryOverflow) if admin_paused => Err(SyncError::Paused),
                Ok(Work::RetryOverflow) => client.retry_overflow().map(|count| {
                    message = Some(format!(
                        "Queued {count} local share{} for sending.",
                        if count == 1 { "" } else { "s" }
                    ));
                }),
                Ok(Work::Delete(id)) => delete_local_clip(
                    &mut client.store,
                    &id,
                    &mut pending_file_commits,
                ),
                Ok(Work::FileSelectionError(text)) => {
                    message = Some(text);
                    Ok(())
                }
                Ok(Work::StageFiles(paths, capture_token)) => {
                    let mut error = None;
                    if paths.len() > 10 {
                        message = Some("Choose up to 10 files at a time.".into());
                        Ok(())
                    } else {
                      for path in paths {
                        let capture_still_valid = || capture_token.is_none_or(|token| capturing.permits(token));
                        match client.stage_file(&path, || !capture_still_valid()) {
                            Ok(descriptor) => {
                                if !capture_still_valid() {
                                    let _ = client.store.discard_file(&descriptor.id);
                                    break;
                                }
                                let event_id = uuid::Uuid::new_v4().to_string();
                                let mut clip = PortableClip::text(&descriptor.filename, descriptor.created_at);
                                clip.kind = "attachment".into();
                                clip.display_text = descriptor.filename.clone();
                                clip.metadata.insert("file_id".into(), descriptor.id.clone());
                                clip.metadata.insert("file_origin".into(), descriptor.origin.clone());
                                clip.metadata.insert("file_size".into(), descriptor.size.to_string());
                                clip.metadata.insert("file_sha256".into(), descriptor.sha256.clone());
                                if !capture_still_valid() {
                                    let _ = client.store.discard_file(&descriptor.id);
                                    break;
                                }
                                let should_queue_for_sharing = should_queue_attachment(
                                    client.sharing_enabled(),
                                    cancelled.load(std::sync::atomic::Ordering::Acquire),
                                    capture_still_valid(),
                                    client
                                        .status()
                                        .is_ok_and(|status| status.members.len() > 1),
                                );
                                if should_queue_for_sharing {
                                    let pending = PendingFileCommit {
                                        file_id: descriptor.id.clone(),
                                        event_id: event_id.clone(),
                                        clip: Some(clip.clone()),
                                        retry_at: 0,
                                    };
                                    pending_file_commits.push(pending);
                                    if let Err(e) =
                                        persist_pending_file_commits(&mut client.store, &pending_file_commits)
                                    {
                                        pending_file_commits.pop();
                                        // Preserve the staged bytes. The user selected
                                        // this file, and dropping it would turn a
                                        // persistence error into silent data loss.
                                        error = Some(e);
                                        continue;
                                    }
                                }
                                if !capture_still_valid() {
                                    if let Err(e) = cancel_pending_file_commit(
                                        &mut client.store,
                                        &mut pending_file_commits,
                                        &descriptor.id,
                                        &event_id,
                                    ) {
                                        error = Some(e);
                                    } else {
                                        let _ = client.store.discard_file(&descriptor.id);
                                    }
                                    break;
                                }
                                match client.capture(clip, Some(&event_id)) {
                                    Ok(_) => {
                                        if !capture_still_valid() {
                                            if let Err(e) = cancel_pending_file_commit(
                                                &mut client.store,
                                                &mut pending_file_commits,
                                                &descriptor.id,
                                                &event_id,
                                            ) {
                                                error = Some(e);
                                            } else {
                                                let _ = client.store.delete_local(&event_id);
                                                let _ = client.store.discard_file(&descriptor.id);
                                            }
                                        } else if should_queue_for_sharing {
                                            if let Some(pending) = pending_file_commits
                                                .iter_mut()
                                                .find(|pending| pending.event_id == event_id)
                                            {
                                                pending.clip = None;
                                            }
                                            if let Err(e) = persist_pending_file_commits(
                                                &mut client.store,
                                                &pending_file_commits,
                                            ) {
                                                error = Some(e);
                                            }
                                        }
                                    }
                                    Err(e) => {
                                        // The durable intent owns this staged file now.
                                        // Leave it available for idempotent replay.
                                        error = Some(e);
                                    }
                                }
                            }
                            Err(e) => { error = Some(e); }
                        }
                        if cancelled.load(std::sync::atomic::Ordering::Acquire) {
                            let _ = client.set_enabled(false);
                        }
                        if !capture_still_valid() { break; }
                      }
                      error.map_or(Ok(()), Err)
                    }
                }
                Ok(Work::SaveFile(id, path)) => client.store.save_file(&id, &path, || false),
                Err(mpsc::RecvTimeoutError::Timeout) => Ok(()),
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            };
            if result.is_ok() && !rejected_file_count {
                if is_stage_files {
                    message = Some(
                        if client.sharing_enabled()
                            && client.status().is_ok_and(|status| status.members.len() > 1)
                        {
                            "File added. Sending encrypted copy to paired devices.".into()
                        } else {
                            "File added on this device. Pair another device and turn on sharing before adding it to send a copy.".into()
                        },
                    );
                }
                if is_save_file {
                    message = Some("File saved.".into());
                }
            }
            if let Err(error) = result {
                message = Some(error.to_string());
            }
            let tick_due = last_tick.elapsed() >= std::time::Duration::from_secs(5);
            let (mut status, tick_succeeded) = if tick_due {
                last_tick = std::time::Instant::now();
                match client.tick(true) {
                    Ok(status) => {
                        request_cache = status.requests.clone();
                        (status, true)
                    }
                    Err(error) => {
                        message = Some(error.to_string());
                        (client.status().unwrap_or_default(), false)
                    }
                }
            } else {
                (client.status().unwrap_or_default(), false)
            };
            if tick_due
                && tick_succeeded
                && client.sharing_enabled()
                && !cancelled.load(std::sync::atomic::Ordering::Acquire)
                && !status.state.contains("Retry scheduled")
                && !pending_file_commits.is_empty()
                && let Err(error) =
                    retry_pending_file_commits(&mut client, &mut pending_file_commits, &cancelled)
            {
                message = Some(error.to_string());
            }
            if status.requests.is_empty() {
                status.requests = request_cache.clone();
            }
            match client.store.history_signature() {
                Ok(signature) => {
                    if previous_signature != Some(signature) {
                        match client.store.matching_history(display_limit, |event| {
                            query.is_empty()
                                || search_index_core::lexical_score(
                                    &query,
                                    &format!("{}\n{}", event.clip.display_text, event.clip.text),
                                ) > 0.
                        }) {
                            Ok(events) => {
                                history = Arc::new(events);
                                previous_signature = Some(signature);
                            }
                            Err(error) => {
                                message = Some(error.to_string());
                            }
                        }
                    }
                }
                Err(error) => {
                    message = Some(error.to_string());
                }
            }
            let file_transfers = client.file_transfers().unwrap_or_else(|error| {
                message = Some(error.to_string());
                vec![]
            });
            if result_tx
                .send(Snapshot {
                    history: history.clone(),
                    status,
                    message: message.take(),
                    pairing: pairing.take(),
                    file_transfers,
                })
                .is_err()
            {
                break;
            }
        }
    });
    (tx, result_rx)
}

fn persist_pending_file_commits(
    store: &mut DeviceStore,
    commits: &[PendingFileCommit],
) -> Result<()> {
    store.put(PENDING_FILE_COMMITS_KEY, &commits)
}

fn clear_pending_file_commits(
    store: &mut DeviceStore,
    commits: &mut Vec<PendingFileCommit>,
) -> Result<()> {
    persist_pending_file_commits(store, &[])?;
    commits.clear();
    Ok(())
}

fn delete_local_clip(
    store: &mut DeviceStore,
    event_id: &str,
    commits: &mut Vec<PendingFileCommit>,
) -> Result<()> {
    // Resolve attachment metadata from authenticated local history instead of
    // trusting identifiers supplied by a UI event or IPC caller.
    let file_id = store
        .event(event_id)?
        .and_then(|event| event.clip.metadata.get("file_id").cloned());
    if let Some(file_id) = file_id {
        // Tombstone the event even when an uncommitted staged transfer has no
        // event_id in file_transfers yet. Keep the event and chunks atomic.
        store.delete_file_with_event(&file_id, event_id)?;
    } else {
        store.delete_local(event_id)?;
    }
    remove_pending_file_commit(store, commits, event_id)
}

fn cancel_pending_file_commit(
    store: &mut DeviceStore,
    commits: &mut Vec<PendingFileCommit>,
    file_id: &str,
    event_id: &str,
) -> Result<()> {
    cancel_pending_file_commit_with_persist(
        store,
        commits,
        file_id,
        event_id,
        persist_pending_file_commits,
    )
}

fn cancel_pending_file_commit_with_persist<F>(
    store: &mut DeviceStore,
    commits: &mut Vec<PendingFileCommit>,
    file_id: &str,
    event_id: &str,
    persist: F,
) -> Result<()>
where
    F: FnOnce(&mut DeviceStore, &[PendingFileCommit]) -> Result<()>,
{
    // The store transaction tombstones a not-yet-captured event together with
    // its staged transfer. If marker persistence later fails, replay sees the
    // tombstone and cannot resurrect the attachment.
    store.delete_file_with_event(file_id, event_id)?;
    remove_pending_file_commit_with(store, commits, event_id, persist)
}

fn remove_pending_file_commit(
    store: &mut DeviceStore,
    commits: &mut Vec<PendingFileCommit>,
    event_id: &str,
) -> Result<()> {
    remove_pending_file_commit_with(store, commits, event_id, persist_pending_file_commits)
}

fn remove_pending_file_commit_with<F>(
    store: &mut DeviceStore,
    commits: &mut Vec<PendingFileCommit>,
    event_id: &str,
    persist: F,
) -> Result<()>
where
    F: FnOnce(&mut DeviceStore, &[PendingFileCommit]) -> Result<()>,
{
    let mut remaining = commits.clone();
    let old_len = remaining.len();
    remaining.retain(|pending| pending.event_id != event_id);
    if remaining.len() != old_len {
        persist(store, &remaining)?;
        *commits = remaining;
    }
    Ok(())
}

fn replay_pending_file_capture(client: &mut SyncClient, pending: &PendingFileCommit) -> Result<()> {
    if let Some(clip) = pending.clip.clone() {
        client.capture(clip, Some(&pending.event_id))?;
    }
    Ok(())
}

fn clear_missing_pending_file_commit(
    store: &mut DeviceStore,
    commits: &mut Vec<PendingFileCommit>,
    pending: &PendingFileCommit,
) -> Result<()> {
    store.delete_file_with_event(&pending.file_id, &pending.event_id)?;
    remove_pending_file_commit(store, commits, &pending.event_id)
}

fn retry_pending_file_commits(
    client: &mut SyncClient,
    commits: &mut Vec<PendingFileCommit>,
    cancelled: &AtomicBool,
) -> Result<()> {
    let now = unix_time();
    let Some(index) = due_pending_commit_index(commits, now) else {
        return Ok(());
    };
    if cancelled.load(std::sync::atomic::Ordering::Acquire) || !client.sharing_enabled() {
        return Ok(());
    }

    let pending = commits[index].clone();
    if cancelled.load(std::sync::atomic::Ordering::Acquire) || !client.sharing_enabled() {
        return Ok(());
    }
    if let Err(error) = replay_pending_file_capture(client, &pending) {
        if matches!(error, SyncError::Attachment) {
            // Cancellation may have removed staged bytes before the process
            // crashed while clearing its retry marker.
            return clear_missing_pending_file_commit(&mut client.store, commits, &pending);
        }
        let mut updated = commits.clone();
        updated[index].retry_at = now.saturating_add(30);
        persist_pending_file_commits(&mut client.store, &updated)?;
        *commits = updated;
        return Err(error);
    }
    if commits[index].clip.is_some() {
        let mut updated = commits.clone();
        updated[index].clip = None;
        persist_pending_file_commits(&mut client.store, &updated)?;
        *commits = updated;
    }
    match client.commit_file(&pending.file_id, &pending.event_id) {
        Ok(_) => remove_pending_file_commit(&mut client.store, commits, &pending.event_id),
        Err(SyncError::Attachment) => {
            // The transfer was deleted or expired while its retry marker
            // survived. Tombstone the event before clearing stale bookkeeping.
            clear_missing_pending_file_commit(&mut client.store, commits, &pending)
        }
        Err(error) => {
            let delay = if matches!(error, SyncError::Unsupported | SyncError::Paused) {
                5
            } else {
                30
            };
            let mut updated = commits.clone();
            updated[index].retry_at = now.saturating_add(delay);
            persist_pending_file_commits(&mut client.store, &updated)?;
            *commits = updated;
            if matches!(error, SyncError::Unsupported) {
                Ok(())
            } else {
                Err(error)
            }
        }
    }
}

fn due_pending_commit_index(commits: &[PendingFileCommit], now: i64) -> Option<usize> {
    commits
        .iter()
        .enumerate()
        .filter(|(_, entry)| entry.retry_at <= now)
        .min_by_key(|(_, entry)| entry.retry_at)
        .map(|(index, _)| index)
}

fn accept_capture(
    policy: &mut CapturePolicy,
    capturing: &CaptureGate,
    clip: &PortableClip,
    marked: bool,
    token: u64,
) -> Result<bool> {
    policy.accept(clip, marked || !capturing.permits(token))
}

fn should_queue_attachment(
    sharing_enabled: bool,
    sharing_paused: bool,
    capture_token_valid: bool,
    has_paired_peer: bool,
) -> bool {
    sharing_enabled && !sharing_paused && capture_token_valid && has_paired_peer
}

#[cfg(test)]
mod tests {
    use super::{
        PENDING_FILE_COMMITS_KEY, PendingFileCommit, accept_capture,
        cancel_pending_file_commit_with_persist, clear_missing_pending_file_commit,
        clear_pending_file_commits, delete_local_clip, due_pending_commit_index,
        persist_pending_file_commits, replay_pending_file_capture, should_queue_attachment,
    };
    use clipvault_linux::policy::{CaptureGate, CapturePolicy};
    use clipvault_sync_core::{
        ClipEvent, DeviceStore, PortableClip, SyncClient, SyncError, unix_time,
    };

    #[test]
    fn queued_capture_is_rejected_after_capture_is_toggled_off_and_on() {
        let gate = CaptureGate::default();
        gate.set(true);
        let queued_token = gate.read_token();
        gate.set(false);
        gate.set(true);

        let mut policy = CapturePolicy::default();
        policy.enabled = true;
        let clip = PortableClip::text("selection read before pause", unix_time());
        assert!(!accept_capture(&mut policy, &gate, &clip, false, queued_token).unwrap());
        assert!(accept_capture(&mut policy, &gate, &clip, false, gate.read_token()).unwrap());
    }

    #[test]
    fn pending_file_commit_survives_reopening_the_encrypted_store() {
        let path = std::env::temp_dir().join(format!(
            "clipvault-linux-pending-commits-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&path).unwrap();
        let database = path.join("clips.sqlite");
        let queued = vec![PendingFileCommit {
            file_id: uuid::Uuid::new_v4().to_string(),
            event_id: uuid::Uuid::new_v4().to_string(),
            clip: None,
            retry_at: 0,
        }];
        {
            let mut store = DeviceStore::open(&database, [17; 32]).unwrap();
            persist_pending_file_commits(&mut store, &queued).unwrap();
        }
        let reopened = DeviceStore::open(&database, [17; 32]).unwrap();
        assert_eq!(
            reopened
                .get::<Vec<PendingFileCommit>>(PENDING_FILE_COMMITS_KEY)
                .unwrap(),
            Some(queued)
        );
        drop(reopened);
        std::fs::remove_dir_all(path).unwrap();
    }

    #[test]
    fn old_pending_marker_without_clip_remains_readable() {
        let old_marker = serde_json::json!({
            "file_id": uuid::Uuid::new_v4().to_string(),
            "event_id": uuid::Uuid::new_v4().to_string(),
            "retry_at": 42
        });
        let decoded: PendingFileCommit = serde_json::from_value(old_marker).unwrap();
        assert!(decoded.clip.is_none());
        assert_eq!(decoded.retry_at, 42);
    }

    #[test]
    fn durable_capture_intent_replays_after_reopen_with_stable_event_id() {
        let path = std::env::temp_dir().join(format!(
            "clipvault-linux-capture-intent-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&path).unwrap();
        let database = path.join("clips.sqlite");
        let source = path.join("source.txt");
        std::fs::write(&source, b"capture intent survives restart").unwrap();

        let pending = {
            let store = DeviceStore::open(&database, [31; 32]).unwrap();
            let mut client = SyncClient::open(store).unwrap();
            let descriptor = client.stage_file(&source, || false).unwrap();
            let mut clip = PortableClip::text(&descriptor.filename, descriptor.created_at);
            clip.kind = "attachment".into();
            clip.display_text = descriptor.filename.clone();
            clip.metadata
                .insert("file_id".into(), descriptor.id.clone());
            clip.metadata
                .insert("file_origin".into(), descriptor.origin.clone());
            clip.metadata
                .insert("file_size".into(), descriptor.size.to_string());
            clip.metadata
                .insert("file_sha256".into(), descriptor.sha256.clone());
            let pending = PendingFileCommit {
                file_id: descriptor.id,
                event_id: uuid::Uuid::new_v4().to_string(),
                clip: Some(clip),
                retry_at: 0,
            };
            persist_pending_file_commits(&mut client.store, std::slice::from_ref(&pending))
                .unwrap();
            pending
        };

        // Reopening here simulates a stop after the write-ahead intent and
        // staged chunks were durable, before the history event was captured.
        let store = DeviceStore::open(&database, [31; 32]).unwrap();
        let mut client = SyncClient::open(store).unwrap();
        let marker: Vec<PendingFileCommit> =
            client.store.get(PENDING_FILE_COMMITS_KEY).unwrap().unwrap();
        assert_eq!(marker, vec![pending.clone()]);
        replay_pending_file_capture(&mut client, &marker[0]).unwrap();
        replay_pending_file_capture(&mut client, &marker[0]).unwrap();

        let event = client.store.event(&pending.event_id).unwrap().unwrap();
        assert_eq!(event.id, pending.event_id);
        assert_eq!(event.clip.metadata.get("file_id"), Some(&pending.file_id));
        assert_eq!(client.store.history().unwrap().len(), 1);
        drop(client);
        std::fs::remove_dir_all(path).unwrap();
    }

    #[test]
    fn failed_cancel_marker_write_cannot_replay_staged_file_after_reopen() {
        let path = std::env::temp_dir().join(format!(
            "clipvault-linux-cancel-intent-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&path).unwrap();
        let database = path.join("clips.sqlite");
        let source = path.join("source.txt");
        std::fs::write(&source, b"cancel intent remains fail closed").unwrap();

        let pending = {
            let store = DeviceStore::open(&database, [37; 32]).unwrap();
            let mut client = SyncClient::open(store).unwrap();
            let descriptor = client.stage_file(&source, || false).unwrap();
            let mut clip = PortableClip::text(&descriptor.filename, descriptor.created_at);
            clip.kind = "attachment".into();
            clip.display_text = descriptor.filename.clone();
            clip.metadata
                .insert("file_id".into(), descriptor.id.clone());
            clip.metadata
                .insert("file_origin".into(), descriptor.origin.clone());
            clip.metadata
                .insert("file_size".into(), descriptor.size.to_string());
            clip.metadata
                .insert("file_sha256".into(), descriptor.sha256.clone());
            let pending = PendingFileCommit {
                file_id: descriptor.id,
                event_id: uuid::Uuid::new_v4().to_string(),
                clip: Some(clip),
                retry_at: 0,
            };
            persist_pending_file_commits(&mut client.store, std::slice::from_ref(&pending))
                .unwrap();
            client.store.put("capture-consent", &false).unwrap();

            let mut markers = vec![pending.clone()];
            let result = cancel_pending_file_commit_with_persist(
                &mut client.store,
                &mut markers,
                &pending.file_id,
                &pending.event_id,
                |_, _| Err(SyncError::Paused),
            );
            assert!(matches!(result, Err(SyncError::Paused)));
            // Failed copy-on-write persistence leaves both process memory and
            // the prior durable intent intact; the store tombstone fences it.
            assert_eq!(markers, vec![pending.clone()]);
            assert!(client.store.file_transfers().unwrap().is_empty());
            pending
        };

        let store = DeviceStore::open(&database, [37; 32]).unwrap();
        let mut client = SyncClient::open(store).unwrap();
        assert_eq!(
            client.store.get::<bool>("capture-consent").unwrap(),
            Some(false)
        );
        let marker: Vec<PendingFileCommit> =
            client.store.get(PENDING_FILE_COMMITS_KEY).unwrap().unwrap();
        assert_eq!(marker, vec![pending.clone()]);

        // The durable event tombstone makes replay a no-op even though the
        // retry marker still contains its write-ahead clip payload.
        assert!(matches!(
            replay_pending_file_capture(&mut client, &marker[0]),
            Err(SyncError::Attachment)
        ));
        assert!(client.store.event(&pending.event_id).unwrap().is_none());
        assert!(client.store.history().unwrap().is_empty());
        assert!(client.store.file_transfers().unwrap().is_empty());
        let mut recovered = marker;
        clear_missing_pending_file_commit(&mut client.store, &mut recovered, &pending).unwrap();
        assert!(recovered.is_empty());
        assert_eq!(
            client
                .store
                .get::<Vec<PendingFileCommit>>(PENDING_FILE_COMMITS_KEY)
                .unwrap(),
            Some(vec![])
        );
        drop(client);
        std::fs::remove_dir_all(path).unwrap();
    }

    #[test]
    fn attachment_added_while_sharing_is_off_stays_local() {
        assert!(!should_queue_attachment(false, false, true, true));
        assert!(!should_queue_attachment(true, true, true, true));
        assert!(!should_queue_attachment(true, false, false, true));
        assert!(!should_queue_attachment(true, false, true, false));
        assert!(should_queue_attachment(true, false, true, true));
    }

    #[test]
    fn pending_retry_selects_one_due_marker_and_backoff_does_not_starve_later_files() {
        let mut commits = vec![
            PendingFileCommit {
                file_id: uuid::Uuid::new_v4().to_string(),
                event_id: uuid::Uuid::new_v4().to_string(),
                clip: None,
                retry_at: 0,
            },
            PendingFileCommit {
                file_id: uuid::Uuid::new_v4().to_string(),
                event_id: uuid::Uuid::new_v4().to_string(),
                clip: None,
                retry_at: 0,
            },
        ];
        assert_eq!(due_pending_commit_index(&commits, 100), Some(0));
        // A is attempted and receives the five-second unsupported backoff.
        commits[0].retry_at = 105;
        assert_eq!(due_pending_commit_index(&commits, 100), Some(1));
        // B also receives a backoff; both become eligible again when due.
        commits[1].retry_at = 105;
        assert_eq!(due_pending_commit_index(&commits, 104), None);
        assert_eq!(due_pending_commit_index(&commits, 105), Some(0));
        commits[0].retry_at = 110;
        assert_eq!(due_pending_commit_index(&commits, 105), Some(1));
    }

    #[test]
    fn deleting_attachment_cancels_transfer_and_removes_local_history_and_retry_marker() {
        let path = std::env::temp_dir().join(format!(
            "clipvault-linux-delete-file-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&path).unwrap();
        let source = path.join("source.txt");
        std::fs::write(&source, b"attachment delete regression").unwrap();
        let mut store = DeviceStore::open(&path.join("clips.sqlite"), [23; 32]).unwrap();
        let origin = uuid::Uuid::new_v4().to_string();
        let descriptor = store.stage_file(&source, &origin, || false).unwrap();
        let event_id = uuid::Uuid::new_v4().to_string();
        let mut clip = PortableClip::text(&descriptor.filename, descriptor.created_at);
        clip.kind = "attachment".into();
        clip.display_text = descriptor.filename.clone();
        clip.metadata
            .insert("file_id".into(), descriptor.id.clone());
        clip.metadata
            .insert("file_origin".into(), descriptor.origin.clone());
        clip.metadata
            .insert("file_size".into(), descriptor.size.to_string());
        clip.metadata
            .insert("file_sha256".into(), descriptor.sha256.clone());
        let mut event = ClipEvent::new(origin, 1, clip);
        event.id = event_id.clone();
        store.capture_local(&event).unwrap();
        let mut markers = vec![PendingFileCommit {
            file_id: descriptor.id.clone(),
            event_id: event_id.clone(),
            clip: None,
            retry_at: 0,
        }];
        persist_pending_file_commits(&mut store, &markers).unwrap();

        delete_local_clip(&mut store, &event_id, &mut markers).unwrap();

        assert!(store.file_transfers().unwrap().is_empty());
        assert!(store.history().unwrap().is_empty());
        assert!(markers.is_empty());
        assert_eq!(
            store
                .get::<Vec<PendingFileCommit>>(PENDING_FILE_COMMITS_KEY)
                .unwrap(),
            Some(vec![])
        );
        drop(store);
        std::fs::remove_dir_all(path).unwrap();
    }

    #[test]
    fn disconnect_persists_empty_retry_queue_before_identity_rotation() {
        let path = std::env::temp_dir().join(format!(
            "clipvault-linux-disconnect-files-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&path).unwrap();
        let mut store = DeviceStore::open(&path.join("clips.sqlite"), [29; 32]).unwrap();
        let mut markers = vec![PendingFileCommit {
            file_id: uuid::Uuid::new_v4().to_string(),
            event_id: uuid::Uuid::new_v4().to_string(),
            clip: None,
            retry_at: 0,
        }];
        persist_pending_file_commits(&mut store, &markers).unwrap();
        clear_pending_file_commits(&mut store, &mut markers).unwrap();
        assert!(markers.is_empty());
        assert_eq!(
            store
                .get::<Vec<PendingFileCommit>>(PENDING_FILE_COMMITS_KEY)
                .unwrap(),
            Some(vec![])
        );
        drop(store);
        std::fs::remove_dir_all(path).unwrap();
    }
}
