use axum::{
    Json,
    body::Body,
    http::Request,
    middleware::{self, Next},
    response::{IntoResponse, Response},
};
use clipvault_sync_core::*;
use clipvault_sync_relay::{RelayStore, router};
use std::sync::{Arc, Mutex};

#[derive(Default)]
struct Cache {
    credential: String,
    roster: Option<SignedRoster>,
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stale_signed_roster_does_not_discard_newer_authenticated_delivery() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().to_path_buf();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let cache = Arc::new(Mutex::new(Cache::default()));
    let server_cache = cache.clone();
    let app = router(RelayStore::open(&path.join("relay.db"), "registration").unwrap()).layer(
        middleware::from_fn(move |request: Request<Body>, next: Next| {
            let cache = server_cache.clone();
            async move {
                let cached = {
                    let cache = cache.lock().unwrap();
                    if request.uri().path() == "/v1/roster"
                        && request
                            .headers()
                            .get("authorization")
                            .and_then(|v| v.to_str().ok())
                            == Some(&format!("Bearer {}", cache.credential))
                    {
                        cache.roster.clone()
                    } else {
                        None
                    }
                };
                if let Some(roster) = cached {
                    return Json(roster).into_response();
                }
                let response: Response = next.run(request).await;
                response
            }
        }),
    );
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    tokio::task::spawn_blocking(move || {
        let open = |name: &str| {
            SyncClient::open(DeviceStore::open(&path.join(name), random_secret()).unwrap()).unwrap()
        };
        let mut owner = open("owner.db");
        let mut receiver = open("receiver.db");
        let mut third = open("third.db");
        owner
            .create_workspace(&endpoint, "registration", "Owner")
            .unwrap();
        let words = receiver
            .join(&owner.create_invite().unwrap(), "Receiver")
            .unwrap();
        let request = owner.pairing_requests().unwrap().remove(0);
        owner.approve(&request.id, &words).unwrap();
        receiver.tick(false).unwrap();
        let old = owner
            .store
            .get::<serde_json::Value>("configuration")
            .unwrap()
            .unwrap();
        let receiver_state = receiver
            .store
            .get::<serde_json::Value>("configuration")
            .unwrap()
            .unwrap();
        let words = third
            .join(&owner.create_invite().unwrap(), "Third")
            .unwrap();
        let request = owner.pairing_requests().unwrap().remove(0);
        owner.approve(&request.id, &words).unwrap();
        owner
            .capture(
                PortableClip::text("must survive a stale roster", unix_time()),
                None,
            )
            .unwrap();
        owner.tick(true).unwrap();
        {
            let mut cache = cache.lock().unwrap();
            cache.credential = receiver_state["credential"].as_str().unwrap().into();
            cache.roster = Some(serde_json::from_value(old["roster"].clone()).unwrap());
        }
        assert_eq!(
            receiver.tick(false).unwrap().state,
            "Waiting for a newer membership record"
        );
        assert!(receiver.store.acknowledgements().unwrap().is_empty());
        assert!(receiver.store.unapplied().unwrap().is_empty());
        cache.lock().unwrap().roster = None;
        receiver.tick(false).unwrap();
        let imports = receiver.store.unapplied().unwrap();
        assert_eq!(imports.len(), 1);
        assert_eq!(imports[0].clip.text, "must survive a stale roster");
        receiver.store.mark_applied(&imports[0].id).unwrap();
        receiver.tick(false).unwrap();
    })
    .await
    .unwrap();
    server.abort();
}
