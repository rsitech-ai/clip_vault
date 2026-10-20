use crate::{Result, SyncError};
use base64::{Engine, engine::general_purpose::STANDARD};
use ed25519_dalek::SigningKey;
use hpke::{Deserializable, Kem, Serializable, kem::X25519HkdfSha256};
use rand::{SeedableRng, rngs::StdRng};
use serde::{Deserialize, Serialize};
use zeroize::{Zeroize, ZeroizeOnDrop};

pub type SyncKem = X25519HkdfSha256;
pub(crate) fn encode(bytes: impl AsRef<[u8]>) -> String {
    STANDARD.encode(bytes)
}
pub(crate) fn decode(value: &str) -> Result<Vec<u8>> {
    STANDARD.decode(value).map_err(|_| SyncError::Invalid)
}
pub fn random_secret() -> [u8; 32] {
    rand::random()
}
pub fn secret_string() -> String {
    encode(random_secret())
}

#[derive(Clone, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
#[serde(deny_unknown_fields)]
pub struct DeviceIdentity {
    #[zeroize(skip)]
    pub id: String,
    private_key: [u8; 32],
}
impl DeviceIdentity {
    pub fn generate() -> Self {
        let (sk, _) = SyncKem::gen_keypair(&mut StdRng::from_os_rng());
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            private_key: sk.to_bytes().into(),
        }
    }
    pub(crate) fn keypair(
        &self,
    ) -> Result<(<SyncKem as Kem>::PrivateKey, <SyncKem as Kem>::PublicKey)> {
        let sk = <SyncKem as Kem>::PrivateKey::from_bytes(&self.private_key)
            .map_err(|_| SyncError::Invalid)?;
        let pk = SyncKem::sk_to_pk(&sk);
        Ok((sk, pk))
    }
    pub fn member(&self, name: &str) -> Member {
        let (_, pk) = self
            .keypair()
            .expect("generated X25519 private key is valid");
        Member {
            id: self.id.clone(),
            name: name.into(),
            public_key: encode(pk.to_bytes()),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Member {
    pub id: String,
    pub name: String,
    pub public_key: String,
}
impl Member {
    pub fn validate(&self) -> Result<()> {
        if uuid::Uuid::parse_str(&self.id).is_err() || self.name.is_empty() || self.name.len() > 128
        {
            return Err(SyncError::Invalid);
        }
        self.key()?;
        Ok(())
    }
    pub(crate) fn key(&self) -> Result<<SyncKem as Kem>::PublicKey> {
        <SyncKem as Kem>::PublicKey::from_bytes(&decode(&self.public_key)?)
            .map_err(|_| SyncError::Invalid)
    }
}

#[derive(Clone, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
pub struct OwnerIdentity {
    secret: [u8; 32],
}
impl OwnerIdentity {
    pub fn generate() -> Self {
        Self {
            secret: random_secret(),
        }
    }
    pub fn public_key(&self) -> String {
        encode(self.signing_key().verifying_key().as_bytes())
    }
    pub(crate) fn signing_key(&self) -> SigningKey {
        SigningKey::from_bytes(&self.secret)
    }
}
