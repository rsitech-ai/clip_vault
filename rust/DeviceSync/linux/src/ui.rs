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
    let add_file = gtk::Button::from_icon_name("document-open-symbolic");
    add_file.set_tooltip_text(Some("Add files up to 100 MiB each"));
    add_file.update_property(&[gtk::accessible::Property::Label("Add file")]);
    header.pack_start(&add_file);
    let settings = gtk::Button::from_icon_name("preferences-system-symbolic");
    settings.set_tooltip_text(Some("Devices and sharing settings"));
    settings.update_property(&[gtk::accessible::Property::Label("Devices and sharing")]);
    header.pack_end(&settings);
    root.append(&header);
    let body = gtk::Box::new(gtk::Orientation::Vertical, 10);
    body.set_margin_start(18);
    body.set_margin_end(18);
    body.set_margin_top(14);
    body.set_margin_bottom(14);
    let capture = gtk::Switch::new();
    capture.set_sensitive(false);
    let capture_row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    let consent = gtk::Label::new(Some("Capture clipboard"));
    consent.set_hexpand(true);
    consent.set_xalign(0.);
    capture_row.append(&consent);
    capture_row.append(&capture);
    body.append(&capture_row);
    let status = gtk::Label::new(Some("Opening encrypted local history…"));
    status.set_xalign(0.);
    status.set_wrap(true);
    body.append(&status);
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
    let more = gtk::Button::with_label("Load older");
    more.add_css_class("flat");
    more.set_halign(gtk::Align::Center);
    more.set_visible(false);
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
        let bridge_state = bridge_state.clone();
        settings.connect_clicked(move |_| {
            devices(
                &window,
                tx.clone(),
                latest.clone(),
                cancelled.clone(),
                x11,
                bridge_state.clone(),
            )
        });
    }
    {
        let window = window.clone();
        let tx = tx.clone();
        add_file.connect_clicked(move |_| add_file_dialog(&window, &tx));
    }
    {
        let latest = latest.clone();
        let list = list.clone();
        let tx = tx.clone();
        let more = more.clone();
        search.connect_search_changed(move |entry| {
            let _ = tx.send(Work::Search(entry.text().to_string()));
            if let Some(snapshot) = latest.borrow().as_ref() {
                more.set_visible(render(&list, snapshot, &entry.text(), &tx) >= 100);
            }
        });
    }
    {
        let latest = latest.clone();
        let list = list.clone();
        let tx = tx.clone();
        let search = search.clone();
        let window = window.clone();
        let more = more.clone();
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
                let capture_state = if capturing.enabled() {
                    "Capturing"
                } else {
                    "Capture off"
                };
                let sharing_state = if snapshot.status.enabled {
                    "Sharing on"
                } else {
                    "Sharing off"
                };
                status.set_text(&snapshot.message.clone().unwrap_or_else(|| {
                    format!(
                        "{capture_state} · {sharing_state} · {} clip{}",
                        snapshot.history.len(),
                        if snapshot.history.len() == 1 { "" } else { "s" }
                    )
                }));
                let _bridge_seen =
                    (unix_time() as u64).saturating_sub(bridge_state.load(Ordering::Relaxed)) < 15;
                let _platform_is_x11 = x11;
                if latest.borrow().as_ref().is_none_or(|old| {
                    old.history != snapshot.history || old.file_transfers != snapshot.file_transfers
                }) {
                    more.set_visible(render(&list, &snapshot, &search.text(), &tx) >= 100);
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
fn render(list: &gtk::ListBox, snapshot: &Snapshot, query: &str, tx: &Sender<Work>) -> usize {
    while let Some(child) = list.first_child() {
        list.remove(&child);
    }
    let mut day = String::new();
    let normalized = search_index_core::normalize_text(query);
    let mut shown = 0usize;
    for event in snapshot.history.iter() {
        if !normalized.is_empty()
            && search_index_core::lexical_score(
                &normalized,
                &format!("{}\n{}", event.clip.display_text, event.clip.text),
            ) <= 0.
        {
            continue;
        }
        shown += 1;
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
        let row = gtk::Box::new(gtk::Orientation::Vertical, 6);
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
            .filter(|line| !line.trim().is_empty())
            .unwrap_or_else(|| {
                if event.clip.kind == "attachment" {
                    "File"
                } else {
                    "Image"
                }
            })
            .chars()
            .take(100)
            .collect::<String>();
        let label = gtk::Label::new(Some(&title));
        label.set_xalign(0.);
        label.set_ellipsize(gtk::pango::EllipsizeMode::End);
        label.add_css_class("heading");
        content.append(&label);
        let snippet_text = event
            .clip
            .text
            .lines()
            .skip(1)
            .collect::<Vec<_>>()
            .join(" ");
        if !snippet_text.trim().is_empty() {
            let snippet =
                gtk::Label::new(Some(&snippet_text.chars().take(240).collect::<String>()));
            snippet.set_xalign(0.);
            snippet.set_wrap(true);
            snippet.set_lines(2);
            snippet.set_ellipsize(gtk::pango::EllipsizeMode::End);
            content.append(&snippet);
        }
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
        let attachment = if event.clip.kind == "attachment" {
            let file_id = event
                .clip
                .metadata
                .get("file_id")
                .cloned()
                .unwrap_or_default();
            let file_size = event
                .clip
                .metadata
                .get("file_size")
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or(0);
            let transfer = snapshot
                .file_transfers
                .iter()
                .find(|state| state.id == file_id);
            let state_text = transfer.map_or_else(
                || format!("{} · Available on this device", format_bytes(file_size)),
                |state| file_status_label(state, file_size, snapshot.status.enabled),
            );
            Some((
                file_id,
                event.clip.display_text.clone(),
                state_text,
                transfer.is_none_or(|state| {
                    !matches!(state.status.as_str(), "receiving" | "verifying")
                }),
            ))
        } else {
            None
        };
        row.append(&content);
        let footer = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        meta.set_hexpand(true);
        footer.append(&meta);
        if let Some((_, _, state_text, _)) = &attachment {
            let state = gtk::Label::new(Some(state_text));
            state.set_xalign(0.);
            state.set_ellipsize(gtk::pango::EllipsizeMode::End);
            state.add_css_class("dim-label");
            footer.append(&state);
        }
        let actions = gtk::Box::new(gtk::Orientation::Horizontal, 4);
        let copy = gtk::Button::from_icon_name("edit-copy-symbolic");
        copy.set_tooltip_text(Some("Copy clip"));
        copy.update_property(&[gtk::accessible::Property::Label("Copy clip")]);
        copy.add_css_class("flat");
        copy.set_visible(attachment.is_none());
        if let Some((file_id, filename, _, can_save)) = &attachment {
            let save = gtk::Button::with_label("Save");
            save.set_visible(*can_save);
            save.add_css_class("flat");
            save.set_tooltip_text(Some("Save file to this device"));
            let parent = list.root().and_downcast::<gtk::Window>();
            let tx = tx.clone();
            let file_id = file_id.clone();
            let filename = filename.clone();
            save.connect_clicked(move |_| {
                if let Some(parent) = parent.as_ref() {
                    save_file_dialog(parent, &tx, &file_id, &filename);
                }
            });
            actions.append(&save);
        }
        let delete = gtk::Button::from_icon_name("user-trash-symbolic");
        delete.set_tooltip_text(Some("Delete clip locally"));
        delete.update_property(&[gtk::accessible::Property::Label("Delete clip locally")]);
        delete.add_css_class("flat");
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
            let parent = list.root().and_downcast::<gtk::Window>();
            delete.connect_clicked(move |_| {
                let Some(parent) = parent.as_ref() else {
                    return;
                };
                let confirmation = gtk::MessageDialog::builder()
                    .transient_for(parent)
                    .modal(true)
                    .message_type(gtk::MessageType::Question)
                    .buttons(gtk::ButtonsType::Cancel)
                    .text("Delete this clip from this device?")
                    .secondary_text("Other paired devices keep their copies.")
                    .build();
                confirmation.add_button("Delete", gtk::ResponseType::Accept);
                let tx = tx.clone();
                let id = id.clone();
                confirmation.connect_response(move |dialog, response| {
                    if response == gtk::ResponseType::Accept {
                        let _ = tx.send(Work::Delete(id.clone()));
                    }
                    dialog.close();
                });
                confirmation.present();
            });
        }
        actions.append(&copy);
        actions.append(&delete);
        footer.append(&actions);
        row.append(&footer);
        list.append(&row);
    }
    if snapshot.history.is_empty() {
        let label = gtk::Label::new(Some("No clips yet"));
        label.set_wrap(true);
        label.set_margin_top(30);
        label.set_margin_bottom(30);
        label.add_css_class("title-3");
        list.append(&label);
    } else if shown == 0 {
        let label = gtk::Label::new(Some("No clips match this search"));
        label.set_margin_top(30);
        label.set_margin_bottom(30);
        label.add_css_class("dim-label");
        list.append(&label);
    }
    shown
}
fn format_bytes(bytes: u64) -> String {
    if bytes >= 1024 * 1024 {
        format!("{:.1} MB", bytes as f64 / (1024. * 1024.))
    } else if bytes >= 1024 {
        format!("{:.0} KB", bytes as f64 / 1024.)
    } else {
        format!("{bytes} B")
    }
}
fn file_status_label(state: &FileTransferStatus, size: u64, sharing: bool) -> String {
    let size = format_bytes(size);
    match state.status.as_str() {
        "ready" => format!("{size} · Ready to save"),
        "staged" if !sharing => format!("{size} · On this device · sharing off"),
        "staged" => format!("{size} · On this device"),
        "pending" => format!("{size} · Waiting to send"),
        "sending" => format!(
            "{size} · Sending · {} of {}",
            format_bytes(state.transferred),
            size
        ),
        "receiving" => format!(
            "{size} · Receiving · {} of {}",
            format_bytes(state.transferred),
            size
        ),
        "verifying" => format!("{size} · Checking file"),
        "unsupported" => format!("{size} · Update the other device to receive files"),
        "paused" => format!("{size} · Paused"),
        "failed" => format!("{size} · Transfer failed"),
        _ => format!("{size} · Transfer status unavailable"),
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
fn add_file_dialog(parent: &adw::ApplicationWindow, tx: &Sender<Work>) {
    #[allow(deprecated)]
    let chooser = gtk::FileChooserNative::new(
        Some("Add files up to 100 MiB each"),
        Some(parent),
        gtk::FileChooserAction::Open,
        Some("Add files"),
        Some("Cancel"),
    );
    chooser.set_select_multiple(true);
    let tx = tx.clone();
    chooser.connect_response(move |chooser, response| {
        if response == gtk::ResponseType::Accept {
            let files = chooser.files();
            let mut paths = Vec::new();
            if files.n_items() > 10 {
                let _ = tx.send(Work::FileSelectionError(
                    "Choose up to 10 files at a time.".into(),
                ));
            } else {
                let mut invalid = false;
                for i in 0..files.n_items() {
                    let Some(file) = files.item(i).and_downcast::<gio::File>() else {
                        let _ = tx.send(Work::FileSelectionError(
                            "Choose local files from this device.".into(),
                        ));
                        invalid = true;
                        break;
                    };
                    let Some(path) = file.path() else {
                        let _ = tx.send(Work::FileSelectionError(
                            "Only files stored on this device can be shared.".into(),
                        ));
                        invalid = true;
                        break;
                    };
                    paths.push(path);
                }
                if !invalid && !paths.is_empty() {
                    let _ = tx.send(Work::StageFiles(paths, None));
                }
            }
        }
        chooser.destroy();
    });
    chooser.show();
    // Native dialogs are not widget children, so keep the GObject alive until
    // the user closes it and GTK emits the response.
    let keepalive = chooser.clone();
    glib::timeout_add_local(std::time::Duration::from_millis(250), move || {
        if keepalive.is_visible() {
            glib::ControlFlow::Continue
        } else {
            glib::ControlFlow::Break
        }
    });
}
fn save_file_dialog(parent: &gtk::Window, tx: &Sender<Work>, id: &str, filename: &str) {
    #[allow(deprecated)]
    let chooser = gtk::FileChooserNative::new(
        Some("Save file from ClipVault"),
        Some(parent),
        gtk::FileChooserAction::Save,
        Some("Save"),
        Some("Cancel"),
    );
    chooser.set_current_name(filename);
    let id = id.to_string();
    let tx = tx.clone();
    chooser.connect_response(move |chooser, response| {
        if response == gtk::ResponseType::Accept
            && let Some(path) = chooser.file().and_then(|file| file.path())
        {
            let _ = tx.send(Work::SaveFile(id.clone(), path));
        }
        chooser.destroy();
    });
    chooser.show();
    let keepalive = chooser.clone();
    glib::timeout_add_local(std::time::Duration::from_millis(250), move || {
        if keepalive.is_visible() {
            glib::ControlFlow::Continue
        } else {
            glib::ControlFlow::Break
        }
    });
}
fn devices(
    parent: &adw::ApplicationWindow,
    tx: Sender<Work>,
    snapshot: Rc<RefCell<Option<Snapshot>>>,
    cancelled: std::sync::Arc<std::sync::atomic::AtomicBool>,
    x11: bool,
    bridge_state: std::sync::Arc<std::sync::atomic::AtomicU64>,
) {
    let dialog = gtk::Window::builder()
        .title("Devices & Sharing")
        .transient_for(parent)
        .default_width(520)
        .default_height(620)
        .build();
    let body = gtk::Box::new(gtk::Orientation::Vertical, 10);
    body.set_margin_start(20);
    body.set_margin_end(20);
    body.set_margin_top(16);
    body.set_margin_bottom(16);
    let enabled = gtk::CheckButton::with_label("Enable encrypted sharing");
    enabled.set_active(snapshot.borrow().as_ref().is_some_and(|s| s.status.enabled));
    let initial_paired = snapshot
        .borrow()
        .as_ref()
        .is_some_and(|s| !s.status.members.is_empty());
    enabled.set_visible(initial_paired);
    let restoring_enabled = Rc::new(std::cell::Cell::new(false));
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

    let paired_box = gtk::Box::new(gtk::Orientation::Vertical, 8);
    paired_box.set_visible(initial_paired);
    let setup_choices = gtk::Box::new(gtk::Orientation::Vertical, 8);
    setup_choices.set_visible(!initial_paired);
    let name_group = gtk::Box::new(gtk::Orientation::Vertical, 6);
    name_group.set_visible(false);
    let name = entry(&name_group, "Device name", false);
    name.set_text("Ubuntu laptop");
    body.append(&name_group);
    let join_choice = gtk::Button::with_label("Join existing devices");
    let create_choice = gtk::Button::with_label("Create a new workspace");
    setup_choices.append(&join_choice);
    setup_choices.append(&create_choice);
    body.append(&setup_choices);

    let join_form = gtk::Box::new(gtk::Orientation::Vertical, 8);
    join_form.set_visible(false);
    let code = entry(&join_form, "Invitation from your other device", true);
    code.set_placeholder_text(Some("Paste the invitation"));
    let join = gtk::Button::with_label("Join paired devices");
    join.add_css_class("suggested-action");
    {
        let tx = tx.clone();
        let name = name.clone();
        let cancelled = cancelled.clone();
        join.connect_clicked(move |_| {
            cancelled.store(false, Ordering::Release);
            let _ = tx.send(Work::Join(code.text().to_string(), name.text().to_string()));
            code.set_text("");
        });
    }
    join_form.append(&join);
    body.append(&join_form);

    let create_form = gtk::Box::new(gtk::Orientation::Vertical, 8);
    create_form.set_visible(false);
    let create_relay = entry(&create_form, "Relay address", false);
    create_relay.set_placeholder_text(Some("https://relay.example"));
    let registration = entry(&create_form, "Workspace setup secret", true);
    let create = gtk::Button::with_label("Create private workspace");
    create.add_css_class("suggested-action");
    {
        let tx = tx.clone();
        let name = name.clone();
        let cancelled = cancelled.clone();
        create.connect_clicked(move |_| {
            cancelled.store(false, Ordering::Release);
            let _ = tx.send(Work::Create(
                create_relay.text().to_string(),
                registration.text().to_string(),
                name.text().to_string(),
            ));
            registration.set_text("");
        });
    }
    create_form.append(&create);
    body.append(&create_form);
    {
        let form = join_form.clone();
        let choices = setup_choices.clone();
        join_choice.connect_clicked(move |_| {
            choices.set_visible(false);
            form.set_visible(true);
        });
    }
    {
        let form = create_form.clone();
        let choices = setup_choices.clone();
        create_choice.connect_clicked(move |_| {
            choices.set_visible(false);
            form.set_visible(true);
        });
    }

    let members_label = gtk::Label::new(None);
    members_label.set_xalign(0.);
    members_label.set_wrap(true);
    paired_box.append(&members_label);
    let invite = gtk::Button::with_label("Add a device");
    invite.add_css_class("suggested-action");
    {
        let tx = tx.clone();
        invite.connect_clicked(move |_| {
            let _ = tx.send(Work::Invite);
        });
    }
    paired_box.append(&invite);
    let request_box = gtk::Box::new(gtk::Orientation::Vertical, 8);
    paired_box.append(&request_box);
    body.append(&paired_box);

    let disclosure = gtk::Expander::new(Some("Privacy and platform details"));
    let disclosure_text = gtk::Label::new(Some(
        "New clips and files are encrypted for paired devices. The relay can see device identifiers, sizes and delivery timing. Existing history is not uploaded. Sensitive-looking text is filtered. Files are sent only after you add them while sharing is on; received files require an explicit Save.",
    ));
    disclosure_text.set_wrap(true);
    disclosure_text.set_xalign(0.);
    disclosure_text.add_css_class("dim-label");
    let disclosure_body = gtk::Box::new(gtk::Orientation::Vertical, 6);
    let platform_status = gtk::Label::new(None);
    platform_status.set_xalign(0.);
    platform_status.set_wrap(true);
    disclosure_body.append(&platform_status);
    disclosure_body.append(&disclosure_text);
    disclosure.set_child(Some(&disclosure_body));
    body.append(&disclosure);

    let disconnect = gtk::Button::with_label("Disconnect and reset pairing…");
    disconnect.add_css_class("destructive-action");
    disconnect.set_visible(initial_paired);
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
                .secondary_text("Pending shares are cancelled and pairing keys replaced. History stays here. The owner must remove this device to revoke its old membership. Disconnecting an owner removes workspace administration.")
                .build();
            let tx = tx.clone(); let cancelled = cancelled.clone();
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
    {
        let dialog = dialog.clone();
        let snapshot = snapshot.clone();
        let cancelled = cancelled.clone();
        let enabled = enabled.clone();
        let restoring_enabled = restoring_enabled.clone();
        let setup_choices = setup_choices.clone();
        let join_form = join_form.clone();
        let create_form = create_form.clone();
        let name_group = name_group.clone();
        let paired_box = paired_box.clone();
        let members_label = members_label.clone();
        let request_box = request_box.clone();
        let invite = invite.clone();
        let disconnect = disconnect.clone();
        let platform_status = platform_status.clone();
        let bridge_state = bridge_state.clone();
        let mut fingerprint = String::new();
        glib::timeout_add_local(std::time::Duration::from_millis(500), move || {
            if !dialog.is_visible() {
                return glib::ControlFlow::Break;
            }
            if let Some(snapshot) = snapshot.borrow().as_ref() {
                platform_status.set_text(if x11 {
                    "Clipboard capture: X11"
                } else if (unix_time() as u64)
                    .saturating_sub(bridge_state.load(Ordering::Relaxed))
                    < 15
                {
                    "Clipboard capture: GNOME extension connected"
                } else {
                    "Clipboard capture: GNOME extension not connected. Enable it in Extensions after starting a fresh desktop session."
                });
                let paused = cancelled.load(Ordering::Acquire);
                let sharing = snapshot.status.enabled && !paused;
                if snapshot.status.enabled != paused
                    && enabled.is_active() != snapshot.status.enabled
                {
                    restoring_enabled.set(true);
                    enabled.set_active(snapshot.status.enabled);
                    restoring_enabled.set(false);
                }
                let paired = !snapshot.status.members.is_empty();
                enabled.set_visible(paired);
                setup_choices
                    .set_visible(!paired && !join_form.is_visible() && !create_form.is_visible());
                join_form.set_visible(!paired && join_form.is_visible());
                create_form.set_visible(!paired && create_form.is_visible());
                name_group
                    .set_visible(!paired && (join_form.is_visible() || create_form.is_visible()));
                paired_box.set_visible(paired);
                invite.set_sensitive(sharing);
                disconnect.set_visible(paired);
                members_label.set_text(
                    &snapshot
                        .status
                        .members
                        .iter()
                        .map(|m| {
                            if m.id == snapshot.status.device_id {
                                format!("{} · this device", m.name)
                            } else {
                                m.name.clone()
                            }
                        })
                        .collect::<Vec<_>>()
                        .join("\n"),
                );
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
                    for request in &snapshot.status.requests {
                        let label = gtk::Label::new(Some(&format!(
                            "Compare on both devices: {}",
                            request.words
                        )));
                        label.set_wrap(true);
                        label.set_xalign(0.);
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
                                let button =
                                    gtk::Button::with_label(&format!("Remove {}", member.name));
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
    dialog.present();
}
