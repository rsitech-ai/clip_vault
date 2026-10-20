use axum::{
    body::Body,
    http::{Request, StatusCode},
    middleware::{self, Next},
    response::IntoResponse,
};
use clipvault_sync_core::*;
use clipvault_sync_relay::{RelayStore, router};
use rusqlite::Connection;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn ambiguous_bootstrap_response_recovers_same_workspace_after_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().to_path_buf();
    let fail_response = Arc::new(AtomicBool::new(true));
    let gate = fail_response.clone();
    let app = router(RelayStore::open(&root.join("relay.db"), "registration").unwrap()).layer(
        middleware::from_fn(move |request: Request<Body>, next: Next| {
            let gate = gate.clone();
            async move {
                let bootstrap = request.uri().path() == "/v1/workspaces";
                let response = next.run(request).await;
                if bootstrap && response.status().is_success() && gate.swap(false, Ordering::SeqCst)
                {
                    return StatusCode::SERVICE_UNAVAILABLE.into_response();
                }
                response
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let result = tokio::task::spawn_blocking(move || {
        let key = random_secret();
        let open = || SyncClient::open(DeviceStore::open(&root.join("client.db"), key).unwrap()).unwrap();
        let mut client = open();
        assert!(matches!(client.create_workspace(&endpoint, "registration", "Owner"), Err(SyncError::Relay(503))));
        let db = Connection::open(root.join("relay.db")).unwrap();
        let first_workspace: String = db.query_row("SELECT id FROM workspaces", [], |row| row.get(0)).unwrap();
        drop(client);
        let mut client = open();
        assert!(matches!(client.create_workspace("http://127.0.0.1:1", "registration", "Owner"), Err(SyncError::Invalid)));
        let local = Connection::open(root.join("client.db")).unwrap();
        local.execute_batch("CREATE TRIGGER fail_configuration BEFORE INSERT ON state WHEN NEW.name='configuration' BEGIN SELECT RAISE(ABORT,'injected local commit failure'); END;").unwrap();
        assert!(matches!(client.create_workspace(&endpoint, "registration", "Owner"), Err(SyncError::Storage(_))));
        assert!(client.store.get::<OwnerIdentity>("owner").unwrap().is_none(), "owner and configuration must commit together");
        assert!(client.store.get::<serde_json::Value>("configuration").unwrap().is_none());
        assert!(client.store.get::<serde_json::Value>("pending-bootstrap").unwrap().is_some());
        local.execute_batch("DROP TRIGGER fail_configuration").unwrap();
        drop(client);
        let mut client = open();
        client.create_workspace(&endpoint, "registration", "Owner").unwrap();
        let count: usize = db.query_row("SELECT COUNT(*) FROM workspaces", [], |row| row.get(0)).unwrap();
        assert_eq!(count, 1, "ambiguous setup must not leak another workspace slot");
        assert!(client.status().unwrap().is_owner);
        let roster = client.status().unwrap().members;
        assert_eq!(roster.len(), 1);
        assert_eq!(roster[0].id, client.device_id());
        assert_eq!(client.tick(false).unwrap().state, "Up to date");
        let pending: Option<serde_json::Value> = client.store.get("pending-bootstrap").unwrap();
        assert!(pending.is_none());
        let persisted: serde_json::Value = client.store.get("configuration").unwrap().unwrap();
        assert_eq!(persisted["workspace"], first_workspace);
    }).await;
    server.abort();
    result.unwrap();
}

#[test]
fn bootstrap_replay_is_exact_and_succeeds_even_at_workspace_capacity() {
    let dir = tempfile::tempdir().unwrap();
    let mut relay = RelayStore::open(&dir.path().join("relay.db"), "registration").unwrap();
    let owner = OwnerIdentity::generate();
    let device = DeviceIdentity::generate();
    let first = SignedRoster::sign(
        "original-workspace",
        1,
        vec![device.member("Device")],
        &owner,
    )
    .unwrap();
    let credential = credential_hash("same credential");
    relay
        .bootstrap(first.clone(), &owner.public_key(), &device.id, &credential)
        .unwrap();
    assert!(matches!(
        relay.bootstrap(
            first.clone(),
            &owner.public_key(),
            &device.id,
            &credential_hash("different credential")
        ),
        Err(SyncError::Membership)
    ));
    for i in 1..16 {
        let member = DeviceIdentity::generate();
        let roster = SignedRoster::sign(
            &format!("another-workspace-{i}"),
            1,
            vec![member.member("Device")],
            &owner,
        )
        .unwrap();
        relay
            .bootstrap(
                roster,
                &owner.public_key(),
                &member.id,
                &credential_hash(&secret_string()),
            )
            .unwrap();
    }
    relay
        .bootstrap(first, &owner.public_key(), &device.id, &credential)
        .unwrap();
}
