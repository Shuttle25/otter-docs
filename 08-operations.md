# 08 — Operations

## Topologies

| Nodes | Typical placement | What you get |
|-------|-------------------|--------------|
| 1 | One VPS (or home server) | Fully working messenger; no redundancy |
| 2 | Two hostings in different countries/providers | Survives one hosting outage; two independent IPs to reach |
| 3 | E.g. 1 domestic (inside restricted network) + 2 foreign on different providers | Survives outages and most blocking scenarios: domestic node stays reachable for clients; the foreign nodes dial it (D132). Step by step: [11](11-deployment.md) §14 |

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
otter-admin node set-dial-out-only --label L [--off]     # M7: never dialed by the other nodes (D71); only for a
                                            # node that cannot accept inbound; a node in Russia stays --off (D132)
otter-admin node set-no-backups --label L [--off]        # M9.3: the node keeps no backups at rest, hands phone
                                            # uploads to the other nodes and serves the restore tunnel (D113, D114)
otter-admin node add-reality --label fi-1 --host H --port 443 --pub B64URL --server-name dl.google.com
                                            # M7: REALITY endpoint (normally via deploy/reality-setup.sh, D72)
otter-admin news init | show | revoke --pub HEX  # M6.5: news key in the desktop keyring (D65); then manifest sign
otter-admin announce --ru ru.txt --en en.txt [--apk F --version-name V --version-code N]
otter-admin announce --list | --delete ID_PREFIX # news to every node (D66, D67)
otter-admin manifest sign                   # bump version, write manifest.bin
otter-admin manifest sign --sig-v1-until 2026-12-01T12:00:00Z
                                            # M9.3, once: the signature v2 cut-over (D110, see below)
otter-admin manifest publish --via <node>   # push new manifest into the mesh
otter-admin invite bootstrap                # first user's invite (QR in terminal + link; the link carries
                                            # the signed INVITE, M9.2 — importing it on a node is optional)
otter-admin user list | revoke | invite-rights | found   # M9.2 members, see "Members" below
otter-admin user rekey NAME --old CODE | --new CODE      # M9.3 lost phone, see "Lost phone" below
otter-admin status --via <node>             # peers, lag, storage, users
```

## Members (M9.2, D99–D101)

Membership is decided by records only the network key can sign; every node and phone checks them itself.
The commands read the passphrase, ask one node for its member list over a request signed with the network key
(`admin.users`), and verify every record on the admin machine: a node can hide accounts or records, it cannot
alter or forge them. Records the admin signs are kept in the admin dir (`revocations/`, `invite-rights/`).

```
otter-admin user list [--via LABEL] [--allow-plain]
    # name#tag, user id, invite rights (and their version), founding, active/revoked; an account without a
    # verifiable invite chain is marked "not admitted". Compare the list from two nodes (--via A, then --via B):
    # a node that hides someone shows a shorter list.
otter-admin user revoke NAME|NAME#TAG|USER_ID [--reason TEXT] [--yes] [--via LABEL]...
    # permanent: the account is closed on every node, its mailbox, prekeys and push tokens are deleted.
    # An ambiguous name is refused (use name#tag or the user id). Asks "[y/N]" unless --yes.
    # Published to every node of the manifest (or --via); OK if one node took it, it replicates from there.
otter-admin user invite-rights NAME|NAME#TAG|USER_ID --off|--on [--via LABEL]...
    # every member may invite by default (D101); --off withdraws the right, --on restores it.
    # The version is one above the highest known (the node's list or the copy in the admin dir).
otter-admin user found USER_ID...
    # accounts created before 0.9.3 have no invite chain: list them as founding members, then
    otter-admin manifest sign && otter-admin manifest publish
```

Upgrading an existing network to 0.9.3: run `user list` (the current accounts show "not admitted"), `user found`
with their user ids, `manifest sign`, `manifest publish`, then `user list` again — all show `founding=true`.
Rights and revocation are judged at the invite's signed `created_ms`; an inviter can backdate an invite by up to
its 30-day lifetime, so an account invited that way after a revocation must be revoked by hand.

## Lost phone: re-key (M9.3, D111)

When a member's phone is lost or stolen (or someone else has their recovery words), the admin moves the account to a
new install in two steps. The person's own history on the lost phone is not recovered; their contacts keep the chats
and see «ключ безопасности изменился».

```
otter-admin user list                          # find the lost account's user id (32 hex digits)
otter-admin user rekey NAME --old CODE [--yes] [--via LABEL]...
    # step 1: revokes the old account (REVOCATION, reason "rekey") and prints a 7-day invite link + QR for the new
    # install. Asks "[y/N]" unless --yes. Recorded in rekeys/NAME.json only after both records reached a node.
    # The person installs Otter fresh with that link and registers with the SAME username (shown as name#tag until
    # step 2).
otter-admin user rekey NAME --new CODE [--via LABEL]...
    # step 2: CODE = «Код аккаунта» from the new phone (Settings → Профиль), read to you by phone or in person —
    # never taken from a message anyone could send. Checks that the account exists under NAME and is not revoked,
    # signs REKEY{old, new}; the new account gets the name, the clash rank and the old account's chats.
    # rekeys/NAME.json becomes rekeys/NAME.done.json.
```

Groups swap the member automatically (one phone per group signs it, D112). If step 2 never happens, groups remove the
member 14 days after step 1 like any revoked member.

## Signature cut-over and the 0.10.0 rollout (M9.3, D109, D110)

0.10.0 nodes and apps accept signature v2 but keep signing v1 until the manifest carries `sig_v1_until_ms`, because
0.9.x apps would drop v2 records. Order:

1. Every node on server 0.10.0 (`deploy/upgrade-all.sh 0.10.0`; mixed 0.9.x/0.10.0 nodes interoperate: all still sign v1).
2. App 0.10.0 (13) released (`deploy/release-apk.sh 0.10.0 APK`, news `dist/news/0.10.0.md`).
3. **Every phone** updated to 0.10.0 — check each one (Settings → О приложении). No admin command sets
   `min_app_version` yet, so this is a manual check. Do not continue before.
4. Cut-over: `otter-admin manifest sign --sig-v1-until <now + 48 h, RFC 3339>`, then `otter-admin manifest publish`.
   The time is stored once in the admin dir (`sig_v1_until_ms`), must be in the future and can never be changed;
   every later `manifest sign` keeps it. From then on the admin, the nodes and the phones sign v2; v1 records created
   after that time are refused. Check on two phones: a message both ways, a photo, a group message; «Журнал
   подключений» shows no signature errors.

**Nodes without backups (D113, D114).** `otter-admin node set-no-backups --label L`, then `manifest sign` and
`manifest publish`, for a node that must never keep backups at rest (the node in Russia). Set it only once every node
and every phone runs 0.10.0: older nodes never confirm a handoff (the flagged node keeps its copies) and older apps
cannot restore through the tunnel. The node's journal shows `backup handed off` once the other nodes hold a backup
uploaded there, and `tunnel …` lines for relayed restores. A foreign node serves the tunnel only when its WSS has its
TLS certificate.

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
  release-signed APK into every node (since 0.8.3 streamed over ssh and imported as `otter`, never as root;
  all nodes must run 0.8.3+, D82) and offers an announcement with an «Обновить» button; phones download it over
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

Three ways to look at the same numbers (M9.4, D119; nodes 0.10.1+). The running node writes
`/var/lib/otter/status.json` (0600) every 15 s and serves Prometheus text on **`127.0.0.1:9477/metrics`** only
(`[metrics] listen`, `"off"` disables; a public address is refused at start, so the port is never in a firewall).

* **`deploy/status.sh`** (admin machine, all nodes, read-only): the node table, the last connectivity log lines, then
  a health block with one line per node and its problems; exit 1 on any problem:

  ```
  health (otter-node status; "!" = needs attention):
    node-a  peers=2/2 lag=0s backlog=0 disk=ok free=31GiB sessions=3 push=12/0 turn=0 rejected=0
    node-c  peers=1/2 lag=14m backlog=37 disk=ok free=8.2GiB sessions=1 push=0/0 turn=0 rejected=4
    node-c  ! peer node-b down for 14m
    node-c  ! peer node-b lag 14m (37 records)
  ```

  `peers` = replication sessions up / other nodes (a session counts whichever side dialed it); `lag` and `backlog` =
  age and count of our records the peers have not confirmed yet (only records a peer would accept, so a `no_backups`
  peer shows no false lag); `push` = sent/failed since the start; `turn` = live TURN allocations; `rejected` = requests
  refused by a limit since the start. Nodes older than 0.10.1 get a note instead of a line.
* **`otter-node status --config /etc/otter/node.toml [--line|--json]`** on a server (root or `otter`; reads only
  `status.json`): exit 0 healthy, 2 problems, 1 no status. Without a flag it prints the version and uptime, one line per
  peer (`up`/`down`, backlog, lag, ping failures), disk, push and TURN.
* **`/metrics`** for a scraper of your own, over SSH:

  ```bash
  ssh root@HOST 'curl -s 127.0.0.1:9477/metrics' | grep '^otter_peer_lag'
  # otter_peer_lag_seconds{peer="node-b"} 0
  ```

  Metrics: `otter_up`, `otter_build_info{version}`, `otter_start_time_seconds`, `otter_client_sessions`, `otter_users`,
  `otter_records`, `otter_oplog_seq`, `otter_blob_bytes`; per peer `otter_peer_connected`, `otter_peer_caught_up`,
  `otter_peer_backlog_records` (-1 = unknown), `otter_peer_lag_seconds`, `otter_peer_ping_failures_total`;
  `otter_disk_free_bytes`, `otter_disk_total_bytes`, `otter_disk_floor_bytes`, `otter_disk_low`;
  `otter_push_sent_total`, `otter_push_failed_total`, `otter_push_unregistered_total`; `otter_turn_enabled`,
  `otter_turn_allocations`, `otter_turn_relayed_bytes_total`; `otter_rejected_total{kind}` with kind `conn_ip`,
  `conn_rate`, `req_rate`, `public_rate`, `user_rate`, `pending`, `disk` (D116–D118).

**Problems** (the `! ` lines, D119): status older than 60 s (node not running); a peer with no session in either
direction for more than 10 minutes (or never, 10 minutes after the start); a peer lag over 10 minutes; disk level not
`ok` (below `[limits] disk_floor`, default 1 GiB); 3 or more push failures and none sent since the start. What each one
means and what to do: [11](11-deployment.md) §7. A hostile peer can lie in its acks; that only changes our numbers.

Other alert ideas for your own scraper: no client sessions for more than an hour during the day; `otter_rejected_total`
growing fast (someone hammering a node, or a phone stuck in a retry loop).
