//! Test-only process driver for native macOS/Linux interoperability checks.
//! Inputs and secret-bearing responses travel over private subprocess pipes.
//! This example is never installed with either client or the relay.
use clipvault_sync_core::{DeviceStore, SyncClient};
use clipvault_sync_relay::{RelayStore, router};
use serde_json::{Value, json};
use std::io::{BufRead, Write};

type Error = Box<dyn std::error::Error>;

fn field<'a>(input: &'a Value, name: &str) -> Result<&'a str, Error> {
    input[name].as_str().ok_or_else(|| "missing field".into())
}

fn reply(value: Value) -> Result<(), Error> {
    println!("{value}");
    std::io::stdout().flush()?;
    Ok(())
}

fn command(client: &mut Option<SyncClient>, input: &Value) -> Result<Value, Error> {
    let action = field(input, "action")?;
    if action == "open" {
        let key: [u8; 32] = hex::decode(field(input, "key")?)?
            .try_into()
            .map_err(|_| "invalid test key")?;
        *client = Some(SyncClient::open(DeviceStore::open(
            std::path::Path::new(field(input, "path")?),
            key,
        )?)?);
        return Ok(json!(true));
    }
    let client = client.as_mut().ok_or("open first")?;
    Ok(match action {
        "create" => {
            client.create_workspace(
                field(input, "endpoint")?,
                field(input, "registration")?,
                "macOS interoperability probe",
            )?;
            json!(true)
        }
        "invite" => json!(client.create_invite()?),
        "join" => json!(client.join(field(input, "invite")?, "Linux interoperability probe")?),
        "requests" => json!(client.pairing_requests()?),
        "approve" => {
            client.approve(field(input, "id")?, field(input, "words")?)?;
            json!(true)
        }
        "capture" => json!(client.capture(serde_json::from_value(input["clip"].clone())?, None)?),
        "tick" => json!(client.tick(input["apply"].as_bool().unwrap_or(false))?),
        "status" => json!(client.status()?),
        "history" => json!(client.store.history()?),
        "imports" => json!(client.store.unapplied()?),
        "apply" => {
            client.store.mark_applied(field(input, "id")?)?;
            json!(true)
        }
        "enable" => {
            client.set_enabled(input["enabled"].as_bool().ok_or("missing flag")?)?;
            json!(true)
        }
        "remove" => {
            client.remove_device(field(input, "id")?)?;
            json!(true)
        }
        _ => return Err("unknown test action".into()),
    })
}

fn main() -> Result<(), Error> {
    let mut lines = std::io::stdin().lock().lines();
    if std::env::args().nth(1).as_deref() == Some("server") {
        let input: Value = serde_json::from_str(&lines.next().ok_or("missing configuration")??)?;
        let port = input["port"].as_u64().ok_or("missing port")?;
        let store = RelayStore::open(
            std::path::Path::new(field(&input, "path")?),
            field(&input, "registration")?,
        )?;
        // Container-only test listener; the orchestrator publishes loopback on the host.
        // The production relay independently enforces loopback binding.
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()?
            .block_on(async {
                let listener = tokio::net::TcpListener::bind(("0.0.0.0", port as u16)).await?;
                reply(json!({"ready": true}))?;
                axum::serve(listener, router(store)).await?;
                Ok::<(), Error>(())
            })?;
    } else {
        let mut client = None;
        for line in lines {
            let input: Value = serde_json::from_str(&line?)?;
            match command(&mut client, &input) {
                Ok(value) => reply(json!({"ok": value}))?,
                // Never echo input or error details, which may contain secrets.
                Err(_) => reply(json!({"error": "probe operation failed"}))?,
            }
        }
    }
    Ok(())
}
