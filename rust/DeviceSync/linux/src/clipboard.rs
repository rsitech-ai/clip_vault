use crate::worker::Work;
use base64::{Engine, engine::general_purpose::STANDARD};
use clipvault_linux::policy::CaptureGate;
use clipvault_sync_core::*;
use gtk::{gdk, prelude::*};
use std::{cell::Cell, rc::Rc, sync::mpsc::Sender};

pub fn watch(display: &gdk::Display, tx: Sender<Work>, capturing: std::sync::Arc<CaptureGate>) {
    let clipboard = display.clipboard();
    let generation = Rc::new(Cell::new(0_u64));
    clipboard.connect_changed(move |clipboard| {
        generation.set(generation.get().wrapping_add(1));
        let current = generation.get();
        let token = capturing.read_token();
        if !capturing.enabled() {
            return;
        }
        let formats = clipboard.formats();
        let marked = [
            "application/x-clipvault-copy",
            "x-kde-passwordManagerHint",
            "application/x-keepassxc",
            "application/x-1password",
        ]
        .iter()
        .any(|mime| formats.contain_mime_type(mime));
        if marked {
            return;
        }
        let image = formats.contain_mime_type("image/png");
        let rich = if formats.contain_mime_type("application/rtf") {
            Some("application/rtf")
        } else if formats.contain_mime_type("text/rtf") {
            Some("text/rtf")
        } else {
            None
        };
        let clipboard = clipboard.clone();
        let tx = tx.clone();
        let generation = generation.clone();
        let capturing = capturing.clone();
        glib::MainContext::default().spawn_local(async move {
            let types = if image {
                vec!["image/png"]
            } else {
                vec!["text/plain;charset=utf-8", "UTF8_STRING", "text/plain"]
            };
            let Ok((stream, _)) = clipboard.read_future(&types, glib::Priority::DEFAULT).await
            else {
                return;
            };
            if generation.get() != current || !capturing.permits(token) {
                let _ = stream.close(None::<&gio::Cancellable>);
                return;
            }
            let mut data = Vec::new();
            loop {
                let Ok(chunk) = stream
                    .read_bytes_future(65536, glib::Priority::DEFAULT)
                    .await
                else {
                    return;
                };
                if generation.get() != current || !capturing.permits(token) {
                    let _ = stream.close(None::<&gio::Cancellable>);
                    return;
                }
                if chunk.is_empty() {
                    break;
                }
                if data.len() + chunk.len() > MAX_PAYLOAD_BYTES {
                    let _ = stream.close(None::<&gio::Cancellable>);
                    return;
                }
                data.extend_from_slice(&chunk);
            }
            let _ = stream.close(None::<&gio::Cancellable>);
            let mut clip = if image {
                if validate_png(&data).is_err() {
                    return;
                }
                let mut clip = PortableClip::text("", unix_time());
                clip.kind = "image".into();
                clip.display_text = "Image".into();
                clip.image_png = Some(STANDARD.encode(data));
                clip
            } else {
                let Ok(text) = String::from_utf8(data) else {
                    return;
                };
                PortableClip::text(&text, unix_time())
            };
            if generation.get() != current || !capturing.permits(token) {
                return;
            }
            if !image
                && let Some(mime) = rich
                && let Ok((stream, _)) = clipboard
                    .read_future(&[mime], glib::Priority::DEFAULT)
                    .await
            {
                let mut rtf = Vec::new();
                loop {
                    let Ok(chunk) = stream
                        .read_bytes_future(65536, glib::Priority::DEFAULT)
                        .await
                    else {
                        return;
                    };
                    if generation.get() != current || !capturing.permits(token) {
                        let _ = stream.close(None::<&gio::Cancellable>);
                        return;
                    }
                    if chunk.is_empty() {
                        break;
                    }
                    if rtf.len() + chunk.len() > MAX_PAYLOAD_BYTES {
                        let _ = stream.close(None::<&gio::Cancellable>);
                        return;
                    }
                    rtf.extend_from_slice(&chunk);
                }
                let _ = stream.close(None::<&gio::Cancellable>);
                if rtf.starts_with(b"{\\rtf") {
                    clip.kind = "richText".into();
                    clip.metadata.insert("rtf".into(), STANDARD.encode(rtf));
                }
            }
            if generation.get() == current && capturing.permits(token) {
                let _ = tx.send(Work::Capture(clip, false));
            }
        });
    });
}
pub fn copy(display: &gdk::Display, clip: &PortableClip) -> Result<()> {
    clip.validate()?;
    let content = if let Some(image) = &clip.image_png {
        let bytes = STANDARD.decode(image).map_err(|_| SyncError::Invalid)?;
        gdk::ContentProvider::for_bytes("image/png", &glib::Bytes::from_owned(bytes))
    } else {
        gdk::ContentProvider::for_value(&clip.text.to_value())
    };
    let marker = gdk::ContentProvider::for_bytes(
        "application/x-clipvault-copy",
        &glib::Bytes::from_static(b"1"),
    );
    let mut providers = vec![content, marker];
    if clip.kind == "richText"
        && let Some(rtf) = clip.metadata.get("rtf")
    {
        let bytes = STANDARD.decode(rtf).map_err(|_| SyncError::Invalid)?;
        providers.push(gdk::ContentProvider::for_bytes(
            "application/rtf",
            &glib::Bytes::from_owned(bytes),
        ));
    }
    let provider = gdk::ContentProvider::new_union(&providers);
    display
        .clipboard()
        .set_content(Some(&provider))
        .map_err(|_| SyncError::Invalid)
}
