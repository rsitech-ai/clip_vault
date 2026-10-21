use clipvault_sync_relay::{RelayStore, low_latency_listener, router};
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!(
            "Usage: clipvault-sync-relay <database-path> <loopback-listen-address>\nSet CLIPVAULT_RELAY_REGISTRATION_TOKEN to a random provisioning secret. Use a TLS reverse proxy for remote access."
        );
        std::process::exit(2);
    }
    let address: std::net::SocketAddr = args[2].parse()?;
    if !address.ip().is_loopback() {
        return Err("The relay must bind loopback behind a TLS reverse proxy".into());
    }
    let secret = std::env::var("CLIPVAULT_RELAY_REGISTRATION_TOKEN")
        .map_err(|_| "Missing registration secret")?;
    if secret.len() < 32 {
        return Err("Registration secret must have at least 32 characters".into());
    }
    let store = RelayStore::open(std::path::Path::new(&args[1]), &secret)?;
    let listener = tokio::net::TcpListener::bind(address).await?;
    eprintln!(
        "ClipVault opaque relay listening on {}",
        listener.local_addr()?
    );
    axum::serve(low_latency_listener(listener), router(store))
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}
