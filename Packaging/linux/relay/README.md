# Private relay installation

The preview relay is a dedicated system service listening on loopback 8742.
A separately extracted Ubuntu nginx executable listens on loopback 8743 and
enforces request, connection, size and timeout limits. This does not install or
start the global Ubuntu nginx service. Tailscale Serve publishes the proxy as
private HTTPS, separately from installing these services. Never enable Funnel.

The installer requires an AMD64 bundle containing the files named in its
SHA256SUMS, including the previously validated ClipVault package, production
relay, Ubuntu nginx executable/copyright, and a private random 64-character hex
provisioning-token. Archive permissions must be 0600 and its parent 0700. Do not
attach the bundle or token to an issue, chat or source control.

Before running the installer, copy the archive into a fresh root-owned 0700
directory, check the copied archive against the digest supplied independently
from the source Mac, and extract as root with `--no-same-owner`. Execute the
installer only from that root-owned copy. Checking a checksum inside a writable
user directory alone is not an authenticity guarantee. The installer also
checks its payload hashes and refuses an existing installation or account.

After successful loopback health checks, publish only if no existing Serve
configuration would be replaced:

```sh
sudo tailscale serve --bg --https=443 http://127.0.0.1:8743
```

The command may require a tailnet administrator to enable HTTPS certificates.
Check the resulting HTTPS `/health` from both laptops with normal certificate
validation. Local loopback health alone does not establish remote delivery.

The service starts at boot independently of a desktop login. Do not disable the
laptop's sleep policy implicitly. While the relay machine sleeps or has no
network, clients retain pending clips and retry later; an always-on host is
needed for availability independent of laptop sleep. Relay mailbox quota and
30-day payload expiry and 37-day delivery/status retention still apply. The proxy streams ciphertext requests and responses without temporary-body copies.
It allows 100 requests/second overall (burst 50) because Tailscale Serve forwards
all paired devices through the same loopback address. Join and workspace setup
retain a separate 20 requests/second limit (burst 50). Empty map keys exclude
ordinary transfer traffic from that setup allowance. These limits still apply
before application authentication. The proxy allows four concurrent requests and the unauthenticated pairing endpoint accepts at most 8 KiB before JSON decoding; authenticated payload requests retain the larger envelope limit. These limits reduce memory pressure under the service resource ceiling. Neither restart checks nor a short network sample
prove long-term uptime.

## Interrupted installation and rollback

The first-install script deliberately fails closed on existing files/accounts.
Do not blindly rerun it after an interruption. Preserve
`/etc/clipvault-relay/environment` and `/var/lib/clipvault-relay/` before recovery;
the first contains the registration secret and the second pending ciphertext.
Inspect `systemctl status clipvault-relay clipvault-relay-proxy` and the units'
journal, compare root-owned files with the verified bundle, and complete only
the missing install/start steps. `systemctl daemon-reload` and
`systemctl enable --now clipvault-relay clipvault-relay-proxy` can resume service
startup after correcting an incomplete copy. Do not delete a database or rotate
credentials merely to make the installer run again.

To disable a successful deployment, remove only this specific Serve HTTPS
mapping (`sudo tailscale serve --https=443 off`) and disable only these units
(`sudo systemctl disable --now clipvault-relay-proxy clipvault-relay`). Preserve
the database and secret for recovery. Check existing Serve configuration before
removing a mapping; do not reset unrelated Tailscale configuration.

The standalone nginx executable is frozen to the Ubuntu package recorded in the
installation receipt. Ubuntu's package manager will not automatically update
this copied executable. Check upstream/distro security updates and replace it
through a reviewed maintenance operation; record its version and digest. The
client preview and relay likewise need explicit updates. Back up the relay
database consistently (stop the service or use SQLite's backup API).

The proxy unit manages its body, proxy, FastCGI, uWSGI and SCGI buffer directories
individually with `StateDirectory=` and mode `0700`. Keep these entries together
with the configured nginx temporary paths. A root-level `nginx -t` can create
children owned by nginx's default user; managing only the parent would not
correct those children when the parent already has the right owner. Run configuration checks through
the service's `ExecStartPre` context, and verify a request larger than the memory
buffer when qualifying an installed proxy. A health request alone does not test
request or response temporary-file permissions.
