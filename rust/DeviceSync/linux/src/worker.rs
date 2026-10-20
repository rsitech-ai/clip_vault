use clipvault_linux::policy::{CaptureGate, CapturePolicy};
use clipvault_sync_core::*;
use std::sync::{
    Arc,
    atomic::AtomicBool,
    mpsc::{self, Receiver, Sender},
};

pub enum Work {
    Capture(PortableClip, bool),
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
    Delete(String),
    Disconnect,
}
#[derive(Clone)]
pub struct Snapshot {
    pub history: Arc<Vec<ClipEvent>>,
    pub status: ClientStatus,
    pub message: Option<String>,
    pub pairing: Option<String>,
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
        let mut last_tick = std::time::Instant::now() - std::time::Duration::from_secs(6);
        let mut request_cache = vec![];
        let mut message = None;
        let mut pairing = None;
        let mut query = String::new();
        let mut display_limit = 100;
        let mut previous_signature = None;
        let mut history = Arc::new(vec![]);
        loop {
            let command = rx.recv_timeout(std::time::Duration::from_secs(1));
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
                Ok(Work::Capture(clip, marked)) => policy
                    .accept(&clip, marked || !capturing.enabled())
                    .and_then(|accept| {
                        if accept {
                            client.capture(clip, None).map(|_| ())
                        } else {
                            Ok(())
                        }
                    }),
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
                Ok(Work::Disconnect) => client.disconnect().map(|count| {
                    request_cache.clear();
                    pairing = None;
                    message = Some(format!("Disconnected locally; {count} pending recipient deliveries cancelled. History kept. Remove this device on the owner to revoke its old membership."));
                }),
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
                Ok(Work::Delete(id)) => client.store.delete_local(&id),
                Err(mpsc::RecvTimeoutError::Timeout) => Ok(()),
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            };
            if let Err(error) = result {
                message = Some(error.to_string());
            }
            let mut status = if last_tick.elapsed() >= std::time::Duration::from_secs(5) {
                last_tick = std::time::Instant::now();
                match client.tick(true) {
                    Ok(status) => {
                        request_cache = status.requests.clone();
                        status
                    }
                    Err(error) => {
                        message = Some(error.to_string());
                        client.status().unwrap_or_default()
                    }
                }
            } else {
                client.status().unwrap_or_default()
            };
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
            if result_tx
                .send(Snapshot {
                    history: history.clone(),
                    status,
                    message: message.take(),
                    pairing: pairing.take(),
                })
                .is_err()
            {
                break;
            }
        }
    });
    (tx, result_rx)
}
