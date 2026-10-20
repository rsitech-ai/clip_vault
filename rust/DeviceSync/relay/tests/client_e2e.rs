use axum::{
    body::Body,
    extract::State,
    http::{Request, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
};
use clipvault_sync_core::*;
use clipvault_sync_relay::{RelayStore, router};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

#[derive(Clone)]
struct DropFirstResponses {
    join: Arc<AtomicBool>,
    approval: Arc<AtomicBool>,
}

async fn drop_first_response(
    State(flags): State<DropFirstResponses>,
    request: Request<Body>,
    next: Next,
) -> Response {
    let path = request.uri().path().to_string();
    let method = request.method().clone();
    let response = next.run(request).await;
    let should_drop = if method == axum::http::Method::POST && path == "/v1/joins" {
        flags.join.swap(false, Ordering::SeqCst)
    } else if method == axum::http::Method::POST && path == "/v1/roster" {
        flags.approval.swap(false, Ordering::SeqCst)
    } else {
        false
    };
    if should_drop {
        StatusCode::SERVICE_UNAVAILABLE.into_response()
    } else {
        response
    }
}

#[derive(Clone)]
struct FailPairOperations {
    join_posts: Arc<std::sync::atomic::AtomicUsize>,
    approval_posts: Arc<std::sync::atomic::AtomicUsize>,
}

async fn fail_first_pair_operations(
    State(counts): State<FailPairOperations>,
    request: Request<Body>,
    next: Next,
) -> Response {
    if request.method() == axum::http::Method::POST {
        let counter = match request.uri().path() {
            "/v1/joins" => Some(&counts.join_posts),
            "/v1/roster" => Some(&counts.approval_posts),
            _ => None,
        };
        if counter.is_some_and(|counter| counter.fetch_add(1, Ordering::SeqCst) == 0) {
            return StatusCode::BAD_REQUEST.into_response();
        }
    }
    next.run(request).await
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn terminal_pairing_failures_allow_a_new_invite_and_approval() {
    let dir = tempfile::tempdir().unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let relay = RelayStore::open(&dir.path().join("relay.db"), "registration").unwrap();
    let failures = FailPairOperations {
        join_posts: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
        approval_posts: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
    };
    let app = router(relay).layer(middleware::from_fn_with_state(
        failures,
        fail_first_pair_operations,
    ));
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let path = dir.path().to_path_buf();
    tokio::task::spawn_blocking(move || {
        let owner_key = random_secret();
        let second_owner_key = random_secret();
        let guest_key = random_secret();
        let mut owner =
            SyncClient::open(DeviceStore::open(&path.join("owner.db"), owner_key).unwrap())
                .unwrap();
        let mut second_owner = SyncClient::open(
            DeviceStore::open(&path.join("second-owner.db"), second_owner_key).unwrap(),
        )
        .unwrap();
        let mut guest =
            SyncClient::open(DeviceStore::open(&path.join("guest.db"), guest_key).unwrap())
                .unwrap();
        owner
            .create_workspace(&endpoint, "registration", "Owner")
            .unwrap();
        second_owner
            .create_workspace(&endpoint, "registration", "Second owner")
            .unwrap();

        let first_invite = owner.create_invite().unwrap();
        assert!(guest.join(&first_invite, "Guest").is_err());
        assert!(owner.pairing_requests().unwrap().is_empty());

        let second_invite = second_owner.create_invite().unwrap();
        assert!(guest.join(&second_invite, "Guest").is_ok());
        assert_eq!(second_owner.create_invite().unwrap(), second_invite);
        let request = second_owner.pairing_requests().unwrap().remove(0);
        assert!(second_owner.approve(&request.id, &request.words).is_err());
        assert_eq!(second_owner.pairing_requests().unwrap().len(), 1);
        second_owner.approve(&request.id, &request.words).unwrap();
        guest.tick(true).unwrap();
        assert!(guest.status().unwrap().members.len() == 2);
    })
    .await
    .unwrap();
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn disabled_pending_join_stays_disabled_after_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let relay = RelayStore::open(&dir.path().join("relay.db"), "registration").unwrap();
    let app = router(relay);
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let path = dir.path().to_path_buf();
    tokio::task::spawn_blocking(move || {
        let owner_key = random_secret();
        let guest_key = random_secret();
        let mut owner =
            SyncClient::open(DeviceStore::open(&path.join("owner.db"), owner_key).unwrap())
                .unwrap();
        let mut guest =
            SyncClient::open(DeviceStore::open(&path.join("guest.db"), guest_key).unwrap())
                .unwrap();
        owner
            .create_workspace(&endpoint, "registration", "Owner")
            .unwrap();
        let invite = owner.create_invite().unwrap();
        guest.join(&invite, "Guest").unwrap();
        guest.set_enabled(false).unwrap();
        drop(guest);

        let mut reopened =
            SyncClient::open(DeviceStore::open(&path.join("guest.db"), guest_key).unwrap())
                .unwrap();
        assert!(!reopened.sharing_enabled());
        let signal = Arc::new(AtomicBool::new(true));
        reopened.set_cancel_signal(signal);
        assert!(matches!(reopened.set_enabled(true), Err(SyncError::Paused)));
        assert!(!reopened.sharing_enabled());
    })
    .await
    .unwrap();
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn disconnect_can_pair_again_without_losing_local_history() {
    let dir = tempfile::tempdir().unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let relay = RelayStore::open(&dir.path().join("relay.db"), "registration").unwrap();
    let app = router(relay);
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let path = dir.path().to_path_buf();
    tokio::task::spawn_blocking(move || {
        let first_owner_key = random_secret();
        let second_owner_key = random_secret();
        let guest_key = random_secret();
        let mut first_owner = SyncClient::open(
            DeviceStore::open(&path.join("first-owner.db"), first_owner_key).unwrap(),
        )
        .unwrap();
        let mut second_owner = SyncClient::open(
            DeviceStore::open(&path.join("second-owner.db"), second_owner_key).unwrap(),
        )
        .unwrap();
        let mut guest =
            SyncClient::open(DeviceStore::open(&path.join("guest.db"), guest_key).unwrap())
                .unwrap();
        first_owner
            .create_workspace(&endpoint, "registration", "First owner")
            .unwrap();
        let first_invite = first_owner.create_invite().unwrap();
        let words = guest.join(&first_invite, "Guest").unwrap();
        let request = first_owner.pairing_requests().unwrap().remove(0);
        first_owner.approve(&request.id, &words).unwrap();
        guest.tick(true).unwrap();
        let old_identity = guest.device_id().to_string();
        guest
            .capture(PortableClip::text("survives disconnect", 1), None)
            .unwrap();
        assert_eq!(guest.disconnect().unwrap(), 1);
        let new_identity = guest.device_id().to_string();
        assert_ne!(new_identity, old_identity);
        assert_eq!(guest.store.pending_count().unwrap(), 0);
        assert_eq!(guest.store.history().unwrap().len(), 1);

        second_owner
            .create_workspace(&endpoint, "registration", "Second owner")
            .unwrap();
        let second_invite = second_owner.create_invite().unwrap();
        let words = guest.join(&second_invite, "Guest").unwrap();
        let request = second_owner.pairing_requests().unwrap().remove(0);
        second_owner.approve(&request.id, &words).unwrap();
        guest.tick(true).unwrap();
        assert_eq!(guest.device_id(), new_identity);
        assert_eq!(guest.store.history().unwrap().len(), 1);
        assert!(guest.store.pending().unwrap().is_empty());
        assert_eq!(guest.status().unwrap().members.len(), 2);
    })
    .await
    .unwrap();
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_clients_pair_share_offline_restart_ack_and_revoke() {
    let dir = tempfile::tempdir().unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let relay =
        RelayStore::open(&dir.path().join("relay.db"), "isolated-registration-token").unwrap();
    let faults = DropFirstResponses {
        join: Arc::new(AtomicBool::new(true)),
        approval: Arc::new(AtomicBool::new(true)),
    };
    let app = router(relay).layer(middleware::from_fn_with_state(faults, drop_first_response));
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let path = dir.path().to_path_buf();
    tokio::task::spawn_blocking(move||{
        let mac_key=random_secret();let linux_key=random_secret();
        let mut mac=SyncClient::open(DeviceStore::open(&path.join("mac.db"),mac_key).unwrap()).unwrap();
        let mut linux=SyncClient::open(DeviceStore::open(&path.join("linux.db"),linux_key).unwrap()).unwrap();
        mac.create_workspace(&endpoint,"isolated-registration-token","Mac").unwrap();
        let code=mac.create_invite().unwrap();
        assert!(linux.join(&code,"Ubuntu").is_err()); // request stored, response dropped
        drop(linux);
        let mut linux=SyncClient::open(DeviceStore::open(&path.join("linux.db"),linux_key).unwrap()).unwrap();
        let words=linux.join(&code,"Ubuntu").unwrap(); // retries the persisted request and credential
        let requests=mac.pairing_requests().unwrap();
        assert_eq!(requests.len(),1);assert_eq!(requests[0].words,words);
        assert!(mac.approve(&requests[0].id,"wrong comparison").is_err());
        assert!(mac.approve(&requests[0].id,&words).is_err()); // publication committed, response dropped
        drop(mac);
        let mut mac=SyncClient::open(DeviceStore::open(&path.join("mac.db"),mac_key).unwrap()).unwrap();
        mac.approve(&requests[0].id,&words).unwrap(); // exact publication recovers success
        assert!(mac.approve(&requests[0].id,&words).is_err());
        linux.tick(true).unwrap();
        let linux_id=linux.device_id().to_string();
        let stale_id = mac.capture(PortableClip::text("stale retry receipt", unix_time()), None).unwrap().unwrap();
        mac.store.mark_target_attempted(&stale_id, &linux_id, unix_time() - DELIVERY_MAX_RETRY_AGE - 1).unwrap();
        let stale_status = mac.tick(true).unwrap();
        assert!(stale_status.state.contains("expired"));
        assert_eq!(mac.store.targets(&stale_id).unwrap().len(), 0);
        drop(linux);
        let event_id=mac.capture(PortableClip::text("Mac → Ubuntu isolated receipt",unix_time()),None).unwrap().unwrap();
        mac.tick(true).unwrap();
        assert_eq!(mac.store.pending().unwrap().len(),1);
        let mut linux=SyncClient::open(DeviceStore::open(&path.join("linux.db"),linux_key).unwrap()).unwrap();
        linux.tick(true).unwrap();linux.tick(true).unwrap();mac.tick(true).unwrap();
        assert_eq!(linux.store.history().unwrap()[0].clip.text,"Mac → Ubuntu isolated receipt");
        assert!(mac.store.pending().unwrap().is_empty());
        mac.tick(true).unwrap();linux.tick(true).unwrap();
        assert_eq!(linux.store.history().unwrap().len(),1);
        linux.capture(PortableClip::text("Ubuntu → Mac isolated receipt",unix_time()),None).unwrap();
        linux.tick(true).unwrap();mac.tick(false).unwrap();
        assert_eq!(mac.store.unapplied().unwrap().len(),1);
        assert!(mac.store.acknowledgements().unwrap().is_empty());
        for event in mac.store.unapplied().unwrap(){mac.store.mark_applied(&event.id).unwrap();}
        mac.tick(false).unwrap();linux.tick(true).unwrap();
        assert!(linux.store.pending().unwrap().is_empty());
        linux.store.delete_local(&event_id).unwrap();
        linux.tick(true).unwrap();assert_eq!(linux.store.history().unwrap().len(),1);
        let image=PortableClip {kind:"image".into(),text:String::new(),display_text:"Image".into(),captured_at:unix_time(),source_app:None,source_device:None,image_png:Some("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGPQbD/+HwAEywJ3k0b7vgAAAABJRU5ErkJggg==".into()),metadata:Default::default()};
        mac.capture(image.clone(),None).unwrap();mac.tick(true).unwrap();linux.tick(true).unwrap();linux.tick(true).unwrap();mac.tick(true).unwrap();
        assert_eq!(linux.store.history().unwrap().iter().filter(|e|e.clip.kind=="image").count(),1);
        linux.capture(image.clone(),None).unwrap();linux.tick(true).unwrap();mac.tick(false).unwrap();
        let imports=mac.store.unapplied().unwrap();assert_eq!(imports[0].clip.image_png,image.image_png);
        for event in imports{mac.store.mark_applied(&event.id).unwrap();}
        mac.tick(false).unwrap();linux.tick(true).unwrap();
        let mut rich=PortableClip::text("Hello world",unix_time());rich.kind="richText".into();rich.metadata.insert("rtf".into(),"e1xydGYxXGFuc2kgSGVsbG8gXGIgd29ybGRcYjB9".into());
        mac.capture(rich.clone(),None).unwrap();mac.tick(true).unwrap();linux.tick(true).unwrap();linux.tick(true).unwrap();mac.tick(true).unwrap();
        let history=linux.store.history().unwrap();let received=history.iter().find(|e|e.clip.kind=="richText").unwrap();assert_eq!(received.clip.metadata.get("rtf"),rich.metadata.get("rtf"));
        mac.remove_device(&linux_id).unwrap();
        assert!(linux.tick(true).is_err());
        mac.set_enabled(false).unwrap();assert_eq!(mac.tick(true).unwrap().state,"Sharing off");
        let raw=std::fs::read(path.join("relay.db")).unwrap();
        assert!(!String::from_utf8_lossy(&raw).contains("isolated receipt"));
        assert!(!String::from_utf8_lossy(&raw).contains("Ubuntu"));
    }).await.unwrap();
    server.abort();
}
