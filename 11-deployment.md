# 11 — Server Deployment

How an OtterMSG node goes from source code to a running server, and how it is kept running.
This document describes the procedure. The code changes and scripts in
[§10](#10-code-and-scripts-to-write) implement it as milestone **M1.5 — Deployment**.

**Decisions this guide is built on** (D25–D28 in [00](00-decisions.md)):

* Each node has a **domain name**. The owner manages DNS by hand at separate providers;
  `otter-admin` prints the exact records to create. No CDN.
* Nodes **don't use ports 80 or 443**. Each node listens on one configurable rare port, default
  **27443/tcp**. It isn't registered with IANA, isn't listed among nmap's known services, and is
  below Linux's ephemeral port range.
* **Self-signed TLS certificate per node, pinned in the app.** `otter-admin` generates it; the
  SHA-256 fingerprint of its public key goes into the signed manifest; the app accepts only
  certificates matching a pin. No Let's Encrypt, no renewals, no DNS API tokens on servers.
* **One program per server:** `otter-node` terminates TLS, serves the messenger WebSocket on a
  secret path and a decoy website on every other path. No reverse proxy.
* Targets: Hetzner VPS, Linode VPS, bare-metal Debian/Ubuntu (all systemd).

Feature availability referenced here:

| Feature | Available from |
|---------|----------------|
| Single node, WSS transport, bootstrap invite | M1 |
| Certificate pinning, deployment scripts | M1.5 |
| 2–3 nodes that sync with each other; manifest updates reaching apps | M2 |
| Push wake-ups (FCM, optional), `push-key.sh`, `node set-push` | M5 (§12) |
| VLESS + REALITY transport | M7 (port layout revisited there, §9) |
| `otter-node status`, `backup`, `/metrics` | M9 |

Until M2, **deploy one node**. A second node would run, but it would not share messages with the first.

---

## 1. Overview

```
 Admin machine (your PC)                           Each server
 ───────────────────────                           ─────────────────────────────────────
 otter-server repo                                 /usr/local/bin/otter-node   (systemd service)
   make release ──► otter-node (amd64/arm64)       /etc/otter/node.toml
 otter-admin + network key (encrypted)             /etc/otter/node.key         node identity
   node add  → node key + TLS cert + pin           /etc/otter/tls.crt, tls.key  self-signed, 10 years
   manifest sign (pins inside, signed)             /etc/otter/manifest.bin
   dns records → you update DNS by hand            /var/lib/otter/node.db      data
   make-bundle → bundle-<label>.tar.gz ── scp ──►  /var/lib/otter/site/        decoy website

   app ── wss://chat.example.org:27443/<secret path> ──► otter-node
          (trusts only certificates whose public key matches a pin in the signed manifest)
```

Principles:

* **Build once, on the admin machine.** Servers receive a static binary. They need no Go, git
  or compiler.
* **The network key never leaves the admin machine.** A server gets only its own node key, its
  TLS key, the signed manifest and its config.
* **One node = one bundle + one systemd unit.** You can rebuild a node from its bundle at any
  time. Its data replicates back from peers (M2+) or is restored from backup (single-node setups).
* **Debian 12/13 and Ubuntu 22.04/24.04**, amd64 or arm64. These are the default images on
  Hetzner and Linode, and fine for bare metal.

### Why pinning instead of a public certificate

* It works on any port with no automatic validation (Let's Encrypt needs port 80/443 or a DNS API).
* Nothing expires unattended: certificates last 10 years and rotation is planned (§6).
* It's stricter than public CAs: a compromised or coerced certificate authority can't
  impersonate a node, because the app trusts only the pinned keys, and the pins arrive signed
  by the network key.
* The domain never appears in public Certificate Transparency logs, which a public
  certificate would expose.
* Trade-off: anyone probing `https://domain:27443/` sees a self-signed certificate. That's common
  on non-standard ports, but less inconspicuous than a public one. REALITY between nodes (M7, §13) is the
  answer for heavy DPI on the link out of a censored country.

---

## 2. Requirements

### Server

| Item | Minimum | Notes |
|------|---------|-------|
| CPU / RAM | 1 vCPU, 512 MB | 1 GB recommended once photos arrive (M4) |
| Disk | 10 GB | Photos and backups dominate; plan 20–50 GB for 100 users |
| OS | Debian 12/13 or Ubuntu 22.04/24.04, amd64 or arm64 | Root or sudo via SSH |
| Public IPv4 | yes | IPv6 optional |
| Open inbound ports | SSH + the node port (27443/tcp) | Nothing else |
| Clock | NTP-synchronised | Logins fail when the clocks of the phone and server differ by more than 5 minutes |

The node port is configurable per node (`--wss-port`). Because it's above 1024, the node needs no
root privileges or extra capabilities.

### Domain

One domain or subdomain per node, e.g. `chat.example.org`. You create the records by hand;
`otter-admin dns records` prints them (§5.1). Only `A` (and optionally `AAAA`) records are needed.
There are no TXT records and no renewals.

### Admin machine

Linux or macOS with Go ≥ 1.26, `git`, `make`, `ssh`/`scp`. It holds `~/.otter-admin` (the
network key, encrypted with your passphrase).

---

## 3. Building a release

On the admin machine, in `otter-server/`:

```bash
make check                      # tests must pass
make release VERSION=0.1.0      # → dist/otter-node_0.1.0_linux_{amd64,arm64}
                                #   dist/otter-admin_0.1.0_<your OS/arch>
                                #   dist/SHA256SUMS
```

The binaries are static (`CGO_ENABLED=0`, `-trimpath`) and have the version stamped in
(`otter-node version`, `otter-admin version`). Older versions in `dist/` are kept; `SHA256SUMS` covers all of them.
The deploy scripts also need host builds of the tools: `make build` (→ `bin/otter-admin`, `bin/otter-node`).

---

## 4. One-time network setup (admin machine)

Done once per network, not per server.

```bash
otter-admin network init                 # asks for a passphrase (min 12 chars)
```

Back up `~/.otter-admin/network.key.enc` and its passphrase now (USB stick, password manager).
Give the second admin their copy of the encrypted key file ([08](08-operations.md)).

---

## 5. Deploying a node, step by step

Example: first node `fi-1`, domain `chat.example.org`, server IP `203.0.113.10`.

### 5.1 Register the node and publish DNS records (admin machine)

```bash
otter-admin node add --label fi-1 --wss-host chat.example.org --ip 203.0.113.10 [--ip 2001:db8::10] [--push]
#   generates: nodes/fi-1/node.key, nodes/fi-1/tls.key, nodes/fi-1/tls.crt
#   endpoint: wss://chat.example.org:27443/<random path>, tls_spki_pins = [sha256(SPKI)]
otter-admin manifest sign
otter-admin dns records
```

`dns records` prints what to create at your DNS provider, for example:

```
; Add these records at the DNS provider of each domain (TTL 300 recommended)
chat.example.org.    300  IN  A     203.0.113.10
chat.example.org.    300  IN  AAAA  2001:db8::10
```

A short TTL lets a later IP change take effect quickly. `otter-admin dns check` resolves the
names and reports any mismatch. The install health check also runs it.

The TLS certificate is ECDSA P-256, valid for 10 years, with `CN` and `subjectAltName` set to the
domain (plus the IPs, so a node can also be reached by IP if ever needed). The pin is the
standard SHA-256 of the certificate's SubjectPublicKeyInfo.

### 5.2 Bootstrap invite (first node of a new network only)

```bash
otter-admin invite bootstrap             # link + terminal QR; record goes into the bundle
```

### 5.3 Create the bundle and install it

```bash
deploy/make-bundle.sh fi-1               # → dist/bundle-fi-1.tar.gz (0600)
deploy/push.sh fi-1 root@203.0.113.10    # scp, remote install.sh, health check, delete local bundle
```

Bundle contents:

```
bundle-fi-1/
  otter-node-{amd64,arm64}     binaries (install.sh picks the right one)
  node.key, tls.key, tls.crt   this node's identity and TLS keypair
  manifest.bin                 signed manifest (contains the pin)
  node.toml                    config (§5.4)
  otter-node.service           systemd unit (§5.5)
  otter-backup.{service,timer} daily DB backup (enabled with backup.sh --install)
  probe.env                    URL, pin and node id for the health check (→ /etc/otter/probe.env)
  site/index.html              decoy website (no product names)
  invites/*.bin                pending bootstrap invites (first node of a new network)
  install.sh, uninstall.sh, backup.sh, health.sh   (→ /usr/local/lib/otter/)
  SHA256SUMS
```

The bundle contains private keys. `push.sh` deletes the local copy after a successful install
(`make-bundle.sh` can recreate it from `~/.otter-admin`) and moves the delivered invites to
`~/.otter-admin/invites/delivered/`. `make-bundle.sh` refuses to build when the signed manifest does not contain
the pin of the bundle's certificate (run `manifest sign`). If a rotated certificate is staged (`tls.new.*`), the
bundle carries that one.

`install.sh` does the following, and is safe to run again:

1. Checks: running as root, systemd present, Debian/Ubuntu, architecture supported, `SHA256SUMS`
   matches, the node port is free (`ss -ltn`). If the port is taken, it stops and names the process holding it.
2. Time sync: enables `systemd-timesyncd` (or uses chrony if already installed) and waits for sync.
3. Creates the system user `otter` (no shell, home `/var/lib/otter`).
4. Installs files, with owner and mode:

   | Path | Owner | Mode |
   |------|-------|------|
   | `/usr/local/bin/otter-node` | root:root | 0755 |
   | `/etc/otter/` | root:otter | 0750 |
   | `/etc/otter/node.key`, `tls.key` | root:otter | 0640 |
   | `/etc/otter/node.toml`, `manifest.bin`, `tls.crt` | root:otter | 0640 |
   | `/etc/otter/fcm.json` (optional, M5; only via `deploy/push-key.sh`, never in the bundle) | root:otter | 0640 |
   | `/var/lib/otter/` (data) | otter:otter | 0700 |
   | `/var/lib/otter/site/` (decoy) | otter:otter | 0755 |
   | `/etc/systemd/system/otter-node.service` | root:root | 0644 |

5. Runs `otter-node check` (config, node key, manifest, endpoint path, TLS pin), then imports the bundled
   invites as user `otter` (copied into `/var/lib/otter` first, because the bundle directory is root-only).
   The manifest is imported automatically at start from `manifest_file`.
6. Firewall: if `ufw` is active, allows SSH and the node port. If no host firewall is active,
   it **prints a warning** but changes nothing, since a Hetzner/Linode cloud firewall may be in use instead (§8).
7. Enables and starts `otter-node.service`.
8. Runs the health check (§7) and prints the result plus the next step (send the bootstrap
   invite to the first member).

`uninstall.sh` stops and removes the unit, binary and `/etc/otter`. It keeps `/var/lib/otter`
unless `--purge` is passed.

### 5.4 Configuration file

`/etc/otter/node.toml` (generated by `make-bundle.sh`):

```toml
data_dir      = "/var/lib/otter"
node_key      = "/etc/otter/node.key"
network_pub   = "<hex, from otter-admin>"
manifest_file = "/etc/otter/manifest.bin"
log_level     = "info"

[wss]
listen   = ":27443"                         # node port, all interfaces
path     = "/<32 random characters>"        # same as the manifest endpoint path
tls_cert = "/etc/otter/tls.crt"
tls_key  = "/etc/otter/tls.key"
site_dir = "/var/lib/otter/site"            # decoy website for every other path

[mesh]
allow_plain = false                         # true only for development meshes with WS_PLAIN endpoints

[push]                                      # M5, always in the template
fcm_credentials = "/etc/otter/fcm.json"     # push is off while this file is missing (§12)
```
Nodes replicate with each other over the same port: the peer endpoint is `<path>/peer`, verified with the
peer's pinned certificate and node key (no extra port or firewall rule).

### 5.5 systemd unit

`/etc/systemd/system/otter-node.service`:

```ini
[Unit]
Description=OtterMSG node
After=network-online.target time-sync.target
Wants=network-online.target

[Service]
Type=simple
User=otter
Group=otter
ExecStart=/usr/local/bin/otter-node run --config /etc/otter/node.toml
Restart=always
RestartSec=3
LimitNOFILE=65536

# hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true
SystemCallArchitectures=native
# :443 for REALITY (M7, D72) without root
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ReadWritePaths=/var/lib/otter

[Install]
WantedBy=multi-user.target
```

### 5.6 First member

Send the bootstrap link printed in 5.2 (or show its QR code) to the first member, normally
yourself. They install the APK and join with "Присоединиться по приглашению". Everyone after
that is invited from inside the app. The invite carries the signed manifest, so the app knows
the node's pin from the start.

---

## 6. Day-2 operations

### Logs

```bash
journalctl -u otter-node -f              # node (JSON lines)
```

Message contents never appear in logs; they don't exist on the server in readable form.

### Upgrade a node

`deploy/upgrade.sh root@host dist/otter-node_0.2.0_linux_amd64` does the following:

1. Copies the new binary to `/usr/local/bin/otter-node.new` and verifies its checksum on the server.
2. Backs up the database with the **installed** binary (`otter-node backup` → `/var/backups/otter/pre-upgrade-<ts>.db`),
   so database migrations can be rolled back by restoring.
3. `systemctl stop otter-node`, swaps binaries (keeps `otter-node.prev` and, since M7, `node.toml.prev`), starts
   the node.
4. Health check (`/usr/local/lib/otter/health.sh`: pinned hello on `127.0.0.1:<port>`, up to 20 s). If it fails:
   restore `otter-node.prev`, `node.toml.prev` and the backed-up DB, restart; the bad binary stays as
   `otter-node.failed`.

Downgrading by hand below 0.7.0: remove the `[reality]` section from `node.toml` first (older binaries refuse unknown
config keys and would not start).

Exit codes: 0 upgraded, 2 rolled back (node still on the old version), 3 rollback failed (act now).

With several nodes (M2+), upgrade **one node at a time**, and wait until it is healthy and
caught up before doing the next one. `deploy/upgrade-all.sh` does this for you, see §11.

### Backups

| Setup | What to back up | Why |
|-------|-----------------|-----|
| 1 node | `/var/lib/otter/node.db` (consistent copy) | Undelivered messages live only here; photo blobs in `/var/lib/otter/blobs/` are transient and not backed up (D48); users' password backups (M6) are persistent blobs, see below |
| 2–3 nodes (M2+) | Optional | Every node holds a full replica; a lost node is rebuilt from its bundle and re-syncs |
| Always | Admin machine: `~/.otter-admin/` | Network key, node keys and TLS keys; without them you can't sign manifests or rebuild bundles |

Consistent DB copy while the node runs: `otter-node backup --config /etc/otter/node.toml --out FILE`
(`VACUUM INTO`; no `sqlite3` CLI needed, D41). `/usr/local/lib/otter/backup.sh --install` enables a daily systemd
timer (`otter-backup.timer`, runs as `otter`) that keeps 7 copies in `/var/backups/otter/`. Backups contain only ciphertext and metadata, but
they **do** reveal who talks to whom, so keep them on the server or in encrypted storage. Hetzner and
Linode server snapshots are a convenient extra layer.

Password backups of members (M6, D50) are persistent blobs in `/var/lib/otter/blobs/` on every node (at most 3 per member, counted in the 2 GiB quota). They replicate like photos, so a rebuilt node refills them from its peers; `backup.sh` copies the database only. Nothing to configure.

### Moving a node to another server (IP blocked, hosting gone)

1. New server → `otter-admin node set-ip --label fi-1 --ip <new IP>` (re-issues the certificate with the same key,
   D42) → `otter-admin dns records` → update the `A` record → `otter-admin dns check --label fi-1`.
2. `deploy/push.sh fi-1 root@<new IP>`. The same bundle contains the same keys, so the pin is unchanged.
3. Apps reconnect by domain name as soon as DNS has updated. No re-invite is needed, even in M1.

### Rotating a node's TLS certificate

Needed only if the TLS key may have leaked, or after about 9 years. This depends on M2, where apps
receive manifest updates:

1. `otter-admin node rotate-tls --label fi-1` stages a new keypair (`nodes/fi-1/tls.new.{crt,key}`); the node now
   lists **both** pins.
2. `otter-admin manifest sign && otter-admin manifest publish` (sends `manifest.bin` to every node in the
   manifest, `--via <label>` for specific nodes; nodes also replicate it and push it to connected apps).
   Wait until apps have the new manifest (hours to days).
3. Deploy the new certificate (`push.sh`; bundles use the staged pair), then `otter-admin node drop-old-pins --label fi-1`
   (promotes `tls.new.*` to `tls.*`, keeps the old pair as `tls.old.*`, leaves only the new pin), `manifest sign`, publish.
Guard `tls.key` like `node.key`.

### Decommissioning a node

On the server `/usr/local/lib/otter/uninstall.sh --purge` (shreds the keys, removes data and backups); without
`--purge` it keeps `/var/lib/otter` and `/var/backups/otter`. Then remove the DNS records, remove the node from the
manifest (`node remove`) and re-sign it.

---

## 7. Health checks

`deploy/check.sh <label> [root@host]` prints a PASS/FAIL table (exit 1 on any FAIL): the admin-side probes always,
the SSH checks when a target is given. `install.sh` and `upgrade.sh` run the server-side `health.sh`.
`OTTER_PROBE_ADDR=host:port` points the admin-side probes elsewhere; `OTTER_SKIP_DNS=1` skips DNS.

| Check | How | Expected |
|-------|-----|----------|
| DNS | `otter-admin dns check` | domain resolves to the node's IPs |
| Service up | `systemctl is-active otter-node` | `active` |
| Node answers via pinned TLS | `otter-node probe --url wss://<domain>:<port><path> --pin <base64>` (from the server and from the admin machine) | `hello`, protocol 1, correct node_id |
| Wrong pin rejected | same with a random `--pin` | fails (proves pinning works) |
| Decoy | `curl -k https://<domain>:<port>/` | 200, decoy page |
| Clock | `timedatectl show -p NTPSynchronized` | `yes` |
| Manifest | node log line on start | no "not listed in the manifest" warning |
| Push (M5) | `otter-node check` line; log line on start; `deploy/status.sh` PUSH column | `ok push key (project …)` and `push on` on push-capable nodes, `ok push off (no key file)` / `push off` elsewhere; no "manifest says push_capable but no FCM key is installed" warning |

---

## 8. Security checklist

* SSH: key-only login, `PermitRootLogin prohibit-password`, optionally a non-standard port.
* Automatic security updates: `unattended-upgrades`.
* Inbound: only SSH, the node port and (with REALITY, §13) the REALITY port, using ufw or the Hetzner/Linode cloud
  firewall.
* `node.key` and `tls.key` are readable only by root and the `otter` group; the network key is never on a server.
* Servers hold no secrets that can read messages. A seized server exposes metadata ([04](04-security.md)),
  and its TLS key would let someone impersonate that node at the transport layer. Rotate it (§6). Message
  content stays end-to-end encrypted regardless.
* **Blocking note:** connections to well-known foreign hosting ranges (Hetzner and Linode included)
  are a common target for throttling, and a rare port with a self-signed certificate is easier to
  single out than 443 with a public certificate. The answer since M7: phones in the restricted network use a
  domestic `dial_out_only` node, which reaches the foreign nodes over REALITY on :443 (§13). A bare-metal machine
  inside the restricted network is a good candidate for that domestic node.

---

## 9. What changes in later milestones

| Milestone | Deployment change |
|-----------|-------------------|
| M2 | 2–3 nodes; node↔node traffic uses the same node port, authenticated by pins + node keys; `otter-admin manifest publish --via`; apps follow manifest updates, which enables TLS rotation (§6) |
| M4 (done) | `/var/lib/otter/blobs/` holds photos until every reader has them (≤ 30 days); size disks for peaks (`[limits] user_quota`, default 2 GiB per member); optional `[limits]`/`[replication]` in `node.toml` (commented defaults in the template); not in backups |
| M5 (done) | Optional `/etc/otter/fcm.json` (Firebase service account) on push-capable nodes, installed with `deploy/push-key.sh`; `[push]` in `node.toml`; DB migration 0006 runs on upgrade. Upgrade a node to M5 **before** `push-key.sh` (§12) |
| M6 (done) | `/var/lib/otter/blobs/` also holds members' password backups (persistent blobs, ≤ 3 per member, counted in `user_quota`); nothing to configure; DB migration 0005 runs on upgrade. Upgrade all nodes (`upgrade-all.sh`) before relying on restore: an older node answers `auth.login` without `installed_ms` and does not know the backup methods |
| M7 (done) | Optional `[reality]` in `node.toml` + `/etc/otter/reality.key` on foreign nodes, listening on :443 (`CAP_NET_BIND_SERVICE`; clients stay on the node port, D26 revised for REALITY only), set up with `deploy/reality-setup.sh` after the node runs 0.7.0; `dial_out_only` for a domestic node (`add-node.sh` asks); DB migration 0008 (`netlog`); `upgrade.sh` also rolls back `node.toml` (§13) |
| M9 | `otter-node status`, `/metrics` on localhost; alerting examples (`backup` and `check` arrived in M1.5, D41) |

---

## 10. Code and scripts (milestone M1.5 — done 2026-11-11)

Everything below exists; `otter-server/deploy/FIRST-DEPLOY.md` is the condensed first-deployment runbook. Script environment: `OTTER_ADMIN_DIR` (default `~/.otter-admin`), `OTTER_SSH_PORT`,
`OTTER_SSH_OPTS`, `OTTER_PROBE_ADDR`, `OTTER_SKIP_DNS` (D43). Quick reference: `otter-server/deploy/README.md`.

**Protocol / server code:**

| Change | Notes |
|--------|-------|
| ~~`Endpoint.tls_spki_pin` → `repeated bytes tls_spki_pins = 5`~~ | **Done in M2** |
| ~~`otter-admin node add`: default port 27443, `--ip`, per-node cert + pin~~ | **Done in M2** (`nodes/<label>/{tls.crt,tls.key,meta.json}`) |
| ~~`otter-admin dns records`, `dns check`, `node set-ip`, `node rotate-tls`, `node drop-old-pins`~~ | **Done in M1.5**, plus `node env` (shell-quoted facts for the scripts) |
| ~~`otter-node probe --url URL [--pin B64]... [--addr H:P] [--insecure] [--expect-node HEX]`~~ | **Done in M1.5**, plus `otter-node check` and `backup` (D41) |
| ~~`make release VERSION=x`~~ | **Done in M1.5** |
| ~~Vectors: SPKI pin of a fixed test certificate~~ | **Done in M2** |

**Android code:**

| Change | Notes |
|--------|-------|
| ~~`PinnedTrust` + per-pin-set `OkHttpClient`~~ | **Done in M2** (`PinnedTrustManager`, `Transport.connect(Candidate)`) |
| Release build refuses `WSS` endpoints that have neither pins nor a publicly trusted certificate? → no: without pins, normal CA validation applies | Keeps domains with public certs (or a CDN) possible later |
| Tests: local TLS server with a generated cert; matching pin connects, wrong pin fails, missing pin falls back to CA validation (fails for self-signed) | |

**Scripts** in `otter-server/deploy/` (bash, `set -euo pipefail`, every action printed, idempotent where sensible):

| Script | Runs on | Purpose |
|--------|---------|---------|
| `make-bundle.sh <label>` | admin | Reads `~/.otter-admin`; renders `node.toml` and the unit from `deploy/templates/` (`envsubst`); adds binaries, keys, cert, manifest, decoy site and the pending bootstrap invite; packs `dist/bundle-<label>.tar.gz` (0600) |
| `install.sh` / `uninstall.sh` (inside the bundle) | server, root | §5.3 |
| `push.sh <label> <ssh-target>` | admin | Bundle → `scp` → remote `install.sh` → health check → deletes the local bundle |
| `upgrade.sh <ssh-target> <binary>` | admin | §6 upgrade with automatic rollback |
| `backup.sh --install` | server, root | Daily DB backup timer, keeps 7 |
| `check.sh <label>` | admin | §7 |
| `templates/{node.toml,otter-node.service,otter-backup.{service,timer},site/index.html}` | — | |
| `bundle/health.sh` | server, root | Pinned hello on `127.0.0.1:<port>` with `/etc/otter/probe.env` |

**Testing (done):** `deploy/test/bundle_test.sh` (offline). `deploy/test/vm.sh start|stop|ssh` boots a disposable
Debian 12 `genericcloud` VM under QEMU/KVM (image cached in `~/.cache/otter-vm/`, NoCloud seed as a vfat `CIDATA`
disk, `127.0.0.1:2222→22`, `127.0.0.1:27443→27443`). `deploy/test/e2e.sh` runs install, reinstall, upgrade, upgrade
with a broken binary (exit 2, rollback), checks, daily backup, uninstall, reinstall over kept data, purge.
`e2e.sh --keep` leaves the VM running and prints a bootstrap link; Android `LiveNodeTest` and `LiveProfileTest`
passed against it over pinned TLS (IP-literal host, IP SAN).

## 11. Adding nodes and rolling upgrades (milestone M1.6 — done 2026-11-12)

Admin-side only (D49): thin bash wrappers over `otter-admin`, `push.sh`, `upgrade.sh` and `check.sh`; nothing new
runs on the servers except `otter-node stats`.

**Hosts file.** `~/.otter-admin/hosts` (mode 0600) has one line per node: `label target [port]`, e.g.
`fi-1 root@203.0.113.10` or `fi-2 root@198.51.100.20 2222`. Managed with `deploy/hosts.sh set LABEL TARGET [PORT] |
get LABEL | list | rm LABEL`. An already deployed node is registered with `hosts.sh set`.

| Script | What it does |
|--------|--------------|
| `add-node.sh LABEL root@HOST --ip IP [--ip IPv6] [--domain D] [--wss-port P] [--ssh-port N] [--version V] [--dial-out-only\|--no-dial-out-only]` | Registers the node (for a new node asks whether it is inside a censored network → `dial_out_only`, M7), signs the manifest if it doesn't list the node yet, records the host, waits for DNS (with `--domain`), builds the bundle (with `--version`), runs `push.sh` (install + checks), then publishes the manifest to the other nodes |
| `status.sh` | One row per node: target, version, pinned hello, service state, `otter-node stats` counts, size of `/var/lib/otter`, PUSH (M5); then the last 5 connectivity log lines per node (M7). Read-only; exit 1 on any problem |
| `upgrade-all.sh VERSION [--only LABEL]...` | Builds the release if missing; per node detects the CPU architecture, skips nodes already on VERSION, runs `upgrade.sh`; prints a summary |
| `hosts.sh` | The registry above |

**Resumable.** Every step of `add-node.sh` checks whether it is already done (node registered, manifest lists the
pin, host recorded, DNS ok), so after any failure you fix the cause and re-run the same command; it prints that hint
itself.

**Mesh pickup without restart.** `manifest publish` sends the new manifest to the running nodes. Their Replicator
dials every manifest peer it has no session with, so the existing nodes connect to the new one on their own. Phones
learn the node on their next connection.

**Upgrade order and exit codes.** Nodes are upgraded one at a time in manifest order. Exit 0: all selected nodes are
on VERSION. Exit 2: a node rolled back, the run stops there (earlier nodes stay upgraded, later ones untouched).
Exit 3: an unreachable node or a failed rollback, act now. `--only` with an unknown label is refused.

**Tests.** `deploy/test/scripts_test.sh` (offline, stubbed ssh); `deploy/test/e2e-mesh.sh [--keep]` (two QEMU VMs;
nftables DNAT inside each VM forwards the other node's `127.0.0.1` port via `10.0.2.2`, so the VMs need internet for
`apt` nftables): add-node, replication, status, upgrade-all; `make deploy-test` runs scripts, bundle, e2e and
e2e-mesh. `vm.sh` supports named instances (`OTTER_VM`, `OTTER_VM_SSH`, `OTTER_VM_WSS`; files in `.vm/run-NAME/`).

## 12. Push notifications (milestone M5 — done 2026-11-12)

Optional. Without push, phones check every 15 minutes («Экономия батареи»); with a Firebase service-account key on
at least one node, a message wakes a sleeping phone (D58–D61). One-screen version: `otter-server/deploy/FIRST-DEPLOY.md`
"Push notifications".

**Once (owner):** create a Firebase project (Analytics off), add the Android app `app.ottermsg`, download
`google-services.json` to `otter-android/app/` (ignored by git; then build the APK, see `otter-android/README.md`),
check that "Firebase Cloud Messaging API (V1)" is enabled, and generate a service-account private key (Project
settings → Service accounts) into a private directory outside every repo, e.g. `~/otter-secrets/fcm.json` (mode 0700
directory). Anyone with that key can send pushes to the project's apps; it can be revoked in the same console screen.

**Per node** (the node must already run a release with M5: a pre-M5 `otter-node` rejects the `[push]` section;
`push-key.sh` checks the new config on a copy and stops with `node.toml` unchanged if the binary is too old):

```bash
deploy/push-key.sh fi-1 ~/otter-secrets/fcm.json   # SSH target from the hosts registry (deploy/hosts.sh)
otter-admin node set-push --label fi-1             # push_capable = true in the admin state
otter-admin manifest sign && otter-admin manifest publish
deploy/status.sh                                   # PUSH: on
```

`push-key.sh LABEL KEY` checks that the file is a service-account key, streams it over SSH stdin with `umask 077`
into `/etc/otter/fcm.json.new` (no temp copy anywhere else), installs it as `/etc/otter/fcm.json` (0640
root:otter), adds `[push] fcm_credentials` to `node.toml` if missing, runs `otter-node check` (parses the key, no
network), restarts the service, runs `health.sh` and requires a `push on` log line after the restart. Re-running it
replaces the key. Re-installing or upgrading a bundle keeps the key (`install.sh` never touches `fcm.json`);
`uninstall.sh` removes `/etc/otter`, the key included.

The manifest flag and the key must match (D58): a node flagged `push_capable` without a key never pushes, the other
nodes do not push for messages it accepted, and if it is the first flagged node in manifest order no node pushes for
messages replicated from unflagged nodes. The node logs a warning at start in that case.

**Turn off:** `otter-admin node set-push --label fi-1 --off`, `manifest sign` + `manifest publish`, then remove
`/etc/otter/fcm.json` on the server and `systemctl restart otter-node` (`push off` in the log).

**`status.sh` PUSH column:** the last `push on` / `push off` line in the node's journal since boot; `off` when there
is none, `-` when the node is unreachable over SSH.

Not run against a real server yet (2026-11-12). Offline tests (`deploy/test/scripts_test.sh`, stubbed ssh) cover
`push-key.sh`'s refusals (missing or non-service-account file, unknown host) and the PUSH column, not the install.

## 13. REALITY and dial-out-only nodes (milestone M7 — done 2026-11-13)

For a network with members inside a censored country (D70–D75). One-screen version: `otter-server/deploy/README.md`
"REALITY and dial-out-only nodes".

**Domestic node.** Install it with `add-node.sh` and answer **yes** to «Is LABEL inside a censored network (e.g.
Russia)? It will dial out to the other nodes and is never dialed by them. [y/N]» (or pass `--dial-out-only`;
without a terminal the answer is No). The flag goes into the same manifest signature; re-runs keep it. Existing
node: `otter-admin node set-dial-out-only --label L [--off]` → `manifest sign` + `manifest publish`. Set it only
when every node runs 0.7.0: an older node ignores the flag and keeps dialing.

**REALITY on a foreign node** (node on 0.7.0+, `upgrade-all.sh` first). Choose the camouflage site from the node:

```bash
ssh root@203.0.113.10 /usr/local/bin/otter-node reality-check dl.google.com www.apple.com
# ok   dl.google.com: tls1.3 h2 cert reality 12ms
```

It needs TLS 1.3, HTTP/2, a valid certificate and handshake records ≤ 8 KB; the check runs a REALITY handshake
through the site on loopback. `www.microsoft.com` fails it (its certificate record is over 8 KB, 2026-11-13). Run
it on the domestic node as well (the censor sees that SNI); pick a host that passes on both. Then:

```bash
deploy/reality-setup.sh fi-1 --dest dl.google.com           # --port 443 by default; --force replaces [reality]
otter-admin manifest sign && otter-admin manifest publish    # your terminal (admin passphrase)
```

`reality-setup.sh LABEL --dest HOST [--port 443] [--force]` (SSH target from the hosts registry):

1. runs `reality-check HOST` on the node; refuses an existing `[reality]` without `--force`;
2. writes `node.toml.new` with `[reality]` (`listen`, `private_key_file = "/etc/otter/reality.key"`, `dest`,
   `server_names`, a random short id and VLESS UUID), runs `otter-node reality keygen` (the private key is made on the
   node, 0640 root:otter, never leaves it; an existing key is kept) and `otter-node check` on it;
3. adds the drop-in `/etc/systemd/system/otter-node.service.d/reality.conf` (`CAP_NET_BIND_SERVICE`; new installs
   have it in the unit), opens the port in ufw when ufw is active;
4. keeps `node.toml.pre-reality`, swaps the config, restarts, and requires the health check and a `"reality on"`
   log line; otherwise the previous config is restored and the node restarted;
5. adds the endpoint with `otter-admin node add-reality` (host = the node's first recorded IP, the node's secret
   path, `server_name`, short id, UUID; `fingerprint = chrome`). The WSS endpoint stays first in the manifest.

Allow the port in the provider's cloud firewall too. **Re-installs:** `push.sh` / `add-node.sh` write a fresh
`node.toml` without `[reality]`; run `reality-setup.sh LABEL --dest HOST --force` afterwards (the key file stays, so
the manifest entry stays valid). There is no admin command to remove a REALITY endpoint yet.

**Connectivity log.** `otter-node netlog` (as user `otter`, `--config /etc/otter/node.toml [--limit 50] [--json]`;
safe while the node runs) prints the merged log of peer connections, newest first:

```
2026-11-20 10:02–14:55  ru-1  reality  in  ok  ×143
```

`fail` lines carry a class (`timeout`, `refused`, `reset`, `reset_after_kb` = throttling, `tls`, `handshake`) and a
detail; an endpoint throttled 3× in 24 h is tried last for a day. `status.sh` prints the last 5 lines per node.

**Rollback.** `upgrade.sh` restores `node.toml.prev` together with the old binary. For a manual downgrade below 0.7.0
remove `[reality]` first; the REALITY endpoint left in the manifest then costs peers one failed dial before WSS.

**Tests.** `deploy/test/scripts_test.sh` covers `reality-setup.sh` (stubbed ssh) and the add-node question; meshsim
covers replication over REALITY, the WSS fallback, the camouflage probe (`internal/meshsim/reality_test.go`) and `dial_out_only` (`scenarios_test.go`). Not run on a VM or a real server yet (2026-11-13).
