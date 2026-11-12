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
* App updates are distributed as APK (Obtainium / direct link / F-Droid-style repo);
  Google Play optional.

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
