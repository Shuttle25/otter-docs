# 03 — Mesh Replication

## Requirements

* 1, 2 or 3 identical nodes (design does not hard-limit the count; tested for ≤5).
* Any node may accept any write at any time, including while partitioned.
* Records reach every node eventually, **transitively** (A↔B↔C delivers A→C when A↔C is blocked).
* No node is trusted; replicated records are re-verified on arrival.
* Inter-node traffic is encrypted and mutually authenticated (see [05](05-transport.md)).

## Why no consensus

All replicated data is either **immutable** (envelopes, ACKs, invites, blob metadata) or has a
**deterministic merge rule** (directory entry: highest version; manifest: highest version;
prekeys: per-node ownership; backup meta: highest version). So nodes never need to agree on
an order — they only need to eventually hold the same *set* of records. This is a simple
grow-only set with tombstones (a CRDT), which tolerates arbitrary partitions.

## Oplog

Each node keeps an append-only log:

```
oplog(seq INTEGER PRIMARY KEY AUTOINCREMENT, record_id BLOB UNIQUE, type, received_ms)
```

* Every record a node accepts — from a client **or from a peer** — that it has not seen before
  (by `record_id`) is validated, applied, and appended with a new local `seq`.
* Because peer-received records are re-appended, they propagate transitively.

## Peer sync protocol

Peers use the node's client port and secret path: the peer endpoint is `<path>/peer` (WSS with the
peer's pinned certificate; `WS_PLAIN` only with `[mesh] allow_plain` for development). Every node
dials every other manifest node every 5 s while it has no session with it (per-node backoff 5 s → 5 min,
reset after a session lasted ≥ 1 min). Both directions may connect; **one session per pair is kept: the
one dialed by the lower node_id** (two sessions in the same direction → the newest). This survives
one-way blocking: whichever side can reach the other dials.

**Dial-out-only nodes (M7, D71).** A node marked `dial_out_only` in the manifest (`otter-admin node
set-dial-out-only`, asked by `deploy/add-node.sh`) is never dialed by the others; it dials every peer itself (two
dial-out-only nodes still dial each other). Use it only for a node that cannot accept inbound connections (e.g.
behind NAT); set it only once every node runs 0.7.0 (older nodes ignore the flag). **Not for a node in Russia
(D132):** every link it started to foreign hosting froze, so it keeps the flag off and the foreign nodes dial it.

**Per-endpoint dialing (M7, D73).** A dial tries the peer's usable endpoints one at a time (WSS pinned, REALITY on
:443 when the peer has one, `WS_PLAIN` only with `allow_plain`), each with a 15 s timeout, in ranked order: last
success within 7 days → admin `priority` → manifest order → failed in the last 10 min → demoted (≥ 3
`reset_after_kb` in 24 h, demoted for 24 h; an outbound session dropped within 2 min after receiving ≥ 1 KB counts
as one). The first endpoint that connects is used and goes first next time. The ranking is in memory. Every
attempt, accepted session and failed node handshake is written to the connectivity log `netlog` (D74,
[05](05-transport.md#connectivity-log-m7-d74)).

Handshake (`proto/otter/v1/peer.proto`):

```
acceptor → dialer: PeerHello{node_id, nonce}
dialer → acceptor: PeerAuth{node_id, ts, nonce', sig = Ed25519(node key, "otter-peer-v1" ‖ acceptor_id ‖ nonce ‖ be64(ts))}
acceptor → dialer: PeerAuthOk{ts, sig over "otter-peer-v1" ‖ dialer_id ‖ nonce' ‖ be64(ts)}   (or PeerError + close)
```
Both keys come from the current manifest; a node not listed, a connection to self, or clock skew > 5 min is rejected.

Then the session is symmetric:

```
both: PeerSubscribe{cursor = last seq of the peer's oplog we applied}
each side streams its oplog after that cursor: PeerBatch{records, last_seq} (≤ 512 records / 4 MiB),
  at most 4 unacknowledged; when idle one PeerBatch{caught_up}; then live, woken by every commit
receiver: re-validates and applies each record, persists the cursor, answers PeerBatchAck
```

Record signatures are checked v2-first, v1 only for records created before the current manifest's
`sig_v1_until_ms` (M9.3, D109, [02](02-protocol.md) "Signature format"); replicated records keep whatever version their
author signed, so v1 records stored before the cut-over keep replicating to nodes added later.

The receiver applies batches in a separate loop (a queue of 4 slots, M9.2) so the reading loop keeps answering
pings while a large catch-up batch is being applied (D130's 60 s pong timeout); a peer never has more than 4 batches
unacknowledged, and an apply error still ends the session without advancing the cursor.

* **Idempotent**: applying a record twice is a no-op (dedup by `author ‖ id`).
* **Ordering independence**: an ACK may arrive before its envelope → the ACK is stored as a
  tombstone and the envelope is dropped on arrival.
* **Back-pressure**: batches are acknowledged; at most 4 batches in flight.
* **Retry later**: if a record's author is not known yet (its `DIRECTORY_ENTRY` has not arrived
  from anywhere), a new account's inviter is not known yet (D100), or applying fails transiently, the session ends
  **without advancing the cursor** and is redialed 30 s later, so nothing is skipped. Skipped (logged, cursor
  advances): invalid records (bad signature, malformed, a new account without a valid invite chain), records of an
  author revoked after writing them (D99), records past the 30-day retention guard, and keys in `compacted` (D107).

### Merge rules for replicated records

Records from peers never fail on business conflicts (clients get errors only for their own submissions):

* **Invite reuse** (the same invite redeemed on two sides of a partition, or by a hostile node; M9.2, D102): both
  `INVITE_USED` records are stored; of all accounts that redeemed one `invite_id` the lowest `SHA-256(invite_proof)`
  (then `user_id`) stays, and every other one — with every account invited through it, at any depth — is disabled on
  every node like a revoked account (`users.revoke_reason` `duplicate invite` / `invited by a duplicate`; no
  `REVOCATION` record). The result does not depend on arrival order.
* **Username clash** (M9.2, D103): the account with the lower rank keeps the name; rank = the `INVITE` record's
  `created_ms` (signed by the inviter), for founding members `registered_ms` (the record's `created_ms` when 0),
  fixed when the account is admitted, so a later version never changes it. The other becomes
  `name#<first 4 bytes of user_id, hex>` on every node, independent of arrival order, and the plain name is
  remembered in `username_clashes` (restore then asks for a tag, D103). Before M9.2 the rank was the self-claimed
  `registered_ms` (D40).
* **One-time prekeys**: each key is owned by one node, which alone hands it out; when it does, it
  writes a node-signed `PREKEY_CONSUMED{user, device, key_ids}` record that replicates, so every node
  knows how many keys each owner has left. A user's app refills keys per owner (`prekeys_low{owner_node}`).
  A `PREKEY_CONSUMED` from a node that is not (yet) in the receiver's manifest is **skipped**, not retried: it only
  feeds refill counts, and stalling the peer session until the manifest arrives cost more than the count (M3).
* **Manifest**: highest version wins; peers of nodes removed from the manifest are disconnected.
* **Push token** (M5, D60; M9.2, D107): newest `created_ms` per (user, device) wins, ties by record key. Only the
  newest record per author is kept: an older one arriving later is deleted on arrival and does not change the token.
  A token FCM reports as unregistered is deleted only on the node that saw the error (not replicated); the record
  stays, so an older one still loses.
* **Invites** (M9.2, D107): an author keeps at most 50 unexpired invites, ranked by `(created_ms, record key)`, so
  every node keeps the same 50: a replicated one past the rank is dropped, an unused one pushed past the rank by an
  earlier-ranked arrival is evicted (and compacted). An invite that expired more than a day ago is dropped on arrival.
* **One-time prekeys budget** (M9.2, D107): at most 200 unconsumed keys per (user, device, owner node); a record
  with more keeps the newest ids and marks the older ones consumed. Ids below the owner's `prekey_floor` are never
  inserted again.
* **Revocation / invite rights** (M9.2, D99): applied in the transaction that stores them, on every node; the
  earliest revocation of a user is kept and is permanent; `INVITE_RIGHTS` highest version wins, ties → "no".

### Membership checks on replication (M9.2, D99–D102)

Membership is decided by signed records that every node checks itself (threat model: any one node may be hostile),
the same way for a registration and for a replicated record:

* A `DIRECTORY_ENTRY` of a user this node does not know yet must carry a valid invite chain (`invite_record`,
  `invite_proof`, [02](02-protocol.md) "Invite chain"): the `INVITE` signed by the network key or a known member, the
  proof valid, the invite living ≤ 30 days, `created_ms ≤ registered_ms ≤ expires_ms`, and the inviter neither revoked
  nor without invite rights **as of the invite's `created_ms`**. Or the user is in the manifest's `founding_members`.
  Broken chain → skipped (`INVALID`); inviter not known here yet → `RETRY_LATER` (it comes in a later batch or from
  another peer). Unlike a registration, a replicated entry does not need the invite to be unexpired *now*.
* An entry of a known user is a new version: the admission (rank, inviter, redemption) is never recomputed.
* A redemption that loses the single-use rank (above) disables the loser and everyone it invited; such an account
  never admits anyone.
* `REVOCATION` / `INVITE_RIGHTS` must be signed by the network key; a `REVOCATION` closes the account's sessions and
  deletes its mailbox, prekeys and push tokens on every node. Records of a revoked author that arrive later are
  skipped (no stall).
* TURN refuses a revoked account's credentials as soon as the node holds the revocation (D108).
* `REKEY` (M9.3, D111) must be signed by the network key. Every REKEY revokes its `old` account like a `REVOCATION`
  (reason `rekey`); per `old` the later `created_ms` wins (ties → lower record key), in any arrival order (table
  `rekeys`, migration 0015). The winner's `new` account is admitted without an invite chain (normally it also has
  one: the 7-day network invite of `user rekey --old`), is never
  disabled as a duplicate redemption, takes `min(own, old's)` clash rank and takes over `old`'s username once both
  entries are present.

## Blob replication

Blob bytes are large, so they replicate separately from `BLOB_META` (D45), over the same peer session:

* Peer frames `PeerBlobGet{req, blob_key, index}` → `PeerBlobChunk{req, data | missing}`; a node serves up to 4 at a
  time per session from its chunk files (busy → "missing"). A peer of an older build ignores them; the asker times out
  after 10 s and tries the next peer.
* A background **puller** walks every blob with missing chunks (oldest first) and fetches them from any live peer
  (the one that answered last for that blob first), bandwidth-limited by `[replication] blob_bandwidth`
  (default 2 MB/s, `0` = unlimited). A blob no peer has yet (the upload is still running) is retried after 1 s,
  doubling to 30 s. Every chunk is checked against the SHA-256 in the signed `BLOB_META` before it is stored.
* If a reader asks for a chunk the node doesn't have yet, the node fetches it from a peer at once (proxy) and keeps it.
* Deletion: `BLOB_FETCHED` from every reader, or expiry, deletes the blob rows, the meta record and (soon after) the
  files on every node, and leaves a tombstone until expiry + 1 day. A `BLOB_META` re-sent by a lagging peer is dropped
  against the tombstone; a node that only ever sees the `BLOB_FETCHED` rows keeps them, so a meta arriving later is
  deleted on arrival.
* Backups (M6, D50): a backup is a persistent blob (no readers, no expiry) and replicates like any blob, so every node
  ends up with every member's latest backup. `BACKUP_META` records never age out of the oplog (a node added later still
  gets them). The latest `BACKUP_META` version wins (tie: later `created_ms`, then record key); the superseded meta and
  its blob are deleted on every node, with a 30-day tombstone. A persistent blob no meta references is deleted 7 days
  after creation.
* Install rule on `PREKEYS` (D52): per (user, device) a newer `installed_ms` replaces all prekeys of the device, an
  older one is ignored (record kept), an equal one merges as before.

### Backup handoff from `no_backups` nodes (M9.3, D113)

A node marked `no_backups` in the manifest never keeps backups at rest:

* Senders skip `BACKUP_META` and persistent `BLOB_META` oplog entries to it (the cursor moves past them); if an older
  peer still sends one, it drops it; a peer answers its `PeerBlobGet` for a backup blob with "missing".
* What phones upload to it is handed off: every minute `RunBackupHandoff` lists its local backup items (a backup blob
  once a `BACKUP_META` references it or it is 1 h old; a `BACKUP_META` once its blob is gone here) and asks the peers
  without `no_backups` over the existing sessions, whichever side dialed:
  ```
  PeerHoldsQuery{req, record_key}  →  PeerHolds{req, held}
  ```
  `held` = the record is stored and, for a `BLOB_META`, every chunk is present; a backup record the peer received and
  deleted as superseded also counts (the asking node must not keep a stale copy). A peer serves 4 queries at a time
  (busy → "not held"); a `no_backups` peer always answers "not held"; a 0.9.x peer never answers (the query times
  out). Once **`min(2, nodes without no_backups)`** distinct peers said "held", the copy is deleted (a blob is
  tombstoned like a superseded backup; log line `backup handed off`). With no such node in the manifest nothing is
  deleted.

### Restore tunnel (M9.3, D114)

A `no_backups` node relays a phone's restore to a node that keeps backups ([02](02-protocol.md) "Nodes without
backups and the restore tunnel"). The stream rides the **existing peer session** with the target, whichever side
dialed it; the relay never dials for a tunnel (D132: links started from Russia to foreign hosting freeze).

```
relay → target: PeerTunnelOpen{stream}
both:           PeerTunnelData{stream, data (1–32768 bytes)}   at most 32 unacknowledged per stream and direction
both:           PeerTunnelAck{stream, chunks}                    returns window slots (never above 32)
either:         PeerTunnelClose{stream, reason}
```

* The target accepts a stream only from a peer marked `no_backups`, only if it is not `no_backups` itself and serves
  the tunnel listener (its WSS has TLS); otherwise it closes the stream with a reason. The stream ends in an
  in-process TLS server with the node's WSS certificate and the normal client handler; the remote address is
  `tunnel:<relay node id>`, which the restore limits use as the source (D105).
* Limits: ≤ 16 streams per peer session, ≤ 4 per phone source and ≤ 32 per relay node, 2 min idle, 30 min life, 5 s
  for the target's TLS server to accept a new stream. An empty or oversize data frame, or one past the window, ends the
  stream; acks never raise the window above 32.
* The relay sees only TLS records (sizes and timing), never the salt, the password check or the backup.

### Map pieces (M11, D141; server 0.13.0)

A node without `[tiles] upstream` (the node in Russia) gets the map pieces its phones ask for (`tiles.get`,
[02](02-protocol.md)) from its peers over the **existing peer sessions**, whichever side dialed:

```
asker → peer: PeerTileGet{req, z, x, y}       peer frame 16
peer → asker: PeerTile{req, data | missing}   peer frame 17
```

* The asker tries its live sessions one by one, the peer that answered a piece last first, 10 s each (a peer before
  0.13.0 ignores the frame and the asker times out). The first piece that passes the checks (≤ 1 MiB; a gzip piece
  decompresses completely to ≤ 8 MiB) is cached and returned; a bad piece is logged with the peer id and its size only
  and the next peer is asked. No peer has it → `NOT_FOUND` to the phone.
* The peer answers from its own cache or its own upstream (`Tiles.Local`, 12 s), **never by asking further peers**, so
  a request cannot loop through the mesh. It serves 4 requests at a time per session (busy → `missing` at once),
  answers `missing` for invalid coordinates or a node without tiles, and recovers from a panic without logging its
  value. Frames outside an authenticated peer session are refused like every peer frame.
* Coordinates are never logged on either side (a z14 piece pins a member's area).

## Deletion & garbage collection

| What | When removed |
|------|--------------|
| Envelope | ACK for it received (any node) **or** expiry (30 d) |
| Blob | every reader's `BLOB_FETCHED`, or expiry; tombstone until expiry + 1 d |
| `BLOB_FETCHED` records | 30 d after they were received |
| ACK tombstone | 30 d after creation (longer than any envelope can live) |
| Old directory/backup/manifest versions | immediately superseded (a superseded backup's blob too; tombstone 30 d) |
| Persistent blob without a `BACKUP_META` | 7 d after creation |
| `auth_failures` rows (restore limit; `username`, `source`, `at_ms`, M9.2 D105) | 24 h. An attempt is written before the secret is compared; a correct secret or a node error removes its row at once |
| `ACK`, `PREKEY_CONSUMED` records | 30 d after they were received |
| Superseded `PUSH_TOKEN` records (M9.2, D107) | on arrival of a newer one (an older one arriving later is deleted at once); only the newest record per author stays |
| `PREKEYS` records (M9.2, D107) | janitor, ≥ 1 h after creation: a record of a replaced install, or one whose one-time keys are all consumed and that is not the newest record with the current install's signed prekeys; its key goes to `compacted` |
| Consumed one-time prekey rows (M9.2, D107) | janitor: below the per-(user, device, owner node) `prekey_floor` (= highest consumed id + 1); the floor itself is kept (dropped with the device's prekeys on a newer install) so those ids are never inserted again |
| Unconsumed one-time prekeys over budget | on arrival: more than 200 per (user, device, owner node) → the oldest ids are marked consumed |
| `INVITE` records (M9.2, D107) | 1 d after `expires_ms` (key to `compacted`); an unused one evicted past the 50-invite rank at once; records from before 0.9.3 (no `invites.record_key`) once `created_ms` is older than 31 d. An `INVITE` arriving > 1 d after its expiry is dropped |
| `invites` rows | unused: with their record, 1 d after expiry; **used rows stay** (single-use check, D102) |
| `compacted` keys (M9.2, D107) | 30 d after the record was compacted (matches the retention guard below) |
| Revoked account's mailbox, prekeys, push tokens (D99) | when the `REVOCATION` is applied (or the account is disabled as a duplicate, D102) |
| Oplog rows | removed together with their record (janitor every 10 min) |

## Compaction & new / long-offline nodes

**No snapshot protocol** (simplified in M2). `Since(cursor)` joins the oplog with the stored records, so a
deleted record is simply not sent, and the janitor drops oplog rows without a record. A record is deleted only
when (a) it expired (envelopes, ACKs, `PREKEY_CONSUMED`, `BLOB_FETCHED`: all after the same 30 days; expired
invites) or (b) its effect is fully carried by records that stay (superseded directory/backup/manifest versions,
older `PUSH_TOKEN`s, `PREKEYS` whose keys are all consumed or belong to a replaced install, evicted invites).
So `Since(cursor)` always yields exactly the live set, whatever the cursor: a brand-new node (cursor 0) or one
that was offline for months simply subscribes and converges to the same derived state as the others (proven in
`meshsim`: a node away while the others compact catches up to the same prekeys, push tokens and invites).

**M9.2 compaction (D107)** keeps this property: the newest `PUSH_TOKEN` and the base `PREKEYS` record of the
current install (with the signed prekeys) are never compacted; a `PREKEYS` record is compacted only after 1 h (its
keys may still be replicating) and only when none of its one-time keys is still live; the used `invites` rows stay.
A node that has never seen a compacted record does not need it.

**Retention guard and `compacted`:** a lagging or hostile peer may still re-send a record this node already
deleted. Envelopes/ACKs/`PREKEY_CONSUMED` are ignored if their `created_ms` is older than the 30-day retention
(clients set `created_ms` from their clock, which logins keep within ±5 min). Compacted records are ignored by key
for 30 days (`compacted`); after that they still change nothing: an older `PUSH_TOKEN` loses to the newest one (and
is deleted again), an old `PREKEYS` record of a replaced install is ignored by the install rule, consumed one-time
ids are below `prekey_floor`, and an invite more than a day past expiry is dropped on arrival.

## Partition behaviour (examples)

| Situation | Behaviour |
|-----------|-----------|
| Node B down for 2 days | A and C keep serving. B returns, pulls since its cursor, deletes envelopes ACKed meanwhile |
| A↔C blocked, both reach B | Records flow A→B→C. Latency +1 hop |
| Total split {A} / {B,C} | Users on each side talk normally within their side; cross-side messages queue and flow when any link heals |
| Client sent to A, A died before replicating | Client got ✓ only after A stored it; if A never comes back the message is lost → client re-sends unacknowledged-by-recipient messages after 24 h via another node (dedup by id makes this safe) |
| Same envelope delivered by A and C | Client dedups by envelope id |

## Clock skew

Nodes do not trust clocks for correctness: expiry uses the node's own clock relative to
`received_ms`; `created_ms` is used only for tie-breaks (username clash rank, invite and push-token ranks), the
retention guard above, the invite-chain checks (judged at the inviter-signed `INVITE.created_ms`, so every node
gets the same answer; an inviter can backdate by up to the 30-day invite lifetime, D100) and display. Clients cannot
submit records dated more than 5 min ahead (M9.2), which would otherwise outrank every later record.

## Security of replication

* Peers authenticate each other with node keys from the current manifest; a node removed
  from the manifest is disconnected and its new records are rejected.
* Every record is re-validated (signature — v2 bound to this network after the cut-over, D109 —, author not revoked,
  invite chain of a new account, budgets) before being applied — a compromised peer cannot inject forgeries or
  members (M9.2: membership checks above), nor replay a member's record from another network that knows the same key
  once the cut-over manifest is out (only v1 records created before it remain replayable).
* A hostile peer can answer `PeerHolds{held: true}` falsely; a `no_backups` node then deletes its copy too early. With
  two confirmations needed (when two nodes without the flag exist) one lying peer is not enough (D113).
* Budgets hold on the replicated path too (D107): a hostile peer relaying a member's flood or replaying old
  records cannot grow prekeys, push-token records or invites beyond them. Submit rates (`PREKEYS` 20/h,
  `PUSH_TOKEN` 30/h per author) and the 5-minute future limit apply to local submits only; a hostile node can
  skip them for records it receives, but the member must still sign each record and the budgets still cap them.
* A compromised peer *can* withhold records; clients mitigate by using several nodes over time
  and by re-sending unacknowledged messages.
