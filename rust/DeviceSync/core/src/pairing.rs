use crate::{
    DeviceIdentity, Member, OwnerIdentity, Result, SyncError, SyncKem,
    identity::{decode, encode},
    secret_string, validate_endpoint,
};
use hpke::{
    Deserializable, Kem, OpModeR, OpModeS, PskBundle, Serializable, aead::ChaCha20Poly1305,
    kdf::HkdfSha256,
};
use rand::{SeedableRng, rngs::StdRng};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use zeroize::{Zeroize, Zeroizing};

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PairInvite {
    pub id: String,
    pub workspace: String,
    pub relay: String,
    pub owner_key: String,
    pub owner_device: Member,
    pub secret: String,
    pub expires: i64,
    pub used: bool,
}
impl Drop for PairInvite {
    fn drop(&mut self) {
        self.secret.zeroize();
    }
}
impl PairInvite {
    /// Pairing permits at most 60 seconds of issuer/receiver clock disagreement.
    /// The nominal ten-minute lifetime is measured from `expires`; receivers
    /// accept an invite until `expires + 60` and reject expiries more than
    /// 660 seconds in their future.
    pub const CLOCK_SKEW_SECONDS: i64 = 60;
    pub fn new(
        workspace: &str,
        relay: &str,
        owner: &OwnerIdentity,
        device: &DeviceIdentity,
        now: i64,
    ) -> Self {
        let canonical_relay = url::Url::parse(relay)
            .map(|url| url.origin().ascii_serialization())
            .unwrap_or_else(|_| relay.to_string());
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            workspace: workspace.into(),
            relay: canonical_relay,
            owner_key: owner.public_key(),
            owner_device: device.member("Device"),
            secret: secret_string(),
            expires: now + 600,
            used: false,
        }
    }
    pub fn validate(&self, now: i64) -> Result<()> {
        let relay = validate_endpoint(&self.relay)?;
        let relay_origin = relay.origin().ascii_serialization();
        if self.used
            || now > self.expires.saturating_add(Self::CLOCK_SKEW_SECONDS)
            || self.expires.saturating_sub(now) > 600 + Self::CLOCK_SKEW_SECONDS
            || self.relay != relay_origin
            || decode(&self.secret)?.len() != 32
            || decode(&self.owner_key)?.len() != 32
            || uuid::Uuid::parse_str(&self.id).is_err()
        {
            return Err(SyncError::Invitation);
        }
        self.owner_device.validate()
    }
    pub fn consume(&mut self, now: i64) -> Result<()> {
        self.validate(now)?;
        self.used = true;
        Ok(())
    }
    pub fn code(&self) -> Result<String> {
        Ok(format!(
            "clipvault-pair-v1:{}",
            encode(serde_json::to_vec(self)?)
        ))
    }
    pub fn from_code(code: &str, now: i64) -> Result<Self> {
        if code.len() > 8192 {
            return Err(SyncError::Invalid);
        }
        let invite: Self = serde_json::from_slice(&decode(
            code.strip_prefix("clipvault-pair-v1:")
                .ok_or(SyncError::Invalid)?,
        )?)?;
        invite.validate(now)?;
        Ok(invite)
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JoinRequest {
    pub id: String,
    pub invite_id: String,
    pub device_id: String,
    pub public_key: String,
    pub encapsulated_key: String,
    pub ciphertext: String,
    #[serde(skip)]
    credential: Option<String>,
}
impl Drop for JoinRequest {
    fn drop(&mut self) {
        self.credential.zeroize();
    }
}

#[derive(Serialize, Deserialize)]
pub struct ApprovedJoin {
    pub member: Member,
    pub credential_hash: String,
    pub request_digest: String,
}
impl ApprovedJoin {
    pub fn words(&self) -> String {
        verification_words(&self.request_digest)
    }
}
pub fn credential_hash(token: &str) -> String {
    hex::encode(Sha256::digest(token.as_bytes()))
}
fn verification_words(digest: &str) -> String {
    digest
        .as_bytes()
        .chunks(4)
        .take(6)
        .map(|x| String::from_utf8_lossy(x).into_owned())
        .collect::<Vec<_>>()
        .join(" ")
}
impl JoinRequest {
    pub fn validate_shape(&self) -> Result<()> {
        if uuid::Uuid::parse_str(&self.id).is_err()
            || uuid::Uuid::parse_str(&self.invite_id).is_err()
            || uuid::Uuid::parse_str(&self.device_id).is_err()
            || self.public_key.len() > 64
            || self.encapsulated_key.len() != 44
            || self.ciphertext.is_empty()
            || self.ciphertext.len() > 4096
        {
            return Err(SyncError::Invalid);
        }
        if decode(&self.public_key)?.len() != 32
            || decode(&self.encapsulated_key)?.len() != 32
            || decode(&self.ciphertext)?.len() > 3072
        {
            return Err(SyncError::Invalid);
        }
        Ok(())
    }
    fn aad(&self, invite: &PairInvite) -> Result<Vec<u8>> {
        Ok(serde_json::to_vec(&(
            "ClipVault pair v1",
            &invite.id,
            &invite.workspace,
            &invite.owner_key,
            &invite.owner_device,
            &invite.relay,
            invite.expires,
            &self.id,
            &self.device_id,
            &self.public_key,
        ))?)
    }
    pub fn create(invite: &PairInvite, identity: &DeviceIdentity, now: i64) -> Result<Self> {
        invite.validate(now)?;
        let credential = secret_string();
        let mut request = Self {
            id: uuid::Uuid::new_v4().to_string(),
            invite_id: invite.id.clone(),
            device_id: identity.id.clone(),
            public_key: identity.member("Device").public_key,
            encapsulated_key: String::new(),
            ciphertext: String::new(),
            credential: Some(credential.clone()),
        };
        let secret = Zeroizing::new(decode(&invite.secret)?);
        let psk =
            PskBundle::new(&secret, invite.id.as_bytes()).map_err(|_| SyncError::Invitation)?;
        let (enc, mut context) = hpke::setup_sender::<ChaCha20Poly1305, HkdfSha256, SyncKem, _>(
            &OpModeS::AuthPsk(identity.keypair()?, psk),
            &invite.owner_device.key()?,
            b"ClipVault enrollment v1",
            &mut StdRng::from_os_rng(),
        )
        .map_err(|_| SyncError::Authentication)?;
        let plaintext = Zeroizing::new(serde_json::to_vec(&(
            identity.member("Device"),
            credential_hash(&credential),
        ))?);
        request.ciphertext = encode(
            context
                .seal(&plaintext, &request.aad(invite)?)
                .map_err(|_| SyncError::Authentication)?,
        );
        request.encapsulated_key = encode(enc.to_bytes());
        Ok(request)
    }
    pub fn credential(&self) -> Result<&str> {
        self.credential.as_deref().ok_or(SyncError::Invalid)
    }
    pub fn digest(&self) -> String {
        credential_hash(&format!(
            "{}:{}:{}:{}:{}:{}",
            self.id,
            self.invite_id,
            self.device_id,
            self.public_key,
            self.encapsulated_key,
            self.ciphertext
        ))
    }
    pub fn words(&self) -> String {
        verification_words(&self.digest())
    }
    pub fn open(
        &self,
        invite: &PairInvite,
        owner_device: &DeviceIdentity,
        now: i64,
    ) -> Result<ApprovedJoin> {
        invite.validate(now)?;
        self.validate_shape()?;
        if self.invite_id != invite.id || owner_device.id != invite.owner_device.id {
            return Err(SyncError::Invalid);
        }
        let sender = Member {
            id: self.device_id.clone(),
            name: "Device".into(),
            public_key: self.public_key.clone(),
        };
        sender.validate()?;
        let secret = Zeroizing::new(decode(&invite.secret)?);
        let psk =
            PskBundle::new(&secret, invite.id.as_bytes()).map_err(|_| SyncError::Invitation)?;
        let (sk, _) = owner_device.keypair()?;
        let enc = <SyncKem as Kem>::EncappedKey::from_bytes(&decode(&self.encapsulated_key)?)
            .map_err(|_| SyncError::Invalid)?;
        let mut context = hpke::setup_receiver::<ChaCha20Poly1305, HkdfSha256, SyncKem>(
            &OpModeR::AuthPsk(sender.key()?, psk),
            &sk,
            &enc,
            b"ClipVault enrollment v1",
        )
        .map_err(|_| SyncError::Authentication)?;
        let plaintext = Zeroizing::new(
            context
                .open(&decode(&self.ciphertext)?, &self.aad(invite)?)
                .map_err(|_| SyncError::Authentication)?,
        );
        let (member, credential_hash): (Member, String) = serde_json::from_slice(&plaintext)?;
        if member != sender || credential_hash.len() != 64 {
            return Err(SyncError::Authentication);
        }
        Ok(ApprovedJoin {
            member,
            credential_hash,
            request_digest: self.digest(),
        })
    }
}
