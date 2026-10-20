use clipvault_sync_core::{PortableClip, Result};
use std::sync::atomic::{AtomicU64, Ordering};

/// User intent controls clipboard reads independently of the blocking sync worker.
/// A late persisted-consent restore can initialize, but never overwrite, intent.
#[derive(Default)]
pub struct CaptureGate(AtomicU64);
impl CaptureGate {
    pub fn initialized(&self) -> bool {
        self.0.load(Ordering::Acquire) != 0
    }
    pub fn enabled(&self) -> bool {
        self.0.load(Ordering::Acquire) & 3 == 2
    }
    pub fn restore(&self, enabled: bool) {
        let _ = self.0.compare_exchange(
            0,
            if enabled { 2 } else { 1 },
            Ordering::AcqRel,
            Ordering::Acquire,
        );
    }
    /// Capture reads retain this token across awaits; a user consent change
    /// invalidates earlier reads even when capture is immediately enabled again.
    pub fn read_token(&self) -> u64 {
        self.0.load(Ordering::Acquire)
    }
    pub fn permits(&self, token: u64) -> bool {
        token & 3 == 2 && self.read_token() == token
    }
    pub fn set(&self, enabled: bool) {
        let _ = self
            .0
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |value| {
                Some((value.wrapping_add(4) & !3) | if enabled { 2 } else { 1 })
            });
    }
}

#[derive(Default)]
pub struct CapturePolicy {
    pub enabled: bool,
    last_copy: Option<String>,
    last_capture: Option<(String, i64)>,
}
impl CapturePolicy {
    pub fn copied(&mut self, clip: &PortableClip) -> Result<()> {
        self.last_copy = Some(clip.digest()?);
        Ok(())
    }
    pub fn accept(&mut self, clip: &PortableClip, sensitive_marker: bool) -> Result<bool> {
        if !self.enabled || sensitive_marker {
            return Ok(false);
        }
        clip.validate()?;
        if self.last_copy.take().as_deref() == Some(clip.digest()?.as_str()) {
            return Ok(false);
        }
        let digest = clip.digest()?;
        if self.last_capture.as_ref().is_some_and(|(last, time)| {
            last == &digest && clip.captured_at.saturating_sub(*time).abs() <= 1
        }) {
            return Ok(false);
        }
        self.last_capture = Some((digest, clip.captured_at));
        Ok(true)
    }
}
