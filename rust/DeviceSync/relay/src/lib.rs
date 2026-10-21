//! Opaque authenticated relay; no client private keys are accepted.
mod store;
use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Path, Query, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use clipvault_sync_core::*;
use serde::Deserialize;
use std::sync::{Arc, Mutex};
pub use store::*;

type Shared = Arc<Mutex<RelayStore>>;
struct Error(SyncError);
impl From<SyncError> for Error {
    fn from(e: SyncError) -> Self {
        Self(e)
    }
}
impl IntoResponse for Error {
    fn into_response(self) -> Response {
        let status = match self.0 {
            SyncError::Authentication => StatusCode::UNAUTHORIZED,
            SyncError::Capacity => StatusCode::INSUFFICIENT_STORAGE,
            SyncError::Membership => StatusCode::FORBIDDEN,
            SyncError::Storage(_) | SyncError::Io(_) => StatusCode::INTERNAL_SERVER_ERROR,
            _ => StatusCode::BAD_REQUEST,
        };
        (status, Json(serde_json::json!({"error":status.as_u16()}))).into_response()
    }
}
fn token(h: &HeaderMap) -> std::result::Result<&str, Error> {
    h.get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .filter(|v| v.len() <= 256)
        .ok_or(Error(SyncError::Authentication))
}
fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |v| v.as_secs() as i64)
}
fn lock(state: &Shared) -> std::result::Result<std::sync::MutexGuard<'_, RelayStore>, Error> {
    state.lock().map_err(|_| Error(SyncError::Invalid))
}
/// Keep small delivery/ACK responses from waiting behind Nagle's algorithm.
pub fn low_latency_listener(
    listener: tokio::net::TcpListener,
) -> impl axum::serve::Listener<Io = tokio::net::TcpStream, Addr = std::net::SocketAddr> {
    use axum::serve::ListenerExt;
    listener.tap_io(|stream| {
        if let Err(error) = stream.set_nodelay(true) {
            eprintln!("ClipVault relay could not set TCP_NODELAY: {error}");
        }
    })
}

pub fn router(store: RelayStore) -> Router {
    let state = Arc::new(Mutex::new(store));
    let maintenance_state = state.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(60));
        interval.tick().await;
        loop {
            interval.tick().await;
            if let Ok(mut store) = maintenance_state.lock()
                && store.maintain(now()).is_err()
            {
                eprintln!("ClipVault relay maintenance failed");
            }
        }
    });
    Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/v1/workspaces", post(bootstrap))
        .route("/v1/roster", get(roster).post(publish))
        .route("/v1/capabilities", get(capabilities).post(set_capabilities))
        .route("/v1/invites", post(invite))
        .route(
            "/v1/joins",
            get(joins).post(join).layer(DefaultBodyLimit::max(8 * 1024)),
        )
        .route("/v1/invites/{id}/consume", post(consume))
        .route("/v1/mailbox", get(mailbox).post(submit))
        .route("/v1/ack/{cursor}", post(ack))
        .route("/v1/reject/{cursor}", post(reject))
        .route("/v1/delivery/{event}/{recipient}", get(status))
        .layer(DefaultBodyLimit::max(MAX_WIRE_BYTES + 4096))
        .with_state(state)
}
#[derive(Deserialize)]
struct Bootstrap {
    roster: SignedRoster,
    owner_key: String,
    owner_device: String,
    token_hash: String,
}
async fn bootstrap(
    State(s): State<Shared>,
    h: HeaderMap,
    Json(b): Json<Bootstrap>,
) -> std::result::Result<Json<bool>, Error> {
    let mut s = lock(&s)?;
    if !s.registration_allowed(token(&h)?) {
        return Err(Error(SyncError::Authentication));
    }
    s.bootstrap(b.roster, &b.owner_key, &b.owner_device, &b.token_hash)?;
    Ok(Json(true))
}
async fn roster(
    State(s): State<Shared>,
    h: HeaderMap,
) -> std::result::Result<Json<SignedRoster>, Error> {
    let s = lock(&s)?;
    let a = s.authenticate(token(&h)?)?;
    Ok(Json(s.roster(&a)?))
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CapabilityUpdate {
    features: Vec<String>,
}
async fn capabilities(
    State(s): State<Shared>,
    h: HeaderMap,
) -> std::result::Result<Json<Vec<DeviceCapabilities>>, Error> {
    let s = lock(&s)?;
    let a = s.authenticate(token(&h)?)?;
    Ok(Json(s.capabilities(&a)?))
}
async fn set_capabilities(
    State(s): State<Shared>,
    h: HeaderMap,
    Json(b): Json<CapabilityUpdate>,
) -> std::result::Result<Json<bool>, Error> {
    let mut s = lock(&s)?;
    let a = s.authenticate(token(&h)?)?;
    s.publish_capabilities(&a, &b.features)?;
    Ok(Json(true))
}
#[derive(Deserialize)]
struct Publication {
    roster: SignedRoster,
    device: Option<String>,
    token_hash: Option<String>,
    invite_id: Option<String>,
    request_id: Option<String>,
    request_digest: Option<String>,
}
async fn publish(
    State(s): State<Shared>,
    h: HeaderMap,
    Json(b): Json<Publication>,
) -> std::result::Result<Json<bool>, Error> {
    let mut s = lock(&s)?;
    let a = s.authenticate(token(&h)?)?;
    let enrollment = match (
        &b.device,
        &b.token_hash,
        &b.invite_id,
        &b.request_id,
        &b.request_digest,
    ) {
        (Some(d), Some(t), Some(i), Some(r), Some(g)) => {
            Some((d.as_str(), t.as_str(), i.as_str(), r.as_str(), g.as_str()))
        }
        (None, None, None, None, None) => None,
        _ => return Err(Error(SyncError::Invalid)),
    };
    s.publish(&a, b.roster, enrollment)?;
    Ok(Json(true))
}
#[derive(Deserialize)]
struct Invitation {
    id: String,
    expires: i64,
}
async fn invite(
    State(s): State<Shared>,
    h: HeaderMap,
    Json(b): Json<Invitation>,
) -> std::result::Result<Json<bool>, Error> {
    let mut s = lock(&s)?;
    let a = s.authenticate(token(&h)?)?;
    s.register_invite(&a, &b.id, b.expires, now())?;
    Ok(Json(true))
}
async fn join(
    State(s): State<Shared>,
    Json(b): Json<JoinRequest>,
) -> std::result::Result<Json<bool>, Error> {
    lock(&s)?.request_join(&b, now())?;
    Ok(Json(true))
}
async fn joins(
    State(s): State<Shared>,
    h: HeaderMap,
) -> std::result::Result<Json<Vec<JoinRequest>>, Error> {
    let s = lock(&s)?;
    let a = s.authenticate(token(&h)?)?;
    Ok(Json(s.joins(&a, now())?))
}
async fn consume(
    State(s): State<Shared>,
    h: HeaderMap,
    Path(id): Path<String>,
) -> std::result::Result<Json<bool>, Error> {
    let mut s = lock(&s)?;
    let a = s.authenticate(token(&h)?)?;
    s.consume_invite(&a, &id)?;
    Ok(Json(true))
}
async fn mailbox(
    State(s): State<Shared>,
    h: HeaderMap,
    Query(query): Query<MailboxQuery>,
) -> std::result::Result<Json<Vec<MailItem>>, Error> {
    let mut s = lock(&s)?;
    let a = s.authenticate(token(&h)?)?;
    Ok(Json(s.mailbox_batch(
        &a,
        now(),
        query.limit.unwrap_or(1),
    )?))
}
#[derive(Deserialize, Default)]
struct MailboxQuery {
    limit: Option<usize>,
}
async fn submit(
    State(s): State<Shared>,
    h: HeaderMap,
    Json(b): Json<Envelope>,
) -> std::result::Result<Json<i64>, Error> {
    let mut s = lock(&s)?;
    let a = s.authenticate(token(&h)?)?;
    Ok(Json(s.submit(&a, &b, now())?))
}
async fn ack(
    State(s): State<Shared>,
    h: HeaderMap,
    Path(cursor): Path<i64>,
) -> std::result::Result<Json<bool>, Error> {
    let mut s = lock(&s)?;
    let a = s.authenticate(token(&h)?)?;
    s.ack(&a, cursor)?;
    Ok(Json(true))
}
async fn status(
    State(s): State<Shared>,
    h: HeaderMap,
    Path((event, recipient)): Path<(String, String)>,
) -> std::result::Result<Json<String>, Error> {
    let mut s = lock(&s)?;
    let a = s.authenticate(token(&h)?)?;
    Ok(Json(s.delivery_status(&a, &event, &recipient, now())?))
}

async fn reject(
    State(s): State<Shared>,
    h: HeaderMap,
    Path(cursor): Path<i64>,
) -> std::result::Result<Json<bool>, Error> {
    let mut s = lock(&s)?;
    let a = s.authenticate(token(&h)?)?;
    s.reject(&a, cursor)?;
    Ok(Json(true))
}
