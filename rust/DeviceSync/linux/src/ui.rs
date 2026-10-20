use crate::{
    bridge, clipboard,
    worker::{self, Snapshot, Work},
};
use adw::prelude::*;
use base64::{Engine, engine::general_purpose::STANDARD};
use clipvault_linux::policy::CaptureGate;
use clipvault_sync_core::*;
use gtk::{gdk, glib};
use std::{
    cell::RefCell,
    rc::Rc,
    sync::{atomic::Ordering, mpsc::Sender},
};

pub fn run() {
    let application = adw::Application::builder()
        .application_id("com.rsitech.ClipVault")
        .build();
    application.connect_activate(build);
    application.run();
}
fn build(app: &adw::Application) {
    // GtkApplication emits activate again when an already-running app is
    // launched from the desktop. Reuse the existing consent gates and worker.
    if let Some(window) = app
        .windows()
        .into_iter()
        .find_map(|window| window.downcast::<adw::ApplicationWindow>().ok())
    {
        window.present();
        return;
    }
    let capturing = std::sync::Arc::new(CaptureGate::default());
    let cancelled = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let (tx, rx) = worker::start(capturing.clone(), cancelled.clone());
    let x11 = std::env::var("XDG_SESSION_TYPE").as_deref() == Ok("x11");
    let bridge_state = bridge::start(tx.clone(), capturing.clone());
    let display = gdk::Display::default().expect("GTK activation requires a display");
    if x11 {
        clipboard::watch(&display, tx.clone(), capturing.clone());
    }
    let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let header = adw::HeaderBar::new();
    header.set_title_widget(Some(&gtk::Label::new(Some("ClipVault"))));
    let quit = gtk::Button::with_label("Quit");
    {
        let app = app.clone();
        quit.connect_clicked(move |_| app.quit());
    }
    header.pack_start(&quit);
    let settings = gtk::Button::with_label("Devices & Sharing");
    header.pack_end(&settings);
    root.append(&header);
    let body = gtk::Box::new(gtk::Orientation::Vertical, 12);
    body.set_margin_start(20);
    body.set_margin_end(20);
    body.set_margin_top(20);
    body.set_margin_bottom(20);
    let capture = gtk::Switch::new();
    capture.set_sensitive(false);
    let capture_row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    let consent = gtk::Label::new(Some("Capture clipboard on this device"));
    consent.set_hexpand(true);
    consent.set_xalign(0.);
    capture_row.append(&consent);
    capture_row.append(&capture);
    body.append(&capture_row);
    let disclosure = gtk::Label::new(Some(
        "Capture stores clipboard history encrypted on this laptop. Sharing stays off until you pair devices. Sensitive-looking text is filtered. Notes, folders and files remain local.",
    ));
    disclosure.set_wrap(true);
    disclosure.set_xalign(0.);
    disclosure.add_css_class("dim-label");
    body.append(&disclosure);
    let status = gtk::Label::new(Some("Opening encrypted local history…"));
    status.set_xalign(0.);
    status.set_wrap(true);
    body.append(&status);
    let platform = gtk::Label::new(None);
    platform.set_xalign(0.);
    platform.set_wrap(true);
    platform.add_css_class("dim-label");
    body.append(&platform);
    let search = gtk::SearchEntry::new();
    search.set_placeholder_text(Some("Search your clips"));
    body.append(&search);
    let list = gtk::ListBox::new();
    list.set_selection_mode(gtk::SelectionMode::None);
    list.add_css_class("boxed-list");
    let scroll = gtk::ScrolledWindow::new();
    scroll.set_vexpand(true);
    scroll.set_child(Some(&list));
    body.append(&scroll);
    let more = gtk::Button::with_label("Load older clips");
    {
        let tx = tx.clone();
        more.connect_clicked(move |_| {
            let _ = tx.send(Work::More);
        });
    }
    body.append(&more);
    root.append(&body);
    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title("ClipVault")
        .default_width(780)
        .default_height(680)
        .content(&root)
        .build();
    let latest: Rc<RefCell<Option<Snapshot>>> = Rc::new(RefCell::new(None));
    let rebuilding = Rc::new(std::cell::Cell::new(false));
    {
        let tx = tx.clone();
        let rebuilding = rebuilding.clone();
        let capturing = capturing.clone();
        capture.connect_active_notify(move |switch| {
            if !rebuilding.get() {
                capturing.set(switch.is_active());
                let _ = tx.send(Work::CaptureConsent(switch.is_active()));
            }
        });
    }
    {
        let latest = latest.clone();
        let window = window.clone();
        let tx = tx.clone();
        settings.connect_clicked(move |_| {
            devices(&window, tx.clone(), latest.clone(), cancelled.clone())
        });
    }
    {
        let latest = latest.clone();
        let list = list.clone();
        let tx = tx.clone();
        search.connect_search_changed(move |entry| {
            let _ = tx.send(Work::Search(entry.text().to_string()));
            if let Some(snapshot) = latest.borrow().as_ref() {
                render(&list, snapshot, &entry.text(), &tx);
            }
        });
    }
    {
        let latest = latest.clone();
        let list = list.clone();
        let tx = tx.clone();
        let search = search.clone();
        let window = window.clone();
        let restored = std::cell::Cell::new(false);
        glib::timeout_add_local(std::time::Duration::from_millis(250), move || {
            while let Ok(snapshot) = rx.try_recv() {
                rebuilding.set(true);
                // Restore once; later worker snapshots can predate a user's
                // gesture. The immediate gate remains authoritative thereafter.
                if !restored.get() && capturing.initialized() {
                    if capture.is_active() != capturing.enabled() {
                        capture.set_active(capturing.enabled());
                    }
                    capture.set_sensitive(true);
                    restored.set(true);
                }
                rebuilding.set(false);
                status.set_text(&snapshot.message.clone().unwrap_or_else(|| {
                    format!(
                        "{} · {} clips · {} pending",
                        snapshot.status.state,
                        snapshot.history.len(),
                        snapshot.status.pending
                    )
                }));
                platform.set_text(if x11{"X11 clipboard capture"}else if (unix_time() as u64).saturating_sub(bridge_state.load(Ordering::Relaxed))<15{"GNOME clipboard bridge connected"}else{"GNOME Wayland: enable the ClipVault capture extension for background capture. History and Copy remain available."});
                if latest
                    .borrow()
                    .as_ref()
                    .is_none_or(|old| old.history != snapshot.history)
                {
                    render(&list, &snapshot, &search.text(), &tx);
                }
                if let Some(code) = &snapshot.pairing {
                    show_code(&window, code);
                }
                *latest.borrow_mut() = Some(snapshot);
            }
            glib::ControlFlow::Continue
        });
    }
    // Keep clipboard ownership and capture alive when the main window is hidden.
    let hold = app.hold();
    window.connect_close_request(move |window| {
        let _ = &hold;
        window.set_visible(false);
        glib::Propagation::Stop
    });
    window.present();
}
fn render(list: &gtk::ListBox, snapshot: &Snapshot, query: &str, tx: &Sender<Work>) {
    while let Some(child) = list.first_child() {
        list.remove(&child);
    }
    let mut day = String::new();
    let normalized = search_index_core::normalize_text(query);
    for event in snapshot.history.iter() {
        if !normalized.is_empty()
            && search_index_core::lexical_score(
                &normalized,
                &format!("{}\n{}", event.clip.display_text, event.clip.text),
            ) <= 0.
        {
            continue;
        }
        let date = glib::DateTime::from_unix_local(event.clip.captured_at).ok();
        let next_day = date
            .as_ref()
            .and_then(|d| d.format("%A, %e %B %Y").ok())
            .map(|v| v.to_string())
            .unwrap_or_default();
        if next_day != day {
            day = next_day;
            let label = gtk::Label::new(Some(&day));
            label.set_xalign(0.);
            label.set_margin_top(14);
            label.set_margin_bottom(6);
            label.add_css_class("heading");
            list.append(&label);
        }
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        row.set_margin_start(12);
        row.set_margin_end(12);
        row.set_margin_top(10);
        row.set_margin_bottom(10);
        let content = gtk::Box::new(gtk::Orientation::Vertical, 5);
        content.set_hexpand(true);
        let title = event
            .clip
            .display_text
            .lines()
            .next()
            .unwrap_or("Image")
            .chars()
            .take(100)
            .collect::<String>();
        let label = gtk::Label::new(Some(&title));
        label.set_xalign(0.);
        label.set_ellipsize(gtk::pango::EllipsizeMode::End);
        label.add_css_class("heading");
        content.append(&label);
        let snippet = gtk::Label::new(Some(&event.clip.text.chars().take(240).collect::<String>()));
        snippet.set_xalign(0.);
        snippet.set_wrap(true);
        snippet.set_lines(2);
        snippet.set_ellipsize(gtk::pango::EllipsizeMode::End);
        content.append(&snippet);
        if let Some(encoded) = &event.clip.image_png
            && let Ok(data) = STANDARD.decode(encoded)
            && validate_png(&data).is_ok()
            && let Ok(texture) = gdk::Texture::from_bytes(&glib::Bytes::from_owned(data))
        {
            let picture = gtk::Picture::for_paintable(&texture);
            picture.set_can_shrink(true);
            picture.set_size_request(160, 100);
            picture.set_halign(gtk::Align::Start);
            content.append(&picture);
        }
        let time = date
            .as_ref()
            .and_then(|d| d.format("%H:%M").ok())
            .map(|v| v.to_string())
            .unwrap_or_default();
        let meta = gtk::Label::new(Some(&format!(
            "{} · {}",
            time,
            event.clip.source_device.as_deref().unwrap_or("This device")
        )));
        meta.set_xalign(0.);
        meta.add_css_class("dim-label");
        content.append(&meta);
        row.append(&content);
        let actions = gtk::Box::new(gtk::Orientation::Vertical, 6);
        let copy = gtk::Button::with_label("Copy");
        let delete = gtk::Button::with_label("Delete locally");
        {
            let clip = event.clip.clone();
            let tx = tx.clone();
            copy.connect_clicked(move |_| {
                if let Some(display) = gdk::Display::default()
                    && clipboard::copy(&display, &clip).is_ok()
                {
                    let _ = tx.send(Work::Copied(clip.clone()));
                }
            });
        }
        {
            let id = event.id.clone();
            let tx = tx.clone();
            delete.connect_clicked(move |_| {
                let _ = tx.send(Work::Delete(id.clone()));
            });
        }
        actions.append(&copy);
        actions.append(&delete);
        row.append(&actions);
        list.append(&row);
    }
    if snapshot.history.is_empty() {
        let label = gtk::Label::new(Some(
            "Your clips will appear here after you enable capture or pair a device.",
        ));
        label.set_wrap(true);
        label.set_margin_top(30);
        label.set_margin_bottom(30);
        list.append(&label);
    }
}
fn show_code(parent: &adw::ApplicationWindow, code: &str) {
    let dialog = gtk::Window::builder()
        .title("Pair ClipVault devices")
        .transient_for(parent)
        .modal(true)
        .default_width(620)
        .default_height(260)
        .build();
    let body = gtk::Box::new(gtk::Orientation::Vertical, 12);
    body.set_margin_start(20);
    body.set_margin_end(20);
    body.set_margin_top(20);
    body.set_margin_bottom(20);
    let instruction = gtk::Label::new(Some(
        "Transfer this invitation privately to the other device. Compare the verification code on both devices before approving. Invitations expire after ten minutes.",
    ));
    instruction.set_wrap(true);
    body.append(&instruction);
    let text = gtk::TextView::new();
    text.set_editable(false);
    text.set_wrap_mode(gtk::WrapMode::Char);
    text.buffer().set_text(code);
    let scroll = gtk::ScrolledWindow::new();
    scroll.set_vexpand(true);
    scroll.set_child(Some(&text));
    body.append(&scroll);
    let close = gtk::Button::with_label("Close");
    {
        let dialog = dialog.clone();
        close.connect_clicked(move |_| dialog.close());
    }
    body.append(&close);
    dialog.set_child(Some(&body));
    dialog.present();
}
fn entry(body: &gtk::Box, title: &str, secret: bool) -> gtk::Entry {
    let label = gtk::Label::new(Some(title));
    label.set_xalign(0.);
    body.append(&label);
    let entry = gtk::Entry::new();
    entry.set_visibility(!secret);
    body.append(&entry);
    entry
}
fn devices(
    parent: &adw::ApplicationWindow,
    tx: Sender<Work>,
    snapshot: Rc<RefCell<Option<Snapshot>>>,
    cancelled: std::sync::Arc<std::sync::atomic::AtomicBool>,
) {
    let dialog = gtk::Window::builder()
        .title("Devices & Sharing")
        .transient_for(parent)
        .default_width(600)
        .default_height(680)
        .build();
    let body = gtk::Box::new(gtk::Orientation::Vertical, 10);
    body.set_margin_start(20);
    body.set_margin_end(20);
    body.set_margin_top(20);
    body.set_margin_bottom(20);
    let disclosure = gtk::Label::new(Some(
        "Enabling sharing sends new text and image clips encrypted to paired devices through your relay. The relay sees delivery timing, sizes and device identifiers. Existing history is not uploaded.",
    ));
    disclosure.set_wrap(true);
    disclosure.set_xalign(0.);
    body.append(&disclosure);
    let enabled = gtk::CheckButton::with_label("Enable encrypted sharing");
    let restoring_enabled = Rc::new(std::cell::Cell::new(false));
    enabled.set_active(snapshot.borrow().as_ref().is_some_and(|s| s.status.enabled));
    {
        let tx = tx.clone();
        let cancelled = cancelled.clone();
        let restoring_enabled = restoring_enabled.clone();
        enabled.connect_toggled(move |v| {
            if restoring_enabled.get() {
                return;
            }
            cancelled.store(!v.is_active(), Ordering::Release);
            let _ = tx.send(Work::Enabled(v.is_active()));
        });
    }
    body.append(&enabled);
    let name = entry(&body, "This device name", false);
    name.set_text("Ubuntu laptop");
    let relay = entry(
        &body,
        "Relay URL (HTTPS, or loopback for local tests)",
        false,
    );
    let registration = entry(
        &body,
        "Relay provisioning secret (create workspace only)",
        true,
    );
    let create = gtk::Button::with_label("Create private workspace");
    {
        let tx = tx.clone();
        let name = name.clone();
        let cancelled = cancelled.clone();
        create.connect_clicked(move |_| {
            cancelled.store(false, Ordering::Release);
            let _ = tx.send(Work::Create(
                relay.text().to_string(),
                registration.text().to_string(),
                name.text().to_string(),
            ));
            registration.set_text("");
        });
    }
    body.append(&create);
    let code = entry(&body, "Invitation from your other device", true);
    let join = gtk::Button::with_label("Join paired devices");
    {
        let tx = tx.clone();
        let cancelled = cancelled.clone();
        join.connect_clicked(move |_| {
            cancelled.store(false, Ordering::Release);
            let _ = tx.send(Work::Join(code.text().to_string(), name.text().to_string()));
            code.set_text("");
        });
    }
    body.append(&join);
    let invite = gtk::Button::with_label("Add a device — create invitation");
    {
        let tx = tx.clone();
        invite.connect_clicked(move |_| {
            let _ = tx.send(Work::Invite);
        });
    }
    body.append(&invite);
    let request_box = gtk::Box::new(gtk::Orientation::Vertical, 8);
    body.append(&request_box);
    {
        let dialog = dialog.clone();
        let tx = tx.clone();
        let snapshot = snapshot.clone();
        let cancelled = cancelled.clone();
        let mut fingerprint = String::new();
        glib::timeout_add_local(std::time::Duration::from_millis(500), move || {
            if !dialog.is_visible() {
                return glib::ControlFlow::Break;
            }
            if let Some(snapshot) = snapshot.borrow().as_ref() {
                let paused = cancelled.load(Ordering::Acquire);
                let sharing = snapshot.status.enabled && !paused;
                // Only reflect a persisted value agreeing with current intent;
                // an older worker snapshot cannot reverse a pending gesture.
                if snapshot.status.enabled != paused
                    && enabled.is_active() != snapshot.status.enabled
                {
                    restoring_enabled.set(true);
                    enabled.set_active(snapshot.status.enabled);
                    restoring_enabled.set(false);
                }
                invite.set_sensitive(sharing);
                let current = format!(
                    "{}:{}:{}",
                    snapshot
                        .status
                        .requests
                        .iter()
                        .map(|r| r.id.as_str())
                        .collect::<Vec<_>>()
                        .join(","),
                    snapshot
                        .status
                        .members
                        .iter()
                        .map(|m| m.id.as_str())
                        .collect::<Vec<_>>()
                        .join(","),
                    sharing
                );
                if current != fingerprint {
                    fingerprint = current;
                    while let Some(child) = request_box.first_child() {
                        request_box.remove(&child);
                    }
                    let label = gtk::Label::new(Some(&format!(
                        "This device: {}",
                        snapshot.status.device_id
                    )));
                    label.set_selectable(true);
                    request_box.append(&label);
                    for request in &snapshot.status.requests {
                        let label = gtk::Label::new(Some(&format!(
                            "Compare on both devices: {}",
                            request.words
                        )));
                        label.set_wrap(true);
                        request_box.append(&label);
                        let button = gtk::Button::with_label("Codes match — approve device");
                        button.set_sensitive(sharing);
                        let tx = tx.clone();
                        let id = request.id.clone();
                        let words = request.words.clone();
                        button.connect_clicked(move |_| {
                            let _ = tx.send(Work::Approve(id.clone(), words.clone()));
                        });
                        request_box.append(&button);
                    }
                    if snapshot.status.is_owner {
                        for member in &snapshot.status.members {
                            if member.id != snapshot.status.device_id {
                                let button = gtk::Button::with_label(&format!(
                                    "Remove device {}",
                                    member.id
                                ));
                                button.set_sensitive(sharing);
                                let tx = tx.clone();
                                let id = member.id.clone();
                                button.connect_clicked(move |_| {
                                    let _ = tx.send(Work::Remove(id.clone()));
                                });
                                request_box.append(&button);
                            }
                        }
                    }
                }
            }
            glib::ControlFlow::Continue
        });
    }
    let disconnect = gtk::Button::with_label("Disconnect and reset pairing…");
    disconnect.add_css_class("destructive-action");
    {
        let dialog = dialog.clone();
        let tx = tx.clone();
        let cancelled = cancelled.clone();
        disconnect.connect_clicked(move |_| {
            let confirmation = gtk::MessageDialog::builder()
                .transient_for(&dialog).modal(true)
                .message_type(gtk::MessageType::Warning)
                .buttons(gtk::ButtonsType::OkCancel)
                .text("Disconnect and keep local history?")
                .secondary_text("Pending shares are cancelled and pairing keys replaced. History stays here. Remove this device on the owner to revoke its old membership. Disconnecting an owner loses workspace administration; create a new workspace to pair again.")
                .build();
            let tx = tx.clone();
            let cancelled = cancelled.clone();
            confirmation.connect_response(move |dialog, response| {
                if response == gtk::ResponseType::Ok {
                    cancelled.store(true, Ordering::Release);
                    let _ = tx.send(Work::Disconnect);
                }
                dialog.close();
            });
            confirmation.present();
        });
    }
    body.append(&disconnect);
    let close = gtk::Button::with_label("Close");
    {
        let dialog = dialog.clone();
        close.connect_clicked(move |_| dialog.close());
    }
    body.append(&close);
    let scroll = gtk::ScrolledWindow::new();
    scroll.set_child(Some(&body));
    let header = adw::HeaderBar::new();
    header.set_title_widget(Some(&gtk::Label::new(Some("Devices & Sharing"))));
    dialog.set_titlebar(Some(&header));
    dialog.set_child(Some(&scroll));
    dialog.present();
}
