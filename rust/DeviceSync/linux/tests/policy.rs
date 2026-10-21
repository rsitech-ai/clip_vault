use clipvault_linux::policy::{CaptureGate, CapturePolicy};
use clipvault_sync_core::PortableClip;
#[test]
fn consent_sensitive_markers_and_own_copy_are_excluded() {
    let clip = PortableClip::text("ordinary clip", 1);
    let mut policy = CapturePolicy::default();
    assert!(!policy.accept(&clip, false).unwrap());
    policy.enabled = true;
    assert!(!policy.accept(&clip, true).unwrap());
    assert!(policy.accept(&clip, false).unwrap());
    policy.copied(&clip).unwrap();
    assert!(!policy.accept(&clip, false).unwrap());
    assert!(
        policy
            .accept(&PortableClip::text("new copy", 2), false)
            .unwrap()
    );
    assert!(
        policy
            .accept(&PortableClip::text("password=secretvalue", 2), false)
            .is_err()
    );
}

#[test]
fn capture_off_closes_gate_before_a_blocked_worker_can_acknowledge_or_restore() {
    use std::sync::{Arc, Barrier};
    let gate = Arc::new(CaptureGate::default());
    assert!(!gate.initialized());
    gate.restore(true);
    assert!(gate.enabled());
    let blocked = Arc::new(Barrier::new(2));
    let release = Arc::new(Barrier::new(2));
    let worker = {
        let gate = gate.clone();
        let blocked = blocked.clone();
        let release = release.clone();
        std::thread::spawn(move || {
            blocked.wait();
            release.wait();
            gate.restore(true); // A stale startup result cannot override user OFF.
            assert!(!gate.enabled());
        })
    };
    blocked.wait();
    gate.set(false);
    assert!(gate.initialized());
    assert!(!gate.enabled()); // Clipboard readers stop before worker acknowledgement.
    release.wait();
    worker.join().unwrap();
    gate.set(true);
    assert!(gate.enabled());
}

#[test]
fn a_pending_clipboard_read_cannot_survive_a_consent_cycle() {
    let gate = CaptureGate::default();
    gate.restore(true);
    let read = gate.read_token();
    assert!(gate.permits(read));
    gate.set(false);
    assert!(!gate.permits(read));
    gate.set(true);
    assert!(gate.enabled());
    assert!(!gate.permits(read));
    assert!(gate.permits(gate.read_token()));
}

#[test]
fn concurrent_consent_changes_each_advance_the_generation() {
    use std::sync::{Arc, Barrier};
    let gate = Arc::new(CaptureGate::default());
    gate.restore(true);
    let old_read = gate.read_token();
    let start = Arc::new(Barrier::new(8));
    let workers: Vec<_> = (0..8)
        .map(|_| {
            let gate = gate.clone();
            let start = start.clone();
            std::thread::spawn(move || {
                start.wait();
                for _ in 0..1_000 {
                    gate.set(true);
                }
            })
        })
        .collect();
    for worker in workers {
        worker.join().unwrap();
    }
    assert_eq!(gate.read_token() >> 2, 8_000);
    assert!(gate.enabled());
    assert!(!gate.permits(old_read));
    assert!(gate.permits(gate.read_token()));
}
