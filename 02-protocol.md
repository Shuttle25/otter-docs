# 02 — Protocol

All wire structures are **Protocol Buffers** (shared `.proto` files in `proto/`, generated
for Go and Kotlin/Java-lite). All signatures are **Ed25519** over the canonical serialized
`body` bytes of a record (signature is *outside* the signed bytes).

## 1. Identities

### User
Generated on the phone at registration from a 256-bit **seed** (shown as 24 BIP-39 words):

| Key | Derivation | Purpose |
|-----|------------|---------|
| Account key (Ed25519) | `HKDF(seed, "otter/account/v1")` | Signs all records; verified by nodes and clients |
| Identity key (Curve25519, libsignal) | `HKDF(seed, "otter/identity/v1")` | Signal protocol identity; safety numbers |
| Backup key, auth secret | from **password**, see [04](04-security.md) | Encrypts/authorizes history backup |

* `user_id = SHA-256(account_pub)[0:16]` — displayed as base32 (26 chars).
* The directory entry binds both keys: signed by the account key **and** contains an
  XEdDSA signature by the identity key over the account public key. Clients verify both;
  nodes verify the Ed25519 one.
* `device_id = 1` in V1. Every address is `(user_id, device_id)` from day one so
  multi-device can be added later without protocol changes.

### Node
Each node has an Ed25519 **node key** (`node_id = SHA-256(node_pub)[0:16]`), listed in the
manifest. Used for node↔node authentication and to sign node-originated records
(e.g. "delivered to mailbox" receipts used only for diagnostics).

### Network
One Ed25519 **network admin key**, held offline by `otter-admin`. Signs the manifest and
user revocations. Its public key is the network's root of trust and is embedded in every invite.

## 2. Records

Everything nodes store and replicate is a `Record`:

```proto
message Record {
  bytes  body      = 1;  // serialized RecordBody
  bytes  signature = 2;  // Ed25519 by body.author key
}

message RecordBody {
  bytes   id         = 1; // 16 random bytes chosen by author (dedup key)
  uint32  type       = 2; // see table
  bytes   author     = 3; // user_id, node_id or "network"
  int64   created_ms = 4; // author's clock (informational, used for tie-breaks)
  int64   expires_ms = 5; // 0 = no expiry
  bytes   payload    = 6; // type-specific message
}
```

| Type | Author | Payload | Notes |
|------|--------|---------|-------|
| `DIRECTORY_ENTRY` | user | user_id, username, display_name, account_pub, identity_pub, identity_sig, version, can_invite, registered_ms | Latest `version` wins; `registered_ms` = first registration, copied into later versions (D40) |
| `PREKEYS` | user | signed prekey, Kyber last-resort prekey, list of one-time EC + Kyber prekeys **each tagged with an owning node_id**, `installed_ms` (M6, D52; 0 before) | See §5 |
| `INVITE` | user | invite_id = SHA-256(secret), expires | |
| `INVITE_USED` | user (new) | invite_id, new user_id | |
| `ENVELOPE` | user | see §3 | Encrypted message |
| `ACK` | user (recipient) | list of envelope ids | Deletes envelopes everywhere |
| `PREKEY_CONSUMED` | node | user_id, key ids | Bookkeeping |
| `PUSH_TOKEN` (type 8) | user | `PushToken{device_id (= 1), kind (FCM = 1), token (1–4096 bytes UTF-8)}` | Newest `created_ms` per (user, device) wins, ties by record key; never expires (M5, D60) |
| `BLOB_META` | user | size, chunk_size (262144), chunk_sha256[] (one per chunk), readers[] (1–100 user ids, not the author); body `expires_ms` ≤ created + 31 d | The record key (author‖id) is the blob key (D44); chunks replicate separately |
| `BLOB_FETCHED` | user (reader) | blob_key | After a verified download; all readers → the blob is deleted everywhere (D45) |
| `BACKUP_META` (type 10) | user | `BackupMeta{version, salt (16 B), kdf_m_kib (19456–262144), kdf_t (1–10), kdf_p (1–4), auth_verifier (32 B) = SHA-256(auth_secret), blob_key (32 B, starts with the author id), size}` | Latest `version` wins (D50); accepted only when its blob is a persistent blob of the author already on the node; see [04](04-security.md) |
| `MANIFEST` | network | see [05](05-transport.md) | Highest version wins |
| `REVOCATION` | network | user_id, reason | Node refuses that user afterwards |
| `INVITE_RIGHTS` | network | user_id, can_invite, version | Overrides `can_invite` from directory entry |

**Record key** (dedup/storage key everywhere, incl. "record_id" in [03](03-mesh-replication.md)
and [06](06-node-architecture.md)) = `author (16 bytes) || id (16 bytes)`. Scoping ids by author
prevents another user from pre-empting someone else's record by publishing a record with the
same id first.

Nodes reject any record whose signature or author binding doesn't verify, whose
`author` is revoked, or which violates quotas.

### Wire details fixed in M1 (source of truth: `otter-server/proto/otter/v1/*.proto`)

* `ACK.envelope_ids` are **record keys** (`author‖id`, 32 bytes) of ENVELOPE records; `ACK.device_id`
  names the acknowledging device. An ACK only removes the author's own mailbox entries.
* `INVITE` may be authored by the **network key** (bootstrap invite for the first member) or by a
  member with `can_invite`.
* Endpoint kind `WS_PLAIN` = unencrypted WebSocket for local development only; release builds refuse it.
* Login signature: Ed25519(account key, `"otter-auth-v1" ‖ node_id(16) ‖ nonce(32) ‖ ts_ms(8, big-endian)`),
  `|now − ts| ≤ 5 min`.
* Invite link: `otter://join/` + base64url(no padding) of `InviteBundle{network_pub, manifest record,
  secret, inviter user_id / account_pub / identity_pub / name}` (inviter fields empty for bootstrap).
* libsignal identity key: private = `HKDF-SHA256(seed, salt=∅, info="otter/identity/v1", 32)`;
  public = `0x05 ‖ X25519(private, basepoint)`. Signal address = (hex(user_id), device_id).
* `PREKEYS` replaces the signed and Kyber last-resort prekeys when present and **adds** one-time EC
  prekeys (each with `owner_node`). One-time Kyber prekeys are not used in V1.

## 3. Envelopes (messages)

```proto
message Envelope {
  enum Kind { KIND_UNSPECIFIED = 0; SIGNAL = 1; PREKEY_SIGNAL = 2; SENDER_KEY = 3; }
  bytes  sender_user    = 1;
  uint32 sender_device  = 2;
  repeated Recipient recipients = 3; // 1 for direct, N for group fan-out (max 100)
  Kind   kind           = 4;
  bool   urgent         = 5; // drives push (false for receipts)
  bytes  shared_content = 6; // SENDER_KEY only: one ciphertext for all recipients
}
message Recipient { bytes user = 1; uint32 device = 2; bytes content = 3; /* 1:1 ciphertext */ }
```

* **1:1** (`SIGNAL`/`PREKEY_SIGNAL`): `shared_content` empty, every recipient has `content` (Double Ratchet).
* **Group** (`SENDER_KEY`): `shared_content` = the Sender-Key ciphertext, once; every recipient's `content` is empty.
  Nodes enforce both shapes (`ErrBadPayload` otherwise), fan the record out into each recipient's mailbox and delete it
  after the last recipient's ACK. Sender-key distribution messages travel as normal 1:1 envelopes.
* Envelope id (in `RecordBody.id`) is the **dedup key on clients too**: a client keeps
  seen ids for 30 days because it may receive the same envelope from two nodes during
  a fail-over.
* Nodes see sender, recipients, size, time. Content (incl. message type: text, image,
  receipt, group change) is hidden inside the ciphertext.

### Decrypted content (client-only)

```proto
message Content {
  oneof body {
    DataMessage           data         = 1; // text (+ group context) + attachments (one photo in V1); quotes later
    ReceiptMessage        receipt      = 2; // DELIVERED | READ, list of message ids
    GroupUpdate           group_update = 3; // signed group state (M3)
    SenderKeyDistribution sender_key   = 4; // a member's sender key for one group (M3)
    SessionReset          session_reset = 5; // M6, D53: "I was restored, start a new session" (empty)
    // Profiles travel in the directory, not in E2E content (D14/D39).
  }
  int64 sent_ms = 10;
}
message DataMessage { bytes message_id = 1; string text = 2; GroupContext group = 3; }
message GroupContext { bytes group_id = 1; }
```

### Groups (M3)

Groups are **client-side state**; nodes only fan out envelopes and never see names or membership.

```proto
message GroupState {
  bytes group_id = 1;          // 16 random bytes
  string name = 2;             // 1–64 chars, trimmed
  repeated bytes members = 3;  // user ids, unique, ≤ 100
  repeated bytes admins = 4;   // ⊆ members, non-empty while members is non-empty
  uint64 version = 5;          // 1 at creation, +1 per change
  bool family = 6;             // D34, immutable
  bytes created_by = 7;        // immutable
  int64 created_ms = 8;        // immutable
}
message SignedGroupState { bytes state = 1; bytes signer = 2; bytes signature = 3; }
message GroupUpdate { SignedGroupState state = 1; }
message SenderKeyDistribution { bytes group_id = 1; bytes distribution_id = 2; bytes message = 3; }
```

* **Signing:** `signature = Ed25519(signer's account key, "otter-group-v1" ‖ state)`; `signer` must equal
  `id16(account key)`. An unknown signer triggers one directory sync; still unknown → the update is parked.
* **Distribution:** every change is sent 1:1 (`GroupUpdate`, urgent) to every member of the new state **and** every
  member the change removed. The author applies it locally first through the same rules (works offline).
* **Acceptance rules** (`GroupRules`, pure; D33, D36, D37), after structural checks (sizes, uniqueness, admins ⊆ members,
  immutable fields unchanged):
  * no local state: version 1 is accepted only if signed by `created_by`, who is an admin; a later version is accepted
    if signed by an admin **of that state** (trust on first use: members added later never see version 1); otherwise parked.
  * `version = current + 1`: accepted if the signer is a current admin, or if it is a **self-leave** (only the signer
    removed from members and admins, name unchanged); parked if the signer is not a current member; else rejected.
  * `version > current + 1`: accepted if signed by a current admin, else parked.
  * same version, different bytes: both must be valid successors of the previous state; the lower signer `user_id`
    wins, then the lower SHA-256 of the state bytes; the loser is rejected (all clients converge).
  * lower version: rejected.
  * Parked updates are retried after every accepted update of that group; they expire after 30 days.
* **System events** (created, added, removed, left, renamed, admin granted/revoked, you were removed, undecryptable) are
  stored per accepted change as local messages with an encoded `GroupEvent` and rendered by the UI.
* **Sender keys:** each member has one sender key per group and `distribution_id` (UUID). Before its first group message
  (and whenever a member lacks it) the sender sends its `SenderKeyDistribution` 1:1 to every current member without it,
  right ahead of the message. **Rotation:** an accepted state that removes anyone (removed or left) makes every member
  drop its distribution id; its next message uses a fresh one shared only with the remaining members, so removed
  members cannot read later messages. New members get the key at its current position (D35: no history).
* **Group message:** `Content{data{message_id, text, group{group_id}}}` encrypted once → one `SENDER_KEY` envelope to the
  recipient set frozen at send time minus anyone no longer a member. Accepted by a receiver only if the sender and the
  receiver are members in the receiver's state.
* **Pending group messages:** a message that cannot be decrypted yet (sender key missing) or not placed yet (group unknown,
  sender not yet a member in our state) is kept locally — the node copy is acked — and retried after a sender-key
  distribution or an accepted state; after 7 days it becomes an "undecryptable" system event. Placed messages are
  stored decrypted-pending, because a sender key decrypts each message only once.
* Limit: 100 members.
* **Receipts in groups** (D23): receipts stay 1:1 to the sender. The recipient set is frozen when the message is sent (all
  members except the sender); a receipt counts only if its author is in that set. Aggregate status = DELIVERED when
  every recipient delivered, READ when every recipient read; per-recipient detail in "Сведения о сообщении". READ
  receipts are sent per author (one receipt message per sender).

### Invite rights (D19)
`DIRECTORY_ENTRY` has `can_invite` (default true). A network-signed `INVITE_RIGHTS{user_id,
can_invite}` record overrides it; nodes reject `INVITE` records from users without the right.
Group admin roles have no effect on network invites.

## 4. Client ↔ node API

Transport: one WebSocket per connection (over WSS or tunnelled via REALITY, see [05](05-transport.md)),
binary frames:

```proto
message Frame {
  oneof kind { Request req = 1; Response resp = 2; Event event = 3; }
}
message Request  { uint64 id = 1; string method = 2; bytes body = 3; }
message Response { uint64 id = 1; uint32 status = 2; bytes body = 3; }
message Event    { string type = 1; bytes body = 2; } // server → client push on the socket
```

### Authentication
1. On connect node sends `Event{hello}`: node_id, nonce, manifest version.
2. Client: `auth.login{user_id, device_id, ts, sig(account_key, "otter-auth|"+node_id+nonce+ts)}`.
3. Unauthenticated methods allowed: `register`, `manifest.get`, `backup.auth`, `backup.fetch`.
   `auth.login` answers `LoginResponse{registration_id, installed_ms}` (M6, D52; an older node sends an empty body = zeros).

### Methods

| Method | Purpose |
|--------|---------|
| `register` | invite secret + DIRECTORY_ENTRY + PREKEYS → creates account |
| `auth.login` | see above |
| `manifest.get` | latest signed manifest |
| `directory.sync{since}` | changed directory entries / revocations |
| `directory.update{record}` | newer version of the caller's own DIRECTORY_ENTRY (profile edit, D39): OK; UNAUTHORIZED (someone else's entry); INVALID (changed username, not a directory entry); CONFLICT (version not newer); RETRY_LATER (user not replicated here yet). Every session gets a `directory` event |
| `prekeys.upload` / `prekeys.fetch{user,device}` | Signal prekey bundles |
| `msg.send{Record}` | submit ENVELOPE; response = stored (✓ "sent") |
| `msg.ack{ids}` | submit ACK record; refused (`UNAUTHORIZED`) from a replaced install (D56) |
| `invite.create{Record}` | publish INVITE |
| `blob.create{record}` | author's signed `BLOB_META` (`persistent` = backup blob: no readers, `expires_ms` 0, at most 3 live per user, D50) → `BlobStatus{chunks, missing[]}`; idempotent; `QUOTA` over `max_blob`/`user_quota`; `NOT_FOUND` if it was deleted already |
| `blob.put{blob_key, index, data}` | author only; each chunk verified against its hash (`INVALID` otherwise); re-put is OK |
| `blob.get{blob_key, index}` → `BlobChunk{data}` | author or reader (`UNAUTHORIZED`); not yet replicated → `RETRY_LATER`; deleted → `NOT_FOUND`; a chunk missing here is fetched from a peer at once |
| `blob.ack{record}` | reader's `BLOB_FETCHED` |
| `backup.auth{username}` | **public.** → `BackupAuthResponse{salt, kdf_m_kib, kdf_t, kdf_p}`. Unknown name or no backup: stable fake salt `HMAC-SHA256(SHA-256("otter/fake-salt/v1" ‖ node private key), username)[:16]` with 65536/3/1 (D51) |
| `backup.fetch{username, auth_secret}` | **public.** → `BackupFetchResponse{backup_meta, blob_meta}` and a grant on this connection to `blob.get` that one blob (as its owner). Wrong secret or no backup → `UNAUTHORIZED`; 5 failures per username per hour and 20 per day per node → `RETRY_LATER` "too many attempts" |
| `backup.publish{Record BACKUP_META}` | logged in; `INVALID` unless the blob is a persistent blob of the author already on this node |
| `push.register{Record PUSH_TOKEN}` | `RecordRequest` with the signed `PUSH_TOKEN` (M5, D60); the app sends it after login only when its FCM token changed. A pre-M5 node answers INVALID "unknown method" (harmless) |
| `ping` | keep-alive / RTT measurement |

Events: `hello`, `envelope` (mailbox delivery, batched), `manifest` (newer version available),
`directory` (changes), `prekeys_low`.

Status codes: 0 OK, 1 retry-later, 2 unauthorized, 3 invalid-signature, 4 quota, 5 not-found,
6 revoked, 7 conflict (e.g. username taken).

## 5. Prekeys across nodes

libsignal sessions start with PQXDH using a prekey bundle (signed EC prekey, Kyber prekey,
optional one-time EC prekey). One-time keys must not be handed out twice.

* The client uploads one-time prekeys **partitioned by node**: each key carries an
  `owner_node`. A node hands out **only its own** keys and emits `PREKEY_CONSUMED`.
* When a node runs out of its own keys it hands out the bundle without a one-time EC key
  and with the **last-resort Kyber key** (allowed by libsignal; slightly weaker forward
  secrecy for that first message only) and raises `prekeys_low` to the client.
* Client keeps ~50 one-time keys per node; refills on `prekeys_low` or every login.
* Signed prekey rotated every 7 days.

## 6. Flows

### Join (invite)
```
Inviter app                          Any node                     New user app
  create secret s
  INVITE{id=H(s)} ─────────────────► store+replicate
  show QR: {manifest, s, inviter user_id, account_pub, identity_pub}
                                                         ◄─────── scan QR
                                                                 choose username, display name
                                                                 generate seed → 24 words (shown, confirmed)
                                                                 choose backup password
                                     ◄──── register{s, DIRECTORY_ENTRY, PREKEYS} (race nodes from manifest)
                                     check H(s) unused & unexpired, username free
                                     store, INVITE_USED, replicate ────►
                                     OK ─────────────────────────────►
                                                                 inviter marked "verified" (keys came via QR)
  sees new member, verified ◄──── (E2E hello message from new user)
```
* Invite expiry: 7 days, single use.
* Username collision across a partition (two nodes accept the same name concurrently):
  deterministic resolution — earliest `created_ms`, then lowest user_id keeps it; the other
  client is told `conflict` on next login and must pick a new username.
* First user of a network: `otter-admin bootstrap-invite` creates an invite signed by the
  network key.

### Backup and restore (M6; D50–D56)
1. Backup: the phone gzips a `BackupSnapshot` (client-only, `backup.proto`), encrypts it with Tink streaming AEAD
   (aad = blob key), uploads it as a persistent blob (`blob.create` + `blob.put`), then publishes the signed
   `BACKUP_META` with `backup.publish`. Meta and blob replicate to every node; the previous version is deleted.
2. Restore: link of the network (manifest only) → `backup.auth{username}` → salt and KDF params → Argon2id →
   `backup.fetch{username, auth_secret}` → meta and blob meta → `blob.get` on the granted connection → decrypt.
3. After login the phone uploads fresh `PREKEYS` with a new `installed_ms` (D52), pulls the directory and sends
   `SessionReset` to every contact (D53). The old install is cut off (D56).

### Send 1:1
1. If no session: `prekeys.fetch` → libsignal builds session (PQXDH).
2. Encrypt `Content` → ENVELOPE record (urgent=true) → `msg.send` to current node.
3. Node validates, stores in recipient mailbox, appends to oplog, responds OK → UI ✓.
4. Replicates to peers ([03](03-mesh-replication.md)); if the recipient has no session on it, the responsible
   push-capable node sends a constant FCM wake-up (D58, [06](06-node-architecture.md) "Push").
5. Recipient's node pushes `Event{envelope}`; recipient decrypts, stores, sends `msg.ack`
   and an encrypted `DELIVERED` receipt (urgent=false) → sender UI ✓✓; on view → `READ`.
6. ACK replicates; all nodes delete the envelope.

### Send to group
Same, with Sender Key: if member lacks my current sender key → send `SenderKeyDist` 1:1
first; then one ENVELOPE with N recipients.

### Photo (M4; D44–D48)
1. The client re-encodes the photo (JPEG ≤ 2560 px, no metadata), encrypts it with a fresh 32-byte key
   (Tink AES-256-GCM-HKDF streaming, 1 MiB segments, aad = blob key) and signs a `BLOB_META` (readers = the peer,
   or the group's frozen recipients; expires in 30 days).
2. The message, its attachment and a **held** outbox row are stored together; `blob.create` returns the missing
   chunks, `blob.put` uploads them (4 in flight), then the envelope is released.
3. The message's `DataMessage` carries
   `Attachment{blob_key, key, digest (SHA-256 of the ciphertext), size, mime, width, height, thumbnail (≤ 4 KiB)}`;
   its text is the caption.
4. The receiver shows the thumbnail at once and downloads by policy (Wi-Fi / any / manual) with `blob.get` from its
   current node (which proxies from a peer if needed), checks size and digest, then sends `blob.ack` (`BLOB_FETCHED`).
5. Nodes delete the blob once every reader acked, or at expiry, and keep a tombstone (D45).
