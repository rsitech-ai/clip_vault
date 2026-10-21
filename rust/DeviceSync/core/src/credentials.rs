//! Device-local credential storage, without plaintext key fallback.
use crate::{Result, SyncError, random_secret};
use zeroize::Zeroizing;

pub fn platform_key(namespace: &str) -> Result<[u8; 32]> {
    if namespace.is_empty() || namespace.len() > 200 {
        return Err(SyncError::Invalid);
    }
    let entry = keyring::Entry::new(namespace, "device-sync-storage-key")
        .map_err(|_| SyncError::Credentials)?;
    match entry.get_secret() {
        Ok(bytes) => Zeroizing::new(bytes)
            .as_slice()
            .try_into()
            .map_err(|_| SyncError::Credentials),
        Err(keyring::Error::NoEntry) => {
            let key = Zeroizing::new(random_secret());
            entry
                .set_secret(&*key)
                .map_err(|_| SyncError::Credentials)?;
            // Read back rather than silently using a key which was never persisted.
            let persisted = Zeroizing::new(entry.get_secret().map_err(|_| SyncError::Credentials)?);
            persisted
                .as_slice()
                .try_into()
                .map_err(|_| SyncError::Credentials)
        }
        Err(_) => Err(SyncError::Credentials),
    }
}
