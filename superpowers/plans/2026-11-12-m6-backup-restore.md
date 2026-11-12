# M6 — Backup & restore — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A member who turns on backup (password in Settings) can wipe or replace the phone and get the account,
contacts, chats, groups and message history back with **username + backup password**; with only the **24 words** the
account comes back with empty chats (plus the history if they also know the password). Contacts keep writing to the
restored phone without doing anything. **Done when:** wipe phone → restore with username + password → history back;
contacts write to it in a direct chat and in a group with no action on their side.

**Read first (in this order):**
1. `docs/superpowers/specs/2026-11-12-ops-scripts-and-backup-design.md` Part 2 (approved scope).
2. `docs/04-security.md` "Recovery phrase", "Password backup" (KDF, contents, restore, rate limits).
3. `docs/02-protocol.md` §2 (records), §4 (methods: `backup.auth`, `backup.fetch` are planned there as unauthenticated).
4. `docs/09-roadmap.md` → "M1 notes" (Gradle on Temurin 21: `JAVA_HOME=~/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2`),
   "M3 notes" (staging build, dev mesh, emulator hints), "M4 notes".
5. `docs/superpowers/plans/2026-11-11-m4-photos.md` — format, and the blob machinery this milestone extends.

**Architecture:**
- *Nodes:* a backup is an M4 blob marked `persistent` (no readers, no expiry, not deleted by reads) plus a signed
  `BACKUP_META` record (type 10, reserved since M0) that names the blob and carries the public KDF parameters and
  `auth_verifier = SHA-256(auth_secret)`. Both replicate to every node like any record; chunks are pulled by the M4
  puller. The newest `BACKUP_META` version per user wins; the superseded blob is deleted everywhere. Two **public**
  methods let a phone with nothing but a username and password find its backup: `backup.auth{username}` → salt + KDF
  params (a stable fake salt for unknown names), `backup.fetch{username, auth_secret}` → the meta records, and a
  per-connection grant to `blob.get` that one blob. Wrong secrets are rate limited per node.
- *Install identity:* every install has an `installed_ms` (registration or restore time) carried in `PREKEYS`. The node
  keeps the newest install per device: a newer install replaces all prekeys, an older one is ignored. `auth.login` now
  answers with the stored `registration_id` and `installed_ms`, so the superseded phone learns it was replaced.
- *App:* `BackupManager` builds a `BackupSnapshot` protobuf (seed, profile, contacts, conversations, messages,
  attachment metadata + thumbnails, groups, photo settings), gzips it, encrypts it with Tink streaming AEAD under
  `backup_key`, uploads it as a persistent blob, then publishes `BACKUP_META`. Keys come from
  `Argon2id(password)` once (when the password is set) and are kept wrapped by the Keystore, so daily backups need no
  password. `RestoreManager` reverses it on a fresh install. After a restore the phone uploads new prekeys and sends a
  new `SessionReset` content to every contact; receivers move to the new session, show «… восстановил(а) аккаунт» and
  forget which sender keys they shared with that person, so group keys are re-sent.

**Decisions (made by the planner; Task 13 records them as D50–D55 in `docs/00-decisions.md`):**
- **D50 Backup storage on nodes:** backup = persistent blob (`BlobMeta.persistent`, zero readers, `expires_ms = 0`) +
  `BACKUP_META{version, salt, kdf_m_kib, kdf_t, kdf_p, auth_verifier, blob_key, size}` signed by the account key.
  Latest version per user wins (tie: later `created_ms`, then record key). A superseded meta's record and its blob are
  deleted; a persistent blob that no `BACKUP_META` references 7 days after creation is deleted by the janitor
  (self-heals failed uploads and resurrected old blobs). Tombstone for a deleted persistent blob: 30 days. Persistent
  blobs count toward the 2 GiB quota; at most 3 live persistent blobs per user (`STATUS_QUOTA` beyond). Backup records
  never leave the oplog by age (a node added later still gets every backup).
- **D51 Restore authentication:** `backup.auth` and `backup.fetch` are public. Unknown username or no backup →
  `salt = HMAC-SHA256(SHA-256("otter/fake-salt/v1" ‖ node private key), username)[:16]` with the default KDF params, so
  one node gives one stable answer. `backup.fetch` compares `SHA-256(auth_secret)` in constant time; failures go to
  `auth_failures`: 5 per username per hour and 20 per day per node → `STATUS_RETRY_LATER` "too many attempts". A
  successful fetch grants that connection `blob.get` on exactly that blob. Known limit: fake salts differ between
  nodes, so someone who can reach two nodes could tell which usernames exist; accepted (the node URL path is secret,
  usernames are visible to every member anyway).
- **D52 Install identity:** `PreKeys.installed_ms` (new field). Node rule per (user, device): newer `installed_ms` →
  delete all prekeys, store the new `registration_id`; equal → merge as today; older → keys ignored (record kept).
  `auth.login` returns `LoginResponse{registration_id, installed_ms}`. A phone whose stored `installed_ms` is older than
  the node's stops syncing and shows «Аккаунт восстановлен на другом телефоне» (only after its own restore has finished,
  so a lagging node can't confuse a fresh restore). Installs from before M6 send 0.
- **D53 Session recovery:** new `Content.session_reset` (`SessionReset{}`), sent 1:1 like any content. The restored
  phone sends it to every contact after uploading prekeys. A receiver inserts a `SYSTEM_RESET` message in the direct
  chat (if one exists), and deletes every `sender_key_shared` row for that member (next group send re-sends our sender
  key). On a 1:1 message that can't be decrypted, or a group message parked because the sender key is missing, the
  receiver deletes its session with the sender and sends `SessionReset` — at most once per contact per hour
  (`contacts.reset_ms`).
- **D54 Restore needs the network's address:** a wiped phone knows no node. «Восстановить» starts by scanning/pasting a
  family invite (any member's QR from «Пригласить в семью», or a bootstrap link); only its signed manifest is used —
  the invite is **not** consumed.
- **D55 Backup policy on the phone:** opt-in in Settings; password ≥ 10 chars and zxcvbn score ≥ 3; KDF Argon2id
  m = 64 MiB, t = 3, p = 1 (BouncyCastle, pure Java); derived `backup_key` + `auth_secret` kept wrapped by the
  Keystore (`SeedVault`) so automatic backups need no password. Automatic backup while the app is in the foreground
  when the last success is > 24 h old; «Создать сейчас»; password change = new salt, new keys, new version. No media
  files: restored photo messages keep the thumbnail and show «Нет в резервной копии» (`AttachmentState.NOT_IN_BACKUP`).

**Tech Stack:** as M4 + `org.bouncycastle:bcprov-jdk18on:1.80` (Argon2id; pure Java so it also runs in Robolectric
unit tests — argon2kt is faster but native-only and can't run in JVM tests; Argon2 runs only when setting/changing the
password or restoring, a few seconds is fine) + `com.nulabinc.zxcvbn:zxcvbn:1.9.0` (password strength).
Tink (`AesGcmHkdfStreaming`, HKDF) already in `core:crypto`.

**Out of scope:** media files in backups, backups while the app is closed (no WorkManager), changing the 24 words,
multi-device, deleting a backup from the phone, restoring messages that arrived for the old install after the backup
(they show «Не удалось прочитать сообщение» and trigger a reset).

**Branches:** `m6-backup` in `otter-server` and `otter-android` (from `main`). The top-level `docs/` is not in git.

**Commits** end with:
```
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S4HpRBxLVKgjFPHw4U4CNo
```

---

## File map

| Repo / file | Responsibility |
|---|---|
| **otter-server** | |
| `proto/otter/v1/records.proto` | `BackupMeta`; `BlobMeta.persistent` |
| `proto/otter/v1/prekeys.proto` | `PreKeys.installed_ms` |
| `proto/otter/v1/api.proto` | `LoginResponse`, `BackupAuthRequest/Response`, `BackupFetchRequest/Response` |
| `proto/otter/v1/content.proto` | `SessionReset`, `Content.session_reset = 5` |
| `proto/otter/v1/backup.proto` (new) | `BackupSnapshot` and parts (client-only) |
| `internal/records/validate.go` | `checkBackupMeta`; persistent rules in `checkBlobMeta` |
| `internal/store/migrations/0005_backups.sql` (new) | `blobs.persistent`, `backups`, `devices.installed_ms`, `auth_failures` index |
| `internal/store/typed.go`, `apply.go`, `janitor.go` | apply rules (D50/D52), `expiring(body)`, unreferenced GC |
| `internal/store/backups.go` (new) | `BackupFor`, `DeviceInstall`, `AuthFailures`, `AddAuthFailure`, `PersistentBlobs` |
| `internal/service/backup.go` (new) | `BackupAuth`, `BackupFetch`, fake salt, rate limit |
| `internal/service/service.go`, `blobs.go` | `VerifyLogin` → `LoginResponse`; persistent quota; owner-read for grants |
| `internal/gateway/methods.go`, `gateway.go` | methods, public set, per-session grant |
| `internal/meshsim/backup_test.go` (new) | restore through another node; install ordering |
| **otter-android** | |
| `core/crypto/.../BackupKeys.kt` (new) | Argon2id + HKDF → `backup_key`, `auth_secret`, verifier |
| `core/network/.../NodeApi.kt` | `login` returns `LoginResponse`; `backupAuth`, `backupFetch`, `backupPublish` |
| `core/database/...` | DB v6: `contacts.reset_ms`; `MessageKind.SYSTEM_RESET`; `AttachmentState.NOT_IN_BACKUP` |
| `core/data/.../settings/Settings.kt` | install/backup keys |
| `core/data/.../backup/PasswordPolicy.kt` (new) | zxcvbn rule |
| `core/data/.../backup/SnapshotCodec.kt` (new) | DB ↔ `BackupSnapshot` |
| `core/data/.../backup/BackupManager.kt` (new) | enable, run, run-if-due, change password, state |
| `core/data/.../backup/RestoreManager.kt` (new) | network from invite, password path, words path, install |
| `core/data/.../backup/InstallGuard.kt` (new) | after-login: finish restore (prekeys, resets) or detect superseded |
| `core/data/.../messaging/SessionResets.kt` (new) | send/receive `SessionReset`, throttle |
| `core/data/.../messaging/MailboxReceiver.kt`, `GroupReceiver.kt` | hooks |
| `core/data/.../registration/Registration.kt`, `signal/PrekeyRefill.kt` | `installed_ms` in PREKEYS |
| `core/data/.../sync/SyncEngine.kt` | InstallGuard + BackupManager in the session |
| `feature/settings/.../BackupScreen.kt` (new) | «Резервная копия» |
| `feature/onboarding/...` | Welcome «Восстановить», restore steps |
| `app/.../AppNavHost.kt`, `MainActivity.kt`, `SupersededScreen.kt` (new) | routes, superseded gate |
| `feature/conversation/...` | `SYSTEM_RESET` chip, «Нет в резервной копии» |
| `core/data/src/test/.../LiveRestoreTest.kt` (new) | acceptance against the dev mesh |
| `docs/m6-manual-test.md` (new) | two-phone checklist |

---

### Task 1: Protos and record validation

**Goal:** All new wire messages exist; nodes validate `BACKUP_META` and persistent `BLOB_META`.

**Files:**
- Modify: `otter-server/proto/otter/v1/{records,prekeys,api,content}.proto`
- Create: `otter-server/proto/otter/v1/backup.proto`
- Modify: `otter-server/internal/records/validate.go`, `otter-server/internal/records/validate_test.go`

**Acceptance Criteria:**
- [ ] `make gen` regenerates Go code; `make check` passes.
- [ ] `BACKUP_META` valid only with: version ≥ 1, salt 16 B, `kdf_m_kib` 19456–262144, `kdf_t` 1–10, `kdf_p` 1–4,
  verifier 32 B, `blob_key` 32 B starting with the author id, size 1..MaxBlobSize, `expires_ms = 0`.
- [ ] `BLOB_META` with `persistent = true` valid only with zero readers and `expires_ms = 0`; non-persistent rules unchanged.

**Verify:** `cd otter-server && make gen && go test ./internal/records/ -run 'Backup|Persistent' -v && make check`

**Steps:**

- [ ] **Step 1: Protos.** `records.proto` — after `BlobFetched`:

```proto
// BACKUP_META: the author's current password backup (D50). Latest version wins.
message BackupMeta {
  uint64 version = 1;
  bytes salt = 2;            // 16 bytes, Argon2id salt
  uint32 kdf_m_kib = 3;      // 65536 in V1
  uint32 kdf_t = 4;          // 3
  uint32 kdf_p = 5;          // 1
  bytes auth_verifier = 6;   // SHA-256(auth_secret), 32 bytes
  bytes blob_key = 7;        // record key of the persistent BLOB_META (author ‖ id)
  uint64 size = 8;           // ciphertext bytes
}
```
and in `BlobMeta` add `bool persistent = 5; // backup blob: no readers, no expiry (D50)`.

`prekeys.proto` `PreKeys`: `int64 installed_ms = 6; // time this install was created (D52); 0 = before M6`.

`api.proto` (after `BlobStatus`):

```proto
message LoginResponse {
  uint32 registration_id = 1;  // of the newest install this node knows (D52)
  int64 installed_ms = 2;
}

message BackupAuthRequest { string username = 1; }
message BackupAuthResponse {
  bytes salt = 1;
  uint32 kdf_m_kib = 2;
  uint32 kdf_t = 3;
  uint32 kdf_p = 4;
}

message BackupFetchRequest {
  string username = 1;
  bytes auth_secret = 2;  // 32 bytes
}
message BackupFetchResponse {
  Record backup_meta = 1;
  Record blob_meta = 2;   // chunk hashes: the client verifies every chunk
}
```

`content.proto`: in `Content.body` add `SessionReset session_reset = 5;` and

```proto
// Sent 1:1 after a restore or when a message could not be decrypted (D53). No fields.
message SessionReset {}
```

New `backup.proto` (client-only; nodes never see it):

```proto
syntax = "proto3";
package otter.v1;

option go_package = "ottermsg/server/internal/proto/otterv1;otterv1";
option java_package = "app.ottermsg.proto.v1";
option java_multiple_files = true;

// Plaintext of a password backup (D55): gzip(BackupSnapshot) is encrypted with backup_key.
message BackupSnapshot {
  uint32 format = 1;            // 1
  int64 created_ms = 2;
  bytes seed = 3;               // 32 bytes
  string username = 4;
  string display_name = 5;
  int64 registered_ms = 6;      // account.created_ms (D40)
  uint32 entry_version = 7;
  repeated BackupContact contacts = 8;
  repeated BackupConversation conversations = 9;
  repeated BackupMessage messages = 10;
  repeated BackupGroup groups = 11;
  uint32 photo_auto_download = 12;
  bool photo_save_to_gallery = 13;
}

message BackupContact {
  bytes user_id = 1; string username = 2; string display_name = 3;
  bytes account_pub = 4; bytes identity_pub = 5;
  bool verified = 6; bool identity_changed = 7; bool revoked = 8; int64 entry_version = 9;
}

message BackupConversation {
  int64 id = 1; bytes peer_user_id = 2; string title = 3; int64 last_activity_ms = 4;
  int32 unread = 5; string draft = 6; bytes group_id = 7; int32 type = 8;
}

message BackupMessage {
  bytes message_id = 1; int64 conversation_id = 2; bytes sender_id = 3; bool outgoing = 4;
  int64 sent_ms = 5; int64 received_ms = 6; string body = 7; int32 status = 8; int32 kind = 9;
  bool read_receipt_sent = 10; bytes system_data = 11;
  BackupAttachment attachment = 12;  // kind = PHOTO
  repeated BackupRecipient recipients = 13;  // outgoing group messages
}

message BackupAttachment {
  bytes blob_key = 1; bytes key = 2; bytes digest = 3; int64 size = 4; string mime = 5;
  int32 width = 6; int32 height = 7; bytes thumb = 8;
}

message BackupRecipient { bytes user_id = 1; int64 delivered_ms = 2; int64 read_ms = 3; }

message BackupGroup {
  bytes group_id = 1; string name = 2; bool family = 3; int64 version = 4;
  bytes state_signed = 5; bytes prev_state = 6; bool i_am_member = 7; bytes created_by = 8;
  repeated BackupGroupMember members = 9;
}

message BackupGroupMember { bytes user_id = 1; bool admin = 2; }
```

Run `make gen`.

- [ ] **Step 2: Failing validator tests** — append to `internal/records/validate_test.go` (reuse the file's helpers that
build and sign a body for a user; if the helper is named differently, read the top of the file and use it):

```go
func backupMetaBody(t *testing.T, author []byte, mut func(*pb.BackupMeta, *pb.RecordBody)) *pb.RecordBody {
	t.Helper()
	m := &pb.BackupMeta{Version: 1, Salt: make([]byte, 16), KdfMKib: 65536, KdfT: 3, KdfP: 1,
		AuthVerifier: make([]byte, 32), BlobKey: append(append([]byte{}, author...), make([]byte, 16)...), Size: 1000}
	b := &pb.RecordBody{Id: make([]byte, 16), Type: pb.RecordType_BACKUP_META, Author: author, CreatedMs: 1}
	if mut != nil {
		mut(m, b)
	}
	b.Payload, _ = proto.Marshal(m)
	return b
}

func TestCheckBackupMeta(t *testing.T) {
	a := bytes.Repeat([]byte{7}, 16)
	if err := checkBackupMeta(backupMetaBody(t, a, nil)); err != nil {
		t.Fatalf("valid meta rejected: %v", err)
	}
	bad := map[string]func(*pb.BackupMeta, *pb.RecordBody){
		"version 0":      func(m *pb.BackupMeta, _ *pb.RecordBody) { m.Version = 0 },
		"short salt":     func(m *pb.BackupMeta, _ *pb.RecordBody) { m.Salt = make([]byte, 8) },
		"weak kdf":       func(m *pb.BackupMeta, _ *pb.RecordBody) { m.KdfMKib = 1024 },
		"t 0":            func(m *pb.BackupMeta, _ *pb.RecordBody) { m.KdfT = 0 },
		"p 9":            func(m *pb.BackupMeta, _ *pb.RecordBody) { m.KdfP = 9 },
		"verifier":       func(m *pb.BackupMeta, _ *pb.RecordBody) { m.AuthVerifier = nil },
		"foreign blob":   func(m *pb.BackupMeta, _ *pb.RecordBody) { m.BlobKey = make([]byte, 32) },
		"size 0":         func(m *pb.BackupMeta, _ *pb.RecordBody) { m.Size = 0 },
		"expires":        func(_ *pb.BackupMeta, b *pb.RecordBody) { b.ExpiresMs = 5 },
	}
	for name, mut := range bad {
		if err := checkBackupMeta(backupMetaBody(t, a, mut)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestCheckBlobMetaPersistent(t *testing.T) {
	a := bytes.Repeat([]byte{7}, 16)
	mk := func(readers [][]byte, expires int64) *pb.RecordBody {
		m := &pb.BlobMeta{Size: 10, ChunkSize: BlobChunkSize, ChunkSha256: [][]byte{make([]byte, 32)}, Readers: readers, Persistent: true}
		p, _ := proto.Marshal(m)
		return &pb.RecordBody{Id: make([]byte, 16), Type: pb.RecordType_BLOB_META, Author: a, CreatedMs: 1, ExpiresMs: expires, Payload: p}
	}
	if err := checkBlobMeta(mk(nil, 0)); err != nil {
		t.Fatalf("persistent blob rejected: %v", err)
	}
	if checkBlobMeta(mk([][]byte{bytes.Repeat([]byte{8}, 16)}, 0)) == nil {
		t.Error("persistent blob with readers accepted")
	}
	if checkBlobMeta(mk(nil, 1000)) == nil {
		t.Error("persistent blob with expiry accepted")
	}
}
```

Run → FAIL (`checkBackupMeta` undefined).

- [ ] **Step 3: Implement** in `internal/records/validate.go`. Add the `BACKUP_META` case to `checkPayload`'s switch
next to `BLOB_META`: `case pb.RecordType_BACKUP_META: return checkBackupMeta(b)`. In `checkBlobMeta` replace the
readers/expiry tail with:

```go
	if m.Persistent {
		if len(m.Readers) != 0 || b.ExpiresMs != 0 {
			return ErrBadPayload
		}
		return nil
	}
	if len(m.Readers) == 0 || len(m.Readers) > MaxBlobReaders {
		return ErrBadPayload
	}
	// … existing reader loop and expiry check unchanged …
```

and add:

```go
// checkBackupMeta: a user's password backup pointer (D50).
func checkBackupMeta(b *pb.RecordBody) error {
	var m pb.BackupMeta
	if err := proto.Unmarshal(b.Payload, &m); err != nil {
		return ErrBadPayload
	}
	switch {
	case b.ExpiresMs != 0, m.Version == 0, len(m.Salt) != 16, len(m.AuthVerifier) != 32,
		m.KdfMKib < 19456 || m.KdfMKib > 262144, m.KdfT < 1 || m.KdfT > 10, m.KdfP < 1 || m.KdfP > 4,
		len(m.BlobKey) != 32 || !bytes.Equal(m.BlobKey[:16], b.Author), m.Size == 0 || m.Size > MaxBlobSize:
		return ErrBadPayload
	}
	return nil
}
```

If the validator has a per-type author rule table (user-authored types), add `BACKUP_META` as user-authored like
`BLOB_META`. Run the tests → PASS; `make check` → PASS.

- [ ] **Step 4: Commit** `feat(proto): backup meta, persistent blobs, install identity, session reset`.

---

### Task 2: Storage — backups, persistent blobs, install identity

**Goal:** Nodes store the latest backup per user, keep persistent blobs until superseded/unreferenced, and keep only
the newest install's prekeys.

**Files:**
- Create: `otter-server/internal/store/migrations/0005_backups.sql`, `otter-server/internal/store/backups.go`,
  `otter-server/internal/store/backups_test.go`
- Modify: `otter-server/internal/store/typed.go`, `apply.go`, `janitor.go`, `blobs.go`

**Acceptance Criteria:**
- [ ] Applying `BACKUP_META` v2 after v1 deletes v1's record, v1's blob (rows + tombstone 30 d); applying v1 after v2
  stores nothing (record removed again); `BackupFor(username)` returns v2's raw record and blob key.
- [ ] Persistent `BLOB_META`: not deleted by `gcBlob(force=false)`; not dropped by `expiring()`; deleted by the
  janitor when unreferenced 7 days after `created_ms`.
- [ ] `PREKEYS` with newer `installed_ms` deletes all of the device's prekeys and sets the new registration id; older
  → device row and prekeys untouched; equal → today's merge. `DeviceInstall` returns (registration_id, installed_ms).
- [ ] `AddAuthFailure`/`AuthFailures(username, since)`/`AuthFailuresTotal(since)` work.

**Verify:** `cd otter-server && go test ./internal/store/ -v -run 'Backup|Persistent|Install|AuthFail' && make check`

**Steps:**

- [ ] **Step 1: Migration** `internal/store/migrations/0005_backups.sql`:

```sql
-- M6: password backups (D50), install identity (D52), restore rate limits (D51).
ALTER TABLE blobs ADD COLUMN persistent INTEGER NOT NULL DEFAULT 0;
DROP TABLE IF EXISTS backups;
CREATE TABLE backups(user_id BLOB PRIMARY KEY, record_key BLOB NOT NULL, version INTEGER NOT NULL,
                     created_ms INTEGER NOT NULL, blob_key BLOB NOT NULL);
CREATE INDEX backups_blob ON backups(blob_key);
ALTER TABLE devices ADD COLUMN installed_ms INTEGER NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS auth_failures_name ON auth_failures(username, at_ms);
CREATE INDEX IF NOT EXISTS auth_failures_at ON auth_failures(at_ms);
```

(Check `migrate.go` picks files up by name order; 0005 follows 0004.)

- [ ] **Step 2: Failing tests** `internal/store/backups_test.go`. Use the existing store test helpers (`open(t)`,
and the signing helper used by `blobs_test.go` to create user-authored records; read `blobs_test.go` first and reuse
its `blobMeta`/sign helpers — names below assume `signed(t, typ, author, priv, payload, created, expires)`; adapt to the
real helper):

```go
func TestBackupLatestWins(t *testing.T) {
	s, _ := open(t)
	ctx := context.Background()
	u := newUser(t, s, "anna") // registers a DIRECTORY_ENTRY; returns id + priv
	b1 := u.persistentBlob(t, s, 1000)
	b2 := u.persistentBlob(t, s, 2000)
	m1 := u.backupMeta(t, s, 1, b1)
	m2 := u.backupMeta(t, s, 2, b2)
	got, err := s.BackupFor(ctx, "anna")
	if err != nil || got.Version != 2 || !bytes.Equal(got.BlobKey, b2) {
		t.Fatalf("BackupFor: %+v %v", got, err)
	}
	if _, err := s.Blob(ctx, b1); !errors.Is(err, ErrNotFound) {
		t.Fatal("superseded blob still live")
	}
	if gone, _ := s.BlobGone(ctx, b1); !gone {
		t.Fatal("superseded blob not tombstoned")
	}
	if _, err := s.Get(ctx, m1); !errors.Is(err, ErrNotFound) {
		t.Fatal("superseded meta record kept")
	}
	// a lagging peer re-sends v1: nothing changes
	u.reapply(t, s, m1)
	if got, _ := s.BackupFor(ctx, "anna"); got.Version != 2 {
		t.Fatal("old version won")
	}
	_ = m2
}

func TestPersistentBlobSurvivesReadGCAndAge(t *testing.T) {
	s, _ := open(t)
	ctx := context.Background()
	u := newUser(t, s, "anna")
	b := u.persistentBlob(t, s, 1000)
	u.backupMeta(t, s, 1, b)
	if _, err := s.Expire(ctx, time.Now().Add(400*24*time.Hour).UnixMilli()); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Blob(ctx, b); err != nil {
		t.Fatalf("referenced persistent blob deleted: %v", err)
	}
}

func TestUnreferencedPersistentBlobCollected(t *testing.T) {
	s, _ := open(t)
	ctx := context.Background()
	u := newUser(t, s, "anna")
	b := u.persistentBlob(t, s, 1000)
	if _, err := s.Expire(ctx, time.Now().Add(6*24*time.Hour).UnixMilli()); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Blob(ctx, b); err != nil {
		t.Fatal("collected before 7 days")
	}
	if _, err := s.Expire(ctx, time.Now().Add(8*24*time.Hour).UnixMilli()); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Blob(ctx, b); !errors.Is(err, ErrNotFound) {
		t.Fatal("unreferenced persistent blob kept")
	}
}

func TestInstallOrdering(t *testing.T) {
	s, _ := open(t)
	ctx := context.Background()
	u := newUser(t, s, "anna")
	u.prekeys(t, s, 111, 0, []uint32{1, 2})      // pre-M6 install
	u.prekeys(t, s, 222, 5000, []uint32{1})      // restore
	rid, inst, err := s.DeviceInstall(ctx, u.id, 1)
	if err != nil || rid != 222 || inst != 5000 {
		t.Fatalf("after restore: %d %d %v", rid, inst, err)
	}
	if n := countPrekeys(t, s, u.id); n != 3 { // signed + kyber + one one-time key of the new install
		t.Fatalf("old install's keys kept: %d rows", n)
	}
	u.prekeys(t, s, 111, 0, []uint32{3})         // old phone refills late
	if rid, _, _ := s.DeviceInstall(ctx, u.id, 1); rid != 222 {
		t.Fatal("older install took over")
	}
	if n := countPrekeys(t, s, u.id); n != 3 {
		t.Fatalf("older install's keys added: %d rows", n)
	}
}

func TestAuthFailures(t *testing.T) {
	s, _ := open(t)
	ctx := context.Background()
	for i := 0; i < 3; i++ {
		if err := s.AddAuthFailure(ctx, "anna", 1000+int64(i)); err != nil {
			t.Fatal(err)
		}
	}
	s.AddAuthFailure(ctx, "boris", 1005)
	if n, _ := s.AuthFailures(ctx, "anna", 1001); n != 2 {
		t.Fatalf("anna since 1001: %d", n)
	}
	if n, _ := s.AuthFailuresTotal(ctx, 0); n != 4 {
		t.Fatalf("total: %d", n)
	}
}
```

Write the small helpers (`newUser`, `persistentBlob`, `backupMeta`, `reapply`, `prekeys`, `countPrekeys`) at the
bottom of the test file on top of the package's existing record-signing helper: `persistentBlob` signs a `BLOB_META`
with `Persistent: true`, one chunk hash per 256 KiB of `size`, `ExpiresMs: 0`, applies it with `s.Apply`, returns
`author‖id`; `backupMeta(version, blobKey)` signs a `BACKUP_META` with valid fields (Task 1) and returns its record key;
`reapply` calls `s.ApplyFrom(ctx, rec, body, peerID)` with a stored copy of the record; `prekeys(rid, installed,
oneTimeIDs)` signs a `PREKEYS` with a 33-byte signed key, a 1000-byte kyber key, those one-time ids and `InstalledMs`;
`countPrekeys` = `SELECT COUNT(*) FROM prekeys WHERE user_id=?` via `s.r`. Run → FAIL.

- [ ] **Step 3: Implement.**

`apply.go` — `expiring` takes the body:

```go
// expiring records leave the oplog after RetentionMs; a peer re-sending one must not resurrect it.
// Persistent blob metas (backups, D50) never expire by age.
func expiring(b *pb.RecordBody) bool {
	switch b.Type {
	case pb.RecordType_ENVELOPE, pb.RecordType_ACK, pb.RecordType_PREKEY_CONSUMED, pb.RecordType_BLOB_FETCHED:
		return true
	case pb.RecordType_BLOB_META:
		return b.ExpiresMs != 0
	}
	return false
}
```
and at the call site `expiring(it.body)`.

`typed.go` — `gcBlob` gains `now int64` and a persistent-aware tombstone and read-GC skip:

```go
func gcBlob(ctx context.Context, tx *sql.Tx, key []byte, force bool, now int64) error {
	var expires int64
	var persistent bool
	err := tx.QueryRowContext(ctx, `SELECT expires_ms, persistent FROM blobs WHERE blob_key=?`, key).Scan(&expires, &persistent)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	if !force {
		if persistent {
			return nil // backups are deleted only when superseded or unreferenced (D50)
		}
		// … existing "waiting readers" check unchanged …
	}
	// … existing DELETEs unchanged …
	until := expires + 24*time.Hour.Milliseconds()
	if persistent {
		until = now + 30*24*time.Hour.Milliseconds()
	}
	_, err = tx.ExecContext(ctx, `INSERT OR REPLACE INTO blob_tombstones(blob_key,until_ms) VALUES(?,?)`, key, until)
	return err
}
```
Update every caller (`BLOB_META`, `BLOB_FETCHED` cases pass `now`; janitor passes `now`). In the `BLOB_META` case
insert `persistent`: `INSERT OR IGNORE INTO blobs(blob_key,owner,size,chunks,expires_ms,created_ms,persistent) VALUES(?,?,?,?,?,?,?)`
with `m.Persistent`.

`typed.go` — new `BACKUP_META` case:

```go
	case pb.RecordType_BACKUP_META:
		var m pb.BackupMeta
		if err := proto.Unmarshal(b.Payload, &m); err != nil {
			return err
		}
		var curKey, curBlob []byte
		var curVer, curCreated int64
		err := tx.QueryRowContext(ctx, `SELECT record_key, version, created_ms, blob_key FROM backups WHERE user_id=?`,
			b.Author).Scan(&curKey, &curVer, &curCreated, &curBlob)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		newer := errors.Is(err, sql.ErrNoRows) || int64(m.Version) > curVer ||
			(int64(m.Version) == curVer && (b.CreatedMs > curCreated || (b.CreatedMs == curCreated && bytes.Compare(it.key, curKey) > 0)))
		if !newer { // an older or equal-but-losing version (e.g. from a lagging peer): drop it again
			_, err := tx.ExecContext(ctx, `DELETE FROM records WHERE record_key=?`, it.key)
			return err
		}
		if _, err := tx.ExecContext(ctx, `INSERT OR REPLACE INTO backups(user_id,record_key,version,created_ms,blob_key) VALUES(?,?,?,?,?)`,
			b.Author, it.key, m.Version, b.CreatedMs, m.BlobKey); err != nil {
			return err
		}
		if curKey != nil {
			if _, err := tx.ExecContext(ctx, `DELETE FROM records WHERE record_key=?`, curKey); err != nil {
				return err
			}
			if !bytes.Equal(curBlob, m.BlobKey) {
				return gcBlob(ctx, tx, curBlob, true, now)
			}
		}
		return nil
```

`typed.go` — `PREKEYS` case: before the device upsert, compare installs:

```go
		var curInstalled int64
		var curRid uint32
		err := tx.QueryRowContext(ctx, `SELECT registration_id, installed_ms FROM devices WHERE user_id=? AND device_id=?`,
			b.Author, p.DeviceId).Scan(&curRid, &curInstalled)
		exists := err == nil
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		switch {
		case exists && p.InstalledMs < curInstalled:
			return nil // an older install (a phone that was replaced): its keys must not be handed out (D52)
		case exists && p.InstalledMs > curInstalled:
			if _, err := tx.ExecContext(ctx, `DELETE FROM prekeys WHERE user_id=? AND device_id=?`, b.Author, p.DeviceId); err != nil {
				return err
			}
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO devices(user_id,device_id,registration_id,installed_ms) VALUES(?,?,?,?)
			 ON CONFLICT(user_id,device_id) DO UPDATE SET registration_id=excluded.registration_id, installed_ms=excluded.installed_ms`,
			b.Author, p.DeviceId, p.RegistrationId, p.InstalledMs); err != nil {
			return err
		}
		// … existing put(signed), put(kyber), one-time inserts unchanged …
```
(Replace the old device upsert with this one. Equal installs keep today's behaviour: one-time keys are added.)

`janitor.go` — after the expired-blob loop, collect unreferenced persistent blobs:

```go
		rows, err = tx.QueryContext(ctx, `SELECT blob_key FROM blobs WHERE persistent=1 AND created_ms < ?
			AND blob_key NOT IN (SELECT blob_key FROM backups)`, now-7*24*time.Hour.Milliseconds())
		if err != nil {
			return err
		}
		var orphans [][]byte
		for rows.Next() {
			var k []byte
			if err := rows.Scan(&k); err != nil {
				rows.Close()
				return err
			}
			orphans = append(orphans, k)
		}
		rows.Close()
		for _, k := range orphans {
			if err := gcBlob(ctx, tx, k, true, now); err != nil {
				return err
			}
			st.Blobs++
		}
		if err := exec(&ignore, `DELETE FROM auth_failures WHERE at_ms < ?`, now-24*time.Hour.Milliseconds()); err != nil {
			return err
		}
```
Also make the expired-blob query skip persistent ones: `SELECT blob_key FROM blobs WHERE persistent=0 AND expires_ms < ?`.

`internal/store/backups.go`:

```go
package store

import (
	"context"
	"database/sql"
	"errors"
)

// Backup is a user's current BACKUP_META (D50).
type Backup struct {
	UserID, RecordKey, BlobKey []byte
	Version                    int64
	Raw                        []byte // serialized pb.Record of the BACKUP_META
}

// BackupFor returns the current backup of the user with this username, or ErrNotFound.
func (s *Store) BackupFor(ctx context.Context, username string) (*Backup, error) {
	b := &Backup{}
	err := s.r.QueryRowContext(ctx, `SELECT k.user_id, k.record_key, k.blob_key, k.version, r.raw
		FROM backups k JOIN users u ON u.user_id = k.user_id JOIN records r ON r.record_key = k.record_key
		WHERE u.username = ? AND u.revoked = 0`, username).Scan(&b.UserID, &b.RecordKey, &b.BlobKey, &b.Version, &b.Raw)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return b, err
}

// DeviceInstall returns the registration id and install time of the newest install of a device (D52).
func (s *Store) DeviceInstall(ctx context.Context, user []byte, device uint32) (uint32, int64, error) {
	var rid uint32
	var inst int64
	err := s.r.QueryRowContext(ctx, `SELECT registration_id, installed_ms FROM devices WHERE user_id=? AND device_id=?`,
		user, device).Scan(&rid, &inst)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, 0, ErrNotFound
	}
	return rid, inst, err
}

// PersistentBlobs counts the user's live persistent blobs (D50 limit).
func (s *Store) PersistentBlobs(ctx context.Context, owner []byte) (int, error) {
	var n int
	err := s.r.QueryRowContext(ctx, `SELECT COUNT(*) FROM blobs WHERE owner=? AND persistent=1`, owner).Scan(&n)
	return n, err
}

func (s *Store) AddAuthFailure(ctx context.Context, username string, atMs int64) error {
	return s.write(ctx, func(ctx context.Context, tx *sql.Tx) error {
		_, err := tx.ExecContext(ctx, `INSERT INTO auth_failures(username, at_ms) VALUES(?,?)`, username, atMs)
		return err
	})
}

func (s *Store) AuthFailures(ctx context.Context, username string, sinceMs int64) (int, error) {
	var n int
	err := s.r.QueryRowContext(ctx, `SELECT COUNT(*) FROM auth_failures WHERE username=? AND at_ms >= ?`, username, sinceMs).Scan(&n)
	return n, err
}

func (s *Store) AuthFailuresTotal(ctx context.Context, sinceMs int64) (int, error) {
	var n int
	err := s.r.QueryRowContext(ctx, `SELECT COUNT(*) FROM auth_failures WHERE at_ms >= ?`, sinceMs).Scan(&n)
	return n, err
}
```
(`s.write` is the single-writer helper used by `Expire`; check its signature in `store.go`/`janitor.go`. If
`users` has no `revoked` column, read `0001_init.sql`/`0002_m1.sql` and use the real column.) Run tests → PASS;
`make check` → PASS (existing blob tests must still pass: non-persistent behaviour is unchanged).

- [ ] **Step 4: Commit** `feat(store): backups, persistent blobs, newest install wins`.

---

### Task 3: Node methods — restore auth, backup publish, login response

**Goal:** A phone can find, authenticate and download its backup without logging in; logged-in phones publish backups
and learn the newest install on login.

**Files:**
- Create: `otter-server/internal/service/backup.go`, `otter-server/internal/service/backup_test.go`
- Modify: `otter-server/internal/service/service.go` (`VerifyLogin`), `internal/service/blobs.go` (`CreateBlob`),
  `internal/gateway/methods.go`, `internal/gateway/gateway.go` (session field), `internal/gateway/gateway_test.go`

**Acceptance Criteria:**
- [ ] `backup.auth{username}`: real salt + params for a user with a backup; for an unknown user or no backup a fake salt
  that is identical on repeated calls and differs per username; params 65536/3/1.
- [ ] `backup.fetch`: correct secret → both meta records; wrong → `UNAUTHORIZED` and one `auth_failures` row; the 6th
  failure for a username within an hour, or the 21st on the node within a day → `RETRY_LATER` without checking.
- [ ] After a successful fetch the same connection (not logged in) can `blob.get` that blob's chunks and nothing else.
- [ ] `backup.publish` (logged in) accepts only `BACKUP_META` whose blob is a persistent blob of the author.
- [ ] `blob.create` with a persistent meta beyond 3 live persistent blobs → `QUOTA`.
- [ ] `auth.login` returns `LoginResponse{registration_id, installed_ms}` (zeros if the device is unknown).

**Verify:** `cd otter-server && go test ./internal/service/ ./internal/gateway/ -v -run 'Backup|Login' && make check`

**Steps:**

- [ ] **Step 1: Failing service tests** `internal/service/backup_test.go` — use the service test helpers that M4's
`blobs_test.go` uses to build a `Service` on a temp store and register a user (read it first). Cases:

```go
func TestBackupAuthFakeSaltStable(t *testing.T) {
	svc := newTestService(t)
	ctx := context.Background()
	a1, err := svc.BackupAuth(ctx, "nobody")
	if err != nil {
		t.Fatal(err)
	}
	a2, _ := svc.BackupAuth(ctx, "nobody")
	b, _ := svc.BackupAuth(ctx, "somebody")
	if !bytes.Equal(a1.Salt, a2.Salt) || bytes.Equal(a1.Salt, b.Salt) || len(a1.Salt) != 16 {
		t.Fatalf("fake salts: %x %x %x", a1.Salt, a2.Salt, b.Salt)
	}
	if a1.KdfMKib != 65536 || a1.KdfT != 3 || a1.KdfP != 1 {
		t.Fatalf("params: %+v", a1)
	}
}

func TestBackupFetchAndRateLimit(t *testing.T) {
	svc := newTestService(t)
	ctx := context.Background()
	u := registerUser(t, svc, "anna")
	secret := bytes.Repeat([]byte{9}, 32)
	salt := u.publishBackup(t, svc, secret) // persistent blob + BACKUP_META with verifier SHA-256(secret)
	got, err := svc.BackupAuth(ctx, "anna")
	if err != nil || !bytes.Equal(got.Salt, salt) {
		t.Fatalf("auth: %v", err)
	}
	res, blobKey, err := svc.BackupFetch(ctx, "anna", secret)
	if err != nil || res.BackupMeta == nil || res.BlobMeta == nil || len(blobKey) != 32 {
		t.Fatalf("fetch: %v", err)
	}
	for i := 0; i < 5; i++ {
		if _, _, err := svc.BackupFetch(ctx, "anna", make([]byte, 32)); !errors.Is(err, ErrUnauthorized) {
			t.Fatalf("wrong secret %d: %v", i, err)
		}
	}
	if _, _, err := svc.BackupFetch(ctx, "anna", secret); !errors.Is(err, ErrRetryLater) {
		t.Fatalf("6th attempt in an hour must be limited even with the right secret: %v", err)
	}
	svc.Now = func() time.Time { return time.Now().Add(61 * time.Minute) }
	if _, _, err := svc.BackupFetch(ctx, "anna", secret); err != nil {
		t.Fatalf("after an hour: %v", err)
	}
}

func TestBackupFetchUnknownCountsFailure(t *testing.T) {
	svc := newTestService(t)
	if _, _, err := svc.BackupFetch(context.Background(), "ghost", make([]byte, 32)); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("unknown user: %v", err)
	}
	if n, _ := svc.Store.AuthFailures(context.Background(), "ghost", 0); n != 1 {
		t.Fatal("failure not counted")
	}
}
```

Run → FAIL.

- [ ] **Step 2: `internal/service/backup.go`:**

```go
package service

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"fmt"
	"time"

	"google.golang.org/protobuf/proto"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/store"
)

// Restore authentication (D51).
const (
	DefaultKdfMKib     = 65536
	DefaultKdfT        = 3
	DefaultKdfP        = 1
	MaxFailuresPerName = 5  // per username per hour, per node
	MaxFailuresPerNode = 20 // per day, per node
)

func (s *Service) fakeSalt(username string) []byte {
	k := sha256.Sum256(append([]byte("otter/fake-salt/v1"), s.NodeKeyPriv...))
	m := hmac.New(sha256.New, k[:])
	m.Write([]byte(username))
	return m.Sum(nil)[:16]
}

func (s *Service) currentBackup(ctx context.Context, username string) (*store.Backup, *pb.BackupMeta, error) {
	b, err := s.Store.BackupFor(ctx, username)
	if err != nil {
		return nil, nil, err
	}
	var rec pb.Record
	var body pb.RecordBody
	var m pb.BackupMeta
	if err := proto.Unmarshal(b.Raw, &rec); err != nil {
		return nil, nil, err
	}
	if err := proto.Unmarshal(rec.Body, &body); err != nil {
		return nil, nil, err
	}
	return b, &m, proto.Unmarshal(body.Payload, &m)
}

// BackupAuth returns the KDF salt and parameters for a username; a stable fake salt when there is no backup.
func (s *Service) BackupAuth(ctx context.Context, username string) (*pb.BackupAuthResponse, error) {
	_, m, err := s.currentBackup(ctx, username)
	if errors.Is(err, store.ErrNotFound) {
		return &pb.BackupAuthResponse{Salt: s.fakeSalt(username), KdfMKib: DefaultKdfMKib, KdfT: DefaultKdfT, KdfP: DefaultKdfP}, nil
	}
	if err != nil {
		return nil, err
	}
	return &pb.BackupAuthResponse{Salt: m.Salt, KdfMKib: m.KdfMKib, KdfT: m.KdfT, KdfP: m.KdfP}, nil
}

// BackupFetch checks auth_secret against the verifier; on success returns both meta records and the blob key.
func (s *Service) BackupFetch(ctx context.Context, username string, secret []byte) (*pb.BackupFetchResponse, []byte, error) {
	now := s.Now()
	perName, err := s.Store.AuthFailures(ctx, username, now.Add(-time.Hour).UnixMilli())
	if err != nil {
		return nil, nil, err
	}
	total, err := s.Store.AuthFailuresTotal(ctx, now.Add(-24*time.Hour).UnixMilli())
	if err != nil {
		return nil, nil, err
	}
	if perName >= MaxFailuresPerName || total >= MaxFailuresPerNode {
		return nil, nil, fmt.Errorf("%w: too many attempts", ErrRetryLater)
	}
	fail := func() error {
		if err := s.Store.AddAuthFailure(ctx, username, now.UnixMilli()); err != nil {
			return err
		}
		return fmt.Errorf("%w: wrong username or password", ErrUnauthorized)
	}
	b, m, err := s.currentBackup(ctx, username)
	if errors.Is(err, store.ErrNotFound) {
		return nil, nil, fail()
	}
	if err != nil {
		return nil, nil, err
	}
	v := sha256.Sum256(secret)
	if len(secret) != 32 || subtle.ConstantTimeCompare(v[:], m.AuthVerifier) != 1 {
		return nil, nil, fail()
	}
	blobRaw, err := s.Store.Get(ctx, m.BlobKey)
	if errors.Is(err, store.ErrNotFound) {
		return nil, nil, fmt.Errorf("%w: backup not replicated here yet", ErrRetryLater)
	}
	if err != nil {
		return nil, nil, err
	}
	var meta, blob pb.Record
	if err := proto.Unmarshal(b.Raw, &meta); err != nil {
		return nil, nil, err
	}
	if err := proto.Unmarshal(blobRaw, &blob); err != nil {
		return nil, nil, err
	}
	return &pb.BackupFetchResponse{BackupMeta: &meta, BlobMeta: &blob}, bytes.Clone(m.BlobKey), nil
}

// PublishBackup stores a BACKUP_META whose blob is one of the author's persistent blobs.
func (s *Service) PublishBackup(ctx context.Context, user []byte, rec *pb.Record) error {
	body, err := s.validator(nil).Validate(rec)
	if err != nil {
		return invalid(err)
	}
	if body.Type != pb.RecordType_BACKUP_META || !bytes.Equal(body.Author, user) {
		return fmt.Errorf("%w: not the author's backup meta", ErrInvalid)
	}
	var m pb.BackupMeta
	if err := proto.Unmarshal(body.Payload, &m); err != nil {
		return fmt.Errorf("%w: %v", ErrInvalid, err)
	}
	blob, err := s.Store.Blob(ctx, m.BlobKey)
	if errors.Is(err, store.ErrNotFound) {
		return fmt.Errorf("%w: backup blob unknown here", ErrInvalid)
	} else if err != nil {
		return err
	}
	if !bytes.Equal(blob.Owner, user) || len(blob.Readers) != 0 || blob.ExpiresMs != 0 {
		return fmt.Errorf("%w: not the author's persistent blob", ErrInvalid)
	}
	_, err = s.Submit(ctx, user, rec, pb.RecordType_BACKUP_META)
	return err
}
```
(`s.Store.Get(ctx, key)` returns the raw record — confirm the name in `query.go`; M4's `blobs_test` uses `Get`.)
`Submit` must accept `BACKUP_META`; if its type switch rejects unknown types, add an empty case.

`blobs.go` `CreateBlob`, after unmarshalling `m`:

```go
	if m.Persistent {
		n, err := s.Store.PersistentBlobs(ctx, user)
		if err != nil {
			return nil, err
		}
		if n >= 3 {
			return nil, fmt.Errorf("%w: too many backup blobs in flight", ErrQuota)
		}
	}
```

`service.go` `VerifyLogin` returns the install:

```go
func (s *Service) VerifyLogin(ctx context.Context, nonce []byte, req *pb.LoginRequest) (*pb.LoginResponse, error) {
	// … existing checks, each `return err` becomes `return nil, err` …
	rid, inst, err := s.Store.DeviceInstall(ctx, req.UserId, req.DeviceId)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		return nil, err
	}
	return &pb.LoginResponse{RegistrationId: rid, InstalledMs: inst}, nil
}
```
Fix every caller (`grep -rn VerifyLogin internal/`).

- [ ] **Step 3: Gateway.** In `gateway.go` add to `session`: `backupBlob, backupOwner []byte // granted by backup.fetch (D51)`
(guarded by `s.mu`). In `methods.go`:

```go
var public = map[string]bool{"ping": true, "manifest.get": true, "manifest.publish": true, "register": true,
	"auth.login": true, "backup.auth": true, "backup.fetch": true}
```

dispatch gate: `if !public[req.Method] && !s.loggedIn() && !(req.Method == "blob.get" && s.hasGrant()) {`, with

```go
func (s *session) hasGrant() bool { s.mu.Lock(); defer s.mu.Unlock(); return s.backupBlob != nil }
```

`auth.login` case: `resp, err := svc.VerifyLogin(ctx, s.nonce, &r)`; on success … `return resp, nil`.

New cases:

```go
	case "backup.auth":
		var r pb.BackupAuthRequest
		if err := decode(req.Body, &r); err != nil {
			return nil, err
		}
		return svc.BackupAuth(ctx, r.Username)
	case "backup.fetch":
		var r pb.BackupFetchRequest
		if err := decode(req.Body, &r); err != nil {
			return nil, err
		}
		res, key, err := svc.BackupFetch(ctx, r.Username, r.AuthSecret)
		if err != nil {
			return nil, err
		}
		var body pb.RecordBody
		_ = proto.Unmarshal(res.BackupMeta.Body, &body)
		s.mu.Lock()
		s.backupBlob, s.backupOwner = key, body.Author
		s.mu.Unlock()
		return res, nil
	case "backup.publish":
		var r pb.RecordRequest
		if err := decode(req.Body, &r); err != nil {
			return nil, err
		}
		if r.Record == nil {
			return nil, fmt.Errorf("%w: record missing", service.ErrInvalid)
		}
		return &pb.Empty{}, svc.PublishBackup(ctx, s.user, r.Record)
```

`blob.get` case: choose the reading user:

```go
		user := s.user
		if !s.loggedIn() {
			s.mu.Lock()
			ok := bytes.Equal(s.backupBlob, r.BlobKey)
			user = s.backupOwner
			s.mu.Unlock()
			if !ok {
				return nil, fmt.Errorf("%w: login required", service.ErrUnauthorized)
			}
		}
		data, err := svc.GetChunk(ctx, user, r.BlobKey, r.Index)
```
(`blob.get` runs off the read loop since M4 — keep that structure; only the user selection changes.)

- [ ] **Step 4: Gateway e2e tests** in `internal/gateway/gateway_test.go` using `startNode`, `dial`, `call`,
`registerReq`, `login`, `sign`: (a) login response carries the registration id from the registration's PREKEYS;
(b) full flow: anna logs in, `blob.create` persistent meta, `blob.put` chunks, `backup.publish`; a second fresh
connection calls `backup.auth` (salt matches), `backup.fetch` (ok), `blob.get` chunk 0 (bytes match); `blob.get` of
another blob key → `UNAUTHORIZED`; a third connection without fetch → `blob.get` → `UNAUTHORIZED`. Write them in the
style of the M4 gateway blob tests in the same file.

Run `go test ./internal/service/ ./internal/gateway/` → PASS; `make check` → PASS.

- [ ] **Step 5: Commit** `feat(node): backup.auth/fetch/publish, restore grant, login response`.

---

### Task 4: Mesh scenarios

**Goal:** Prove a backup uploaded through node A restores through node C while A is down, and that install ordering
holds when records arrive out of order across nodes.

**Files:**
- Create: `otter-server/internal/meshsim/backup_test.go`

**Acceptance Criteria:**
- [ ] `TestBackupRestoreThroughOtherNode`: anna uploads a 3 MiB persistent blob + `BACKUP_META` via A; C has the meta
  and all chunks (`eventually`); A stopped; a fresh connection to C: `backup.auth` → same salt, `backup.fetch` → ok,
  every `blob.get` chunk matches; anna publishes v2 via C; after A restarts, A has no trace of v1's blob (tombstone)
  and serves v2.
- [ ] `TestNewerInstallWinsAcrossNodes`: PREKEYS install 2 via B, then a late PREKEYS refill of install 1 via C;
  every node reports install 2 in `auth.login`'s response.

**Verify:** `cd otter-server && go test ./internal/meshsim/ -run 'Backup|Install' -v -count=1 && make check`

**Steps:**

- [ ] **Step 1:** Write the two tests with the meshsim harness (`newSim(t, "a","b","c")`, `s.register`, `s.login`,
`s.stop`/`s.start`, `eventually`, and `putBlob` from `blobs_test.go` — extend `putBlob` with a variant
`putPersistentBlob(c, a, data)` that sets `Persistent: true`, no readers, `ExpiresMs: 0`). Sign `BACKUP_META` with
`s.signAs(a, pb.RecordType_BACKUP_META, &pb.BackupMeta{…})` (verifier = SHA-256 of a fixed 32-byte secret). Use a
one-minute `eventually` budget for multi-MiB transfers (as M4's large scenarios).

```go
func TestBackupRestoreThroughOtherNode(t *testing.T) {
	s := newSim(t, "a", "b", "c")
	a, c := s.node("a"), s.node("c")
	anna := s.register(a, "anna")
	ca := s.login(a, anna)
	data := make([]byte, 3<<20)
	rand.Read(data)
	blob := s.putPersistentBlob(ca, anna, data)
	secret := bytes.Repeat([]byte{5}, 32)
	v := sha256.Sum256(secret)
	salt := bytes.Repeat([]byte{1}, 16)
	meta := s.signAs(anna, pb.RecordType_BACKUP_META, &pb.BackupMeta{Version: 1, Salt: salt, KdfMKib: 65536, KdfT: 3, KdfP: 1,
		AuthVerifier: v[:], BlobKey: blob, Size: uint64(len(data))})
	ca.mustCall("backup.publish", &pb.RecordRequest{Record: meta}, &pb.Empty{})
	eventually(t, time.Minute, "c holds the backup", func() bool { return c.hasAllChunks(blob) && c.hasRecord(recordKey(meta)) })
	s.stop(a)

	fresh := s.dial(c)
	var auth pb.BackupAuthResponse
	fresh.mustCall("backup.auth", &pb.BackupAuthRequest{Username: "anna"}, &auth)
	if !bytes.Equal(auth.Salt, salt) {
		t.Fatal("salt")
	}
	var res pb.BackupFetchResponse
	fresh.mustCall("backup.fetch", &pb.BackupFetchRequest{Username: "anna", AuthSecret: secret}, &res)
	var got []byte
	for i := 0; i*chunk < len(data); i++ {
		var ch pb.BlobChunk
		fresh.mustCall("blob.get", &pb.BlobGetRequest{BlobKey: blob, Index: uint32(i)}, &ch)
		got = append(got, ch.Data...)
	}
	if !bytes.Equal(got, data) {
		t.Fatal("restored bytes differ")
	}
	// v2 via c while a is down; a must drop v1 when it comes back
	cc := s.login(c, anna)
	blob2 := s.putPersistentBlob(cc, anna, data[:1<<20])
	meta2 := s.signAs(anna, pb.RecordType_BACKUP_META, &pb.BackupMeta{Version: 2, Salt: salt, KdfMKib: 65536, KdfT: 3, KdfP: 1,
		AuthVerifier: v[:], BlobKey: blob2, Size: 1 << 20})
	cc.mustCall("backup.publish", &pb.RecordRequest{Record: meta2}, &pb.Empty{})
	s.start(a)
	eventually(t, time.Minute, "a forgets v1", func() bool { return a.blobGone(blob) && a.hasRecord(recordKey(meta2)) })
}
```
Add small node helpers to the harness if missing: `hasRecord(key)` (open the node's store read-only or reuse an
existing `has` helper), `hasAllChunks(key)`, `blobGone(key)` — check `blobs_test.go` for existing equivalents first and
reuse them.

`TestNewerInstallWinsAcrossNodes`: register anna on A (install 0), sign `PREKEYS{RegistrationId: 2, InstalledMs: 5000,
signed, kyber}` and submit via B (`prekeys.upload`), then `PREKEYS{RegistrationId: <the original>, InstalledMs: 0,
OneTime: …}` via C; `eventually` every node's `auth.login` response (log in as anna on each) has `RegistrationId == 2`.

- [ ] **Step 2:** Run `go test ./internal/meshsim/ -count=1` (whole package) → PASS; `make check` → PASS.
- [ ] **Step 3: Commit** `test(meshsim): backup restore through another node; newest install wins`.

---

### Task 5: Android — protos, backup crypto, node API

**Goal:** The app speaks the new methods and derives backup keys exactly per D55.

**Files:**
- Modify: `otter-android/core/proto/src/main/proto/otter/v1/*` (via `scripts/sync-proto.sh`)
- Modify: `otter-android/gradle/libs.versions.toml`, `core/crypto/build.gradle.kts`
- Create: `core/crypto/src/main/kotlin/app/ottermsg/core/crypto/BackupKeys.kt`,
  `core/crypto/src/test/kotlin/app/ottermsg/core/crypto/BackupKeysTest.kt`
- Modify: `core/network/src/main/kotlin/app/ottermsg/core/network/NodeApi.kt`;
  `core/data/src/test/kotlin/app/ottermsg/core/data/FakeNode.kt`; `ConnectionBannerTest`'s `FakeApi`
  (`feature/chats/src/test/...`), and any other `NodeApi` implementation (`grep -rn ": NodeApi" --include=*.kt`)

**Acceptance Criteria:**
- [ ] `BackupKeys.derive(password, salt, m, t, p)` matches the RFC 9106 Argon2id vector for the raw Argon2 step and
  returns `backupKey` (32 B), `authSecret` (32 B), `verifier = SHA-256(authSecret)`; different passwords → different keys.
- [ ] `NodeApi.login` returns `LoginResponse`; `backupAuth`, `backupFetch`, `backupPublish` exist in `RemoteNodeApi`.
- [ ] `FakeNode` implements them with Go's rules (latest version wins, fake salt, grant, 5/hour limit, newest install
  wins in `uploadPrekeys`, login response).
- [ ] `./gradlew test` passes.

**Verify:** `cd otter-android && ./gradlew :core:crypto:test :core:network:test :core:data:testDebugUnitTest --tests '*BackupKeys*' --tests '*FakeNode*'` then `./gradlew test`

**Steps:**

- [ ] **Step 1:** `scripts/sync-proto.sh`. Add to `libs.versions.toml`:
`bouncycastle = "1.80"`, `zxcvbn = "1.9.0"`; libraries
`bouncycastle-prov = { module = "org.bouncycastle:bcprov-jdk18on", version.ref = "bouncycastle" }`,
`zxcvbn = { module = "com.nulabinc.zxcvbn:zxcvbn", version.ref = "zxcvbn" }`. In `core/crypto/build.gradle.kts`:
`implementation(libs.bouncycastle.prov)`. (R8 keeps only the used classes; the release build in Task 12 checks size.
Android's own repackaged BC lives under `com.android.org.bouncycastle`, so there is no clash.)

- [ ] **Step 2: Failing test** `BackupKeysTest.kt`:

```kotlin
package app.ottermsg.core.crypto

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import java.security.MessageDigest

class BackupKeysTest {
    private fun hex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test fun argon2idMatchesRfc9106() {
        // RFC 9106 §5.3: Argon2id, m=32 KiB, t=3, p=4, password 32×01, salt 16×02, secret 8×03, ad 12×04
        val tag = BackupKeys.argon2id(ByteArray(32) { 1 }, ByteArray(16) { 2 }, mKib = 32, t = 3, p = 4, outLen = 32,
            secret = ByteArray(8) { 3 }, ad = ByteArray(12) { 4 })
        assertArrayEquals(hex("0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659"), tag)
    }

    @Test fun derivesSeparateKeysAndVerifier() {
        val salt = ByteArray(16) { 7 }
        val k = BackupKeys.derive("корова-лодка-зима-7", salt, mKib = 1024, t = 1, p = 1) // small params: fast test
        assertEquals(32, k.backupKey.size); assertEquals(32, k.authSecret.size)
        assertFalse(k.backupKey.contentEquals(k.authSecret))
        assertArrayEquals(MessageDigest.getInstance("SHA-256").digest(k.authSecret), k.verifier)
        val again = BackupKeys.derive("корова-лодка-зима-7", salt, mKib = 1024, t = 1, p = 1)
        assertArrayEquals(k.backupKey, again.backupKey)
        val other = BackupKeys.derive("корова-лодка-зима-8", salt, mKib = 1024, t = 1, p = 1)
        assertFalse(k.backupKey.contentEquals(other.backupKey))
    }
}
```
Run `./gradlew :core:crypto:test --tests '*BackupKeys*'` → FAIL.

- [ ] **Step 3: Implement** `BackupKeys.kt`:

```kotlin
package app.ottermsg.core.crypto

import com.google.crypto.tink.subtle.Hkdf
import org.bouncycastle.crypto.generators.Argon2BytesGenerator
import org.bouncycastle.crypto.params.Argon2Parameters
import java.security.MessageDigest
import java.security.SecureRandom

/** Password backup keys (docs/04 "Password backup", D55). The password never leaves the phone. */
object BackupKeys {
    const val M_KIB = 65536
    const val T = 3
    const val P = 1
    const val INFO_ENC = "otter/backup/enc/v1"
    const val INFO_AUTH = "otter/backup/auth/v1"

    class Keys(val backupKey: ByteArray, val authSecret: ByteArray) {
        val verifier: ByteArray get() = MessageDigest.getInstance("SHA-256").digest(authSecret)
    }

    fun newSalt(): ByteArray = ByteArray(16).also(SecureRandom()::nextBytes)

    fun argon2id(password: ByteArray, salt: ByteArray, mKib: Int, t: Int, p: Int, outLen: Int,
                 secret: ByteArray? = null, ad: ByteArray? = null): ByteArray {
        val b = Argon2Parameters.Builder(Argon2Parameters.ARGON2_id).withVersion(Argon2Parameters.ARGON2_VERSION_13)
            .withSalt(salt).withMemoryAsKB(mKib).withIterations(t).withParallelism(p)
        secret?.let { b.withSecret(it) }
        ad?.let { b.withAdditional(it) }
        val out = ByteArray(outLen)
        Argon2BytesGenerator().apply { init(b.build()) }.generateBytes(password, out)
        return out
    }

    /** master = Argon2id(password) → 64 bytes; backup_key / auth_secret = HKDF(master, info). */
    fun derive(password: String, salt: ByteArray, mKib: Int = M_KIB, t: Int = T, p: Int = P): Keys {
        val master = argon2id(password.toByteArray(Charsets.UTF_8), salt, mKib, t, p, 64)
        return Keys(Hkdf.computeHkdf("HMACSHA256", master, ByteArray(0), INFO_ENC.toByteArray(), 32),
            Hkdf.computeHkdf("HMACSHA256", master, ByteArray(0), INFO_AUTH.toByteArray(), 32))
    }
}
```
Run → PASS. (If the RFC vector fails, check `withVersion(ARGON2_VERSION_13)` and that `generateBytes(ByteArray, ByteArray)`
is used, not the `CharArray` overload.)

- [ ] **Step 4: `NodeApi`.** Change and add:

```kotlin
    /** auth.login; the answer names the newest install the node knows (D52). */
    suspend fun login(userId: ByteArray, account: Ed25519.KeyPair): LoginResponse
    /** Public: salt and KDF params for a username (fake but stable when there is no backup). */
    suspend fun backupAuth(username: String): BackupAuthResponse
    /** Public: on success this connection may blob.get the backup blob (D51). */
    suspend fun backupFetch(username: String, authSecret: ByteArray): BackupFetchResponse
    suspend fun backupPublish(meta: Record)
```

`RemoteNodeApi`:

```kotlin
    override suspend fun login(userId: ByteArray, account: Ed25519.KeyPair): LoginResponse {
        val h = rpc.hello.await()
        val ts = clock()
        val sig = account.sign(AuthMessage.build(h.nodeId.toByteArray(), h.nonce.toByteArray(), ts))
        return LoginResponse.parseFrom(rpc.call("auth.login", LoginRequest.newBuilder().setUserId(ByteString.copyFrom(userId))
            .setDeviceId(1).setTsMs(ts).setSignature(ByteString.copyFrom(sig)).build()))
    }
    override suspend fun backupAuth(username: String): BackupAuthResponse =
        BackupAuthResponse.parseFrom(rpc.call("backup.auth", BackupAuthRequest.newBuilder().setUsername(username).build()))
    override suspend fun backupFetch(username: String, authSecret: ByteArray): BackupFetchResponse =
        BackupFetchResponse.parseFrom(rpc.call("backup.fetch", BackupFetchRequest.newBuilder().setUsername(username)
            .setAuthSecret(ByteString.copyFrom(authSecret)).build()))
    override suspend fun backupPublish(meta: Record) { rpc.call("backup.publish", req(meta)) }
```
(An old node returns an empty body for `auth.login`; `parseFrom(empty)` gives zeros — compatible.)

Update every `NodeApi` implementation. `ConnectionBannerTest.FakeApi`: `login` returns
`LoginResponse.getDefaultInstance()`, the three new methods `throw UnsupportedOperationException()`.

- [ ] **Step 5: FakeNode.** In `FakeNode` add state and behaviour mirroring Go:
  - `Keys` gains `var installedMs: Long`; `uploadPrekeys`/`register` apply the D52 rule (newer → replace all keys and
    registration id; older → ignore; equal → merge as now).
  - `login` returns `LoginResponse(registrationId, installedMs)` of the user's keys.
  - `private val backups = HashMap<String /*user hex*/, Pair<Record, BackupMeta>>()`; `backupPublish` validates author,
    persistent blob present, keeps the higher version and drops the old blob from `blobs` (mark it in `goneBlobs`).
  - `blobCreate` accepts `persistent` metas (no readers, no expiry).
  - `backupAuth(username)`: real salt or `HmacSHA256(fakeKey, username)[:16]` with 65536/3/1.
  - `backupFetch`: per-username failure list (timestamps from the node clock); ≥ 5 in the last hour → `RETRY_LATER`;
    wrong secret → `UNAUTHORIZED` + record failure; success → set the session's `grantBlob`.
  - `blobGet` when not logged in: allowed only for `grantBlob`.
  - Test hooks: `fun backupOf(user: ByteArray): BackupMeta?`, `fun loginInfo(user: ByteArray): Pair<Int, Long>`.
  Add a short `FakeNodeBackupTest` (Robolectric) covering: latest wins, fake salt stable, grant only for that blob,
  rate limit, newest install wins.

Run `./gradlew test` → PASS (all existing tests compile against the new `login` return type).

- [ ] **Step 6: Commit** (android) `feat(api): backup methods, login response, Argon2id backup keys`.

---

### Task 6: Database v6 and settings

**Goal:** Storage for reset throttling, the new message/attachment states and all backup/install settings.

**Files:**
- Modify: `core/database/.../entity/ContactEntity.kt`, `model/MessageStatus.kt`, `OtterDatabase.kt`,
  `dao/ContactDao.kt`, `dao/GroupDao.kt`, `core/database/src/test/.../MigrationTest.kt`
- Modify: `core/data/src/main/kotlin/app/ottermsg/core/data/settings/Settings.kt`
- Create: `core/data/src/main/kotlin/app/ottermsg/core/data/backup/PasswordPolicy.kt` (+ test); `core/data/build.gradle.kts`

**Acceptance Criteria:**
- [ ] DB version 6 with `AutoMigration(from = 5, to = 6)`; `contacts.reset_ms INTEGER NOT NULL DEFAULT 0`; schema
  `6.json` exported; `MigrationTest.migrate5To6` keeps a contact row and reads `reset_ms = 0`.
- [ ] `MessageKind.SYSTEM_RESET = 4`; `AttachmentState.NOT_IN_BACKUP = 8`.
- [ ] `ContactDao.all()`, `ContactDao.setResetMs(id, ms)`, `GroupDao.deleteSharedWithMember(member)`.
- [ ] Settings: `installedMs`, `restorePending`, `superseded` (+ observe), `backupSecret` (wrapped bytes),
  `backupSalt`, `backupVersion`, `backupLastMs` (+ observe), `backupError` (+ observe).
- [ ] `PasswordPolicy.check(pw)` → `TOO_SHORT` (< 10), `WEAK` (zxcvbn < 3), `OK`; `score(pw)` 0–4.

**Verify:** `./gradlew :core:database:testDebugUnitTest --tests '*MigrationTest*' :core:data:testDebugUnitTest --tests '*PasswordPolicy*'`

**Steps:**

- [ ] **Step 1:** `ContactEntity` add
`@ColumnInfo(name = "reset_ms", defaultValue = "0") val resetMs: Long = 0, // last SessionReset we sent (D53)`.
`MessageKind`: `const val SYSTEM_RESET = 4`. `AttachmentState`: `const val NOT_IN_BACKUP = 8 // restored: thumbnail only (D55)`.
`OtterDatabase`: `version = 6`, add `AutoMigration(from = 5, to = 6)`. `ContactDao`:

```kotlin
    @Query("SELECT * FROM contacts") suspend fun all(): List<ContactEntity>
    @Query("UPDATE contacts SET reset_ms = :ms WHERE user_id = :id") suspend fun setResetMs(id: ByteArray, ms: Long)
```
`GroupDao`: `@Query("DELETE FROM sender_key_shared WHERE member = :member") suspend fun deleteSharedWithMember(member: ByteArray)`.

- [ ] **Step 2:** `MigrationTest`:

```kotlin
    @Test fun migrate5To6AddsResetMs() {
        helper.createDatabase("m6.db", 5).use {
            it.execSQL("""INSERT INTO contacts(user_id, username, display_name, account_pub, identity_pub, verified, identity_changed, revoked, entry_version)
                          VALUES (x'01', 'anna', 'Анна', x'02', x'03', 1, 0, 0, 1)""")
        }
        helper.runMigrationsAndValidate("m6.db", 6, true).use { db ->
            db.query("SELECT username, reset_ms FROM contacts").use { c -> c.moveToFirst(); assertEquals("anna", c.getString(0)); assertEquals(0, c.getInt(1)) }
        }
    }
```
Build once (`./gradlew :core:database:kspDebugKotlin`) so `schemas/.../6.json` is generated; commit it.

- [ ] **Step 3: Settings** — add (same style as existing):

```kotlin
    private suspend fun long(key: String): Long? = dao.get(key)?.let { ByteBuffer.wrap(it).long }
    private suspend fun putLong(key: String, v: Long) = dao.put(SettingEntity(key, ByteBuffer.allocate(8).putLong(v).array()))

    /** Time this install was created (registration or restore, D52); 0 for installs from before M6. */
    suspend fun installedMs(): Long = long(INSTALLED_MS) ?: 0
    suspend fun setInstalledMs(v: Long) = putLong(INSTALLED_MS, v)
    /** A restore wrote the database but prekeys/resets are not done yet (InstallGuard finishes it). */
    suspend fun restorePending(): Boolean = (int(RESTORE_PENDING) ?: 0) != 0
    suspend fun setRestorePending(v: Boolean) = putInt(RESTORE_PENDING, if (v) 1 else 0)
    /** Another phone restored this account; this install stopped syncing. */
    suspend fun superseded(): Boolean = (int(SUPERSEDED) ?: 0) != 0
    suspend fun setSuperseded(v: Boolean) = putInt(SUPERSEDED, if (v) 1 else 0)

    /** backup_key ‖ auth_secret wrapped by SeedVault; null = backup off. */
    suspend fun backupSecret(): ByteArray? = dao.get(BACKUP_SECRET)
    suspend fun setBackupSecret(v: ByteArray) = dao.put(SettingEntity(BACKUP_SECRET, v))
    suspend fun backupSalt(): ByteArray? = dao.get(BACKUP_SALT)
    suspend fun setBackupSalt(v: ByteArray) = dao.put(SettingEntity(BACKUP_SALT, v))
    suspend fun backupVersion(): Long = long(BACKUP_VERSION) ?: 0
    suspend fun setBackupVersion(v: Long) = putLong(BACKUP_VERSION, v)
    suspend fun backupLastMs(): Long = long(BACKUP_LAST_MS) ?: 0
    suspend fun setBackupLastMs(v: Long) = putLong(BACKUP_LAST_MS, v)
    /** Last backup error code (BackupManager.ERR_*), 0 = none. */
    suspend fun backupError(): Int = int(BACKUP_ERROR) ?: 0
    suspend fun setBackupError(v: Int) = putInt(BACKUP_ERROR, v)
```
with constants `INSTALLED_MS = "installed_ms"`, `RESTORE_PENDING = "restore_pending"`, `SUPERSEDED = "superseded"`,
`BACKUP_SECRET = "backup_secret"`, `BACKUP_SALT = "backup_salt"`, `BACKUP_VERSION = "backup_version"`,
`BACKUP_LAST_MS = "backup_last_ms"`, `BACKUP_ERROR = "backup_error"`, and
`fun observeLong(key: String, default: Long): Flow<Long> = dao.observe(key).map { it?.let { b -> ByteBuffer.wrap(b).long } ?: default }`.

- [ ] **Step 4: PasswordPolicy** — `core/data/build.gradle.kts`: `implementation(libs.zxcvbn)`.

```kotlin
package app.ottermsg.core.data.backup

import com.nulabinc.zxcvbn.Zxcvbn

/** Backup password rule (D55): at least 10 characters and zxcvbn score ≥ 3. */
object PasswordPolicy {
    enum class Result { OK, TOO_SHORT, WEAK }
    const val MIN_LENGTH = 10
    private val zxcvbn by lazy { Zxcvbn() }
    fun score(pw: String): Int = if (pw.isEmpty()) 0 else zxcvbn.measure(pw).score
    fun check(pw: String): Result = when {
        pw.length < MIN_LENGTH -> Result.TOO_SHORT
        score(pw) < 3 -> Result.WEAK
        else -> Result.OK
    }
}
```
Test: `"short"` → TOO_SHORT; `"password12"` → WEAK; `"корова лодка зима семь"` → OK; `"Tr0ub4dour&3x!Lake"` → OK.

- [ ] **Step 5:** Run verify → PASS; `./gradlew test` → PASS. **Commit** `feat(db): v6 reset_ms, restore/backup settings, password policy`.

---

### Task 7: Install identity and session recovery

**Goal:** Registrations carry `installed_ms`; a superseded phone stops; `SessionReset` is sent and handled; messages
that can't be decrypted trigger a throttled reset.

**Files:**
- Create: `core/data/src/main/kotlin/app/ottermsg/core/data/messaging/SessionResets.kt`,
  `core/data/src/main/kotlin/app/ottermsg/core/data/backup/InstallGuard.kt`
- Modify: `registration/Registration.kt`, `signal/PrekeyRefill.kt`, `messaging/MailboxReceiver.kt`,
  `messaging/GroupReceiver.kt`, `sync/SyncEngine.kt`, `di/DataModule.kt` (if bindings needed),
  `core/data/src/test/.../TestGraph.kt`, `LiveClient.kt`
- Test: `core/data/src/test/kotlin/app/ottermsg/core/data/SessionResetTest.kt`, `InstallGuardTest.kt`

**Acceptance Criteria:**
- [ ] New registrations store `installed_ms = now` and send it in PREKEYS; refills send the stored value.
- [ ] `InstallGuard.afterLogin(api, resp)`: if `restorePending` → uploads full PREKEYS (new signed/kyber/one-time per
  manifest node, `installed_ms`), clears the flag, queues `SessionReset` to every non-revoked contact; else if
  `resp.installedMs > settings.installedMs()` → `superseded = true` and returns `false` (SyncEngine stops).
- [ ] Receiving `SessionReset`: libsignal session replaced (decrypt of the PreKey message), `SYSTEM_RESET` message in
  the direct chat if it exists, `deleteSharedWithMember(sender)`, outbox kicked.
- [ ] Undecryptable 1:1 message, or a group envelope parked for a missing sender key: delete our session with the
  sender and queue `SessionReset`, only if `contacts.reset_ms < now - 1 h`; sets `reset_ms`.
- [ ] Test: two `TestGraph`s on one `FakeNode`; boris's Signal state is wiped (simulated restore) → boris sends
  SessionReset → anna→boris message decrypts; a group message from anna reaches boris after the reset (sender key re-sent).

**Verify:** `./gradlew :core:data:testDebugUnitTest --tests '*SessionReset*' --tests '*InstallGuard*'` then `./gradlew test`

**Steps:**

- [ ] **Step 1: Registration / refill.** In `Registration.doRegister` build PREKEYS with `.setInstalledMs(now)` and in
the transaction `settings.setInstalledMs(now)`. In `PrekeyRefill.refill`: `.setInstalledMs(settings.installedMs())`.

- [ ] **Step 2: `SessionResets.kt`:**

```kotlin
package app.ottermsg.core.data.messaging

import app.ottermsg.core.data.Clock
import app.ottermsg.core.database.OtterDatabase
import app.ottermsg.core.database.entity.MessageEntity
import app.ottermsg.core.database.entity.OutboxEntity
import app.ottermsg.core.database.model.MessageKind
import app.ottermsg.core.database.model.MessageStatus
import app.ottermsg.core.data.signal.SignalService
import app.ottermsg.proto.v1.Content
import app.ottermsg.proto.v1.SessionReset
import java.security.SecureRandom
import javax.inject.Inject
import javax.inject.Singleton

/** SessionReset (D53): after a restore, and when a contact's messages can't be decrypted. */
@Singleton
class SessionResets @Inject constructor(
    private val db: OtterDatabase, private val signal: SignalService, private val outbox: Outbox, private val clock: Clock,
) {
    private fun content() = Content.newBuilder().setSessionReset(SessionReset.getDefaultInstance()).setSentMs(clock.now()).build().toByteArray()

    /** Drops our session with [peer] (the next send builds a fresh one from its prekeys) and queues a reset. */
    suspend fun send(peer: ByteArray) {
        signal.withSessions { store, s -> store.deleteSession(s.address(peer)) }
        db.outboxDao().insert(OutboxEntity(recipientUserId = peer, contentBytes = content(), messageLocalId = null,
            urgent = false, createdMs = clock.now()))
        db.contactDao().setResetMs(peer, clock.now())
        outbox.kick()
    }

    /** Throttled reset after a decryption failure: at most once per contact per hour. */
    suspend fun onUndecryptable(peer: ByteArray) {
        val c = db.contactDao().get(peer) ?: return
        if (c.revoked || c.resetMs > clock.now() - HOUR_MS) return
        send(peer)
    }

    /** After a restore: every contact. */
    suspend fun sendToAll() { db.contactDao().all().filter { !it.revoked }.forEach { send(it.userId) } }

    /** A contact restored their account: their new session is already active (libsignal took the PreKey message). */
    suspend fun onReceived(sender: ByteArray) {
        db.groupDao().deleteSharedWithMember(sender)
        val cid = db.conversationDao().byPeer(sender)?.id
        if (cid != null) {
            db.messageDao().insert(MessageEntity(messageId = ByteArray(16).also(SecureRandom()::nextBytes), conversationId = cid,
                senderId = sender, outgoing = false, sentMs = clock.now(), receivedMs = clock.now(), body = "",
                status = MessageStatus.DELIVERED, kind = MessageKind.SYSTEM_RESET))
            db.conversationDao().touch(cid, clock.now())
        }
        outbox.kick()
    }

    companion object { const val HOUR_MS = 3_600_000L }
}
```
(`OtterProtocolStore.deleteSession(SignalProtocolAddress)` is part of libsignal's `SessionStore`; if the store wraps it
differently, use its delete method.)

- [ ] **Step 3: Receivers.** `MailboxReceiver`: inject `SessionResets` (constructor + `TestGraph`/`LiveClient`/Hilt).
Add to the control-content `when`: `Content.BodyCase.SESSION_RESET -> { resets.onReceived(sender.userId); acks += key; continue }`.
After the `content == null` branch's transaction: `if (content == null) resets.onUndecryptable(sender.userId)` (outside
the transaction). `GroupReceiver.onEnvelope`: where an envelope is parked because no sender key exists for the sender,
call `resets.onUndecryptable(sender)` (inject `SessionResets`; mind the constructor cycle: `SessionResets` depends on
`Outbox`, not on receivers, so no cycle).

- [ ] **Step 4: `InstallGuard.kt`:**

```kotlin
package app.ottermsg.core.data.backup

import app.ottermsg.core.crypto.RecordCodec
import app.ottermsg.core.data.Clock
import app.ottermsg.core.data.account.AccountRepository
import app.ottermsg.core.data.messaging.SessionResets
import app.ottermsg.core.data.registration.Registration
import app.ottermsg.core.data.settings.Settings
import app.ottermsg.core.data.signal.SignalService
import app.ottermsg.core.database.OtterDatabase
import app.ottermsg.core.network.NodeApi
import app.ottermsg.core.crypto.ManifestVerifier
import app.ottermsg.core.signal.PreKeyFactory
import app.ottermsg.proto.v1.LoginResponse
import app.ottermsg.proto.v1.PreKeys
import app.ottermsg.proto.v1.RecordType
import javax.inject.Inject
import javax.inject.Singleton

/** Runs right after every login (D52): finishes a restore, or notices that another phone replaced this one. */
@Singleton
class InstallGuard @Inject constructor(
    private val db: OtterDatabase, private val accounts: AccountRepository, private val settings: Settings,
    private val signal: SignalService, private val resets: SessionResets, private val clock: Clock,
) {
    /** False when this install is superseded: the caller must stop syncing. */
    suspend fun afterLogin(api: NodeApi, resp: LoginResponse): Boolean {
        if (settings.restorePending()) { finishRestore(api); return true }
        if (resp.installedMs > settings.installedMs()) { settings.setSuperseded(true); return false }
        return true
    }

    private suspend fun finishRestore(api: NodeApi) {
        val me = accounts.require()
        val manifest = ManifestVerifier.verify(checkNotNull(db.manifestDao().latest()).raw, settings.networkPub(), 0)
        val now = clock.now()
        var next = 1
        val payload = signal.withSessions { store, _ ->
            val signed = PreKeyFactory.signed(store, 1, now)
            val kyber = PreKeyFactory.kyberLastResort(store, 1, now)
            val oneTime = manifest.nodesList.flatMap { n ->
                PreKeyFactory.oneTime(store, next, Registration.ONE_TIME_PER_NODE, n.nodeId.toByteArray()).also { next += Registration.ONE_TIME_PER_NODE }
            }
            PreKeys.newBuilder().setDeviceId(1).setRegistrationId(me.registrationId).setInstalledMs(settings.installedMs())
                .setSignedPrekey(signed).setKyberPrekey(kyber).addAllOneTime(oneTime).build()
        }
        settings.setNextOneTimeId(next)
        api.uploadPrekeys(RecordCodec.sign(RecordCodec.body(RecordType.PREKEYS, me.userId, payload.toByteArray(), createdMs = now), me.accountKey))
        settings.setRestorePending(false)
        resets.sendToAll()
    }
}
```
(Check `ManifestDao` for the latest-manifest query name and `ManifestEntity` field names; `ManifestUpdater` already
reads the stored manifest — reuse its accessor if one exists.)

- [ ] **Step 5: SyncEngine.** Inject `InstallGuard`; in `runSession` replace `api.login(me.userId, me.accountKey)` with:

```kotlin
        val resp = api.login(me.userId, me.accountKey)
        if (!guard.afterLogin(api, resp)) { stop(); return }
```
and in `start()`: `fun start() { if (!supersededCache) manager.start() }` — simplest: `MainActivity`/`ForegroundSync`
don't start the engine when `settings.superseded()` (Task 11 gates the UI; here make `ForegroundSync` check
`settings.superseded()` before `engine.start()`). Update `TestGraph`/`LiveClient` constructors.

- [ ] **Step 6: Tests** `SessionResetTest` (Robolectric, `TestGraph` × 2 on one `FakeNode`, like the M3 group tests):

```kotlin
    @Test fun resetRestoresDirectAndGroupDelivery() = runBlocking {
        val node = FakeNode(clock::now)
        val anna = TestGraph(node, clock); val boris = TestGraph(node, clock)
        anna.register(node.bootstrapLink(), "Анна", "anna").getOrThrow(); anna.online()
        boris.register(anna.invites.create().link, "Борис", "boris").getOrThrow(); boris.online()
        // a working chat and a group first
        val cid = anna.messages.conversationWith(boris.me.userId)
        anna.messages.sendText(cid, "привет")
        eventually { boris.lastText() == "привет" }
        val gid = anna.groups.create("Семья", listOf(boris.me.userId)).getOrThrow()
        anna.messages.sendText(anna.db.conversationDao().byGroup(gid)!!.id, "всем")
        eventually { boris.lastGroupText(gid) == "всем" }

        // boris loses all Signal state but keeps identity (what a restore looks like to anna)
        boris.offline()
        boris.db.signalKvDao().clearSessionsAndSenderKeys() // helper added for the test (see note)
        boris.settings.setRestorePending(true)
        boris.settings.setInstalledMs(clock.now())
        boris.online() // InstallGuard: new prekeys + SessionReset to anna

        eventually { anna.db.messageDao().observe(cid).first().any { it.kind == MessageKind.SYSTEM_RESET } }
        anna.messages.sendText(cid, "снова")
        eventually { boris.lastText() == "снова" }
        anna.messages.sendText(anna.db.conversationDao().byGroup(gid)!!.id, "и в группе")
        eventually { boris.lastGroupText(gid) == "и в группе" }
    }

    @Test fun undecryptableTriggersOneResetPerHour() = runBlocking { /* corrupt boris's session with anna, anna sends 2
        messages → exactly one SessionReset in boris's outbox; clock.advance(61 min) + third failure → second reset */ }
```
Write the second test concretely: after setup, delete boris's session with anna on boris's side **and** anna's on
anna's side is kept, so anna's next message is a normal (non-PreKey) Signal message boris can't decrypt; assert
`boris.db.outboxDao()` contains one item whose content parses to `SESSION_RESET` after two failures, two after the
clock advance and a third failure. Add test helpers in the test sources only: `SignalKvDao` already has key-prefix
queries? If not, add to `TestGraph` a helper that deletes `signal_kv` rows whose key starts with the session /
sender-key prefixes used by `RoomSignalKeyValue` (read it for the prefixes). `lastText`/`lastGroupText` helpers may
already exist in M3 tests — reuse them.

`InstallGuardTest`: superseded case — `FakeNode.loginInfo` reports a newer install (register, then upload a PREKEYS
with a later `installed_ms` from a second graph on the same seed) → first graph's `runSession` sets `superseded` and
returns; restore-pending case — prekeys uploaded with the stored install, flag cleared, one outbox reset per contact.

- [ ] **Step 7:** `./gradlew test` → PASS. **Commit** `feat(sync): install identity, superseded detection, SessionReset`.

---

### Task 8: Backup snapshot and BackupManager

**Goal:** The phone turns backup on with a password and uploads encrypted snapshots: on demand, daily while in use,
and on password change.

**Files:**
- Create: `core/data/src/main/kotlin/app/ottermsg/core/data/backup/SnapshotCodec.kt`,
  `core/data/src/main/kotlin/app/ottermsg/core/data/backup/BackupManager.kt`
- Modify: `sync/SyncEngine.kt` (launch), `TestGraph.kt`, `LiveClient.kt`
- Test: `core/data/src/test/kotlin/app/ottermsg/core/data/SnapshotCodecTest.kt`, `BackupManagerTest.kt`

**Acceptance Criteria:**
- [ ] `SnapshotCodec.export(db, account, settings)` → `BackupSnapshot`; `import(snapshot, db, …)` writes the same
  rows into an empty DB (conversation ids remapped, message ↔ attachment ↔ recipients linked, attachments
  `NOT_IN_BACKUP` with `file = null`, outgoing PENDING/FAILED messages stored as FAILED).
- [ ] `BackupManager.enable(password)`: refuses `PasswordPolicy != OK`; new salt; Argon2id; stores wrapped keys; runs a
  backup. `runNow()`: snapshot → gzip → `BlobCipher` → persistent blob (`blobCreate`/`blobPut` missing chunks) →
  `BACKUP_META` (version+1) → `backupPublish` → `backupLastMs`. Each run uses a fresh blob id (a failed run's leftover
  persistent blob is collected by the nodes after 7 days, D50). Errors set `backupError`.
- [ ] `runIfDue(api)` runs when enabled and `now - backupLastMs > 24 h`; SyncEngine launches it in each session.
- [ ] `changePassword(pw)`: new salt + keys, immediate backup with a higher version.
- [ ] `state: Flow<BackupState>` (off / last time / running / error) for the UI.

**Verify:** `./gradlew :core:data:testDebugUnitTest --tests '*SnapshotCodec*' --tests '*BackupManager*'`

**Steps:**

- [ ] **Step 1: Failing `SnapshotCodecTest`** — fill one graph with: a contact, a direct conversation with 3 messages
(one outgoing READ, one incoming, one PHOTO with attachment + thumb), a group with 2 members and one outgoing group
message with recipients; `export`, then `import` into a fresh in-memory DB; assert counts, texts, statuses, attachment
state `NOT_IN_BACKUP` + thumb bytes, recipients rows, group `stateSigned` bytes, seed, username, `entry_version`, photo
settings.

- [ ] **Step 2: `SnapshotCodec.kt`** — straightforward mapping, one `export` and one `import` function:

```kotlin
package app.ottermsg.core.data.backup

import androidx.room.withTransaction
import app.ottermsg.core.data.account.LocalAccount
import app.ottermsg.core.data.bs
import app.ottermsg.core.data.settings.Settings
import app.ottermsg.core.database.OtterDatabase
import app.ottermsg.core.database.entity.*
import app.ottermsg.core.database.model.AttachmentState
import app.ottermsg.core.database.model.MessageStatus
import app.ottermsg.proto.v1.*

/** DB ↔ BackupSnapshot (D55). Signal state, outbox, seen envelopes and endpoint stats are never included. */
object SnapshotCodec {
    suspend fun export(db: OtterDatabase, me: LocalAccount, settings: Settings, nowMs: Long): BackupSnapshot {
        val b = BackupSnapshot.newBuilder().setFormat(1).setCreatedMs(nowMs).setSeed(bs(me.seed)).setUsername(me.username)
            .setDisplayName(me.displayName).setRegisteredMs(me.createdMs).setEntryVersion(settings.entryVersion())
            .setPhotoAutoDownload(settings.photoAutoDownload()).setPhotoSaveToGallery(settings.photoSaveToGallery())
        db.contactDao().all().forEach { c ->
            b.addContacts(BackupContact.newBuilder().setUserId(bs(c.userId)).setUsername(c.username).setDisplayName(c.displayName)
                .setAccountPub(bs(c.accountPub)).setIdentityPub(bs(c.identityPub)).setVerified(c.verified)
                .setIdentityChanged(c.identityChanged).setRevoked(c.revoked).setEntryVersion(c.entryVersion))
        }
        db.conversationDao().all().forEach { c ->
            b.addConversations(BackupConversation.newBuilder().setId(c.id).setTitle(c.title).setLastActivityMs(c.lastActivityMs)
                .setUnread(c.unread).setDraft(c.draft).setType(c.type).also { x ->
                    c.peerUserId?.let { x.peerUserId = bs(it) }; c.groupId?.let { x.groupId = bs(it) } })
        }
        db.messageDao().all().forEach { m ->
            val mb = BackupMessage.newBuilder().setMessageId(bs(m.messageId)).setConversationId(m.conversationId)
                .setSenderId(bs(m.senderId)).setOutgoing(m.outgoing).setSentMs(m.sentMs).setReceivedMs(m.receivedMs)
                .setBody(m.body).setStatus(m.status).setKind(m.kind).setReadReceiptSent(m.readReceiptSent)
            m.systemData?.let { mb.systemData = bs(it) }
            db.attachmentDao().forMessage(m.localId)?.let { a ->
                mb.attachment = BackupAttachment.newBuilder().setBlobKey(bs(a.blobKey)).setKey(bs(a.key)).setDigest(bs(a.digest))
                    .setSize(a.size).setMime(a.mime).setWidth(a.width).setHeight(a.height).also { x -> a.thumb?.let { x.thumb = bs(it) } }.build()
            }
            db.messageRecipientDao().forMessage(m.localId).forEach { r ->
                mb.addRecipients(BackupRecipient.newBuilder().setUserId(bs(r.userId)).setDeliveredMs(r.deliveredMs ?: 0).setReadMs(r.readMs ?: 0))
            }
            b.addMessages(mb)
        }
        db.groupDao().all().forEach { g ->
            val gb = BackupGroup.newBuilder().setGroupId(bs(g.groupId)).setName(g.name).setFamily(g.family).setVersion(g.version)
                .setStateSigned(bs(g.stateSigned)).setIAmMember(g.iAmMember).setCreatedBy(bs(g.createdBy))
            g.prevState?.let { gb.prevState = bs(it) }
            db.groupDao().members(g.groupId).forEach { gb.addMembers(BackupGroupMember.newBuilder().setUserId(bs(it.userId)).setAdmin(it.admin)) }
            b.addGroups(gb)
        }
        return b.build()
    }

    /** Writes [s] into an empty database (restore). Returns nothing; the account row is written by RestoreManager. */
    suspend fun import(s: BackupSnapshot, db: OtterDatabase, settings: Settings) = db.withTransaction {
        s.contactsList.forEach { c ->
            db.contactDao().upsert(ContactEntity(c.userId.toByteArray(), c.username, c.displayName, c.accountPub.toByteArray(),
                c.identityPub.toByteArray(), c.verified, c.identityChanged, c.revoked, c.entryVersion))
        }
        val ids = HashMap<Long, Long>()
        s.conversationsList.forEach { c ->
            ids[c.id] = db.conversationDao().insert(ConversationEntity(peerUserId = c.peerUserId.toByteArray().takeIf { it.isNotEmpty() },
                title = c.title, lastActivityMs = c.lastActivityMs, unread = c.unread, draft = c.draft,
                groupId = c.groupId.toByteArray().takeIf { it.isNotEmpty() }, type = c.type))
        }
        s.messagesList.forEach { m ->
            val cid = ids[m.conversationId] ?: return@forEach
            val status = if (m.outgoing && (m.status == MessageStatus.PENDING)) MessageStatus.FAILED else m.status
            val local = db.messageDao().insert(MessageEntity(messageId = m.messageId.toByteArray(), conversationId = cid,
                senderId = m.senderId.toByteArray(), outgoing = m.outgoing, sentMs = m.sentMs, receivedMs = m.receivedMs, body = m.body,
                status = status, kind = m.kind, readReceiptSent = m.readReceiptSent,
                systemData = m.systemData.toByteArray().takeIf { it.isNotEmpty() }))
            if (local <= 0) return@forEach
            if (m.hasAttachment()) {
                val a = m.attachment
                db.attachmentDao().insert(AttachmentEntity(messageLocalId = local, blobKey = a.blobKey.toByteArray(), key = a.key.toByteArray(),
                    digest = a.digest.toByteArray(), size = a.size, mime = a.mime, width = a.width, height = a.height,
                    thumb = a.thumb.toByteArray().takeIf { it.isNotEmpty() }, file = null, state = AttachmentState.NOT_IN_BACKUP))
            }
            if (m.recipientsCount > 0) db.messageRecipientDao().insertAll(m.recipientsList.map {
                MessageRecipientEntity(local, it.userId.toByteArray(), it.deliveredMs.takeIf { v -> v > 0 }, it.readMs.takeIf { v -> v > 0 })
            })
        }
        s.groupsList.forEach { g ->
            db.groupDao().upsert(GroupEntity(g.groupId.toByteArray(), g.name, g.family, g.version, g.stateSigned.toByteArray(),
                g.prevState.toByteArray().takeIf { it.isNotEmpty() }, g.iAmMember, g.createdBy.toByteArray()))
            db.groupDao().replaceMembers(g.groupId.toByteArray(), g.membersList.map { GroupMemberEntity(g.groupId.toByteArray(), it.userId.toByteArray(), it.admin) })
        }
        settings.setPhotoAutoDownload(s.photoAutoDownload)
        settings.setPhotoSaveToGallery(s.photoSaveToGallery)
        settings.setEntryVersion(s.entryVersion)
    }
}
```
DAO additions this needs (add in this task, they are plain queries): `ConversationDao.all()`
(`SELECT * FROM conversations`), `MessageDao.all()` (`SELECT * FROM messages ORDER BY local_id`), `GroupDao.all()`
(`SELECT * FROM groups`), `MessageRecipientDao.forMessage` (exists — check) and `insertAll(list)` (check the existing
insert name). If `MessageRecipientEntity`'s constructor differs, follow its definition. Gzip happens in BackupManager.

- [ ] **Step 3: `BackupManager.kt`:**

```kotlin
package app.ottermsg.core.data.backup

import app.ottermsg.core.crypto.BackupKeys
import app.ottermsg.core.crypto.BlobCipher
import app.ottermsg.core.crypto.RecordCodec
import app.ottermsg.core.data.Clock
import app.ottermsg.core.data.account.AccountRepository
import app.ottermsg.core.data.account.SeedVault
import app.ottermsg.core.data.bs
import app.ottermsg.core.data.invite.OnlineApi
import app.ottermsg.core.data.media.BlobMetaBuilder
import app.ottermsg.core.data.settings.Settings
import app.ottermsg.core.database.OtterDatabase
import app.ottermsg.core.network.NodeApi
import app.ottermsg.core.network.RpcException
import app.ottermsg.proto.v1.BackupMeta
import app.ottermsg.proto.v1.BlobMeta
import app.ottermsg.proto.v1.RecordType
import app.ottermsg.proto.v1.Status
import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.security.SecureRandom
import java.util.zip.GZIPOutputStream
import javax.inject.Inject
import javax.inject.Singleton

sealed interface BackupState {
    data object Off : BackupState
    data class On(val lastMs: Long, val running: Boolean, val error: Int) : BackupState
}

/** Password backups (D50/D55). Keys are derived once and kept wrapped; backups run while the app is in use. */
@Singleton
class BackupManager @Inject constructor(
    @ApplicationContext private val context: Context,
    private val db: OtterDatabase, private val accounts: AccountRepository, private val settings: Settings,
    private val vault: SeedVault, private val online: OnlineApi, private val clock: Clock,
) {
    private val mutex = Mutex()
    private val running = MutableStateFlow(false)

    val state: Flow<BackupState> = combine(settings.observe(Settings.BACKUP_SECRET), settings.observeLong(Settings.BACKUP_LAST_MS, 0),
        settings.observeInt(Settings.BACKUP_ERROR, 0), running) { secret, last, err, run ->
        if (secret == null || secret.isEmpty()) BackupState.Off else BackupState.On(last, run, err)
    }

    /** Sets the password (first time or change) and backs up at once. */
    suspend fun setPassword(password: String): Int {
        if (PasswordPolicy.check(password) != PasswordPolicy.Result.OK) return ERR_WEAK
        val salt = BackupKeys.newSalt()
        val keys = withContext(Dispatchers.Default) { BackupKeys.derive(password, salt) }
        settings.setBackupSalt(salt)
        settings.setBackupSecret(vault.wrap(keys.backupKey + keys.authSecret))
        return runNow()
    }

    /** «Создать сейчас»: needs a connection. */
    suspend fun runNow(): Int = online.current()?.let { run(it) } ?: ERR_OFFLINE

    /** From each sync session: back up if the last success is older than 24 h. */
    suspend fun runIfDue(api: NodeApi) {
        if (settings.backupSecret() == null || clock.now() - settings.backupLastMs() < DAY_MS) return
        run(api)
    }

    private suspend fun run(api: NodeApi): Int = mutex.withLock {
        val wrapped = settings.backupSecret() ?: return ERR_OFF
        running.value = true
        try {
            val secret = vault.unwrap(wrapped)
            val backupKey = secret.copyOfRange(0, 32); val authSecret = secret.copyOfRange(32, 64)
            val me = accounts.require()
            val id = ByteArray(16).also(SecureRandom()::nextBytes) // fresh per run (D50 collects leftovers)
            val blobKey = BlobMetaBuilder.blobKey(me.userId, id)
            val file = File(context.cacheDir, "backup.otb")
            withContext(Dispatchers.IO) {
                val snapshot = SnapshotCodec.export(db, me, settings, clock.now())
                val gz = java.io.ByteArrayOutputStream().also { o -> GZIPOutputStream(o).use { snapshot.writeTo(it) } }.toByteArray()
                BlobCipher.encrypt(gz.inputStream(), file, backupKey, blobKey)
            }
            try {
                val hashes = BlobCipher.chunkHashes(file)
                val meta = BlobMeta.newBuilder().setSize(file.length()).setChunkSize(BlobCipher.CHUNK)
                    .addAllChunkSha256(hashes.map(::bs)).setPersistent(true).build()
                val metaRec = RecordCodec.sign(RecordCodec.body(RecordType.BLOB_META, me.userId, meta.toByteArray(), createdMs = clock.now(),
                    id = id), me.accountKey)
                val status = api.blobCreate(metaRec)
                file.inputStream().buffered().use { s ->
                    val buf = ByteArray(BlobCipher.CHUNK)
                    for (i in 0 until status.chunks) {
                        val n = BlobCipher.readFully(s, buf)
                        if (i in status.missingList) api.blobPut(blobKey, i, buf.copyOf(n))
                    }
                }
                val version = settings.backupVersion() + 1
                val bm = BackupMeta.newBuilder().setVersion(version).setSalt(bs(checkNotNull(settings.backupSalt())))
                    .setKdfMKib(BackupKeys.M_KIB).setKdfT(BackupKeys.T).setKdfP(BackupKeys.P)
                    .setAuthVerifier(bs(BackupKeys.Keys(backupKey, authSecret).verifier)).setBlobKey(bs(blobKey)).setSize(file.length()).build()
                api.backupPublish(RecordCodec.sign(RecordCodec.body(RecordType.BACKUP_META, me.userId, bm.toByteArray(), createdMs = clock.now()), me.accountKey))
                settings.setBackupVersion(version); settings.setBackupLastMs(clock.now())
                settings.setBackupError(0)
                OK
            } finally { file.delete() }
        } catch (e: RpcException) {
            val code = if (e.status == Status.STATUS_QUOTA) ERR_QUOTA else ERR_NETWORK
            settings.setBackupError(code); code
        } catch (e: java.io.IOException) {
            settings.setBackupError(ERR_NETWORK); ERR_NETWORK
        } finally { running.value = false }
    }

    companion object {
        const val DAY_MS = 86_400_000L
        const val OK = 0; const val ERR_WEAK = 1; const val ERR_OFFLINE = 2; const val ERR_NETWORK = 3; const val ERR_QUOTA = 4; const val ERR_OFF = 5
    }
}
```
Notes: the blob key must equal `author ‖ record id`, so the BLOB_META must be signed with the chosen `id`. Check
`RecordCodec.body`'s signature; if it has no `id` parameter, add one (default random) or reuse M4's
`BlobMetaBuilder` signing helper, which already signs metas with a chosen id. Why a fresh id per run: reusing an id
with a different snapshot would make `blob.create` return the stored meta (the key exists) and the new chunks would
fail verification. The 3-blob cap (D50) leaves room for one failed attempt; leftovers are collected after 7 days.

`SyncEngine.runSession`: `session.launch { backups.runIfDue(api) }` after the outbox launch. Inject `BackupManager`
(`TestGraph`, `LiveClient`).

- [ ] **Step 4: `BackupManagerTest`** (Robolectric, `FakeNode`): weak password → `ERR_WEAK`, nothing stored;
`setPassword` ok → `FakeNode.backupOf(user).version == 1` and the blob decrypts (with keys re-derived from the password
and the FakeNode salt) to a snapshot with the right messages; `runIfDue` before 24 h → no new version, after
`clock.advance(25 h)` → version 2 and v1's blob gone in FakeNode; `setPassword(new)` → version 3, new salt; offline
`runNow()` → `ERR_OFFLINE`. Use small Argon2 params in tests? `BackupManager` uses the defaults (64 MiB, 3 passes) —
acceptable in JVM tests (≈1 s each); if too slow, add an internal `kdf` parameter (`BackupKeys::derive`) for tests.

- [ ] **Step 5:** `./gradlew test` → PASS. **Commit** `feat(backup): snapshot codec and BackupManager`.

---

### Task 9: RestoreManager

**Goal:** A fresh install restores from (invite link + username + password) or (invite link + 24 words [+ password]).

**Files:**
- Create: `core/data/src/main/kotlin/app/ottermsg/core/data/backup/RestoreManager.kt`
- Modify: `account/AccountRepository.kt` (nothing if `load()` suffices), `TestGraph.kt`, `LiveClient.kt`
- Test: `core/data/src/test/kotlin/app/ottermsg/core/data/RestoreFlowTest.kt`

**Acceptance Criteria:**
- [ ] `RestoreManager.network(link)` → verified manifest + network pub from an invite link (`BadLink` otherwise); the
  invite is not used.
- [ ] `withPassword(link, username, password)`: `backupAuth` → Argon2id → `backupFetch` → chunks via `blobGet` on the
  same connection (each chunk verified against `blob_meta` hashes) → decrypt → gunzip → snapshot; the snapshot's seed
  must derive the `BACKUP_META` author id; then `install(snapshot)`. Errors: `WrongPassword` (UNAUTHORIZED),
  `TooManyAttempts` (RETRY_LATER "too many"), `Network`, `NotReplicated` (RETRY_LATER other), `Corrupt`.
- [ ] `withWords(link, words)`: BIP-39 → seed → account key → login on a node → own `DIRECTORY_ENTRY` from
  `directory()` (username, display name, registered_ms, version) → `install(identity-only snapshot)`.
- [ ] `install`: account row (seed wrapped), new registration id, `installed_ms = now`, `restore_pending = true`,
  network pub, manifest row, snapshot rows (`SnapshotCodec.import`), backup keys kept (password path: the backup stays
  on, version continues from the restored meta's version); `accounts.load()`.
- [ ] `RestoreFlowTest` (FakeNode): anna with history + group backs up; a new `TestGraph` (empty DB, same node)
  restores with username+password → messages, contacts, group present; goes online → boris receives SessionReset,
  boris→anna and anna→boris messages decrypt, group message both ways; the old anna graph, when it goes online, ends
  `superseded`. Words path restores identity with empty chats; then `withPasswordAfterWords(password)` adds history.

**Verify:** `./gradlew :core:data:testDebugUnitTest --tests '*RestoreFlow*'`

**Steps:**

- [ ] **Step 1: Failing test** `RestoreFlowTest` as described (model it on `PhotoFlowTest`'s setup). Key assertions:

```kotlin
        val restored = TestGraph(node, clock)
        restored.restore.withPassword(link, "anna", "корова лодка зима семь").getOrThrow()
        assertEquals(anna.me.userId.toList(), restored.me.userId.toList())
        assertEquals(listOf("привет", "как дела"), restored.texts(restored.messages.conversationWith(boris.me.userId)))
        assertNotNull(restored.db.groupDao().get(gid))
        restored.online()
        boris.messages.sendText(boris.messages.conversationWith(anna.me.userId), "ты вернулась!")
        eventually { restored.lastText() == "ты вернулась!" }
        restored.messages.sendText(restored.messages.conversationWith(boris.me.userId), "да")
        eventually { boris.lastText() == "да" }
        anna.online() // the old phone
        eventually { anna.settings.superseded() }
```

- [ ] **Step 2: Implement `RestoreManager.kt`:**

```kotlin
package app.ottermsg.core.data.backup

import androidx.room.withTransaction
import app.ottermsg.core.crypto.BackupKeys
import app.ottermsg.core.crypto.Bip39
import app.ottermsg.core.crypto.BlobCipher
import app.ottermsg.core.crypto.Ids
import app.ottermsg.core.crypto.InviteLink
import app.ottermsg.core.crypto.ManifestVerifier
import app.ottermsg.core.crypto.SeedKeys
import app.ottermsg.core.data.Clock
import app.ottermsg.core.data.account.AccountRepository
import app.ottermsg.core.data.account.SeedVault
import app.ottermsg.core.data.bs
import app.ottermsg.core.data.di.AllowPlaintext
import app.ottermsg.core.data.registration.NodeConnector
import app.ottermsg.core.data.settings.Settings
import app.ottermsg.core.database.OtterDatabase
import app.ottermsg.core.database.entity.AccountEntity
import app.ottermsg.core.database.entity.ManifestEntity
import app.ottermsg.core.network.Endpoints
import app.ottermsg.core.network.NodeApi
import app.ottermsg.core.network.RpcException
import app.ottermsg.proto.v1.*
import java.io.IOException
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.zip.GZIPInputStream
import javax.inject.Inject
import javax.inject.Singleton

sealed class RestoreError : Exception() {
    data object BadLink : RestoreError() { private fun readResolve(): Any = BadLink }
    data object BadWords : RestoreError() { private fun readResolve(): Any = BadWords }
    data object WrongPassword : RestoreError() { private fun readResolve(): Any = WrongPassword }
    data object TooManyAttempts : RestoreError() { private fun readResolve(): Any = TooManyAttempts }
    data object NotReplicated : RestoreError() { private fun readResolve(): Any = NotReplicated }
    data object UnknownAccount : RestoreError() { private fun readResolve(): Any = UnknownAccount }
    data object Corrupt : RestoreError() { private fun readResolve(): Any = Corrupt }
    data object Network : RestoreError() { private fun readResolve(): Any = Network }
}

/** Seam for the onboarding ViewModel tests. */
interface Restorer {
    suspend fun withPassword(link: String, username: String, password: String): Result<Unit>
    suspend fun withWords(link: String, words: List<String>): Result<Unit>
    /** After a words restore: add the history from the backup (logged-in path; same password check). */
    suspend fun addHistory(password: String): Result<Unit>
}

@Singleton
class RestoreManager @Inject constructor(
    private val db: OtterDatabase, private val connector: NodeConnector, private val vault: SeedVault,
    private val accounts: AccountRepository, private val settings: Settings, private val clock: Clock,
    @param:AllowPlaintext private val allowPlaintext: Boolean,
) : Restorer {
    private class Network(val manifest: Manifest, val raw: ByteArray, val networkPub: ByteArray)

    private fun network(link: String): Network {
        val b = try { InviteLink.decode(link) } catch (e: IllegalArgumentException) { throw RestoreError.BadLink }
        val pub = b.networkPub.toByteArray()
        val m = try { ManifestVerifier.verify(b.manifest.toByteArray(), pub, 0) } catch (e: Exception) { throw RestoreError.BadLink }
        return Network(m, b.manifest.toByteArray(), pub)
    }

    private suspend fun <T> guarded(block: suspend () -> T): Result<T> = try { Result.success(block()) }
        catch (e: kotlin.coroutines.cancellation.CancellationException) { throw e }
        catch (e: RestoreError) { Result.failure(e) }
        catch (e: RpcException) { Result.failure(map(e)) }
        catch (e: IOException) { Result.failure(RestoreError.Network) }

    private fun map(e: RpcException): RestoreError = when {
        e.status == Status.STATUS_UNAUTHORIZED -> RestoreError.WrongPassword
        e.status == Status.STATUS_RETRY_LATER && "too many" in e.message.orEmpty() -> RestoreError.TooManyAttempts
        e.status == Status.STATUS_RETRY_LATER -> RestoreError.NotReplicated
        else -> RestoreError.Network
    }

    override suspend fun withPassword(link: String, username: String, password: String): Result<Unit> = guarded {
        val net = network(link)
        val (snapshot, keys, meta) = connector.withNode(Endpoints.candidates(net.manifest, allowPlaintext)) { api ->
            download(api, username.trim().lowercase(), password)
        }
        install(net, snapshot, keys, meta)
    }

    /** Fetches, verifies and decrypts the backup over one connection (the fetch grant is per connection). */
    private suspend fun download(api: NodeApi, username: String, password: String): Triple<BackupSnapshot, BackupKeys.Keys, BackupMeta> {
        val auth = api.backupAuth(username)
        val keys = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
            BackupKeys.derive(password, auth.salt.toByteArray(), auth.kdfMKib, auth.kdfT, auth.kdfP)
        }
        val res = api.backupFetch(username, keys.authSecret)
        val metaBody = RecordBody.parseFrom(res.backupMeta.body)
        val meta = BackupMeta.parseFrom(metaBody.payload)
        val blob = BlobMeta.parseFrom(RecordBody.parseFrom(res.blobMeta.body).payload)
        val out = java.io.ByteArrayOutputStream()
        for (i in 0 until blob.chunkSha256Count) {
            val data = api.blobGet(meta.blobKey.toByteArray(), i)
            if (!MessageDigest.getInstance("SHA-256").digest(data).contentEquals(blob.getChunkSha256(i).toByteArray())) throw RestoreError.Corrupt
            out.write(data)
        }
        val tmp = java.io.File.createTempFile("restore", ".otb")
        try {
            tmp.writeBytes(out.toByteArray())
            val snapshot = try {
                BlobCipher.decrypt(tmp, keys.backupKey, meta.blobKey.toByteArray()).use { GZIPInputStream(it).use(BackupSnapshot::parseFrom) }
            } catch (e: IOException) { throw RestoreError.Corrupt }
            val author = Ids.id16(SeedKeys.accountKeyPair(snapshot.seed.toByteArray()).publicKey)
            if (!author.contentEquals(metaBody.author.toByteArray())) throw RestoreError.Corrupt
            return Triple(snapshot, keys, meta)
        } finally { tmp.delete() }
    }

    override suspend fun withWords(link: String, words: List<String>): Result<Unit> = guarded {
        val net = network(link)
        val seed = try { Bip39.toEntropy(words.map { it.trim().lowercase() }) } catch (e: IllegalArgumentException) { throw RestoreError.BadWords }
        val account = SeedKeys.accountKeyPair(seed)
        val userId = Ids.id16(account.publicKey)
        val entry = connector.withNode(Endpoints.candidates(net.manifest, allowPlaintext)) { api ->
            api.login(userId, account)
            api.directory().map { RecordBody.parseFrom(it.body) }.filter { it.type == RecordType.DIRECTORY_ENTRY }
                .map { DirectoryEntry.parseFrom(it.payload) }.firstOrNull { it.userId.toByteArray().contentEquals(userId) }
        } ?: throw RestoreError.UnknownAccount
        val snapshot = BackupSnapshot.newBuilder().setFormat(1).setSeed(bs(seed)).setUsername(entry.username)
            .setDisplayName(entry.displayName).setRegisteredMs(entry.registeredMs).setEntryVersion(entry.version.toInt()).build()
        install(net, snapshot, null, null)
    }

    override suspend fun addHistory(password: String): Result<Unit> = guarded {
        val me = accounts.require()
        val raw = checkNotNull(db.manifestDao().latest()).raw
        val m = ManifestVerifier.verify(raw, settings.networkPub(), 0)
        val (snapshot, keys, meta) = connector.withNode(Endpoints.candidates(m, allowPlaintext)) { api -> download(api, me.username, password) }
        if (!snapshot.seed.toByteArray().contentEquals(me.seed)) throw RestoreError.Corrupt
        SnapshotCodec.import(snapshot, db, settings)
        keepBackupOn(keys, meta)
    }

    private suspend fun keepBackupOn(keys: BackupKeys.Keys, meta: BackupMeta) {
        settings.setBackupSalt(meta.salt.toByteArray())
        settings.setBackupSecret(vault.wrap(keys.backupKey + keys.authSecret))
        settings.setBackupVersion(meta.version)
        settings.setBackupLastMs(0) // back up again soon from this phone
    }

    private suspend fun install(net: Network, s: BackupSnapshot, keys: BackupKeys.Keys?, meta: BackupMeta?) {
        val seed = s.seed.toByteArray()
        val userId = Ids.id16(SeedKeys.accountKeyPair(seed).publicKey)
        val now = clock.now()
        db.withTransaction {
            db.accountDao().insert(AccountEntity(userId, s.username, s.displayName, vault.wrap(seed), s.registeredMs))
            settings.setRegistrationId(SecureRandom().nextInt(16380) + 1)
            settings.setInstalledMs(now)
            settings.setRestorePending(true)
            settings.setNetworkPub(net.networkPub)
            db.manifestDao().insert(ManifestEntity(net.manifest.version, net.raw, receivedMs = now))
            SnapshotCodec.import(s, db, settings)
            if (keys != null && meta != null) keepBackupOn(keys, meta)
        }
        accounts.load()
    }
}
```
Check: `Bip39.toEntropy` signature (list or string), `ManifestDao` latest accessor, `DirectoryEntry.registeredMs`
(D40 field 9), `Endpoints.candidates` signature — all used as in `Registration`. Hilt: bind `Restorer` to
`RestoreManager` in `DataModule` like `Registrar`. Add `val restore` to `TestGraph`/`LiveClient`.

- [ ] **Step 3:** Run the test → PASS; `./gradlew test` → PASS. **Commit** `feat(backup): restore with password or words`.

---

### Task 10: Settings — «Резервная копия»

**Goal:** Members turn backup on, see its state, back up now and change the password.

**Files:**
- Create: `feature/settings/src/main/kotlin/app/ottermsg/feature/settings/BackupScreen.kt`, `BackupViewModel.kt`
- Modify: `SettingsScreen.kt` (row in a new «Безопасность» section), `feature/settings/src/main/res/values{,-en}/strings.xml`,
  `app/.../AppNavHost.kt` (route `settings/backup`)
- Test: `feature/settings/src/test/.../BackupViewModelTest.kt`

**Acceptance Criteria:**
- [ ] Off state: explanation + «Включить» → password + repeat fields (hidden text, show toggle), strength bar (zxcvbn
  0–4, colours from theme), rule text; button enabled only when both match and `PasswordPolicy == OK`; Argon2 runs with
  a progress indicator «Готовим ключ…» then «Создаём копию…».
- [ ] On state: «Последняя копия: <дата время>» or «Ещё не создана»; error line for `backupError`; «Создать сейчас»
  (disabled while running or offline); «Сменить пароль» (same password form).
- [ ] Strings in RU (default) and EN; TalkBack labels for the visibility toggle and strength bar
  («Надёжность пароля: слабый/средний/надёжный»).

**Verify:** `./gradlew :feature:settings:testDebugUnitTest` and a screen check on the emulator in Task 12.

**Steps:**

- [ ] **Step 1: ViewModel** (test first: weak password keeps the button disabled; matching strong passwords call
`setPassword` once; `runNow` result maps to a snackbar message id).

```kotlin
@HiltViewModel
class BackupViewModel @Inject constructor(private val backups: BackupManager, sync: SyncEngine) : ViewModel() {
    val state = backups.state.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), BackupState.Off)
    val online = sync.connection.map { it is ConnectionState.Online }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), false)
    data class Form(val open: Boolean = false, val pw: String = "", val repeat: String = "", val busy: Boolean = false)
    private val _form = MutableStateFlow(Form())
    val form: StateFlow<Form> = _form
    private val _message = MutableSharedFlow<Int>(extraBufferCapacity = 1)
    val message: SharedFlow<Int> = _message

    fun openForm() = _form.update { Form(open = true) }
    fun closeForm() = _form.update { Form() }
    fun onPw(v: String) = _form.update { it.copy(pw = v) }
    fun onRepeat(v: String) = _form.update { it.copy(repeat = v) }
    fun canSubmit(f: Form) = !f.busy && f.pw == f.repeat && PasswordPolicy.check(f.pw) == PasswordPolicy.Result.OK
    fun submit() {
        val f = _form.value
        if (!canSubmit(f)) return
        _form.update { it.copy(busy = true) }
        viewModelScope.launch {
            val r = backups.setPassword(f.pw)
            _form.value = Form()
            _message.tryEmit(messageFor(r))
        }
    }
    fun runNow() = viewModelScope.launch { _message.tryEmit(messageFor(backups.runNow())) }

    companion object {
        fun messageFor(code: Int) = when (code) {
            BackupManager.OK -> R.string.backup_done
            BackupManager.ERR_OFFLINE -> R.string.backup_offline
            BackupManager.ERR_QUOTA -> R.string.backup_quota
            else -> R.string.backup_failed
        }
    }
}
```

- [ ] **Step 2: Screen** `BackupScreen.kt` with `OtterTopBar`, `OtterSettingsRow`, `OutlinedTextField` ×2
(`PasswordVisualTransformation` + eye toggle), a `LinearProgressIndicator(progress = score/4f)` strength bar, primary
button, `SnackbarHost` for `message`. Follow `PhotoStorageScreen.kt` for structure and theme usage (no default
Material colours — use `MaterialTheme.colorScheme` from `OtterTheme`; the M4 emulator run found stray lavender).

- [ ] **Step 3: Strings** (`feature/settings/src/main/res/values/strings.xml` / `values-en/strings.xml`):

| key | RU | EN |
|---|---|---|
| settings_security | Безопасность | Security |
| settings_backup | Резервная копия | Backup |
| backup_title | Резервная копия | Backup |
| backup_off_text | Копия чатов хранится на ваших серверах в зашифрованном виде. С именем пользователя и паролем вы вернёте переписку на новом телефоне. | An encrypted copy of your chats is kept on your servers. With your username and this password you get your chats back on a new phone. |
| backup_enable | Включить | Turn on |
| backup_password | Пароль копии | Backup password |
| backup_password_repeat | Повторите пароль | Repeat password |
| backup_rule | Не меньше 10 символов. Лучше несколько слов. Пароль нельзя восстановить — запишите его. | At least 10 characters; several words work best. The password can't be recovered — write it down. |
| backup_strength | Надёжность пароля: %1$s | Password strength: %1$s |
| backup_strength_weak | слабый | weak |
| backup_strength_ok | средний | fair |
| backup_strength_strong | надёжный | strong |
| backup_show | Показать пароль | Show password |
| backup_preparing | Готовим ключ… | Preparing the key… |
| backup_running | Создаём копию… | Backing up… |
| backup_last | Последняя копия: %1$s | Last backup: %1$s |
| backup_never | Ещё не создана | Not created yet |
| backup_now | Создать сейчас | Back up now |
| backup_change | Сменить пароль | Change password |
| backup_done | Копия создана | Backup created |
| backup_offline | Нет связи. Копия создастся, когда появится сеть | No connection. The backup runs when you're online |
| backup_quota | На сервере не хватает места для копии | Not enough space on the server |
| backup_failed | Не удалось создать копию. Попробуем позже | Backup failed. We'll try again later |
| backup_mismatch | Пароли не совпадают | Passwords don't match |

- [ ] **Step 4:** Settings row (`Icons.Outlined.CloudDone`) in a new section «Безопасность» before «Связь»; route
`Routes.BACKUP = "settings/backup"`; `SettingsRoute(onBackup = …)`.
- [ ] **Step 5:** `./gradlew test` → PASS. **Commit** `feat(settings): backup screen`.

---

### Task 11: Onboarding restore, superseded screen, message rendering

**Goal:** A wiped phone can restore from the welcome screen; a replaced phone shows why it stopped; restored and
reset messages render properly.

**Files:**
- Modify: `feature/onboarding/.../OnboardingState.kt`, `OnboardingNavigation.kt`, `OnboardingViewModel.kt`,
  `screens/WelcomeScreen.kt`; Create `screens/RestoreMethodScreen.kt`, `screens/RestorePasswordScreen.kt`,
  `screens/RestoreWordsScreen.kt`, `screens/RestoreHistoryScreen.kt`; strings RU/EN
- Create: `app/src/main/java/app/ottermsg/SupersededScreen.kt`; Modify `MainActivity.kt`, `AppNavHost.kt`
- Modify: `feature/conversation/.../PhotoMessage.kt` (NOT_IN_BACKUP), `SystemEventChip.kt`/`MessageBubble.kt`
  (SYSTEM_RESET), `feature/chats` preview text for SYSTEM_RESET; strings
- Test: `feature/onboarding/src/test/.../OnboardingViewModelTest.kt` (restore cases)

**Acceptance Criteria:**
- [ ] Welcome: «Присоединиться» (primary) and «Восстановить аккаунт» (secondary). Restore: invite step (same screen,
  title «Ссылка на вашу сеть», hint «Попросите родственника показать QR из «Пригласить в семью»») → method
  («Имя пользователя и пароль копии» / «24 слова») → form → progress («Ищем копию…», «Расшифровываем…») → DONE (chats).
  Words path → after DONE-equivalent shows «Есть резервная копия? Введите её пароль, чтобы вернуть переписку» with
  «Вернуть переписку» / «Пропустить».
- [ ] Errors: wrong password (with remaining-tries hint not shown — just «Неверное имя или пароль»), too many attempts
  («Слишком много попыток. Попробуйте через час»), not replicated («Копия ещё не дошла до этого сервера. Попробуйте
  позже»), bad words («Проверьте слова: одно или несколько не подходят»), unknown account, network.
- [ ] 24-word input: one field per word in a 2-column grid of 24 numbered fields, paste of a whole phrase into field 1
  splits it; words validated against the BIP-39 list as you type (red underline).
- [ ] `MainActivity`: when `settings.superseded` → `SupersededScreen` («Аккаунт восстановлен на другом телефоне.
  Этот телефон больше не получает сообщения. Чтобы пользоваться Otter здесь, удалите данные приложения и
  восстановите аккаунт снова.») instead of the nav host; sync never starts.
- [ ] Photo with `NOT_IN_BACKUP`: thumbnail, blurred, label «Нет в резервной копии», no tap action besides the menu.
  `SYSTEM_RESET` chip: «%1$s восстановил(а) аккаунт» (EN «%1$s restored their account»); chat-list preview the same.

**Verify:** `./gradlew :feature:onboarding:testDebugUnitTest :feature:conversation:testDebugUnitTest :app:assembleDebug`

**Steps:**

- [ ] **Step 1:** `OnboardingStep` gains `RESTORE_LINK, RESTORE_METHOD, RESTORE_PASSWORD, RESTORE_WORDS, RESTORING,
RESTORE_HISTORY`; `OnboardingUiState` gains `restoreUsername`, `restorePassword`, `restoreWords: List<String>` (24),
`restoreError: Int?`, `restoring: Boolean`, `restoreViaWords: Boolean`. `OnboardingViewModel` takes
`Restorer` (Hilt binds `RestoreManager`); functions `startRestore()`, `submitRestoreLink()` (same `InviteLink.decode`
check), `chooseMethod(words: Boolean)`, `onRestoreUsername/Password`, `onWord(i, v)` (if `i == 0` and `v` has ≥ 12
spaces → split into all fields), `submitRestore()`, `addHistory(password)`, `skipHistory()`. Map `RestoreError` →
string ids. Tests: wrong-password error shown and state stays on the form; words path goes to `RESTORE_HISTORY`;
history skip → DONE; paste splitting.
- [ ] **Step 2:** Screens with `OnboardingScaffold` like the existing ones (`PhraseConfirmScreen` shows how word fields
look). `WelcomeScreen(onJoin, onRestore)`.
- [ ] **Step 3: Strings** (onboarding RU/EN):

| key | RU | EN |
|---|---|---|
| onb_welcome_restore | Восстановить аккаунт | Restore my account |
| onb_restore_link_title | Ссылка на вашу сеть | Link to your network |
| onb_restore_link_hint | Попросите родственника открыть «Пригласить в семью» и покажите камере QR-код или вставьте ссылку. Приглашение при этом не тратится. | Ask a family member to open "Invite to family" and scan the QR code or paste the link. The invite is not used up. |
| onb_restore_method_title | Как восстановить? | How do you want to restore? |
| onb_restore_by_password | Имя пользователя и пароль копии | Username and backup password |
| onb_restore_by_password_hint | Вернутся чаты, контакты и группы | Chats, contacts and groups come back |
| onb_restore_by_words | 24 слова | 24 words |
| onb_restore_by_words_hint | Вернётся аккаунт. Чаты — если знаете пароль копии | Your account comes back; chats too if you know the backup password |
| onb_restore_username | Имя пользователя | Username |
| onb_restore_password | Пароль копии | Backup password |
| onb_restore_words_title | Введите 24 слова | Enter your 24 words |
| onb_restore_searching | Ищем копию… | Looking for your backup… |
| onb_restore_decrypting | Расшифровываем… | Decrypting… |
| onb_restore_history_title | Вернуть переписку? | Bring your chats back? |
| onb_restore_history_text | Если вы включали резервную копию, введите её пароль. | If you turned on backups, enter the backup password. |
| onb_restore_history_do | Вернуть переписку | Restore chats |
| onb_restore_history_skip | Пропустить | Skip |
| onb_restore_err_password | Неверное имя пользователя или пароль | Wrong username or password |
| onb_restore_err_many | Слишком много попыток. Попробуйте через час | Too many attempts. Try again in an hour |
| onb_restore_err_replicating | Копия ещё не дошла до этого сервера. Попробуйте позже | The backup hasn't reached this server yet. Try again later |
| onb_restore_err_words | Проверьте слова: одно или несколько не подходят | Check the words: one or more don't fit |
| onb_restore_err_unknown | Аккаунт с такими словами не найден в этой сети | No account with these words in this network |
| onb_restore_err_corrupt | Копия повреждена. Попробуйте ещё раз позже | The backup is damaged. Try again later |
| onb_restore_err_network | Нет связи с сервером | Can't reach the server |

app/conversation/chats: `superseded_title` «Аккаунт на другом телефоне» / "Account moved to another phone",
`superseded_text` (as in the criteria) / "This account was restored on another phone. This phone no longer receives
messages. To use Otter here, clear the app's data and restore the account again.", `photo_not_in_backup` «Нет в
резервной копии» / "Not in the backup", `system_reset` «%1$s восстановил(а) аккаунт» / "%1$s restored their account".
- [ ] **Step 4:** `MainViewModel` exposes `superseded = settings.observeInt(Settings.SUPERSEDED, 0).map { it != 0 }`;
`MainActivity` renders `SupersededScreen()` when true. `ForegroundSync` (Task 7) already refuses to start.
- [ ] **Step 5:** `./gradlew test :app:assembleDebug` → PASS. **Commit** `feat(onboarding): restore flow; superseded screen; restored/reset rendering`.

---

### Task 12: Live acceptance, release builds, manual checklist

**Goal:** Prove the "done when" against real nodes and leave a two-phone checklist.

**Files:**
- Create: `core/data/src/test/kotlin/app/ottermsg/core/data/LiveRestoreTest.kt`, `otter-android/docs/m6-manual-test.md`
- Modify: `app/src/androidTest/.../SmokeTest.kt` (welcome shows both buttons)

**Acceptance Criteria:**
- [ ] Dev mesh restarted on the M6 server build (`cd otter-server && make build && scripts/dev-mesh.sh stop && scripts/dev-mesh.sh` — data kept).
- [ ] `LiveRestoreTest` (skipped without `OTTER_DEV_INVITE`): anna (prefers node a) and boris (prefers c) register,
  chat, form a group, exchange a group message; anna sets a backup password; anna's graph is discarded; a fresh
  graph restores via node c (prefer c) with username + password → anna's texts present; boris → anna 1:1 decrypts;
  anna → boris 1:1 decrypts; group message both ways; the discarded graph re-opened online → superseded.
  Second run with node b killed (`scripts/dev-mesh.sh kill b`) passes too; then `start b`.
- [ ] `./gradlew assembleDebug assembleRelease test` green; release APK size noted (bcprov after R8).
- [ ] Emulator: enable backup (weak password rejected, strong accepted), «Создать сейчас», wipe app data, restore with
  username + password via an invite link, history visible, photo shows «Нет в резервной копии», a scripted contact's
  message arrives; restore with 24 words + skip history; superseded screen on the old install (second emulator or the
  scripted second client); TalkBack labels on the backup screen.
- [ ] `otter-android/docs/m6-manual-test.md` with rows for two phones (backup on, restore on the other phone after
  clearing data, both directions, group, old phone shows superseded, 24-word restore, 200 % font, TalkBack).

**Verify:** `OTTER_DEV_INVITE="otter://join/…" OTTER_PREFER_A=a OTTER_PREFER_B=c ./gradlew :core:data:testDebugUnitTest --tests '*LiveRestoreTest*' --rerun`

**Steps:**

- [ ] **Step 1:** Write `LiveRestoreTest` on `LiveClient` like `LiveBlobTest` (same env vars and `eventually`
budgets; Argon2 at full parameters is fine here). Use a fresh bootstrap invite:
`OTTER_ADMIN_PASSPHRASE=dev-only-passphrase bin/otter-admin --dir .dev-mesh/admin invite bootstrap` (M3 notes).
- [ ] **Step 2:** Restart the dev mesh on the new build (it holds the owner's dev data — use `stop` + start, never
`--reset`); run the live test twice (all nodes; with b killed).
- [ ] **Step 3:** Builds, emulator checks (use the M3/M4 notes: `adb reverse`, `svc power stayon true`, typing long
links in ≤ 60-char chunks, `adb input text` can't type Cyrillic — use Latin passwords on the emulator), checklist.
- [ ] **Step 4: Commit** `test: M6 live restore, manual checklist, release checks`.

---

### Task 13: Docs and merge

**Goal:** Record decisions and behaviour; merge both branches.

**Files (not in git unless noted):**
- `docs/00-decisions.md` (D50–D55), `docs/02-protocol.md` (new methods, `BACKUP_META`, `LoginResponse`,
  `SessionReset`, `PreKeys.installed_ms`), `docs/03-mesh-replication.md` (backup records never age out; persistent blob
  GC), `docs/04-security.md` (restore needs the network link; fake salt per node; rate limits as built; superseded
  install), `docs/07-android-architecture.md` (backup/restore modules, onboarding steps), `docs/09-roadmap.md` (M6 row
  done + "M6 notes": deviations, test results, APK size), `docs/10-otter-design-guidelines.md` (backup screen, restore
  screens, superseded screen), README if it lists features.
- Memory: `~/.claude/projects/-home-al-Documents-Projects-OttterMSG/memory/otter-milestone-status.md`

**Acceptance Criteria:**
- [ ] Docs updated as listed; `make check` and `./gradlew test assembleDebug` pass on the merge results.
- [ ] `m6-backup` fast-forwarded into `main` in both repos, branches deleted.
- [ ] Memory: M6 merged (heads), open items (two-phone rows of `m6-manual-test.md`), next milestone M5 push.

**Verify:** `cd otter-server && make check`; `cd otter-android && ./gradlew test assembleDebug`

**Steps:**

- [ ] **Step 1:** Write the docs.
- [ ] **Step 2:** Merge:

```bash
cd otter-server && git checkout main && git merge --ff-only m6-backup && git branch -d m6-backup && make check
cd ../otter-android && git checkout main && git merge --ff-only m6-backup && git branch -d m6-backup && ./gradlew test assembleDebug
```
- [ ] **Step 3:** Update memory; report to the owner: what works, what was tested, open two-phone rows.

---

## Self-review notes (planner)

- **Spec coverage:** opt-in Settings backup (T10), 24 h foreground + «Создать сейчас» + password change (T8),
  username+password restore (T9/T11), 24-word restore + optional history (T9/T11), superseded install (T2/T3/T7/T11),
  photos thumbnail-only (T8 import, T11 UI), snapshot contents (T1 proto, T8 codec), Argon2id/HKDF/Tink (T5/T8),
  persistent blob + BACKUP_META + latest wins + GC (T1/T2), public auth/fetch + fake salt + rate limits + grant (T3),
  login response (T3), PREKEYS replacement (T2), SessionReset + auto-reset (T7), meshsim A-down restore via C (T4),
  live acceptance (T12), docs/merge (T13). Restore needing the network link is a gap in the spec → D54.
- **Type names used across tasks:** `BackupKeys.derive/Keys(backupKey, authSecret, verifier)`, `BackupManager
  .setPassword/runNow/runIfDue/state`, `RestoreManager` implements `Restorer.withPassword/withWords/addHistory`,
  `InstallGuard.afterLogin(api, LoginResponse): Boolean`, `SessionResets.send/onUndecryptable/sendToAll/onReceived`,
  `Settings.installedMs/restorePending/superseded/backup*`, `MessageKind.SYSTEM_RESET = 4`,
  `AttachmentState.NOT_IN_BACKUP = 8`, Go `Store.BackupFor/DeviceInstall/PersistentBlobs/AddAuthFailure/AuthFailures/
  AuthFailuresTotal`, `Service.BackupAuth/BackupFetch/PublishBackup`, `VerifyLogin → (*pb.LoginResponse, error)`.
- **Known risks for the executor:** (1) `RecordCodec.body` may not take an explicit id — add one (Task 8 note). (2) `RoomSignalKeyValue` key prefixes for the test helper that wipes
  sessions. (3) BouncyCastle size in the release APK — if R8 keeps too much, add a keep-rule-free check and note the
  size; fallback is `argon2kt` with Argon2 tests moved to instrumentation. (4) Messages sent to the old install after
  the last backup are lost by design (documented).
