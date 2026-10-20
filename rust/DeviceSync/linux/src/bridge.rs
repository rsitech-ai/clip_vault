use crate::worker::Work;
use clipvault_linux::policy::CaptureGate;
use clipvault_sync_core::*;
use dbus::{blocking::Connection, channel::MatchingReceiver, message::MatchRule};
use std::{
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
        mpsc::Sender,
    },
    time::Duration,
};

pub fn start(tx: Sender<Work>, capturing: Arc<CaptureGate>) -> Arc<AtomicU64> {
    let connected = Arc::new(AtomicU64::new(0));
    let state = connected.clone();
    std::thread::spawn(move || {
        let Ok(connection) = Connection::new_session() else {
            return;
        };
        if connection
            .request_name("com.rsitech.ClipVault.Capture", false, true, false)
            .is_err()
        {
            return;
        }
        let mut rule = MatchRule::new_method_call();
        rule.path = Some("/com/rsitech/ClipVault/Capture".into());
        rule.interface = Some("com.rsitech.ClipVault.Capture".into());
        connection.start_receive(
            rule,
            Box::new(move |message, connection| {
                let accepted = (|| -> Option<()> {
                    let sender = message.sender()?;
                    let bus = connection.with_proxy(
                        "org.freedesktop.DBus",
                        "/org/freedesktop/DBus",
                        Duration::from_secs(2),
                    );
                    let (owner,): (String,) = bus
                        .method_call("org.freedesktop.DBus", "GetNameOwner", ("org.gnome.Shell",))
                        .ok()?;
                    if &*sender != owner.as_str() {
                        return None;
                    }
                    let (pid,): (u32,) = bus
                        .method_call(
                            "org.freedesktop.DBus",
                            "GetConnectionUnixProcessID",
                            (owner,),
                        )
                        .ok()?;
                    let exe = std::fs::read_link(format!("/proc/{pid}/exe")).ok()?;
                    if exe != Path::new("/usr/bin/gnome-shell") {
                        return None;
                    }
                    state.store(unix_time() as u64, Ordering::Relaxed);
                    if !capturing.enabled() {
                        return None;
                    }
                    match message.member()?.as_ref() {
                        "Heartbeat" => {}
                        "Capture" => {
                            let (body,): (String,) = message.read1().ok().map(|body| (body,))?;
                            if body.len() > MAX_WIRE_BYTES {
                                return None;
                            }
                            let clip: PortableClip = serde_json::from_str(&body).ok()?;
                            clip.validate().ok()?;
                            tx.send(Work::Capture(clip, false)).ok()?;
                        }
                        _ => return None,
                    }
                    Some(())
                })()
                .is_some();
                let response = message.method_return().append1(accepted);
                let _ = dbus::channel::Sender::send(connection, response);
                true
            }),
        );
        loop {
            if connection.process(Duration::from_secs(1)).is_err() {
                break;
            }
        }
    });
    connected
}
