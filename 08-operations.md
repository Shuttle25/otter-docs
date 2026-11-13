# 08 — Operations

## Topologies

| Nodes | Typical placement | What you get |
|-------|-------------------|--------------|
| 1 | One VPS (or home server) | Fully working messenger; no redundancy |
| 2 | Two hostings in different countries/providers | Survives one hosting outage; two independent IPs to reach |
| 3 | E.g. 1 domestic (inside restricted network) + 2 foreign on different providers | Survives outages and most blocking scenarios: domestic node stays reachable for clients and relays to foreign nodes over REALITY |

Minimum per node: 1 vCPU, 512 MB RAM, 10 GB disk (more for media), Linux amd64/arm64.

## The admin CLI (`otter-admin`)

Admin keys live on the admin's own machine. `network.key` is stored **encrypted with a
passphrase** (Argon2id + XChaCha20-Poly1305); `otter-admin` asks for the passphrase when
signing. There are two admins (owner + one trusted person): both hold a copy of the same
encrypted `network.key` — copies are equivalent. Keep one extra offline backup (e.g. USB
stick in a safe place). Losing every copy means a new network must be created; a leaked
copy means rotating to a new network key (re-invite everyone), so guard it carefully.

```
otter-admin key export --out network.key.enc   # to share with the second admin
otter-admin key import network.key.enc
```

```
otter-admin network init                    # creates network.key (Ed25519), VLESS UUID
otter-admin node add --label fi-1 \
    --reality host=1.2.3.4,port=443,server-name=www.example.com \
    --wss host=chat.example.org,path=/k3J9...,cdn=true
                                            # generates node.key + reality keys, prints node bundle
otter-admin node remove fi-1
otter-admin node set-push --label fi-1 [--off]   # M5: mark push_capable (after deploy/push-key.sh)
otter-admin node set-dial-out-only --label ru-1 [--off]   # M7: never dialed by the other nodes (D71)
otter-admin node add-reality --label fi-1 --host H --port 443 --pub B64URL --server-name dl.google.com
                                            # M7: REALITY endpoint (normally via deploy/reality-setup.sh, D72)
otter-admin news init | show | revoke --pub HEX  # M6.5: news key in the desktop keyring (D65); then manifest sign
otter-admin announce --ru ru.txt --en en.txt [--apk F --version-name V --version-code N]
otter-admin announce --list | --delete ID_PREFIX # news to every node (D66, D67)
otter-admin manifest sign                   # bump version, write manifest.bin
otter-admin manifest publish --via <node>   # push new manifest into the mesh
otter-admin invite bootstrap                # first user's invite (QR in terminal + link)
otter-admin user revoke <username>
otter-admin status --via <node>             # peers, lag, storage, users
```

## Deploying a node

See **[11 — Server deployment](11-deployment.md)** (authoritative: build, bundle, install, systemd unit,
upgrades, backups, health checks) and `otter-server/deploy/README.md` (one-screen command reference for day 2:
`push.sh`, `upgrade.sh`, `check.sh`, `node set-ip`, `rotate-tls`, `push-key.sh` + `node set-push`, backups, uninstall).

## Adding / replacing a node (e.g. hosting died or IP blocked)

1. `otter-admin node add ...` on admin machine → deploy new node with its bundle.
2. `otter-admin manifest sign && otter-admin manifest publish --via <any working node>`.
3. New node joins the mesh, receives a snapshot, starts serving.
4. Clients learn the new manifest from whichever node they reach next.
5. Remove the dead node from the manifest when certain it's gone.

## Upgrades

* Protocol is versioned (`hello` carries protocol version; protobuf fields only added, never reused).
* Roll nodes one at a time; mixed versions must interoperate for ≥1 minor version.
* `min_app_version` in manifest forces app update only for breaking changes.
* App updates are distributed as APK. Since M6.5 the nodes serve it: `deploy/release-apk.sh VERSION APK` imports a
  release-signed APK into every node and offers an announcement with an «Обновить» button; phones download it over
  their pinned connection and check its SHA-256 (D68, D69). `upgrade-all.sh` offers the same news dialog
  (`--no-news` skips). Google Play optional.

## Calls: TURN relay (M8, D77)

Every 0.8.0+ node can relay calls. Steps and checks (details in `otter-server/deploy/README.md`, "Calls (TURN, M8)"):

* **Order for 0.8.0**: upgrade every node first (`deploy/upgrade-all.sh 0.8.0`), check `deploy/status.sh`, then
  release the app (`deploy/release-apk.sh 0.8.0 APK`). Phones on a node without TURN show «Звонки недоступны: сервер
  не обновлён».
* **`deploy/turn-setup.sh LABEL [--if-missing|--force]`** turns TURN on for one node: refuses nodes below 0.8.0
  (`version_ge`) and nodes without an IPv4 address in the admin dir (`relay_ip`), creates `/etc/otter/turn.secret`
  on the node if missing (`otter-node turn keygen`; 32 bytes, 0640 root:otter, never printed or copied), writes
  `[turn]` into `node.toml.new`, runs `otter-node check`, keeps `node.toml.pre-turn`, swaps, restarts and waits for
  the health check and the `"turn on"` log line; on failure the previous config is back. `--if-missing` leaves a node
  that already has `[turn]`; `--force` rewrites the section (the secret is kept).
* **`upgrade-all.sh`** runs `turn-setup.sh --if-missing` on every node once it runs ≥ 0.8.0 (also on nodes already on
  the version); `--no-turn` skips it. A TURN failure does not stop the rollout: the summary says `TURN NOT ENABLED`.
  New nodes: `make-bundle.sh` adds `[turn]` to 0.8.0+ bundles and `install.sh` creates the secret.
* **Firewall**: the relay needs **UDP 3478, TCP 3478, TCP 5349, UDP 49160–49200** (`TURN_PORTS` in `deploy/lib.sh`).
  ufw on the node is changed **only on an explicit yes** on the admin's terminal (default No; `install.sh` via
  `push.sh`, `turn-setup.sh` after TURN is up); otherwise the commands are printed. **Cloud firewalls** (hosting
  panel) are opened by hand; the scripts only remind.
* **Status**: `deploy/status.sh` has a TURN column (`on` / `off`; `-` = no `[turn]`, e.g. below 0.8.0) and the STATS
  column gets `turn_allocs=` / `turn_relayed_bytes=` from `otter-node stats` (snapshot `<data_dir>/turn.stats.json`,
  shown when < 60 s old). TURN problems (bad or expired logins, quota, listener start) are in `otter-node netlog`
  with classes `auth`, `quota`, `listen`.
* **Rotation**: `otter-node turn keygen --force` + restart gives a new secret; phones ask for credentials on every
  call, so the next call already uses it.
* **Downgrade** below 0.8.0: remove `[turn]` first (or restore `node.toml.pre-turn`); 0.7.0 refuses the section.
  Re-installs (`push.sh`) rewrite `node.toml` from the template, which for 0.8.0+ includes `[turn]` again.

## Backups of nodes

Not required for correctness (state is replicated and mostly temporary). For a 1-node setup,
daily `otter-node backup` copies are recommended (`/usr/local/lib/otter/backup.sh --install`: a systemd timer,
7 kept in `/var/backups/otter`). The blobs directory (`/var/lib/otter/blobs`, M4) is **not** backed up: photo blobs are
transient — deleted once every reader has them — and the phone keeps the original (D24/D48). Users' password
backups (M6, D50) are persistent blobs in the same directory, on every node; they are **not** transient. `otter-node
backup` copies only the database (backup records, not the chunk files); a rebuilt node pulls the backup chunks back
from its peers, so nothing needs to be configured.

## Monitoring

* `otter-node status` and `/metrics` (localhost).
* Alert ideas: peer lag > 10 min, disk > 80 %, no client sessions for > 1 h during daytime,
  push failures.
