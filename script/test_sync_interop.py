#!/usr/bin/env python3
"""Exercise native Mac and container Linux engines against one isolated relay.

Build relay/examples/interop_probe on both hosts first. No app data, system
clipboard, real Keychain, or real relay credentials are used. This checks
cross-platform engine/transport behavior, not either app's UI integration.
"""
import base64
import argparse
import hashlib
import json
from pathlib import Path
import secrets
import selectors
import socket
import sqlite3
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
PROBE = ROOT / "rust/DeviceSync/target/debug/examples/interop_probe"
NAME = "clipvault-interop-" + uuid.uuid4().hex[:12]


class Probe:
    def __init__(self, args):
        self.process = subprocess.Popen(
            args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1,
        )

    def request(self, **value):
        self.process.stdin.write(json.dumps(value) + "\n")
        self.process.stdin.flush()
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            if not selector.select(timeout=30):
                raise RuntimeError("probe response timeout")
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError("probe process exited")
        result = json.loads(line)
        if "error" in result:
            raise RuntimeError(result["error"])
        return result.get("ok", result)

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)


def clip(text, png=None):
    return dict(kind="image" if png else "text", text="" if png else text,
                display_text="Image" if png else text, captured_at=1792497600,
                source_app=None, source_device=None, image_png=png, metadata={})


def run(image, target_volume, platform):
    probes = []
    container_started = False
    try:
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        subprocess.run([
            "docker", "run", "--detach", "--rm", "--name", NAME,
            *(["--platform", platform] if platform else []),
            "--memory=1g", "--cpus=1", "--publish", f"127.0.0.1:{port}:{port}",
            "--volume", f"{target_volume}:/build:ro", image, "sleep", "900",
        ], check=True, stdout=subprocess.DEVNULL, timeout=20)
        container_started = True
        server = Probe(["docker", "exec", "-i", NAME,
                        "/build/debug/examples/interop_probe", "server"])
        probes.append(server)
        registration = secrets.token_hex(32)
        assert server.request(port=port, path="/tmp/relay.db", registration=registration)["ready"]
        with tempfile.TemporaryDirectory(prefix="clipvault-interop-") as directory:
            mac = Probe([str(PROBE)])
            linux_args = ["docker", "exec", "-i", NAME, "/build/debug/examples/interop_probe"]
            linux = Probe(linux_args)
            probes.extend([mac, linux])
            mac.request(action="open", key=secrets.token_hex(32), path=str(Path(directory)/"mac.db"))
            linux_key = secrets.token_hex(32)
            linux.request(action="open", key=linux_key, path="/tmp/linux.db")
            mac.request(action="create", endpoint=f"http://127.0.0.1:{port}", registration=registration)
            words = linux.request(action="join", invite=mac.request(action="invite"))
            request = mac.request(action="requests")[0]
            assert request["words"] == words
            mac.request(action="approve", id=request["id"], words=words)
            linux_id = linux.request(action="tick", apply=True)["device_id"]
            print("PASS: native macOS and Linux pairing and comparison code")

            token = "ClipVault cross-OS receipt " + uuid.uuid4().hex
            png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGPQbD/+HwAEywJ3k0b7vgAAAABJRU5ErkJggg=="

            def assert_opaque_pending(event, payload):
                raw = subprocess.check_output(["docker", "exec", NAME, "cat", "/tmp/relay.db"], timeout=10)
                with sqlite3.connect(":memory:") as db:
                    db.deserialize(raw)
                    row = db.execute("SELECT envelope FROM deliveries WHERE event=? AND status='pending'",
                                     (event,)).fetchone()
                    assert row is not None
                    envelope = json.loads(row[0])
                    assert len(base64.b64decode(envelope["ciphertext"])) > 16
                for plaintext in [payload["text"].encode(),
                                  base64.b64decode(payload["image_png"] or ""),
                                  base64.b64decode(payload["metadata"].get("rtf", ""))]:
                    if plaintext:
                        assert plaintext not in raw

            def receive(sender, receiver, payload, apply):
                event = sender.request(action="capture", clip=payload)
                assert event
                sender.request(action="tick", apply=True)
                assert_opaque_pending(event, payload)
                receiver.request(action="tick", apply=apply)
                events = receiver.request(action="history" if apply else "imports")
                found = next(e for e in events if e["id"] == event)
                expected = dict(payload, source_device=("macOS interoperability probe"
                                                       if sender is mac else "Linux interoperability probe"))
                assert found["clip"] == expected
                if not apply:
                    assert sender.request(action="status")["pending"] > 0
                    receiver.request(action="apply", id=event)
                receiver.request(action="tick", apply=apply)
                sender.request(action="tick", apply=True)
                assert sender.request(action="status")["pending"] == 0
                return event

            receive(mac, linux, clip(token + " Mac to Linux"), True)
            receive(linux, mac, clip(token + " Linux to Mac"), False)
            receive(mac, linux, clip("", png), True)
            receive(linux, mac, clip("", png), False)
            rich = clip("Rich cross-OS receipt")
            rich["kind"] = "richText"
            rich["metadata"]["rtf"] = base64.b64encode(b"{\\rtf1\\ansi Rich \\b cross-OS\\b0 receipt}").decode()
            receive(mac, linux, rich, True)
            receive(linux, mac, rich, False)
            print("PASS: text, PNG and exact RTF bytes in both directions; applied receipts")

            count = len(linux.request(action="history"))
            for _ in range(3):
                mac.request(action="tick", apply=True)
                linux.request(action="tick", apply=True)
            assert len(linux.request(action="history")) == count
            print("PASS: repeated delivery polling does not duplicate history")

            linux.close()
            offline_event = mac.request(action="capture", clip=clip(token + " offline"))
            mac.request(action="tick", apply=True)
            assert mac.request(action="status")["pending"] == 1
            assert_opaque_pending(offline_event, clip(token + " offline"))
            linux = Probe(linux_args)
            probes.append(linux)
            linux.request(action="open", key=linux_key, path="/tmp/linux.db")
            linux.request(action="tick", apply=True)
            linux.request(action="tick", apply=True)
            mac.request(action="tick", apply=True)
            assert any(e["id"] == offline_event for e in linux.request(action="history"))
            assert mac.request(action="status")["pending"] == 0
            print("PASS: Linux process restart decrypts retained state and catches up offline delivery")

            mac.request(action="enable", enabled=False)
            paused = mac.request(action="capture", clip=clip(token + " paused"))
            assert paused
            assert mac.request(action="status")["pending"] == 0
            assert mac.request(action="tick", apply=True)["state"] == "Sharing off"
            linux.request(action="tick", apply=True)
            assert all(e["id"] != paused for e in linux.request(action="history"))
            mac.request(action="enable", enabled=True)
            mac.request(action="remove", id=linux_id)
            try:
                linux.request(action="tick", apply=True)
            except RuntimeError as error:
                assert str(error) == "probe operation failed"
            else:
                raise AssertionError("revoked device was accepted")
            print("PASS: sharing pause and revoked-device rejection")

            raw = subprocess.check_output(["docker", "exec", NAME, "cat", "/tmp/relay.db"], timeout=10)
            for plaintext in [token.encode(), b"Rich cross-OS receipt", base64.b64decode(png)]:
                assert plaintext not in raw
            print("PASS: pending relay envelopes hold ciphertext; controlled text, PNG and RTF bytes absent")
            print("Controlled PNG SHA-256:", hashlib.sha256(base64.b64decode(png)).hexdigest())
    finally:
        for probe in reversed(probes):
            if probe.process.poll() is None:
                probe.close()
        if container_started:
            subprocess.run(["docker", "stop", "--time", "1", NAME],
                           stdout=subprocess.DEVNULL, timeout=15, check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", default="clipvault-linux-validation")
    parser.add_argument("--target-volume", default="clipvault-linux-target")
    parser.add_argument("--platform", help="optional Docker platform; otherwise use the selected image")
    args = parser.parse_args()
    run(args.image, args.target_volume, args.platform)
