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
| `otter-node backup` | M1.5 |
| Limits, disk floor, `otter-node status`, `/metrics` on loopback, sandboxed units, `harden-check.sh` | M9.4 (0.10.1; §8, §9) |

**A new network with three nodes, from an empty admin machine to two phones chatting: [§14](#14-three-nodes-from-scratch)**
(one copy-paste runbook). One node only: `otter-server/deploy/FIRST-DEPLOY.md`.

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
  on non-standard ports, but less inconspicuous than a public one. REALITY between nodes (M7, §13) was meant
  for heavy DPI on the link out of a censored country; from Russia it froze too, and the foreign nodes dial the
  domestic node instead (D132).

---

## 2. Requirements

### Server

| Item | Minimum | Notes |
|------|---------|-------|
| CPU / RAM | 1 vCPU, 512 MB | 1 GB recommended once photos arrive (M4) |
| Disk | 10 GB | Photos and backups dominate; plan 20–50 GB for 100 users |
| OS | Debian 12/13 or Ubuntu 22.04/24.04, amd64 or arm64 | Root or sudo via SSH |
| Public IPv4 | yes | IPv6 optional |
| Open inbound ports | SSH, the node port (27443/tcp), the TURN ports for calls | The full table is in §8 |
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
   it **prints a warning** but changes nothing, since a provider's cloud firewall may be in use instead (§8).
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

[turn]                                      # M8, in 0.8.0+ bundles (deploy/README.md "Calls")
enabled  = true
relay_ip = "203.0.113.10"
```

Optional sections, commented out in the template with their defaults (M9.4, D116–D119):

```toml
[limits]
user_quota      = "2GiB"    # live blobs (photos, backups) per member (D44)
max_blob        = "100MiB"
disk_floor      = "1GiB"    # free space under data_dir; below: no photos/backups; below 1/4: no messages either (D118)
user_pending    = "256MiB"  # undelivered messages per sender; over: STATUS_QUOTA, the phone retries; "0" = no cap (D117)
conns_per_ip    = 32        # concurrent connections per source address (IPv6: per /64); loopback exempt (D116)
requests_per_ip = 50        # client requests per second per source, burst 10x (D116)

[metrics]
listen = "127.0.0.1:9477"   # loopback only: a public address is refused at start; "off" disables (D119)
```
Nodes replicate with each other over the same port: the peer endpoint is `<path>/peer`, verified with the
peer's pinned certificate and node key (no extra port or firewall rule).

### 5.5 systemd unit

`/etc/systemd/system/otter-node.service` (template `deploy/templates/otter-node.service`; the 0.10.1 sandbox, D120):

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

UMask=0077

# sandbox (D120). Offline exposure (systemd-analyze security --offline=true): 1.5; the 0.8.x unit scored 3.8.
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
PrivateIPC=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
# No ProcSubset=pid: it hides /proc/sys/net/core/somaxconn and Go would listen with a backlog of 128 (score unchanged).
# AF_NETLINK: listing network interfaces (Go net.Interfaces), needed by the TURN relay (M8)
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
RemoveIPC=true
LockPersonality=true
MemoryDenyWriteExecute=true
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
SystemCallErrorNumber=EPERM
# (Go raises RLIMIT_NOFILE with prlimit64, which @system-service allows; LimitNOFILE above sets it anyway.)
# :443 for REALITY (D72) without root. No PrivateUsers=: the capability would then not count on the host network.
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ReadWritePaths=/var/lib/otter

[Install]
WantedBy=multi-user.target
```

`systemd-analyze security otter-node` rates it **1.5** (the 0.8.x unit: 3.8); the daily backup unit
`otter-backup.service` adds `PrivateNetwork`, `ProcSubset=pid` and an empty `CapabilityBoundingSet=` (**0.5**, was 9.0).
Not used, on purpose: `ProcSubset=pid` on the node (it hides `/proc/sys/net/core/somaxconn`, Go would listen with a
backlog of 128), `PrivateUsers` (breaks `CAP_NET_BIND_SERVICE` for REALITY on :443), `PrivateNetwork`/`IPAddressDeny`
for the node. New installs get both units from the bundle; a node installed before 0.10.1 gets them with
`deploy/sandbox-setup.sh LABEL` (rollback when the node is not healthy under the new unit; `upgrade-all.sh` runs it for
0.10.1+ unless `--no-sandbox`). The service can write only `/var/lib/otter`; everything it reads in `/etc/otter` and
its binary are root-owned.

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
2. Backs up the database with the **installed** binary (`otter-node backup` → `/var/backups/otter/pre-upgrade-<ts>.db`)
   (0600; the newest 3 pre-upgrade copies are kept), so database migrations can be rolled back by restoring. Since
   0.8.3 the chmod, the pruning and a rollback's restore run as `otter`, never as root (D82, D84).
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
timer (`otter-backup.timer`, runs as `otter`) that keeps 7 copies in `/var/backups/otter/`. Since 0.8.3 every copy
is created 0600 in the 0700 directory `/var/backups/otter/` (`O_EXCL|O_NOFOLLOW`, whatever the umask; `upgrade.sh`
also sets older copies to 0600), and only the newest 3 `pre-upgrade-*.db` are kept (D84). Backups contain only ciphertext and metadata, but
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
| Health summary (M9.4) | `otter-node status --config /etc/otter/node.toml` (on the server, as root or `otter`) / `deploy/status.sh` health block | exit 0, no `!` lines; `peers=N/N`, `disk=ok` |
| Hardening (M9.4) | `deploy/harden-check.sh` (admin machine, read-only) | no `FAIL` line |

**`otter-node status`** reads only `<data_dir>/status.json`, which the running node rewrites every 15 s (no database
access, safe while it runs). Exit 0 healthy, 2 problems (each printed as a `! ` line), 1 no status (`error: no status
from the running node …`: the node is not running or older than 0.10.1). `--line` prints the one-line summary that
`status.sh` shows, `--json` everything plus `"problems"`. The problem lines and their thresholds (D119):

| `! ` line | Meaning / what to do |
|---|---|
| `status is X old: is otter-node running?` | status.json older than 60 s: `systemctl status otter-node`, `journalctl -u otter-node -n 50` |
| `peer L down for X` / `peer L not connected since start (X ago)` | no replication session with L in either direction for > 10 min: is L up, is its node port open (§8), what does `otter-node netlog` say (§13)? |
| `peer L lag X (n records)` | L has not confirmed our oldest unsent record for > 10 min (a session that is up but stuck, or very slow) |
| `disk low/critical/full: X free (floor Y)` | free space under `data_dir` below `[limits] disk_floor` (low: no photos/backups), below floor/4 (critical: no new messages either, acks still pass), below 64 MiB (full: replication stops too). Free space or grow the disk; the node recovers by itself within 10 s |
| `push failing: n failures, none sent since start` | ≥ 3 push failures and no success since the start: the FCM key (§12) |

---

## 8. Security checklist

Run `deploy/harden-check.sh` (read-only, all nodes, one SSH call each) after every install and every few months; it
prints `PASS`/`WARN`/`FAIL` for each item below and exits 1 on any `FAIL` or unreachable node. It changes nothing:
fix findings by hand on the server, with the commands below. The same report runs on a server as
`/usr/local/lib/otter/harden-report.sh` (as root).

* **SSH:** key-only login (`PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PubkeyAuthentication
  yes`), `PermitRootLogin prohibit-password`, `X11Forwarding no`, `MaxAuthTries 6` or lower; optionally a
  non-standard port (then `OTTER_SSH_PORT` or `--ssh-port`, §11). On the server, as root; keep your current SSH
  session open until a **new** login works:

  ```bash
  printf '%s\n' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'PubkeyAuthentication yes' \
    'PermitRootLogin prohibit-password' 'X11Forwarding no' 'MaxAuthTries 6' > /etc/ssh/sshd_config.d/00-otter.conf
  sshd -t && systemctl reload ssh
  sshd -T | grep -Ei '^(passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitrootlogin|x11forwarding|maxauthtries) '
  ```

  `sshd -T` prints the effective values (what `harden-check.sh` reads). The first value sshd reads wins, so the file
  name starts with `00-` to come before files like `50-cloud-init.conf`; `/etc/ssh/sshd_config` must include
  `sshd_config.d/*.conf` (Debian 12+ and Ubuntu 22.04+ do, at the top).
* **Security updates:**

  ```bash
  apt-get update && apt-get install -y unattended-upgrades
  dpkg-reconfigure -plow unattended-upgrades          # answer "Yes"
  # without a dialog: echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | debconf-set-selections
  #                   dpkg-reconfigure -f noninteractive unattended-upgrades
  apt-config dump APT::Periodic::Unattended-Upgrade   # APT::Periodic::Unattended-Upgrade "1";
  systemctl is-enabled apt-daily-upgrade.timer         # enabled
  ```

  Reboot when `/var/run/reboot-required` exists (kernel or libc update), one node at a time.
* **Firewall** (ufw on the host and/or the provider's cloud firewall; inbound, everything else closed):

  | Port | Protocol | From | What |
  |---|---|---|---|
  | 22 (or your SSH port) | TCP | your own addresses if they are stable, else anywhere | SSH |
  | the node port (default 27443) | TCP | anywhere | phones and the other nodes (WSS, peer sessions, restore tunnel) |
  | 443 | TCP | anywhere | REALITY, only on nodes with `[reality]` (§13) |
  | 3478 | UDP and TCP | anywhere | TURN (calls) |
  | 5349 | TCP | anywhere | TURN over TLS |
  | 49160–49200 | UDP | anywhere | TURN relay ports |
  | 9477 | — | **never** | `/metrics` listens on 127.0.0.1 only |

  ufw on the server (allow SSH **before** `ufw enable`):

  ```bash
  apt-get install -y ufw
  ufw allow 22/tcp                 # or your SSH port
  ufw allow 27443/tcp              # the node port
  ufw allow 3478/udp && ufw allow 3478/tcp && ufw allow 5349/tcp && ufw allow 49160:49200/udp
  # ufw allow 443/tcp              # only on a node with REALITY
  ufw enable                       # "Command may disrupt existing ssh connections. Proceed?" y
  ufw status verbose               # Status: active, Default: deny (incoming), the rules above
  ```

  `install.sh` adds the SSH and node-port rules itself when ufw is active, and the TURN rules when you answer yes to
  `push.sh`'s question; `turn-setup.sh` and `reality-setup.sh` ask too.

  Cloud firewall (any provider): in the provider's console create a firewall (or "security group"), add one inbound
  rule per row above (source "anywhere" = `0.0.0.0/0` and `::/0`), keep outbound open, attach it to the server.
  Then check from the admin machine: `deploy/check.sh LABEL root@HOST` (`pinned hello` and `decoy site` PASS = the
  node port is open), `deploy/status.sh` (TURN `on`); a call between two phones on mobile data proves the UDP ports.
  A peer that stays down in `status.sh` (`! peer L …`) usually means a node port closed between servers.
* **Shared hosts:** when a node runs on a machine that also serves other things, every public listener that is not
  `otter-node` or `sshd` shows up as a `WARN listener` line (address, port, process) in `harden-check.sh`. For each
  one decide: must it be reachable from the internet? If not, bind it to 127.0.0.1 or close it in the firewall. Keep
  the list of such services and the decisions **outside the repositories** (they reveal what else runs on the host).
* **Service sandbox:** `otter-node` runs as `otter` (no shell, no sudo) with the systemd sandbox of §5.5. Read the
  score on a server (read-only; ask the server's owner first if it is not yours):

  ```bash
  ssh root@HOST 'systemd-analyze security otter-node --no-pager | tail -n1'
  # → Overall exposure level for otter-node.service: 1.5 OK
  ```

  The full listing marks each setting `✓` or `✗`; the `✗` lines left on purpose are those §5.5 names (`PrivateNetwork`,
  `PrivateUsers`, `IPAddressDeny`, `ProcSubset`, the address families and `CAP_NET_BIND_SERVICE` the node needs). The
  number can differ a little between systemd versions; `harden-check.sh` passes anything ≤ 2.0
  (`PASS sandbox: exposure 1.5`). Above 2.0 the node still has an older unit: `deploy/sandbox-setup.sh LABEL`.
* **Monitoring:** `/metrics` only on `127.0.0.1:9477` (a public `[metrics] listen` is refused at start; port 9477
  is never opened in a firewall); read it over SSH ([08](08-operations.md) "Monitoring").
* **Files:** the binary, `/usr/local/lib/otter/*.sh` and `/etc/otter` are root-owned and not writable by group or
  others; `node.key`, `tls.key`, `turn.secret`, `reality.key`, `fcm.json`, `node.toml` are `root:otter 0640`
  (readable by root and the `otter` group only); `/var/lib/otter` is `otter 0700`. The network key is never on a server.
* Root never handles files in `/var/lib/otter` or `/var/backups/otter`; deploy scripts do that as `otter` (D82).
  Files root holds (APKs, invites) reach `otter` on stdin; `release-apk.sh` refuses nodes older than 0.8.3.
* The connectivity log (`otter-node netlog`) forgets lines not updated for 7 days, rejected source IPs included (D85).
* Servers hold no secrets that can read messages. A seized server exposes metadata ([04](04-security.md)),
  and its TLS key would let someone impersonate that node at the transport layer. Rotate it (§6). Message
  content stays end-to-end encrypted regardless.
* **Blocking note:** connections to well-known foreign hosting ranges are a common target for throttling, and a rare
  port with a self-signed certificate is easier to single out than 443 with a public certificate. Phones in the
  restricted network use a domestic node; the foreign nodes dial it, because links it starts out of Russia freeze
  after a few KB (D132, §13). A bare-metal machine inside the restricted network is a good candidate for that
  domestic node.

What `harden-check.sh` prints (one line per check, `PASS`/`WARN`/`FAIL name: detail`):

| Check | FAIL / WARN when | Fix |
|---|---|---|
| `ssh-password`, `ssh-root` | FAIL: password login on, `PermitRootLogin` other than `prohibit-password`/`no` | SSH item above |
| `ssh-kbd`, `ssh-pubkey`, `ssh-x11`, `ssh-tries` | WARN: keyboard-interactive on, public keys off, X11 on, `MaxAuthTries` > 6 | SSH item above |
| `updates` | FAIL: unattended-upgrades not installed or not enabled | updates item above |
| `updates-timer`, `updates-run`, `reboot` | WARN: timer disabled, last run > 3 days ago, reboot pending | `systemctl enable --now apt-daily-upgrade.timer`; reboot |
| `firewall` | WARN: ufw inactive (fine if the cloud firewall has exactly the table above) | firewall item above |
| `listener` | WARN: a public listener that is not `otter-node`/`sshd` | shared-host item above |
| `metrics` | FAIL: `/metrics` on a public address | remove `[metrics] listen` from `node.toml`, restart |
| `sandbox`, `sandbox-backup` | WARN: exposure over 2.0 | `deploy/sandbox-setup.sh LABEL` |
| `otter-user` | FAIL: `otter` has a shell, an admin group or a sudoers line | `usermod -s /usr/sbin/nologin otter`; remove the group/line |
| `file`, `data-dir` | FAIL: a file above not root-owned, group/world-writable or a key readable by others; WARN: data dir not `otter 0700` | e.g. `chown root:otter /etc/otter/tls.key && chmod 0640 /etc/otter/tls.key`; `chown root:root /usr/local/bin/otter-node && chmod 0755 /usr/local/bin/otter-node`; `chown otter:otter /var/lib/otter && chmod 0700 /var/lib/otter` |
| `clock` | WARN: NTP not synchronized | `timedatectl`; `systemctl restart systemd-timesyncd` |

On Ubuntu 24.04 sshd can be socket-activated; a `WARN listener` naming `systemd` on your SSH port is that socket.

---

## 9. What changes in later milestones

| Milestone | Deployment change |
|-----------|-------------------|
| M2 | 2–3 nodes; node↔node traffic uses the same node port, authenticated by pins + node keys; `otter-admin manifest publish --via`; apps follow manifest updates, which enables TLS rotation (§6) |
| M4 (done) | `/var/lib/otter/blobs/` holds photos until every reader has them (≤ 30 days); size disks for peaks (`[limits] user_quota`, default 2 GiB per member); optional `[limits]`/`[replication]` in `node.toml` (commented defaults in the template); not in backups |
| M5 (done) | Optional `/etc/otter/fcm.json` (Firebase service account) on push-capable nodes, installed with `deploy/push-key.sh`; `[push]` in `node.toml`; DB migration 0006 runs on upgrade. Upgrade a node to M5 **before** `push-key.sh` (§12) |
| M6 (done) | `/var/lib/otter/blobs/` also holds members' password backups (persistent blobs, ≤ 3 per member, counted in `user_quota`); nothing to configure; DB migration 0005 runs on upgrade. Upgrade all nodes (`upgrade-all.sh`) before relying on restore: an older node answers `auth.login` without `installed_ms` and does not know the backup methods |
| M7 (done) | Optional `[reality]` in `node.toml` + `/etc/otter/reality.key` on foreign nodes, listening on :443 (`CAP_NET_BIND_SERVICE`; clients stay on the node port, D26 revised for REALITY only), set up with `deploy/reality-setup.sh` after the node runs 0.7.0; `dial_out_only` for a domestic node (`add-node.sh` asks); DB migration 0008 (`netlog`); `upgrade.sh` also rolls back `node.toml` (§13) |
| M9.4 (done, 0.10.1) | `[limits]` gains `disk_floor`, `user_pending`, `conns_per_ip`, `requests_per_ip`; `[metrics]` (loopback only, default `127.0.0.1:9477`); the node writes `/var/lib/otter/status.json`; `otter-node status`; `status.sh` health block; sandboxed `otter-node.service` / `otter-backup.service` via `sandbox-setup.sh` (also run by `upgrade-all.sh` for 0.10.1+, `--no-sandbox` skips it); read-only `harden-check.sh` (`harden-report.sh` installed to `/usr/local/lib/otter/`). No DB migration (M9.0–M9.3 brought 0009–0015); nothing to change in `node.toml` |

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
| `add-node.sh LABEL root@HOST --ip IP [--ip IPv6] [--domain D] [--wss-port P] [--ssh-port N] [--version V] [--dial-out-only\|--no-dial-out-only]` | Registers the node (for a new node asks whether to make it `dial_out_only`, M7: only for a node that cannot accept inbound connections; never for a node in Russia, D132), signs the manifest if it doesn't list the node yet, records the host, waits for DNS (with `--domain`), builds the bundle (with `--version`), runs `push.sh` (install + checks), then publishes the manifest to the other nodes |
| `status.sh` | One row per node: target, version, pinned hello, service state, `otter-node stats` counts, size of `/var/lib/otter`, PUSH (M5), TURN (M8); then the last 5 connectivity log lines per node (M7); then each node's `otter-node status --line` health line and `! ` problems (M9.4, 0.10.1+). Read-only; exit 1 on any problem |
| `upgrade-all.sh VERSION [--only LABEL]... [--no-news] [--no-turn] [--no-sandbox]` | Builds the release if missing; per node detects the CPU architecture, skips nodes already on VERSION, runs `upgrade.sh`; 0.8.0+: `turn-setup.sh --if-missing`; 0.10.1+: `sandbox-setup.sh --if-older`; prints a summary |
| `harden-check.sh [LABEL...]` | M9.4: read-only hardening report per node (§8); exit 1 on a FAIL or an unreachable node |
| `sandbox-setup.sh LABEL [--if-older]` | M9.4: installs the sandboxed units (§5.5) with rollback; exit 0 installed or current, 2 rolled back, 3 act now |
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

**Domestic node (D132).** Install it with `add-node.sh` and answer **No** to «Make LABEL dial-out-only? …
[y/N]» (the default; or pass `--no-dial-out-only`); keep its node port reachable from abroad. The foreign nodes dial
it and one session carries both directions. On 2026-11-15 every link the node in Russia started to foreign hosting
froze after ~11–20 KB (direct WSS, REALITY, a CDN-proxied hostname), while links started from abroad carried bulk
data. A node marked earlier: `otter-admin node set-dial-out-only --label L --off` → `manifest sign` + `manifest
publish`. Dial-out-only stays for a node that cannot accept inbound connections (e.g. behind NAT); the flag goes into
the same manifest signature, re-runs keep it, and it needs every node on 0.7.0+ (an older node ignores it).

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

## 14. Three nodes from scratch

One runbook from an empty admin machine to two phones chatting through three nodes. Every command is meant to be
copied; after each step: what you should see, and what to do when you see something else. Nothing here needs
knowledge outside this document and the `otter-server` / `otter-android` repositories. Background for each step is
in the sections it links to.

Names used below; replace them everywhere:

| Placeholder | Example | Meaning |
|---|---|---|
| `node-a`, `node-b` | — | labels of the two nodes outside the censored network (lowercase letters, digits, `-`) |
| `node-c` | — | label of the node **inside** the censored network (the "domestic" node, D70, D132) |
| `203.0.113.10`, `.20`, `.30` | — | public IPv4 of node-a, node-b, node-c |
| `chat-a.example.org` … `chat-c.example.org` | — | optional domain per node (recommended, D25); without one the node is reached by its IP |
| `0.10.1` | — | the server release you deploy (the current one) |

### 14.1 What you need

* **Three servers:** Debian 12/13 or Ubuntu 22.04/24.04, amd64 or arm64, ≥ 1 vCPU, ≥ 1 GB RAM, ≥ 10 GB disk, a
  public IPv4, root login over SSH with a key (§2). node-c is inside the censored network; its node port must be
  reachable from the internet, because the other two nodes dial it (D132).
* **Admin machine:** Linux with Go ≥ 1.26 (`go version`), `git`, `make`, `ssh`/`scp`, `curl`, `envsubst`
  (Debian/Ubuntu package `gettext-base`), `tar`, `sha256sum`. It keeps the network key; the servers never get it.
* **Two Android phones** (8.0 or newer) and the Otter APK (step 14.10).
* Optional: a Firebase service-account key for push wake-ups (§12).

The scripts read these variables (`otter-server/deploy/README.md` "Environment"); set them in the shell you use for
every step:

```bash
export OTTER_SSH_OPTS="-i $HOME/.ssh/otter"   # only if your key is not the default one; use $HOME, not ~
# export OTTER_SSH_PORT=2222                  # only if every server's SSH is on another port (per node: --ssh-port)
```

The admin state lives in `~/.otter-admin`. To keep it elsewhere, `export OTTER_ADMIN_DIR=/path` for the scripts **and**
run every `bin/otter-admin` command below as `bin/otter-admin --dir "$OTTER_ADMIN_DIR" …` (otter-admin itself does not
read the variable).

### 14.2 Check SSH to each server

```bash
for h in 203.0.113.10 203.0.113.20 203.0.113.30; do ssh $OTTER_SSH_OPTS root@$h 'echo ok; . /etc/os-release; echo $PRETTY_NAME'; done
```

**Expected:** `ok` and the OS name three times, no password prompt.
**If not:** a password prompt or `Permission denied (publickey)` → add your public key to `/root/.ssh/authorized_keys`
through the provider's console; a host-key question → answer `yes` once; `Connection timed out` → the SSH port is
closed in the provider's firewall.

### 14.3 Prepare each server (SSH, updates, firewall)

On **each** server (`ssh root@203.0.113.10`, …), run the three blocks of §8: **SSH** (drop-in file, `sshd -t`,
reload, `sshd -T` check), **Security updates** (`unattended-upgrades`) and **Firewall** (the ufw block, all rows:
SSH, node port 27443, TURN 3478/udp, 3478/tcp, 5349/tcp, 49160:49200/udp). If the provider has a cloud firewall,
add the same rows there (§8, "Cloud firewall"). Before closing the root session, open a second terminal and check
`ssh root@203.0.113.10 true` still works.

**Expected:** `sshd -T` shows `passwordauthentication no`, `kbdinteractiveauthentication no`,
`pubkeyauthentication yes`, `permitrootlogin prohibit-password`, `x11forwarding no`, `maxauthtries 6`;
`apt-config dump APT::Periodic::Unattended-Upgrade` shows `"1"`; `ufw status verbose` shows `Status: active`,
`deny (incoming)` and the six rules (twice, `(v6)` too).
**If not:** `sshd -t` prints an error → fix the named line, nothing was reloaded; `sshd -T` still shows `yes` for
passwords → a file sorting before `00-otter.conf` sets it, or `sshd_config` lacks the `Include` line (§8); the new
SSH login fails after `ufw enable` → use the provider's console: `ufw allow 22/tcp`.

### 14.4 Build the tools and the release (admin machine)

```bash
git clone <URL of the otter-server repository> otter-server
cd otter-server
make build                      # → bin/otter-admin, bin/otter-node (used by the scripts)
make release VERSION=0.10.1     # → dist/otter-node_0.10.1_linux_{amd64,arm64}, dist/otter-admin_0.10.1_…, dist/SHA256SUMS
ls dist/
```

All later commands run in `otter-server/`. `make check` runs the tests first (optional; the race detector needs `gcc`).

**Expected:** `dist/` lists `otter-node_0.10.1_linux_amd64`, `otter-node_0.10.1_linux_arm64`, `otter-admin_0.10.1_…`
and `SHA256SUMS`.
**If not:** `go: command not found` or `go.mod requires go >= 1.26` → install Go 1.26 from go.dev and repeat; the
scripts later say `build the tools first: make build` when `bin/` is missing.

### 14.5 Create the network (admin machine, once)

```bash
bin/otter-admin network init
```

Type a passphrase of at least 12 characters twice (it is never stored; every signing step asks for it).
**Expected:** `network created in /home/<you>/.otter-admin`, `network_pub <64 hex digits>`.
**If not:** `network in … already exists` → this machine already has a network; use it, or set `OTTER_ADMIN_DIR` to a
new directory (§14.1).

Back up `~/.otter-admin/` and the passphrase now (encrypted USB stick, password manager): without them nobody can
sign manifests, add nodes or rebuild a bundle.

### 14.6 First node with the bootstrap invite (node-a)

```bash
bin/otter-admin node add --label node-a --wss-host chat-a.example.org --ip 203.0.113.10
bin/otter-admin manifest sign
bin/otter-admin invite bootstrap
deploy/add-node.sh node-a root@203.0.113.10 --ip 203.0.113.10 --domain chat-a.example.org
```

Without a domain: `--wss-host 203.0.113.10` in `node add` and no `--domain` in `add-node.sh`. The `--ip` of
`add-node.sh` must be given again (it is required even when the node is already registered).

**Expected**, in order:
1. `node add`: `node node-a added, node_id <hex>`, `Run 'manifest sign' to publish.`
2. `manifest sign` (passphrase): `signature OK` and the manifest as JSON with one node.
3. `invite bootstrap` (passphrase): `Invite for the first member (valid 168h0m0s):`, an `otter://join/…` link and a QR
   code. **Keep the link** (copy it into a note): it is for the first phone in step 14.10 and valid 7 days.
4. `add-node.sh`: `node node-a already exists: skipping node add`, `the signed manifest already lists node-a`,
   `node-a → root@203.0.113.10`; with `--domain`: `create these DNS records now (TTL 300):` and an `A` record
   → create it at your DNS provider; the script waits (`waiting for DNS (up to 30 min …)`) and goes on by itself.
   Then `If ufw is active on node-a, allow the TURN ports for calls (…)? [y/N]` → `y` (you use ufw, step 14.3).
   Then the install on the server (`==> verifying SHA256SUMS`, `==> creating system user otter`,
   `==> importing <hex>.bin`, `==> node is up: 0.10.1, wss://chat-a.example.org:27443/<path>`) and the check table:

   ```
   DNS                          PASS (…)
   pinned hello                 PASS (…)
   wrong pin rejected           PASS
   decoy site                   PASS
   service                      PASS
   clock synchronised           PASS
   server-side health           PASS
   listed in manifest           PASS
   ==> all checks passed for node-a
   ==> bootstrap invite delivered; send its link to the first member
   ==> done: node-a is part of the network; phones learn about it on their next connection
   ```

**If not:** the script stops with `add-node stopped (exit N): fix the cause and re-run the same command` — fix and
re-run `deploy/add-node.sh` with the same arguments; finished steps are skipped. Common causes:

| Message | Cause and fix |
|---|---|
| `DNS for chat-a.example.org is not correct yet` | the `A` record is missing or still propagating: `bin/otter-admin dns check --label node-a`, fix the record, re-run |
| `error: port 27443 is in use: …` (from `install.sh`) | another program holds the port: stop it, or start over for this node with another port (`bin/otter-admin node remove --label node-a`, then `node add … --wss-port P`, `manifest sign`, `invite bootstrap` again, `add-node.sh … --wss-port P`) |
| `pinned hello FAIL` / `decoy site FAIL`, but `service PASS` | the node port is closed between the admin machine and the server: ufw or the cloud firewall (step 14.3) |
| `clock synchronised FAIL` | the clock is still syncing: wait a minute, `deploy/check.sh node-a root@203.0.113.10` |
| `install failed on root@…; the local bundle is kept in dist/` | read the `error:` line above it; re-run after the fix |

### 14.7 Second node (node-b)

```bash
deploy/add-node.sh node-b root@203.0.113.20 --ip 203.0.113.20 --domain chat-b.example.org
```

**Expected:** `registering node node-b`, `node node-b added …`, then the question `Make node-b dial-out-only? … [y/N]`
→ press Enter (No). `signing the manifest (asks for the admin passphrase)` → passphrase; DNS record and wait as in
14.6; TURN question → `y`; install; the check table ending in `all checks passed for node-b`; then
`publishing the new manifest to the running nodes` with one line per node:

```
node-a       ok
node-b       already current
```

**If not:** as in 14.6. `node-a  error: …` in the publish lines → node-a is not reachable from the admin machine
right now; once it is, `bin/otter-admin manifest publish` (no passphrase needed).

### 14.8 Node inside the censored network (node-c)

```bash
deploy/add-node.sh node-c root@203.0.113.30 --ip 203.0.113.30 --domain chat-c.example.org
```

Answer **No** (Enter) to `Make node-c dial-out-only? …`: a node in a censored country is dialed by the foreign nodes,
because links it starts to foreign hosting freeze (D132); one session carries both directions. **Expected:** as in
14.7, with three publish lines (`node-a ok`, `node-b ok`, `node-c already current`).

Then keep backups away from it (D113; every node runs 0.10.1, so this is safe right away):

```bash
bin/otter-admin node set-no-backups --label node-c
bin/otter-admin manifest sign
bin/otter-admin manifest publish
bin/otter-admin node list
```

**Expected:** publish prints `ok` per node; `node list` shows `no_backups=true` on node-c's line. Phones in the censored
network then restore backups through node-c's tunnel to a foreign node (D114).

*Variant — a node that cannot accept inbound connections at all* (behind NAT, no public port): answer `y` to the
question (or pass `--dial-out-only`). It dials the two others and is never dialed; nothing else in this runbook changes
(`status.sh` shows `peers=2/2` for it as well). The admin-side checks of `add-node.sh` still need its node port
reachable from the admin machine.

### 14.9 Check the three nodes

Wait a minute (each node rewrites its status every 15 s and dials missing peers on its own), then:

```bash
deploy/status.sh; echo "exit $?"
deploy/harden-check.sh; echo "exit $?"
```

**Expected from `status.sh`:** three rows with `VERSION 0.10.1`, `HELLO ok`, `SERVICE active`, `TURN on`
(`PUSH off` until §12); a `connectivity log` block with `ok` lines between the nodes; and

```
health (otter-node status; "!" = needs attention):
  node-a  peers=2/2 lag=0s backlog=0 disk=ok free=… sessions=0 push=0/0 turn=0 rejected=0
  node-b  peers=2/2 lag=0s backlog=0 disk=ok free=… sessions=0 push=0/0 turn=0 rejected=0
  node-c  peers=2/2 lag=0s backlog=0 disk=ok free=… sessions=0 push=0/0 turn=0 rejected=0
exit 0
```

**Expected from `harden-check.sh`:** per node only `PASS` lines (`ssh-*`, `updates`, `firewall: ufw active`,
`metrics: 127.0.0.1:9477`, `sandbox: exposure 1.5` or close, `sandbox-backup: exposure 0.5` or close, `otter-user`,
`files`, `clock`), ending with `no FAIL; review the WARN lines` and `exit 0`.

**If not:**

| You see | Do |
|---|---|
| `peers=1/2` or `peers=0/2`, `fail` lines in the connectivity log | a node port is closed between two servers: ufw/cloud firewall on the node named in the `fail` lines (§8); `ssh root@203.0.113.30 'runuser -u otter -- /usr/local/bin/otter-node netlog --config /etc/otter/node.toml --limit 20'` shows the class (`timeout`, `refused`, `tls`, …, §13) |
| `! peer node-x not connected since start (…)` | the same, for more than 10 minutes |
| `! disk low: …` | less than 1 GiB free under `/var/lib/otter`: grow the disk (§7 table) |
| `HELLO FAIL` | the node port is not reachable from the admin machine (§14.6 table) |
| `! no status from the running node …` | `ssh root@HOST systemctl status otter-node`; `journalctl -u otter-node -n 50` |
| `FAIL ssh-…`, `FAIL updates` | step 14.3 was skipped on that node; do it, run `harden-check.sh` again |
| `WARN listener …` | something else listens publicly on that server (§8 "Shared hosts") |
| `WARN reboot` | `ssh root@HOST reboot`, one node at a time; `deploy/status.sh` again afterwards |

### 14.10 Two phones

**APK.** Build it from `otter-android` (JDK 21 and the Android SDK, see `otter-android/README.md`):
`./gradlew :app:assembleDebug` → `app/build/outputs/apk/debug/app-debug.apk` (works with any network; a release APK
needs the release signing key, `otter-android/README.md` "News and in-app updates"). Install it on both phones
(`adb install app-debug.apk`, or copy the file and open it; allow installing from that source).

1. **Phone 1:** «Присоединиться по приглашению» → scan the QR code from step 14.6 (or open the `otter://join/…` link
   on the phone) → name and username → write down the 24 recovery words → confirm three of them.
2. **Phone 2:** on phone 1 Settings → Семья → «Пригласить в семью» shows a QR code; phone 2 «Присоединиться по
   приглашению» scans it, then the same steps.
3. Write a message each way; send a photo; open the chat's call button (top bar) and talk for a minute.
4. Settings → Подключение on each phone shows which node it uses (`node-x · WSS`); «Состояние сети» lists all three
   nodes with their last success.

**Expected:** messages get ✓✓ and are read on the other phone; the photo arrives; the call connects with audio both
ways. `deploy/status.sh` now shows `sessions=` ≥ 1 on the nodes the phones use, and `otter-node stats` (STATS column)
`users=2`.
**If not:** «Срок приглашения истёк» on phone 1 → `bin/otter-admin invite bootstrap` again (a new link; the old
one stays unused); a phone stays «Подключаемся…» → Settings → Подключение → «Состояние сети» shows the last failure
per node (blocked port, wrong time on the phone: logins need the phone clock within 5 minutes); the call does not
connect on mobile data → the TURN UDP ports (step 14.3) in the cloud firewall; the photo stays pending → `! disk`
lines in `status.sh`.

### 14.11 Signature cut-over (once, now)

A new network runs only 0.10.1 nodes and apps, so it can switch to network-bound signatures (v2, D109, D110) at once:

```bash
bin/otter-admin manifest sign --sig-v1-until "$(date -u -d '+48 hours' +%Y-%m-%dT%H:%M:%SZ)"
bin/otter-admin manifest publish
```

**Expected:** `v1 signatures end at <time>; this and every later manifest, invite, network record and announcement is
signed v2.`, `signature OK`, a `sig_v1_until:` line; publish prints `ok` per node. Then one more message each way
between the phones. Any phone that joins later must run app 0.10.0 or newer. The time can never be changed
([08](08-operations.md) "Signature cut-over").

### 14.12 Optional, then day 2

* **Push wake-ups** (a message wakes a sleeping phone within seconds): §12, on one or more nodes outside the censored
  network; afterwards `deploy/status.sh` shows `PUSH on` there.
* **REALITY** (§13) is not needed for this layout (D132).
* **Day 2:** `deploy/status.sh` whenever something seems off (exit 0 = all healthy); `deploy/harden-check.sh` every few
  months and after reboots; upgrades with `deploy/upgrade-all.sh VERSION` (one node at a time, automatic rollback,
  §6, §11); members with `otter-admin user list | revoke` and lost phones with `user rekey` ([08](08-operations.md));
  monitoring over SSH ([08](08-operations.md) "Monitoring"). With three nodes, database backups are optional (§6);
  keep `~/.otter-admin/` backed up.
