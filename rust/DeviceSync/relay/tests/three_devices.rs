use clipvault_sync_core::*;
use clipvault_sync_relay::{RelayStore, router};
use std::collections::HashSet;

fn tick_and_apply(device: &mut SyncClient) {
    device.tick(false).unwrap();
    // Model the platform's successful import callback. tick(false) waits for
    // this callback before acknowledging an ordinary clip.
    for event in device.store.unapplied().unwrap() {
        device.store.mark_applied(&event.id).unwrap();
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn three_devices_fan_out_text_and_files_and_recover_without_duplicates() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().to_path_buf();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let relay = router(RelayStore::open(&root.join("relay.db"), "registration").unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, relay).await.unwrap() });

    let result = tokio::task::spawn_blocking(move || {
        let keys = [random_secret(), random_secret(), random_secret()];
        let open = || {
            keys.iter()
                .enumerate()
                .map(|(i, key)| {
                    SyncClient::open(
                        DeviceStore::open(&root.join(format!("device-{i}.db")), *key).unwrap(),
                    )
                    .unwrap()
                })
                .collect::<Vec<_>>()
        };
        let mut devices = open();
        devices[0]
            .create_workspace(&endpoint, "registration", "Here")
            .unwrap();
        let names = ["Here", "Razer", "Sii"];
        for (i, name) in [(1, names[1]), (2, names[2])] {
            let invite = devices[0].create_invite().unwrap();
            let words = devices[i].join(&invite, name).unwrap();
            let request = devices[0].pairing_requests().unwrap().remove(0);
            assert_eq!(request.words, words);
            devices[0].approve(&request.id, &words).unwrap();
        }
        let ids: Vec<_> = devices.iter().map(|d| d.device_id().to_owned()).collect();
        assert_eq!(ids.iter().collect::<HashSet<_>>().len(), 3);
        for device in &mut devices {
            let status = device.tick(false).unwrap();
            assert_eq!(status.members.len(), 3);
        }

        let mut expected = Vec::new();
        for (i, device) in devices.iter_mut().enumerate() {
            let mut clip = PortableClip::text(
                &format!("three-device origin {i}: zażółć gęślą jaźń"),
                unix_time(),
            );
            clip.source_device = Some(names[i].to_owned());
            let id = device.capture(clip.clone(), None).unwrap().unwrap();
            expected.push((id, ids[i].clone(), clip));
        }
        for _ in 0..8 {
            for device in &mut devices {
                tick_and_apply(device);
            }
        }
        for (i, device) in devices.iter().enumerate() {
            let history = device.store.history().unwrap();
            assert_eq!(
                history.len(),
                3,
                "receiver {i} must retain all three unique origins"
            );
            for (id, origin, clip) in &expected {
                let event = history.iter().find(|event| &event.id == id).unwrap();
                assert_eq!(&event.origin, origin);
                assert_eq!(&event.clip, clip);
            }
        }

        let mut files = Vec::new();
        for (i, device) in devices.iter_mut().enumerate() {
            let roster_name = device
                .status()
                .unwrap()
                .members
                .into_iter()
                .find(|member| member.id == ids[i])
                .unwrap()
                .name;
            assert_ne!(
                names[i], roster_name,
                "fixture must distinguish local and authenticated roster names"
            );
            let source = root.join(format!("origin-{i}.bin"));
            let bytes: Vec<_> = (0..(1024 * 1024 + 37))
                .map(|n| ((n + i * 31) % 251) as u8)
                .collect();
            std::fs::write(&source, &bytes).unwrap();
            let descriptor = device.stage_file(&source, || false).unwrap();
            let mut clip = PortableClip::attachment(&descriptor);
            clip.source_device = Some(names[i].to_owned());
            let event = device.capture(clip.clone(), None).unwrap().unwrap();
            device.commit_file(&descriptor.id, &event).unwrap();
            expected.push((event, ids[i].clone(), clip));
            files.push((descriptor.id, bytes));
        }
        let mut complete = false;
        for _ in 0..64 {
            for device in &mut devices {
                tick_and_apply(device);
            }
            complete = devices.iter().all(|device| {
                let transfers = device.file_transfers().unwrap();
                files.iter().all(|(id, _)| {
                    transfers
                        .iter()
                        .any(|transfer| &transfer.id == id && transfer.status == "ready")
                })
            });
            if complete {
                break;
            }
        }
        assert!(
            complete,
            "all receivers must verify and all senders receive outcomes"
        );

        // Reopen every encrypted store with its own retained key. Six distinct
        // receiver saves then verify all directed device pairs after restart.
        drop(devices);
        let mut devices = open();
        for (receiver, device) in devices.iter_mut().enumerate() {
            assert_eq!(device.device_id(), ids[receiver]);
            for _ in 0..3 {
                tick_and_apply(device);
            }
            let history = device.store.history().unwrap();
            assert_eq!(history.len(), expected.len());
            assert_eq!(
                history.iter().map(|e| &e.id).collect::<HashSet<_>>().len(),
                6
            );
            for (id, origin, clip) in &expected {
                let event = history.iter().find(|event| &event.id == id).unwrap();
                assert_eq!(&event.origin, origin);
                let mut expected_clip = clip.clone();
                if clip.kind == "attachment" && origin != device.device_id() {
                    // File provenance uses the authenticated roster's display
                    // name; the sender's local configuration name stays local.
                    expected_clip.source_device = Some(
                        device
                            .status()
                            .unwrap()
                            .members
                            .into_iter()
                            .find(|member| &member.id == origin)
                            .unwrap()
                            .name,
                    );
                }
                assert_eq!(event.clip, expected_clip);
            }
            for (sender, (id, bytes)) in files.iter().enumerate() {
                if sender == receiver {
                    continue;
                }
                let saved = root.join(format!("saved-{sender}-to-{receiver}.bin"));
                device.store.save_file(id, &saved, || false).unwrap();
                assert_eq!(&std::fs::read(saved).unwrap(), bytes);
            }
        }
    })
    .await;
    server.abort();
    result.unwrap();
}
