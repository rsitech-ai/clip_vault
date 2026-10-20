//! Synchronous bounded JSON ABI. The Swift caller dispatches off its main actor.
use clipvault_sync_core::*;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    ffi::{CString, c_char},
    path::PathBuf,
    sync::{
        Arc, LazyLock, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};
use zeroize::Zeroizing;
static EXECUTION: Mutex<()> = Mutex::new(());
static CANCELLED: LazyLock<Arc<AtomicBool>> = LazyLock::new(|| Arc::new(AtomicBool::new(false)));
static FILE_CAPTURE_GENERATION: AtomicU64 = AtomicU64::new(0);

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Command {
    namespace: String,
    directory: PathBuf,
    action: String,
    #[serde(default)]
    payload: Value,
}
fn text<'a>(body: &'a Value, key: &str) -> Result<&'a str> {
    body.get(key)
        .and_then(Value::as_str)
        .ok_or(SyncError::Invalid)
}
fn export_outbox(client: &mut SyncClient, body: &Value) -> Result<Value> {
    // Swift removes its durable marker only after this call succeeds. A queued
    // export must never be accepted as local-only if pause won the race.
    if CANCELLED.load(Ordering::Acquire) || !client.sharing_enabled() {
        return Err(SyncError::Paused);
    }
    let clip: PortableClip =
        serde_json::from_value(body.get("clip").cloned().ok_or(SyncError::Invalid)?)?;
    if clip.kind == "attachment" {
        clip.validate()?;
        let id = clip.metadata.get("file_id").ok_or(SyncError::Invalid)?;
        let event_id = text(body, "id")?;
        let file_id = id.clone();
        client.capture(clip, Some(event_id))?;
        client.commit_file(&file_id, event_id)?;
        return Ok(json!(event_id));
    }
    Ok(json!(
        client.capture(clip, body.get("id").and_then(Value::as_str))?
    ))
}
fn execute(bytes: &[u8]) -> Result<Value> {
    let cmd: Command = serde_json::from_slice(bytes)?;
    if !cmd.namespace.starts_with("com.andrzej.ClipVault") || !cmd.directory.is_absolute() {
        return Err(SyncError::Invalid);
    }
    let key = platform_key(&format!("{}.sync", cmd.namespace))?;
    let mut client = SyncClient::open(DeviceStore::open(
        &cmd.directory.join("device-sync.sqlite"),
        key,
    )?)?;
    client.set_cancel_signal(CANCELLED.clone());
    let b = &cmd.payload;
    if ["invite", "approve", "remove"].contains(&cmd.action.as_str()) && !client.sharing_enabled() {
        return Err(SyncError::Paused);
    }
    match cmd.action.as_str() {
        "disconnect" => Ok(json!(client.disconnect()?)),
        "status" => Ok(serde_json::to_value(client.status()?)?),
        "create" => {
            client.create_workspace(
                text(b, "relay")?,
                text(b, "registration")?,
                text(b, "name")?,
            )?;
            Ok(json!(true))
        }
        "join" => Ok(json!(client.join(text(b, "code")?, text(b, "name")?)?)),
        "invite" => Ok(json!(client.create_invite()?)),
        "requests" => Ok(serde_json::to_value(client.pairing_requests()?)?),
        "approve" => {
            client.approve(text(b, "id")?, text(b, "words")?)?;
            Ok(json!(true))
        }
        "remove" => {
            client.remove_device(text(b, "id")?)?;
            Ok(json!(true))
        }
        "enable" => {
            client.set_enabled(
                b.get("enabled")
                    .and_then(Value::as_bool)
                    .ok_or(SyncError::Invalid)?,
            )?;
            Ok(json!(true))
        }
        "capture" => export_outbox(&mut client, b),
        "file_stage" => {
            let generation = match b.get("generation") {
                None | Some(Value::Null) => None,
                Some(value) => Some(value.as_u64().ok_or(SyncError::Invalid)?),
            };
            let path = PathBuf::from(text(b, "path")?);
            if !path.is_absolute() {
                return Err(SyncError::Invalid);
            }
            let descriptor = client.stage_file(&path, || {
                generation.is_some_and(|expected| {
                    FILE_CAPTURE_GENERATION.load(Ordering::Acquire) != expected
                })
            })?;
            Ok(serde_json::to_value(descriptor)?)
        }
        "file_save" => {
            let path = PathBuf::from(text(b, "path")?);
            if !path.is_absolute() {
                return Err(SyncError::Invalid);
            }
            client.store.save_file(text(b, "id")?, &path, || false)?;
            Ok(json!(true))
        }
        "file_discard" => {
            client.store.discard_uncommitted_file(text(b, "id")?)?;
            Ok(json!(true))
        }
        "file_transfers" => Ok(serde_json::to_value(client.file_transfers()?)?),
        "tick" => Ok(serde_json::to_value(client.tick(false)?)?),
        "retry_overflow" => Ok(serde_json::to_value(client.retry_overflow()?)?),
        "imports" => Ok(serde_json::to_value(client.store.unapplied()?)?),
        "applied" => {
            client.store.mark_applied(text(b, "id")?)?;
            Ok(json!(true))
        }
        "reject_import" => {
            client.store.reject_import(text(b, "id")?)?;
            Ok(json!(true))
        }
        "delete" => {
            let id = text(b, "id")?;
            if let Some(file_id) = id.strip_prefix("file:") {
                client.store.delete_file(file_id)?;
            } else {
                client.store.delete_local(id)?;
            }
            Ok(json!(true))
        }
        _ => Err(SyncError::Invalid),
    }
}
/// Captured before queueing a file read so a later pause cancels queued work too.
#[unsafe(no_mangle)]
pub extern "C" fn cv_sync_file_generation() -> u64 {
    FILE_CAPTURE_GENERATION.load(Ordering::Acquire)
}
#[unsafe(no_mangle)]
pub extern "C" fn cv_sync_cancel_file_capture() {
    FILE_CAPTURE_GENERATION.fetch_add(1, Ordering::AcqRel);
}
/// Executes one bounded UTF-8 command and returns a NUL-terminated JSON result.
///
/// # Safety
/// `input` must refer to `length` readable bytes for the duration of this call.
/// Release the returned pointer exactly once with `cv_sync_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cv_sync_execute(input: *const u8, length: usize) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        if input.is_null() || length == 0 || length > MAX_WIRE_BYTES + 8192 {
            return Err(SyncError::Invalid);
        }
        let _guard = EXECUTION.lock().map_err(|_| SyncError::Invalid)?;
        // SAFETY: required by the ABI contract; bounded above before constructing the slice.
        let data = Zeroizing::new(unsafe { std::slice::from_raw_parts(input, length) }.to_vec());
        execute(&data)
    });
    let value = match result {
        Ok(Ok(value)) => json!({"ok":true,"value":value}),
        Ok(Err(error)) => json!({"ok":false,"error":error.to_string()}),
        Err(_) => json!({"ok":false,"error":"Sync engine failed safely"}),
    };
    // JSON escaping makes interior NUL impossible.
    CString::new(value.to_string()).map_or(std::ptr::null_mut(), CString::into_raw)
}
/// # Safety
/// `value` must be a live pointer returned by `cv_sync_execute`, freed only once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cv_sync_free(value: *mut c_char) {
    if !value.is_null() {
        let mut string = unsafe { CString::from_raw(value) }.into_bytes();
        use zeroize::Zeroize;
        string.zeroize();
    }
}

/// Stops further requests between network operations; an already accepted HTTP request cannot be undone.
#[unsafe(no_mangle)]
pub extern "C" fn cv_sync_pause() {
    CANCELLED.store(true, Ordering::Release);
}

/// Explicit user consent opens the gate immediately. Queued commands never
/// reopen it, so an older enable cannot undo a newer pause.
#[unsafe(no_mangle)]
pub extern "C" fn cv_sync_resume() {
    CANCELLED.store(false, Ordering::Release);
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn abi_rejects_null_and_oversize_before_access_or_credentials() {
        for (pointer, len) in [
            (std::ptr::null(), 0),
            (std::ptr::null(), MAX_WIRE_BYTES + 10000),
        ] {
            let output = unsafe { cv_sync_execute(pointer, len) };
            assert!(!output.is_null());
            let value: Value =
                serde_json::from_slice(unsafe { std::ffi::CStr::from_ptr(output) }.to_bytes())
                    .unwrap();
            assert_eq!(value["ok"], false);
            unsafe { cv_sync_free(output) };
        }
    }

    #[test]
    fn paused_export_keeps_the_platform_retry_marker_instead_of_succeeding_locally() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = DeviceStore::open(&dir.path().join("store.sqlite"), [7; 32]).unwrap();
        store
            .put(
                "configuration",
                &json!({
                    "workspace":"00000000-0000-4000-8000-000000000001",
                    "relay":"https://example.test", "owner_key":"test-only",
                    "credential":"test-only", "roster":null, "enabled":false,
                    "awaiting_approval":false, "name":"Test"
                }),
            )
            .unwrap();
        let mut client = SyncClient::open(store).unwrap();
        let body = json!({"id":"00000000-0000-4000-8000-000000000002",
            "clip":PortableClip::text("Retain my pending export", 1)});
        assert!(matches!(
            export_outbox(&mut client, &body),
            Err(SyncError::Paused)
        ));
        assert!(client.store.history().unwrap().is_empty());
    }
}
