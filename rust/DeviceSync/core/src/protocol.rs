use crate::{
    DeviceIdentity, Member, Result, SyncError, SyncKem,
    identity::{decode, encode},
};
use hpke::{
    Deserializable, Kem, OpModeR, OpModeS, Serializable, aead::ChaCha20Poly1305, kdf::HkdfSha256,
};
use rand::{SeedableRng, rngs::StdRng};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use zeroize::Zeroizing;

pub const MAX_PAYLOAD_BYTES: usize = 10 * 1024 * 1024;
pub const MAX_WIRE_BYTES: usize = MAX_PAYLOAD_BYTES * 2 + 8192;
pub const MAX_QUEUE_BYTES: u64 = 256 * 1024 * 1024;
pub const DELIVERY_TTL: i64 = 30 * 24 * 60 * 60;
/// Retain sender-visible terminal state for the full 30-day pending lifetime
/// plus a seven-day terminal grace period.
pub const DELIVERY_TERMINAL_RETENTION: i64 = DELIVERY_TTL + 7 * 24 * 60 * 60;
pub const DELIVERY_MAX_RETRY_AGE: i64 = DELIVERY_TERMINAL_RETENTION;
const INFO: &[u8] = b"ClipVault authenticated clip sharing v1";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PortableClip {
    pub kind: String,
    pub text: String,
    pub display_text: String,
    pub captured_at: i64,
    pub source_app: Option<String>,
    pub source_device: Option<String>,
    pub image_png: Option<String>,
    #[serde(default)]
    pub metadata: BTreeMap<String, String>,
}
impl PortableClip {
    pub fn text(text: &str, captured_at: i64) -> Self {
        Self {
            kind: "text".into(),
            text: text.into(),
            display_text: text.into(),
            captured_at,
            source_app: None,
            source_device: None,
            image_png: None,
            metadata: BTreeMap::new(),
        }
    }
    pub fn attachment(file: &crate::FileDescriptor) -> Self {
        let mut metadata = BTreeMap::new();
        metadata.insert("file_id".into(), file.id.clone());
        metadata.insert("file_origin".into(), file.origin.clone());
        metadata.insert("file_size".into(), file.size.to_string());
        metadata.insert("file_sha256".into(), file.sha256.clone());
        Self {
            kind: "attachment".into(),
            text: file.filename.clone(),
            display_text: file.filename.clone(),
            captured_at: file.created_at,
            source_app: None,
            source_device: None,
            image_png: None,
            metadata,
        }
    }
    pub fn validate(&self) -> Result<()> {
        if ![
            "text",
            "code",
            "sql",
            "url",
            "richText",
            "image",
            "error",
            "unknown",
            "attachment",
        ]
        .contains(&self.kind.as_str())
            || self.captured_at < 0
            || self.metadata.len() > 32
        {
            return Err(SyncError::Invalid);
        }
        let wire = Zeroizing::new(serde_json::to_vec(self)?);
        if wire.len() > MAX_WIRE_BYTES {
            return Err(SyncError::TooLarge);
        }
        let mut bytes = self.text.len().saturating_add(self.display_text.len());
        for text in [&self.text, &self.display_text] {
            if sensitive(text) {
                return Err(SyncError::Sensitive);
            }
        }
        for (key, value) in &self.metadata {
            bytes = bytes.saturating_add(key.len()).saturating_add(value.len());
            if sensitive(value) {
                return Err(SyncError::Sensitive);
            }
        }
        for value in [&self.source_app, &self.source_device]
            .into_iter()
            .flatten()
        {
            if value.len() > 256 {
                return Err(SyncError::Invalid);
            }
            bytes = bytes.saturating_add(value.len());
        }
        if self.kind == "richText" {
            let rtf = decode(self.metadata.get("rtf").ok_or(SyncError::Invalid)?)?;
            if !rtf.starts_with(b"{\\rtf") {
                return Err(SyncError::Invalid);
            }
            if sensitive(&String::from_utf8_lossy(&rtf)) {
                return Err(SyncError::Sensitive);
            }
        } else if self.metadata.contains_key("rtf") {
            return Err(SyncError::Invalid);
        }
        if self.kind == "attachment" {
            let id = self.metadata.get("file_id").ok_or(SyncError::Invalid)?;
            let origin = self.metadata.get("file_origin").ok_or(SyncError::Invalid)?;
            let size: u64 = self
                .metadata
                .get("file_size")
                .ok_or(SyncError::Invalid)?
                .parse()
                .map_err(|_| SyncError::Invalid)?;
            let sha256 = self.metadata.get("file_sha256").ok_or(SyncError::Invalid)?;
            let descriptor = crate::FileDescriptor {
                id: id.clone(),
                origin: origin.clone(),
                filename: self.text.clone(),
                size,
                sha256: sha256.clone(),
                chunk_count: size.div_ceil(crate::FILE_CHUNK_BYTES as u64) as u32,
                created_at: self.captured_at,
            };
            if self.metadata.len() != 4
                || self.display_text != self.text
                || self.image_png.is_some()
                || self.source_app.is_some()
            {
                return Err(SyncError::Invalid);
            }
            descriptor.validate()?;
        }
        match &self.image_png {
            Some(image) => {
                if self.kind != "image" || image.len() > MAX_WIRE_BYTES {
                    return Err(SyncError::Invalid);
                }
                let data = decode(image)?;
                validate_png(&data)?;
                bytes = bytes.saturating_add(data.len());
            }
            None if self.kind == "image" => return Err(SyncError::Invalid),
            None => {}
        }
        if bytes > MAX_PAYLOAD_BYTES {
            return Err(SyncError::TooLarge);
        }
        if self.text.is_empty() && self.image_png.is_none() {
            return Err(SyncError::Invalid);
        }
        Ok(())
    }
    pub fn digest(&self) -> Result<String> {
        // Only content, not device-specific source context, participates in grouping.
        Ok(hex::encode(Sha256::digest(serde_json::to_vec(&(
            &self.kind,
            &self.text,
            &self.image_png,
            &self.metadata,
        ))?)))
    }
}

pub fn sensitive(text: &str) -> bool {
    static RULES: std::sync::OnceLock<regex::RegexSet> = std::sync::OnceLock::new();
    RULES
        .get_or_init(|| {
            regex::RegexSet::new([
        r"(?i)clipvault-pair-v1:[A-Za-z0-9+/=]+",
        r"(?i)-----BEGIN [A-Z ]*PRIVATE KEY-----",
        r"(?i)\bsk-(proj-)?[A-Za-z0-9_-]{20,}\b",
        r"(?i)\b(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}\b",
        r"(?i)\b(A3T[A-Z0-9]|AKIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA)[A-Z0-9]{16}\b",
        r"(?i)\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b",
        r#"(?i)\b(password|passwd|pwd|secret|token|api[_-]?key)\s*[:=]\s*['\"]?[^'\"\s]{10,}"#,
    ]).expect("constant sensitive-content patterns are valid")
        })
        .is_match(text.trim())
}

pub fn validate_png(data: &[u8]) -> Result<()> {
    if data.len() < 33
        || &data[..8] != b"\x89PNG\r\n\x1a\n"
        || &data[12..16] != b"IHDR"
        || data[8..12] != [0, 0, 0, 13]
    {
        return Err(SyncError::Invalid);
    }
    let width = u32::from_be_bytes(data[16..20].try_into().map_err(|_| SyncError::Invalid)?);
    let height = u32::from_be_bytes(data[20..24].try_into().map_err(|_| SyncError::Invalid)?);
    if width == 0
        || height == 0
        || width > 16384
        || height > 16384
        || u64::from(width) * u64::from(height) > 40_000_000
    {
        return Err(SyncError::TooLarge);
    }
    let mut reader =
        image::ImageReader::with_format(std::io::Cursor::new(data), image::ImageFormat::Png);
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(16384);
    limits.max_image_height = Some(16384);
    limits.max_alloc = Some(160_000_000);
    reader.limits(limits);
    reader.decode().map_err(|_| SyncError::Invalid)?;
    Ok(())
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ClipEvent {
    pub id: String,
    pub origin: String,
    pub sequence: u64,
    pub clip: PortableClip,
}
impl ClipEvent {
    pub fn new(origin: String, sequence: u64, clip: PortableClip) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            origin,
            sequence,
            clip,
        }
    }
    pub fn validate(&self) -> Result<()> {
        if uuid::Uuid::parse_str(&self.id).is_err()
            || uuid::Uuid::parse_str(&self.origin).is_err()
            || self.sequence == 0
            || self.sequence > i64::MAX as u64
        {
            return Err(SyncError::Invalid);
        }
        self.clip.validate()
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EnvelopeHeader {
    pub version: u32,
    pub workspace: String,
    pub sender: String,
    pub recipient: String,
    pub event: String,
    pub sequence: u64,
    pub epoch: u64,
    pub message_type: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Envelope {
    pub header: EnvelopeHeader,
    pub encapsulated_key: String,
    pub ciphertext: String,
}

pub fn seal_event(
    workspace: &str,
    epoch: u64,
    sender: &DeviceIdentity,
    recipient: &Member,
    event: &ClipEvent,
) -> Result<Envelope> {
    event.validate()?;
    if event.clip.kind == "attachment" {
        return Err(SyncError::Invalid);
    }
    recipient.validate()?;
    if event.origin != sender.id || epoch == 0 || workspace.is_empty() || workspace.len() > 64 {
        return Err(SyncError::Invalid);
    }
    let header = EnvelopeHeader {
        version: 1,
        workspace: workspace.into(),
        sender: sender.id.clone(),
        recipient: recipient.id.clone(),
        event: event.id.clone(),
        sequence: event.sequence,
        epoch,
        message_type: "clip".into(),
    };
    let aad = serde_json::to_vec(&header)?;
    let (enc, mut context) = hpke::setup_sender::<ChaCha20Poly1305, HkdfSha256, SyncKem, _>(
        &OpModeS::Auth(sender.keypair()?),
        &recipient.key()?,
        INFO,
        &mut StdRng::from_os_rng(),
    )
    .map_err(|_| SyncError::Authentication)?;
    let plaintext = Zeroizing::new(serde_json::to_vec(event)?);
    let ciphertext = context
        .seal(&plaintext, &aad)
        .map_err(|_| SyncError::Authentication)?;
    Ok(Envelope {
        header,
        encapsulated_key: encode(enc.to_bytes()),
        ciphertext: encode(ciphertext),
    })
}
pub fn open_event(
    workspace: &str,
    recipient: &DeviceIdentity,
    sender: &Member,
    envelope: &Envelope,
) -> Result<ClipEvent> {
    let h = &envelope.header;
    if h.version != 1
        || h.workspace != workspace
        || h.recipient != recipient.id
        || h.sender != sender.id
        || h.epoch == 0
        || h.message_type != "clip"
        || envelope.ciphertext.len() > MAX_WIRE_BYTES
    {
        return Err(SyncError::Invalid);
    }
    let enc = <SyncKem as Kem>::EncappedKey::from_bytes(&decode(&envelope.encapsulated_key)?)
        .map_err(|_| SyncError::Invalid)?;
    let (sk, _) = recipient.keypair()?;
    let mut context = hpke::setup_receiver::<ChaCha20Poly1305, HkdfSha256, SyncKem>(
        &OpModeR::Auth(sender.key()?),
        &sk,
        &enc,
        INFO,
    )
    .map_err(|_| SyncError::Authentication)?;
    let plaintext = Zeroizing::new(
        context
            .open(&decode(&envelope.ciphertext)?, &serde_json::to_vec(h)?)
            .map_err(|_| SyncError::Authentication)?,
    );
    if plaintext.len() > MAX_WIRE_BYTES {
        return Err(SyncError::TooLarge);
    }
    let event: ClipEvent = serde_json::from_slice(&plaintext)?;
    event.validate()?;
    if event.clip.kind == "attachment" {
        return Err(SyncError::Invalid);
    }
    if event.id != h.event || event.origin != h.sender || event.sequence != h.sequence {
        return Err(SyncError::Authentication);
    }
    Ok(event)
}
