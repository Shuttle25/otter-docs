# 06 — Node (Server) Architecture

## Overview

`otter-node`: a single statically linked Go binary (`CGO_ENABLED=0`), Linux amd64/arm64,
no external services required (no Postgres, Redis, etc.). Optional Caddy in front for the
WSS/website endpoint.

* Go ≥ 1.23
* SQLite via `modernc.org/sqlite` (pure Go, WAL mode)
* Xray-core embedded (`github.com/xtls/xray-core`, MPL-2.0)
* TURN relay embedded: Pion `github.com/pion/turn/v5` v5.1.3 (MIT; M8, D77)
* WebSocket: `github.com/coder/websocket`
* Protobuf: `google.golang.org/protobuf`
* FCM: HTTP v1 API via `golang.org/x/oauth2/google` (no Firebase Admin SDK needed)
* Config: TOML (`github.com/BurntSushi/toml`)
* Logging: `log/slog`; metrics: Prometheus text endpoint on localhost

## Repository layout

```
server/
  cmd/
    otter-node/        main: load config, wire components, run
    otter-admin/       network/admin CLI
  internal/
    config/            TOML config + validation
    keys/              node key, network key loading, signing helpers
    proto/             generated protobuf code (from /proto)
    records/           Record validation: signature, author binding, per-type rules, quotas
    store/             SQLite schema, migrations, typed queries (only package touching SQL)
    mailbox/           per-recipient queues, fan-out of group envelopes, ACK handling
    directory/         users, usernames, revocations, invites
    prekeys/           per-node prekey ownership, hand-out, low-water events
    blobs/             chunked blob files on disk, quotas, peer pull, proxying
    backup/            backup meta, auth checks, rate limiting   (as built: service/backup.go, store/backups.go)
    replication/       peer sessions, cursors, batches, snapshots
    gateway/           client WebSocket sessions, auth, method router, events
    transport/
      wss/             HTTP server + secret-path WebSocket + decoy site
      reality/         embedded Xray REALITY inbound → internal handler; outbound dialer for peers
    push/              FCM sender, coalescing
    turnsrv/           embedded TURN relay for calls (M8): credentials, quotas, rate cap, peer filter, stats
    janitor/           expiry, GC, oplog compaction
    ratelimit/         token buckets per user / IP
    manifest/          current manifest, verification, distribution
  test/
    meshsim/           in-process multi-node tests with simulated partitions
```

Rule: packages talk through small interfaces; only `store` knows SQL; only `transport/*`
knows network details; `records` is pure (no I/O) and fully unit-tested.

## Request path

```
transport (WSS | REALITY) → net.Conn / WebSocket
  → gateway.Session (auth state, rate limit)
    → router(method) → service (mailbox / directory / prekeys / blobs / backup)
      → records.Validate(record) → store.Apply(record) [tx: apply + oplog append]
        → replication.Notify(seq)   (live push to peers)
        → gateway.Notify(recipient) (live event to connected clients)
        → service.maybePush         (FCM wake-up if urgent, fresh, recipient offline here, this node responsible: D58)
```

`store.Apply` is the single write path for both client-originated and peer-originated records,
which guarantees identical behaviour.

## SQLite schema (initial)

```sql
CREATE TABLE oplog(seq INTEGER PRIMARY KEY AUTOINCREMENT, record_id BLOB UNIQUE NOT NULL,
                   type INTEGER NOT NULL, received_ms INTEGER NOT NULL);
CREATE TABLE records(record_id BLOB PRIMARY KEY, type INTEGER, author BLOB,
                     created_ms INTEGER, expires_ms INTEGER, raw BLOB NOT NULL);
CREATE TABLE mailbox(user_id BLOB, device_id INTEGER, record_id BLOB, origin_node BLOB,
                     received_ms INTEGER, PRIMARY KEY(user_id, device_id, record_id));
CREATE TABLE tombstones(record_id BLOB PRIMARY KEY, until_ms INTEGER);
CREATE TABLE users(user_id BLOB PRIMARY KEY, username TEXT UNIQUE, entry_record BLOB,
                   version INTEGER, revoked INTEGER DEFAULT 0, created_ms INTEGER);
CREATE TABLE invites(invite_id BLOB PRIMARY KEY, inviter BLOB, expires_ms INTEGER,
                     used_by BLOB);
CREATE TABLE prekeys(user_id BLOB, device_id INTEGER, key_id INTEGER, kind INTEGER,
                     owner_node BLOB, public BLOB, consumed INTEGER DEFAULT 0,
                     PRIMARY KEY(user_id, device_id, kind, key_id));
-- M4 (migration 0004, D44/D45): blob_key = record key of the BLOB_META
CREATE TABLE blobs(blob_key BLOB PRIMARY KEY, owner BLOB, size INTEGER, chunks INTEGER, expires_ms INTEGER, created_ms INTEGER);
CREATE TABLE blob_chunks(blob_key BLOB, idx INTEGER, PRIMARY KEY(blob_key, idx));      -- chunks present on this node
CREATE TABLE blob_readers(blob_key BLOB, user_id BLOB, PRIMARY KEY(blob_key, user_id));
CREATE TABLE blob_fetched(blob_key BLOB, user_id BLOB, at_ms INTEGER, PRIMARY KEY(blob_key, user_id));
CREATE TABLE blob_tombstones(blob_key BLOB PRIMARY KEY, until_ms INTEGER);
-- M6 (migration 0005, D50-D52): blobs.persistent=1 marks backup blobs; devices.installed_ms; index on auth_failures
CREATE TABLE backups(user_id BLOB PRIMARY KEY, record_key BLOB, version INTEGER, created_ms INTEGER, blob_key BLOB);  -- winning BACKUP_META
CREATE TABLE auth_failures(username TEXT, at_ms INTEGER);
CREATE TABLE push_tokens(user_id BLOB, device_id INTEGER, kind INTEGER, token TEXT,
                         PRIMARY KEY(user_id, device_id));
-- M5 (migration 0006, D60): push_tokens.created_ms, record_key — the newest PUSH_TOKEN per (user, device) wins
CREATE TABLE peers(node_id BLOB PRIMARY KEY, cursor INTEGER DEFAULT 0, last_seen_ms INTEGER);
CREATE TABLE manifest(version INTEGER PRIMARY KEY, raw BLOB);
```

Blob chunks are files: `<data_dir>/blobs/<hex(blob_key)[0:2]>/<hex(blob_key)>/<chunk_idx>` (written atomically: temp file,
fsync, rename). A sweeper removes directories of deleted blobs after every applied `BLOB_FETCHED` and on every janitor
tick. `blob.get` runs off the session's read loop (4 at a time), so a proxied chunk doesn't stall other requests.

### SQLite capacity & tuning

* Settings: `journal_mode=WAL`, `synchronous=NORMAL`, `busy_timeout=5000`, `foreign_keys=ON`.
* **Single writer goroutine with group commit**: all `store.Apply` calls go through one
  channel; the writer batches up to 256 records or 10 ms into one transaction. Readers use a
  separate connection pool (WAL allows concurrent reads).
* **Media and backups are files on disk, not in SQLite**, so the DB only holds small records.
* Expected load (100 users × ~200 msgs/day, each message ⇒ envelope + delivered + read
  receipts + ACKs ≈ 6 records): ~120k records/day, peak ≈ 5–20 records/s.
* Capacity on a 1-vCPU VPS with SSD: ≥ 1 000 records/s with group commit (≈ 60 000/min),
  i.e. 50–100× headroom over peak.
* Size: delivered envelopes are deleted; what remains is 30 days of ACKs/tombstones/oplog
  (~200–400 bytes per message) + prekeys (Kyber prekeys ≈ 1.6 KB each, ~150 per user ⇒
  ~25 MB for 100 users) + directory. Steady state **≈ 100–500 MB**. SQLite's hard limit
  (~281 TB) is irrelevant.
* If ever outgrown (~thousands of users), only `internal/store` touches SQL, so it can be
  swapped for Postgres without changing other packages.

## Push (FCM) — M5, D58–D60

* A node pushes only with a Firebase service-account key at `[push] fcm_credentials` (`/etc/otter/fcm.json`,
  installed by `deploy/push-key.sh`; a missing file = push off, logged as `push off` at start). All nodes use keys of
  the same Firebase project. `push_capable` in the manifest (`otter-admin node set-push`) tells the other nodes which
  ones push; a node flagged but without a key logs a warning and does not push.
* Tokens: phones send a signed `PUSH_TOKEN` (`push.register`); it replicates like every record and the newest
  `created_ms` per (user, device) wins (ties: record key).
* **Who pushes** (D58), decided in `afterApply` for every newly applied `ENVELOPE`:
  * accepted **locally** (client `msg.send`, local import): this node, if it is push-capable (flag **and** key);
  * **replicated from peer P**: this node only if it has a key, P is not flagged `push_capable`, **and** this node
    is the first node in manifest order flagged `push_capable`. P approximates the origin; in a full mesh it is the
    origin. A flagged node without a key therefore silences the nodes after it: keep flag and key in step.
* Only for `urgent=true` envelopes (not receipts), created ≤ 10 min ago (a late replication never pushes), and only
  for recipients with no logged-in, non-replaced session on this node (`Gateway.Online`).
* Coalesced: at most one push per (user, device) per 10 s per node. Sends run in the background (20 s timeout).
* Message (D59): FCM HTTP v1 `messages:send`, OAuth2 from the key (`golang.org/x/oauth2/google`), body
  `{"token", "android": {"priority": "HIGH", "collapse_key": "otter", "ttl": "600s"}, "data": {"w": "1"}}` — constant,
  no ids, no content. HTTP 404 or `UNREGISTERED` → the token row is deleted on this node only (if still current);
  other errors are logged (`push failed`).

## TURN relay for calls (M8, D77)

`internal/turnsrv` wraps Pion `turn/v5` inside `otter-node` (no extra service):
* `creds.go` — TURN-REST credentials (`"<expiry>:<hex(sha256(user_id))[:16]>"`, HMAC-SHA1, 12 h) and the `Issuer`
  behind `turn.credentials`; our own expiry check (injectable clock) wraps pion's auth handler on **every**
  authenticated request, because pion fires `OnAuth` only on an HMAC mismatch. pion's auth logger is silenced.
* `server.go` — listeners (UDP/TCP 3478, TLS 5349 with the WSS certificate), quota handler with **reservations**
  (a slot is reserved on Allocate and confirmed in `OnAllocationCreated`, stale after 5 s): per user (4) and per node
  (41 = relay port range); over the limit → 486.
* `relay.go` — relay address generator: UDP only, IPv4 `relay_ip`, ports 49160–49200 (RESERVATION-TOKEN ports outside
  the range and RFC 6062 TCP relays refused); a token-bucket **rate cap per allocation**, each direction
  (`relay_kbps`, default 200); writes to any address of the node (relay IP, interface addresses) are dropped unless
  the port is one of its relay ports (two phones on one node).
* `peers.go` — permission handler: no loopback, private, link-local, multicast, unspecified, CGNAT, `0/8`,
  `192.0.0.0/24`, `198.18/15`, `240/4`, NAT64, 6to4, Teredo, `100::/64` peers (`allow_private_peers` for tests and
  dev networks only).
* `stats.go` — allocations, relayed and dropped bytes; written every 10 s to `<data_dir>/turn.stats.json`;
  `otter-node stats` appends ` turn_allocs=N turn_relayed_bytes=M` when the snapshot is < 60 s old.
* `keygen.go` — `otter-node turn keygen --config FILE [--force]`: 32 random bytes to `secret_file` (refuses to
  overwrite without `--force`, never prints the secret; does not open the DB).
* netlog (D74) classes `auth` (bad HMAC, expired/malformed username), `quota`, `listen` (start failure); merged, and
  rate limited (burst 20, then 1/s).

`otter-node run` starts the relay **before** serving WSS (sessions read `svc.Turn`) and closes it on stop; the log
says `"turn on"` with the ports; nothing is started without `[turn]`. A start failure (port taken, unreadable
secret) is logged as `"turn off: could not start"` and netlogged (class `listen`), and the node keeps serving;
`turn.credentials` then answers UNAVAILABLE. `otter-node check`
validates `[turn]` and the secret (`ok turn secret … (32 bytes), relay IP:49160-49200`). New RPCs in
`service/calls.go`: `turn.credentials`, `push.status` (has a PUSH_TOKEN for device 1).

Call signaling envelopes carry a 2-minute record expiry (D78): `Store.Mailbox` skips envelopes past their
`expires_ms`, and the janitor purges them (other envelopes still go by the 30-day receive age).

## Quotas & limits (defaults, configurable)

| Limit | Default |
|-------|---------|
| Max envelope size | 256 KiB |
| Max blob (`[limits] max_blob`) | 100 MiB (protocol maximum) |
| Per-author live blobs (`[limits] user_quota`) | 2 GiB (persistent backup blobs count; at most 3 live per user, D50) |
| Backup guesses (`backup.fetch`) | 5 failures per username per hour, 20 per day per node (D51) |
| Blob chunk pull between nodes (`[replication] blob_bandwidth`) | 2 MB/s (`0` = unlimited) |
| Mailbox max undelivered | 10 000 envelopes |
| Requests | 50/s burst, 10/s sustained per session |
| Registration attempts | 10/hour per IP |
| TURN allocations (`[turn]`) | 4 per user, 41 per node (= relay port range) |
| TURN relayed rate (`[turn] relay_kbps`) | 200 kbit/s per allocation, each direction |

## Configuration (`/etc/otter/node.toml`)

```toml
data_dir      = "/var/lib/otter"
node_key      = "/etc/otter/node.key"
manifest_file = "/etc/otter/manifest.bin"   # initial; newer versions come via mesh

[wss]
listen      = "127.0.0.1:8080"   # behind Caddy, or ":443" with own certs
secret_path = "/k3J9...random"
site_dir    = "/var/lib/otter/site"   # decoy website

[reality]
listen       = ":443"
private_key  = "/etc/otter/reality.key"
server_names = ["www.example-big-site.com"]
dest         = "www.example-big-site.com:443"
short_ids    = ["a1b2c3d4"]

[push]
fcm_credentials = "/etc/otter/fcm.json"   # always in the template; push is off while the file is missing

[replication]
blob_bandwidth = "2MB/s"   # sizes: B, KB/MB/GB, KiB/MiB/GiB; rates with /s; "0" = unlimited

[limits]
user_quota = "2GiB"
max_blob   = "100MiB"

[turn]                       # M8, optional; written by make-bundle.sh / deploy/turn-setup.sh (0.8.0+ only)
enabled  = true
relay_ip = "203.0.113.10"    # the node's public IPv4
# defaults: udp_listen = tcp_listen = ":3478", tls_listen = ":5349" (only with [wss] TLS),
# relay_port_min/max = 49160/49200, secret_file = "/etc/otter/turn.secret", realm = "otter",
# max_allocations_per_user = 12, max_allocations = port range, relay_kbps = 200, allow_private_peers = false
```

## Observability

* `slog` JSON logs (no message content exists to log; user ids hashed in logs by default).
* `/metrics` on `127.0.0.1:9100`: sessions, mailbox depth, replication lag per peer, blob
  bytes, push sent/failed, auth failures.
* `otter-node status`: prints peers, lag, manifest version, storage usage.

## Testing

* `records`: table-driven tests for every record type (valid, bad signature, revoked author,
  over-quota, wrong binding).
* `store`: migrations + apply idempotency.
* `meshsim`: 3 nodes in-process connected through a fake transport that can drop, delay,
  partition, and cut connections after N bytes; property tests that after healing all nodes
  converge to the same live record set and every non-ACKed envelope is delivered exactly-once
  per client after dedup.
* Integration test with a Go test client (Ed25519 + dummy ciphertext; no libsignal needed on server side).
