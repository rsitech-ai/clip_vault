use crate::{
    Member, OwnerIdentity, Result, SyncError,
    identity::{decode, encode},
};
use ed25519_dalek::{Signature, Signer, VerifyingKey};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SignedRoster {
    pub version: u32,
    pub workspace: String,
    pub epoch: u64,
    pub members: Vec<Member>,
    pub signature: String,
}
impl SignedRoster {
    fn message(&self) -> Result<Vec<u8>> {
        Ok(serde_json::to_vec(&(
            "ClipVault membership v1",
            self.version,
            &self.workspace,
            self.epoch,
            &self.members,
        ))?)
    }
    pub fn sign(
        workspace: &str,
        epoch: u64,
        members: Vec<Member>,
        owner: &OwnerIdentity,
    ) -> Result<Self> {
        let mut roster = Self {
            version: 1,
            workspace: workspace.into(),
            epoch,
            members,
            signature: String::new(),
        };
        roster.signature = encode(owner.signing_key().sign(&roster.message()?).to_bytes());
        roster.verify(&owner.public_key(), epoch)?;
        Ok(roster)
    }
    pub fn verify(&self, owner_public_key: &str, min_epoch: u64) -> Result<()> {
        if self.version != 1
            || self.epoch == 0
            || self.epoch < min_epoch
            || self.workspace.is_empty()
            || self.workspace.len() > 64
            || self.members.is_empty()
            || self.members.len() > 16
        {
            return Err(SyncError::Membership);
        }
        let mut ids = std::collections::HashSet::new();
        let mut keys = std::collections::HashSet::new();
        for member in &self.members {
            member.validate()?;
            if !ids.insert(&member.id) || !keys.insert(&member.public_key) {
                return Err(SyncError::Membership);
            }
        }
        let key_bytes: [u8; 32] = decode(owner_public_key)?
            .try_into()
            .map_err(|_| SyncError::Invalid)?;
        let key = VerifyingKey::from_bytes(&key_bytes).map_err(|_| SyncError::Invalid)?;
        let signature =
            Signature::from_slice(&decode(&self.signature)?).map_err(|_| SyncError::Invalid)?;
        key.verify_strict(&self.message()?, &signature)
            .map_err(|_| SyncError::Authentication)
    }
    pub fn member(&self, id: &str) -> Result<&Member> {
        self.members
            .iter()
            .find(|m| m.id == id)
            .ok_or(SyncError::Membership)
    }
}
