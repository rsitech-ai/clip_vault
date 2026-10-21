#!/bin/sh
# Install only the reviewed bundle next to this script. Does not publish HTTPS.
set -eu
test "$(id -u)" = 0 || { echo 'Run this installer with sudo.' >&2; exit 1; }
bundle_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$bundle_dir"
test "$(stat -c %u .)" = 0 || { echo 'Use a verified, root-owned staging directory.' >&2; exit 1; }
sha256sum --check SHA256SUMS
for destination in /etc/clipvault-relay /etc/systemd/system/clipvault-relay.service /etc/systemd/system/clipvault-relay-proxy.service /usr/local/libexec/clipvault-sync-relay /usr/local/libexec/clipvault-relay-nginx; do
    if test -e "$destination"; then
        echo "Refusing to replace existing installation: $destination" >&2
        exit 1
    fi
done
if getent passwd clipvault-relay >/dev/null; then
    echo 'Refusing to reuse an existing clipvault-relay account.' >&2
    exit 1
fi
test "$(dpkg --print-architecture)" = amd64
test "$(dpkg-deb -f clipvault.deb Architecture)" = amd64
test "$(dpkg-deb -f clipvault.deb Package)" = clipvault
# Install the app through apt for dependency checking. The proxy executable was
# extracted from Ubuntu's nginx package; no global nginx service is installed.
apt-get install -y --no-install-recommends "$bundle_dir/clipvault.deb"
useradd --system --user-group --home-dir /var/lib/clipvault-relay --no-create-home --shell /usr/sbin/nologin clipvault-relay
install -d -m 0755 /usr/local/libexec
install -m 0755 clipvault-sync-relay /usr/local/libexec/clipvault-sync-relay
install -m 0755 clipvault-relay-nginx /usr/local/libexec/clipvault-relay-nginx
install -d -m 0755 /usr/local/share/doc/clipvault-relay-nginx
install -m 0644 nginx-copyright /usr/local/share/doc/clipvault-relay-nginx/copyright
install -d -m 0755 /etc/clipvault-relay
install -m 0644 nginx.conf /etc/clipvault-relay/nginx.conf
python3 - <<'PY'
import os, re
secret = open('provisioning-token', encoding='ascii').read().strip()
if not re.fullmatch('[0-9a-f]{64}', secret):
    raise ValueError('Invalid private provisioning token')
fd = os.open('/etc/clipvault-relay/environment', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as f:
    f.write('CLIPVAULT_RELAY_REGISTRATION_TOKEN=' + secret + '\n')
PY
install -m 0644 clipvault-relay.service /etc/systemd/system/clipvault-relay.service
install -m 0644 clipvault-relay-proxy.service /etc/systemd/system/clipvault-relay-proxy.service
systemd-analyze verify /etc/systemd/system/clipvault-relay.service /etc/systemd/system/clipvault-relay-proxy.service
systemctl daemon-reload
systemctl enable --now clipvault-relay.service clipvault-relay-proxy.service
python3 - <<'PY'
import time, urllib.request
for attempt in range(20):
    try:
        with urllib.request.urlopen('http://127.0.0.1:8743/health', timeout=2) as r:
            assert r.status == 200 and r.read(16) == b'ok'
        print('Loopback relay and bounded proxy: healthy')
        break
    except Exception:
        if attempt == 19:
            raise
        time.sleep(0.5)
PY
echo 'Installed ClipVault and boot-persistent loopback relay services.'
echo 'HTTPS publishing and private device pairing are the next separate steps.'
echo 'No registration secret was printed.'
