//! Portable, authenticated clip sharing. Platform APIs live in clients.
mod attachments;
mod client;
mod credentials;
mod identity;
mod membership;
mod pairing;
mod protocol;
mod store;
pub use attachments::*;
pub use client::*;
pub use credentials::*;
pub use identity::*;
pub use membership::*;
pub use pairing::*;
pub use protocol::*;
pub use store::*;

#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error("Invalid or unsupported sync data")]
    Invalid,
    #[error("Clip exceeds the sharing limit")]
    TooLarge,
    #[error("Attachment is unavailable or invalid")]
    Attachment,
    #[error("Sensitive-looking content is excluded from sharing")]
    Sensitive,
    #[error("Encrypted message authentication failed")]
    Authentication,
    #[error("Device is not a member of this workspace")]
    Membership,
    #[error("Sharing backlog is full; clips remain local")]
    Capacity,
    #[error("Invitation expired or was already used")]
    Invitation,
    #[error("Local sync storage failed")]
    Storage(#[from] rusqlite::Error),
    #[error("Local sync file could not be accessed")]
    Io(#[from] std::io::Error),
    #[error("Sync data could not be decoded")]
    Json(#[from] serde_json::Error),
    #[error("Relay connection failed; delivery remains pending")]
    Network,
    #[error("Relay rejected the request (HTTP {0})")]
    Relay(u16),
    #[error("Unlock the system credential store to use ClipVault sharing")]
    Credentials,
    #[error("Sharing paused")]
    Paused,
    #[error("A paired device needs an update before it can receive files; the local copy is kept")]
    Unsupported,
}
pub type Result<T> = std::result::Result<T, SyncError>;
