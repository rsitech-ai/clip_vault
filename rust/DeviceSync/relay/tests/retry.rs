use axum::{
    body::Body,
    http::{Request, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
};
use clipvault_sync_core::*;
use clipvault_sync_relay::{RelayStore, router};
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicUsize, Ordering},
};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn outage_backoff_survives_client_reopen_is_capped_and_resets_on_explicit_resume() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().to_path_buf();
    let outage = Arc::new(AtomicBool::new(false));
    let attempts = Arc::new(AtomicUsize::new(0));
    let server_outage = outage.clone();
    let server_attempts = attempts.clone();
    let app = router(RelayStore::open(&path.join("relay.db"), "registration").unwrap()).layer(
        middleware::from_fn(move |request: Request<Body>, next: Next| {
            let outage = server_outage.clone();
            let attempts = server_attempts.clone();
            async move {
                if request.uri().path() == "/v1/roster" {
                    attempts.fetch_add(1, Ordering::SeqCst);
                    if outage.load(Ordering::SeqCst) {
                        return StatusCode::SERVICE_UNAVAILABLE.into_response();
                    }
                }
                let response: Response = next.run(request).await;
                response
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    tokio::task::spawn_blocking(move || {
        let key = random_secret();
        let open =
            || SyncClient::open(DeviceStore::open(&path.join("client.db"), key).unwrap()).unwrap();
        let mut client = open();
        client
            .create_workspace(&endpoint, "registration", "Owner")
            .unwrap();
        attempts.store(0, Ordering::SeqCst);
        outage.store(true, Ordering::SeqCst);
        assert!(matches!(client.tick(false), Err(SyncError::Relay(503))));
        drop(client);
        let mut client = open();
        assert!(client.status().unwrap().state.contains("Retry"));
        assert!(client.tick(false).unwrap().state.contains("Retry"));
        assert_eq!(attempts.load(Ordering::SeqCst), 1);
        client.set_enabled(false).unwrap();
        assert_eq!(client.tick(false).unwrap().state, "Sharing off");
        client.set_enabled(true).unwrap();
        assert!(matches!(client.tick(false), Err(SyncError::Relay(503))));
        assert_eq!(attempts.load(Ordering::SeqCst), 2);
        client
            .store
            .put(
                "retry-backoff",
                &serde_json::json!({"failures": 100, "retry_at": unix_time()-1}),
            )
            .unwrap();
        assert!(matches!(client.tick(false), Err(SyncError::Relay(503))));
        let retry = client
            .store
            .get::<serde_json::Value>("retry-backoff")
            .unwrap()
            .unwrap();
        let delay = retry["retry_at"].as_i64().unwrap() - unix_time();
        assert!((59..=60).contains(&delay));
        outage.store(false, Ordering::SeqCst);
        client.set_enabled(false).unwrap();
        client.set_enabled(true).unwrap();
        assert_eq!(client.tick(false).unwrap().state, "Up to date");
        assert_eq!(
            client
                .store
                .get::<serde_json::Value>("retry-backoff")
                .unwrap()
                .unwrap()["failures"],
            0
        );
    })
    .await
    .unwrap();
    server.abort();
}
