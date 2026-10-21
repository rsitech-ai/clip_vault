use crate::worker::Work;
use base64::{Engine, engine::general_purpose::STANDARD};
use clipvault_linux::policy::CaptureGate;
use clipvault_sync_core::*;
use gtk::{gdk, prelude::*};
use std::{cell::Cell, path::PathBuf, rc::Rc, sync::mpsc::Sender};

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
        let files = formats.contain_mime_type("text/uri-list");
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
            let types = if preferred_mime(image, files) == "text/uri-list" {
                vec!["text/uri-list"]
            } else if preferred_mime(image, files) == "image/png" {
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
            if files {
                let mut data = Vec::new();
                loop {
                    let Ok(chunk) = stream
                        .read_bytes_future(8192, glib::Priority::DEFAULT)
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
                    if data.len().saturating_add(chunk.len()) > 64 * 1024 {
                        let _ = stream.close(None::<&gio::Cancellable>);
                        return;
                    }
                    data.extend_from_slice(&chunk);
                }
                let _ = stream.close(None::<&gio::Cancellable>);
                if generation.get() == current && capturing.permits(token) {
                    match local_uri_paths(&data) {
                        Ok(paths) => {
                            let _ = tx.send(Work::StageFiles(paths, Some(token)));
                        }
                        Err(()) => {
                            let _ = tx.send(Work::FileSelectionError(
                                "Only up to 10 local files can be shared at a time.".into(),
                            ));
                        }
                    }
                }
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
                let _ = tx.send(Work::Capture(clip, false, token));
            }
        });
    });
}

fn preferred_mime(image: bool, files: bool) -> &'static str {
    if files {
        "text/uri-list"
    } else if image {
        "image/png"
    } else {
        "text/plain;charset=utf-8"
    }
}

/// Convert a bounded text/uri-list to local file paths. URI parsing happens
/// once through GFile; only empty and localhost authorities are accepted.
pub(crate) fn local_uri_paths(input: &[u8]) -> std::result::Result<Vec<PathBuf>, ()> {
    if input.len() > 64 * 1024 {
        return Err(());
    }
    let text = std::str::from_utf8(input).map_err(|_| ())?;
    let mut paths = Vec::new();
    for line in text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
    {
        if paths.len() >= 10 {
            return Err(());
        }
        let rest = line.strip_prefix("file://").ok_or(())?;
        let slash = rest.find('/').ok_or(())?;
        let authority = &rest[..slash];
        if !(authority.is_empty() || authority.eq_ignore_ascii_case("localhost"))
            || line.contains('?')
            || line.contains('#')
        {
            return Err(());
        }
        let path = gio::File::for_uri(line).path().ok_or(())?;
        if !path.is_absolute() {
            return Err(());
        }
        paths.push(path);
    }
    if paths.is_empty() {
        return Err(());
    }
    Ok(paths)
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

#[cfg(test)]
mod tests {
    use super::{local_uri_paths, preferred_mime};
    use std::path::Path;

    #[test]
    fn uri_list_decodes_local_paths_and_rejects_remote_and_unbounded_input() {
        let paths = local_uri_paths(
            b"# comment\r\nfile:///tmp/a%20b.txt\r\nfile://localhost/tmp/c.txt\r\n",
        )
        .unwrap();
        assert_eq!(
            paths,
            vec![Path::new("/tmp/a b.txt"), Path::new("/tmp/c.txt")]
        );
        assert!(local_uri_paths(b"file://server/share/a.txt\n").is_err());
        assert!(local_uri_paths(b"https://example.test/a\n").is_err());
        assert!(local_uri_paths(&vec![b'a'; 64 * 1024 + 1]).is_err());
        let ten = (0..10)
            .map(|i| format!("file:///tmp/{i}\n"))
            .collect::<String>();
        assert_eq!(local_uri_paths(ten.as_bytes()).unwrap().len(), 10);
        let eleven = format!("{ten}file:///tmp/10\n");
        assert!(local_uri_paths(eleven.as_bytes()).is_err());
    }

    #[test]
    fn file_list_takes_precedence_when_clipboard_offers_files_and_png() {
        assert_eq!(preferred_mime(true, true), "text/uri-list");
        assert_eq!(preferred_mime(true, false), "image/png");
        assert_eq!(preferred_mime(false, false), "text/plain;charset=utf-8");
    }
}
