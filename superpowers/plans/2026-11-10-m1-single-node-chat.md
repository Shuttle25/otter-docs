# M1 — Single Node, 1:1 Text Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two Android phones register through invites and exchange end-to-end encrypted 1:1 text
messages through one `otter-node`, with PENDING → SENT → DELIVERED → READ statuses.

**Architecture:** Server: `records` validation → `store` (typed appliers + queries, atomic
group writes) → `service` (register, login, submit, prekeys, directory, mailbox) → `gateway`
(WebSocket sessions, request routing, mailbox delivery) → `transport/wss` (HTTP server with secret
path). `otter-node` wires it from a TOML config; `otter-admin` gains bootstrap invites.
Android: `core:signal` (libsignal store/sessions), `core:network` (OkHttp WebSocket, RPC,
connection manager), `core:database` v2, `core:data` (account, registration, directory sync, outbox,
mailbox receiver, receipts, sync engine), and three feature modules (onboarding, chats, conversation).
Specs: `docs/02-protocol.md` (incl. "Wire details fixed in M1"), `docs/06`, `docs/07`, `docs/10` (UI, normative).

**Tech Stack:** Go 1.26, `github.com/coder/websocket` v1.8.15, `github.com/BurntSushi/toml` v1.6.0,
`github.com/mdp/qrterminal/v3` v3.2.1, `golang.org/x/crypto/curve25519` (vectors only).
Android: libsignal-android **0.106.2** (Signal Maven repo, already configured), OkHttp 5.2.1,
zxing-android-embedded 4.3.0, lifecycle-process 2.9.4, navigation-compose 2.9.5,
hilt-navigation-compose 1.3.0, material-icons-extended (BOM), NDK 27.0.12077973 (stripping).

**Facts verified before writing this plan (2026-11-10):**
- M0 is complete; `make check` and `./gradlew assembleDebug test` are green.
- libsignal-client 0.106.2 classes are **Java 21 bytecode** (class version 65) and its Gradle
  metadata requires JVM 21 → all modules move to Java 21. The machine has only a JDK 17 (`~/.jdks/jbr-17.0.12`)
  and JDK 23 with `javac`; `/usr/lib/jvm/*` are JRE-only. → Use the foojay toolchain resolver (0.10.0,
  Gradle 8.x compatible) to auto-provision JDK 21.
- libsignal API (0.106.2): `SessionBuilder(store, localAddress, remoteAddress)`,
  `SessionCipher(store, localAddress, remoteAddress)`, `IdentityKeyStore.saveIdentity` returns
  `IdentityChange`, `KyberPreKeyStore.markKyberPreKeyUsed(kyberId, signedId, baseKey)` throws
  `ReusedBaseKeyException`, `PreKeyBundle(regId, deviceId, preKeyId, preKey?, signedId, signedPub, signedSig,
  identityKey, kyberId, kyberPub, kyberSig)`, `ECPrivateKey(byte[32])`, `KEMKeyPair.generate(KEMKeyType.KYBER_1024)`.
- `libsignal_jni.so` in the AAR is **not stripped** (~120 MB per ABI) → install NDK so AGP strips it;
  exclude `libsignal_jni_testing.so` and the desktop natives that `libsignal-client.jar` carries as resources.
- AVD `Medium_Phone_API_35` exists (no device attached).
- Go X25519 of seed bytes 0x00..0x1f gives `058f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f`
  (used to cross-check libsignal identity derivation).

**Out of scope for M1 (later milestones):** multi-node replication and endpoint racing (M2), groups (M3),
photos (M4), push/background delivery (M5 — M1 syncs only while the app is in the foreground),
backup/restore and backup password (M6), REALITY (M7), reply-quotes, rate limits, revocation UI (M8).

---

## File structure

```
otter-server/
  proto/otter/v1/{records,manifest}.proto           MODIFY (Ack.device_id, Endpoint WS_PLAIN)
  proto/otter/v1/{envelope,prekeys,invite,api,content}.proto   CREATE
  internal/keys/auth.go                              CREATE  AuthMessage
  internal/records/validate.go                       MODIFY  network INVITE, payload rules
  internal/store/apply.go                            MODIFY  groups, savepoints, origin, write()
  internal/store/typed.go                            CREATE  per-type appliers
  internal/store/query.go                            CREATE  read queries + TakePrekeys
  internal/store/migrations/0002_m1.sql              CREATE
  internal/service/{service,register,submit,errors}.go  CREATE
  internal/gateway/{gateway,session,methods}.go      CREATE
  internal/gateway/e2e_test.go, testclient_test.go   CREATE
  internal/transport/wss/server.go                   CREATE
  internal/config/config.go                          CREATE
  cmd/otter-node/main.go                             CREATE
  internal/admin/invite.go                           CREATE  bootstrap invite, invite links
  internal/admin/state.go, cmd/otter-admin/main.go   MODIFY  --plain, invite bootstrap
  internal/vectors/vectors_test.go, testdata/vectors/v1.json   MODIFY
  scripts/dev-node.sh                                CREATE  local dev network + node

otter-android/
  settings.gradle.kts, gradle/libs.versions.toml, gradle.properties, */build.gradle.kts   MODIFY (Java 21, deps)
  core/crypto/.../{SeedKeys,AuthMessage,InviteLink}.kt   MODIFY/CREATE
  core/signal/   (JVM)  SignalKeyValue.kt, OtterProtocolStore.kt, IdentityKeys.kt, PreKeyFactory.kt, SignalSessions.kt
  core/network/  (JVM)  Transport.kt, OkHttpTransport.kt, Endpoints.kt, RpcClient.kt, NodeApi.kt, ConnectionManager.kt
  core/database/        entities (contacts, conversations, messages, outbox, seen, signal_kv, settings), DAOs, v2 auto-migration
  core/data/     (Android lib)  account/, signal/, registration/, directory/, messaging/, sync/, invite/, di/
  feature/onboarding/   Welcome, InviteInput(scan/paste), Profile, Phrase, PhraseConfirm, Registering
  feature/chats/        ChatList, NewChat, Invite, Settings(stub)
  feature/conversation/ Conversation, MessageBubble, MessageMeta, MessageComposer
  app/                  navigation, network security config, BuildConfig flag, lifecycle sync
```

---

## Part A — `otter-server`

### Task 1: Protos for M1

**Goal:** All wire messages M1 needs, generated for Go (Android picks them up via `sync-proto.sh` in Task 10).

**Files:**
- Modify: `proto/otter/v1/records.proto`, `proto/otter/v1/manifest.proto`
- Create: `proto/otter/v1/envelope.proto`, `prekeys.proto`, `invite.proto`, `api.proto`, `content.proto`
- Regenerate: `internal/proto/otterv1/*.pb.go`

**Acceptance Criteria:**
- [ ] `make gen` passes `buf lint` and regenerates with no manual edits
- [ ] Existing tests still pass (`make check`)

**Verify:** `cd otter-server && make gen && make check`

**Steps:**

- [ ] **Step 1: Modify `records.proto`** — replace `Ack`:
```proto
message Ack {
  // Record keys (author || id, 32 bytes) of acknowledged ENVELOPE records.
  repeated bytes envelope_ids = 1;
  uint32 device_id = 2;
}
```

- [ ] **Step 2: Modify `manifest.proto`** — `Endpoint.Kind`:
```proto
  enum Kind {
    WSS = 0;
    REALITY = 1;
    WS_PLAIN = 2; // development only: unencrypted WebSocket; release apps refuse it
  }
```

- [ ] **Step 3: Create `envelope.proto`**
```proto
syntax = "proto3";
package otter.v1;

option go_package = "ottermsg/server/internal/proto/otterv1;otterv1";
option java_package = "app.ottermsg.proto.v1";
option java_multiple_files = true;

message Envelope {
  enum Kind {
    KIND_UNSPECIFIED = 0;
    SIGNAL = 1;
    PREKEY_SIGNAL = 2;
    SENDER_KEY = 3;
  }
  bytes sender_user = 1;
  uint32 sender_device = 2;
  repeated Recipient recipients = 3;
  Kind kind = 4;
  bool urgent = 5;          // false for receipts; drives push in M5
  bytes shared_content = 6; // SENDER_KEY (M3): one ciphertext for all recipients
}

message Recipient {
  bytes user = 1;
  uint32 device = 2;
  bytes content = 3; // per-recipient libsignal ciphertext (1:1)
}
```

- [ ] **Step 4: Create `prekeys.proto`**
```proto
syntax = "proto3";
package otter.v1;

option go_package = "ottermsg/server/internal/proto/otterv1;otterv1";
option java_package = "app.ottermsg.proto.v1";
option java_multiple_files = true;

message SignedPreKey {
  uint32 id = 1;
  bytes public_key = 2; // EC: 33 bytes; Kyber: libsignal-serialized KEM public key
  bytes signature = 3;  // XEdDSA by identity key
}

message OneTimePreKey {
  uint32 id = 1;
  bytes public_key = 2;
  bytes owner_node = 3; // only this node hands the key out
}

// Payload of a PREKEYS record. signed/kyber replace current ones when set; one_time are added.
message PreKeys {
  uint32 device_id = 1;
  uint32 registration_id = 2;
  SignedPreKey signed_prekey = 3;
  SignedPreKey kyber_prekey = 4;
  repeated OneTimePreKey one_time = 5;
}

message PreKeyBundle {
  bytes user_id = 1;
  uint32 device_id = 2;
  uint32 registration_id = 3;
  bytes identity_pub = 4;
  SignedPreKey signed_prekey = 5;
  SignedPreKey kyber_prekey = 6;
  OneTimePreKey one_time = 7; // absent when this node has none left
}
```

- [ ] **Step 5: Create `invite.proto`**
```proto
syntax = "proto3";
package otter.v1;

import "otter/v1/records.proto";

option go_package = "ottermsg/server/internal/proto/otterv1;otterv1";
option java_package = "app.ottermsg.proto.v1";
option java_multiple_files = true;

// Encoded as otter://join/<base64url(no padding)>.
message InviteBundle {
  bytes network_pub = 1;
  Record manifest = 2;
  bytes secret = 3;               // invite_id = SHA-256(secret)
  bytes inviter_user_id = 4;      // empty for the bootstrap invite
  bytes inviter_account_pub = 5;
  bytes inviter_identity_pub = 6;
  string inviter_name = 7;
}
```

- [ ] **Step 6: Create `api.proto`**
```proto
syntax = "proto3";
package otter.v1;

import "otter/v1/prekeys.proto";
import "otter/v1/records.proto";

option go_package = "ottermsg/server/internal/proto/otterv1;otterv1";
option java_package = "app.ottermsg.proto.v1";
option java_multiple_files = true;

enum Status {
  STATUS_OK = 0;
  STATUS_RETRY_LATER = 1;
  STATUS_UNAUTHORIZED = 2;
  STATUS_INVALID = 3;
  STATUS_NOT_FOUND = 4;
  STATUS_CONFLICT = 5;
  STATUS_REVOKED = 6;
  STATUS_QUOTA = 7;
  STATUS_INTERNAL = 8;
}

message Frame {
  oneof kind {
    Request request = 1;
    Response response = 2;
    Event event = 3;
  }
}

message Request {
  uint64 id = 1;
  string method = 2;
  bytes body = 3;
}

message Response {
  uint64 id = 1;
  Status status = 2;
  bytes body = 3;
  string error = 4;
}

// Server-initiated. Types: hello, envelopes (RecordBatch), directory (Empty), prekeys_low (PrekeysLow).
message Event {
  string type = 1;
  bytes body = 2;
}

message Hello {
  uint32 protocol_version = 1;
  bytes node_id = 2;
  bytes nonce = 3;
  uint64 manifest_version = 4;
  int64 server_time_ms = 5;
}

message LoginRequest {
  bytes user_id = 1;
  uint32 device_id = 2;
  int64 ts_ms = 3;
  bytes signature = 4;
}

message RegisterRequest {
  bytes invite_secret = 1;
  Record directory_entry = 2;
  Record prekeys = 3;
  Record invite_used = 4;
}

// Body of msg.send, msg.ack, prekeys.upload, invite.create.
message RecordRequest {
  Record record = 1;
}

message RecordBatch {
  repeated Record records = 1;
}

message PreKeyFetchRequest {
  bytes user_id = 1;
  uint32 device_id = 2;
}

message ManifestResponse {
  Record manifest = 1;
}

message PrekeysLow {
  uint32 remaining = 1;
}

message Empty {}
```

- [ ] **Step 7: Create `content.proto`** (decrypted content; used only by clients, kept here as single source)
```proto
syntax = "proto3";
package otter.v1;

option go_package = "ottermsg/server/internal/proto/otterv1;otterv1";
option java_package = "app.ottermsg.proto.v1";
option java_multiple_files = true;

message Content {
  oneof body {
    DataMessage data = 1;
    ReceiptMessage receipt = 2;
  }
  int64 sent_ms = 10;
}

message DataMessage {
  bytes message_id = 1; // 16 random bytes chosen by sender; receipts refer to it
  string text = 2;
}

message ReceiptMessage {
  enum Type {
    DELIVERED = 0;
    READ = 1;
  }
  Type type = 1;
  repeated bytes message_ids = 2;
}
```

- [ ] **Step 8: Generate & check** `make gen && make check` → PASS. If `buf lint` flags an enum rule, add it to `except` in `buf.yaml` (do not rename fields — Android depends on these names).
- [ ] **Step 9: Commit** `git add -A && git commit -m "feat(proto): envelope, prekeys, invite, api and content messages"`

---

### Task 2: Validation rules for M1 records + auth message

**Goal:** Validator accepts network-signed bootstrap invites and enforces payload rules for INVITE,
INVITE_USED, ENVELOPE, ACK, PREKEYS; shared `AuthMessage`.

**Files:**
- Create: `internal/keys/auth.go`; Test: add to `internal/keys/keys_test.go`
- Modify: `internal/records/validate.go`; Test: `internal/records/validate_test.go`

**Acceptance Criteria:**
- [ ] `keys.AuthMessage(nodeID, nonce, ts)` = `"otter-auth-v1" ‖ nodeID ‖ nonce ‖ be64(ts)`
- [ ] INVITE authored by `ID16(networkPub)` is verified with the network key; by a user → user key
- [ ] Payload rules (each with a test case): INVITE id 32 bytes & expires > 0; INVITE_USED id 32 bytes & `user_id == author`; ENVELOPE `sender_user == author`, `sender_device == 1`, 1–100 recipients, each `user` 16 bytes & `device ≥ 1`, non-empty content (per recipient or shared), total content ≤ 256 KiB, kind ≠ unspecified; ACK 1–1000 ids each 32 bytes; PREKEYS `device_id == 1`, `registration_id > 0`, signed key (if set) pub 33/sig 64, kyber (if set) pub 1000–2000 bytes/sig 64, ≤ 200 one-time keys each pub 33 & owner_node 16
- [ ] All M0 tests still pass

**Verify:** `go test ./internal/keys/ ./internal/records/ -v` → PASS

**Steps:**

- [ ] **Step 1: Failing tests.** Add to `keys_test.go`:
```go
func TestAuthMessage(t *testing.T) {
	m := AuthMessage(bytes.Repeat([]byte{1}, 16), bytes.Repeat([]byte{2}, 32), 0x0102030405060708)
	want := append([]byte("otter-auth-v1"), bytes.Repeat([]byte{1}, 16)...)
	want = append(want, bytes.Repeat([]byte{2}, 32)...)
	want = append(want, 1, 2, 3, 4, 5, 6, 7, 8)
	if !bytes.Equal(m, want) { t.Fatalf("got %x", m) }
}
```
Add to the `cases` slice in `validate_test.go` (reuse helpers `rid`, `mustSign`, `payload`, `netPriv`, `netID`, `userID`, `userPriv`):
```go
		{"network invite ok", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_INVITE, Author: netID,
				Payload: payload(&pb.Invite{InviteId: make([]byte, 32), ExpiresMs: now.UnixMilli() + 1000})}, netPriv)
		}, nil},
		{"user invite ok", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_INVITE, Author: userID,
				Payload: payload(&pb.Invite{InviteId: make([]byte, 32), ExpiresMs: now.UnixMilli() + 1000})}, userPriv)
		}, nil},
		{"invite short id", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_INVITE, Author: userID,
				Payload: payload(&pb.Invite{InviteId: make([]byte, 31), ExpiresMs: 1})}, userPriv)
		}, ErrBadPayload},
		{"invite_used for someone else", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_INVITE_USED, Author: userID,
				Payload: payload(&pb.InviteUsed{InviteId: make([]byte, 32), UserId: revID})}, userPriv)
		}, ErrBadPayload},
		{"envelope ok", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_ENVELOPE, Author: userID,
				Payload: payload(&pb.Envelope{SenderUser: userID, SenderDevice: 1, Kind: pb.Envelope_SIGNAL,
					Recipients: []*pb.Recipient{{User: revID, Device: 1, Content: []byte{1}}}})}, userPriv)
		}, nil},
		{"envelope spoofed sender", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_ENVELOPE, Author: userID,
				Payload: payload(&pb.Envelope{SenderUser: revID, SenderDevice: 1, Kind: pb.Envelope_SIGNAL,
					Recipients: []*pb.Recipient{{User: revID, Device: 1, Content: []byte{1}}}})}, userPriv)
		}, ErrBadPayload},
		{"envelope no recipients", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_ENVELOPE, Author: userID,
				Payload: payload(&pb.Envelope{SenderUser: userID, SenderDevice: 1, Kind: pb.Envelope_SIGNAL})}, userPriv)
		}, ErrBadPayload},
		{"envelope empty content", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_ENVELOPE, Author: userID,
				Payload: payload(&pb.Envelope{SenderUser: userID, SenderDevice: 1, Kind: pb.Envelope_SIGNAL,
					Recipients: []*pb.Recipient{{User: revID, Device: 1}}})}, userPriv)
		}, ErrBadPayload},
		{"ack bad id length", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_ACK, Author: userID,
				Payload: payload(&pb.Ack{EnvelopeIds: [][]byte{make([]byte, 16)}, DeviceId: 1})}, userPriv)
		}, ErrBadPayload},
		{"prekeys ok", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_PREKEYS, Author: userID,
				Payload: payload(validPrekeys())}, userPriv)
		}, nil},
		{"prekeys bad device", func() *pb.Record {
			p := validPrekeys(); p.DeviceId = 2
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_PREKEYS, Author: userID, Payload: payload(p)}, userPriv)
		}, ErrBadPayload},
		{"prekeys bad one-time owner", func() *pb.Record {
			p := validPrekeys(); p.OneTime[0].OwnerNode = nil
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_PREKEYS, Author: userID, Payload: payload(p)}, userPriv)
		}, ErrBadPayload},
```
and the helper:
```go
func validPrekeys() *pb.PreKeys {
	return &pb.PreKeys{DeviceId: 1, RegistrationId: 7,
		SignedPrekey: &pb.SignedPreKey{Id: 1, PublicKey: make([]byte, 33), Signature: make([]byte, 64)},
		KyberPrekey:  &pb.SignedPreKey{Id: 1, PublicKey: make([]byte, 1569), Signature: make([]byte, 64)},
		OneTime:      []*pb.OneTimePreKey{{Id: 1, PublicKey: make([]byte, 33), OwnerNode: make([]byte, 16)}}}
}
```
Also update the existing `ack` payload in the test to 32-byte ids: `ack := payload(&pb.Ack{EnvelopeIds: [][]byte{make([]byte, 32)}, DeviceId: 1})`.

- [ ] **Step 2: Run** → FAIL.

- [ ] **Step 3: Implement** `internal/keys/auth.go`:
```go
package keys

import "encoding/binary"

const authContext = "otter-auth-v1"

// AuthMessage is the byte string a client signs to log in (docs/02 "Wire details").
func AuthMessage(nodeID, nonce []byte, tsMs int64) []byte {
	m := make([]byte, 0, len(authContext)+len(nodeID)+len(nonce)+8)
	m = append(m, authContext...)
	m = append(m, nodeID...)
	m = append(m, nonce...)
	return binary.BigEndian.AppendUint64(m, uint64(tsMs))
}
```

In `validate.go` add constants and the INVITE signer case:
```go
const (
	MaxBodySize        = 300 * 1024
	MaxRecipients      = 100
	MaxEnvelopeContent = 256 * 1024
	MaxAckIDs          = 1000
	MaxOneTimePrekeys  = 200
)
```
In `signerKey`, add right after the `networkAuthored` case:
```go
	case b.Type == pb.RecordType_INVITE && bytes.Equal(b.Author, keys.ID16(v.NetworkPub)):
		return v.NetworkPub, nil // bootstrap invite for the first member
```
Replace the ACK case in `checkPayload` and add the new ones:
```go
	case pb.RecordType_ACK:
		var a pb.Ack
		if err := proto.Unmarshal(b.Payload, &a); err != nil || len(a.EnvelopeIds) == 0 || len(a.EnvelopeIds) > MaxAckIDs {
			return ErrBadPayload
		}
		for _, id := range a.EnvelopeIds {
			if len(id) != 32 {
				return ErrBadPayload
			}
		}
	case pb.RecordType_INVITE:
		var i pb.Invite
		if err := proto.Unmarshal(b.Payload, &i); err != nil || len(i.InviteId) != 32 || i.ExpiresMs <= 0 {
			return ErrBadPayload
		}
	case pb.RecordType_INVITE_USED:
		var u pb.InviteUsed
		if err := proto.Unmarshal(b.Payload, &u); err != nil || len(u.InviteId) != 32 || !bytes.Equal(u.UserId, b.Author) {
			return ErrBadPayload
		}
	case pb.RecordType_ENVELOPE:
		return checkEnvelope(b)
	case pb.RecordType_PREKEYS:
		return checkPrekeys(b)
```
and below:
```go
func checkEnvelope(b *pb.RecordBody) error {
	var e pb.Envelope
	if err := proto.Unmarshal(b.Payload, &e); err != nil {
		return ErrBadPayload
	}
	if !bytes.Equal(e.SenderUser, b.Author) || e.SenderDevice != 1 || e.Kind == pb.Envelope_KIND_UNSPECIFIED ||
		len(e.Recipients) == 0 || len(e.Recipients) > MaxRecipients {
		return ErrBadPayload
	}
	total := len(e.SharedContent)
	for _, r := range e.Recipients {
		if len(r.User) != 16 || r.Device == 0 || (len(r.Content) == 0 && len(e.SharedContent) == 0) {
			return ErrBadPayload
		}
		total += len(r.Content)
	}
	if total > MaxEnvelopeContent {
		return ErrBadPayload
	}
	return nil
}

func checkSigned(k *pb.SignedPreKey, minPub, maxPub int) bool {
	return k == nil || (len(k.PublicKey) >= minPub && len(k.PublicKey) <= maxPub && len(k.Signature) == 64)
}

func checkPrekeys(b *pb.RecordBody) error {
	var p pb.PreKeys
	if err := proto.Unmarshal(b.Payload, &p); err != nil {
		return ErrBadPayload
	}
	if p.DeviceId != 1 || p.RegistrationId == 0 || !checkSigned(p.SignedPrekey, 33, 33) ||
		!checkSigned(p.KyberPrekey, 1000, 2000) || len(p.OneTime) > MaxOneTimePrekeys {
		return ErrBadPayload
	}
	for _, k := range p.OneTime {
		if len(k.PublicKey) != 33 || len(k.OwnerNode) != 16 {
			return ErrBadPayload
		}
	}
	return nil
}
```
Remove the old standalone `MaxBodySize` const (now in the block).

- [ ] **Step 4: Run** `go test ./internal/keys/ ./internal/records/ -v` → PASS; `make check` → PASS.
- [ ] **Step 5: Commit** `git add -A && git commit -m "feat(records): M1 payload rules, network bootstrap invites, auth message"`

---

### Task 3: Store — typed appliers, atomic groups, queries

**Goal:** Records update derived tables (users, invites, prekeys, mailbox, tombstones, manifest) in the
same transaction; registration can apply three records atomically; services get typed queries.

**Files:**
- Create: `internal/store/migrations/0002_m1.sql`, `internal/store/typed.go`, `internal/store/query.go`
- Modify: `internal/store/apply.go`, `internal/store/store.go`
- Test: `internal/store/typed_test.go`

**Acceptance Criteria:**
- [ ] Every Apply request runs inside `SAVEPOINT req`; any error rolls back only that request
- [ ] `ApplyAll(ctx, origin, items)` is all-or-nothing
- [ ] DIRECTORY_ENTRY inserts/updates `users` (higher version wins; `entry_key` follows); a different user claiming a taken username → `ErrUsernameTaken`, record not stored
- [ ] INVITE inserts `invites`; INVITE_USED sets `used_by` once, else `ErrInviteUnavailable`
- [ ] PREKEYS upserts `devices`, replaces signed/kyber, adds one-time keys
- [ ] ENVELOPE adds one mailbox row per recipient unless tombstoned; ACK deletes the author's rows, writes tombstones (30 d) and deletes the envelope record when no mailbox rows remain
- [ ] MANIFEST inserts into `manifest`
- [ ] Queries: `UserKey` (implements `records.UserResolver`), `UserByID`, `UsernameOwner`, `DirectoryEntries`, `Invite`, `Mailbox`, `TakePrekeys` (consumes one own one-time key, returns remaining), `LatestManifest`
- [ ] Existing store tests still pass

**Verify:** `go test -race ./internal/store/ -v` → PASS

**Steps:**

- [ ] **Step 1: Migration `0002_m1.sql`**
```sql
DROP TABLE tombstones;
CREATE TABLE tombstones(record_key BLOB NOT NULL, user_id BLOB NOT NULL, device_id INTEGER NOT NULL,
                        until_ms INTEGER NOT NULL, PRIMARY KEY(record_key, user_id, device_id));
ALTER TABLE prekeys ADD COLUMN signature BLOB;
CREATE TABLE devices(user_id BLOB NOT NULL, device_id INTEGER NOT NULL, registration_id INTEGER NOT NULL,
                     PRIMARY KEY(user_id, device_id));
CREATE INDEX mailbox_record ON mailbox(record_key);
```

- [ ] **Step 2: Failing tests** `typed_test.go`. Records here bypass the validator, so build bodies directly:
```go
package store

import (
	"context"
	"crypto/rand"
	"errors"
	"testing"

	"google.golang.org/protobuf/proto"
	pb "ottermsg/server/internal/proto/otterv1"
)

func r16() []byte { b := make([]byte, 16); rand.Read(b); return b }

func item(t *testing.T, typ pb.RecordType, author []byte, payload proto.Message) Item {
	p, _ := proto.Marshal(payload)
	b := &pb.RecordBody{Id: r16(), Type: typ, Author: author, Payload: p}
	raw, _ := proto.Marshal(b)
	return Item{Record: &pb.Record{Body: raw, Signature: make([]byte, 64)}, Body: b}
}

func apply(t *testing.T, s *Store, it Item) error {
	_, _, err := s.ApplyFrom(context.Background(), it.Record, it.Body, []byte("node-node-node-1"))
	return err
}

func entry(id []byte, name string, ver uint64) *pb.DirectoryEntry {
	return &pb.DirectoryEntry{UserId: id, Username: name, DisplayName: name, AccountPub: make([]byte, 32), Version: ver, CanInvite: true}
}

func TestDirectoryEntries(t *testing.T) {
	s, _ := open(t)
	ctx := context.Background()
	a, b := r16(), r16()
	if err := apply(t, s, item(t, pb.RecordType_DIRECTORY_ENTRY, a, entry(a, "anna", 1))); err != nil { t.Fatal(err) }
	if err := apply(t, s, item(t, pb.RecordType_DIRECTORY_ENTRY, b, entry(b, "anna", 1))); !errors.Is(err, ErrUsernameTaken) {
		t.Fatalf("want ErrUsernameTaken, got %v", err)
	}
	if err := apply(t, s, item(t, pb.RecordType_DIRECTORY_ENTRY, a, entry(a, "anna_k", 2))); err != nil { t.Fatal(err) }
	u, err := s.UserByID(ctx, a)
	if err != nil || u.Username != "anna_k" || u.Version != 2 { t.Fatalf("user: %+v %v", u, err) }
	if _, ok := s.UserKey(a); !ok { t.Fatal("UserKey missing") }
	if _, ok := s.UserKey(b); ok { t.Fatal("b must not exist (rolled back)") }
	all, _ := s.DirectoryEntries(ctx)
	if len(all) != 1 { t.Fatalf("entries %d", len(all)) }
	owner, _ := s.UsernameOwner(ctx, "anna_k")
	if string(owner) != string(a) { t.Fatal("owner") }
}

func TestInviteFlowAtomic(t *testing.T) {
	s, _ := open(t)
	ctx := context.Background()
	inviter, newU := r16(), r16()
	id := make([]byte, 32); rand.Read(id)
	if err := apply(t, s, item(t, pb.RecordType_INVITE, inviter, &pb.Invite{InviteId: id, ExpiresMs: 1 << 62})); err != nil { t.Fatal(err) }
	group := []Item{
		item(t, pb.RecordType_DIRECTORY_ENTRY, newU, entry(newU, "boris", 1)),
		item(t, pb.RecordType_INVITE_USED, newU, &pb.InviteUsed{InviteId: id, UserId: newU}),
	}
	if _, err := s.ApplyAll(ctx, nil, group); err != nil { t.Fatal(err) }
	inv, _ := s.Invite(ctx, id)
	if string(inv.UsedBy) != string(newU) { t.Fatal("used_by") }
	other := r16()
	group2 := []Item{
		item(t, pb.RecordType_DIRECTORY_ENTRY, other, entry(other, "vera", 1)),
		item(t, pb.RecordType_INVITE_USED, other, &pb.InviteUsed{InviteId: id, UserId: other}),
	}
	if _, err := s.ApplyAll(ctx, nil, group2); !errors.Is(err, ErrInviteUnavailable) { t.Fatalf("want ErrInviteUnavailable, got %v", err) }
	if u, _ := s.UserByID(ctx, other); u != nil { t.Fatal("vera must be rolled back") }
}

func TestMailboxAndAck(t *testing.T) {
	s, _ := open(t)
	ctx := context.Background()
	sender, rcpt := r16(), r16()
	env := item(t, pb.RecordType_ENVELOPE, sender, &pb.Envelope{SenderUser: sender, SenderDevice: 1, Kind: pb.Envelope_SIGNAL,
		Recipients: []*pb.Recipient{{User: rcpt, Device: 1, Content: []byte{9}}}})
	if err := apply(t, s, env); err != nil { t.Fatal(err) }
	box, _ := s.Mailbox(ctx, rcpt, 1, 10)
	if len(box) != 1 { t.Fatalf("mailbox %d", len(box)) }
	key := box[0].Key
	if err := apply(t, s, item(t, pb.RecordType_ACK, sender, &pb.Ack{EnvelopeIds: [][]byte{key}, DeviceId: 1})); err != nil { t.Fatal(err) }
	if box, _ := s.Mailbox(ctx, rcpt, 1, 10); len(box) != 1 { t.Fatal("someone else's ACK removed the entry") }
	if err := apply(t, s, item(t, pb.RecordType_ACK, rcpt, &pb.Ack{EnvelopeIds: [][]byte{key}, DeviceId: 1})); err != nil { t.Fatal(err) }
	if box, _ := s.Mailbox(ctx, rcpt, 1, 10); len(box) != 0 { t.Fatal("not removed") }
	if _, err := s.Get(ctx, key); !errors.Is(err, ErrNotFound) { t.Fatalf("envelope should be deleted, got %v", err) }
	// re-applying the same envelope (e.g. via replication later) must not resurrect it
	_, _, _ = s.ApplyFrom(ctx, env.Record, env.Body, nil)
	if box, _ := s.Mailbox(ctx, rcpt, 1, 10); len(box) != 0 { t.Fatal("resurrected") }
}

func TestPrekeys(t *testing.T) {
	s, _ := open(t)
	ctx := context.Background()
	u, me, other := r16(), []byte("me-me-me-me-me-1"), []byte("other-other-oth1")
	pk := &pb.PreKeys{DeviceId: 1, RegistrationId: 42,
		SignedPrekey: &pb.SignedPreKey{Id: 1, PublicKey: []byte{1}, Signature: []byte{2}},
		KyberPrekey:  &pb.SignedPreKey{Id: 1, PublicKey: []byte{3}, Signature: []byte{4}},
		OneTime: []*pb.OneTimePreKey{{Id: 10, PublicKey: []byte{5}, OwnerNode: me}, {Id: 11, PublicKey: []byte{6}, OwnerNode: other}}}
	if err := apply(t, s, item(t, pb.RecordType_PREKEYS, u, pk)); err != nil { t.Fatal(err) }
	got, err := s.TakePrekeys(ctx, u, 1, me)
	if err != nil || got.RegistrationID != 42 || got.OneTime == nil || got.OneTime.Id != 10 || got.RemainingOwn != 0 { t.Fatalf("%+v %v", got, err) }
	got, _ = s.TakePrekeys(ctx, u, 1, me)
	if got.OneTime != nil { t.Fatal("one-time key handed out twice / foreign key handed out") }
	if got.Signed.Id != 1 || got.Kyber.Id != 1 { t.Fatal("signed/kyber missing") }
	if _, err := s.TakePrekeys(ctx, r16(), 1, me); !errors.Is(err, ErrNotFound) { t.Fatalf("want ErrNotFound, got %v", err) }
}

func TestManifestTable(t *testing.T) {
	s, _ := open(t)
	netID := r16()
	if err := apply(t, s, item(t, pb.RecordType_MANIFEST, netID, &pb.Manifest{Version: 3})); err != nil { t.Fatal(err) }
	if err := apply(t, s, item(t, pb.RecordType_MANIFEST, netID, &pb.Manifest{Version: 5})); err != nil { t.Fatal(err) }
	v, raw, err := s.LatestManifest(context.Background())
	if err != nil || v != 5 || len(raw) == 0 { t.Fatalf("%d %v", v, err) }
}
```

- [ ] **Step 3: Run** → FAIL.

- [ ] **Step 4: Rewrite `apply.go`**
```go
package store

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"google.golang.org/protobuf/proto"
	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
)

const (
	maxBatch  = 256
	batchWait = 10 * time.Millisecond
)

// Item is a validated record with its parsed body.
type Item struct {
	Record *pb.Record
	Body   *pb.RecordBody
}

type item struct {
	key, raw []byte
	body     *pb.RecordBody
	origin   []byte
}

type applyReq struct {
	items []item
	fn    func(context.Context, *sql.Tx) error
	res   chan applyRes
}

type applyRes struct {
	seqs    []int64
	applied []bool
	err     error
}

type LogEntry struct {
	Seq int64
	Raw []byte // serialized pb.Record
}

func toItem(it Item, origin []byte) (item, error) {
	key, err := keys.RecordKey(it.Body.Author, it.Body.Id)
	if err != nil {
		return item{}, err
	}
	raw, err := proto.Marshal(it.Record)
	if err != nil {
		return item{}, err
	}
	return item{key: key, raw: raw, body: it.Body, origin: origin}, nil
}

// Apply stores a validated record. Idempotent by author||id.
func (s *Store) Apply(ctx context.Context, rec *pb.Record, body *pb.RecordBody) (int64, bool, error) {
	return s.ApplyFrom(ctx, rec, body, nil)
}

// ApplyFrom is Apply with the node that first accepted the record (mailbox origin).
func (s *Store) ApplyFrom(ctx context.Context, rec *pb.Record, body *pb.RecordBody, origin []byte) (int64, bool, error) {
	it, err := toItem(Item{rec, body}, origin)
	if err != nil {
		return 0, false, err
	}
	r, err := s.submit(ctx, &applyReq{items: []item{it}})
	if err != nil {
		return 0, false, err
	}
	return r.seqs[0], r.applied[0], nil
}

// ApplyAll applies all items atomically: either every record is stored or none.
func (s *Store) ApplyAll(ctx context.Context, origin []byte, items []Item) ([]int64, error) {
	req := &applyReq{}
	for _, in := range items {
		it, err := toItem(in, origin)
		if err != nil {
			return nil, err
		}
		req.items = append(req.items, it)
	}
	r, err := s.submit(ctx, req)
	return r.seqs, err
}

// write runs fn inside the writer's transaction (savepoint-isolated).
func (s *Store) write(ctx context.Context, fn func(context.Context, *sql.Tx) error) error {
	_, err := s.submit(ctx, &applyReq{fn: fn})
	return err
}

func (s *Store) submit(ctx context.Context, req *applyReq) (applyRes, error) {
	req.res = make(chan applyRes, 1)
	select {
	case s.reqs <- req:
	case <-s.done:
		return applyRes{}, errClosed
	case <-ctx.Done():
		return applyRes{}, ctx.Err()
	}
	select {
	case r := <-req.res:
		return r, r.err
	case <-s.stopped:
		select {
		case r := <-req.res:
			return r, r.err
		default:
			return applyRes{}, errClosed
		}
	case <-ctx.Done():
		return applyRes{}, ctx.Err()
	}
}

func (s *Store) writer() {
	defer close(s.stopped)
	for {
		var batch []*applyReq
		select {
		case r := <-s.reqs:
			batch = append(batch, r)
		case <-s.done:
			return
		}
		timer := time.NewTimer(batchWait)
	fill:
		for len(batch) < maxBatch {
			select {
			case r := <-s.reqs:
				batch = append(batch, r)
			case <-timer.C:
				break fill
			}
		}
		timer.Stop()
		s.commit(batch)
	}
}

func (s *Store) commit(batch []*applyReq) {
	ctx := context.Background()
	results := make([]applyRes, len(batch))
	tx, err := s.w.BeginTx(ctx, nil)
	if err == nil {
		now := s.now().UnixMilli()
		for i, r := range batch {
			results[i] = runReq(ctx, tx, r, now)
		}
		err = tx.Commit()
	}
	for i, r := range batch {
		if err != nil {
			results[i] = applyRes{err: err}
		}
		r.res <- results[i]
	}
}

func runReq(ctx context.Context, tx *sql.Tx, r *applyReq, now int64) applyRes {
	if _, err := tx.ExecContext(ctx, `SAVEPOINT req`); err != nil {
		return applyRes{err: err}
	}
	var res applyRes
	var err error
	if r.fn != nil {
		err = r.fn(ctx, tx)
	} else {
		for _, it := range r.items {
			seq, applied, e := applyOne(ctx, tx, it, now)
			if e != nil {
				err = e
				break
			}
			res.seqs = append(res.seqs, seq)
			res.applied = append(res.applied, applied)
		}
	}
	if err != nil {
		tx.ExecContext(ctx, `ROLLBACK TO req`)
		tx.ExecContext(ctx, `RELEASE req`)
		return applyRes{err: err}
	}
	if _, err := tx.ExecContext(ctx, `RELEASE req`); err != nil {
		return applyRes{err: err}
	}
	return res
}

func applyOne(ctx context.Context, tx *sql.Tx, it item, now int64) (int64, bool, error) {
	var seq int64
	err := tx.QueryRowContext(ctx, `SELECT seq FROM oplog WHERE record_key=?`, it.key).Scan(&seq)
	if err == nil {
		return seq, false, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return 0, false, err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO records(record_key,type,author,created_ms,expires_ms,raw) VALUES(?,?,?,?,?,?)`,
		it.key, int32(it.body.Type), it.body.Author, it.body.CreatedMs, it.body.ExpiresMs, it.raw); err != nil {
		return 0, false, err
	}
	res, err := tx.ExecContext(ctx, `INSERT INTO oplog(record_key,type,received_ms) VALUES(?,?,?)`, it.key, int32(it.body.Type), now)
	if err != nil {
		return 0, false, err
	}
	seq, _ = res.LastInsertId()
	if err := applyTyped(ctx, tx, it, now); err != nil {
		return 0, false, err
	}
	return seq, true, nil
}

// Since returns log entries with seq > cursor, oldest first. Deleted records are skipped.
func (s *Store) Since(ctx context.Context, cursor int64, limit int) ([]LogEntry, error) {
	rows, err := s.r.QueryContext(ctx,
		`SELECT o.seq, r.raw FROM oplog o JOIN records r ON r.record_key=o.record_key WHERE o.seq>? ORDER BY o.seq LIMIT ?`,
		cursor, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []LogEntry
	for rows.Next() {
		var e LogEntry
		if err := rows.Scan(&e.Seq, &e.Raw); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// Get returns the serialized record stored under key (author||id).
func (s *Store) Get(ctx context.Context, key []byte) ([]byte, error) {
	var raw []byte
	err := s.r.QueryRowContext(ctx, `SELECT raw FROM records WHERE record_key=?`, key).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return raw, err
}
```
In `store.go` add exported errors next to `ErrNotFound`:
```go
var (
	ErrUsernameTaken     = errors.New("username taken")
	ErrInviteUnavailable = errors.New("invite unknown, used or expired")
)
```

- [ ] **Step 5: `typed.go`**
```go
package store

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"time"

	"google.golang.org/protobuf/proto"
	pb "ottermsg/server/internal/proto/otterv1"
)

const (
	PrekeySigned  = 1
	PrekeyKyber   = 2
	PrekeyOneTime = 3
	tombstoneTTL  = 30 * 24 * time.Hour
)

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// applyTyped maintains derived tables. Runs inside the request savepoint.
// NOTE (M2): replicated records must apply leniently (e.g. INVITE_USED for an invite already used
// elsewhere); M2 introduces conflict rules — M1 has a single node.
func applyTyped(ctx context.Context, tx *sql.Tx, it item, now int64) error {
	b := it.body
	switch b.Type {
	case pb.RecordType_DIRECTORY_ENTRY:
		var e pb.DirectoryEntry
		if err := proto.Unmarshal(b.Payload, &e); err != nil {
			return err
		}
		var owner []byte
		err := tx.QueryRowContext(ctx, `SELECT user_id FROM users WHERE username=?`, e.Username).Scan(&owner)
		if err == nil && !bytes.Equal(owner, e.UserId) {
			return ErrUsernameTaken
		}
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		var cur uint64
		err = tx.QueryRowContext(ctx, `SELECT version FROM users WHERE user_id=?`, e.UserId).Scan(&cur)
		switch {
		case errors.Is(err, sql.ErrNoRows):
			_, err = tx.ExecContext(ctx,
				`INSERT INTO users(user_id,username,account_pub,entry_key,version,can_invite,created_ms) VALUES(?,?,?,?,?,?,?)`,
				e.UserId, e.Username, e.AccountPub, it.key, e.Version, boolInt(e.CanInvite), now)
		case err != nil:
		case e.Version > cur:
			_, err = tx.ExecContext(ctx, `UPDATE users SET username=?, entry_key=?, version=? WHERE user_id=?`,
				e.Username, it.key, e.Version, e.UserId)
		}
		return err

	case pb.RecordType_INVITE:
		var i pb.Invite
		if err := proto.Unmarshal(b.Payload, &i); err != nil {
			return err
		}
		_, err := tx.ExecContext(ctx, `INSERT OR IGNORE INTO invites(invite_id,inviter,expires_ms) VALUES(?,?,?)`,
			i.InviteId, b.Author, i.ExpiresMs)
		return err

	case pb.RecordType_INVITE_USED:
		var u pb.InviteUsed
		if err := proto.Unmarshal(b.Payload, &u); err != nil {
			return err
		}
		res, err := tx.ExecContext(ctx, `UPDATE invites SET used_by=? WHERE invite_id=? AND used_by IS NULL AND expires_ms>?`,
			u.UserId, u.InviteId, now)
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return ErrInviteUnavailable
		}
		return nil

	case pb.RecordType_PREKEYS:
		var p pb.PreKeys
		if err := proto.Unmarshal(b.Payload, &p); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO devices(user_id,device_id,registration_id) VALUES(?,?,?)
			 ON CONFLICT(user_id,device_id) DO UPDATE SET registration_id=excluded.registration_id`,
			b.Author, p.DeviceId, p.RegistrationId); err != nil {
			return err
		}
		put := func(kind int, k *pb.SignedPreKey) error {
			if k == nil {
				return nil
			}
			if _, err := tx.ExecContext(ctx, `DELETE FROM prekeys WHERE user_id=? AND device_id=? AND kind=?`, b.Author, p.DeviceId, kind); err != nil {
				return err
			}
			_, err := tx.ExecContext(ctx,
				`INSERT INTO prekeys(user_id,device_id,key_id,kind,owner_node,public,signature) VALUES(?,?,?,?,NULL,?,?)`,
				b.Author, p.DeviceId, k.Id, kind, k.PublicKey, k.Signature)
			return err
		}
		if err := put(PrekeySigned, p.SignedPrekey); err != nil {
			return err
		}
		if err := put(PrekeyKyber, p.KyberPrekey); err != nil {
			return err
		}
		for _, k := range p.OneTime {
			if _, err := tx.ExecContext(ctx,
				`INSERT OR IGNORE INTO prekeys(user_id,device_id,key_id,kind,owner_node,public) VALUES(?,?,?,?,?,?)`,
				b.Author, p.DeviceId, k.Id, PrekeyOneTime, k.OwnerNode, k.PublicKey); err != nil {
				return err
			}
		}
		return nil

	case pb.RecordType_ENVELOPE:
		var e pb.Envelope
		if err := proto.Unmarshal(b.Payload, &e); err != nil {
			return err
		}
		for _, r := range e.Recipients {
			var x int
			err := tx.QueryRowContext(ctx, `SELECT 1 FROM tombstones WHERE record_key=? AND user_id=? AND device_id=?`,
				it.key, r.User, r.Device).Scan(&x)
			if err == nil {
				continue
			}
			if !errors.Is(err, sql.ErrNoRows) {
				return err
			}
			if _, err := tx.ExecContext(ctx,
				`INSERT OR IGNORE INTO mailbox(user_id,device_id,record_key,origin_node,received_ms) VALUES(?,?,?,?,?)`,
				r.User, r.Device, it.key, it.origin, now); err != nil {
				return err
			}
		}
		return nil

	case pb.RecordType_ACK:
		var a pb.Ack
		if err := proto.Unmarshal(b.Payload, &a); err != nil {
			return err
		}
		dev := a.DeviceId
		if dev == 0 {
			dev = 1
		}
		until := now + tombstoneTTL.Milliseconds()
		for _, k := range a.EnvelopeIds {
			if _, err := tx.ExecContext(ctx, `DELETE FROM mailbox WHERE user_id=? AND device_id=? AND record_key=?`, b.Author, dev, k); err != nil {
				return err
			}
			if _, err := tx.ExecContext(ctx, `INSERT OR IGNORE INTO tombstones(record_key,user_id,device_id,until_ms) VALUES(?,?,?,?)`,
				k, b.Author, dev, until); err != nil {
				return err
			}
			if _, err := tx.ExecContext(ctx,
				`DELETE FROM records WHERE record_key=? AND type=? AND NOT EXISTS (SELECT 1 FROM mailbox WHERE record_key=?)`,
				k, int32(pb.RecordType_ENVELOPE), k); err != nil {
				return err
			}
		}
		return nil

	case pb.RecordType_MANIFEST:
		var m pb.Manifest
		if err := proto.Unmarshal(b.Payload, &m); err != nil {
			return err
		}
		_, err := tx.ExecContext(ctx, `INSERT OR IGNORE INTO manifest(version,raw) VALUES(?,?)`, m.Version, it.raw)
		return err
	}
	return nil
}
```
Note on `TestMailboxAndAck` re-apply: the second `ApplyFrom` of the same envelope finds the oplog row
(`applied=false`) and does nothing, so it can't resurrect the entry. Tombstones additionally protect
replicated copies arriving in M2.

- [ ] **Step 6: `query.go`**
```go
package store

import (
	"context"
	"database/sql"
	"errors"

	"ottermsg/server/internal/records"
	pb "ottermsg/server/internal/proto/otterv1"
)

type User struct {
	ID         []byte
	Username   string
	AccountPub []byte
	Version    uint64
	Revoked    bool
	CanInvite  bool
	EntryRaw   []byte // serialized pb.Record of the current DIRECTORY_ENTRY
}

type InviteState struct {
	Inviter   []byte
	ExpiresMs int64
	UsedBy    []byte
}

type MailboxEntry struct {
	Key []byte
	Raw []byte // serialized pb.Record
}

type PrekeyRows struct {
	RegistrationID uint32
	Signed, Kyber  *pb.SignedPreKey
	OneTime        *pb.OneTimePreKey
	RemainingOwn   int
}

// UserKey implements records.UserResolver.
func (s *Store) UserKey(id []byte) (records.UserKey, bool) {
	var pub []byte
	var revoked int
	if err := s.r.QueryRow(`SELECT account_pub, revoked FROM users WHERE user_id=?`, id).Scan(&pub, &revoked); err != nil {
		return records.UserKey{}, false
	}
	return records.UserKey{Pub: pub, Revoked: revoked != 0}, true
}

// UserByID returns nil, nil when the user does not exist.
func (s *Store) UserByID(ctx context.Context, id []byte) (*User, error) {
	u := &User{ID: id}
	var revoked, canInvite int
	err := s.r.QueryRowContext(ctx,
		`SELECT u.username, u.account_pub, u.version, u.revoked, u.can_invite, r.raw
		 FROM users u JOIN records r ON r.record_key=u.entry_key WHERE u.user_id=?`, id).
		Scan(&u.Username, &u.AccountPub, &u.Version, &revoked, &canInvite, &u.EntryRaw)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	u.Revoked, u.CanInvite = revoked != 0, canInvite != 0
	return u, nil
}

// UsernameOwner returns nil, nil when the username is free.
func (s *Store) UsernameOwner(ctx context.Context, username string) ([]byte, error) {
	var id []byte
	err := s.r.QueryRowContext(ctx, `SELECT user_id FROM users WHERE username=?`, username).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return id, err
}

// DirectoryEntries returns current DIRECTORY_ENTRY records (serialized), oldest member first.
func (s *Store) DirectoryEntries(ctx context.Context) ([][]byte, error) {
	rows, err := s.r.QueryContext(ctx,
		`SELECT r.raw FROM users u JOIN records r ON r.record_key=u.entry_key ORDER BY u.created_ms, u.user_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out [][]byte
	for rows.Next() {
		var raw []byte
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		out = append(out, raw)
	}
	return out, rows.Err()
}

func (s *Store) Invite(ctx context.Context, id []byte) (*InviteState, error) {
	var st InviteState
	err := s.r.QueryRowContext(ctx, `SELECT inviter, expires_ms, used_by FROM invites WHERE invite_id=?`, id).
		Scan(&st.Inviter, &st.ExpiresMs, &st.UsedBy)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return &st, err
}

// Mailbox returns pending envelopes for a device, oldest first.
func (s *Store) Mailbox(ctx context.Context, user []byte, device uint32, limit int) ([]MailboxEntry, error) {
	rows, err := s.r.QueryContext(ctx,
		`SELECT m.record_key, r.raw FROM mailbox m JOIN records r ON r.record_key=m.record_key
		 WHERE m.user_id=? AND m.device_id=? ORDER BY m.received_ms, m.record_key LIMIT ?`, user, device, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []MailboxEntry
	for rows.Next() {
		var e MailboxEntry
		if err := rows.Scan(&e.Key, &e.Raw); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// TakePrekeys returns a bundle's key material and consumes one one-time key owned by node.
func (s *Store) TakePrekeys(ctx context.Context, user []byte, device uint32, node []byte) (*PrekeyRows, error) {
	out := &PrekeyRows{}
	err := s.write(ctx, func(ctx context.Context, tx *sql.Tx) error {
		err := tx.QueryRowContext(ctx, `SELECT registration_id FROM devices WHERE user_id=? AND device_id=?`, user, device).
			Scan(&out.RegistrationID)
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		get := func(kind int) (*pb.SignedPreKey, error) {
			k := &pb.SignedPreKey{}
			err := tx.QueryRowContext(ctx, `SELECT key_id, public, signature FROM prekeys WHERE user_id=? AND device_id=? AND kind=?`,
				user, device, kind).Scan(&k.Id, &k.PublicKey, &k.Signature)
			if errors.Is(err, sql.ErrNoRows) {
				return nil, ErrNotFound
			}
			return k, err
		}
		if out.Signed, err = get(PrekeySigned); err != nil {
			return err
		}
		if out.Kyber, err = get(PrekeyKyber); err != nil {
			return err
		}
		ot := &pb.OneTimePreKey{OwnerNode: node}
		err = tx.QueryRowContext(ctx,
			`SELECT key_id, public FROM prekeys WHERE user_id=? AND device_id=? AND kind=? AND owner_node=? AND consumed=0
			 ORDER BY key_id LIMIT 1`, user, device, PrekeyOneTime, node).Scan(&ot.Id, &ot.PublicKey)
		switch {
		case err == nil:
			if _, err := tx.ExecContext(ctx, `UPDATE prekeys SET consumed=1 WHERE user_id=? AND device_id=? AND kind=? AND key_id=?`,
				user, device, PrekeyOneTime, ot.Id); err != nil {
				return err
			}
			out.OneTime = ot
		case !errors.Is(err, sql.ErrNoRows):
			return err
		}
		return tx.QueryRowContext(ctx,
			`SELECT COUNT(*) FROM prekeys WHERE user_id=? AND device_id=? AND kind=? AND owner_node=? AND consumed=0`,
			user, device, PrekeyOneTime, node).Scan(&out.RemainingOwn)
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// LatestManifest returns ErrNotFound when no manifest has been imported.
func (s *Store) LatestManifest(ctx context.Context) (uint64, []byte, error) {
	var v uint64
	var raw []byte
	err := s.r.QueryRowContext(ctx, `SELECT version, raw FROM manifest ORDER BY version DESC LIMIT 1`).Scan(&v, &raw)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil, ErrNotFound
	}
	return v, raw, err
}
```

- [ ] **Step 6b: Fix the old `TestApplyIdempotent` / `TestConcurrentApply` helpers if needed** — `rec()` builds ACK
bodies with an empty payload; `applyTyped` would now fail to parse nothing? (`proto.Unmarshal` of empty bytes
succeeds, `EnvelopeIds` empty → loop does nothing.) No change expected; run to confirm.

- [ ] **Step 7: Run** `go test -race ./internal/store/ -v` → PASS.
- [ ] **Step 8: Commit** `git add -A && git commit -m "feat(store): typed appliers, atomic groups, M1 queries"`

---

### Task 4: `internal/service` — register, login, submit, prekeys, directory

**Goal:** Transport-independent business logic with typed errors.

**Files:**
- Create: `internal/service/errors.go`, `service.go`, `register.go`, `submit.go`
- Test: `internal/service/service_test.go`

**Acceptance Criteria:**
- [ ] `Register` checks (in order): complete request; invite exists (`ErrNotFound`); not used / not expired (`ErrConflict`); inviter is the network or an existing, non-revoked member with `can_invite` (`ErrUnauthorized`); directory entry valid (`ErrInvalid`); user not yet registered and username free (`ErrConflict`); prekeys record (author = new user, signed+kyber present) and INVITE_USED (matching invite id) valid; then applies all three atomically and calls `Notify.Directory()`
- [ ] `VerifyLogin` checks device 1, |now−ts| ≤ 5 min, user exists (`ErrUnauthorized`), not revoked (`ErrRevoked`), signature over `keys.AuthMessage(nodeID, nonce, ts)`
- [ ] `Submit(ctx, user, rec, allowed...)` validates, requires `author == user`, type in `allowed`; ENVELOPE recipients must exist (`ErrNotFound`); INVITE requires invite right; on first application of an ENVELOPE calls `Notify.Envelope` per recipient
- [ ] `FetchPrekeys` returns a `pb.PreKeyBundle` (identity from the directory entry); calls `Notify.PrekeysLow` when fewer than 10 own one-time keys remain
- [ ] `Directory`, `Manifest`, `Mailbox`, `ImportRecord` (validate + apply, any author) implemented
- [ ] Tests cover every error branch listed above

**Verify:** `go test ./internal/service/ -v` → PASS

**Steps:**

- [ ] **Step 1: `errors.go`**
```go
// Package service implements node business logic independent of transports.
package service

import (
	"errors"
	"fmt"

	"ottermsg/server/internal/records"
)

var (
	ErrInvalid      = errors.New("invalid")
	ErrNotFound     = errors.New("not found")
	ErrConflict     = errors.New("conflict")
	ErrUnauthorized = errors.New("unauthorized")
	ErrRevoked      = errors.New("revoked")
)

// invalid maps validator errors to service errors.
func invalid(err error) error {
	if errors.Is(err, records.ErrRevoked) {
		return fmt.Errorf("%w: %v", ErrRevoked, err)
	}
	return fmt.Errorf("%w: %v", ErrInvalid, err)
}
```

- [ ] **Step 2: `service.go`**
```go
package service

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"errors"
	"fmt"
	"time"

	"google.golang.org/protobuf/proto"
	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/records"
	"ottermsg/server/internal/store"
)

const (
	LowPrekeys    = 10
	MaxClockSkew  = 5 * time.Minute
)

// Notifier is implemented by the gateway.
type Notifier interface {
	Envelope(user []byte, device uint32)
	Directory()
	PrekeysLow(user []byte, device uint32, remaining int)
}

type nopNotifier struct{}

func (nopNotifier) Envelope([]byte, uint32)        {}
func (nopNotifier) Directory()                     {}
func (nopNotifier) PrekeysLow([]byte, uint32, int) {}

type Service struct {
	Store      *store.Store
	NodeID     []byte
	NetworkPub ed25519.PublicKey
	Notify     Notifier
	Now        func() time.Time
}

func New(st *store.Store, nodeID []byte, networkPub ed25519.PublicKey) *Service {
	return &Service{Store: st, NodeID: nodeID, NetworkPub: networkPub, Notify: nopNotifier{}, Now: time.Now}
}

type overlay struct {
	base records.UserResolver
	id   []byte
	key  records.UserKey
}

func (o overlay) UserKey(id []byte) (records.UserKey, bool) {
	if o.id != nil && bytes.Equal(id, o.id) {
		return o.key, true
	}
	return o.base.UserKey(id)
}

func (s *Service) validator(res records.UserResolver) *records.Validator {
	if res == nil {
		res = s.Store
	}
	return &records.Validator{NetworkPub: s.NetworkPub, Users: res, Now: s.Now}
}

func (s *Service) networkID() []byte { return keys.ID16(s.NetworkPub) }

func (s *Service) inviterAllowed(ctx context.Context, inviter []byte) error {
	if bytes.Equal(inviter, s.networkID()) {
		return nil
	}
	u, err := s.Store.UserByID(ctx, inviter)
	if err != nil {
		return err
	}
	switch {
	case u == nil:
		return fmt.Errorf("%w: unknown inviter", ErrUnauthorized)
	case u.Revoked:
		return fmt.Errorf("%w: inviter revoked", ErrRevoked)
	case !u.CanInvite:
		return fmt.Errorf("%w: inviter may not invite", ErrUnauthorized)
	}
	return nil
}

func (s *Service) VerifyLogin(ctx context.Context, nonce []byte, req *pb.LoginRequest) error {
	if req.DeviceId != 1 {
		return fmt.Errorf("%w: device %d", ErrInvalid, req.DeviceId)
	}
	skew := s.Now().Sub(time.UnixMilli(req.TsMs))
	if skew > MaxClockSkew || skew < -MaxClockSkew {
		return fmt.Errorf("%w: clock skew %v", ErrUnauthorized, skew)
	}
	u, err := s.Store.UserByID(ctx, req.UserId)
	if err != nil {
		return err
	}
	if u == nil {
		return fmt.Errorf("%w: unknown user", ErrUnauthorized)
	}
	if u.Revoked {
		return ErrRevoked
	}
	if !ed25519.Verify(u.AccountPub, keys.AuthMessage(s.NodeID, nonce, req.TsMs), req.Signature) {
		return fmt.Errorf("%w: bad signature", ErrUnauthorized)
	}
	return nil
}

func (s *Service) Directory(ctx context.Context) ([]*pb.Record, error) {
	raws, err := s.Store.DirectoryEntries(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]*pb.Record, 0, len(raws))
	for _, raw := range raws {
		r := &pb.Record{}
		if err := proto.Unmarshal(raw, r); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, nil
}

func (s *Service) Manifest(ctx context.Context) (*pb.Record, uint64, error) {
	v, raw, err := s.Store.LatestManifest(ctx)
	if errors.Is(err, store.ErrNotFound) {
		return nil, 0, fmt.Errorf("%w: no manifest", ErrNotFound)
	}
	if err != nil {
		return nil, 0, err
	}
	r := &pb.Record{}
	return r, v, proto.Unmarshal(raw, r)
}

func (s *Service) Mailbox(ctx context.Context, user []byte, device uint32, limit int) ([]store.MailboxEntry, error) {
	return s.Store.Mailbox(ctx, user, device, limit)
}

func (s *Service) FetchPrekeys(ctx context.Context, req *pb.PreKeyFetchRequest) (*pb.PreKeyBundle, error) {
	dev := req.DeviceId
	if dev == 0 {
		dev = 1
	}
	u, err := s.Store.UserByID(ctx, req.UserId)
	if err != nil {
		return nil, err
	}
	if u == nil || u.Revoked {
		return nil, fmt.Errorf("%w: user", ErrNotFound)
	}
	rows, err := s.Store.TakePrekeys(ctx, req.UserId, dev, s.NodeID)
	if errors.Is(err, store.ErrNotFound) {
		return nil, fmt.Errorf("%w: prekeys", ErrNotFound)
	}
	if err != nil {
		return nil, err
	}
	var rec pb.Record
	var body pb.RecordBody
	var entry pb.DirectoryEntry
	if err := proto.Unmarshal(u.EntryRaw, &rec); err != nil {
		return nil, err
	}
	if err := proto.Unmarshal(rec.Body, &body); err != nil {
		return nil, err
	}
	if err := proto.Unmarshal(body.Payload, &entry); err != nil {
		return nil, err
	}
	if rows.RemainingOwn < LowPrekeys {
		s.Notify.PrekeysLow(req.UserId, dev, rows.RemainingOwn)
	}
	return &pb.PreKeyBundle{UserId: req.UserId, DeviceId: dev, RegistrationId: rows.RegistrationID,
		IdentityPub: entry.IdentityPub, SignedPrekey: rows.Signed, KyberPrekey: rows.Kyber, OneTime: rows.OneTime}, nil
}

// ImportRecord validates and applies a record from a trusted local file (manifest, bootstrap invite).
func (s *Service) ImportRecord(ctx context.Context, rec *pb.Record) (bool, error) {
	body, err := s.validator(nil).Validate(rec)
	if err != nil {
		return false, invalid(err)
	}
	_, applied, err := s.Store.ApplyFrom(ctx, rec, body, s.NodeID)
	return applied, err
}
```

- [ ] **Step 3: `register.go`**
```go
package service

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"

	"google.golang.org/protobuf/proto"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/records"
	"ottermsg/server/internal/store"
)

// Register creates an account from an invite. Returns the new user_id.
func (s *Service) Register(ctx context.Context, req *pb.RegisterRequest) ([]byte, error) {
	if len(req.InviteSecret) != 32 || req.DirectoryEntry == nil || req.Prekeys == nil || req.InviteUsed == nil {
		return nil, fmt.Errorf("%w: incomplete registration", ErrInvalid)
	}
	sum := sha256.Sum256(req.InviteSecret)
	inviteID := sum[:]
	inv, err := s.Store.Invite(ctx, inviteID)
	if errors.Is(err, store.ErrNotFound) {
		return nil, fmt.Errorf("%w: unknown invite", ErrNotFound)
	}
	if err != nil {
		return nil, err
	}
	if inv.UsedBy != nil {
		return nil, fmt.Errorf("%w: invite already used", ErrConflict)
	}
	if inv.ExpiresMs < s.Now().UnixMilli() {
		return nil, fmt.Errorf("%w: invite expired", ErrConflict)
	}
	if err := s.inviterAllowed(ctx, inv.Inviter); err != nil {
		return nil, err
	}

	dirBody, err := s.validator(nil).Validate(req.DirectoryEntry)
	if err != nil {
		return nil, invalid(err)
	}
	if dirBody.Type != pb.RecordType_DIRECTORY_ENTRY {
		return nil, fmt.Errorf("%w: directory_entry has type %v", ErrInvalid, dirBody.Type)
	}
	var e pb.DirectoryEntry
	if err := proto.Unmarshal(dirBody.Payload, &e); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalid, err)
	}
	if u, err := s.Store.UserByID(ctx, e.UserId); err != nil {
		return nil, err
	} else if u != nil {
		return nil, fmt.Errorf("%w: already registered", ErrConflict)
	}
	if owner, err := s.Store.UsernameOwner(ctx, e.Username); err != nil {
		return nil, err
	} else if owner != nil {
		return nil, fmt.Errorf("%w: username taken", ErrConflict)
	}

	ov := s.validator(overlay{base: s.Store, id: e.UserId, key: records.UserKey{Pub: e.AccountPub}})
	pkBody, err := ov.Validate(req.Prekeys)
	if err != nil {
		return nil, invalid(err)
	}
	var pk pb.PreKeys
	_ = proto.Unmarshal(pkBody.Payload, &pk)
	if pkBody.Type != pb.RecordType_PREKEYS || !bytes.Equal(pkBody.Author, e.UserId) || pk.SignedPrekey == nil || pk.KyberPrekey == nil {
		return nil, fmt.Errorf("%w: prekeys", ErrInvalid)
	}
	usedBody, err := ov.Validate(req.InviteUsed)
	if err != nil {
		return nil, invalid(err)
	}
	var used pb.InviteUsed
	_ = proto.Unmarshal(usedBody.Payload, &used)
	if usedBody.Type != pb.RecordType_INVITE_USED || !bytes.Equal(used.InviteId, inviteID) {
		return nil, fmt.Errorf("%w: invite_used", ErrInvalid)
	}

	_, err = s.Store.ApplyAll(ctx, s.NodeID, []store.Item{
		{Record: req.DirectoryEntry, Body: dirBody},
		{Record: req.Prekeys, Body: pkBody},
		{Record: req.InviteUsed, Body: usedBody},
	})
	switch {
	case errors.Is(err, store.ErrUsernameTaken):
		return nil, fmt.Errorf("%w: username taken", ErrConflict)
	case errors.Is(err, store.ErrInviteUnavailable):
		return nil, fmt.Errorf("%w: invite already used", ErrConflict)
	case err != nil:
		return nil, err
	}
	s.Notify.Directory()
	return e.UserId, nil
}
```

- [ ] **Step 4: `submit.go`**
```go
package service

import (
	"bytes"
	"context"
	"fmt"
	"slices"

	"google.golang.org/protobuf/proto"
	pb "ottermsg/server/internal/proto/otterv1"
)

// Submit validates and applies a client-authored record of one of the allowed types.
func (s *Service) Submit(ctx context.Context, user []byte, rec *pb.Record, allowed ...pb.RecordType) (*pb.RecordBody, error) {
	body, err := s.validator(nil).Validate(rec)
	if err != nil {
		return nil, invalid(err)
	}
	if !bytes.Equal(body.Author, user) {
		return nil, fmt.Errorf("%w: author is not the logged-in user", ErrUnauthorized)
	}
	if !slices.Contains(allowed, body.Type) {
		return nil, fmt.Errorf("%w: record type %v not allowed here", ErrInvalid, body.Type)
	}
	var env *pb.Envelope
	switch body.Type {
	case pb.RecordType_ENVELOPE:
		env = &pb.Envelope{}
		if err := proto.Unmarshal(body.Payload, env); err != nil {
			return nil, fmt.Errorf("%w: %v", ErrInvalid, err)
		}
		for _, r := range env.Recipients {
			u, err := s.Store.UserByID(ctx, r.User)
			if err != nil {
				return nil, err
			}
			if u == nil || u.Revoked {
				return nil, fmt.Errorf("%w: recipient %x", ErrNotFound, r.User)
			}
		}
	case pb.RecordType_INVITE:
		if err := s.inviterAllowed(ctx, user); err != nil {
			return nil, err
		}
	}
	_, applied, err := s.Store.ApplyFrom(ctx, rec, body, s.NodeID)
	if err != nil {
		return nil, err
	}
	if applied && env != nil {
		for _, r := range env.Recipients {
			s.Notify.Envelope(r.User, r.Device)
		}
	}
	return body, nil
}
```

- [ ] **Step 5: Tests `service_test.go`** — a fixture with a network key, a store in `t.TempDir()`,
a recording notifier and helper builders; table-free sequential tests:
```go
package service

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"
	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/records"
	"ottermsg/server/internal/store"
)

type rec struct {
	env, dir int
	low      []int
}

func (r *rec) Envelope([]byte, uint32)          { r.env++ }
func (r *rec) Directory()                       { r.dir++ }
func (r *rec) PrekeysLow(_ []byte, _ uint32, n int) { r.low = append(r.low, n) }

type fx struct {
	t       *testing.T
	svc     *Service
	netPriv ed25519.PrivateKey
	notes   *rec
}

func newFx(t *testing.T) *fx {
	st, err := store.Open(filepath.Join(t.TempDir(), "n.db"))
	if err != nil { t.Fatal(err) }
	t.Cleanup(func() { st.Close() })
	pub, priv, _ := ed25519.GenerateKey(nil)
	s := New(st, []byte("node-node-node-1"), pub)
	n := &rec{}
	s.Notify = n
	return &fx{t: t, svc: s, netPriv: priv, notes: n}
}

func r16() []byte { b := make([]byte, 16); rand.Read(b); return b }

func sign(t *testing.T, typ pb.RecordType, author []byte, payload proto.Message, k ed25519.PrivateKey) *pb.Record {
	p, _ := proto.Marshal(payload)
	r, err := records.Sign(&pb.RecordBody{Id: r16(), Type: typ, Author: author, CreatedMs: time.Now().UnixMilli(), Payload: p}, k)
	if err != nil { t.Fatal(err) }
	return r
}

type user struct {
	id   []byte
	priv ed25519.PrivateKey
}

// invite publishes an invite signed by the network (inviter == nil) or by a user; returns the secret.
func (f *fx) invite(inviter *user, ttl time.Duration) []byte {
	secret := make([]byte, 32); rand.Read(secret)
	id := sha256.Sum256(secret)
	inv := &pb.Invite{InviteId: id[:], ExpiresMs: time.Now().Add(ttl).UnixMilli()}
	if inviter == nil {
		if _, err := f.svc.ImportRecord(context.Background(), sign(f.t, pb.RecordType_INVITE, keys.ID16(f.svc.NetworkPub), inv, f.netPriv)); err != nil { f.t.Fatal(err) }
	} else {
		if _, err := f.svc.Submit(context.Background(), inviter.id, sign(f.t, pb.RecordType_INVITE, inviter.id, inv, inviter.priv), pb.RecordType_INVITE); err != nil { f.t.Fatal(err) }
	}
	return secret
}

func (f *fx) registerReq(secret []byte, username string) (*user, *pb.RegisterRequest) {
	pub, priv, _ := ed25519.GenerateKey(nil)
	id := keys.ID16(pub)
	u := &user{id: id, priv: priv}
	entry := &pb.DirectoryEntry{UserId: id, Username: username, DisplayName: username, AccountPub: pub,
		IdentityPub: make([]byte, 33), IdentitySig: make([]byte, 64), Version: 1, CanInvite: true}
	pk := &pb.PreKeys{DeviceId: 1, RegistrationId: 5,
		SignedPrekey: &pb.SignedPreKey{Id: 1, PublicKey: make([]byte, 33), Signature: make([]byte, 64)},
		KyberPrekey:  &pb.SignedPreKey{Id: 1, PublicKey: make([]byte, 1569), Signature: make([]byte, 64)}}
	for i := 0; i < 12; i++ {
		pk.OneTime = append(pk.OneTime, &pb.OneTimePreKey{Id: uint32(100 + i), PublicKey: make([]byte, 33), OwnerNode: f.svc.NodeID})
	}
	sum := sha256.Sum256(secret)
	return u, &pb.RegisterRequest{InviteSecret: secret,
		DirectoryEntry: sign(f.t, pb.RecordType_DIRECTORY_ENTRY, id, entry, priv),
		Prekeys:        sign(f.t, pb.RecordType_PREKEYS, id, pk, priv),
		InviteUsed:     sign(f.t, pb.RecordType_INVITE_USED, id, &pb.InviteUsed{InviteId: sum[:], UserId: id}, priv)}
}

func (f *fx) mustRegister(secret []byte, name string) *user {
	u, req := f.registerReq(secret, name)
	if _, err := f.svc.Register(context.Background(), req); err != nil { f.t.Fatal(err) }
	return u
}

func TestRegisterFlow(t *testing.T) {
	f := newFx(t)
	ctx := context.Background()
	anna := f.mustRegister(f.invite(nil, time.Hour), "anna")
	if f.notes.dir != 1 { t.Fatal("directory notification") }

	secret := f.invite(anna, time.Hour)
	f.mustRegister(secret, "boris")
	_, again := f.registerReq(secret, "vera")
	if _, err := f.svc.Register(ctx, again); !errors.Is(err, ErrConflict) { t.Fatalf("reused invite: %v", err) }

	_, taken := f.registerReq(f.invite(anna, time.Hour), "anna")
	if _, err := f.svc.Register(ctx, taken); !errors.Is(err, ErrConflict) { t.Fatalf("taken username: %v", err) }

	_, unknown := f.registerReq(make([]byte, 32), "gleb")
	if _, err := f.svc.Register(ctx, unknown); !errors.Is(err, ErrNotFound) { t.Fatalf("unknown invite: %v", err) }

	_, expired := f.registerReq(f.invite(anna, -time.Minute+time.Second), "dina")
	f.svc.Now = func() time.Time { return time.Now().Add(time.Hour) }
	if _, err := f.svc.Register(ctx, expired); err == nil { t.Fatal("expired invite accepted") }
	f.svc.Now = time.Now

	_, bad := f.registerReq(f.invite(anna, time.Hour), "egor")
	bad.Prekeys.Signature[0] ^= 1
	if _, err := f.svc.Register(ctx, bad); !errors.Is(err, ErrInvalid) { t.Fatalf("bad prekeys sig: %v", err) }

	dir, _ := f.svc.Directory(ctx)
	if len(dir) != 2 { t.Fatalf("directory has %d entries", len(dir)) }
}

func TestLogin(t *testing.T) {
	f := newFx(t)
	ctx := context.Background()
	u := f.mustRegister(f.invite(nil, time.Hour), "anna")
	nonce := make([]byte, 32); rand.Read(nonce)
	ts := time.Now().UnixMilli()
	good := &pb.LoginRequest{UserId: u.id, DeviceId: 1, TsMs: ts, Signature: ed25519.Sign(u.priv, keys.AuthMessage(f.svc.NodeID, nonce, ts))}
	if err := f.svc.VerifyLogin(ctx, nonce, good); err != nil { t.Fatal(err) }
	other := make([]byte, 32)
	if err := f.svc.VerifyLogin(ctx, other, good); !errors.Is(err, ErrUnauthorized) { t.Fatalf("wrong nonce: %v", err) }
	old := time.Now().Add(-10 * time.Minute).UnixMilli()
	stale := &pb.LoginRequest{UserId: u.id, DeviceId: 1, TsMs: old, Signature: ed25519.Sign(u.priv, keys.AuthMessage(f.svc.NodeID, nonce, old))}
	if err := f.svc.VerifyLogin(ctx, nonce, stale); !errors.Is(err, ErrUnauthorized) { t.Fatalf("stale: %v", err) }
	if err := f.svc.VerifyLogin(ctx, nonce, &pb.LoginRequest{UserId: r16(), DeviceId: 1, TsMs: ts}); !errors.Is(err, ErrUnauthorized) { t.Fatal("unknown user") }
}

func TestSubmitAndPrekeys(t *testing.T) {
	f := newFx(t)
	ctx := context.Background()
	a := f.mustRegister(f.invite(nil, time.Hour), "anna")
	b := f.mustRegister(f.invite(a, time.Hour), "boris")

	env := &pb.Envelope{SenderUser: b.id, SenderDevice: 1, Kind: pb.Envelope_PREKEY_SIGNAL, Urgent: true,
		Recipients: []*pb.Recipient{{User: a.id, Device: 1, Content: []byte("ct")}}}
	r := sign(t, pb.RecordType_ENVELOPE, b.id, env, b.priv)
	if _, err := f.svc.Submit(ctx, a.id, r, pb.RecordType_ENVELOPE); !errors.Is(err, ErrUnauthorized) { t.Fatalf("foreign author: %v", err) }
	if _, err := f.svc.Submit(ctx, b.id, r, pb.RecordType_ACK); !errors.Is(err, ErrInvalid) { t.Fatalf("wrong type: %v", err) }
	if _, err := f.svc.Submit(ctx, b.id, r, pb.RecordType_ENVELOPE); err != nil { t.Fatal(err) }
	if _, err := f.svc.Submit(ctx, b.id, r, pb.RecordType_ENVELOPE); err != nil { t.Fatal("resend must be idempotent") }
	if f.notes.env != 1 { t.Fatalf("envelope notifications %d", f.notes.env) }
	box, _ := f.svc.Mailbox(ctx, a.id, 1, 10)
	if len(box) != 1 { t.Fatalf("mailbox %d", len(box)) }

	ghost := &pb.Envelope{SenderUser: b.id, SenderDevice: 1, Kind: pb.Envelope_SIGNAL,
		Recipients: []*pb.Recipient{{User: r16(), Device: 1, Content: []byte("x")}}}
	if _, err := f.svc.Submit(ctx, b.id, sign(t, pb.RecordType_ENVELOPE, b.id, ghost, b.priv), pb.RecordType_ENVELOPE); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown recipient: %v", err)
	}

	bundle, err := f.svc.FetchPrekeys(ctx, &pb.PreKeyFetchRequest{UserId: a.id, DeviceId: 1})
	if err != nil || bundle.OneTime == nil || bundle.RegistrationId != 5 || len(bundle.IdentityPub) != 33 { t.Fatalf("%v %v", bundle, err) }
	for i := 0; i < 12; i++ { f.svc.FetchPrekeys(ctx, &pb.PreKeyFetchRequest{UserId: a.id, DeviceId: 1}) }
	last, _ := f.svc.FetchPrekeys(ctx, &pb.PreKeyFetchRequest{UserId: a.id, DeviceId: 1})
	if last.OneTime != nil { t.Fatal("one-time keys should be exhausted") }
	if len(f.notes.low) == 0 { t.Fatal("prekeys_low not signalled") }
}
```
(`pb.Envelope_PREKEY_SIGNAL` / `Urgent` names follow protoc-gen-go conventions for the Task 1 protos.)

- [ ] **Step 6: Run** `go test ./internal/service/ -v` → PASS.
- [ ] **Step 7: Commit** `git add -A && git commit -m "feat(service): registration, login, submit, prekeys, directory"`

---

### Task 5: Gateway (WebSocket sessions) + WSS transport + end-to-end test

**Goal:** Clients speak the `Frame` protocol over WebSocket; mailbox entries are pushed to logged-in sessions.

**Files:**
- Create: `internal/gateway/gateway.go`, `session.go`, `methods.go`
- Create: `internal/transport/wss/server.go`
- Test: `internal/gateway/testclient_test.go`, `internal/gateway/e2e_test.go`, `internal/transport/wss/server_test.go`

**Acceptance Criteria:**
- [ ] On connect the node sends `Event{hello}` (protocol 1, node_id, 32-byte nonce, manifest version, server time)
- [ ] Only `ping`, `manifest.get`, `register`, `auth.login` work before login (others → `STATUS_UNAUTHORIZED`); a second login → `STATUS_INVALID`
- [ ] Methods: `register`, `auth.login`, `manifest.get`, `directory.sync`, `prekeys.upload`, `prekeys.fetch`, `msg.send`, `msg.ack`, `invite.create`, `ping` — errors mapped to `Status` + message
- [ ] After login and whenever a new envelope arrives for that user, the session pushes `Event{envelopes, RecordBatch}` (≤100 per event) containing only entries not yet pushed **in this session**; unacked entries are pushed again after reconnect
- [ ] `Event{directory}` broadcast after a registration; `Event{prekeys_low}` to the affected user's sessions
- [ ] Frames > 1 MiB rejected (connection closed)
- [ ] WSS server routes only the secret path to the gateway; any other path → static site dir or 404; TLS used when cert+key configured
- [ ] E2E test (real WebSocket, in-process node) covers: bootstrap register; invite + second register; unauthenticated call rejected; fetch prekeys; send; recipient receives on login; ack removes; reconnect without ack redelivers; directory event; prekeys_low event

**Verify:** `go test -race ./internal/gateway/ ./internal/transport/... -v` → PASS

**Steps:**

- [ ] **Step 1: Dependency** `go get github.com/coder/websocket@v1.8.15`

- [ ] **Step 2: `gateway.go`**
```go
// Package gateway serves the client protocol (docs/02 §4) over WebSocket.
package gateway

import (
	"context"
	"crypto/rand"
	"errors"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/service"
)

const (
	ProtocolVersion = 1
	maxFrame        = 1 << 20
	deliverBatch    = 100
	writeTimeout    = 10 * time.Second
)

type Gateway struct {
	svc      *service.Service
	log      *slog.Logger
	mu       sync.Mutex
	sessions map[*session]struct{}
}

func New(svc *service.Service, log *slog.Logger) *Gateway {
	g := &Gateway{svc: svc, log: log, sessions: map[*session]struct{}{}}
	svc.Notify = g
	return g
}

func (g *Gateway) snapshot() []*session {
	g.mu.Lock()
	defer g.mu.Unlock()
	out := make([]*session, 0, len(g.sessions))
	for s := range g.sessions {
		out = append(out, s)
	}
	return out
}

func (g *Gateway) add(s *session)    { g.mu.Lock(); g.sessions[s] = struct{}{}; g.mu.Unlock() }
func (g *Gateway) remove(s *session) { g.mu.Lock(); delete(g.sessions, s); g.mu.Unlock() }

// Envelope implements service.Notifier.
func (g *Gateway) Envelope(user []byte, device uint32) {
	for _, s := range g.snapshot() {
		if s.is(user, device) {
			s.kick()
		}
	}
}

func (g *Gateway) Directory() {
	for _, s := range g.snapshot() {
		if s.loggedIn() {
			s.event("directory", &pb.Empty{})
		}
	}
}

func (g *Gateway) PrekeysLow(user []byte, device uint32, remaining int) {
	for _, s := range g.snapshot() {
		if s.is(user, device) {
			s.event("prekeys_low", &pb.PrekeysLow{Remaining: uint32(remaining)})
		}
	}
}

func (g *Gateway) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true}) // native clients send no Origin
	if err != nil {
		return
	}
	c.SetReadLimit(maxFrame)
	ctx, cancel := context.WithCancel(r.Context())
	nonce := make([]byte, 32)
	rand.Read(nonce)
	s := &session{g: g, conn: c, out: make(chan *pb.Frame, 64), wake: make(chan struct{}, 1), nonce: nonce, ctx: ctx, cancel: cancel}
	defer func() {
		cancel()
		g.remove(s)
		c.CloseNow()
	}()
	go s.writeLoop()

	var mv uint64
	if _, v, err := g.svc.Manifest(ctx); err == nil {
		mv = v
	}
	s.event("hello", &pb.Hello{ProtocolVersion: ProtocolVersion, NodeId: g.svc.NodeID, Nonce: nonce,
		ManifestVersion: mv, ServerTimeMs: time.Now().UnixMilli()})

	for {
		typ, data, err := c.Read(ctx)
		if err != nil {
			if !errors.Is(err, context.Canceled) && websocket.CloseStatus(err) == -1 {
				g.log.Debug("session read ended", "err", err)
			}
			return
		}
		if typ != websocket.MessageBinary {
			continue
		}
		var f pb.Frame
		if err := proto.Unmarshal(data, &f); err != nil {
			c.Close(websocket.StatusUnsupportedData, "bad frame")
			return
		}
		if req := f.GetRequest(); req != nil {
			s.handle(ctx, req)
		}
	}
}
```

- [ ] **Step 3: `session.go`**
```go
package gateway

import (
	"bytes"
	"context"
	"sync"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"
	pb "ottermsg/server/internal/proto/otterv1"
)

type session struct {
	g      *Gateway
	conn   *websocket.Conn
	out    chan *pb.Frame
	wake   chan struct{}
	nonce  []byte
	ctx    context.Context
	cancel context.CancelFunc

	mu     sync.Mutex
	user   []byte
	device uint32
}

func (s *session) loggedIn() bool { s.mu.Lock(); defer s.mu.Unlock(); return s.user != nil }

func (s *session) is(user []byte, device uint32) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.user != nil && s.device == device && bytes.Equal(s.user, user)
}

func (s *session) kick() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

func (s *session) send(f *pb.Frame) {
	select {
	case s.out <- f:
	case <-s.ctx.Done():
	}
}

func (s *session) event(typ string, body proto.Message) {
	b, _ := proto.Marshal(body)
	s.send(&pb.Frame{Kind: &pb.Frame_Event{Event: &pb.Event{Type: typ, Body: b}}})
}

func (s *session) writeLoop() {
	for {
		select {
		case f := <-s.out:
			b, err := proto.Marshal(f)
			if err != nil {
				continue
			}
			ctx, cancel := context.WithTimeout(s.ctx, writeTimeout)
			err = s.conn.Write(ctx, websocket.MessageBinary, b)
			cancel()
			if err != nil {
				s.cancel()
				return
			}
		case <-s.ctx.Done():
			return
		}
	}
}

// deliverLoop pushes mailbox entries not yet pushed in this session.
func (s *session) deliverLoop() {
	sent := map[string]bool{}
	for {
		select {
		case <-s.wake:
		case <-s.ctx.Done():
			return
		}
		for {
			entries, err := s.g.svc.Mailbox(s.ctx, s.user, s.device, 1000)
			if err != nil {
				s.g.log.Warn("mailbox", "err", err)
				break
			}
			next := make(map[string]bool, len(entries))
			batch := &pb.RecordBatch{}
			for _, e := range entries {
				k := string(e.Key)
				next[k] = true
				if sent[k] || len(batch.Records) >= deliverBatch {
					continue
				}
				r := &pb.Record{}
				if proto.Unmarshal(e.Raw, r) == nil {
					batch.Records = append(batch.Records, r)
				}
				sent[k] = true
			}
			for k := range sent {
				if !next[k] {
					delete(sent, k) // acknowledged meanwhile
				}
			}
			if len(batch.Records) == 0 {
				break
			}
			s.event("envelopes", batch)
			if len(batch.Records) < deliverBatch {
				break
			}
		}
	}
}
```
(`next[k]=true` must be set before the `continue`, as written, so the prune step keeps unsent-but-pending keys out of `sent`.)

- [ ] **Step 4: `methods.go`**
```go
package gateway

import (
	"context"
	"errors"
	"fmt"

	"google.golang.org/protobuf/proto"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/service"
)

var public = map[string]bool{"ping": true, "manifest.get": true, "register": true, "auth.login": true}

func status(err error) pb.Status {
	switch {
	case errors.Is(err, service.ErrInvalid):
		return pb.Status_STATUS_INVALID
	case errors.Is(err, service.ErrNotFound):
		return pb.Status_STATUS_NOT_FOUND
	case errors.Is(err, service.ErrConflict):
		return pb.Status_STATUS_CONFLICT
	case errors.Is(err, service.ErrUnauthorized):
		return pb.Status_STATUS_UNAUTHORIZED
	case errors.Is(err, service.ErrRevoked):
		return pb.Status_STATUS_REVOKED
	default:
		return pb.Status_STATUS_INTERNAL
	}
}

func (s *session) handle(ctx context.Context, req *pb.Request) {
	resp := &pb.Response{Id: req.Id}
	body, err := s.dispatch(ctx, req)
	if err != nil {
		resp.Status = status(err)
		resp.Error = err.Error()
		if resp.Status == pb.Status_STATUS_INTERNAL {
			s.g.log.Error("request failed", "method", req.Method, "err", err)
			resp.Error = "internal error"
		}
	} else if body != nil {
		resp.Body, _ = proto.Marshal(body)
	}
	s.send(&pb.Frame{Kind: &pb.Frame_Response{Response: resp}})
}

func decode(b []byte, m proto.Message) error {
	if err := proto.Unmarshal(b, m); err != nil {
		return fmt.Errorf("%w: %v", service.ErrInvalid, err)
	}
	return nil
}

func (s *session) dispatch(ctx context.Context, req *pb.Request) (proto.Message, error) {
	if !public[req.Method] && !s.loggedIn() {
		return nil, fmt.Errorf("%w: login required", service.ErrUnauthorized)
	}
	svc := s.g.svc
	switch req.Method {
	case "ping":
		return &pb.Empty{}, nil
	case "manifest.get":
		rec, _, err := svc.Manifest(ctx)
		if err != nil {
			return nil, err
		}
		return &pb.ManifestResponse{Manifest: rec}, nil
	case "register":
		var r pb.RegisterRequest
		if err := decode(req.Body, &r); err != nil {
			return nil, err
		}
		_, err := svc.Register(ctx, &r)
		return &pb.Empty{}, err
	case "auth.login":
		if s.loggedIn() {
			return nil, fmt.Errorf("%w: already logged in", service.ErrInvalid)
		}
		var r pb.LoginRequest
		if err := decode(req.Body, &r); err != nil {
			return nil, err
		}
		if err := svc.VerifyLogin(ctx, s.nonce, &r); err != nil {
			return nil, err
		}
		s.mu.Lock()
		s.user, s.device = r.UserId, r.DeviceId
		s.mu.Unlock()
		s.g.add(s)
		go s.deliverLoop()
		s.kick()
		return &pb.Empty{}, nil
	case "directory.sync":
		recs, err := svc.Directory(ctx)
		if err != nil {
			return nil, err
		}
		return &pb.RecordBatch{Records: recs}, nil
	case "prekeys.fetch":
		var r pb.PreKeyFetchRequest
		if err := decode(req.Body, &r); err != nil {
			return nil, err
		}
		return svc.FetchPrekeys(ctx, &r)
	case "prekeys.upload", "msg.send", "msg.ack", "invite.create":
		var r pb.RecordRequest
		if err := decode(req.Body, &r); err != nil {
			return nil, err
		}
		if r.Record == nil {
			return nil, fmt.Errorf("%w: record missing", service.ErrInvalid)
		}
		allowed := map[string]pb.RecordType{"prekeys.upload": pb.RecordType_PREKEYS, "msg.send": pb.RecordType_ENVELOPE,
			"msg.ack": pb.RecordType_ACK, "invite.create": pb.RecordType_INVITE}[req.Method]
		_, err := svc.Submit(ctx, s.user, r.Record, allowed)
		return &pb.Empty{}, err
	default:
		return nil, fmt.Errorf("%w: unknown method %q", service.ErrInvalid, req.Method)
	}
}
```
Note: `s.user` is read without the lock in `dispatch` after login; it never changes once set, and is set before
`deliverLoop` starts, so this is race-free (`-race` will confirm).

- [ ] **Step 5: `internal/transport/wss/server.go`**
```go
// Package wss serves the client WebSocket on a secret path, everything else as a plain website.
package wss

import (
	"net/http"
	"time"
)

type Config struct {
	Listen  string
	Path    string
	TLSCert string
	TLSKey  string
	SiteDir string
}

func NewServer(cfg Config, ws http.Handler) *http.Server {
	mux := http.NewServeMux()
	mux.Handle(cfg.Path, ws)
	var site http.Handler = http.NotFoundHandler()
	if cfg.SiteDir != "" {
		site = http.FileServer(http.Dir(cfg.SiteDir))
	}
	mux.Handle("/", site)
	return &http.Server{Addr: cfg.Listen, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
}

func Serve(srv *http.Server, cfg Config) error {
	if cfg.TLSCert != "" {
		return srv.ListenAndServeTLS(cfg.TLSCert, cfg.TLSKey)
	}
	return srv.ListenAndServe()
}
```
`server_test.go`:
```go
package wss

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestRouting(t *testing.T) {
	ws := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(299) })
	srv := httptest.NewServer(NewServer(Config{Path: "/s3cretPath"}, ws).Handler)
	defer srv.Close()
	for path, want := range map[string]int{"/s3cretPath": 299, "/": 404, "/s3cretPath/x": 404, "/other": 404} {
		resp, err := http.Get(srv.URL + path)
		if err != nil { t.Fatal(err) }
		resp.Body.Close()
		if resp.StatusCode != want { t.Errorf("%s: %d, want %d", path, resp.StatusCode, want) }
	}
}
```

- [ ] **Step 6: Test client `testclient_test.go`**
```go
package gateway

import (
	"context"
	"crypto/ed25519"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"log/slog"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/service"
	"ottermsg/server/internal/store"
)

type node struct {
	url     string
	svc     *service.Service
	netPriv ed25519.PrivateKey
}

func startNode(t *testing.T) *node {
	st, err := store.Open(filepath.Join(t.TempDir(), "n.db"))
	if err != nil { t.Fatal(err) }
	pub, priv, _ := ed25519.GenerateKey(nil)
	svc := service.New(st, []byte("node-node-node-1"), pub)
	gw := New(svc, slog.New(slog.DiscardHandler))
	srv := httptest.NewServer(gw)
	t.Cleanup(func() { srv.Close(); st.Close() })
	return &node{url: "ws" + strings.TrimPrefix(srv.URL, "http"), svc: svc, netPriv: priv}
}

type client struct {
	t      *testing.T
	c      *websocket.Conn
	next   atomic.Uint64
	resps  chan *pb.Response
	events chan *pb.Event
	hello  *pb.Hello
}

func dial(t *testing.T, n *node) *client {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, _, err := websocket.Dial(ctx, n.url, nil)
	if err != nil { t.Fatal(err) }
	c.SetReadLimit(maxFrame)
	cl := &client{t: t, c: c, resps: make(chan *pb.Response, 16), events: make(chan *pb.Event, 64)}
	go func() {
		for {
			_, data, err := c.Read(context.Background())
			if err != nil { close(cl.events); return }
			var f pb.Frame
			proto.Unmarshal(data, &f)
			if r := f.GetResponse(); r != nil { cl.resps <- r }
			if e := f.GetEvent(); e != nil { cl.events <- e }
		}
	}()
	e := cl.nextEvent("hello")
	cl.hello = &pb.Hello{}
	proto.Unmarshal(e.Body, cl.hello)
	t.Cleanup(func() { c.CloseNow() })
	return cl
}

func (c *client) call(method string, req, resp proto.Message) (pb.Status, string) {
	c.t.Helper()
	b, _ := proto.Marshal(req)
	id := c.next.Add(1)
	f, _ := proto.Marshal(&pb.Frame{Kind: &pb.Frame_Request{Request: &pb.Request{Id: id, Method: method, Body: b}}})
	if err := c.c.Write(context.Background(), websocket.MessageBinary, f); err != nil { c.t.Fatal(err) }
	select {
	case r := <-c.resps:
		if r.Id != id { c.t.Fatalf("response id %d, want %d", r.Id, id) }
		if resp != nil && r.Status == pb.Status_STATUS_OK { proto.Unmarshal(r.Body, resp) }
		return r.Status, r.Error
	case <-time.After(5 * time.Second):
		c.t.Fatalf("%s: timeout", method)
	}
	return 0, ""
}

func (c *client) nextEvent(typ string) *pb.Event {
	c.t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case e, ok := <-c.events:
			if !ok { c.t.Fatalf("closed while waiting for %s", typ) }
			if e.Type == typ { return e }
		case <-deadline:
			c.t.Fatalf("timeout waiting for event %s", typ)
		}
	}
}

func (c *client) noEvent(typ string, d time.Duration) {
	c.t.Helper()
	deadline := time.After(d)
	for {
		select {
		case e := <-c.events:
			if e.Type == typ { c.t.Fatalf("unexpected event %s", typ) }
		case <-deadline:
			return
		}
	}
}
```
Reuse record/user builders: copy `r16`, `sign`, `user`, invite/register helpers from Task 4's `service_test.go`
into `e2e_test.go` (test files can't import each other across packages), adapted to call through the client.

- [ ] **Step 7: `e2e_test.go`**
```go
package gateway

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"testing"
	"time"

	"context"

	"google.golang.org/protobuf/proto"
	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/records"
)

func r16() []byte { b := make([]byte, 16); rand.Read(b); return b }

func sign(t *testing.T, typ pb.RecordType, author []byte, payload proto.Message, k ed25519.PrivateKey) *pb.Record {
	p, _ := proto.Marshal(payload)
	r, err := records.Sign(&pb.RecordBody{Id: r16(), Type: typ, Author: author, CreatedMs: time.Now().UnixMilli(), Payload: p}, k)
	if err != nil { t.Fatal(err) }
	return r
}

type acct struct {
	id   []byte
	priv ed25519.PrivateKey
}

func registerReq(t *testing.T, n *node, secret []byte, name string) (*acct, *pb.RegisterRequest) {
	pub, priv, _ := ed25519.GenerateKey(nil)
	id := keys.ID16(pub)
	entry := &pb.DirectoryEntry{UserId: id, Username: name, DisplayName: name, AccountPub: pub,
		IdentityPub: make([]byte, 33), IdentitySig: make([]byte, 64), Version: 1, CanInvite: true}
	pk := &pb.PreKeys{DeviceId: 1, RegistrationId: 9,
		SignedPrekey: &pb.SignedPreKey{Id: 1, PublicKey: make([]byte, 33), Signature: make([]byte, 64)},
		KyberPrekey:  &pb.SignedPreKey{Id: 1, PublicKey: make([]byte, 1569), Signature: make([]byte, 64)}}
	for i := 0; i < 11; i++ {
		pk.OneTime = append(pk.OneTime, &pb.OneTimePreKey{Id: uint32(i + 1), PublicKey: make([]byte, 33), OwnerNode: n.svc.NodeID})
	}
	sum := sha256.Sum256(secret)
	return &acct{id, priv}, &pb.RegisterRequest{InviteSecret: secret,
		DirectoryEntry: sign(t, pb.RecordType_DIRECTORY_ENTRY, id, entry, priv),
		Prekeys:        sign(t, pb.RecordType_PREKEYS, id, pk, priv),
		InviteUsed:     sign(t, pb.RecordType_INVITE_USED, id, &pb.InviteUsed{InviteId: sum[:], UserId: id}, priv)}
}

func login(t *testing.T, c *client, a *acct) {
	ts := time.Now().UnixMilli()
	st, msg := c.call("auth.login", &pb.LoginRequest{UserId: a.id, DeviceId: 1, TsMs: ts,
		Signature: ed25519.Sign(a.priv, keys.AuthMessage(c.hello.NodeId, c.hello.Nonce, ts))}, nil)
	if st != pb.Status_STATUS_OK { t.Fatalf("login: %v %s", st, msg) }
}

func TestEndToEnd(t *testing.T) {
	n := startNode(t)
	ctx := context.Background()

	// bootstrap invite imported by the operator
	secret := make([]byte, 32); rand.Read(secret)
	sum := sha256.Sum256(secret)
	inv := sign(t, pb.RecordType_INVITE, keys.ID16(n.svc.NetworkPub), &pb.Invite{InviteId: sum[:], ExpiresMs: time.Now().Add(time.Hour).UnixMilli()}, n.netPriv)
	if _, err := n.svc.ImportRecord(ctx, inv); err != nil { t.Fatal(err) }

	ca := dial(t, n)
	if st, _ := ca.call("directory.sync", &pb.Empty{}, nil); st != pb.Status_STATUS_UNAUTHORIZED { t.Fatalf("pre-login call: %v", st) }
	anna, req := registerReq(t, n, secret, "anna")
	if st, msg := ca.call("register", req, nil); st != pb.Status_STATUS_OK { t.Fatalf("register: %v %s", st, msg) }
	login(t, ca, anna)
	if st, _ := ca.call("auth.login", &pb.LoginRequest{}, nil); st != pb.Status_STATUS_INVALID { t.Fatal("second login must fail") }

	// anna invites boris
	s2 := make([]byte, 32); rand.Read(s2)
	sum2 := sha256.Sum256(s2)
	invRec := sign(t, pb.RecordType_INVITE, anna.id, &pb.Invite{InviteId: sum2[:], ExpiresMs: time.Now().Add(time.Hour).UnixMilli()}, anna.priv)
	if st, msg := ca.call("invite.create", &pb.RecordRequest{Record: invRec}, nil); st != pb.Status_STATUS_OK { t.Fatalf("invite: %v %s", st, msg) }
	cb := dial(t, n)
	boris, req2 := registerReq(t, n, s2, "boris")
	if st, msg := cb.call("register", req2, nil); st != pb.Status_STATUS_OK { t.Fatalf("register boris: %v %s", st, msg) }
	ca.nextEvent("directory")
	login(t, cb, boris)

	var dir pb.RecordBatch
	cb.call("directory.sync", &pb.Empty{}, &dir)
	if len(dir.Records) != 2 { t.Fatalf("directory: %d", len(dir.Records)) }

	var bundle pb.PreKeyBundle
	if st, msg := cb.call("prekeys.fetch", &pb.PreKeyFetchRequest{UserId: anna.id, DeviceId: 1}, &bundle); st != pb.Status_STATUS_OK || bundle.OneTime == nil {
		t.Fatalf("prekeys: %v %s", st, msg)
	}
	// 11 uploaded: after one fetch 10 remain (not low); the second fetch leaves 9 -> prekeys_low
	cb.call("prekeys.fetch", &pb.PreKeyFetchRequest{UserId: anna.id, DeviceId: 1}, &bundle)
	ca.nextEvent("prekeys_low")

	// boris -> anna
	env := sign(t, pb.RecordType_ENVELOPE, boris.id, &pb.Envelope{SenderUser: boris.id, SenderDevice: 1, Kind: pb.Envelope_PREKEY_SIGNAL, Urgent: true,
		Recipients: []*pb.Recipient{{User: anna.id, Device: 1, Content: []byte("hello")}}}, boris.priv)
	if st, msg := cb.call("msg.send", &pb.RecordRequest{Record: env}, nil); st != pb.Status_STATUS_OK { t.Fatalf("send: %v %s", st, msg) }
	var batch pb.RecordBatch
	proto.Unmarshal(ca.nextEvent("envelopes").Body, &batch)
	if len(batch.Records) != 1 || !proto.Equal(batch.Records[0], env) { t.Fatalf("delivered %v", batch.Records) }

	// reconnect without ack -> redelivered
	ca.c.CloseNow()
	ca2 := dial(t, n)
	login(t, ca2, anna)
	proto.Unmarshal(ca2.nextEvent("envelopes").Body, &batch)
	if len(batch.Records) != 1 { t.Fatal("not redelivered") }

	// ack -> gone
	var body pb.RecordBody
	proto.Unmarshal(env.Body, &body)
	key, _ := keys.RecordKey(body.Author, body.Id)
	ack := sign(t, pb.RecordType_ACK, anna.id, &pb.Ack{EnvelopeIds: [][]byte{key}, DeviceId: 1}, anna.priv)
	if st, msg := ca2.call("msg.ack", &pb.RecordRequest{Record: ack}, nil); st != pb.Status_STATUS_OK { t.Fatalf("ack: %v %s", st, msg) }
	if box, _ := n.svc.Mailbox(ctx, anna.id, 1, 10); len(box) != 0 { t.Fatal("mailbox not empty after ack") }
	ca3 := dial(t, n)
	login(t, ca3, anna)
	ca3.noEvent("envelopes", 300*time.Millisecond)
}
```
- [ ] **Step 8: Run** `go test -race ./internal/gateway/ ./internal/transport/... -v` → PASS; `make check` → PASS.
- [ ] **Step 9: Commit** `git add -A && git commit -m "feat(gateway): websocket protocol, mailbox delivery, wss transport"`

---

### Task 6: `otter-node` binary and config

**Goal:** A runnable node: `otter-node run --config node.toml`, `otter-node import --config node.toml FILE...`.

**Files:**
- Create: `internal/config/config.go`, `internal/config/config_test.go`, `cmd/otter-node/main.go`, `cmd/otter-node/main_test.go`

**Acceptance Criteria:**
- [ ] TOML config fields: `data_dir`, `node_key`, `network_pub` (hex), `manifest_file` (optional), `log_level` (debug|info|warn|error, default info), `[wss] listen, path, tls_cert, tls_key, site_dir`
- [ ] Validation errors name the field: missing required, bad hex/length, path not starting with `/` or shorter than 8, only one of cert/key
- [ ] `run`: opens `<data_dir>/node.db`, loads node key, imports `manifest_file` if set (verifies against `network_pub`), warns if this node is not in the latest manifest, serves until SIGINT/SIGTERM, graceful shutdown (5 s)
- [ ] `import`: applies each record file via `Service.ImportRecord`, prints `applied`/`already present` per file
- [ ] `main_test.go` builds a config in a temp dir, runs `import` of an admin-signed manifest and bootstrap invite (via `internal/admin`), then starts `run` on `127.0.0.1:0`-style free port in a goroutine and connects a WebSocket, receiving `hello`

**Verify:** `go test ./internal/config/ ./cmd/otter-node/ -v` → PASS; `make build` produces `bin/otter-node`

**Steps:**

- [ ] **Step 1:** `go get github.com/BurntSushi/toml@v1.6.0`

- [ ] **Step 2: `internal/config/config.go`**
```go
// Package config loads otter-node's TOML configuration.
package config

import (
	"crypto/ed25519"
	"encoding/hex"
	"fmt"
	"strings"

	"github.com/BurntSushi/toml"
)

type WSS struct {
	Listen  string `toml:"listen"`
	Path    string `toml:"path"`
	TLSCert string `toml:"tls_cert"`
	TLSKey  string `toml:"tls_key"`
	SiteDir string `toml:"site_dir"`
}

type Config struct {
	DataDir      string `toml:"data_dir"`
	NodeKey      string `toml:"node_key"`
	NetworkPub   string `toml:"network_pub"`
	ManifestFile string `toml:"manifest_file"`
	LogLevel     string `toml:"log_level"`
	WSS          WSS    `toml:"wss"`
}

func Load(path string) (*Config, error) {
	var c Config
	md, err := toml.DecodeFile(path, &c)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if und := md.Undecoded(); len(und) > 0 {
		return nil, fmt.Errorf("%s: unknown keys %v", path, und)
	}
	if c.LogLevel == "" {
		c.LogLevel = "info"
	}
	return &c, c.validate()
}

func (c *Config) validate() error {
	req := map[string]string{"data_dir": c.DataDir, "node_key": c.NodeKey, "network_pub": c.NetworkPub,
		"wss.listen": c.WSS.Listen, "wss.path": c.WSS.Path}
	for k, v := range req {
		if strings.TrimSpace(v) == "" {
			return fmt.Errorf("config: %s is required", k)
		}
	}
	if _, err := c.NetworkPubKey(); err != nil {
		return err
	}
	if !strings.HasPrefix(c.WSS.Path, "/") || len(c.WSS.Path) < 8 {
		return fmt.Errorf("config: wss.path must start with / and be at least 8 characters")
	}
	if (c.WSS.TLSCert == "") != (c.WSS.TLSKey == "") {
		return fmt.Errorf("config: wss.tls_cert and wss.tls_key must be set together")
	}
	switch c.LogLevel {
	case "debug", "info", "warn", "error":
	default:
		return fmt.Errorf("config: log_level %q (debug|info|warn|error)", c.LogLevel)
	}
	return nil
}

func (c *Config) NetworkPubKey() (ed25519.PublicKey, error) {
	b, err := hex.DecodeString(c.NetworkPub)
	if err != nil || len(b) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("config: network_pub must be %d hex-encoded bytes", ed25519.PublicKeySize)
	}
	return b, nil
}
```
`config_test.go`: one valid file parses; table of invalid variants (missing `data_dir`, bad `network_pub`,
`path = "x"`, cert without key, unknown key `foo = 1`, `log_level = "loud"`) each returns an error containing the field name.

- [ ] **Step 3: `cmd/otter-node/main.go`**
```go
// Command otter-node runs an OtterMSG relay node.
package main

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"google.golang.org/protobuf/proto"
	"ottermsg/server/internal/config"
	"ottermsg/server/internal/gateway"
	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/service"
	"ottermsg/server/internal/store"
	"ottermsg/server/internal/transport/wss"
)

var version = "dev"

const usage = `usage: otter-node <command> --config FILE
  run                  serve clients
  import FILE...       apply signed record files (manifest, bootstrap invite)
  version`

func main() {
	if err := run(context.Background(), os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

type app struct {
	cfg   *config.Config
	st    *store.Store
	svc   *service.Service
	log   *slog.Logger
	close func()
}

func open(cfgPath string, out io.Writer) (*app, error) {
	cfg, err := config.Load(cfgPath)
	if err != nil {
		return nil, err
	}
	var lvl slog.Level
	_ = lvl.UnmarshalText([]byte(cfg.LogLevel))
	log := slog.New(slog.NewJSONHandler(out, &slog.HandlerOptions{Level: lvl}))
	if err := os.MkdirAll(cfg.DataDir, 0o700); err != nil {
		return nil, err
	}
	nodeKey, err := keys.ReadPlainKey(cfg.NodeKey)
	if err != nil {
		return nil, err
	}
	netPub, _ := cfg.NetworkPubKey()
	st, err := store.Open(filepath.Join(cfg.DataDir, "node.db"))
	if err != nil {
		return nil, err
	}
	nodeID := keys.ID16(nodeKey.Public().(ed25519.PublicKey))
	svc := service.New(st, nodeID, netPub)
	return &app{cfg: cfg, st: st, svc: svc, log: log, close: func() { st.Close() }}, nil
}

func importFile(ctx context.Context, svc *service.Service, path string) (bool, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return false, err
	}
	var rec pb.Record
	if err := proto.Unmarshal(raw, &rec); err != nil {
		return false, fmt.Errorf("%s: not a record: %w", path, err)
	}
	return svc.ImportRecord(ctx, &rec)
}

func run(ctx context.Context, args []string, out io.Writer) error {
	if len(args) == 0 {
		return errors.New(usage)
	}
	cmd := args[0]
	if cmd == "version" {
		fmt.Fprintln(out, version)
		return nil
	}
	fs := flag.NewFlagSet(cmd, flag.ContinueOnError)
	cfgPath := fs.String("config", "/etc/otter/node.toml", "config file")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	a, err := open(*cfgPath, out)
	if err != nil {
		return err
	}
	defer a.close()

	switch cmd {
	case "import":
		if fs.NArg() == 0 {
			return errors.New("import: no files")
		}
		for _, f := range fs.Args() {
			applied, err := importFile(ctx, a.svc, f)
			if err != nil {
				return fmt.Errorf("%s: %w", f, err)
			}
			state := "already present"
			if applied {
				state = "applied"
			}
			fmt.Fprintf(out, "%s: %s\n", f, state)
		}
		return nil
	case "run":
		return serve(ctx, a)
	default:
		return errors.New(usage)
	}
}

func serve(ctx context.Context, a *app) error {
	if a.cfg.ManifestFile != "" {
		if _, err := importFile(ctx, a.svc, a.cfg.ManifestFile); err != nil {
			return fmt.Errorf("manifest_file: %w", err)
		}
	}
	if rec, v, err := a.svc.Manifest(ctx); err != nil {
		a.log.Warn("no manifest imported; clients cannot verify this network yet")
	} else {
		var body pb.RecordBody
		var m pb.Manifest
		_ = proto.Unmarshal(rec.Body, &body)
		_ = proto.Unmarshal(body.Payload, &m)
		found := false
		for _, n := range m.Nodes {
			found = found || bytes.Equal(n.NodeId, a.svc.NodeID)
		}
		if !found {
			a.log.Warn("this node is not listed in the manifest", "manifest_version", v, "node_id", fmt.Sprintf("%x", a.svc.NodeID))
		}
	}
	gw := gateway.New(a.svc, a.log)
	wcfg := wss.Config{Listen: a.cfg.WSS.Listen, Path: a.cfg.WSS.Path, TLSCert: a.cfg.WSS.TLSCert, TLSKey: a.cfg.WSS.TLSKey, SiteDir: a.cfg.WSS.SiteDir}
	srv := wss.NewServer(wcfg, gw)
	ctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()
	errc := make(chan error, 1)
	go func() { errc <- wss.Serve(srv, wcfg) }()
	a.log.Info("otter-node started", "listen", a.cfg.WSS.Listen, "node_id", fmt.Sprintf("%x", a.svc.NodeID), "version", version)
	select {
	case err := <-errc:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		return srv.Shutdown(sctx)
	}
}
```
Also import `"crypto/ed25519"`.
Note: `srv.Shutdown` doesn't close hijacked WebSocket connections; their request contexts end when the process exits — acceptable for M1.

- [ ] **Step 4: `main_test.go`** — create admin state with `admin.InitNetwork`, `admin.AddNode(..., Plain: true)` (from Task 7 —
if Task 7 isn't done yet, sign the manifest directly with `records.Sign` in the test), write `node.toml` pointing at the generated
`nodes/<label>/node.key`, run `import` for `manifest.bin`, then start `run` with `wss.listen = 127.0.0.1:<free port>`
(get one via `net.Listen("tcp","127.0.0.1:0")` then close), dial `ws://127.0.0.1:<port><path>` with `coder/websocket` and
read the `hello` event; cancel the context to stop.

- [ ] **Step 5: Run** `go test ./internal/config/ ./cmd/otter-node/ -v` → PASS; `make build` → `bin/otter-admin`, `bin/otter-node`.
- [ ] **Step 6: Commit** `git add -A && git commit -m "feat(node): otter-node binary with toml config, run and import"`

---

### Task 7: Admin bootstrap invites, dev endpoints, vectors v1 extension

**Goal:** Admin can create the first member's invite (link + terminal QR); dev nodes can advertise
plain `ws://`; vectors cover identity derivation, auth message and invite links.

**Files:**
- Create: `internal/admin/invite.go`; Test: add to `internal/admin/admin_test.go`
- Modify: `internal/admin/state.go` (`NodeSpec.Plain`), `cmd/otter-admin/main.go` (`--plain`, `invite bootstrap`)
- Modify: `internal/vectors/vectors_test.go`, regenerate `testdata/vectors/v1.json`

**Acceptance Criteria:**
- [ ] `node add --plain` creates a `WS_PLAIN` endpoint
- [ ] `invite bootstrap [--ttl 168h]` requires `manifest.bin`; writes `invites/<first 16 hex of invite_id>.bin` (network-signed INVITE, `expires_ms` = now+ttl in both body and payload); prints the `otter://join/...` link, a terminal QR, and the import command
- [ ] `EncodeInviteLink`/`DecodeInviteLink` round-trip; decode rejects other schemes and bad base64
- [ ] Vectors gain `identity_pub_hex` (= `05 ‖ X25519(HKDF(seed,"otter/identity/v1"))`), `auth_message_hex`, `invite_link`; regenerated intentionally

**Verify:** `go test ./internal/admin/ ./cmd/otter-admin/ ./internal/vectors/ -v` → PASS

**Steps:**

- [ ] **Step 1:** `go get github.com/mdp/qrterminal/v3@v3.2.1`

- [ ] **Step 2: `internal/admin/invite.go`**
```go
package admin

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"google.golang.org/protobuf/proto"
	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/records"
)

const InvitePrefix = "otter://join/"

func EncodeInviteLink(b *pb.InviteBundle) (string, error) {
	raw, err := proto.MarshalOptions{Deterministic: true}.Marshal(b)
	if err != nil {
		return "", err
	}
	return InvitePrefix + base64.RawURLEncoding.EncodeToString(raw), nil
}

func DecodeInviteLink(link string) (*pb.InviteBundle, error) {
	if !strings.HasPrefix(link, InvitePrefix) {
		return nil, errors.New("not an otter invite link")
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(link, InvitePrefix))
	if err != nil {
		return nil, fmt.Errorf("invite link: %w", err)
	}
	b := &pb.InviteBundle{}
	return b, proto.Unmarshal(raw, b)
}

type BootstrapResult struct {
	Record *pb.Record
	Link   string
	File   string
}

// BootstrapInvite creates a network-signed invite for the first member.
func BootstrapInvite(dir string, pass []byte, now time.Time, ttl time.Duration) (*BootstrapResult, error) {
	st, err := LoadState(dir)
	if err != nil {
		return nil, err
	}
	mraw, err := os.ReadFile(filepath.Join(dir, "manifest.bin"))
	if err != nil {
		return nil, fmt.Errorf("no signed manifest (run 'manifest sign' first): %w", err)
	}
	var manifest pb.Record
	if err := proto.Unmarshal(mraw, &manifest); err != nil {
		return nil, err
	}
	priv, err := keys.ReadEncryptedKey(filepath.Join(dir, "network.key.enc"), pass)
	if err != nil {
		return nil, err
	}
	secret := make([]byte, 32)
	rand.Read(secret)
	sum := sha256.Sum256(secret)
	exp := now.Add(ttl).UnixMilli()
	payload, _ := proto.Marshal(&pb.Invite{InviteId: sum[:], ExpiresMs: exp})
	id := make([]byte, 16)
	rand.Read(id)
	rec, err := records.Sign(&pb.RecordBody{Id: id, Type: pb.RecordType_INVITE, Author: keys.ID16(st.NetworkPub),
		CreatedMs: now.UnixMilli(), ExpiresMs: exp, Payload: payload}, priv)
	if err != nil {
		return nil, err
	}
	link, err := EncodeInviteLink(&pb.InviteBundle{NetworkPub: st.NetworkPub, Manifest: &manifest, Secret: secret})
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Join(dir, "invites"), 0o700); err != nil {
		return nil, err
	}
	file := filepath.Join(dir, "invites", hex.EncodeToString(sum[:8])+".bin")
	raw, _ := proto.Marshal(rec)
	if err := os.WriteFile(file, raw, 0o600); err != nil {
		return nil, err
	}
	return &BootstrapResult{Record: rec, Link: link, File: file}, nil
}
```

- [ ] **Step 3: `state.go`** — add `Plain bool` to `NodeSpec`; in `AddNode` set the endpoint kind:
```go
	kind := pb.Endpoint_WSS
	if s.Plain {
		kind = pb.Endpoint_WS_PLAIN
	}
	// ... Endpoints: []*pb.Endpoint{{Kind: kind, Host: ..., Port: ..., Path: ..., ViaCdn: s.CDN}}
```

- [ ] **Step 4: CLI** — in `node add` add `fs.BoolVar(&s.Plain, "plain", false, "development only: unencrypted ws:// endpoint")`;
add command (update `usage` with `invite bootstrap [--ttl 168h]`):
```go
	case "invite bootstrap":
		fs := flag.NewFlagSet("invite bootstrap", flag.ContinueOnError)
		ttl := fs.Duration("ttl", 7*24*time.Hour, "invite validity")
		if err := fs.Parse(a[2:]); err != nil { return err }
		p, err := passphrase(in, false)
		if err != nil { return err }
		res, err := admin.BootstrapInvite(*dir, p, time.Now(), *ttl)
		if err != nil { return err }
		fmt.Fprintf(out, "Invite for the first member (valid %s):\n%s\n\n", *ttl, res.Link)
		qrterminal.GenerateHalfBlock(res.Link, qrterminal.L, out)
		fmt.Fprintf(out, "\nRecord: %s\nCopy it to the node and run:\n  otter-node import --config /etc/otter/node.toml %s\n", res.File, filepath.Base(res.File))
```
(import `github.com/mdp/qrterminal/v3`.)

- [ ] **Step 5: Tests** — in `admin_test.go`:
```go
func TestBootstrapInvite(t *testing.T) {
	dir := t.TempDir()
	if err := InitNetwork(dir, pass); err != nil { t.Fatal(err) }
	if _, err := BootstrapInvite(dir, pass, time.Now(), time.Hour); err == nil { t.Fatal("must require manifest") }
	if _, err := AddNode(dir, NodeSpec{Label: "dev", WSSHost: "10.0.2.2", WSSPort: 8080, Plain: true}); err != nil { t.Fatal(err) }
	if _, err := SignManifest(dir, pass, time.Now()); err != nil { t.Fatal(err) }
	res, err := BootstrapInvite(dir, pass, time.Now(), time.Hour)
	if err != nil { t.Fatal(err) }
	st, _ := LoadState(dir)
	v := &records.Validator{NetworkPub: st.NetworkPub, Users: noUsers{}, Now: time.Now}
	body, err := v.Validate(res.Record)
	if err != nil || body.Type != pb.RecordType_INVITE { t.Fatalf("invite record: %v", err) }
	b, err := DecodeInviteLink(res.Link)
	if err != nil || len(b.Secret) != 32 || b.Manifest == nil { t.Fatalf("link: %v", err) }
	sum := sha256.Sum256(b.Secret)
	var inv pb.Invite
	proto.Unmarshal(body.Payload, &inv)
	if !bytes.Equal(sum[:], inv.InviteId) { t.Fatal("secret does not match invite_id") }
	if st.Nodes[0].Endpoints[0].Kind != pb.Endpoint_WS_PLAIN { t.Fatal("plain endpoint") }
	if _, err := DecodeInviteLink("https://x/" ); err == nil { t.Fatal("scheme") }
	if _, err := DecodeInviteLink(InvitePrefix + "!!!"); err == nil { t.Fatal("base64") }
}
```
(add imports `bytes`, `crypto/sha256`.)

- [ ] **Step 6: Vectors** — in `internal/vectors/vectors_test.go` add fields and generation:
```go
	IdentityPubHex string `json:"identity_pub_hex"`
	AuthMessageHex string `json:"auth_message_hex"`
	InviteLink     string `json:"invite_link"`
```
```go
	idPriv, _ := hkdf.Key(sha256.New, seed, nil, "otter/identity/v1", 32)
	idPub, _ := curve25519.X25519(idPriv, curve25519.Basepoint)
	v.IdentityPubHex = "05" + hex.EncodeToString(idPub)
	v.AuthMessageHex = hex.EncodeToString(keys.AuthMessage(seq(16, 10), seq(32, 20), 1_800_000_000_000))
	v.InviteLink, _ = admin.EncodeInviteLink(&pb.InviteBundle{NetworkPub: netPub, Manifest: mrec, Secret: seq(32, 9),
		InviterUserId: keys.ID16(accPub), InviterAccountPub: accPub, InviterIdentityPub: append([]byte{5}, idPub...), InviterName: "Мама"})
```
(imports `crypto/hkdf`, `crypto/sha256`, `golang.org/x/crypto/curve25519`, `ottermsg/server/internal/admin`.)
Regenerate: `OTTER_WRITE_VECTORS=1 go test ./internal/vectors/` then `go test ./internal/vectors/ -v` → PASS.

- [ ] **Step 7: Run** `make check` → PASS.
- [ ] **Step 8: Commit** `git add -A && git commit -m "feat(admin): bootstrap invites, plain dev endpoints; extend vectors"`

---

### Task 8: Local development node script

**Goal:** One command creates a throwaway network and runs a node reachable from the Android emulator.

**Files:**
- Create: `scripts/dev-node.sh`; Modify: `README.md` (dev section)

**Acceptance Criteria:**
- [ ] `scripts/dev-node.sh` (re)creates `./.dev/` (gitignored): admin dir, node `dev` with `--plain --wss-host 10.0.2.2 --wss-port 8080`, signed manifest, `node.toml` (`listen = "0.0.0.0:8080"`), imports manifest + bootstrap invite, prints the invite link and QR, then runs the node in the foreground
- [ ] `--keep` reuses the existing `.dev/` (no new network) and just runs the node
- [ ] `--host H` overrides the advertised host (e.g. the PC's LAN IP for a real phone)

**Verify:** `scripts/dev-node.sh` → prints link; `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/` → `404`; Ctrl-C stops it.

**Steps:**

- [ ] **Step 1: Script**
```bash
#!/usr/bin/env bash
# Throwaway local network for development. NOT for production (plain ws://, passphrase in env).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
dev="$root/.dev"
host="10.0.2.2"   # Android emulator's alias for the host machine
keep=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) keep=1 ;;
    --host) host="$2"; shift ;;
    *) echo "usage: $0 [--keep] [--host H]"; exit 2 ;;
  esac
  shift
done
export OTTER_ADMIN_PASSPHRASE="dev-only-passphrase"
make -C "$root" build >/dev/null
admin="$root/bin/otter-admin --dir $dev/admin"
node="$root/bin/otter-node"
if [[ $keep -eq 0 ]]; then
  rm -rf "$dev" && mkdir -p "$dev"
  $admin network init >/dev/null
  $admin node add --label dev --plain --wss-host "$host" --wss-port 8080 >/dev/null
  $admin manifest sign >/dev/null
  netpub="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["network_pub"])' "$dev/admin/network.json")"
  path="$(python3 - "$dev/admin/nodes.json" <<'EOF'
import json,sys
n=json.load(open(sys.argv[1]))["nodes"][0]
print(n["endpoints"][0]["path"])
EOF
)"
  cat > "$dev/node.toml" <<EOF
data_dir = "$dev/data"
node_key = "$dev/admin/nodes/dev/node.key"
network_pub = "$netpub"
manifest_file = "$dev/admin/manifest.bin"
log_level = "debug"
[wss]
listen = "0.0.0.0:8080"
path = "$path"
EOF
  $node import --config "$dev/node.toml" "$dev/admin/manifest.bin"
  out="$($admin invite bootstrap)"
  echo "$out"
  file="$(echo "$out" | sed -n 's/^Record: //p')"
  $node import --config "$dev/node.toml" "$file"
  echo "$out" | grep '^otter://' > "$dev/bootstrap-invite.txt"
fi
echo "Bootstrap invite: $(cat "$dev/bootstrap-invite.txt")"
exec $node run --config "$dev/node.toml"
```
(`protojson` writes `"endpoints"` and `"path"` in lowerCamel — verify the key names in `.dev/admin/nodes.json` and adjust.)
`chmod +x scripts/dev-node.sh`; add `.dev/` to `.gitignore`.

- [ ] **Step 2: README** — "Local development" section: run the script, paste/scan the link in the emulator app, `--host <LAN IP>` for a real phone on the same Wi-Fi.
- [ ] **Step 3: Verify manually** (commands above).
- [ ] **Step 4: Commit** `git add -A && git commit -m "chore: local dev network script"`

---

## Part B — `otter-android`

All Gradle commands: `cd otter-android && JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 ./gradlew <tasks>`
(the Gradle *daemon* may run on that JRE; compilation uses toolchains).

### Task 9: Java 21 toolchain, libsignal, NDK, new modules

**Goal:** Project compiles against libsignal 0.106.2 on Java 21, the APK strips native libs, and new module shells exist.

**Files:**
- Modify: `settings.gradle.kts`, `gradle.properties`, `gradle/libs.versions.toml`, every `build.gradle.kts`
- Create: `core/signal/build.gradle.kts`, `core/network/build.gradle.kts`, `core/data/build.gradle.kts`,
  `feature/onboarding/build.gradle.kts`, `feature/chats/build.gradle.kts`, `feature/conversation/build.gradle.kts`
  (+ minimal `src/main/AndroidManifest.xml` not required for libraries with namespaces)
- Test: `core/signal/src/test/kotlin/app/ottermsg/core/signal/LibsignalSmokeTest.kt`

**Acceptance Criteria:**
- [ ] foojay resolver 0.10.0 in `settings.gradle.kts`; all modules use `jvmToolchain(21)` and Java 21 `compileOptions`
- [ ] NDK `27.0.12077973` installed (`sdkmanager "ndk;27.0.12077973"`) and set as `ndkVersion` in `app`; ABI filters `arm64-v8a`, `armeabi-v7a`, `x86_64`
- [ ] Packaging excludes `**/libsignal_jni_testing.so` and desktop natives (`libsignal_jni*.so`, `*.dylib`, `signal_jni*.dll` from java resources)
- [ ] `LibsignalSmokeTest` (JVM) creates an `IdentityKeyPair` and an `ECKeyPair` — proves desktop natives load in unit tests
- [ ] `./gradlew assembleDebug test` green; the debug APK size is recorded in the task report (expect < 60 MB)

**Verify:** `./gradlew :core:signal:test assembleDebug && ls -lh app/build/outputs/apk/debug/`

**Steps:**

- [ ] **Step 1: Install NDK** `~/Android/Sdk/cmdline-tools/latest/bin/sdkmanager "ndk;27.0.12077973"`

- [ ] **Step 2: `settings.gradle.kts`**
```kotlin
pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}
plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "0.10.0"
}
dependencyResolutionManagement { /* unchanged */ }
rootProject.name = "otter-android"
include(
    ":app",
    ":core:proto", ":core:crypto", ":core:signal", ":core:network", ":core:database", ":core:data", ":core:ui",
    ":feature:onboarding", ":feature:chats", ":feature:conversation",
)
```
`gradle.properties`: remove the `org.gradle.java.installations.paths=...jbr-17...` line (JDK 21 is auto-provisioned).

- [ ] **Step 3: Version catalog additions**
```toml
[versions]
libsignal = "0.106.2"
okhttp = "5.2.1"
zxingEmbedded = "4.3.0"
androidxTestExt = "1.3.0"
androidxTestRunner = "1.7.0"

[libraries]
libsignal-client = { module = "org.signal:libsignal-client", version.ref = "libsignal" }
libsignal-android = { module = "org.signal:libsignal-android", version.ref = "libsignal" }
okhttp = { module = "com.squareup.okhttp3:okhttp", version.ref = "okhttp" }
zxing-embedded = { module = "com.journeyapps:zxing-android-embedded", version.ref = "zxingEmbedded" }
androidx-lifecycle-process = { module = "androidx.lifecycle:lifecycle-process", version.ref = "lifecycle" }
androidx-test-ext-junit = { module = "androidx.test.ext:junit", version.ref = "androidxTestExt" }
androidx-test-runner = { module = "androidx.test:runner", version.ref = "androidxTestRunner" }
compose-ui-test-junit4 = { module = "androidx.compose.ui:ui-test-junit4" }
compose-ui-test-manifest = { module = "androidx.compose.ui:ui-test-manifest" }
```

- [ ] **Step 4: Java 21 everywhere** — in every module replace `jvmToolchain(17)` with `jvmToolchain(21)` and
`JavaVersion.VERSION_17` with `JavaVersion.VERSION_21`.

- [ ] **Step 5: New module build files**

`core/signal/build.gradle.kts`:
```kotlin
plugins { alias(libs.plugins.kotlin.jvm) }
kotlin { jvmToolchain(21) }
dependencies {
    api(project(":core:crypto"))
    api(libs.libsignal.client)
    testImplementation(libs.junit)
}
```
`core/network/build.gradle.kts`:
```kotlin
plugins { alias(libs.plugins.kotlin.jvm) }
kotlin { jvmToolchain(21) }
dependencies {
    api(project(":core:crypto"))
    api(libs.okhttp)
    api(libs.coroutines.core)
    testImplementation(libs.junit); testImplementation(libs.coroutines.test)
}
```
`core/data/build.gradle.kts`:
```kotlin
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.ksp)
    alias(libs.plugins.hilt)
}
android {
    namespace = "app.ottermsg.core.data"
    compileSdk = 36
    defaultConfig { minSdk = 26 }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_21; targetCompatibility = JavaVersion.VERSION_21 }
    testOptions { unitTests.isIncludeAndroidResources = true }
}
kotlin { jvmToolchain(21) }
dependencies {
    api(project(":core:signal")); api(project(":core:network")); api(project(":core:database"))
    implementation(libs.room.runtime); implementation(libs.room.ktx)
    implementation(libs.hilt.android); ksp(libs.hilt.compiler)
    implementation(libs.androidx.lifecycle.process)
    testImplementation(libs.junit); testImplementation(libs.robolectric); testImplementation(libs.androidx.test.core)
    testImplementation(libs.coroutines.test)
}
```
Feature modules (`feature/onboarding`, `feature/chats`, `feature/conversation`) — same template, namespace
`app.ottermsg.feature.<name>`:
```kotlin
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.ksp)
    alias(libs.plugins.hilt)
}
android {
    namespace = "app.ottermsg.feature.onboarding"
    compileSdk = 36
    defaultConfig { minSdk = 26 }
    buildFeatures { compose = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_21; targetCompatibility = JavaVersion.VERSION_21 }
    testOptions { unitTests.isIncludeAndroidResources = true }
}
kotlin { jvmToolchain(21) }
dependencies {
    implementation(project(":core:ui")); implementation(project(":core:data"))
    implementation(libs.androidx.lifecycle.runtime.compose); implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.hilt.android); ksp(libs.hilt.compiler); implementation(libs.hilt.navigation.compose)
    implementation(libs.compose.material.icons)
    testImplementation(libs.junit); testImplementation(libs.robolectric); testImplementation(libs.coroutines.test)
    testImplementation(libs.compose.ui.test.junit4); debugImplementation(libs.compose.ui.test.manifest)
}
```
`feature/onboarding` additionally: `implementation(libs.zxing.embedded)`.

- [ ] **Step 6: `app/build.gradle.kts`** additions:
```kotlin
android {
    ndkVersion = "27.0.12077973"
    defaultConfig {
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64") }
    }
    buildFeatures { compose = true; buildConfig = true }
    buildTypes {
        debug { buildConfigField("boolean", "ALLOW_PLAINTEXT", "true") }
        release {
            buildConfigField("boolean", "ALLOW_PLAINTEXT", "false")
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    packaging {
        jniLibs { excludes += "**/libsignal_jni_testing.so" }
        resources { excludes += listOf("libsignal_jni*.so", "libsignal_jni*.dylib", "signal_jni*.dll") }
    }
}
dependencies {
    implementation(project(":core:data"))
    implementation(project(":feature:onboarding")); implementation(project(":feature:chats")); implementation(project(":feature:conversation"))
    implementation(libs.libsignal.android)
    implementation(libs.androidx.navigation.compose); implementation(libs.hilt.navigation.compose)
    implementation(libs.androidx.lifecycle.process)
}
```
`proguard-rules.pro` add: `-keep class org.signal.libsignal.** { *; }` and `-keep class app.ottermsg.proto.** { *; }`
(JNI and protobuf-lite reflection).

- [ ] **Step 7: Smoke test** `core/signal/src/test/kotlin/app/ottermsg/core/signal/LibsignalSmokeTest.kt`:
```kotlin
package app.ottermsg.core.signal

import org.junit.Assert.assertEquals
import org.junit.Test
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.ecc.ECKeyPair

class LibsignalSmokeTest {
    @Test fun nativesLoad() {
        val id = IdentityKeyPair.generate()
        assertEquals(33, id.publicKey.serialize().size)
        assertEquals(33, ECKeyPair.generate().publicKey.serialize().size)
    }
}
```

- [ ] **Step 8: Build** `./gradlew :core:signal:test assembleDebug test` → green. Record `ls -lh app/build/outputs/apk/debug/`.
If the build log says "Unable to strip library", the NDK path is wrong — fix before continuing.
- [ ] **Step 9: Commit** `git add -A && git commit -m "build: java 21 toolchain, libsignal, ndk stripping, M1 module shells"`

---

### Task 10: `core:crypto` additions — identity seed, auth message, invite links

**Goal:** Kotlin mirrors of the Go helpers, checked against regenerated vectors.

**Files:**
- Run: `scripts/sync-proto.sh` (new protos + vectors)
- Modify: `core/crypto/.../SeedKeys.kt`; Create: `AuthMessage.kt`, `InviteLink.kt`
- Test: extend `core/crypto/src/test/.../VectorsTest.kt`; Create `InviteLinkTest.kt`

**Acceptance Criteria:**
- [ ] `SeedKeys.identityPrivate(seed)` = HKDF(seed, info `otter/identity/v1`, 32)
- [ ] `AuthMessage.build(nodeId, nonce, tsMs)` equals vector `auth_message_hex`
- [ ] `InviteLink.decode(vector invite_link)` yields inviter name "Мама", 32-byte secret, the vector manifest; `encode(decode(x)) == x`; decode rejects wrong scheme / bad base64 with `IllegalArgumentException`

**Verify:** `./gradlew :core:crypto:test`

**Steps:**

- [ ] **Step 1:** `scripts/sync-proto.sh` (copies all 7 protos and the regenerated v1.json).
- [ ] **Step 2: Tests** — add to `VectorsTest`:
```kotlin
    @Test fun authMessageMatchesGo() {
        val m = AuthMessage.build(ByteArray(16) { (10 + it).toByte() }, ByteArray(32) { (20 + it).toByte() }, 1_800_000_000_000)
        assertArrayEquals(hex(v.getValue("auth_message_hex")), m)
    }

    @Test fun inviteLinkFromGo() {
        val link = v.getValue("invite_link")
        val b = InviteLink.decode(link)
        assertEquals("Мама", b.inviterName)
        assertEquals(32, b.secret.size())
        assertEquals(link, InviteLink.encode(b))
        val m = ManifestVerifier.verify(b.manifest.toByteArray(), b.networkPub.toByteArray(), 0)
        assertEquals(7L, m.version)
    }
```
`InviteLinkTest.kt`:
```kotlin
package app.ottermsg.core.crypto

import org.junit.Assert.assertThrows
import org.junit.Test

class InviteLinkTest {
    @Test fun rejectsScheme() { assertThrows(IllegalArgumentException::class.java) { InviteLink.decode("https://example.org/x") } }
    @Test fun rejectsBase64() { assertThrows(IllegalArgumentException::class.java) { InviteLink.decode("otter://join/@@@") } }
    @Test fun trimsWhitespace() { assertThrows(IllegalArgumentException::class.java) { InviteLink.decode("  otter://join/  ") } }
}
```
(The vector regex parser in `VectorsTest` handles `invite_link` since it contains no quotes/commas — base64url only.)
- [ ] **Step 3: Implement**

`SeedKeys.kt` — add:
```kotlin
    const val INFO_IDENTITY = "otter/identity/v1"

    /** 32-byte libsignal identity private key (Curve25519); public = 0x05 || X25519(priv). */
    fun identityPrivate(seed: ByteArray): ByteArray {
        require(seed.size == 32) { "seed must be 32 bytes" }
        return Hkdf.computeHkdf("HMACSHA256", seed, ByteArray(0), INFO_IDENTITY.toByteArray(), 32)
    }
```
`AuthMessage.kt`:
```kotlin
package app.ottermsg.core.crypto

import java.nio.ByteBuffer

object AuthMessage {
    private val CONTEXT = "otter-auth-v1".toByteArray()

    fun build(nodeId: ByteArray, nonce: ByteArray, tsMs: Long): ByteArray =
        ByteBuffer.allocate(CONTEXT.size + nodeId.size + nonce.size + 8)
            .put(CONTEXT).put(nodeId).put(nonce).putLong(tsMs).array()
}
```
`InviteLink.kt`:
```kotlin
package app.ottermsg.core.crypto

import app.ottermsg.proto.v1.InviteBundle
import com.google.protobuf.InvalidProtocolBufferException
import java.util.Base64

object InviteLink {
    const val PREFIX = "otter://join/"

    fun encode(b: InviteBundle): String = PREFIX + Base64.getUrlEncoder().withoutPadding().encodeToString(b.toByteArray())

    fun decode(link: String): InviteBundle {
        val s = link.trim()
        require(s.startsWith(PREFIX) && s.length > PREFIX.length) { "not an Otter invite link" }
        val raw = try { Base64.getUrlDecoder().decode(s.removePrefix(PREFIX)) } catch (e: IllegalArgumentException) {
            throw IllegalArgumentException("invite link is damaged", e)
        }
        return try { InviteBundle.parseFrom(raw) } catch (e: InvalidProtocolBufferException) {
            throw IllegalArgumentException("invite link is damaged", e)
        }
    }
}
```
Note: `encode(decode(x)) == x` holds only if protobuf-javalite serializes fields in the same order as Go's
deterministic marshal (field-number order, no unknown fields) — both do for this message. If it fails, drop
that assertion and compare decoded fields instead; report it.
- [ ] **Step 4: Run** `./gradlew :core:crypto:test` → PASS.
- [ ] **Step 5: Commit** `git add -A && git commit -m "feat(crypto): identity seed, auth message, invite links"`

---

### Task 11: `core:signal` — protocol store, identity, prekeys, sessions

**Goal:** Everything libsignal-related behind a small API, persisted through a byte key-value interface.

**Files:**
- Create in `core/signal/src/main/kotlin/app/ottermsg/core/signal/`: `SignalKeyValue.kt`, `OtterProtocolStore.kt`,
  `IdentityKeys.kt`, `PreKeyFactory.kt`, `SignalSessions.kt`, `Hex.kt`
- Test: `IdentityKeysTest.kt`, `SessionsTest.kt` (+ copy `vectors/v1.json` into `core/signal/src/test/resources/vectors/` via `sync-proto.sh` — extend the script)

**Acceptance Criteria:**
- [ ] `IdentityKeys.fromSeed(vector seed).publicKey.serialize()` == vector `identity_pub_hex`
- [ ] `IdentityKeys.bindAccount` / `verifyBinding` round-trip; tampered signature fails
- [ ] Two in-memory parties: Bob publishes prekeys (`PreKeyFactory`), Alice builds a session from a proto `PreKeyBundle`, sends 3 messages (first is `PREKEY_SIGNAL`), Bob decrypts in order; Bob replies (`SIGNAL`), Alice decrypts; replaying a message → `DuplicateMessageException`; out-of-order delivery decrypts
- [ ] Bundle whose identity differs from the directory identity → `IllegalStateException`
- [ ] Bundle without one-time key (last-resort Kyber only) still establishes a session
- [ ] `markKyberPreKeyUsed` twice with the same base key → `ReusedBaseKeyException`
- [ ] `saveIdentity` returns `REPLACED_EXISTING` and invokes the callback when a contact's identity changes

**Verify:** `./gradlew :core:signal:test`

**Steps:**

- [ ] **Step 1: Failing tests**

`IdentityKeysTest.kt`:
```kotlin
package app.ottermsg.core.signal

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class IdentityKeysTest {
    private val v: Map<String, String> = run {
        val text = javaClass.getResource("/vectors/v1.json")!!.readText()
        Regex("\"(\\w+)\":\\s*\"?([^\",\\n]*)\"?").findAll(text).associate { it.groupValues[1] to it.groupValues[2] }
    }

    @Test fun identityMatchesGoX25519() {
        val id = IdentityKeys.fromSeed(v.getValue("seed_hex").hexToBytes())
        assertArrayEquals(v.getValue("identity_pub_hex").hexToBytes(), id.publicKey.serialize())
    }

    @Test fun accountBinding() {
        val id = IdentityKeys.fromSeed(ByteArray(32) { 3 })
        val account = ByteArray(32) { 9 }
        val sig = IdentityKeys.bindAccount(id, account)
        assertTrue(IdentityKeys.verifyBinding(id.publicKey.serialize(), account, sig))
        sig[0] = (sig[0].toInt() xor 1).toByte()
        assertFalse(IdentityKeys.verifyBinding(id.publicKey.serialize(), account, sig))
    }
}
```
`SessionsTest.kt`:
```kotlin
package app.ottermsg.core.signal

import app.ottermsg.proto.v1.Envelope
import app.ottermsg.proto.v1.PreKeyBundle
import com.google.protobuf.ByteString
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import org.signal.libsignal.protocol.DuplicateMessageException
import org.signal.libsignal.protocol.ReusedBaseKeyException
import org.signal.libsignal.protocol.ecc.ECKeyPair
import org.signal.libsignal.protocol.state.IdentityKeyStore

class SessionsTest {
    private val node = ByteArray(16) { 1 }

    private class Party(name: Byte) {
        val userId = ByteArray(16) { name }
        val identity = IdentityKeys.fromSeed(ByteArray(32) { name })
        val changes = mutableListOf<String>()
        val store = OtterProtocolStore(identity, 1000 + name, InMemorySignalKeyValue()) { changes += it.name }
        val sessions = SignalSessions(store, userId)
    }

    private fun publish(p: Party, withOneTime: Boolean): PreKeyBundle {
        val signed = PreKeyFactory.signed(p.store, 1, 0)
        val kyber = PreKeyFactory.kyberLastResort(p.store, 1, 0)
        val oneTime = PreKeyFactory.oneTime(p.store, 100, 1, node)
        return PreKeyBundle.newBuilder().setUserId(ByteString.copyFrom(p.userId)).setDeviceId(1)
            .setRegistrationId(p.store.localRegistrationId).setIdentityPub(ByteString.copyFrom(p.identity.publicKey.serialize()))
            .setSignedPrekey(signed).setKyberPrekey(kyber)
            .apply { if (withOneTime) setOneTime(oneTime[0]) }.build()
    }

    @Test fun conversation() {
        val alice = Party(1); val bob = Party(2)
        alice.sessions.processBundle(publish(bob, true), bob.identity.publicKey.serialize())
        val toBob = alice.sessions.address(bob.userId)
        val toAlice = bob.sessions.address(alice.userId)

        val m1 = alice.sessions.encrypt(toBob, "один".toByteArray())
        val m2 = alice.sessions.encrypt(toBob, "два".toByteArray())
        val m3 = alice.sessions.encrypt(toBob, "три".toByteArray())
        assertEquals(Envelope.Kind.PREKEY_SIGNAL, m1.first)
        assertArrayEquals("один".toByteArray(), bob.sessions.decrypt(toAlice, m1.first, m1.second))
        assertArrayEquals("три".toByteArray(), bob.sessions.decrypt(toAlice, m3.first, m3.second)) // out of order
        assertArrayEquals("два".toByteArray(), bob.sessions.decrypt(toAlice, m2.first, m2.second))
        assertThrows(DuplicateMessageException::class.java) { bob.sessions.decrypt(toAlice, m2.first, m2.second) }

        val r = bob.sessions.encrypt(toAlice, "ответ".toByteArray())
        assertEquals(Envelope.Kind.SIGNAL, r.first)
        assertArrayEquals("ответ".toByteArray(), alice.sessions.decrypt(toBob, r.first, r.second))
    }

    @Test fun lastResortOnly() {
        val alice = Party(3); val bob = Party(4)
        alice.sessions.processBundle(publish(bob, false), bob.identity.publicKey.serialize())
        val m = alice.sessions.encrypt(alice.sessions.address(bob.userId), "hi".toByteArray())
        assertArrayEquals("hi".toByteArray(), bob.sessions.decrypt(bob.sessions.address(alice.userId), m.first, m.second))
    }

    @Test fun identityMismatchRejected() {
        val alice = Party(5); val bob = Party(6)
        assertThrows(IllegalStateException::class.java) {
            alice.sessions.processBundle(publish(bob, true), alice.identity.publicKey.serialize())
        }
    }

    @Test fun kyberReuseDetected() {
        val bob = Party(7)
        val base = ECKeyPair.generate().publicKey
        bob.store.markKyberPreKeyUsed(1, 1, base)
        assertThrows(ReusedBaseKeyException::class.java) { bob.store.markKyberPreKeyUsed(1, 1, base) }
    }

    @Test fun identityChangeReported() {
        val alice = Party(8)
        val addr = alice.sessions.address(ByteArray(16) { 9 })
        assertEquals(IdentityKeyStore.IdentityChange.NEW_OR_UNCHANGED, alice.store.saveIdentity(addr, IdentityKeys.fromSeed(ByteArray(32) { 1 }).publicKey))
        assertEquals(IdentityKeyStore.IdentityChange.REPLACED_EXISTING, alice.store.saveIdentity(addr, IdentityKeys.fromSeed(ByteArray(32) { 2 }).publicKey))
        assertEquals(listOf(addr.name), alice.changes)
    }
}
```

- [ ] **Step 2: Implement**

`Hex.kt`:
```kotlin
package app.ottermsg.core.signal

fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
fun String.hexToBytes(): ByteArray = chunked(2).map { it.toInt(16).toByte() }.toByteArray()
```
`SignalKeyValue.kt`:
```kotlin
package app.ottermsg.core.signal

/** Byte-level persistence for libsignal state; implemented over Room in core:data. */
interface SignalKeyValue {
    enum class Table(val id: Int) { IDENTITY(1), PREKEY(2), SIGNED_PREKEY(3), KYBER_PREKEY(4), SESSION(5), SENDER_KEY(6), KYBER_USED(7) }
    fun get(table: Table, key: String): ByteArray?
    fun put(table: Table, key: String, value: ByteArray)
    fun delete(table: Table, key: String)
    fun keys(table: Table): List<String>
}

class InMemorySignalKeyValue : SignalKeyValue {
    private val data = LinkedHashMap<Pair<SignalKeyValue.Table, String>, ByteArray>()
    @Synchronized override fun get(table: SignalKeyValue.Table, key: String) = data[table to key]?.copyOf()
    @Synchronized override fun put(table: SignalKeyValue.Table, key: String, value: ByteArray) { data[table to key] = value.copyOf() }
    @Synchronized override fun delete(table: SignalKeyValue.Table, key: String) { data.remove(table to key) }
    @Synchronized override fun keys(table: SignalKeyValue.Table) = data.keys.filter { it.first == table }.map { it.second }
    /** Copies everything into [target] (used after a successful registration). */
    @Synchronized fun copyInto(target: SignalKeyValue) = data.forEach { (k, v) -> target.put(k.first, k.second, v) }
}
```
`OtterProtocolStore.kt`:
```kotlin
package app.ottermsg.core.signal

import app.ottermsg.core.signal.SignalKeyValue.Table
import org.signal.libsignal.protocol.IdentityKey
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.InvalidKeyIdException
import org.signal.libsignal.protocol.NoSessionException
import org.signal.libsignal.protocol.ReusedBaseKeyException
import org.signal.libsignal.protocol.SignalProtocolAddress
import org.signal.libsignal.protocol.ecc.ECPublicKey
import org.signal.libsignal.protocol.groups.state.SenderKeyRecord
import org.signal.libsignal.protocol.state.IdentityKeyStore
import org.signal.libsignal.protocol.state.KyberPreKeyRecord
import org.signal.libsignal.protocol.state.PreKeyRecord
import org.signal.libsignal.protocol.state.SessionRecord
import org.signal.libsignal.protocol.state.SignalProtocolStore
import org.signal.libsignal.protocol.state.SignedPreKeyRecord
import java.util.UUID

/**
 * Trust policy: TOFU per user (address.name). Identity changes are accepted but reported through
 * [onIdentityChanged] so the UI can warn and clear "verified" (docs/04 "Key verification").
 */
class OtterProtocolStore(
    private val identity: IdentityKeyPair,
    private val registrationId: Int,
    private val kv: SignalKeyValue,
    private val onIdentityChanged: (SignalProtocolAddress) -> Unit = {},
) : SignalProtocolStore {
    private fun key(a: SignalProtocolAddress) = "${a.name}.${a.deviceId}"

    override fun getIdentityKeyPair(): IdentityKeyPair = identity
    override fun getLocalRegistrationId(): Int = registrationId

    override fun saveIdentity(address: SignalProtocolAddress, identityKey: IdentityKey): IdentityKeyStore.IdentityChange {
        val new = identityKey.serialize()
        val old = kv.get(Table.IDENTITY, address.name)
        kv.put(Table.IDENTITY, address.name, new)
        if (old != null && !old.contentEquals(new)) {
            onIdentityChanged(address)
            return IdentityKeyStore.IdentityChange.REPLACED_EXISTING
        }
        return IdentityKeyStore.IdentityChange.NEW_OR_UNCHANGED
    }

    override fun isTrustedIdentity(address: SignalProtocolAddress, identityKey: IdentityKey, direction: IdentityKeyStore.Direction) = true
    override fun getIdentity(address: SignalProtocolAddress): IdentityKey? = kv.get(Table.IDENTITY, address.name)?.let { IdentityKey(it) }

    override fun loadPreKey(preKeyId: Int) = kv.get(Table.PREKEY, "$preKeyId")?.let { PreKeyRecord(it) } ?: throw InvalidKeyIdException("no prekey $preKeyId")
    override fun storePreKey(preKeyId: Int, record: PreKeyRecord) = kv.put(Table.PREKEY, "$preKeyId", record.serialize())
    override fun containsPreKey(preKeyId: Int) = kv.get(Table.PREKEY, "$preKeyId") != null
    override fun removePreKey(preKeyId: Int) = kv.delete(Table.PREKEY, "$preKeyId")

    override fun loadSignedPreKey(signedPreKeyId: Int) =
        kv.get(Table.SIGNED_PREKEY, "$signedPreKeyId")?.let { SignedPreKeyRecord(it) } ?: throw InvalidKeyIdException("no signed prekey $signedPreKeyId")
    override fun loadSignedPreKeys() = kv.keys(Table.SIGNED_PREKEY).map { SignedPreKeyRecord(kv.get(Table.SIGNED_PREKEY, it)!!) }
    override fun storeSignedPreKey(signedPreKeyId: Int, record: SignedPreKeyRecord) = kv.put(Table.SIGNED_PREKEY, "$signedPreKeyId", record.serialize())
    override fun containsSignedPreKey(signedPreKeyId: Int) = kv.get(Table.SIGNED_PREKEY, "$signedPreKeyId") != null
    override fun removeSignedPreKey(signedPreKeyId: Int) = kv.delete(Table.SIGNED_PREKEY, "$signedPreKeyId")

    override fun loadKyberPreKey(kyberPreKeyId: Int) =
        kv.get(Table.KYBER_PREKEY, "$kyberPreKeyId")?.let { KyberPreKeyRecord(it) } ?: throw InvalidKeyIdException("no kyber prekey $kyberPreKeyId")
    override fun loadKyberPreKeys() = kv.keys(Table.KYBER_PREKEY).map { KyberPreKeyRecord(kv.get(Table.KYBER_PREKEY, it)!!) }
    override fun storeKyberPreKey(kyberPreKeyId: Int, record: KyberPreKeyRecord) = kv.put(Table.KYBER_PREKEY, "$kyberPreKeyId", record.serialize())
    override fun containsKyberPreKey(kyberPreKeyId: Int) = kv.get(Table.KYBER_PREKEY, "$kyberPreKeyId") != null
    override fun markKyberPreKeyUsed(kyberPreKeyId: Int, signedPreKeyId: Int, baseKey: ECPublicKey) {
        val k = "$kyberPreKeyId:$signedPreKeyId:${baseKey.serialize().toHex()}"
        if (kv.get(Table.KYBER_USED, k) != null) throw ReusedBaseKeyException("kyber prekey $kyberPreKeyId reused with same base key")
        kv.put(Table.KYBER_USED, k, byteArrayOf(1))
    }

    override fun loadSession(address: SignalProtocolAddress) = kv.get(Table.SESSION, key(address))?.let { SessionRecord(it) } ?: SessionRecord()
    override fun loadExistingSessions(addresses: List<SignalProtocolAddress>) =
        addresses.map { kv.get(Table.SESSION, key(it))?.let { b -> SessionRecord(b) } ?: throw NoSessionException("no session for $it") }
    override fun getSubDeviceSessions(name: String) =
        kv.keys(Table.SESSION).filter { it.startsWith("$name.") }.map { it.substringAfterLast('.').toInt() }.filter { it != 1 }
    override fun storeSession(address: SignalProtocolAddress, record: SessionRecord) = kv.put(Table.SESSION, key(address), record.serialize())
    override fun containsSession(address: SignalProtocolAddress) =
        kv.get(Table.SESSION, key(address))?.let { SessionRecord(it).hasSenderChain() } ?: false
    override fun deleteSession(address: SignalProtocolAddress) = kv.delete(Table.SESSION, key(address))
    override fun deleteAllSessions(name: String) = kv.keys(Table.SESSION).filter { it.startsWith("$name.") }.forEach { kv.delete(Table.SESSION, it) }

    override fun storeSenderKey(sender: SignalProtocolAddress, distributionId: UUID, record: SenderKeyRecord) =
        kv.put(Table.SENDER_KEY, "${key(sender)}:$distributionId", record.serialize())
    override fun loadSenderKey(sender: SignalProtocolAddress, distributionId: UUID): SenderKeyRecord? =
        kv.get(Table.SENDER_KEY, "${key(sender)}:$distributionId")?.let { SenderKeyRecord(it) }
}
```
(If a Kotlin override signature mismatches the Java/Kotlin interface — e.g. nullability of `getIdentity` — follow the compiler; the interfaces were checked with `javap`, see plan header.)

`IdentityKeys.kt`:
```kotlin
package app.ottermsg.core.signal

import app.ottermsg.core.crypto.SeedKeys
import org.signal.libsignal.protocol.IdentityKey
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.ecc.ECPrivateKey

object IdentityKeys {
    fun fromSeed(seed: ByteArray): IdentityKeyPair {
        val priv = ECPrivateKey(SeedKeys.identityPrivate(seed))
        return IdentityKeyPair(IdentityKey(priv.publicKey()), priv)
    }

    /** DirectoryEntry.identity_sig: XEdDSA by the identity key over the Ed25519 account public key. */
    fun bindAccount(identity: IdentityKeyPair, accountPub: ByteArray): ByteArray = identity.privateKey.calculateSignature(accountPub)

    fun verifyBinding(identityPub: ByteArray, accountPub: ByteArray, signature: ByteArray): Boolean =
        runCatching { IdentityKey(identityPub).publicKey.verifySignature(accountPub, signature) }.getOrDefault(false)
}
```
`PreKeyFactory.kt`:
```kotlin
package app.ottermsg.core.signal

import app.ottermsg.proto.v1.OneTimePreKey
import app.ottermsg.proto.v1.SignedPreKey
import com.google.protobuf.ByteString
import org.signal.libsignal.protocol.ecc.ECKeyPair
import org.signal.libsignal.protocol.kem.KEMKeyPair
import org.signal.libsignal.protocol.kem.KEMKeyType
import org.signal.libsignal.protocol.state.KyberPreKeyRecord
import org.signal.libsignal.protocol.state.PreKeyRecord
import org.signal.libsignal.protocol.state.SignedPreKeyRecord

/** Generates prekeys, stores private parts in [OtterProtocolStore], returns the public protos. */
object PreKeyFactory {
    private fun bs(b: ByteArray) = ByteString.copyFrom(b)

    fun signed(store: OtterProtocolStore, id: Int, nowMs: Long): SignedPreKey {
        val kp = ECKeyPair.generate()
        val pub = kp.publicKey.serialize()
        val sig = store.identityKeyPair.privateKey.calculateSignature(pub)
        store.storeSignedPreKey(id, SignedPreKeyRecord(id, nowMs, kp, sig))
        return SignedPreKey.newBuilder().setId(id).setPublicKey(bs(pub)).setSignature(bs(sig)).build()
    }

    fun kyberLastResort(store: OtterProtocolStore, id: Int, nowMs: Long): SignedPreKey {
        val kp = KEMKeyPair.generate(KEMKeyType.KYBER_1024)
        val pub = kp.publicKey.serialize()
        val sig = store.identityKeyPair.privateKey.calculateSignature(pub)
        store.storeKyberPreKey(id, KyberPreKeyRecord(id, nowMs, kp, sig))
        return SignedPreKey.newBuilder().setId(id).setPublicKey(bs(pub)).setSignature(bs(sig)).build()
    }

    fun oneTime(store: OtterProtocolStore, firstId: Int, count: Int, ownerNode: ByteArray): List<OneTimePreKey> =
        (0 until count).map { i ->
            val id = firstId + i
            val kp = ECKeyPair.generate()
            store.storePreKey(id, PreKeyRecord(id, kp))
            OneTimePreKey.newBuilder().setId(id).setPublicKey(bs(kp.publicKey.serialize())).setOwnerNode(bs(ownerNode)).build()
        }
}
```
`SignalSessions.kt`:
```kotlin
package app.ottermsg.core.signal

import app.ottermsg.proto.v1.Envelope
import org.signal.libsignal.protocol.IdentityKey
import org.signal.libsignal.protocol.SessionBuilder
import org.signal.libsignal.protocol.SessionCipher
import org.signal.libsignal.protocol.SignalProtocolAddress
import org.signal.libsignal.protocol.ecc.ECPublicKey
import org.signal.libsignal.protocol.kem.KEMPublicKey
import org.signal.libsignal.protocol.message.CiphertextMessage
import org.signal.libsignal.protocol.message.PreKeySignalMessage
import org.signal.libsignal.protocol.message.SignalMessage
import app.ottermsg.proto.v1.PreKeyBundle as ProtoBundle
import org.signal.libsignal.protocol.state.PreKeyBundle as SignalBundle

/** 1:1 Signal sessions. Not thread-safe: callers serialize access (core:data uses one Mutex). */
class SignalSessions(private val store: OtterProtocolStore, localUserId: ByteArray, localDevice: Int = 1) {
    private val local = SignalProtocolAddress(localUserId.toHex(), localDevice)

    fun address(userId: ByteArray, device: Int = 1) = SignalProtocolAddress(userId.toHex(), device)

    fun hasSession(remote: SignalProtocolAddress) = store.containsSession(remote)

    fun processBundle(bundle: ProtoBundle, expectedIdentity: ByteArray) {
        check(bundle.identityPub.toByteArray().contentEquals(expectedIdentity)) { "prekey bundle identity differs from directory" }
        val ot = if (bundle.hasOneTime()) bundle.oneTime else null
        val b = SignalBundle(
            bundle.registrationId, bundle.deviceId,
            ot?.id ?: SignalBundle.NULL_PRE_KEY_ID, ot?.let { ECPublicKey(it.publicKey.toByteArray()) },
            bundle.signedPrekey.id, ECPublicKey(bundle.signedPrekey.publicKey.toByteArray()), bundle.signedPrekey.signature.toByteArray(),
            IdentityKey(bundle.identityPub.toByteArray()),
            bundle.kyberPrekey.id, KEMPublicKey(bundle.kyberPrekey.publicKey.toByteArray()), bundle.kyberPrekey.signature.toByteArray(),
        )
        SessionBuilder(store, local, address(bundle.userId.toByteArray(), bundle.deviceId)).process(b)
    }

    fun encrypt(remote: SignalProtocolAddress, plaintext: ByteArray): Pair<Envelope.Kind, ByteArray> {
        val m = SessionCipher(store, local, remote).encrypt(plaintext)
        val kind = if (m.type == CiphertextMessage.PREKEY_TYPE) Envelope.Kind.PREKEY_SIGNAL else Envelope.Kind.SIGNAL
        return kind to m.serialize()
    }

    fun decrypt(remote: SignalProtocolAddress, kind: Envelope.Kind, ciphertext: ByteArray): ByteArray {
        val c = SessionCipher(store, local, remote)
        return when (kind) {
            Envelope.Kind.PREKEY_SIGNAL -> c.decrypt(PreKeySignalMessage(ciphertext))
            Envelope.Kind.SIGNAL -> c.decrypt(SignalMessage(ciphertext))
            else -> throw IllegalArgumentException("unsupported envelope kind $kind")
        }
    }
}
```
- [ ] **Step 3: Extend `scripts/sync-proto.sh`** to also copy vectors into `core/signal/src/test/resources/vectors/`; run it.
- [ ] **Step 4: Run** `./gradlew :core:signal:test` → PASS.
- [ ] **Step 5: Commit** `git add -A && git commit -m "feat(signal): protocol store, identity from seed, prekeys, sessions"`

---

### Task 12: `core:network` — transport, RPC, node API, connection manager

**Goal:** Talk to a node: connect, read `hello`, call methods, receive events, reconnect with backoff.

**Files:**
- Create in `core/network/src/main/kotlin/app/ottermsg/core/network/`: `Transport.kt`, `OkHttpTransport.kt`,
  `Endpoints.kt`, `RpcClient.kt`, `NodeApi.kt`, `ConnectionManager.kt`
- Test: `FakeTransport.kt` (test source), `RpcClientTest.kt`, `EndpointsTest.kt`, `ConnectionManagerTest.kt`

**Acceptance Criteria:**
- [ ] `Endpoints.urls(manifest, allowPlaintext)` → `wss://host:port/path` for `WSS`, `ws://...` for `WS_PLAIN` only when allowed; `REALITY` skipped (M7); order = manifest order (racing is M2)
- [ ] `RpcClient`: correlates responses by id; non-OK → `RpcException(status, error)`; timeout → `RpcTimeoutException`; `hello` exposed as `CompletableDeferred<Hello>`; other events on `events: SharedFlow<Event>`; connection close fails pending calls with `IOException`
- [ ] `RemoteNodeApi` implements `NodeApi` (register, login using hello nonce + `AuthMessage`, manifest, directory, uploadPrekeys, fetchPrekeys, send, ack, createInvite, ping)
- [ ] `ConnectionManager`: tries endpoints in order; after connect waits for hello (10 s) and runs `onConnected(api)`; exposes `state: StateFlow<ConnectionState>` (Offline / Connecting / Online(api) / Waiting(retryAtMs)); exponential backoff 1 s → 60 s with ±20 % jitter, reset after a successful session; `stop()` closes the connection and stops retrying
- [ ] Unit tests use an in-memory `FakeTransport` (no sockets)

**Verify:** `./gradlew :core:network:test`

**Steps:**

- [ ] **Step 1: Implement**

`Transport.kt`:
```kotlin
package app.ottermsg.core.network

import kotlinx.coroutines.channels.ReceiveChannel

interface Transport {
    /** Opens a connection or throws. */
    suspend fun connect(url: String): Connection
}

interface Connection {
    /** Binary frames from the node; closed (possibly with an exception) when the connection ends. */
    val incoming: ReceiveChannel<ByteArray>
    fun send(bytes: ByteArray): Boolean
    fun close()
}
```
`OkHttpTransport.kt`:
```kotlin
package app.ottermsg.core.network

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class OkHttpTransport(
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .pingInterval(60, TimeUnit.SECONDS)
        .build(),
) : Transport {
    override suspend fun connect(url: String): Connection = suspendCancellableCoroutine { cont ->
        val incoming = Channel<ByteArray>(Channel.UNLIMITED)
        val ws = client.newWebSocket(Request.Builder().url(url).build(), object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                if (cont.isActive) cont.resume(OkConnection(webSocket, incoming))
            }
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) { incoming.trySend(bytes.toByteArray()) }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(1000, null); incoming.close() }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { incoming.close() }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                incoming.close(t)
                if (cont.isActive) cont.resumeWithException(t)
            }
        })
        cont.invokeOnCancellation { ws.cancel() }
    }

    private class OkConnection(private val ws: WebSocket, override val incoming: Channel<ByteArray>) : Connection {
        override fun send(bytes: ByteArray) = ws.send(bytes.toByteString())
        override fun close() { ws.close(1000, null) }
    }
}
```
`Endpoints.kt`:
```kotlin
package app.ottermsg.core.network

import app.ottermsg.proto.v1.Endpoint
import app.ottermsg.proto.v1.Manifest

object Endpoints {
    fun urls(manifest: Manifest, allowPlaintext: Boolean): List<String> = manifest.nodesList.flatMap { node ->
        node.endpointsList.mapNotNull { e ->
            when (e.kind) {
                Endpoint.Kind.WSS -> "wss://${e.host}:${e.port}${e.path}"
                Endpoint.Kind.WS_PLAIN -> if (allowPlaintext) "ws://${e.host}:${e.port}${e.path}" else null
                else -> null
            }
        }
    }
}
```
`RpcClient.kt`:
```kotlin
package app.ottermsg.core.network

import app.ottermsg.proto.v1.Event
import app.ottermsg.proto.v1.Frame
import app.ottermsg.proto.v1.Hello
import app.ottermsg.proto.v1.Request
import app.ottermsg.proto.v1.Response
import app.ottermsg.proto.v1.Status
import com.google.protobuf.ByteString
import com.google.protobuf.MessageLite
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

class RpcException(val status: Status, message: String) : Exception("$status: $message")
class RpcTimeoutException(method: String) : IOException("$method timed out")

class RpcClient(private val conn: Connection, scope: CoroutineScope, private val timeoutMs: Long = 15_000) {
    private val nextId = AtomicLong(1)
    private val pending = ConcurrentHashMap<Long, CompletableDeferred<Response>>()
    private val _events = MutableSharedFlow<Event>(extraBufferCapacity = 256)
    val events: SharedFlow<Event> = _events
    val hello = CompletableDeferred<Hello>()
    /** Completes when the connection ends (with the cause, or null on clean close). */
    val closed = CompletableDeferred<Throwable?>()

    private val reader = scope.launch {
        var cause: Throwable? = null
        try {
            for (bytes in conn.incoming) {
                val f = Frame.parseFrom(bytes)
                when (f.kindCase) {
                    Frame.KindCase.RESPONSE -> pending.remove(f.response.id)?.complete(f.response)
                    Frame.KindCase.EVENT ->
                        if (f.event.type == "hello") hello.complete(Hello.parseFrom(f.event.body)) else _events.emit(f.event)
                    else -> {}
                }
            }
        } catch (e: Throwable) {
            cause = e
        } finally {
            val err = IOException("connection closed", cause)
            pending.values.forEach { it.completeExceptionally(err) }
            pending.clear()
            hello.completeExceptionally(err)
            closed.complete(cause)
        }
    }

    suspend fun call(method: String, body: MessageLite): ByteString {
        val id = nextId.getAndIncrement()
        val d = CompletableDeferred<Response>()
        pending[id] = d
        val frame = Frame.newBuilder().setRequest(Request.newBuilder().setId(id).setMethod(method).setBody(body.toByteString())).build()
        if (!conn.send(frame.toByteArray())) {
            pending.remove(id)
            throw IOException("send failed")
        }
        val r = try {
            withTimeout(timeoutMs) { d.await() }
        } catch (e: TimeoutCancellationException) {
            throw RpcTimeoutException(method)
        } finally {
            pending.remove(id)
        }
        if (r.status != Status.STATUS_OK) throw RpcException(r.status, r.error)
        return r.body
    }

    fun close() {
        conn.close()
        reader.cancel()
    }
}
```
`NodeApi.kt`:
```kotlin
package app.ottermsg.core.network

import app.ottermsg.core.crypto.AuthMessage
import app.ottermsg.core.crypto.Ed25519
import app.ottermsg.proto.v1.Empty
import app.ottermsg.proto.v1.Event
import app.ottermsg.proto.v1.LoginRequest
import app.ottermsg.proto.v1.ManifestResponse
import app.ottermsg.proto.v1.PreKeyBundle
import app.ottermsg.proto.v1.PreKeyFetchRequest
import app.ottermsg.proto.v1.Record
import app.ottermsg.proto.v1.RecordBatch
import app.ottermsg.proto.v1.RecordRequest
import app.ottermsg.proto.v1.RegisterRequest
import com.google.protobuf.ByteString
import kotlinx.coroutines.flow.Flow

/** The node's client API (docs/02 §4). Faked in core:data tests. */
interface NodeApi {
    val events: Flow<Event>
    suspend fun register(req: RegisterRequest)
    suspend fun login(userId: ByteArray, account: Ed25519.KeyPair)
    suspend fun manifest(): Record
    suspend fun directory(): List<Record>
    suspend fun uploadPrekeys(record: Record)
    suspend fun fetchPrekeys(userId: ByteArray, device: Int = 1): PreKeyBundle
    suspend fun send(envelope: Record)
    suspend fun ack(ack: Record)
    suspend fun createInvite(invite: Record)
    suspend fun ping()
}

class RemoteNodeApi(private val rpc: RpcClient, private val clock: () -> Long = System::currentTimeMillis) : NodeApi {
    override val events: Flow<Event> = rpc.events
    private fun req(r: Record) = RecordRequest.newBuilder().setRecord(r).build()

    override suspend fun register(req: RegisterRequest) { rpc.call("register", req) }

    override suspend fun login(userId: ByteArray, account: Ed25519.KeyPair) {
        val h = rpc.hello.await()
        val ts = clock()
        val sig = account.sign(AuthMessage.build(h.nodeId.toByteArray(), h.nonce.toByteArray(), ts))
        rpc.call("auth.login", LoginRequest.newBuilder().setUserId(ByteString.copyFrom(userId)).setDeviceId(1)
            .setTsMs(ts).setSignature(ByteString.copyFrom(sig)).build())
    }

    override suspend fun manifest(): Record = ManifestResponse.parseFrom(rpc.call("manifest.get", Empty.getDefaultInstance())).manifest
    override suspend fun directory(): List<Record> = RecordBatch.parseFrom(rpc.call("directory.sync", Empty.getDefaultInstance())).recordsList
    override suspend fun uploadPrekeys(record: Record) { rpc.call("prekeys.upload", req(record)) }
    override suspend fun fetchPrekeys(userId: ByteArray, device: Int): PreKeyBundle =
        PreKeyBundle.parseFrom(rpc.call("prekeys.fetch", PreKeyFetchRequest.newBuilder().setUserId(ByteString.copyFrom(userId)).setDeviceId(device).build()))
    override suspend fun send(envelope: Record) { rpc.call("msg.send", req(envelope)) }
    override suspend fun ack(ack: Record) { rpc.call("msg.ack", req(ack)) }
    override suspend fun createInvite(invite: Record) { rpc.call("invite.create", req(invite)) }
    override suspend fun ping() { rpc.call("ping", Empty.getDefaultInstance()) }
}
```
`ConnectionManager.kt`:
```kotlin
package app.ottermsg.core.network

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlin.random.Random

sealed interface ConnectionState {
    data object Offline : ConnectionState
    data object Connecting : ConnectionState
    data class Online(val api: NodeApi, val url: String) : ConnectionState
    data class Waiting(val retryAtMs: Long, val reason: String) : ConnectionState
}

/**
 * Keeps one node connection alive while started. [onConnected] runs after hello (e.g. login + initial sync);
 * if it throws, the connection is dropped and retried.
 */
class ConnectionManager(
    private val transport: Transport,
    private val urls: suspend () -> List<String>,
    private val scope: CoroutineScope,
    private val onConnected: suspend (NodeApi) -> Unit,
    private val clock: () -> Long = System::currentTimeMillis,
    private val random: Random = Random.Default,
) {
    private val _state = MutableStateFlow<ConnectionState>(ConnectionState.Offline)
    val state: StateFlow<ConnectionState> = _state
    private var job: Job? = null
    private var rpc: RpcClient? = null

    @Synchronized fun start() {
        if (job?.isActive == true) return
        job = scope.launch { loop() }
    }

    @Synchronized fun stop() {
        job?.cancel(); job = null
        rpc?.close(); rpc = null
        _state.value = ConnectionState.Offline
    }

    /** Skips the current backoff wait (e.g. network became available). */
    fun retryNow() { if (_state.value is ConnectionState.Waiting) { stop(); start() } }

    private suspend fun loop() {
        var backoffMs = 1_000L
        while (scope.isActive) {
            _state.value = ConnectionState.Connecting
            var lastError = "no endpoints"
            for (url in urls()) {
                val r = try {
                    val conn = transport.connect(url)
                    RpcClient(conn, scope).also { rpc = it }
                } catch (e: Exception) { lastError = e.message ?: e.javaClass.simpleName; continue }
                try {
                    withTimeout(10_000) { r.hello.await() }
                    val api = RemoteNodeApi(r, clock)
                    onConnected(api)
                    _state.value = ConnectionState.Online(api, url)
                    backoffMs = 1_000L
                    r.closed.await()
                    lastError = "connection lost"
                } catch (e: Exception) {
                    if (!scope.isActive) return
                    lastError = e.message ?: e.javaClass.simpleName
                } finally {
                    r.close(); rpc = null
                }
                break // after a session ended (or failed after connect), restart from the first endpoint after backoff
            }
            val jitter = 1.0 + (random.nextDouble() - 0.5) * 0.4
            val wait = (backoffMs * jitter).toLong()
            _state.value = ConnectionState.Waiting(clock() + wait, lastError)
            delay(wait)
            backoffMs = (backoffMs * 2).coerceAtMost(60_000)
        }
    }
}
```

- [ ] **Step 2: Tests**

`FakeTransport.kt` (src/test):
```kotlin
package app.ottermsg.core.network

import app.ottermsg.proto.v1.Event
import app.ottermsg.proto.v1.Frame
import app.ottermsg.proto.v1.Hello
import app.ottermsg.proto.v1.Request
import app.ottermsg.proto.v1.Response
import app.ottermsg.proto.v1.Status
import com.google.protobuf.ByteString
import kotlinx.coroutines.channels.Channel
import java.io.IOException

/** In-memory "node": answers requests with [handler], can push events and drop the connection. */
class FakeTransport(var failUrls: Set<String> = emptySet(), val handler: (Request) -> Response) : Transport {
    val connections = mutableListOf<FakeConnection>()
    override suspend fun connect(url: String): Connection {
        if (url in failUrls) throw IOException("refused $url")
        return FakeConnection(handler).also { connections += it; it.push(helloEvent()) }
    }
    private fun helloEvent() = Frame.newBuilder().setEvent(Event.newBuilder().setType("hello")
        .setBody(Hello.newBuilder().setProtocolVersion(1).setNodeId(ByteString.copyFrom(ByteArray(16) { 1 }))
            .setNonce(ByteString.copyFrom(ByteArray(32) { 2 })).build().toByteString())).build()

    class FakeConnection(private val handler: (Request) -> Response) : Connection {
        override val incoming = Channel<ByteArray>(Channel.UNLIMITED)
        var closed = false
        fun push(f: Frame) { incoming.trySend(f.toByteArray()) }
        fun drop() { incoming.close(IOException("dropped")) }
        override fun send(bytes: ByteArray): Boolean {
            if (closed) return false
            val req = Frame.parseFrom(bytes).request
            push(Frame.newBuilder().setResponse(handler(req).toBuilder().setId(req.id)).build())
            return true
        }
        override fun close() { closed = true; incoming.close() }
    }
}

fun ok(body: ByteString = ByteString.EMPTY): Response = Response.newBuilder().setStatus(Status.STATUS_OK).setBody(body).build()
fun err(s: Status, msg: String): Response = Response.newBuilder().setStatus(s).setError(msg).build()
```
`RpcClientTest.kt`:
```kotlin
package app.ottermsg.core.network

import app.ottermsg.proto.v1.Empty
import app.ottermsg.proto.v1.Event
import app.ottermsg.proto.v1.Frame
import app.ottermsg.proto.v1.Status
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.IOException

class RpcClientTest {
    @Test fun callAndHello() = runTest {
        val t = FakeTransport { r -> if (r.method == "ping") ok() else err(Status.STATUS_INVALID, "nope") }
        val rpc = RpcClient(t.connect("x"), backgroundScope)
        assertEquals(1, rpc.hello.await().protocolVersion)
        rpc.call("ping", Empty.getDefaultInstance())
        val e = runCatching { rpc.call("bogus", Empty.getDefaultInstance()) }.exceptionOrNull() as RpcException
        assertEquals(Status.STATUS_INVALID, e.status)
    }

    @Test fun eventsAndClose() = runTest {
        val t = FakeTransport { ok() }
        val conn = t.connect("x") as FakeTransport.FakeConnection
        val rpc = RpcClient(conn, backgroundScope)
        val ev = async { rpc.events.first() }
        rpc.hello.await()
        conn.push(Frame.newBuilder().setEvent(Event.newBuilder().setType("directory")).build())
        assertEquals("directory", ev.await().type)
        conn.drop()
        rpc.closed.await()
        assertThrows(IOException::class.java) { kotlinx.coroutines.runBlocking { rpc.call("ping", Empty.getDefaultInstance()) } }
    }
}
```
`EndpointsTest.kt`: manifest with one node having WSS, WS_PLAIN and REALITY endpoints →
`urls(m, false) == listOf("wss://a:443/p")`, `urls(m, true)` additionally contains `"ws://b:8080/q"`, REALITY never.
`ConnectionManagerTest.kt` (use `runTest`, `backgroundScope`, virtual time):
```kotlin
package app.ottermsg.core.network

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

class ConnectionManagerTest {
    @Test fun failsOverAndReconnects() = runTest {
        val t = FakeTransport(failUrls = setOf("bad")) { ok() }
        var logins = 0
        val cm = ConnectionManager(t, { listOf("bad", "good") }, backgroundScope, { logins++ }, { currentTime }, Random(1))
        cm.start()
        val online = cm.state.first { it is ConnectionState.Online } as ConnectionState.Online
        assertEquals("good", online.url)
        assertEquals(1, logins)
        (t.connections.last()).drop()
        cm.state.first { it is ConnectionState.Waiting }
        advanceTimeBy(2_000)
        cm.state.first { it is ConnectionState.Online }
        assertEquals(2, logins)
        cm.stop()
        assertTrue(cm.state.value is ConnectionState.Offline)
    }

    @Test fun backoffWhenAllFail() = runTest {
        val t = FakeTransport(failUrls = setOf("a")) { ok() }
        val cm = ConnectionManager(t, { listOf("a") }, backgroundScope, {}, { currentTime }, Random(1))
        cm.start()
        val w1 = cm.state.first { it is ConnectionState.Waiting } as ConnectionState.Waiting
        assertTrue(w1.retryAtMs - currentTime in 800..1200)
        advanceTimeBy(1_300)
        val w2 = cm.state.first { it is ConnectionState.Waiting && it.retryAtMs > w1.retryAtMs } as ConnectionState.Waiting
        assertTrue(w2.retryAtMs - currentTime in 1600..2400)
        cm.stop()
    }
}
```
- [ ] **Step 3: Run** `./gradlew :core:network:test` → PASS.
- [ ] **Step 4: Commit** `git add -A && git commit -m "feat(network): okhttp transport, rpc client, node api, connection manager"`

---

### Task 13: `core:database` v2 — messaging tables

**Goal:** Persistent model for contacts, conversations, messages, outbox, dedup, Signal state and settings.

**Files:**
- Create in `core/database/src/main/kotlin/app/ottermsg/core/database/`:
  `entity/{ContactEntity,ConversationEntity,MessageEntity,OutboxEntity,SeenEnvelopeEntity,SignalKvEntity,SettingEntity}.kt`,
  `dao/{ContactDao,ConversationDao,MessageDao,OutboxDao,SeenEnvelopeDao,SignalKvDao,SettingsDao}.kt`,
  `model/{ConversationSummary,MessageStatus}.kt`
- Modify: `OtterDatabase.kt` (version 2, auto-migration 1→2), `di/DatabaseModule.kt` (provide new DAOs)
- Test: `core/database/src/test/.../MessagingDaoTest.kt`, `MigrationTest.kt`

**Acceptance Criteria:**
- [ ] Schema per the entities below; `schemas/.../2.json` exported; `AutoMigration(from = 1, to = 2)` verified by `MigrationTestHelper` (Robolectric)
- [ ] `ConversationDao.getOrCreateDirect(peer, title)` is idempotent (unique index on `peer_user_id`)
- [ ] `MessageDao.insert` ignores a duplicate `message_id` (returns -1)
- [ ] `MessageDao.advanceStatus(messageId, status)` only moves forward (PENDING < SENT < DELIVERED < READ) and never changes FAILED or incoming messages
- [ ] `ConversationDao.observeSummaries()` returns title, last message text/time/status/direction, unread count, newest first
- [ ] `SeenEnvelopeDao.insert` returns -1 for an already seen key; `prune(now)` deletes expired rows
- [ ] `OutboxDao.due(now)` ordered by id; `SignalKvDao` blocking get/put/delete/keys

**Verify:** `./gradlew :core:database:testDebugUnitTest`

**Steps:**

- [ ] **Step 1: Entities**
```kotlin
// model/MessageStatus.kt
package app.ottermsg.core.database.model
object MessageStatus { const val PENDING = 0; const val SENT = 1; const val DELIVERED = 2; const val READ = 3; const val FAILED = 4 }
object MessageKind { const val TEXT = 0; const val SYSTEM_UNDECRYPTABLE = 1 }
```
```kotlin
// entity/ContactEntity.kt
@Entity(tableName = "contacts")
data class ContactEntity(
    @PrimaryKey @ColumnInfo(name = "user_id") val userId: ByteArray,
    val username: String,
    @ColumnInfo(name = "display_name") val displayName: String,
    @ColumnInfo(name = "account_pub") val accountPub: ByteArray,
    @ColumnInfo(name = "identity_pub") val identityPub: ByteArray,
    val verified: Boolean,
    @ColumnInfo(name = "identity_changed") val identityChanged: Boolean,
    val revoked: Boolean,
    @ColumnInfo(name = "entry_version") val entryVersion: Long,
)
// entity/ConversationEntity.kt
@Entity(tableName = "conversations", indices = [Index(value = ["peer_user_id"], unique = true)])
data class ConversationEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    @ColumnInfo(name = "peer_user_id") val peerUserId: ByteArray,
    val title: String,
    @ColumnInfo(name = "last_activity_ms") val lastActivityMs: Long,
    val unread: Int = 0,
    val draft: String = "",
)
// entity/MessageEntity.kt
@Entity(tableName = "messages",
    indices = [Index(value = ["message_id"], unique = true), Index(value = ["conversation_id", "sent_ms"])])
data class MessageEntity(
    @PrimaryKey(autoGenerate = true) @ColumnInfo(name = "local_id") val localId: Long = 0,
    @ColumnInfo(name = "message_id") val messageId: ByteArray,
    @ColumnInfo(name = "conversation_id") val conversationId: Long,
    @ColumnInfo(name = "sender_id") val senderId: ByteArray,
    val outgoing: Boolean,
    @ColumnInfo(name = "sent_ms") val sentMs: Long,
    @ColumnInfo(name = "received_ms") val receivedMs: Long,
    val body: String,
    val status: Int,
    val kind: Int = MessageKind.TEXT,
    @ColumnInfo(name = "read_receipt_sent") val readReceiptSent: Boolean = false,
)
// entity/OutboxEntity.kt — content is plaintext Content bytes (DB is SQLCipher-encrypted);
// record_bytes is set once encrypted+signed so retries resend the identical record.
@Entity(tableName = "outbox")
data class OutboxEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    @ColumnInfo(name = "recipient_user_id") val recipientUserId: ByteArray,
    @ColumnInfo(name = "content_bytes") val contentBytes: ByteArray,
    @ColumnInfo(name = "message_local_id") val messageLocalId: Long?,
    val urgent: Boolean,
    @ColumnInfo(name = "record_bytes") val recordBytes: ByteArray? = null,
    val attempts: Int = 0,
    @ColumnInfo(name = "next_attempt_ms") val nextAttemptMs: Long = 0,
    @ColumnInfo(name = "created_ms") val createdMs: Long,
)
// entity/SeenEnvelopeEntity.kt
@Entity(tableName = "seen_envelopes")
data class SeenEnvelopeEntity(@PrimaryKey @ColumnInfo(name = "record_key") val recordKey: ByteArray, @ColumnInfo(name = "until_ms") val untilMs: Long)
// entity/SignalKvEntity.kt
@Entity(tableName = "signal_kv", primaryKeys = ["table_id", "k"])
data class SignalKvEntity(@ColumnInfo(name = "table_id") val tableId: Int, val k: String, val v: ByteArray)
// entity/SettingEntity.kt
@Entity(tableName = "settings")
data class SettingEntity(@PrimaryKey val key: String, val value: ByteArray)
```
(each file with its `package app.ottermsg.core.database.entity` and `androidx.room.*` imports.)

- [ ] **Step 2: DAOs**
```kotlin
@Dao interface ContactDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun upsert(c: ContactEntity)
    @Query("SELECT * FROM contacts WHERE user_id = :id") suspend fun get(id: ByteArray): ContactEntity?
    @Query("SELECT * FROM contacts WHERE revoked = 0 ORDER BY display_name COLLATE NOCASE") fun observeAll(): Flow<List<ContactEntity>>
    @Query("UPDATE contacts SET identity_changed = 1, verified = 0 WHERE user_id = :id") suspend fun markIdentityChanged(id: ByteArray)
}

data class ConversationSummary(
    val id: Long, val title: String, @ColumnInfo(name = "peer_user_id") val peerUserId: ByteArray,
    val unread: Int, @ColumnInfo(name = "last_activity_ms") val lastActivityMs: Long,
    @ColumnInfo(name = "last_body") val lastBody: String?, @ColumnInfo(name = "last_status") val lastStatus: Int?,
    @ColumnInfo(name = "last_outgoing") val lastOutgoing: Boolean?, @ColumnInfo(name = "last_kind") val lastKind: Int?,
)

@Dao interface ConversationDao {
    @Query("SELECT * FROM conversations WHERE peer_user_id = :peer") suspend fun byPeer(peer: ByteArray): ConversationEntity?
    @Query("SELECT * FROM conversations WHERE id = :id") suspend fun get(id: Long): ConversationEntity?
    @Query("SELECT * FROM conversations WHERE id = :id") fun observe(id: Long): Flow<ConversationEntity?>
    @Insert(onConflict = OnConflictStrategy.IGNORE) suspend fun insert(c: ConversationEntity): Long
    @Transaction suspend fun getOrCreateDirect(peer: ByteArray, title: String, nowMs: Long): Long =
        byPeer(peer)?.id ?: insert(ConversationEntity(peerUserId = peer, title = title, lastActivityMs = nowMs)).takeIf { it > 0 } ?: byPeer(peer)!!.id
    @Query("UPDATE conversations SET last_activity_ms = MAX(last_activity_ms, :ms) WHERE id = :id") suspend fun touch(id: Long, ms: Long)
    @Query("UPDATE conversations SET unread = unread + 1 WHERE id = :id") suspend fun incrementUnread(id: Long)
    @Query("UPDATE conversations SET unread = 0 WHERE id = :id") suspend fun clearUnread(id: Long)
    @Query("UPDATE conversations SET draft = :draft WHERE id = :id") suspend fun setDraft(id: Long, draft: String)
    @Query("UPDATE conversations SET title = :title WHERE peer_user_id = :peer") suspend fun setTitle(peer: ByteArray, title: String)
    @Query("""
        SELECT c.id, c.title, c.peer_user_id, c.unread, c.last_activity_ms,
               m.body AS last_body, m.status AS last_status, m.outgoing AS last_outgoing, m.kind AS last_kind
        FROM conversations c
        LEFT JOIN messages m ON m.local_id = (SELECT local_id FROM messages WHERE conversation_id = c.id ORDER BY sent_ms DESC, local_id DESC LIMIT 1)
        ORDER BY c.last_activity_ms DESC""")
    fun observeSummaries(): Flow<List<ConversationSummary>>
}

@Dao interface MessageDao {
    @Insert(onConflict = OnConflictStrategy.IGNORE) suspend fun insert(m: MessageEntity): Long
    @Query("SELECT * FROM messages WHERE conversation_id = :cid ORDER BY sent_ms, local_id") fun observe(cid: Long): Flow<List<MessageEntity>>
    @Query("SELECT * FROM messages WHERE local_id = :id") suspend fun get(id: Long): MessageEntity?
    @Query("""UPDATE messages SET status = :status WHERE message_id = :messageId AND outgoing = 1
              AND status < :status AND status != ${MessageStatus.FAILED}""")
    suspend fun advanceStatus(messageId: ByteArray, status: Int): Int
    @Query("""UPDATE messages SET status = :status WHERE local_id = :localId AND status < :status AND status != ${MessageStatus.FAILED}""")
    suspend fun advanceStatusLocal(localId: Long, status: Int): Int
    @Query("UPDATE messages SET status = ${MessageStatus.FAILED} WHERE local_id = :localId") suspend fun markFailed(localId: Long)
    @Query("SELECT * FROM messages WHERE conversation_id = :cid AND outgoing = 0 AND kind = ${MessageKind.TEXT} AND read_receipt_sent = 0")
    suspend fun unreadReceiptsPending(cid: Long): List<MessageEntity>
    @Query("UPDATE messages SET read_receipt_sent = 1 WHERE local_id IN (:ids)") suspend fun markReadReceiptSent(ids: List<Long>)
    @Query("DELETE FROM messages WHERE local_id = :localId") suspend fun delete(localId: Long)
}

@Dao interface OutboxDao {
    @Insert suspend fun insert(o: OutboxEntity): Long
    @Query("SELECT * FROM outbox WHERE next_attempt_ms <= :now ORDER BY id LIMIT :limit") suspend fun due(now: Long, limit: Int = 50): List<OutboxEntity>
    @Query("SELECT MIN(next_attempt_ms) FROM outbox") suspend fun nextAttemptAt(): Long?
    @Query("UPDATE outbox SET record_bytes = :record WHERE id = :id") suspend fun setRecord(id: Long, record: ByteArray)
    @Query("UPDATE outbox SET attempts = :attempts, next_attempt_ms = :next WHERE id = :id") suspend fun reschedule(id: Long, attempts: Int, next: Long)
    @Query("DELETE FROM outbox WHERE id = :id") suspend fun delete(id: Long)
}

@Dao interface SeenEnvelopeDao {
    @Insert(onConflict = OnConflictStrategy.IGNORE) suspend fun insert(e: SeenEnvelopeEntity): Long
    @Query("DELETE FROM seen_envelopes WHERE until_ms < :now") suspend fun prune(now: Long)
}

@Dao interface SignalKvDao {   // blocking: called from libsignal callbacks on a background thread
    @Query("SELECT v FROM signal_kv WHERE table_id = :t AND k = :k") fun get(t: Int, k: String): ByteArray?
    @Insert(onConflict = OnConflictStrategy.REPLACE) fun put(e: SignalKvEntity)
    @Query("DELETE FROM signal_kv WHERE table_id = :t AND k = :k") fun delete(t: Int, k: String)
    @Query("SELECT k FROM signal_kv WHERE table_id = :t") fun keys(t: Int): List<String>
}

@Dao interface SettingsDao {
    @Query("SELECT value FROM settings WHERE `key` = :key") suspend fun get(key: String): ByteArray?
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun put(s: SettingEntity)
}
```

- [ ] **Step 3: Database** — `@Database(entities = [AccountEntity, ManifestEntity, ContactEntity, ConversationEntity,
MessageEntity, OutboxEntity, SeenEnvelopeEntity, SignalKvEntity, SettingEntity], version = 2, exportSchema = true,
autoMigrations = [AutoMigration(from = 1, to = 2)])` with abstract accessors for every DAO. `DatabaseModule` gets
`@Provides` for each DAO. Add `testImplementation(libs.room.testing)` to `core/database`.

- [ ] **Step 4: Tests** — `MessagingDaoTest` (Robolectric, in-memory) covering each acceptance criterion
(insert duplicate message → -1; advanceStatus forward-only incl. FAILED & incoming untouched; getOrCreateDirect twice same id;
summaries ordering and last message; seen insert twice → -1; prune). `MigrationTest`:
```kotlin
@RunWith(RobolectricTestRunner::class)
class MigrationTest {
    @get:Rule val helper = MigrationTestHelper(InstrumentationRegistry.getInstrumentation(), OtterDatabase::class.java)
    @Test fun migrate1To2() {
        helper.createDatabase("m.db", 1).use { it.execSQL("INSERT INTO manifest(version, raw) VALUES (1, x'01')") }
        helper.runMigrationsAndValidate("m.db", 2, true).use { db ->
            db.query("SELECT COUNT(*) FROM manifest").use { c -> c.moveToFirst(); assertEquals(1, c.getInt(0)) }
        }
    }
}
```
(needs `testImplementation("androidx.test:core:1.7.0")`, `androidx.test.ext:junit` for `InstrumentationRegistry` under Robolectric, and
`android.sourceSets["test"].assets.srcDir("$projectDir/schemas")` so the helper finds `1.json`.)

- [ ] **Step 5: Run** `./gradlew :core:database:testDebugUnitTest` → PASS.
- [ ] **Step 6: Commit** `git add -A && git commit -m "feat(database): v2 messaging schema with auto-migration"`

---

### Task 14: `core:data` — account, registration, directory, messaging engine

**Goal:** All non-UI client logic: create an account from an invite, keep the directory, send/receive/ack
messages, receipts, prekey refill, invites, foreground sync.

**Files (all under `core/data/src/main/kotlin/app/ottermsg/core/data/`):**
- `Clock.kt` — `fun interface Clock { fun now(): Long }`
- `account/SeedVault.kt`, `account/LocalAccount.kt`, `account/AccountRepository.kt`
- `settings/Settings.kt` (typed wrapper over `SettingsDao`: registration id, next one-time prekey id, network pub)
- `signal/RoomSignalKeyValue.kt`, `signal/SignalService.kt` (one `Mutex`, lazily built `OtterProtocolStore` + `SignalSessions`)
- `directory/DirectorySync.kt`
- `registration/Registration.kt` (+ `RegistrationError` sealed class)
- `messaging/Outbox.kt`, `messaging/MailboxReceiver.kt`, `messaging/MessageRepository.kt`, `messaging/Receipts.kt`
- `invite/InviteRepository.kt`
- `sync/SyncEngine.kt`, `sync/ForegroundSync.kt`
- `di/DataModule.kt`
- Tests: `src/test/.../FakeNode.kt`, `TestGraph.kt`, `RegistrationTest.kt`, `MessagingFlowTest.kt`, `DirectorySyncTest.kt`

**Acceptance Criteria:**
- [ ] **Registration** (`Registration.register(link, displayName, username, seed)`): decodes the invite, verifies the manifest against the
  invite's `network_pub`; derives account/identity keys from the seed; builds DIRECTORY_ENTRY (identity binding signature, `can_invite = true`),
  PREKEYS (signed id 1, Kyber id 1, 50 one-time keys per manifest node with that node as owner) and INVITE_USED; connects via
  `Endpoints.urls(manifest, allowPlaintext)`; calls `register`; **only on success** persists account (seed wrapped by Keystore key `otter_seed_kek`),
  settings, manifest, Signal state (copied from an in-memory store) and the inviter as a **verified** contact. Errors map to
  `RegistrationError.{UsernameTaken, InviteUsed, InviteExpired, InviteUnknown, BadLink, Network, Unknown}` (from `RpcException` status + message)
- [ ] Username rules checked locally before network: `^[a-z0-9_]{3,32}$`; display name 1–64 chars trimmed
- [ ] **DirectorySync** verifies each entry (Ed25519 record signature by `account_pub`, `user_id == id16(account_pub)`, identity binding);
  skips self and invalid entries; upserts contacts; identity change vs. stored ⇒ `identity_changed = true, verified = false`; inviter stays verified only if keys match the invite
- [ ] **Send** (`MessageRepository.sendText(conversationId, text)`): one DB transaction inserts the message (PENDING, random 16-byte `message_id`)
  and the outbox item, clears the draft; text trimmed, empty → no-op
- [ ] **Outbox** (serialised, runs when online): fetch prekeys + build session if none; encrypt once and persist the signed ENVELOPE in `record_bytes`
  before the first send; `send` OK ⇒ delete item, message → SENT; `STATUS_INVALID/NOT_FOUND/REVOKED` ⇒ message FAILED + delete; other errors ⇒
  backoff `min(2^attempts s, 5 min)`
- [ ] **MailboxReceiver**: per record — dedup by record key (`seen_envelopes`, 30 d); unknown sender ⇒ directory sync once, still unknown ⇒ leave un-acked;
  bad record signature ⇒ drop + ack; decrypt failure ⇒ system message "undecryptable" + ack; `DataMessage` ⇒ message + unread++ + queue DELIVERED receipt (urgent=false);
  `ReceiptMessage` ⇒ `advanceStatus`; persist before ack; one ACK record per batch
- [ ] **Receipts**: `markConversationRead(id)` clears unread and queues one READ receipt per conversation for messages without `read_receipt_sent`
- [ ] **Prekeys**: on `prekeys_low` (and on login when `settings.prekeysLow` flag is set) upload 50 new one-time keys owned by the current node, ids continuing from settings
- [ ] **InviteRepository.create()**: publishes a 7-day INVITE and returns `otter://join/...` with inviter id, keys, display name and latest manifest
- [ ] **SyncEngine**: owns `ConnectionManager` (urls from the latest stored manifest); `onConnected` = login → directory sync → prekey check →
  start collecting events (`envelopes` → receiver, `directory` → sync, `prekeys_low` → refill) → kick outbox; exposes `connection: StateFlow<ConnectionState>`
- [ ] **ForegroundSync**: `ProcessLifecycleOwner` ON_START → `start()`, ON_STOP → `stop()` after 10 s unless restarted
- [ ] **Tests** (Robolectric + real libsignal + `FakeNode` implementing `NodeApi` in memory, two independent client graphs with in-memory Room):
  bootstrap registration → invite → second registration → B sends "Привет" → A gets text, B sees DELIVERED → A marks read → B sees READ;
  A offline while B sends 3 messages → A connects → all 3 in order; duplicate delivery of the same record → one message; receipts never generate receipts;
  registration with taken username → `UsernameTaken` and nothing persisted

**Verify:** `./gradlew :core:data:testDebugUnitTest`

**Steps:**

- [ ] **Step 1: Write the test harness first** — `FakeNode` keeps directory records, prekey bundles (consuming one-time keys), invites,
mailboxes per user and per-client event flows; validates record signatures with `RecordCodec.verify` (enough for tests); `register`
applies the same checks as the Go service (invite exists/unused, username free). `TestGraph` builds one client:
in-memory `OtterDatabase` (Robolectric `Room.inMemoryDatabaseBuilder`, `allowMainThreadQueries` not needed), `FakeKeyWrapper` (XOR),
fixed `Clock`, all data classes wired by hand, and a `FakeNodeApi` view bound to that client. Then write `MessagingFlowTest` and
`RegistrationTest` covering the acceptance list. They fail to compile until Step 2–5 exist.

- [ ] **Step 2: Account & settings**
```kotlin
// account/LocalAccount.kt
data class LocalAccount(
    val userId: ByteArray, val username: String, val displayName: String,
    val seed: ByteArray, val accountKey: Ed25519.KeyPair, val identity: IdentityKeyPair, val registrationId: Int,
)
// account/SeedVault.kt — wraps/unwraps the seed with its own Keystore key
class SeedVault(private val wrapper: KeyWrapper) {
    fun wrap(seed: ByteArray) = wrapper.wrap(seed)
    fun unwrap(enc: ByteArray) = wrapper.unwrap(enc)
}
// account/AccountRepository.kt
@Singleton class AccountRepository @Inject constructor(
    private val accountDao: AccountDao, private val settings: Settings, private val vault: SeedVault,
) {
    private val _account = MutableStateFlow<LocalAccount?>(null)
    val account: StateFlow<LocalAccount?> = _account
    private val loadMutex = Mutex()

    /** Loads the stored account (if any). Safe to call repeatedly. */
    suspend fun load(): LocalAccount? = loadMutex.withLock {
        _account.value ?: accountDao.get()?.let { e ->
            val seed = vault.unwrap(e.seedEnc)
            LocalAccount(e.userId, e.username, e.displayName, seed, SeedKeys.accountKeyPair(seed),
                IdentityKeys.fromSeed(seed), settings.registrationId()).also { _account.value = it }
        }
    }
    fun require(): LocalAccount = checkNotNull(_account.value) { "no account loaded" }
}
```
`Settings` keys: `registration_id` (Int), `next_one_time_id` (Int), `network_pub` (bytes), `prekeys_low` (Boolean), stored as bytes
(`ByteBuffer` for ints); expose suspend getters/setters.

- [ ] **Step 3: Signal adapter**
```kotlin
// signal/RoomSignalKeyValue.kt
class RoomSignalKeyValue(private val dao: SignalKvDao) : SignalKeyValue {
    override fun get(table: SignalKeyValue.Table, key: String) = dao.get(table.id, key)
    override fun put(table: SignalKeyValue.Table, key: String, value: ByteArray) = dao.put(SignalKvEntity(table.id, key, value))
    override fun delete(table: SignalKeyValue.Table, key: String) = dao.delete(table.id, key)
    override fun keys(table: SignalKeyValue.Table) = dao.keys(table.id)
}
// signal/SignalService.kt — all libsignal use goes through withSessions { } on Dispatchers.IO under one Mutex
@Singleton class SignalService @Inject constructor(
    private val accounts: AccountRepository, private val kvDao: SignalKvDao, private val contacts: ContactDao,
    @ApplicationScope private val appScope: CoroutineScope,
) {
    private val mutex = Mutex()
    private var cached: Pair<OtterProtocolStore, SignalSessions>? = null
    suspend fun <T> withSessions(block: (OtterProtocolStore, SignalSessions) -> T): T = mutex.withLock {
        withContext(Dispatchers.IO) {
            val (store, sessions) = cached ?: run {
                val a = accounts.require()
                val store = OtterProtocolStore(a.identity, a.registrationId, RoomSignalKeyValue(kvDao)) { addr ->
                    appScope.launch { contacts.markIdentityChanged(addr.name.hexToBytes()) }
                }
                (store to SignalSessions(store, a.userId)).also { cached = it }
            }
            block(store, sessions)
        }
    }
}
```
Provide `@ApplicationScope CoroutineScope` (`SupervisorJob() + Dispatchers.Default`) in `DataModule`.

- [ ] **Step 4: Registration** — implement exactly the acceptance list. Key code:
```kotlin
class Registration @Inject constructor(
    private val db: OtterDatabase, private val transport: Transport, private val vault: SeedVault,
    private val accounts: AccountRepository, private val clock: Clock, @AllowPlaintext private val allowPlaintext: Boolean,
) {
    suspend fun register(link: String, displayName: String, username: String, seed: ByteArray): Result<Unit> = runCatching {
        val name = displayName.trim(); val user = username.trim().lowercase()
        if (!USERNAME.matches(user)) throw RegistrationError.BadUsername
        if (name.isEmpty() || name.length > 64) throw RegistrationError.BadDisplayName
        val bundle = try { InviteLink.decode(link) } catch (e: IllegalArgumentException) { throw RegistrationError.BadLink }
        val networkPub = bundle.networkPub.toByteArray()
        val manifest = try { ManifestVerifier.verify(bundle.manifest.toByteArray(), networkPub, 0) } catch (e: ManifestException) { throw RegistrationError.BadLink }

        val account = SeedKeys.accountKeyPair(seed)
        val userId = Ids.id16(account.publicKey)
        val identity = IdentityKeys.fromSeed(seed)
        val registrationId = SecureRandom().nextInt(16380) + 1
        val mem = InMemorySignalKeyValue()
        val store = OtterProtocolStore(identity, registrationId, mem)
        val now = clock.now()
        val signed = PreKeyFactory.signed(store, 1, now)
        val kyber = PreKeyFactory.kyberLastResort(store, 1, now)
        var nextId = 1
        val oneTime = manifest.nodesList.flatMap { n -> PreKeyFactory.oneTime(store, nextId, 50, n.nodeId.toByteArray()).also { nextId += 50 } }

        val entry = DirectoryEntry.newBuilder().setUserId(bs(userId)).setUsername(user).setDisplayName(name)
            .setAccountPub(bs(account.publicKey)).setIdentityPub(bs(identity.publicKey.serialize()))
            .setIdentitySig(bs(IdentityKeys.bindAccount(identity, account.publicKey))).setVersion(1).setCanInvite(true).build()
        val prekeys = PreKeys.newBuilder().setDeviceId(1).setRegistrationId(registrationId)
            .setSignedPrekey(signed).setKyberPrekey(kyber).addAllOneTime(oneTime).build()
        val inviteId = MessageDigest.getInstance("SHA-256").digest(bundle.secret.toByteArray())
        val used = InviteUsed.newBuilder().setInviteId(bs(inviteId)).setUserId(bs(userId)).build()
        fun rec(t: RecordType, p: MessageLite) = RecordCodec.sign(RecordCodec.body(t, userId, p.toByteArray(), createdMs = now), account)
        val req = RegisterRequest.newBuilder().setInviteSecret(bundle.secret)
            .setDirectoryEntry(rec(RecordType.DIRECTORY_ENTRY, entry)).setPrekeys(rec(RecordType.PREKEYS, prekeys))
            .setInviteUsed(rec(RecordType.INVITE_USED, used)).build()

        callRegister(Endpoints.urls(manifest, allowPlaintext), req)   // tries each URL; maps RpcException -> RegistrationError

        db.withTransaction {
            db.accountDao().insert(AccountEntity(userId, user, name, vault.wrap(seed), now))
            db.settingsDao()... // registration_id, next_one_time_id = nextId, network_pub
            db.manifestDao().insert(ManifestEntity(manifest.version, bundle.manifest.toByteArray()))
            mem.copyInto(RoomSignalKeyValue(db.signalKvDao()))
            if (!bundle.inviterUserId.isEmpty) db.contactDao().upsert(ContactEntity(
                bundle.inviterUserId.toByteArray(), "", bundle.inviterName, bundle.inviterAccountPub.toByteArray(),
                bundle.inviterIdentityPub.toByteArray(), verified = true, identityChanged = false, revoked = false, entryVersion = 0))
        }
        accounts.load()
    }
    companion object { val USERNAME = Regex("^[a-z0-9_]{3,32}$") }
}
```
`callRegister`: for each url → `transport.connect(url)`, `RpcClient(conn, scope)`, `withTimeout(10s){hello}`, `RemoteNodeApi(rpc).register(req)`,
close; on `IOException` try the next url; `RpcException` mapping: `CONFLICT` + message contains "username" → `UsernameTaken`,
`CONFLICT` + "used" → `InviteUsed`, `CONFLICT` + "expired" → `InviteExpired`, `NOT_FOUND` → `InviteUnknown`, else `Unknown(message)`;
all urls failed with IO → `Network`. `RegistrationError` is `sealed class RegistrationError : Exception()` with those objects/classes.
(`ContactEntity` username "" until the directory sync fills it.)

- [ ] **Step 5: Messaging** — `Outbox`, `MailboxReceiver`, `Receipts`, `MessageRepository`, `DirectorySync`, `InviteRepository`,
`SyncEngine`, `ForegroundSync` per the acceptance list. Essential pieces:

Outbox processing for one item:
```kotlin
private suspend fun process(api: NodeApi, item: OutboxEntity, me: LocalAccount) {
    val record = item.recordBytes?.let { Record.parseFrom(it) } ?: run {
        val contact = contacts.get(item.recipientUserId) ?: throw PermanentFailure("unknown contact")
        val (kind, ct) = signal.withSessions { _, s ->
            val addr = s.address(item.recipientUserId)
            if (!s.hasSession(addr)) null else s.encrypt(addr, item.contentBytes)
        } ?: run {
            val bundle = api.fetchPrekeys(item.recipientUserId)
            signal.withSessions { _, s ->
                s.processBundle(bundle, contact.identityPub)
                s.encrypt(s.address(item.recipientUserId), item.contentBytes)
            }
        }
        val env = Envelope.newBuilder().setSenderUser(bs(me.userId)).setSenderDevice(1).setKind(kind).setUrgent(item.urgent)
            .addRecipients(Recipient.newBuilder().setUser(bs(item.recipientUserId)).setDevice(1).setContent(bs(ct))).build()
        RecordCodec.sign(RecordCodec.body(RecordType.ENVELOPE, me.userId, env.toByteArray(), createdMs = clock.now()), me.accountKey)
            .also { outboxDao.setRecord(item.id, it.toByteArray()) }
    }
    api.send(record)
    db.withTransaction {
        outboxDao.delete(item.id)
        item.messageLocalId?.let { messages.advanceStatusLocal(it, MessageStatus.SENT) }
    }
}
```
Error handling around `process`: `PermanentFailure` or `RpcException` with `STATUS_INVALID|STATUS_NOT_FOUND|STATUS_REVOKED` →
`messageLocalId?.let(markFailed)` + delete; anything else → `reschedule(id, attempts+1, now + min(2^attempts * 1000, 300_000))`.
The loop: `kick()` sends on a conflated channel; the worker waits for `kick` **or** the next `nextAttemptAt()` deadline, and only processes while
`SyncEngine.connection` is `Online`.

MailboxReceiver core:
```kotlin
suspend fun handle(api: NodeApi, records: List<Record>) {
    val me = accounts.require()
    val acks = mutableListOf<ByteArray>()
    for (rec in records) {
        val body = RecordBody.parseFrom(rec.body)
        val key = body.author.toByteArray() + body.id.toByteArray()
        if (seen.insert(SeenEnvelopeEntity(key, clock.now() + 30.days.inWholeMilliseconds)) == -1L) { acks += key; continue }
        val sender = contacts.get(body.author.toByteArray()) ?: run { directory.sync(api); contacts.get(body.author.toByteArray()) }
        if (sender == null) { seen.delete(key); continue }                       // keep it on the node; retry later
        if (!RecordCodec.verify(rec, sender.accountPub)) { acks += key; continue }
        val env = Envelope.parseFrom(body.payload)
        val mine = env.recipientsList.firstOrNull { it.user.toByteArray().contentEquals(me.userId) && it.device == 1 }
        if (mine == null) { acks += key; continue }
        val plain = runCatching {
            signal.withSessions { _, s -> s.decrypt(s.address(sender.userId), env.kind, mine.content.toByteArray()) }
        }.getOrNull()
        db.withTransaction {
            val cid = conversations.getOrCreateDirect(sender.userId, sender.displayName, clock.now())
            if (plain == null) {
                messages.insert(MessageEntity(messageId = key.copyOf(16), conversationId = cid, senderId = sender.userId, outgoing = false,
                    sentMs = body.createdMs, receivedMs = clock.now(), body = "", status = MessageStatus.DELIVERED, kind = MessageKind.SYSTEM_UNDECRYPTABLE))
            } else handleContent(cid, sender, Content.parseFrom(plain))
            conversations.touch(cid, clock.now())
        }
        acks += key
    }
    if (acks.isNotEmpty()) {
        val ack = Ack.newBuilder().addAllEnvelopeIds(acks.map(::bs)).setDeviceId(1).build()
        api.ack(RecordCodec.sign(RecordCodec.body(RecordType.ACK, me.userId, ack.toByteArray(), createdMs = clock.now()), me.accountKey))
    }
    outbox.kick()
}
```
(add `@Query("DELETE FROM seen_envelopes WHERE record_key = :k") suspend fun delete(k: ByteArray)` to `SeenEnvelopeDao`.)
`handleContent`: DataMessage → `messages.insert(... status DELIVERED, sentMs = content.sentMs ...)`; if inserted (`!= -1`) → `incrementUnread`
and enqueue receipt `Content{receipt{DELIVERED,[message_id]}}` to sender (`urgent=false`, `messageLocalId=null`). Receipt → for each id
`advanceStatus(id, if type == READ then READ else DELIVERED)`.

SyncEngine event loop (started in `onConnected` inside the connection's scope so it ends with the connection):
```kotlin
api.events.onEach { e -> when (e.type) {
    "envelopes" -> receiver.handle(api, RecordBatch.parseFrom(e.body).recordsList)
    "directory" -> directory.sync(api)
    "prekeys_low" -> prekeys.refill(api)
} }.launchIn(sessionScope)
```

- [ ] **Step 6: DI** — `DataModule` provides `Clock { System.currentTimeMillis() }`, `Transport = OkHttpTransport()`, `SeedVault(KeystoreKeyWrapper("otter_seed_kek"))`,
`@ApplicationScope` scope; `@AllowPlaintext Boolean` is provided by `app` (BuildConfig). `KeystoreKeyWrapper` must accept the alias (it does: constructor param).
- [ ] **Step 7: Run** `./gradlew :core:data:testDebugUnitTest` → PASS. If libsignal natives fail to load under Robolectric, add
`testImplementation(libs.libsignal.client)` to `core:data` explicitly and report.
- [ ] **Step 8: Commit** `git add -A && git commit -m "feat(data): registration, directory, outbox, receiver, receipts, sync engine"`

---

### Task 15: `feature:onboarding` — join with an invite

**Goal:** First-run flow per `docs/07` screens §1 and `docs/10` (tone, layout, accessibility). Backup password is M6 — not shown.

**Files:**
- Create in `feature/onboarding/src/main/kotlin/app/ottermsg/feature/onboarding/`: `OnboardingViewModel.kt`, `OnboardingState.kt`,
  `OnboardingNavigation.kt`, `screens/{WelcomeScreen,InviteScreen,ProfileScreen,PhraseScreen,PhraseConfirmScreen,RegisteringScreen}.kt`
- Create: `feature/onboarding/src/main/res/values/strings.xml` (ru), `values-en/strings.xml`
- Test: `src/test/.../OnboardingViewModelTest.kt`, `PhraseConfirmTest.kt` (Compose, Robolectric)

**Acceptance Criteria:**
- [ ] Flow: Welcome → Invite (scan QR with zxing **or** paste link; validation inline) → Profile (display name + username with live rule hint) →
  Phrase (24 numbered words, `FLAG_SECURE` while visible, "Я записал(а)" button) → Confirm (3 random positions, wrong word → inline error) →
  Registering (progress; on error: human message from `RegistrationError` + "Повторить"/"Назад") → done callback
- [ ] Seed generated once per flow (`SecureRandom`), kept in the ViewModel (`SavedStateHandle` stores **no** seed — process death restarts the flow)
- [ ] Camera permission requested only when tapping "Сканировать"; denial → message + paste option still works
- [ ] All interactive targets ≥ 48 dp; content descriptions in Russian/English; screen titles are headings for TalkBack
- [ ] Strings (ru/en) for every visible text; no technical jargon (no "node", "RPC")
- [ ] ViewModel tests: invalid link → error state; username rule; confirm with wrong word fails, right words pass; registration error mapping → message id

**Verify:** `./gradlew :feature:onboarding:testDebugUnitTest`

**Steps:**

- [ ] **Step 1: State + ViewModel**
```kotlin
enum class OnboardingStep { WELCOME, INVITE, PROFILE, PHRASE, CONFIRM, REGISTERING, DONE }

data class OnboardingUiState(
    val step: OnboardingStep = OnboardingStep.WELCOME,
    val link: String = "", val linkError: Int? = null, val inviterName: String? = null,
    val displayName: String = "", val username: String = "", val profileError: Int? = null,
    val words: List<String> = emptyList(), val confirmPositions: List<Int> = emptyList(),
    val confirmInputs: List<String> = listOf("", "", ""), val confirmError: Boolean = false,
    val registering: Boolean = false, val registrationError: Int? = null,
)

@HiltViewModel
class OnboardingViewModel @Inject constructor(private val registration: Registration) : ViewModel() {
    private val seed = ByteArray(32).also(SecureRandom()::nextBytes)
    private val _state = MutableStateFlow(OnboardingUiState(words = Bip39.toMnemonic(seed),
        confirmPositions = (0 until 24).shuffled(SecureRandom().asKotlinRandom()).take(3).sorted()))
    val state: StateFlow<OnboardingUiState> = _state

    fun start() = update { copy(step = OnboardingStep.INVITE) }
    fun onLink(text: String) = update { copy(link = text, linkError = null) }
    fun submitLink() {
        val b = runCatching { InviteLink.decode(_state.value.link) }.getOrNull()
        update { if (b == null) copy(linkError = R.string.onb_invite_invalid) else copy(inviterName = b.inviterName.ifEmpty { null }, step = OnboardingStep.PROFILE) }
    }
    fun onDisplayName(v: String) = update { copy(displayName = v.take(64), profileError = null) }
    fun onUsername(v: String) = update { copy(username = v.lowercase().filter { it.isLetterOrDigit() || it == '_' }.take(32), profileError = null) }
    fun submitProfile() = update {
        when {
            displayName.isBlank() -> copy(profileError = R.string.onb_profile_name_required)
            !Registration.USERNAME.matches(username) -> copy(profileError = R.string.onb_profile_username_rule)
            else -> copy(step = OnboardingStep.PHRASE)
        }
    }
    fun phraseWritten() = update { copy(step = OnboardingStep.CONFIRM) }
    fun onConfirmInput(i: Int, v: String) = update { copy(confirmInputs = confirmInputs.toMutableList().also { it[i] = v.trim().lowercase() }, confirmError = false) }
    fun submitConfirm() {
        val s = _state.value
        val ok = s.confirmPositions.indices.all { s.confirmInputs[it] == s.words[s.confirmPositions[it]] }
        if (!ok) { update { copy(confirmError = true) }; return }
        register()
    }
    fun register() {
        val s = _state.value
        update { copy(step = OnboardingStep.REGISTERING, registering = true, registrationError = null) }
        viewModelScope.launch {
            val r = registration.register(s.link, s.displayName, s.username, seed)
            update {
                r.fold(onSuccess = { copy(registering = false, step = OnboardingStep.DONE) },
                       onFailure = { copy(registering = false, registrationError = errorMessage(it)) })
            }
        }
    }
    fun back() = update {
        when (step) {
            OnboardingStep.INVITE -> copy(step = OnboardingStep.WELCOME)
            OnboardingStep.PROFILE -> copy(step = OnboardingStep.INVITE)
            OnboardingStep.PHRASE -> copy(step = OnboardingStep.PROFILE)
            OnboardingStep.CONFIRM -> copy(step = OnboardingStep.PHRASE)
            OnboardingStep.REGISTERING -> if (registering) this else copy(step = if (registrationError == R.string.onb_err_username_taken) OnboardingStep.PROFILE else OnboardingStep.CONFIRM)
            else -> this
        }
    }
    private inline fun update(f: OnboardingUiState.() -> OnboardingUiState) { _state.value = _state.value.f() }

    companion object {
        fun errorMessage(t: Throwable): Int = when (t) {
            RegistrationError.UsernameTaken -> R.string.onb_err_username_taken
            RegistrationError.InviteUsed -> R.string.onb_err_invite_used
            RegistrationError.InviteExpired -> R.string.onb_err_invite_expired
            RegistrationError.InviteUnknown, RegistrationError.BadLink -> R.string.onb_invite_invalid
            RegistrationError.Network -> R.string.onb_err_network
            else -> R.string.onb_err_unknown
        }
    }
}
```
(`Registration` must be an open class or behind an interface `Registrar` for the ViewModel test fake — introduce `interface Registrar { suspend fun register(...): Result<Unit> }` implemented by `Registration`.)

- [ ] **Step 2: Strings** (`values/strings.xml`, Russian):
```xml
<resources>
    <string name="onb_welcome_title">Otter</string>
    <string name="onb_welcome_text">Семейный мессенджер. Сообщения шифруются на телефоне и видны только участникам переписки.</string>
    <string name="onb_welcome_join">Присоединиться по приглашению</string>
    <string name="onb_invite_title">Приглашение</string>
    <string name="onb_invite_text">Отсканируйте QR-код приглашения или вставьте ссылку, которую вам прислали.</string>
    <string name="onb_invite_scan">Сканировать QR-код</string>
    <string name="onb_invite_paste_label">Ссылка-приглашение</string>
    <string name="onb_invite_continue">Продолжить</string>
    <string name="onb_invite_invalid">Приглашение не распознано. Проверьте ссылку или попросите новую.</string>
    <string name="onb_camera_denied">Для сканирования нужен доступ к камере. Можно вставить ссылку вручную.</string>
    <string name="onb_invite_from">Вас приглашает %1$s</string>
    <string name="onb_profile_title">Как вас называть</string>
    <string name="onb_profile_name">Имя</string>
    <string name="onb_profile_username">Имя пользователя</string>
    <string name="onb_profile_username_hint">3–32 символа: латинские буквы, цифры и _</string>
    <string name="onb_profile_name_required">Введите имя</string>
    <string name="onb_profile_username_rule">Имя пользователя: 3–32 символа, латинские буквы, цифры и _</string>
    <string name="onb_phrase_title">Фраза восстановления</string>
    <string name="onb_phrase_text">Запишите эти 24 слова на бумаге и храните в надёжном месте. Они нужны, чтобы восстановить аккаунт на новом телефоне. Никому их не показывайте.</string>
    <string name="onb_phrase_done">Я записал(а)</string>
    <string name="onb_confirm_title">Проверка</string>
    <string name="onb_confirm_text">Введите слова с указанными номерами.</string>
    <string name="onb_confirm_word">Слово №%1$d</string>
    <string name="onb_confirm_wrong">Слова не совпадают. Проверьте запись.</string>
    <string name="onb_confirm_continue">Готово</string>
    <string name="onb_registering">Создаём аккаунт…</string>
    <string name="onb_err_username_taken">Это имя пользователя уже занято. Выберите другое.</string>
    <string name="onb_err_invite_used">Это приглашение уже использовано. Попросите новое.</string>
    <string name="onb_err_invite_expired">Срок приглашения истёк. Попросите новое.</string>
    <string name="onb_err_network">Не удалось подключиться. Проверьте интернет и повторите.</string>
    <string name="onb_err_unknown">Не получилось создать аккаунт. Повторите попытку.</string>
    <string name="onb_retry">Повторить</string>
    <string name="onb_back">Назад</string>
</resources>
```
English equivalents in `values-en/strings.xml` with the same keys.

- [ ] **Step 3: Screens** — one composable per step, all using `OtterTheme` tokens, `Dimens.screenGutter`, `Scaffold` with
`OtterTopBar`-style `TopAppBar` (64 dp, Back icon "Назад"), primary action as full-width `Button` at the bottom
(`Modifier.navigationBarsPadding().imePadding()`). Specifics:
  - `InviteScreen`: "Сканировать QR-код" uses `rememberLauncherForActivityResult(ScanContract())` with
    `ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setBeepEnabled(false).setOrientationLocked(false)`; result text → `onLink` + `submitLink`.
    Camera permission is requested by the zxing activity itself; on cancel-with-denied show `onb_camera_denied`. Text field for paste with error text below.
  - `PhraseScreen`: `LazyVerticalGrid(GridCells.Fixed(2))` of "N. word" items; set `FLAG_SECURE` via `DisposableEffect` on the activity window, cleared on dispose.
  - `PhraseConfirmScreen`: three `OutlinedTextField`s labelled `onb_confirm_word` with the 1-based position; `KeyboardOptions(autoCorrect = false, capitalization = None)`.
  - `RegisteringScreen`: `CircularProgressIndicator` + text while registering; error text (error color on errorContainer card) + Retry/Back buttons.
- [ ] **Step 4: Navigation entry** — `@Composable fun OnboardingRoute(onDone: () -> Unit)` collects state, renders the step, calls `onDone` at DONE, handles system Back via `BackHandler { vm.back() }`.
- [ ] **Step 5: Tests** — ViewModel tests with a fake `Registrar`; one Compose test: confirm screen shows "Слово №N" labels for the chosen positions.
- [ ] **Step 6: Run** `./gradlew :feature:onboarding:testDebugUnitTest` → PASS.
- [ ] **Step 7: Commit** `git add -A && git commit -m "feat(onboarding): join by invite, recovery phrase, registration"`

---

### Task 16: `feature:chats` — chat list, new chat, invite, minimal settings

**Goal:** Main screen per `docs/10` §6 and `docs/07` screens 2, 4, 6, 7 (M1 subset).

**Files:** in `feature/chats/src/main/kotlin/app/ottermsg/feature/chats/`:
`ChatListViewModel.kt`, `ChatListScreen.kt`, `NewChatViewModel.kt`, `NewChatScreen.kt`, `InviteViewModel.kt`, `InviteScreen.kt`,
`SettingsScreen.kt`, `ConnectionBanner.kt`, `QrImage.kt`, strings ru/en; tests `ChatListViewModelTest.kt`, `ConnectionBannerTest.kt`

**Acceptance Criteria:**
- [ ] Chat list: top bar "Otter" + avatar button → Settings; rows (48 dp avatar with initials, title, last message preview with status icon for outgoing,
  time "HH:mm" today / "d MMM" otherwise, unread badge); empty state text; FAB/primary button "Написать" → New chat
- [ ] Connection banner under the top bar: `Waiting`/`Offline` → "Нет подключения. Сообщения отправятся автоматически."; `Connecting` shown only if it lasts > 2 s → "Подключаемся…"; `Online` → hidden. No node names here.
- [ ] New chat: list of family members (contacts, excluding self), tap → `getOrCreateDirect` → open conversation
- [ ] Invite screen: creates an invite, shows QR (zxing `BarcodeEncoder` → `ImageBitmap`, 256 dp, with content description) + "Поделиться ссылкой" (`Intent.ACTION_SEND`), expiry text "Действует 7 дней, один раз"; error → retry
- [ ] Settings (M1 stub): profile name/username, "Пригласить в семью" → Invite, "Подключение" row showing human status (+ node URL in secondary text); other sections from the guide are not shown yet
- [ ] Strings ru/en; icons with descriptions; 48 dp targets

**Verify:** `./gradlew :feature:chats:testDebugUnitTest`

**Steps:**

- [ ] **Step 1:** ViewModels expose `StateFlow`s mapped from `MessageRepository.observeSummaries()`, `ContactRepository.observeContacts()`,
`SyncEngine.connection`, `InviteRepository.create()`; time formatting via `java.time` with the device locale.
- [ ] **Step 2:** Composables per the acceptance list. Status icon mapping (shared with conversation, put it in `core:ui` as
`DeliveryStatusIcon(status: Int, modifier)`): PENDING `Icons.Outlined.Schedule` "Ожидает отправки"; SENT `Icons.Outlined.Done` "Отправлено";
DELIVERED `Icons.Outlined.DoneAll` (onSurfaceVariant) "Доставлено"; READ `Icons.Outlined.DoneAll` (primary) "Прочитано";
FAILED `Icons.Outlined.ErrorOutline` (error) "Не отправлено".
- [ ] **Step 3:** `ConnectionBanner` logic as a pure function `bannerFor(state, connectingSinceMs, nowMs): Int?` and unit-test it.
- [ ] **Step 4: Run** tests → PASS. **Step 5: Commit** `git commit -m "feat(chats): chat list, new chat, invite qr, settings stub"`

---

### Task 17: `feature:conversation` — 1:1 conversation

**Goal:** Conversation screen per `docs/10` §7–§8 (text only in M1).

**Files:** in `feature/conversation/src/main/kotlin/app/ottermsg/feature/conversation/`:
`ConversationViewModel.kt`, `ConversationScreen.kt`, `MessageBubble.kt`, `MessageMeta.kt`, `MessageComposer.kt`, `DateChip.kt`,
strings ru/en; tests `ConversationViewModelTest.kt`, `MessageGroupingTest.kt`, `MessageBubbleTest.kt` (Compose/Robolectric)

**Acceptance Criteria:**
- [ ] Top bar: Back, 40 dp avatar, title (1 line, ellipsis); no call buttons, no fake online status
- [ ] Bubbles: outgoing right (`outgoingContainer`), incoming left (`surface`); radius 20 dp; padding 12/8 dp; max width min(84 %, 480 dp)
  (94 % when font scale ≥ 1.3); long words wrap; time + status in a separate bottom row
- [ ] Grouping: 4 dp between same-author messages, 12 dp between groups; new group on author change, > 5 min gap, or date change; date chip centered
- [ ] Undecryptable message → system bubble "Не удалось прочитать сообщение. Пробуем восстановить соединение"
- [ ] Composer: growing field 1–5 lines (radius 24 dp), Enter = newline, round 48 dp send button disabled when blank; on send the text is cleared **only after**
  `sendText` returns (DB write); double-tap creates no duplicate (button disabled while sending); draft saved per conversation (debounced 500 ms) and restored
- [ ] Long-press menu: "Копировать" (clipboard), "Удалить у меня" with confirm dialog "Сообщение исчезнет только на этом устройстве"; FAILED message tap → "Повторить" (re-queues)
- [ ] Opening/visible conversation → `markConversationRead` (on enter and when new incoming arrive while visible)
- [ ] Scrolling: list starts at bottom; new incoming while user scrolled up → "jump to bottom" button with count; own send scrolls to bottom
- [ ] TalkBack: each message is one merged node "Автор, текст, время, статус"
- [ ] No photo/camera/voice/reaction controls in M1

**Verify:** `./gradlew :feature:conversation:testDebugUnitTest`

**Steps:**

- [ ] **Step 1:** `groupMessages(list, zone): List<ConversationItem>` (pure; items: `DateChip(date)`, `Bubble(message, firstInGroup, lastInGroup)`) + unit tests for the grouping rules.
- [ ] **Step 2:** ViewModel: `messages` (grouped), `title`, `draft` restore/save, `send()` with an in-flight flag, `retry(localId)`, `delete(localId)`, `markRead()`.
  Add `MessageRepository.retry(localId)` (re-creates the outbox item from the stored text with the same `message_id`) — implement in `core:data` with a test.
- [ ] **Step 3:** Composables per acceptance; `MessageBubble` takes a ready UI model (no DB/Signal access, per guide §13).
- [ ] **Step 4:** Compose test: outgoing READ bubble exposes content description containing "Прочитано"; send button disabled for blank input.
- [ ] **Step 5: Run** tests → PASS. **Step 6: Commit** `git commit -m "feat(conversation): 1:1 conversation screen with statuses and composer"`

---

### Task 18: App wiring

**Goal:** One app: onboarding when there is no account, chats otherwise; sync while in foreground; plaintext only in debug.

**Files:** `app/src/main/java/app/ottermsg/{MainActivity,OtterApp,AppNavHost,AppModule}.kt`,
`app/src/debug/res/xml/network_security_config.xml`, `app/src/debug/AndroidManifest.xml`, `app/src/main/AndroidManifest.xml`

**Acceptance Criteria:**
- [ ] `AppModule` provides `@AllowPlaintext = BuildConfig.ALLOW_PLAINTEXT`
- [ ] Debug-only network security config permits cleartext (for `ws://10.0.2.2`); release has none (cleartext blocked by default on API 28+, and `ALLOW_PLAINTEXT=false` drops `WS_PLAIN` endpoints)
- [ ] `MainActivity`: shows a blank themed surface while `AccountRepository.load()` runs (no skeleton), then onboarding or chats; after onboarding DONE → chats (back stack cleared)
- [ ] NavHost routes: `onboarding`, `chats`, `newChat`, `conversation/{id}`, `invite`, `settings`
- [ ] `OtterApp` registers `ForegroundSync` with `ProcessLifecycleOwner` once an account exists (and right after registration)
- [ ] `INTERNET` permission in main manifest; camera permission is declared by the zxing library
- [ ] `./gradlew assembleDebug assembleRelease` succeed (release unsigned is fine); R8 keeps libsignal/proto classes

**Verify:** `./gradlew assembleDebug assembleRelease test`

**Steps:**

- [ ] **Step 1:** Debug network security config:
```xml
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <base-config cleartextTrafficPermitted="true" />
</network-security-config>
```
`app/src/debug/AndroidManifest.xml`:
```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">
    <application android:networkSecurityConfig="@xml/network_security_config" tools:ignore="UnusedAttribute" />
</manifest>
```
- [ ] **Step 2:** NavHost + activity + app as specified.
- [ ] **Step 3: Build** → green. **Step 4: Commit** `git commit -m "feat(app): navigation, foreground sync, debug-only plaintext"`

---

### Task 19: End-to-end verification against a real node

**Goal:** Prove interop with `otter-node` automatically, then on emulators by hand.

**Files:**
- Create: `core/data/src/test/kotlin/app/ottermsg/core/data/LiveNodeTest.kt`
- Create: `otter-android/docs/m1-manual-test.md` (checklist; short)

**Acceptance Criteria:**
- [ ] `LiveNodeTest` is skipped unless `OTTER_DEV_INVITE` (bootstrap link) is set; with the dev node running (`otter-server/scripts/dev-node.sh --host 127.0.0.1`):
  client A registers with the bootstrap invite, creates an invite, client B registers with it, B → A "Привет", A receives it, B's message reaches DELIVERED,
  A marks read, B's message reaches READ — using the real `OkHttpTransport` and `ConnectionManager`
- [ ] Manual checklist executed on two emulators (create a second AVD:
  `avdmanager create avd -n Otter_B -k "system-images;android-35;google_apis;x86_64" -d medium_phone` — use the image that `Medium_Phone_API_35` uses, see `~/.android/avd/Medium_Phone_API_35.avd/config.ini`):
  install debug APK on both; A joins with the bootstrap link (paste); A creates invite; B joins with A's link; both see each other in "Написать";
  exchange messages both ways; statuses go ✓ → ✓✓ → blue ✓✓ on open; kill node → banner "Нет подключения…", message stays PENDING (clock); restart node → message sends;
  force-stop app during sending → message delivered after restart; reinstall not covered (M6)
- [ ] Results (pass/fail per line, APK size, any crash logs from `adb logcat`) recorded in the task report

**Verify:** `cd otter-server && scripts/dev-node.sh --host 127.0.0.1` (terminal 1); `OTTER_DEV_INVITE="$(cat ../otter-server/.dev/bootstrap-invite.txt)" ./gradlew :core:data:testDebugUnitTest --tests '*LiveNodeTest*'` (terminal 2) → PASS

**Steps:**

- [ ] **Step 1:** Write `LiveNodeTest` reusing `TestGraph` but with the real transport and `allowPlaintext = true`. Note: a bootstrap invite is single-use — the test
  must run against a fresh `.dev` (re-run `dev-node.sh` without `--keep`).
- [ ] **Step 2:** Run it; fix interop bugs in either repo (commit fixes in the repo they belong to, with a test reproducing the bug).
- [ ] **Step 3:** Manual checklist on emulators (dev node with default host `10.0.2.2`).
- [ ] **Step 4: Commit** `git add -A && git commit -m "test: live node interop test and M1 manual checklist"`

---

## M1 Done checklist

- [ ] `otter-server`: `make check` green; `scripts/dev-node.sh` runs a node and prints a bootstrap invite
- [ ] `otter-android`: `./gradlew assembleDebug assembleRelease test` green; APK size noted
- [ ] `LiveNodeTest` green against the dev node
- [ ] Manual two-emulator checklist passed (statuses, offline banner, retry after reconnect)
- [ ] Docs: update `docs/09-roadmap.md` M1 row with "done" and any deviations; note open issues for M2
- [ ] Next: M2 plan (mesh replication, manifest updates, endpoint racing)
