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

* **Idempotent**: applying a record twice is a no-op (dedup by `author ‖ id`).
* **Ordering independence**: an ACK may arrive before its envelope → the ACK is stored as a
  tombstone and the envelope is dropped on arrival.
* **Back-pressure**: batches are acknowledged; at most 4 batches in flight.
* **Retry later**: if a record's author is not known yet (its `DIRECTORY_ENTRY` has not arrived
  from anywhere) or applying fails transiently, the session ends **without advancing the cursor**
  and is redialed 30 s later, so nothing is skipped. Only invalid records (bad signature, malformed)
  are logged and skipped.

### Merge rules for replicated records

Records from peers never fail on business conflicts (clients get errors only for their own submissions):

* **Invite reuse** (the same invite used on two sides of a partition): both `INVITE_USED` records are
  stored; the first `used_by` stays. Both accounts exist.
* **Username clash**: the user whose directory entry has the lower `(registered_ms, user_id)` keeps the
  name (`registered_ms` = first registration, copied into every later version; the record's `created_ms`
  when 0 for M1–M3 entries, D40), so a profile update never changes the outcome; the other becomes `name#<first 4 bytes of user_id, hex>` on every node, independent of arrival
  order. (A rename screen comes in M8.)
* **One-time prekeys**: each key is owned by one node, which alone hands it out; when it does, it
  writes a node-signed `PREKEY_CONSUMED{user, device, key_ids}` record that replicates, so every node
  knows how many keys each owner has left. A user's app refills keys per owner (`prekeys_low{owner_node}`).
  A `PREKEY_CONSUMED` from a node that is not (yet) in the receiver's manifest is **skipped**, not retried: it only
  feeds refill counts, and stalling the peer session until the manifest arrives cost more than the count (M3).
* **Manifest**: highest version wins; peers of nodes removed from the manifest are disconnected.
* **Push token** (M5, D60): newest `created_ms` per (user, device) wins, ties by record key; an older token arriving
  later is stored as a record but does not change the token. A token FCM reports as unregistered is deleted only on
  the node that saw the error (not replicated).

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

## Deletion & garbage collection

| What | When removed |
|------|--------------|
| Envelope | ACK for it received (any node) **or** expiry (30 d) |
| Blob | every reader's `BLOB_FETCHED`, or expiry; tombstone until expiry + 1 d |
| `BLOB_FETCHED` records | 30 d after they were received |
| ACK tombstone | 30 d after creation (longer than any envelope can live) |
| Old directory/backup/manifest versions | immediately superseded (a superseded backup's blob too; tombstone 30 d) |
| Persistent blob without a `BACKUP_META` | 7 d after creation |
| `auth_failures` rows (backup rate limit) | 24 h |
| `ACK`, `PREKEY_CONSUMED` records | 30 d after they were received |
| Oplog rows | removed together with their record (janitor every 10 min) |

## Compaction & new / long-offline nodes

**No snapshot protocol** (simplified in M2). The oplog only loses rows of records that were deleted,
and every deleted kind (envelopes, ACKs, `PREKEY_CONSUMED`) expires after the same 30 days. So
`Since(cursor)` always yields exactly the live set, whatever the cursor: a brand-new node (cursor 0)
or one that was offline for months simply subscribes and converges.

**Retention guard:** a peer may still re-send an envelope/ACK/`PREKEY_CONSUMED` that this node already
expired and forgot. Such records are ignored if their `created_ms` is older than the 30-day retention
(clients set `created_ms` from their clock, which logins keep within ±5 min).

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
`received_ms`; `created_ms` is used only for tie-breaks (username clash), the retention guard above,
and display.

## Security of replication

* Peers authenticate each other with node keys from the current manifest; a node removed
  from the manifest is disconnected and its new records are rejected.
* Every record is re-validated (signature, author not revoked, quotas) before being applied —
  a compromised peer cannot inject forgeries.
* A compromised peer *can* withhold records; clients mitigate by using several nodes over time
  and by re-sending unacknowledged messages.
