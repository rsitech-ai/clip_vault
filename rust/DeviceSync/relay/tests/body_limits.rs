use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use clipvault_sync_relay::{RelayStore, router};
use tower::ServiceExt;

#[tokio::test]
async fn unauthenticated_pairing_body_is_bounded_before_json_validation() {
    let directory = tempfile::tempdir().unwrap();
    let store = RelayStore::open(&directory.path().join("relay.db"), "registration").unwrap();
    let application = router(store);
    let response = application
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/joins")
                .header("content-type", "application/json")
                .body(Body::from(format!(
                    "{{\"ciphertext\":\"{}\"}}",
                    "A".repeat(16 * 1024)
                )))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
}
