# M0 — Foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lay the foundations of both repositories: shared protobuf schemas, signed-record
validation, SQLite store with group commit, the admin CLI that creates a network and signs a
manifest, and an Android skeleton (modules, theme, encrypted DB, BIP-39 seed, Ed25519) that
verifies a manifest signed by the Go side.

**Architecture:** Two git repos side by side in `~/Documents/Projects/OttterMSG`:
`otter-server/` (Go module `ottermsg/server`, owns `proto/`) and `otter-android/` (Gradle
multi-module; copies protos and cross-language test vectors from `../otter-server` via
`scripts/sync-proto.sh`). Specs: `docs/01`–`docs/10`. Records are signed over their exact
serialized `body` bytes (no canonicalization needed). Record key = `author‖id` (32 bytes).

**Tech Stack:** Go 1.26, `google.golang.org/protobuf`, buf (codegen), `modernc.org/sqlite`,
`golang.org/x/crypto` (argon2, chacha20poly1305), `crypto/ed25519`, `crypto/hkdf`.
Android: Gradle 8.14.3 (run with JDK 21), AGP 8.13.2, Kotlin 2.2.21, KSP 2.3.0, Hilt 2.57.2,
Room 2.8.3, SQLCipher `net.zetetic:sqlcipher-android` 4.11.0, Compose BOM 2025.10.01, Tink
1.19.0, protobuf-javalite 4.32.1, JUnit 4, Robolectric 4.16. compileSdk 36, minSdk 26.

**Environment facts (verified 2026-11-10):** Android SDK at `~/Android/Sdk`
(platforms 33–36, build-tools 36.1.0). System `gradle` is 4.4 (unusable) → bootstrap wrapper
from the 8.14.3 distribution. JDKs in `/usr/lib/jvm/java-{17,21,25}-openjdk-amd64`. No
`protoc` installed → Go side uses `buf` via `go run`, Android side uses the protobuf Gradle
plugin's downloaded `protoc`.

**Out of scope for M0:** envelopes/API protos (M1), libsignal (M1), networking (M1), any
type-specific store appliers (M1).

---

## File structure

```
otter-server/
  go.mod  Makefile  .gitignore  README.md  buf.yaml  buf.gen.yaml
  proto/otter/v1/records.proto       Record, RecordBody, RecordType, M0 payloads
  proto/otter/v1/manifest.proto      Manifest, NodeInfo, Endpoint
  internal/proto/otterv1/            generated (committed)
  internal/keys/ids.go               UserID/NodeID/NetworkID, RecordKey
  internal/keys/derive.go            DeriveAccountKey(seed)
  internal/keys/keyfile.go           passphrase-encrypted key file + plain key file
  internal/records/sign.go           Sign
  internal/records/validate.go       Validator, sentinel errors
  internal/store/store.go            Open/Close, reader pool, writer goroutine
  internal/store/apply.go            Apply (group commit), Since, Get
  internal/store/migrate.go          embedded migrations runner
  internal/store/migrations/0001_init.sql
  internal/admin/state.go            admin directory: network, nodes, manifest version
  internal/admin/manifest.go         build + sign manifest record
  cmd/otter-admin/main.go            CLI
  internal/vectors/vectors_test.go   writes/checks testdata/vectors/v1.json
  testdata/vectors/v1.json

otter-android/
  settings.gradle.kts  build.gradle.kts  gradle.properties  gradle/libs.versions.toml
  gradlew gradlew.bat gradle/wrapper/*  local.properties (gitignored)  .gitignore  README.md
  scripts/sync-proto.sh
  core/proto/      (JVM lib)  src/main/proto/otter/v1/*.proto (synced)
  core/crypto/     (JVM lib)  Bip39.kt, bip39-english.txt, SeedKeys.kt, Ed25519.kt,
                              Ids.kt, RecordCodec.kt, ManifestVerifier.kt
                              src/test/resources/vectors/v1.json (synced)
  core/database/   (Android lib) OtterDatabase.kt, entities, DAOs, DatabaseKeyProvider.kt,
                              KeyWrapper.kt, KeystoreKeyWrapper.kt, DatabaseModule.kt
  core/ui/         (Android lib) theme/Color.kt, Theme.kt, Type.kt, Dimens.kt
  app/             OtterApp.kt (Hilt), MainActivity.kt, res/values{,-en}/strings.xml
```

---

## Part A — `otter-server`

### Task 1: Server repo scaffold, protos, codegen

**Goal:** Go module with protobuf schemas generated into `internal/proto/otterv1`, `make check` green.

**Files:**
- Create: `otter-server/go.mod`, `Makefile`, `.gitignore`, `README.md`, `buf.yaml`, `buf.gen.yaml`
- Create: `otter-server/proto/otter/v1/records.proto`, `proto/otter/v1/manifest.proto`
- Create (generated): `otter-server/internal/proto/otterv1/*.pb.go`
- Test: `otter-server/internal/proto/otterv1/roundtrip_test.go`

**Acceptance Criteria:**
- [ ] `make gen` regenerates code with no diff
- [ ] `make check` (vet + test) passes
- [ ] Round-trip test marshals/unmarshals a `Record` and a `Manifest`

**Verify:** `cd otter-server && make gen && git diff --exit-code internal/proto && make check`

**Steps:**

- [ ] **Step 1: Module + tooling files**

`go.mod`:
```
module ottermsg/server

go 1.26
```

`buf.yaml`:
```yaml
version: v2
modules:
  - path: proto
lint:
  use: [STANDARD]
  except: [ENUM_VALUE_PREFIX, ENUM_ZERO_VALUE_SUFFIX, PACKAGE_VERSION_SUFFIX]
```

`buf.gen.yaml`:
```yaml
version: v2
plugins:
  - local: protoc-gen-go
    out: internal/proto
    opt: [module=ottermsg/server/internal/proto]
```

`Makefile`:
```make
BUF := go run github.com/bufbuild/buf/cmd/buf@v1.75.0
export PATH := $(shell go env GOPATH)/bin:$(PATH)

.PHONY: gen check test vet build
gen:
	go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.12
	$(BUF) lint
	$(BUF) generate
vet:
	go vet ./...
test:
	go test -race -count=1 ./...
check: vet test
build:
	CGO_ENABLED=0 go build -trimpath -o bin/ ./cmd/...
```

`.gitignore`: `bin/`, `*.db`, `*.db-wal`, `*.db-shm`, `/tmp/`.

`README.md`: one paragraph (what it is, `make gen`, `make check`, `make build`, link to `../docs`).

- [ ] **Step 2: `proto/otter/v1/records.proto`**

```proto
syntax = "proto3";
package otter.v1;

option go_package = "ottermsg/server/internal/proto/otterv1;otterv1";
option java_package = "app.ottermsg.proto.v1";
option java_multiple_files = true;

enum RecordType {
  RECORD_TYPE_UNSPECIFIED = 0;
  DIRECTORY_ENTRY = 1;
  PREKEYS = 2;
  INVITE = 3;
  INVITE_USED = 4;
  ENVELOPE = 5;
  ACK = 6;
  PREKEY_CONSUMED = 7;
  PUSH_TOKEN = 8;
  BLOB_META = 9;
  BACKUP_META = 10;
  MANIFEST = 11;
  REVOCATION = 12;
  INVITE_RIGHTS = 13;
}

// Signature is Ed25519 over the exact `body` bytes.
message Record {
  bytes body = 1;
  bytes signature = 2;
}

message RecordBody {
  bytes id = 1;          // 16 random bytes, unique per author
  RecordType type = 2;
  bytes author = 3;      // user_id | node_id | network_id (16 bytes)
  int64 created_ms = 4;
  int64 expires_ms = 5;  // 0 = never
  bytes payload = 6;
}

message DirectoryEntry {
  bytes user_id = 1;
  string username = 2;
  string display_name = 3;
  bytes account_pub = 4;   // Ed25519, 32 bytes
  bytes identity_pub = 5;  // libsignal serialized Curve25519 (33 bytes, 0x05 prefix)
  bytes identity_sig = 6;  // XEdDSA by identity key over account_pub (checked by clients)
  uint64 version = 7;
  bool can_invite = 8;
}

message Revocation {
  bytes user_id = 1;
  string reason = 2;
}

message InviteRights {
  bytes user_id = 1;
  bool can_invite = 2;
  uint64 version = 3;
}

message Invite {
  bytes invite_id = 1;   // SHA-256(secret)
  int64 expires_ms = 2;
}

message InviteUsed {
  bytes invite_id = 1;
  bytes user_id = 2;
}

message Ack {
  repeated bytes envelope_ids = 1;
}
```

- [ ] **Step 3: `proto/otter/v1/manifest.proto`**

```proto
syntax = "proto3";
package otter.v1;

option go_package = "ottermsg/server/internal/proto/otterv1;otterv1";
option java_package = "app.ottermsg.proto.v1";
option java_multiple_files = true;

message Manifest {
  uint64 version = 1;
  int64 issued_ms = 2;
  bytes network_pub = 3;
  repeated NodeInfo nodes = 4;
  uint32 min_app_version = 5;
}

message NodeInfo {
  bytes node_id = 1;
  bytes node_pub = 2;
  string label = 3;
  bool push_capable = 4;
  repeated Endpoint endpoints = 5;
}

message Endpoint {
  enum Kind {
    WSS = 0;
    REALITY = 1;
  }
  Kind kind = 1;
  string host = 2;
  uint32 port = 3;
  string path = 4;
  bytes tls_spki_pin = 5;
  bool via_cdn = 6;
  string vless_uuid = 7;
  bytes reality_pub = 8;
  repeated string short_ids = 9;
  repeated string server_names = 10;
  string fingerprint = 11;
  uint32 priority = 12;
}
```

- [ ] **Step 4: Generate and write round-trip test**

Run: `cd otter-server && make gen` → creates `internal/proto/otterv1/records.pb.go`, `manifest.pb.go`.
Then `go get google.golang.org/protobuf@v1.36.12 && go mod tidy`.

`internal/proto/otterv1/roundtrip_test.go`:
```go
package otterv1_test

import (
	"testing"

	"google.golang.org/protobuf/proto"
	"ottermsg/server/internal/proto/otterv1"
)

func TestRecordRoundTrip(t *testing.T) {
	body := &otterv1.RecordBody{Id: make([]byte, 16), Type: otterv1.RecordType_MANIFEST, Author: make([]byte, 16), CreatedMs: 42}
	b, err := proto.Marshal(body)
	if err != nil { t.Fatal(err) }
	var got otterv1.RecordBody
	if err := proto.Unmarshal(b, &got); err != nil { t.Fatal(err) }
	if !proto.Equal(body, &got) { t.Fatalf("mismatch: %v vs %v", body, &got) }
}

func TestManifestRoundTrip(t *testing.T) {
	m := &otterv1.Manifest{Version: 3, Nodes: []*otterv1.NodeInfo{{Label: "a", Endpoints: []*otterv1.Endpoint{{Kind: otterv1.Endpoint_WSS, Host: "x", Port: 443}}}}}
	b, _ := proto.Marshal(m)
	var got otterv1.Manifest
	if err := proto.Unmarshal(b, &got); err != nil { t.Fatal(err) }
	if !proto.Equal(m, &got) { t.Fatal("mismatch") }
}
```

- [ ] **Step 5: Run** `make check` → PASS.

- [ ] **Step 6: Commit**
```bash
git add -A && git commit -m "chore: scaffold server module and protobuf schemas"
```

---

### Task 2: `internal/keys` — ids, derivation, key files

**Goal:** Identity helpers shared by validator, admin CLI and tests.

**Files:**
- Create: `internal/keys/ids.go`, `internal/keys/derive.go`, `internal/keys/keyfile.go`
- Test: `internal/keys/keys_test.go`

**Acceptance Criteria:**
- [ ] `ID16(pub)` = first 16 bytes of SHA-256(pub); `RecordKey(author,id)` = 32-byte concat, errors on wrong lengths
- [ ] `DeriveAccountKey(seed)` = Ed25519 key from HKDF-SHA256(ikm=seed, salt=nil, info="otter/account/v1", 32); deterministic; rejects seed ≠ 32 bytes
- [ ] Encrypted key file round-trips; wrong passphrase → `ErrBadPassphrase`; file mode 0600
- [ ] Plain key file (hex seed) round-trips

**Verify:** `go test ./internal/keys/ -v` → PASS

**Steps:**

- [ ] **Step 1: Write failing tests** (`keys_test.go`)

```go
package keys

import (
	"bytes"
	"crypto/ed25519"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestID16(t *testing.T) {
	pub := bytes.Repeat([]byte{1}, 32)
	id := ID16(pub)
	if len(id) != 16 { t.Fatalf("len %d", len(id)) }
	if !bytes.Equal(id, ID16(pub)) { t.Fatal("not deterministic") }
}

func TestRecordKey(t *testing.T) {
	k, err := RecordKey(make([]byte, 16), bytes.Repeat([]byte{2}, 16))
	if err != nil || len(k) != 32 || k[16] != 2 { t.Fatalf("bad key %x %v", k, err) }
	if _, err := RecordKey(make([]byte, 15), make([]byte, 16)); err == nil { t.Fatal("want error") }
}

func TestDeriveAccountKey(t *testing.T) {
	seed := bytes.Repeat([]byte{7}, 32)
	a, err := DeriveAccountKey(seed)
	if err != nil { t.Fatal(err) }
	b, _ := DeriveAccountKey(seed)
	if !bytes.Equal(a, b) { t.Fatal("not deterministic") }
	if len(a) != ed25519.PrivateKeySize { t.Fatal("size") }
	if _, err := DeriveAccountKey(seed[:31]); err == nil { t.Fatal("want error") }
}

func TestEncryptedKeyFile(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "network.key.enc")
	_, priv, _ := ed25519.GenerateKey(nil)
	if err := WriteEncryptedKey(p, priv, []byte("correct horse")); err != nil { t.Fatal(err) }
	st, _ := os.Stat(p)
	if st.Mode().Perm() != 0o600 { t.Fatalf("mode %v", st.Mode()) }
	got, err := ReadEncryptedKey(p, []byte("correct horse"))
	if err != nil || !bytes.Equal(got, priv) { t.Fatalf("roundtrip: %v", err) }
	if _, err := ReadEncryptedKey(p, []byte("wrong")); !errors.Is(err, ErrBadPassphrase) { t.Fatalf("want ErrBadPassphrase, got %v", err) }
}

func TestPlainKeyFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "node.key")
	_, priv, _ := ed25519.GenerateKey(nil)
	if err := WritePlainKey(p, priv); err != nil { t.Fatal(err) }
	got, err := ReadPlainKey(p)
	if err != nil || !bytes.Equal(got, priv) { t.Fatalf("roundtrip: %v", err) }
}
```

- [ ] **Step 2: Run** `go test ./internal/keys/` → FAIL (undefined).

- [ ] **Step 3: Implement**

`ids.go`:
```go
// Package keys holds identity helpers: ids, key derivation and key files.
package keys

import (
	"crypto/sha256"
	"fmt"
)

// ID16 returns the first 16 bytes of SHA-256(pub). Used for user_id, node_id, network_id.
func ID16(pub []byte) []byte {
	h := sha256.Sum256(pub)
	return append([]byte(nil), h[:16]...)
}

// RecordKey is the global dedup/storage key of a record: author || id.
func RecordKey(author, id []byte) ([]byte, error) {
	if len(author) != 16 || len(id) != 16 {
		return nil, fmt.Errorf("record key: author %d bytes, id %d bytes, want 16/16", len(author), len(id))
	}
	return append(append(make([]byte, 0, 32), author...), id...), nil
}
```

`derive.go`:
```go
package keys

import (
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/sha256"
	"fmt"
)

const InfoAccount = "otter/account/v1"

// DeriveAccountKey derives the user's Ed25519 account key from the 32-byte recovery seed.
// Must match the Android implementation (see testdata/vectors/v1.json).
func DeriveAccountKey(seed []byte) (ed25519.PrivateKey, error) {
	if len(seed) != 32 {
		return nil, fmt.Errorf("seed must be 32 bytes, got %d", len(seed))
	}
	k, err := hkdf.Key(sha256.New, seed, nil, InfoAccount, ed25519.SeedSize)
	if err != nil {
		return nil, err
	}
	return ed25519.NewKeyFromSeed(k), nil
}
```

`keyfile.go`:
```go
package keys

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"strings"

	"golang.org/x/crypto/argon2"
	"golang.org/x/crypto/chacha20poly1305"
)

var ErrBadPassphrase = errors.New("wrong passphrase or corrupted key file")

var magic = []byte("OTTERKEY1")

func kek(pass, salt []byte) []byte { return argon2.IDKey(pass, salt, 3, 64*1024, 4, 32) }

// WriteEncryptedKey stores an Ed25519 private key encrypted with a passphrase:
// magic | salt(16) | nonce(24) | XChaCha20-Poly1305(seed, aad=magic).
func WriteEncryptedKey(path string, priv ed25519.PrivateKey, pass []byte) error {
	salt := make([]byte, 16)
	nonce := make([]byte, chacha20poly1305.NonceSizeX)
	if _, err := rand.Read(salt); err != nil { return err }
	if _, err := rand.Read(nonce); err != nil { return err }
	aead, err := chacha20poly1305.NewX(kek(pass, salt))
	if err != nil { return err }
	out := bytes.Join([][]byte{magic, salt, nonce, aead.Seal(nil, nonce, priv.Seed(), magic)}, nil)
	return os.WriteFile(path, out, 0o600)
}

func ReadEncryptedKey(path string, pass []byte) (ed25519.PrivateKey, error) {
	b, err := os.ReadFile(path)
	if err != nil { return nil, err }
	if len(b) < len(magic)+16+24+16 || !bytes.Equal(b[:len(magic)], magic) {
		return nil, fmt.Errorf("%s: not an otter key file", path)
	}
	b = b[len(magic):]
	salt, nonce, ct := b[:16], b[16:40], b[40:]
	aead, err := chacha20poly1305.NewX(kek(pass, salt))
	if err != nil { return nil, err }
	seed, err := aead.Open(nil, nonce, ct, magic)
	if err != nil { return nil, ErrBadPassphrase }
	return ed25519.NewKeyFromSeed(seed), nil
}

// WritePlainKey stores the hex seed (for node keys deployed to servers).
func WritePlainKey(path string, priv ed25519.PrivateKey) error {
	return os.WriteFile(path, []byte(hex.EncodeToString(priv.Seed())+"\n"), 0o600)
}

func ReadPlainKey(path string) (ed25519.PrivateKey, error) {
	b, err := os.ReadFile(path)
	if err != nil { return nil, err }
	seed, err := hex.DecodeString(strings.TrimSpace(string(b)))
	if err != nil || len(seed) != ed25519.SeedSize {
		return nil, fmt.Errorf("%s: invalid key file", path)
	}
	return ed25519.NewKeyFromSeed(seed), nil
}
```
Then `go get golang.org/x/crypto@v0.58.0 && go mod tidy`.

- [ ] **Step 4: Run** `go test ./internal/keys/ -v` → PASS.
- [ ] **Step 5: Commit** `git add -A && git commit -m "feat(keys): ids, account key derivation, key files"`

---

### Task 3: `internal/records` — sign and validate

**Goal:** Pure (no I/O) signing and validation of records per `docs/02-protocol.md` §2.

**Files:**
- Create: `internal/records/sign.go`, `internal/records/validate.go`
- Test: `internal/records/validate_test.go`

**Acceptance Criteria:**
- [ ] `Sign` marshals body deterministically and signs the exact bytes
- [ ] Network-authored types (MANIFEST, REVOCATION, INVITE_RIGHTS) require `author == ID16(networkPub)` and network signature
- [ ] DIRECTORY_ENTRY self-certifies: `author == entry.user_id == ID16(entry.account_pub)`, signed by `account_pub`; username `^[a-z0-9_]{3,32}$`; display name 1–64 runes; identity_pub 33 bytes; identity_sig 64 bytes; if resolver already knows the user with a different key → `ErrKeyMismatch`
- [ ] Other types: key from resolver; unknown → `ErrUnknownAuthor`; revoked → `ErrRevoked`
- [ ] Rejects: body > 300 KiB, sig ≠ 64 bytes, id/author ≠ 16 bytes, UNSPECIFIED/unknown type, expired, bad signature, MANIFEST whose `network_pub` ≠ validator's
- [ ] Table-driven test covers every rule above

**Verify:** `go test ./internal/records/ -v` → PASS

**Steps:**

- [ ] **Step 1: Write failing table test** (`validate_test.go`)

```go
package records

import (
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"strings"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"
	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
)

type fakeUsers map[string]UserKey

func (f fakeUsers) UserKey(id []byte) (UserKey, bool) { k, ok := f[string(id)]; return k, ok }

var now = time.UnixMilli(1_800_000_000_000)

func rid() []byte { b := make([]byte, 16); rand.Read(b); return b }

func mustSign(t *testing.T, b *pb.RecordBody, k ed25519.PrivateKey) *pb.Record {
	t.Helper()
	r, err := Sign(b, k)
	if err != nil { t.Fatal(err) }
	return r
}

func payload(m proto.Message) []byte { b, _ := proto.Marshal(m); return b }

func TestValidate(t *testing.T) {
	netPub, netPriv, _ := ed25519.GenerateKey(nil)
	netID := keys.ID16(netPub)
	userPub, userPriv, _ := ed25519.GenerateKey(nil)
	userID := keys.ID16(userPub)
	revPub, revPriv, _ := ed25519.GenerateKey(nil)
	revID := keys.ID16(revPub)
	otherPub, otherPriv, _ := ed25519.GenerateKey(nil)
	_ = otherPub

	users := fakeUsers{string(userID): {Pub: userPub}, string(revID): {Pub: revPub, Revoked: true}}
	v := &Validator{NetworkPub: netPub, Users: users, Now: func() time.Time { return now }}

	entry := func(pub ed25519.PublicKey, username string) *pb.DirectoryEntry {
		return &pb.DirectoryEntry{UserId: keys.ID16(pub), Username: username, DisplayName: "Мама",
			AccountPub: pub, IdentityPub: make([]byte, 33), IdentitySig: make([]byte, 64), Version: 1, CanInvite: true}
	}
	newPub, newPriv, _ := ed25519.GenerateKey(nil)
	manifest := &pb.Manifest{Version: 1, NetworkPub: netPub}
	ack := payload(&pb.Ack{EnvelopeIds: [][]byte{rid()}})

	cases := []struct {
		name string
		rec  func() *pb.Record
		want error
	}{
		{"manifest ok", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_MANIFEST, Author: netID, Payload: payload(manifest)}, netPriv)
		}, nil},
		{"manifest signed by user", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_MANIFEST, Author: netID, Payload: payload(manifest)}, userPriv)
		}, ErrBadSignature},
		{"manifest wrong author", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_MANIFEST, Author: userID, Payload: payload(manifest)}, netPriv)
		}, ErrBadAuthor},
		{"manifest foreign network_pub", func() *pb.Record {
			m := &pb.Manifest{Version: 1, NetworkPub: userPub}
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_MANIFEST, Author: netID, Payload: payload(m)}, netPriv)
		}, ErrBadPayload},
		{"new directory entry ok", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_DIRECTORY_ENTRY, Author: keys.ID16(newPub), Payload: payload(entry(newPub, "mama_1"))}, newPriv)
		}, nil},
		{"directory entry bad username", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_DIRECTORY_ENTRY, Author: keys.ID16(newPub), Payload: payload(entry(newPub, "Mama!"))}, newPriv)
		}, ErrBadPayload},
		{"directory entry long display name", func() *pb.Record {
			e := entry(newPub, "mama"); e.DisplayName = strings.Repeat("я", 65)
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_DIRECTORY_ENTRY, Author: keys.ID16(newPub), Payload: payload(e)}, newPriv)
		}, ErrBadPayload},
		{"directory entry author != user_id", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_DIRECTORY_ENTRY, Author: userID, Payload: payload(entry(newPub, "mama"))}, newPriv)
		}, ErrBadAuthor},
		{"directory entry key takeover", func() *pb.Record {
			e := entry(otherPub, "x_y_z"); e.UserId = userID
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_DIRECTORY_ENTRY, Author: userID, Payload: payload(e)}, otherPriv)
		}, ErrBadAuthor},
		{"ack by known user ok", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_ACK, Author: userID, Payload: ack}, userPriv)
		}, nil},
		{"ack by unknown user", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_ACK, Author: keys.ID16(otherPub), Payload: ack}, otherPriv)
		}, ErrUnknownAuthor},
		{"ack by revoked user", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_ACK, Author: revID, Payload: ack}, revPriv)
		}, ErrRevoked},
		{"expired", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_ACK, Author: userID, ExpiresMs: now.UnixMilli() - 1, Payload: ack}, userPriv)
		}, ErrExpired},
		{"unspecified type", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Author: userID}, userPriv)
		}, ErrMalformed},
		{"short id", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: []byte{1}, Type: pb.RecordType_ACK, Author: userID, Payload: ack}, userPriv)
		}, ErrMalformed},
		{"oversized", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_ACK, Author: userID, Payload: make([]byte, MaxBodySize+1)}, userPriv)
		}, ErrMalformed},
		{"truncated signature", func() *pb.Record {
			r := mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_ACK, Author: userID, Payload: ack}, userPriv)
			r.Signature = r.Signature[:10]
			return r
		}, ErrMalformed},
		{"tampered body", func() *pb.Record {
			r := mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_ACK, Author: userID, Payload: ack}, userPriv)
			r.Body[len(r.Body)-1] ^= 1
			return r
		}, ErrBadSignature},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := v.Validate(c.rec())
			if c.want == nil && err != nil { t.Fatalf("unexpected error: %v", err) }
			if c.want != nil && !errors.Is(err, c.want) { t.Fatalf("want %v, got %v", c.want, err) }
		})
	}
}
```

- [ ] **Step 2: Run** → FAIL (undefined).

- [ ] **Step 3: Implement**

`sign.go`:
```go
// Package records signs and validates replicated records. It performs no I/O.
package records

import (
	"crypto/ed25519"

	"google.golang.org/protobuf/proto"
	pb "ottermsg/server/internal/proto/otterv1"
)

// Sign serializes body deterministically and signs the exact bytes.
func Sign(body *pb.RecordBody, priv ed25519.PrivateKey) (*pb.Record, error) {
	b, err := proto.MarshalOptions{Deterministic: true}.Marshal(body)
	if err != nil {
		return nil, err
	}
	return &pb.Record{Body: b, Signature: ed25519.Sign(priv, b)}, nil
}
```

`validate.go`:
```go
package records

import (
	"bytes"
	"crypto/ed25519"
	"errors"
	"fmt"
	"regexp"
	"time"
	"unicode/utf8"

	"google.golang.org/protobuf/proto"
	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
)

const MaxBodySize = 300 * 1024

var (
	ErrMalformed     = errors.New("malformed record")
	ErrBadAuthor     = errors.New("author binding invalid")
	ErrBadSignature  = errors.New("signature invalid")
	ErrUnknownAuthor = errors.New("unknown author")
	ErrRevoked       = errors.New("author revoked")
	ErrExpired       = errors.New("record expired")
	ErrBadPayload    = errors.New("payload invalid")
	ErrKeyMismatch   = errors.New("user already registered with another key")
)

var usernameRe = regexp.MustCompile(`^[a-z0-9_]{3,32}$`)

type UserKey struct {
	Pub     ed25519.PublicKey
	Revoked bool
}

// UserResolver looks up a user's current account key (implemented by the store/directory).
type UserResolver interface {
	UserKey(userID []byte) (UserKey, bool)
}

type Validator struct {
	NetworkPub ed25519.PublicKey
	Users      UserResolver
	Now        func() time.Time
}

func networkAuthored(t pb.RecordType) bool {
	return t == pb.RecordType_MANIFEST || t == pb.RecordType_REVOCATION || t == pb.RecordType_INVITE_RIGHTS
}

// Validate checks structure, author binding, signature and type-specific payload rules.
// It returns the parsed body on success.
func (v *Validator) Validate(r *pb.Record) (*pb.RecordBody, error) {
	if len(r.GetBody()) == 0 || len(r.GetBody()) > MaxBodySize || len(r.GetSignature()) != ed25519.SignatureSize {
		return nil, ErrMalformed
	}
	var body pb.RecordBody
	if err := proto.Unmarshal(r.Body, &body); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrMalformed, err)
	}
	if len(body.Id) != 16 || len(body.Author) != 16 {
		return nil, ErrMalformed
	}
	if _, known := pb.RecordType_name[int32(body.Type)]; !known || body.Type == pb.RecordType_RECORD_TYPE_UNSPECIFIED {
		return nil, ErrMalformed
	}
	if body.ExpiresMs != 0 && body.ExpiresMs < v.Now().UnixMilli() {
		return nil, ErrExpired
	}
	key, err := v.signerKey(&body)
	if err != nil {
		return nil, err
	}
	if !ed25519.Verify(key, r.Body, r.Signature) {
		return nil, ErrBadSignature
	}
	if err := v.checkPayload(&body); err != nil {
		return nil, err
	}
	return &body, nil
}

func (v *Validator) signerKey(b *pb.RecordBody) (ed25519.PublicKey, error) {
	switch {
	case networkAuthored(b.Type):
		if !bytes.Equal(b.Author, keys.ID16(v.NetworkPub)) {
			return nil, ErrBadAuthor
		}
		return v.NetworkPub, nil
	case b.Type == pb.RecordType_DIRECTORY_ENTRY:
		var e pb.DirectoryEntry
		if err := proto.Unmarshal(b.Payload, &e); err != nil || len(e.AccountPub) != ed25519.PublicKeySize {
			return nil, ErrBadPayload
		}
		if !bytes.Equal(b.Author, e.UserId) || !bytes.Equal(e.UserId, keys.ID16(e.AccountPub)) {
			return nil, ErrBadAuthor
		}
		if k, ok := v.Users.UserKey(e.UserId); ok {
			if k.Revoked {
				return nil, ErrRevoked
			}
			if !bytes.Equal(k.Pub, e.AccountPub) {
				return nil, ErrKeyMismatch
			}
		}
		return ed25519.PublicKey(e.AccountPub), nil
	default:
		k, ok := v.Users.UserKey(b.Author)
		if !ok {
			return nil, ErrUnknownAuthor
		}
		if k.Revoked {
			return nil, ErrRevoked
		}
		return k.Pub, nil
	}
}

func (v *Validator) checkPayload(b *pb.RecordBody) error {
	switch b.Type {
	case pb.RecordType_MANIFEST:
		var m pb.Manifest
		if err := proto.Unmarshal(b.Payload, &m); err != nil || !bytes.Equal(m.NetworkPub, v.NetworkPub) || m.Version == 0 {
			return ErrBadPayload
		}
	case pb.RecordType_DIRECTORY_ENTRY:
		var e pb.DirectoryEntry
		_ = proto.Unmarshal(b.Payload, &e) // already parsed in signerKey
		n := utf8.RuneCountInString(e.DisplayName)
		if !usernameRe.MatchString(e.Username) || n < 1 || n > 64 || !utf8.ValidString(e.DisplayName) ||
			len(e.IdentityPub) != 33 || len(e.IdentitySig) != 64 || e.Version == 0 {
			return ErrBadPayload
		}
	case pb.RecordType_ACK:
		var a pb.Ack
		if err := proto.Unmarshal(b.Payload, &a); err != nil || len(a.EnvelopeIds) == 0 {
			return ErrBadPayload
		}
	}
	return nil
}
```

Note: "directory entry key takeover" expects `ErrBadAuthor` because `user_id ≠ ID16(account_pub)` is caught first; `ErrKeyMismatch` stays reachable only for ID16 collisions and is kept as defence in depth.

- [ ] **Step 4: Run** `go test ./internal/records/ -v` → PASS (all subtests).
- [ ] **Step 5: Commit** `git add -A && git commit -m "feat(records): sign and validate signed records"`

---

### Task 4: `internal/store` — SQLite, migrations, group-commit Apply

**Goal:** Durable, idempotent record storage with an oplog, per `docs/06` §SQLite.

**Files:**
- Create: `internal/store/store.go`, `apply.go`, `migrate.go`, `migrations/0001_init.sql`
- Test: `internal/store/store_test.go`

**Acceptance Criteria:**
- [ ] `Open` sets WAL, `synchronous=NORMAL`, `busy_timeout=5000`, `foreign_keys=ON`; runs embedded migrations once (`schema_migrations`)
- [ ] `Apply(ctx, rec, body)` stores raw record + oplog row atomically; second Apply of same `author‖id` returns `applied=false` and the original seq
- [ ] All Apply calls go through one writer goroutine that batches ≤256 requests or 10 ms per transaction
- [ ] `Since(ctx, cursor, limit)` returns entries with `seq > cursor` in order; `Get(ctx, key)` returns raw record
- [ ] 1000 concurrent Applies complete with 1000 distinct seqs; reopen keeps data

**Verify:** `go test -race ./internal/store/ -v` → PASS

**Steps:**

- [ ] **Step 1: Migration** `migrations/0001_init.sql` — schema from `docs/06-node-architecture.md`, with
`record_key` (32 bytes) as the record identity:

```sql
CREATE TABLE oplog(seq INTEGER PRIMARY KEY AUTOINCREMENT, record_key BLOB UNIQUE NOT NULL,
                   type INTEGER NOT NULL, received_ms INTEGER NOT NULL);
CREATE TABLE records(record_key BLOB PRIMARY KEY, type INTEGER NOT NULL, author BLOB NOT NULL,
                     created_ms INTEGER NOT NULL, expires_ms INTEGER NOT NULL, raw BLOB NOT NULL);
CREATE INDEX records_type ON records(type);
CREATE TABLE mailbox(user_id BLOB, device_id INTEGER, record_key BLOB, origin_node BLOB,
                     received_ms INTEGER, PRIMARY KEY(user_id, device_id, record_key));
CREATE TABLE tombstones(record_key BLOB PRIMARY KEY, until_ms INTEGER NOT NULL);
CREATE TABLE users(user_id BLOB PRIMARY KEY, username TEXT UNIQUE NOT NULL, account_pub BLOB NOT NULL,
                   entry_key BLOB NOT NULL, version INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0,
                   can_invite INTEGER NOT NULL DEFAULT 1, created_ms INTEGER NOT NULL);
CREATE TABLE invites(invite_id BLOB PRIMARY KEY, inviter BLOB NOT NULL, expires_ms INTEGER NOT NULL, used_by BLOB);
CREATE TABLE prekeys(user_id BLOB, device_id INTEGER, key_id INTEGER, kind INTEGER,
                     owner_node BLOB, public BLOB, consumed INTEGER NOT NULL DEFAULT 0,
                     PRIMARY KEY(user_id, device_id, kind, key_id));
CREATE TABLE blobs(blob_id BLOB PRIMARY KEY, owner BLOB, size INTEGER, chunks INTEGER, sha256 BLOB,
                   present_chunks BLOB, expires_ms INTEGER, kind INTEGER);
CREATE TABLE blob_readers(blob_id BLOB, user_id BLOB, fetched INTEGER NOT NULL DEFAULT 0,
                          PRIMARY KEY(blob_id, user_id));
CREATE TABLE backups(user_id BLOB PRIMARY KEY, meta_key BLOB, version INTEGER);
CREATE TABLE auth_failures(username TEXT, at_ms INTEGER);
CREATE TABLE push_tokens(user_id BLOB, device_id INTEGER, kind INTEGER, token TEXT,
                         PRIMARY KEY(user_id, device_id));
CREATE TABLE peers(node_id BLOB PRIMARY KEY, cursor INTEGER NOT NULL DEFAULT 0, last_seen_ms INTEGER);
CREATE TABLE manifest(version INTEGER PRIMARY KEY, raw BLOB NOT NULL);
```

- [ ] **Step 2: Failing tests** (`store_test.go`)

```go
package store

import (
	"bytes"
	"context"
	"crypto/rand"
	"path/filepath"
	"sync"
	"testing"

	pb "ottermsg/server/internal/proto/otterv1"
)

func rec(t *testing.T) (*pb.Record, *pb.RecordBody) {
	id, author := make([]byte, 16), make([]byte, 16)
	rand.Read(id); rand.Read(author)
	b := &pb.RecordBody{Id: id, Author: author, Type: pb.RecordType_ACK, CreatedMs: 1}
	raw := append([]byte{0xAA}, id...)
	return &pb.Record{Body: raw, Signature: make([]byte, 64)}, b
}

func open(t *testing.T) (*Store, string) {
	p := filepath.Join(t.TempDir(), "node.db")
	s, err := Open(p)
	if err != nil { t.Fatal(err) }
	t.Cleanup(func() { s.Close() })
	return s, p
}

func TestApplyIdempotent(t *testing.T) {
	s, _ := open(t)
	ctx := context.Background()
	r, b := rec(t)
	seq1, applied, err := s.Apply(ctx, r, b)
	if err != nil || !applied || seq1 != 1 { t.Fatalf("first apply: %d %v %v", seq1, applied, err) }
	seq2, applied, err := s.Apply(ctx, r, b)
	if err != nil || applied || seq2 != seq1 { t.Fatalf("second apply: %d %v %v", seq2, applied, err) }
}

func TestSinceAndGet(t *testing.T) {
	s, _ := open(t)
	ctx := context.Background()
	var keys [][]byte
	for i := 0; i < 5; i++ {
		r, b := rec(t)
		if _, _, err := s.Apply(ctx, r, b); err != nil { t.Fatal(err) }
		keys = append(keys, append(append([]byte{}, b.Author...), b.Id...))
	}
	got, err := s.Since(ctx, 2, 10)
	if err != nil || len(got) != 3 || got[0].Seq != 3 || got[2].Seq != 5 { t.Fatalf("since: %+v %v", got, err) }
	raw, err := s.Get(ctx, keys[0])
	if err != nil || raw[0] != 0xAA { t.Fatalf("get: %x %v", raw, err) }
	if _, err := s.Get(ctx, make([]byte, 32)); err != ErrNotFound { t.Fatalf("want ErrNotFound, got %v", err) }
}

func TestConcurrentApply(t *testing.T) {
	s, _ := open(t)
	ctx := context.Background()
	var wg sync.WaitGroup
	seqs := make(chan int64, 1000)
	for i := 0; i < 1000; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r, b := rec(t)
			seq, _, err := s.Apply(ctx, r, b)
			if err != nil { t.Error(err); return }
			seqs <- seq
		}()
	}
	wg.Wait(); close(seqs)
	seen := map[int64]bool{}
	for q := range seqs { if seen[q] { t.Fatalf("dup seq %d", q) }; seen[q] = true }
	if len(seen) != 1000 { t.Fatalf("got %d seqs", len(seen)) }
}

func TestReopen(t *testing.T) {
	s, p := open(t)
	r, b := rec(t)
	if _, _, err := s.Apply(context.Background(), r, b); err != nil { t.Fatal(err) }
	s.Close()
	s2, err := Open(p)
	if err != nil { t.Fatal(err) }
	defer s2.Close()
	got, _ := s2.Since(context.Background(), 0, 10)
	if len(got) != 1 || !bytes.Equal(got[0].Raw, mustRaw(r)) { t.Fatalf("after reopen: %+v", got) }
}
```
`mustRaw(r)` = `proto.Marshal(r)` helper — the store keeps the full serialized `Record` (body+signature) as `raw`, and `Since`/`Get` return it. Add to test file:
```go
func mustRaw(r *pb.Record) []byte { b, _ := proto.Marshal(r); return b }
```
(import `google.golang.org/protobuf/proto`; in `TestSinceAndGet` compare by unmarshalling: replace `raw[0] != 0xAA` with `var got pb.Record; proto.Unmarshal(raw, &got); got.Body[0] != 0xAA`).

- [ ] **Step 3: Run** → FAIL.

- [ ] **Step 4: Implement**

`store.go`:
```go
// Package store is the only package that touches SQL.
package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	_ "modernc.org/sqlite"
)

var ErrNotFound = errors.New("not found")

type Store struct {
	r      *sql.DB // readers
	w      *sql.DB // single writer connection
	reqs   chan *applyReq
	done   chan struct{}
	stopped chan struct{}
	now    func() time.Time
}

func dsn(path string) string {
	return fmt.Sprintf("file:%s?_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(ON)", path)
}

func Open(path string) (*Store, error) {
	w, err := sql.Open("sqlite", dsn(path))
	if err != nil { return nil, err }
	w.SetMaxOpenConns(1)
	if err := migrate(context.Background(), w); err != nil { w.Close(); return nil, err }
	r, err := sql.Open("sqlite", dsn(path))
	if err != nil { w.Close(); return nil, err }
	r.SetMaxOpenConns(8)
	s := &Store{r: r, w: w, reqs: make(chan *applyReq, 1024), done: make(chan struct{}), stopped: make(chan struct{}), now: time.Now}
	go s.writer()
	return s, nil
}

func (s *Store) Close() error {
	select {
	case <-s.done:
		return nil
	default:
	}
	close(s.done)
	<-s.stopped
	return errors.Join(s.r.Close(), s.w.Close())
}
```

`migrate.go`:
```go
package store

import (
	"context"
	"database/sql"
	"embed"
	"fmt"
	"sort"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

func migrate(ctx context.Context, db *sql.DB) error {
	if _, err := db.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations(name TEXT PRIMARY KEY)`); err != nil {
		return err
	}
	entries, err := migrationsFS.ReadDir("migrations")
	if err != nil { return err }
	names := make([]string, 0, len(entries))
	for _, e := range entries { names = append(names, e.Name()) }
	sort.Strings(names)
	for _, n := range names {
		var x string
		err := db.QueryRowContext(ctx, `SELECT name FROM schema_migrations WHERE name=?`, n).Scan(&x)
		if err == nil { continue }
		if err != sql.ErrNoRows { return err }
		body, _ := migrationsFS.ReadFile("migrations/" + n)
		tx, err := db.BeginTx(ctx, nil)
		if err != nil { return err }
		if _, err := tx.ExecContext(ctx, string(body)); err != nil { tx.Rollback(); return fmt.Errorf("migration %s: %w", n, err) }
		if _, err := tx.ExecContext(ctx, `INSERT INTO schema_migrations(name) VALUES(?)`, n); err != nil { tx.Rollback(); return err }
		if err := tx.Commit(); err != nil { return err }
	}
	return nil
}
```

`apply.go`:
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

type applyReq struct {
	key  []byte
	raw  []byte
	body *pb.RecordBody
	res  chan applyRes
}

type applyRes struct {
	seq     int64
	applied bool
	err     error
}

type LogEntry struct {
	Seq int64
	Raw []byte // serialized pb.Record
}

// Apply stores a validated record. Idempotent by author||id.
func (s *Store) Apply(ctx context.Context, rec *pb.Record, body *pb.RecordBody) (int64, bool, error) {
	key, err := keys.RecordKey(body.Author, body.Id)
	if err != nil { return 0, false, err }
	raw, err := proto.Marshal(rec)
	if err != nil { return 0, false, err }
	req := &applyReq{key: key, raw: raw, body: body, res: make(chan applyRes, 1)}
	select {
	case s.reqs <- req:
	case <-s.done:
		return 0, false, errors.New("store closed")
	case <-ctx.Done():
		return 0, false, ctx.Err()
	}
	select {
	case r := <-req.res:
		return r.seq, r.applied, r.err
	case <-ctx.Done():
		return 0, false, ctx.Err()
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
			results[i] = applyOne(ctx, tx, r, now)
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

func applyOne(ctx context.Context, tx *sql.Tx, r *applyReq, now int64) applyRes {
	var seq int64
	err := tx.QueryRowContext(ctx, `SELECT seq FROM oplog WHERE record_key=?`, r.key).Scan(&seq)
	if err == nil {
		return applyRes{seq: seq, applied: false}
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return applyRes{err: err}
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO records(record_key,type,author,created_ms,expires_ms,raw) VALUES(?,?,?,?,?,?)`,
		r.key, int32(r.body.Type), r.body.Author, r.body.CreatedMs, r.body.ExpiresMs, r.raw); err != nil {
		return applyRes{err: err}
	}
	res, err := tx.ExecContext(ctx, `INSERT INTO oplog(record_key,type,received_ms) VALUES(?,?,?)`, r.key, int32(r.body.Type), now)
	if err != nil {
		return applyRes{err: err}
	}
	seq, _ = res.LastInsertId()
	return applyRes{seq: seq, applied: true}
}

// Since returns log entries with seq > cursor, oldest first.
func (s *Store) Since(ctx context.Context, cursor int64, limit int) ([]LogEntry, error) {
	rows, err := s.r.QueryContext(ctx,
		`SELECT o.seq, r.raw FROM oplog o JOIN records r ON r.record_key=o.record_key WHERE o.seq>? ORDER BY o.seq LIMIT ?`,
		cursor, limit)
	if err != nil { return nil, err }
	defer rows.Close()
	var out []LogEntry
	for rows.Next() {
		var e LogEntry
		if err := rows.Scan(&e.Seq, &e.Raw); err != nil { return nil, err }
		out = append(out, e)
	}
	return out, rows.Err()
}

// Get returns the serialized record stored under key (author||id).
func (s *Store) Get(ctx context.Context, key []byte) ([]byte, error) {
	var raw []byte
	err := s.r.QueryRowContext(ctx, `SELECT raw FROM records WHERE record_key=?`, key).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) { return nil, ErrNotFound }
	return raw, err
}
```
Then `go get modernc.org/sqlite@v1.62.0 && go mod tidy`.

Note: a failing record inside a batch (e.g. constraint error) is reported per-request; a failed **commit** fails the whole batch — callers retry. Type-specific appliers (users, mailbox, …) hook into `applyOne` in M1.

- [ ] **Step 5: Run** `go test -race ./internal/store/ -v` → PASS.
- [ ] **Step 6: Commit** `git add -A && git commit -m "feat(store): sqlite store with migrations and group-commit apply"`

---

### Task 5: `internal/admin` + `cmd/otter-admin` — network init, nodes, manifest

**Goal:** Admin can create a network, add/remove nodes, sign and inspect the manifest.

**Files:**
- Create: `internal/admin/state.go`, `internal/admin/manifest.go`, `cmd/otter-admin/main.go`
- Test: `internal/admin/admin_test.go`, `cmd/otter-admin/main_test.go`

**Acceptance Criteria:**
- [ ] Admin dir layout: `network.key.enc`, `network.json` (`{"network_pub":hex,"vless_uuid":uuid}`), `nodes.json` (protojson list of `NodeInfo`), `nodes/<label>/node.key` (0600), `manifest.bin`, `manifest_version`
- [ ] `network init` refuses to overwrite an existing network
- [ ] `node add --label L --wss-host H [--wss-port 443] [--wss-path P] [--cdn] [--push]` generates node key; random 32-char path when omitted; duplicate label rejected; label `^[a-z0-9-]{1,32}$`
- [ ] `manifest sign` bumps version (starts at 1), writes signed `MANIFEST` record; the record passes `records.Validator`
- [ ] `manifest show [--file F]` verifies signature against `network.json` and prints protojson
- [ ] Passphrase from `OTTER_ADMIN_PASSPHRASE` env, else interactive prompt (twice on init); min 12 chars on init

**Verify:** `go test ./internal/admin/ ./cmd/otter-admin/ -v` → PASS; manual: `go run ./cmd/otter-admin --dir /tmp/x network init` etc.

**Steps:**

- [ ] **Step 1: Failing test** (`internal/admin/admin_test.go`)

```go
package admin

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"
	"ottermsg/server/internal/records"
	pb "ottermsg/server/internal/proto/otterv1"
)

var pass = []byte("a very long passphrase")

func TestFullFlow(t *testing.T) {
	dir := t.TempDir()
	if err := InitNetwork(dir, pass); err != nil { t.Fatal(err) }
	if err := InitNetwork(dir, pass); !errors.Is(err, ErrExists) { t.Fatalf("want ErrExists, got %v", err) }

	if _, err := AddNode(dir, NodeSpec{Label: "fi-1", WSSHost: "chat.example.org", WSSPort: 443}); err != nil { t.Fatal(err) }
	if _, err := AddNode(dir, NodeSpec{Label: "fi-1", WSSHost: "x"}); !errors.Is(err, ErrExists) { t.Fatalf("dup label: %v", err) }
	if _, err := AddNode(dir, NodeSpec{Label: "Bad Label", WSSHost: "x"}); err == nil { t.Fatal("bad label accepted") }
	if _, err := os.Stat(filepath.Join(dir, "nodes", "fi-1", "node.key")); err != nil { t.Fatal(err) }

	rec, err := SignManifest(dir, pass, time.UnixMilli(1000))
	if err != nil { t.Fatal(err) }
	st, _ := LoadState(dir)
	v := &records.Validator{NetworkPub: st.NetworkPub, Users: noUsers{}, Now: time.Now}
	body, err := v.Validate(rec)
	if err != nil { t.Fatalf("manifest invalid: %v", err) }
	var m pb.Manifest
	proto.Unmarshal(body.Payload, &m)
	if m.Version != 1 || len(m.Nodes) != 1 || m.Nodes[0].Endpoints[0].Path == "" { t.Fatalf("manifest: %v", &m) }

	rec2, _ := SignManifest(dir, pass, time.UnixMilli(2000))
	body2, _ := v.Validate(rec2)
	var m2 pb.Manifest
	proto.Unmarshal(body2.Payload, &m2)
	if m2.Version != 2 { t.Fatalf("version %d", m2.Version) }

	if err := RemoveNode(dir, "fi-1"); err != nil { t.Fatal(err) }
	if _, err := SignManifest(dir, []byte("wrong passphrase!!"), time.Now()); err == nil { t.Fatal("wrong passphrase accepted") }
}

type noUsers struct{}

func (noUsers) UserKey([]byte) (records.UserKey, bool) { return records.UserKey{}, false }
```

- [ ] **Step 2: Run** → FAIL.

- [ ] **Step 3: Implement `state.go`**

```go
// Package admin implements the network admin's local state and operations.
package admin

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"

	"google.golang.org/protobuf/encoding/protojson"
	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
)

var (
	ErrExists   = errors.New("already exists")
	ErrNotFound = errors.New("not found")
	labelRe     = regexp.MustCompile(`^[a-z0-9-]{1,32}$`)
)

type State struct {
	Dir        string
	NetworkPub ed25519.PublicKey
	VlessUUID  string
	Nodes      []*pb.NodeInfo
}

type networkJSON struct {
	NetworkPub string `json:"network_pub"`
	VlessUUID  string `json:"vless_uuid"`
}

type nodesJSON struct {
	Nodes []json.RawMessage `json:"nodes"`
}

func newUUID() string {
	b := make([]byte, 16)
	rand.Read(b)
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func randPath() string {
	const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	b := make([]byte, 32)
	rand.Read(b)
	for i := range b { b[i] = alphabet[int(b[i])%len(alphabet)] }
	return "/" + string(b)
}

func InitNetwork(dir string, pass []byte) error {
	if _, err := os.Stat(filepath.Join(dir, "network.json")); err == nil {
		return fmt.Errorf("network in %s: %w", dir, ErrExists)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil { return err }
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil { return err }
	if err := keys.WriteEncryptedKey(filepath.Join(dir, "network.key.enc"), priv, pass); err != nil { return err }
	nj, _ := json.MarshalIndent(networkJSON{NetworkPub: hex.EncodeToString(pub), VlessUUID: newUUID()}, "", "  ")
	if err := os.WriteFile(filepath.Join(dir, "network.json"), nj, 0o644); err != nil { return err }
	return saveNodes(dir, nil)
}

func LoadState(dir string) (*State, error) {
	b, err := os.ReadFile(filepath.Join(dir, "network.json"))
	if err != nil { return nil, fmt.Errorf("no network in %s (run 'network init'): %w", dir, err) }
	var nj networkJSON
	if err := json.Unmarshal(b, &nj); err != nil { return nil, err }
	pub, err := hex.DecodeString(nj.NetworkPub)
	if err != nil || len(pub) != ed25519.PublicKeySize { return nil, errors.New("network.json: bad network_pub") }
	st := &State{Dir: dir, NetworkPub: pub, VlessUUID: nj.VlessUUID}
	nb, err := os.ReadFile(filepath.Join(dir, "nodes.json"))
	if err != nil { return nil, err }
	var nodes nodesJSON
	if err := json.Unmarshal(nb, &nodes); err != nil { return nil, err }
	for _, raw := range nodes.Nodes {
		n := &pb.NodeInfo{}
		if err := protojson.Unmarshal(raw, n); err != nil { return nil, err }
		st.Nodes = append(st.Nodes, n)
	}
	return st, nil
}

func saveNodes(dir string, nodes []*pb.NodeInfo) error {
	out := nodesJSON{Nodes: []json.RawMessage{}}
	for _, n := range nodes {
		b, err := protojson.Marshal(n)
		if err != nil { return err }
		out.Nodes = append(out.Nodes, b)
	}
	b, _ := json.MarshalIndent(out, "", "  ")
	return os.WriteFile(filepath.Join(dir, "nodes.json"), b, 0o644)
}

type NodeSpec struct {
	Label   string
	WSSHost string
	WSSPort uint32
	WSSPath string
	CDN     bool
	Push    bool
}

func AddNode(dir string, s NodeSpec) (*pb.NodeInfo, error) {
	if !labelRe.MatchString(s.Label) { return nil, fmt.Errorf("label %q: must match %s", s.Label, labelRe) }
	if s.WSSHost == "" { return nil, errors.New("wss host required") }
	st, err := LoadState(dir)
	if err != nil { return nil, err }
	for _, n := range st.Nodes {
		if n.Label == s.Label { return nil, fmt.Errorf("node %s: %w", s.Label, ErrExists) }
	}
	if s.WSSPort == 0 { s.WSSPort = 443 }
	if s.WSSPath == "" { s.WSSPath = randPath() }
	nodeDir := filepath.Join(dir, "nodes", s.Label)
	if err := os.MkdirAll(nodeDir, 0o700); err != nil { return nil, err }
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil { return nil, err }
	if err := keys.WritePlainKey(filepath.Join(nodeDir, "node.key"), priv); err != nil { return nil, err }
	n := &pb.NodeInfo{NodeId: keys.ID16(pub), NodePub: pub, Label: s.Label, PushCapable: s.Push,
		Endpoints: []*pb.Endpoint{{Kind: pb.Endpoint_WSS, Host: s.WSSHost, Port: s.WSSPort, Path: s.WSSPath, ViaCdn: s.CDN}}}
	return n, saveNodes(dir, append(st.Nodes, n))
}

func RemoveNode(dir, label string) error {
	st, err := LoadState(dir)
	if err != nil { return err }
	kept := st.Nodes[:0]
	found := false
	for _, n := range st.Nodes {
		if n.Label == label { found = true; continue }
		kept = append(kept, n)
	}
	if !found { return fmt.Errorf("node %s: %w", label, ErrNotFound) }
	return saveNodes(dir, kept)
}
```

- [ ] **Step 4: Implement `manifest.go`**

```go
package admin

import (
	"crypto/rand"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"google.golang.org/protobuf/proto"
	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/records"
)

func readVersion(dir string) uint64 {
	b, err := os.ReadFile(filepath.Join(dir, "manifest_version"))
	if err != nil { return 0 }
	v, _ := strconv.ParseUint(strings.TrimSpace(string(b)), 10, 64)
	return v
}

// SignManifest builds a manifest from nodes.json with version+1, signs it with the network
// key and writes manifest.bin (a serialized pb.Record).
func SignManifest(dir string, pass []byte, now time.Time) (*pb.Record, error) {
	st, err := LoadState(dir)
	if err != nil { return nil, err }
	priv, err := keys.ReadEncryptedKey(filepath.Join(dir, "network.key.enc"), pass)
	if err != nil { return nil, err }
	version := readVersion(dir) + 1
	m := &pb.Manifest{Version: version, IssuedMs: now.UnixMilli(), NetworkPub: st.NetworkPub, Nodes: st.Nodes}
	payload, err := proto.MarshalOptions{Deterministic: true}.Marshal(m)
	if err != nil { return nil, err }
	id := make([]byte, 16)
	rand.Read(id)
	rec, err := records.Sign(&pb.RecordBody{Id: id, Type: pb.RecordType_MANIFEST, Author: keys.ID16(st.NetworkPub),
		CreatedMs: now.UnixMilli(), Payload: payload}, priv)
	if err != nil { return nil, err }
	raw, _ := proto.Marshal(rec)
	if err := os.WriteFile(filepath.Join(dir, "manifest.bin"), raw, 0o644); err != nil { return nil, err }
	if err := os.WriteFile(filepath.Join(dir, "manifest_version"), []byte(fmt.Sprintf("%d\n", version)), 0o644); err != nil { return nil, err }
	return rec, nil
}
```

- [ ] **Step 5: CLI `cmd/otter-admin/main.go`**

```go
// Command otter-admin manages an OtterMSG network: keys, nodes and the signed manifest.
package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/term"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	"ottermsg/server/internal/admin"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/records"
)

const usage = `usage: otter-admin [--dir DIR] <command>
  network init
  node add --label L --wss-host H [--wss-port 443] [--wss-path /p] [--cdn] [--push]
  node list
  node remove --label L
  manifest sign
  manifest show [--file F]`

func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stdin); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func passphrase(in io.Reader, confirm bool) ([]byte, error) {
	if p := os.Getenv("OTTER_ADMIN_PASSPHRASE"); p != "" {
		return []byte(p), nil
	}
	read := func(prompt string) ([]byte, error) {
		fmt.Fprint(os.Stderr, prompt)
		if f, ok := in.(*os.File); ok && term.IsTerminal(int(f.Fd())) {
			b, err := term.ReadPassword(int(f.Fd()))
			fmt.Fprintln(os.Stderr)
			return b, err
		}
		line, err := bufio.NewReader(in).ReadString('\n')
		return []byte(strings.TrimRight(line, "\r\n")), err
	}
	p, err := read("Admin key passphrase: ")
	if err != nil { return nil, err }
	if confirm {
		if len(p) < 12 { return nil, errors.New("passphrase must be at least 12 characters") }
		p2, err := read("Repeat passphrase: ")
		if err != nil { return nil, err }
		if string(p) != string(p2) { return nil, errors.New("passphrases differ") }
	}
	return p, nil
}

func run(args []string, out io.Writer, in io.Reader) error {
	root := flag.NewFlagSet("otter-admin", flag.ContinueOnError)
	dir := root.String("dir", defaultDir(), "admin state directory")
	if err := root.Parse(args); err != nil { return err }
	a := root.Args()
	if len(a) < 2 { return errors.New(usage) }
	switch a[0] + " " + a[1] {
	case "network init":
		p, err := passphrase(in, true)
		if err != nil { return err }
		if err := admin.InitNetwork(*dir, p); err != nil { return err }
		st, _ := admin.LoadState(*dir)
		fmt.Fprintf(out, "network created in %s\nnetwork_pub %x\nKeep a backup of network.key.enc and its passphrase.\n", *dir, st.NetworkPub)
	case "node add":
		fs := flag.NewFlagSet("node add", flag.ContinueOnError)
		var s admin.NodeSpec
		var port uint
		fs.StringVar(&s.Label, "label", "", "node label")
		fs.StringVar(&s.WSSHost, "wss-host", "", "WSS host")
		fs.UintVar(&port, "wss-port", 443, "WSS port")
		fs.StringVar(&s.WSSPath, "wss-path", "", "secret WebSocket path (random if empty)")
		fs.BoolVar(&s.CDN, "cdn", false, "endpoint is behind a CDN")
		fs.BoolVar(&s.Push, "push", false, "node can send FCM pushes")
		if err := fs.Parse(a[2:]); err != nil { return err }
		s.WSSPort = uint32(port)
		n, err := admin.AddNode(*dir, s)
		if err != nil { return err }
		fmt.Fprintf(out, "node %s added, node_id %x\nkey: %s\nRun 'manifest sign' to publish.\n", n.Label, n.NodeId, filepath.Join(*dir, "nodes", n.Label, "node.key"))
	case "node list":
		st, err := admin.LoadState(*dir)
		if err != nil { return err }
		for _, n := range st.Nodes {
			for _, e := range n.Endpoints {
				fmt.Fprintf(out, "%-12s %x  %s %s:%d%s cdn=%v\n", n.Label, n.NodeId, e.Kind, e.Host, e.Port, e.Path, e.ViaCdn)
			}
		}
	case "node remove":
		fs := flag.NewFlagSet("node remove", flag.ContinueOnError)
		label := fs.String("label", "", "node label")
		if err := fs.Parse(a[2:]); err != nil { return err }
		if err := admin.RemoveNode(*dir, *label); err != nil { return err }
		fmt.Fprintf(out, "node %s removed. Run 'manifest sign' to publish.\n", *label)
	case "manifest sign":
		p, err := passphrase(in, false)
		if err != nil { return err }
		rec, err := admin.SignManifest(*dir, p, time.Now())
		if err != nil { return err }
		return show(out, *dir, rec)
	case "manifest show":
		fs := flag.NewFlagSet("manifest show", flag.ContinueOnError)
		file := fs.String("file", "", "manifest file (default DIR/manifest.bin)")
		if err := fs.Parse(a[2:]); err != nil { return err }
		if *file == "" { *file = filepath.Join(*dir, "manifest.bin") }
		raw, err := os.ReadFile(*file)
		if err != nil { return err }
		var rec pb.Record
		if err := proto.Unmarshal(raw, &rec); err != nil { return err }
		return show(out, *dir, &rec)
	default:
		return errors.New(usage)
	}
	return nil
}

func show(out io.Writer, dir string, rec *pb.Record) error {
	st, err := admin.LoadState(dir)
	if err != nil { return err }
	v := &records.Validator{NetworkPub: st.NetworkPub, Users: noUsers{}, Now: time.Now}
	body, err := v.Validate(rec)
	if err != nil { return fmt.Errorf("manifest does not verify: %w", err) }
	var m pb.Manifest
	if err := proto.Unmarshal(body.Payload, &m); err != nil { return err }
	b, _ := protojson.MarshalOptions{Multiline: true}.Marshal(&m)
	fmt.Fprintf(out, "signature OK\n%s\n", b)
	return nil
}

type noUsers struct{}

func (noUsers) UserKey([]byte) (records.UserKey, bool) { return records.UserKey{}, false }

func defaultDir() string {
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".otter-admin")
}
```

`cmd/otter-admin/main_test.go`:
```go
package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestCLIFlow(t *testing.T) {
	t.Setenv("OTTER_ADMIN_PASSPHRASE", "a very long passphrase")
	dir := t.TempDir()
	steps := [][]string{
		{"--dir", dir, "network", "init"},
		{"--dir", dir, "node", "add", "--label", "fi-1", "--wss-host", "chat.example.org"},
		{"--dir", dir, "manifest", "sign"},
		{"--dir", dir, "manifest", "show"},
	}
	var out bytes.Buffer
	for _, s := range steps {
		if err := run(s, &out, strings.NewReader("")); err != nil { t.Fatalf("%v: %v", s, err) }
	}
	if !strings.Contains(out.String(), "signature OK") || !strings.Contains(out.String(), "chat.example.org") {
		t.Fatalf("output: %s", out.String())
	}
}
```
Then `go get golang.org/x/term@v0.48.0 && go mod tidy`.

- [ ] **Step 6: Run** `go test ./internal/admin/ ./cmd/otter-admin/ -v` → PASS. `make check` → PASS.
- [ ] **Step 7: Commit** `git add -A && git commit -m "feat(admin): otter-admin network init, nodes, manifest sign/show"`

---

### Task 6: Cross-language test vectors

**Goal:** Deterministic vectors that the Android side must reproduce/verify.

**Files:**
- Create: `internal/vectors/vectors_test.go`, `testdata/vectors/v1.json`

**Acceptance Criteria:**
- [ ] `OTTER_WRITE_VECTORS=1 go test ./internal/vectors/` writes `testdata/vectors/v1.json`
- [ ] Without the env var, the test regenerates in memory and fails if the file differs (detects accidental derivation changes)
- [ ] Vector contents: `seed_hex`, `account_pub_hex`, `user_id_hex`, `network_seed_hex`, `network_pub_hex`, `network_id_hex`, `manifest_record_hex`, `manifest_version`, `directory_entry_record_hex`, `bad_signature_record_hex`

**Verify:** `go test ./internal/vectors/ -v` → PASS

**Steps:**

- [ ] **Step 1: Write** `internal/vectors/vectors_test.go`

```go
// Package vectors produces cross-language test vectors (consumed by otter-android).
package vectors

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"google.golang.org/protobuf/proto"
	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/records"
)

type V1 struct {
	SeedHex                 string `json:"seed_hex"`
	AccountPubHex           string `json:"account_pub_hex"`
	UserIDHex               string `json:"user_id_hex"`
	NetworkSeedHex          string `json:"network_seed_hex"`
	NetworkPubHex           string `json:"network_pub_hex"`
	NetworkIDHex            string `json:"network_id_hex"`
	ManifestVersion         uint64 `json:"manifest_version"`
	ManifestRecordHex       string `json:"manifest_record_hex"`
	DirectoryEntryRecordHex string `json:"directory_entry_record_hex"`
	BadSignatureRecordHex   string `json:"bad_signature_record_hex"`
}

func seq(n int, start byte) []byte { b := make([]byte, n); for i := range b { b[i] = start + byte(i) }; return b }

func generate(t *testing.T) []byte {
	seed := seq(32, 0)
	acc, err := keys.DeriveAccountKey(seed)
	if err != nil { t.Fatal(err) }
	accPub := acc.Public().(ed25519.PublicKey)
	netPriv := ed25519.NewKeyFromSeed(seq(32, 100))
	netPub := netPriv.Public().(ed25519.PublicKey)

	m := &pb.Manifest{Version: 7, IssuedMs: 1_800_000_000_000, NetworkPub: netPub, Nodes: []*pb.NodeInfo{{
		NodeId: keys.ID16(seq(32, 200)), NodePub: seq(32, 200), Label: "fi-1",
		Endpoints: []*pb.Endpoint{{Kind: pb.Endpoint_WSS, Host: "chat.example.org", Port: 443, Path: "/abc"}}}}}
	mp, _ := proto.MarshalOptions{Deterministic: true}.Marshal(m)
	mrec, _ := records.Sign(&pb.RecordBody{Id: seq(16, 1), Type: pb.RecordType_MANIFEST, Author: keys.ID16(netPub), CreatedMs: 1_800_000_000_000, Payload: mp}, netPriv)

	e := &pb.DirectoryEntry{UserId: keys.ID16(accPub), Username: "mama", DisplayName: "Мама", AccountPub: accPub,
		IdentityPub: append([]byte{5}, seq(32, 50)...), IdentitySig: seq(64, 0), Version: 1, CanInvite: true}
	ep, _ := proto.MarshalOptions{Deterministic: true}.Marshal(e)
	drec, _ := records.Sign(&pb.RecordBody{Id: seq(16, 2), Type: pb.RecordType_DIRECTORY_ENTRY, Author: keys.ID16(accPub), CreatedMs: 1_800_000_000_000, Payload: ep}, acc)

	bad := proto.Clone(mrec).(*pb.Record)
	bad.Signature = append([]byte(nil), bad.Signature...)
	bad.Signature[0] ^= 0xFF

	enc := func(r *pb.Record) string { b, _ := proto.Marshal(r); return hex.EncodeToString(b) }
	v := V1{
		SeedHex: hex.EncodeToString(seed), AccountPubHex: hex.EncodeToString(accPub), UserIDHex: hex.EncodeToString(keys.ID16(accPub)),
		NetworkSeedHex: hex.EncodeToString(seq(32, 100)), NetworkPubHex: hex.EncodeToString(netPub), NetworkIDHex: hex.EncodeToString(keys.ID16(netPub)),
		ManifestVersion: 7, ManifestRecordHex: enc(mrec), DirectoryEntryRecordHex: enc(drec), BadSignatureRecordHex: enc(bad),
	}
	out, _ := json.MarshalIndent(v, "", "  ")
	return append(out, '\n')
}

func TestVectorsV1(t *testing.T) {
	path := filepath.Join("..", "..", "testdata", "vectors", "v1.json")
	got := generate(t)
	if os.Getenv("OTTER_WRITE_VECTORS") == "1" {
		os.MkdirAll(filepath.Dir(path), 0o755)
		if err := os.WriteFile(path, got, 0o644); err != nil { t.Fatal(err) }
		return
	}
	want, err := os.ReadFile(path)
	if err != nil { t.Fatalf("missing vectors (run with OTTER_WRITE_VECTORS=1): %v", err) }
	if !bytes.Equal(got, want) { t.Fatal("vectors changed: derivation or encoding drifted; regenerate only if intentional") }
}
```

- [ ] **Step 2: Generate** `OTTER_WRITE_VECTORS=1 go test ./internal/vectors/` then `go test ./internal/vectors/ -v` → PASS. `make check` → PASS.
- [ ] **Step 3: Commit** `git add -A && git commit -m "test: cross-language vectors v1"`

---

## Part B — `otter-android`

All Gradle commands run as:
`cd otter-android && JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 ./gradlew <tasks>`

### Task 7: Android repo scaffold (Gradle wrapper, modules, app shell builds)

**Goal:** Multi-module project that assembles a debug APK and runs (empty) unit tests.

**Files:**
- Create: `otter-android/settings.gradle.kts`, `build.gradle.kts`, `gradle.properties`, `gradle/libs.versions.toml`, `.gitignore`, `README.md`, `local.properties`
- Create: wrapper (`gradlew`, `gradlew.bat`, `gradle/wrapper/gradle-wrapper.{jar,properties}`)
- Create: `core/proto/build.gradle.kts`, `core/crypto/build.gradle.kts`, `core/database/build.gradle.kts`, `core/ui/build.gradle.kts`, `app/build.gradle.kts`
- Create: `app/src/main/AndroidManifest.xml`, `app/src/main/java/app/ottermsg/OtterApp.kt`, `MainActivity.kt`, `app/src/main/res/values/strings.xml` (ru), `values-en/strings.xml`, `app/proguard-rules.pro`
- Create: `scripts/sync-proto.sh`

**Acceptance Criteria:**
- [ ] Wrapper pinned to Gradle 8.14.3 (with distributionSha256Sum)
- [ ] `./gradlew assembleDebug test` succeeds
- [ ] `scripts/sync-proto.sh` copies `../otter-server/proto/otter/v1/*.proto` → `core/proto/src/main/proto/otter/v1/` and `../otter-server/testdata/vectors/*.json` → `core/crypto/src/test/resources/vectors/`
- [ ] App label "Otter"; default locale strings Russian, `values-en` English; `applicationId = "app.ottermsg"`; `@HiltAndroidApp` application

**Verify:** `JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 ./gradlew assembleDebug test` → BUILD SUCCESSFUL

**Steps:**

- [ ] **Step 1: Bootstrap wrapper**
```bash
cd /tmp/claude-1000/-home-al-Documents-Projects-OttterMSG/804c241f-09cb-4e57-a773-235e8f324f5b/scratchpad
curl -sSLO https://services.gradle.org/distributions/gradle-8.14.3-bin.zip
curl -sSL https://services.gradle.org/distributions/gradle-8.14.3-bin.zip.sha256   # note value
unzip -q gradle-8.14.3-bin.zip
cd ~/Documents/Projects/OttterMSG/otter-android
JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 <scratchpad>/gradle-8.14.3/bin/gradle wrapper --gradle-version 8.14.3 --gradle-distribution-sha256-sum <sha>
```
(Create an empty `settings.gradle.kts` with `rootProject.name = "otter-android"` first.)

- [ ] **Step 2: `gradle/libs.versions.toml`**

```toml
[versions]
agp = "8.13.2"
kotlin = "2.2.21"
ksp = "2.3.0"
hilt = "2.57.2"
hiltNavigationCompose = "1.3.0"
room = "2.8.3"
sqlite = "2.6.1"
sqlcipher = "4.11.0"
composeBom = "2025.10.01"
coreKtx = "1.17.0"
activityCompose = "1.11.0"
lifecycle = "2.9.4"
navigation = "2.9.5"
tink = "1.19.0"
protobuf = "4.32.1"
protobufPlugin = "0.9.5"
coroutines = "1.10.2"
junit = "4.13.2"
robolectric = "4.16"
androidxTestCore = "1.7.0"

[libraries]
androidx-core-ktx = { module = "androidx.core:core-ktx", version.ref = "coreKtx" }
androidx-activity-compose = { module = "androidx.activity:activity-compose", version.ref = "activityCompose" }
androidx-lifecycle-runtime-compose = { module = "androidx.lifecycle:lifecycle-runtime-compose", version.ref = "lifecycle" }
androidx-lifecycle-viewmodel-compose = { module = "androidx.lifecycle:lifecycle-viewmodel-compose", version.ref = "lifecycle" }
androidx-navigation-compose = { module = "androidx.navigation:navigation-compose", version.ref = "navigation" }
compose-bom = { module = "androidx.compose:compose-bom", version.ref = "composeBom" }
compose-ui = { module = "androidx.compose.ui:ui" }
compose-ui-tooling = { module = "androidx.compose.ui:ui-tooling" }
compose-ui-tooling-preview = { module = "androidx.compose.ui:ui-tooling-preview" }
compose-material3 = { module = "androidx.compose.material3:material3" }
compose-material-icons = { module = "androidx.compose.material:material-icons-extended" }
hilt-android = { module = "com.google.dagger:hilt-android", version.ref = "hilt" }
hilt-compiler = { module = "com.google.dagger:hilt-android-compiler", version.ref = "hilt" }
hilt-navigation-compose = { module = "androidx.hilt:hilt-navigation-compose", version.ref = "hiltNavigationCompose" }
room-runtime = { module = "androidx.room:room-runtime", version.ref = "room" }
room-ktx = { module = "androidx.room:room-ktx", version.ref = "room" }
room-compiler = { module = "androidx.room:room-compiler", version.ref = "room" }
room-testing = { module = "androidx.room:room-testing", version.ref = "room" }
sqlite-ktx = { module = "androidx.sqlite:sqlite-ktx", version.ref = "sqlite" }
sqlcipher = { module = "net.zetetic:sqlcipher-android", version.ref = "sqlcipher" }
tink = { module = "com.google.crypto.tink:tink-android", version.ref = "tink" }
protobuf-javalite = { module = "com.google.protobuf:protobuf-javalite", version.ref = "protobuf" }
protobuf-protoc = { module = "com.google.protobuf:protoc", version.ref = "protobuf" }
coroutines-core = { module = "org.jetbrains.kotlinx:kotlinx-coroutines-core", version.ref = "coroutines" }
coroutines-test = { module = "org.jetbrains.kotlinx:kotlinx-coroutines-test", version.ref = "coroutines" }
junit = { module = "junit:junit", version.ref = "junit" }
robolectric = { module = "org.robolectric:robolectric", version.ref = "robolectric" }
androidx-test-core = { module = "androidx.test:core", version.ref = "androidxTestCore" }

[plugins]
android-application = { id = "com.android.application", version.ref = "agp" }
android-library = { id = "com.android.library", version.ref = "agp" }
kotlin-android = { id = "org.jetbrains.kotlin.android", version.ref = "kotlin" }
kotlin-jvm = { id = "org.jetbrains.kotlin.jvm", version.ref = "kotlin" }
kotlin-compose = { id = "org.jetbrains.kotlin.plugin.compose", version.ref = "kotlin" }
ksp = { id = "com.google.devtools.ksp", version.ref = "ksp" }
hilt = { id = "com.google.dagger.hilt.android", version.ref = "hilt" }
protobuf = { id = "com.google.protobuf", version.ref = "protobufPlugin" }
```

- [ ] **Step 3: Root build files**

`settings.gradle.kts`:
```kotlin
pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        maven("https://build-artifacts.signal.org/libraries/maven/") { content { includeGroup("org.signal") } }
    }
}
rootProject.name = "otter-android"
include(":app", ":core:proto", ":core:crypto", ":core:database", ":core:ui")
```

`build.gradle.kts`:
```kotlin
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.ksp) apply false
    alias(libs.plugins.hilt) apply false
    alias(libs.plugins.protobuf) apply false
}
```

`gradle.properties`:
```
org.gradle.jvmargs=-Xmx4g -Dfile.encoding=UTF-8
org.gradle.parallel=true
org.gradle.caching=true
android.useAndroidX=true
android.nonTransitiveRClass=true
kotlin.code.style=official
```

`local.properties` (gitignored): `sdk.dir=~/Android/Sdk`

`.gitignore`: `.gradle/`, `build/`, `local.properties`, `.idea/`, `*.iml`, `.kotlin/`, `captures/`.

- [ ] **Step 4: Module build files**

`core/proto/build.gradle.kts` (JVM library):
```kotlin
plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.protobuf)
}
kotlin { jvmToolchain(17) }
dependencies { api(libs.protobuf.javalite) }
protobuf {
    protoc { artifact = libs.protobuf.protoc.get().toString() }
    generateProtoTasks {
        all().forEach { task -> task.builtins { named("java") { option("lite") } } }
    }
}
```

`core/crypto/build.gradle.kts` (JVM library):
```kotlin
plugins { alias(libs.plugins.kotlin.jvm) }
kotlin { jvmToolchain(17) }
dependencies {
    api(project(":core:proto"))
    implementation(libs.tink)
    testImplementation(libs.junit)
}
```

`core/database/build.gradle.kts`:
```kotlin
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.ksp)
    alias(libs.plugins.hilt)
}
android {
    namespace = "app.ottermsg.core.database"
    compileSdk = 36
    defaultConfig { minSdk = 26; testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner" }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    testOptions { unitTests.isIncludeAndroidResources = true }
}
kotlin { jvmToolchain(17) }
ksp { arg("room.schemaLocation", "$projectDir/schemas") }
dependencies {
    implementation(libs.room.runtime); implementation(libs.room.ktx); ksp(libs.room.compiler)
    implementation(libs.sqlite.ktx); implementation(libs.sqlcipher)
    implementation(libs.hilt.android); ksp(libs.hilt.compiler)
    testImplementation(libs.junit); testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core); testImplementation(libs.coroutines.test)
    androidTestImplementation(libs.androidx.test.core); androidTestImplementation(libs.junit)
    androidTestImplementation("androidx.test:runner:1.7.0"); androidTestImplementation("androidx.test.ext:junit:1.3.0")
}
```

`core/ui/build.gradle.kts`:
```kotlin
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}
android {
    namespace = "app.ottermsg.core.ui"
    compileSdk = 36
    defaultConfig { minSdk = 26 }
    buildFeatures { compose = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
kotlin { jvmToolchain(17) }
dependencies {
    api(platform(libs.compose.bom)); api(libs.compose.ui); api(libs.compose.material3)
    api(libs.compose.ui.tooling.preview); debugImplementation(libs.compose.ui.tooling)
    testImplementation(libs.junit)
}
```

`app/build.gradle.kts`:
```kotlin
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.ksp)
    alias(libs.plugins.hilt)
}
android {
    namespace = "app.ottermsg"
    compileSdk = 36
    defaultConfig {
        applicationId = "app.ottermsg"
        minSdk = 26; targetSdk = 36
        versionCode = 1; versionName = "0.1.0"
    }
    buildTypes {
        release { isMinifyEnabled = true; proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro") }
    }
    buildFeatures { compose = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
kotlin { jvmToolchain(17) }
dependencies {
    implementation(project(":core:ui")); implementation(project(":core:database")); implementation(project(":core:crypto"))
    implementation(libs.androidx.core.ktx); implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.hilt.android); ksp(libs.hilt.compiler)
    testImplementation(libs.junit)
}
```
`jvmToolchain(17)` requires a JDK 17 → available at `/usr/lib/jvm/java-17-openjdk-amd64`; if Gradle's toolchain detection fails add `org.gradle.java.installations.paths=/usr/lib/jvm/java-17-openjdk-amd64` to `gradle.properties`.

- [ ] **Step 5: App shell**

`app/src/main/AndroidManifest.xml`:
```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:name=".OtterApp"
        android:label="@string/app_name"
        android:allowBackup="false"
        android:supportsRtl="true"
        android:theme="@android:style/Theme.Material.NoActionBar">
        <activity android:name=".MainActivity" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
```
(`allowBackup=false`: Android cloud backup must not copy keys/DB — our own backup handles history.)

`OtterApp.kt`:
```kotlin
package app.ottermsg

import android.app.Application
import dagger.hilt.android.HiltAndroidApp

@HiltAndroidApp
class OtterApp : Application()
```

`MainActivity.kt` (placeholder until M1; uses theme from Task 10 — in this task use plain `MaterialTheme`, Task 10 swaps to `OtterTheme`):
```kotlin
package app.ottermsg

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            MaterialTheme {
                Surface(Modifier.fillMaxSize()) {
                    Box(contentAlignment = Alignment.Center) { Text(stringResource(R.string.app_name)) }
                }
            }
        }
    }
}
```

`res/values/strings.xml` (Russian, default):
```xml
<resources>
    <string name="app_name">Otter</string>
</resources>
```
`res/values-en/strings.xml`: same `app_name` "Otter". (More strings arrive with screens in M1.)

- [ ] **Step 6: `scripts/sync-proto.sh`**
```bash
#!/usr/bin/env bash
# Copy shared protobuf schemas and cross-language test vectors from ../otter-server.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
server="${OTTER_SERVER_DIR:-$here/../otter-server}"
mkdir -p "$here/core/proto/src/main/proto/otter/v1" "$here/core/crypto/src/test/resources/vectors"
cp "$server"/proto/otter/v1/*.proto "$here/core/proto/src/main/proto/otter/v1/"
cp "$server"/testdata/vectors/*.json "$here/core/crypto/src/test/resources/vectors/"
echo "synced from $server ($(git -C "$server" rev-parse --short HEAD 2>/dev/null || echo no-git))"
```
`chmod +x scripts/sync-proto.sh && scripts/sync-proto.sh`

- [ ] **Step 7: Build** `./gradlew assembleDebug test` → BUILD SUCCESSFUL.
- [ ] **Step 8: Commit** `git add -A && git commit -m "chore: scaffold android multi-module project"`

---

### Task 8: `core:crypto` — BIP-39, seed keys, Ed25519, records, manifest verification

**Goal:** Kotlin equivalents of the Go key logic, proven against Go vectors.

**Files:**
- Create: `core/crypto/src/main/kotlin/app/ottermsg/core/crypto/Bip39.kt`
- Create: `core/crypto/src/main/resources/app/ottermsg/core/crypto/bip39-english.txt` (from `https://raw.githubusercontent.com/bitcoin/bips/master/bip-0039/english.txt`, sha256 `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda`)
- Create: `SeedKeys.kt`, `Ed25519.kt`, `Ids.kt`, `RecordCodec.kt`, `ManifestVerifier.kt` (same package)
- Test: `core/crypto/src/test/kotlin/app/ottermsg/core/crypto/Bip39Test.kt`, `VectorsTest.kt`, `ManifestVerifierTest.kt`

**Acceptance Criteria:**
- [ ] `Bip39.toMnemonic(entropy32)` / `Bip39.toEntropy(words)` pass the standard BIP-39 vectors below; bad checksum / unknown word / wrong count → `IllegalArgumentException`
- [ ] `SeedKeys.accountKeyPair(seed)` equals Go's `account_pub_hex`; `Ids.id16(pub)` equals `user_id_hex`
- [ ] `RecordCodec.verify(record, pub)` accepts vector records, rejects `bad_signature_record_hex`
- [ ] `ManifestVerifier.verify(bytes, networkPub, currentVersion)` returns the parsed `Manifest` for valid newer manifests; throws `ManifestException` for bad signature, wrong type, wrong author, foreign `network_pub`, version ≤ current

**Verify:** `./gradlew :core:crypto:test` → BUILD SUCCESSFUL, all tests pass

**Steps:**

- [ ] **Step 1: Download wordlist and verify checksum**
```bash
f=core/crypto/src/main/resources/app/ottermsg/core/crypto/bip39-english.txt
mkdir -p "$(dirname $f)" && curl -sSL https://raw.githubusercontent.com/bitcoin/bips/master/bip-0039/english.txt -o $f
echo "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda  $f" | sha256sum -c
```

- [ ] **Step 2: Failing tests**

`Bip39Test.kt`:
```kotlin
package app.ottermsg.core.crypto

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class Bip39Test {
    private fun hex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private val vectors = listOf(
        "0000000000000000000000000000000000000000000000000000000000000000" to
            "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art",
        "7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f" to
            "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title",
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" to
            "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote",
    )

    @Test fun standardVectors() {
        for ((e, m) in vectors) {
            assertEquals(m, Bip39.toMnemonic(hex(e)).joinToString(" "))
            assertArrayEquals(hex(e), Bip39.toEntropy(m.split(" ")))
        }
    }

    @Test(expected = IllegalArgumentException::class) fun badChecksum() {
        Bip39.toEntropy(("abandon ".repeat(24)).trim().split(" "))
    }

    @Test(expected = IllegalArgumentException::class) fun unknownWord() {
        Bip39.toEntropy((List(23) { "abandon" } + "otterword"))
    }

    @Test(expected = IllegalArgumentException::class) fun wrongCount() {
        Bip39.toEntropy(List(12) { "abandon" })
    }

    @Test fun normalizesCaseAndSpaces() {
        val m = vectors[0].second.uppercase().split(" ").map { " $it " }
        assertArrayEquals(ByteArray(32), Bip39.toEntropy(m))
    }
}
```

`VectorsTest.kt`:
```kotlin
package app.ottermsg.core.crypto

import app.ottermsg.proto.v1.Record
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VectorsTest {
    private val v: Map<String, String> = run {
        val text = javaClass.getResource("/vectors/v1.json")!!.readText()
        Regex("\"(\\w+)\":\\s*\"?([^\",\\n]*)\"?").findAll(text).associate { it.groupValues[1] to it.groupValues[2] }
    }
    private fun hex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test fun accountKeyMatchesGo() {
        val kp = SeedKeys.accountKeyPair(hex(v.getValue("seed_hex")))
        assertArrayEquals(hex(v.getValue("account_pub_hex")), kp.publicKey)
        assertArrayEquals(hex(v.getValue("user_id_hex")), Ids.id16(kp.publicKey))
    }

    @Test fun networkIdMatchesGo() {
        assertArrayEquals(hex(v.getValue("network_id_hex")), Ids.id16(hex(v.getValue("network_pub_hex"))))
    }

    @Test fun verifiesGoRecords() {
        val dir = Record.parseFrom(hex(v.getValue("directory_entry_record_hex")))
        assertTrue(RecordCodec.verify(dir, hex(v.getValue("account_pub_hex"))))
        val bad = Record.parseFrom(hex(v.getValue("bad_signature_record_hex")))
        assertFalse(RecordCodec.verify(bad, hex(v.getValue("network_pub_hex"))))
    }

    @Test fun verifiesGoManifest() {
        val m = ManifestVerifier.verify(hex(v.getValue("manifest_record_hex")), hex(v.getValue("network_pub_hex")), currentVersion = 0)
        assertEquals(v.getValue("manifest_version").toLong(), m.version)
        assertEquals("chat.example.org", m.getNodes(0).getEndpoints(0).host)
    }

    @Test fun kotlinSignatureVerifiesWithKotlin() {
        val kp = SeedKeys.accountKeyPair(ByteArray(32) { it.toByte() })
        val rec = RecordCodec.sign(RecordCodec.body(
            type = app.ottermsg.proto.v1.RecordType.ACK, author = Ids.id16(kp.publicKey), payload = byteArrayOf(1)), kp)
        assertTrue(RecordCodec.verify(rec, kp.publicKey))
    }
}
```

`ManifestVerifierTest.kt`:
```kotlin
package app.ottermsg.core.crypto

import app.ottermsg.proto.v1.Manifest
import app.ottermsg.proto.v1.RecordType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ManifestVerifierTest {
    private val net = Ed25519.keyPairFromSeed(ByteArray(32) { 1 })
    private val other = Ed25519.keyPairFromSeed(ByteArray(32) { 2 })

    private fun signed(version: Long, signer: Ed25519.KeyPair = net, author: ByteArray = Ids.id16(net.publicKey),
                       networkPub: ByteArray = net.publicKey, type: RecordType = RecordType.MANIFEST): ByteArray {
        val m = Manifest.newBuilder().setVersion(version).setNetworkPub(com.google.protobuf.ByteString.copyFrom(networkPub)).build()
        return RecordCodec.sign(RecordCodec.body(type, author, m.toByteArray()), signer).toByteArray()
    }

    @Test fun acceptsNewer() { assertEquals(5L, ManifestVerifier.verify(signed(5), net.publicKey, 4).version) }
    @Test fun rejectsSameVersion() { assertThrows(ManifestException::class.java) { ManifestVerifier.verify(signed(4), net.publicKey, 4) } }
    @Test fun rejectsWrongSigner() { assertThrows(ManifestException::class.java) { ManifestVerifier.verify(signed(5, signer = other), net.publicKey, 0) } }
    @Test fun rejectsWrongAuthor() { assertThrows(ManifestException::class.java) { ManifestVerifier.verify(signed(5, author = ByteArray(16)), net.publicKey, 0) } }
    @Test fun rejectsForeignNetworkPub() { assertThrows(ManifestException::class.java) { ManifestVerifier.verify(signed(5, networkPub = other.publicKey), net.publicKey, 0) } }
    @Test fun rejectsWrongType() { assertThrows(ManifestException::class.java) { ManifestVerifier.verify(signed(5, type = RecordType.ACK), net.publicKey, 0) } }
    @Test fun rejectsGarbage() { assertThrows(ManifestException::class.java) { ManifestVerifier.verify(byteArrayOf(1, 2, 3), net.publicKey, 0) } }
}
```

- [ ] **Step 3: Run** `./gradlew :core:crypto:test` → FAIL (unresolved).

- [ ] **Step 4: Implement**

`Bip39.kt`:
```kotlin
package app.ottermsg.core.crypto

import java.security.MessageDigest

/** BIP-39 mnemonic <-> 256-bit entropy. The entropy itself is the OtterMSG recovery seed. */
object Bip39 {
    private val words: List<String> by lazy {
        Bip39::class.java.getResourceAsStream("bip39-english.txt")!!.bufferedReader().readLines().filter { it.isNotBlank() }
            .also { require(it.size == 2048) }
    }
    private val index: Map<String, Int> by lazy { words.withIndex().associate { it.value to it.index } }

    fun toMnemonic(entropy: ByteArray): List<String> {
        require(entropy.size == 32) { "entropy must be 32 bytes" }
        val checksum = MessageDigest.getInstance("SHA-256").digest(entropy)[0]
        val bits = BooleanArray(264)
        for (i in 0 until 256) bits[i] = (entropy[i / 8].toInt() shr (7 - i % 8)) and 1 == 1
        for (i in 0 until 8) bits[256 + i] = (checksum.toInt() shr (7 - i)) and 1 == 1
        return List(24) { w -> var v = 0; for (b in 0 until 11) v = (v shl 1) or (if (bits[w * 11 + b]) 1 else 0); words[v] }
    }

    fun toEntropy(mnemonic: List<String>): ByteArray {
        val ws = mnemonic.map { it.trim().lowercase() }.filter { it.isNotEmpty() }
        require(ws.size == 24) { "expected 24 words, got ${ws.size}" }
        val bits = BooleanArray(264)
        ws.forEachIndexed { w, word ->
            val v = index[word] ?: throw IllegalArgumentException("unknown word: $word")
            for (b in 0 until 11) bits[w * 11 + b] = (v shr (10 - b)) and 1 == 1
        }
        val entropy = ByteArray(32)
        for (i in 0 until 256) if (bits[i]) entropy[i / 8] = (entropy[i / 8].toInt() or (1 shl (7 - i % 8))).toByte()
        val checksum = MessageDigest.getInstance("SHA-256").digest(entropy)[0].toInt() and 0xFF
        var got = 0
        for (i in 0 until 8) got = (got shl 1) or (if (bits[256 + i]) 1 else 0)
        require(got == checksum) { "bad checksum" }
        return entropy
    }
}
```

`Ed25519.kt`:
```kotlin
package app.ottermsg.core.crypto

import com.google.crypto.tink.subtle.Ed25519Sign
import com.google.crypto.tink.subtle.Ed25519Verify
import java.security.GeneralSecurityException

object Ed25519 {
    class KeyPair(val seed: ByteArray, val publicKey: ByteArray) {
        fun sign(data: ByteArray): ByteArray = Ed25519Sign(seed).sign(data)
    }

    fun keyPairFromSeed(seed: ByteArray): KeyPair {
        require(seed.size == 32)
        return KeyPair(seed.copyOf(), Ed25519Sign.KeyPair.newKeyPairFromSeed(seed).publicKey)
    }

    fun verify(publicKey: ByteArray, data: ByteArray, signature: ByteArray): Boolean =
        try { Ed25519Verify(publicKey).verify(signature, data); true } catch (e: GeneralSecurityException) { false }
}
```

`SeedKeys.kt`:
```kotlin
package app.ottermsg.core.crypto

import com.google.crypto.tink.subtle.Hkdf

/** Keys derived from the 32-byte recovery seed. Must match Go `keys.DeriveAccountKey`. */
object SeedKeys {
    const val INFO_ACCOUNT = "otter/account/v1"

    fun accountKeyPair(seed: ByteArray): Ed25519.KeyPair {
        require(seed.size == 32) { "seed must be 32 bytes" }
        val k = Hkdf.computeHkdf("HMACSHA256", seed, ByteArray(0), INFO_ACCOUNT.toByteArray(), 32)
        return Ed25519.keyPairFromSeed(k)
    }
}
```

`Ids.kt`:
```kotlin
package app.ottermsg.core.crypto

import java.security.MessageDigest

object Ids {
    fun id16(publicKey: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(publicKey).copyOf(16)
}
```

`RecordCodec.kt`:
```kotlin
package app.ottermsg.core.crypto

import app.ottermsg.proto.v1.Record
import app.ottermsg.proto.v1.RecordBody
import app.ottermsg.proto.v1.RecordType
import com.google.protobuf.ByteString
import java.security.SecureRandom

object RecordCodec {
    private val rng = SecureRandom()

    fun body(type: RecordType, author: ByteArray, payload: ByteArray, expiresMs: Long = 0,
             id: ByteArray = ByteArray(16).also(rng::nextBytes), createdMs: Long = System.currentTimeMillis()): RecordBody =
        RecordBody.newBuilder().setId(ByteString.copyFrom(id)).setType(type).setAuthor(ByteString.copyFrom(author))
            .setCreatedMs(createdMs).setExpiresMs(expiresMs).setPayload(ByteString.copyFrom(payload)).build()

    /** Signs the exact serialized body bytes (same rule as the Go node). */
    fun sign(body: RecordBody, key: Ed25519.KeyPair): Record {
        val bytes = body.toByteArray()
        return Record.newBuilder().setBody(ByteString.copyFrom(bytes)).setSignature(ByteString.copyFrom(key.sign(bytes))).build()
    }

    fun verify(record: Record, publicKey: ByteArray): Boolean =
        record.signature.size() == 64 && Ed25519.verify(publicKey, record.body.toByteArray(), record.signature.toByteArray())
}
```

`ManifestVerifier.kt`:
```kotlin
package app.ottermsg.core.crypto

import app.ottermsg.proto.v1.Manifest
import app.ottermsg.proto.v1.Record
import app.ottermsg.proto.v1.RecordBody
import app.ottermsg.proto.v1.RecordType
import com.google.protobuf.InvalidProtocolBufferException

class ManifestException(msg: String) : Exception(msg)

object ManifestVerifier {
    /** Verifies a serialized MANIFEST record and returns the manifest if it is valid and newer. */
    fun verify(recordBytes: ByteArray, networkPub: ByteArray, currentVersion: Long): Manifest {
        try {
            val rec = Record.parseFrom(recordBytes)
            if (!RecordCodec.verify(rec, networkPub)) throw ManifestException("bad signature")
            val body = RecordBody.parseFrom(rec.body)
            if (body.type != RecordType.MANIFEST) throw ManifestException("not a manifest")
            if (!body.author.toByteArray().contentEquals(Ids.id16(networkPub))) throw ManifestException("wrong author")
            val m = Manifest.parseFrom(body.payload)
            if (!m.networkPub.toByteArray().contentEquals(networkPub)) throw ManifestException("foreign network")
            if (m.version <= currentVersion) throw ManifestException("not newer: ${m.version} <= $currentVersion")
            return m
        } catch (e: InvalidProtocolBufferException) {
            throw ManifestException("malformed: ${e.message}")
        }
    }
}
```
Note: `Manifest.version` is `uint64` → Kotlin `Long`; versions stay far below 2^63.

- [ ] **Step 5: Run** `scripts/sync-proto.sh && ./gradlew :core:crypto:test` → all PASS.
- [ ] **Step 6: Commit** `git add -A && git commit -m "feat(crypto): bip39 seed, account key, ed25519 records, manifest verification"`

---

### Task 9: `core:database` — Room + SQLCipher with Keystore-wrapped key

**Goal:** Encrypted local DB skeleton with key management, ready for M1 entities.

**Files:**
- Create: `core/database/src/main/kotlin/app/ottermsg/core/database/OtterDatabase.kt`
- Create: `.../entity/AccountEntity.kt`, `.../entity/ManifestEntity.kt`, `.../dao/AccountDao.kt`, `.../dao/ManifestDao.kt`
- Create: `.../key/KeyWrapper.kt`, `.../key/KeystoreKeyWrapper.kt`, `.../key/DatabaseKeyProvider.kt`
- Create: `.../di/DatabaseModule.kt`
- Test: `core/database/src/test/kotlin/app/ottermsg/core/database/DatabaseKeyProviderTest.kt`, `DaoTest.kt`
- Test (device): `core/database/src/androidTest/kotlin/app/ottermsg/core/database/EncryptedDatabaseTest.kt`

**Acceptance Criteria:**
- [ ] `DatabaseKeyProvider.getOrCreate()` creates a random 32-byte key once, stores it wrapped (via `KeyWrapper`) in `noBackupFilesDir/db.key`, returns the same key afterwards
- [ ] `KeystoreKeyWrapper` uses AES-256-GCM key `otter_db_kek` in AndroidKeyStore (StrongBox if available, fallback otherwise)
- [ ] `OtterDatabase` opened via `SupportOpenHelperFactory(key)` (SQLCipher) in production; tests use in-memory Room without SQLCipher
- [ ] Entities: `account(user_id PK, username, display_name, seed_enc BLOB, created_ms)`, `manifest(version PK, raw BLOB)`; DAOs insert/get/observe latest manifest
- [ ] Room schema JSON exported to `core/database/schemas/`
- [ ] Unit tests (Robolectric) pass; instrumented test verifies the DB file is not plaintext SQLite (header ≠ "SQLite format 3") — run when a device/emulator is available

**Verify:** `./gradlew :core:database:testDebugUnitTest` → PASS; with emulator: `./gradlew :core:database:connectedDebugAndroidTest` → PASS

**Steps:**

- [ ] **Step 1: Failing unit tests**

`DatabaseKeyProviderTest.kt`:
```kotlin
package app.ottermsg.core.database

import app.ottermsg.core.database.key.DatabaseKeyProvider
import app.ottermsg.core.database.key.KeyWrapper
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class DatabaseKeyProviderTest {
    @get:Rule val tmp = TemporaryFolder()

    private class XorWrapper : KeyWrapper {
        var wraps = 0
        override fun wrap(plain: ByteArray) = plain.map { (it.toInt() xor 0x5A).toByte() }.toByteArray().also { wraps++ }
        override fun unwrap(wrapped: ByteArray) = wrapped.map { (it.toInt() xor 0x5A).toByte() }.toByteArray()
    }

    @Test fun createsOnceAndReuses() {
        val w = XorWrapper()
        val file = File(tmp.root, "db.key")
        val k1 = DatabaseKeyProvider(file, w).getOrCreate()
        val k2 = DatabaseKeyProvider(file, w).getOrCreate()
        assertEquals(32, k1.size)
        assertArrayEquals(k1, k2)
        assertEquals(1, w.wraps)
        assertFalse(file.readBytes().contentEquals(k1)) // stored wrapped, not plain
    }
}
```

`DaoTest.kt`:
```kotlin
package app.ottermsg.core.database

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.ottermsg.core.database.entity.ManifestEntity
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class DaoTest {
    private lateinit var db: OtterDatabase

    @Before fun setUp() {
        db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), OtterDatabase::class.java)
            .allowMainThreadQueries().build()
    }
    @After fun tearDown() = db.close()

    @Test fun latestManifest() = runTest {
        assertNull(db.manifestDao().latest())
        db.manifestDao().insert(ManifestEntity(3, byteArrayOf(3)))
        db.manifestDao().insert(ManifestEntity(5, byteArrayOf(5)))
        assertEquals(5L, db.manifestDao().latest()!!.version)
        assertEquals(5L, db.manifestDao().observeLatest().first()!!.version)
    }
}
```

- [ ] **Step 2: Run** `./gradlew :core:database:testDebugUnitTest` → FAIL.

- [ ] **Step 3: Implement**

`key/KeyWrapper.kt`:
```kotlin
package app.ottermsg.core.database.key

/** Wraps small secrets (the DB key) with a device-bound key. */
interface KeyWrapper {
    fun wrap(plain: ByteArray): ByteArray
    fun unwrap(wrapped: ByteArray): ByteArray
}
```

`key/KeystoreKeyWrapper.kt`:
```kotlin
package app.ottermsg.core.database.key

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** AES-256-GCM in AndroidKeyStore. Output: iv(12) || ciphertext+tag. */
class KeystoreKeyWrapper(private val alias: String = "otter_db_kek") : KeyWrapper {
    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(alias, null) as? SecretKey)?.let { return it }
        fun gen(strongBox: Boolean): SecretKey {
            val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .apply { if (strongBox && Build.VERSION.SDK_INT >= 28) setIsStrongBoxBacked(true) }
                .build()
            return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply { init(spec) }.generateKey()
        }
        // StrongBox failures surface as different exception types across vendors → any failure falls back.
        return try { gen(strongBox = true) } catch (e: Exception) { gen(strongBox = false) }
    }

    override fun wrap(plain: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        return c.iv + c.doFinal(plain)
    }

    override fun unwrap(wrapped: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, wrapped, 0, 12))
        return c.doFinal(wrapped, 12, wrapped.size - 12)
    }
}
```
(Remove the unused `StrongBoxUnavailableException` import.)

`key/DatabaseKeyProvider.kt`:
```kotlin
package app.ottermsg.core.database.key

import java.io.File
import java.security.SecureRandom

class DatabaseKeyProvider(private val file: File, private val wrapper: KeyWrapper) {
    @Synchronized
    fun getOrCreate(): ByteArray {
        if (file.exists()) return wrapper.unwrap(file.readBytes())
        val key = ByteArray(32).also(SecureRandom()::nextBytes)
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeBytes(wrapper.wrap(key))
        check(tmp.renameTo(file)) { "cannot store db key" }
        return key
    }
}
```

`entity/AccountEntity.kt`:
```kotlin
package app.ottermsg.core.database.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "account")
data class AccountEntity(
    @PrimaryKey @ColumnInfo(name = "user_id") val userId: ByteArray,
    val username: String,
    @ColumnInfo(name = "display_name") val displayName: String,
    @ColumnInfo(name = "seed_enc") val seedEnc: ByteArray,
    @ColumnInfo(name = "created_ms") val createdMs: Long,
)
```

`entity/ManifestEntity.kt`:
```kotlin
package app.ottermsg.core.database.entity

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "manifest")
data class ManifestEntity(@PrimaryKey val version: Long, val raw: ByteArray)
```

`dao/AccountDao.kt`:
```kotlin
package app.ottermsg.core.database.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import app.ottermsg.core.database.entity.AccountEntity

@Dao
interface AccountDao {
    @Insert suspend fun insert(a: AccountEntity)
    @Query("SELECT * FROM account LIMIT 1") suspend fun get(): AccountEntity?
}
```

`dao/ManifestDao.kt`:
```kotlin
package app.ottermsg.core.database.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import app.ottermsg.core.database.entity.ManifestEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface ManifestDao {
    @Insert(onConflict = OnConflictStrategy.IGNORE) suspend fun insert(m: ManifestEntity)
    @Query("SELECT * FROM manifest ORDER BY version DESC LIMIT 1") suspend fun latest(): ManifestEntity?
    @Query("SELECT * FROM manifest ORDER BY version DESC LIMIT 1") fun observeLatest(): Flow<ManifestEntity?>
}
```

`OtterDatabase.kt`:
```kotlin
package app.ottermsg.core.database

import androidx.room.Database
import androidx.room.RoomDatabase
import app.ottermsg.core.database.dao.AccountDao
import app.ottermsg.core.database.dao.ManifestDao
import app.ottermsg.core.database.entity.AccountEntity
import app.ottermsg.core.database.entity.ManifestEntity

@Database(entities = [AccountEntity::class, ManifestEntity::class], version = 1, exportSchema = true)
abstract class OtterDatabase : RoomDatabase() {
    abstract fun accountDao(): AccountDao
    abstract fun manifestDao(): ManifestDao
}
```

`di/DatabaseModule.kt`:
```kotlin
package app.ottermsg.core.database.di

import android.content.Context
import androidx.room.Room
import app.ottermsg.core.database.OtterDatabase
import app.ottermsg.core.database.key.DatabaseKeyProvider
import app.ottermsg.core.database.key.KeystoreKeyWrapper
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import net.zetetic.database.sqlcipher.SupportOpenHelperFactory
import java.io.File
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object DatabaseModule {
    @Provides @Singleton
    fun database(@ApplicationContext ctx: Context): OtterDatabase {
        System.loadLibrary("sqlcipher")
        val key = DatabaseKeyProvider(File(ctx.noBackupFilesDir, "db.key"), KeystoreKeyWrapper()).getOrCreate()
        return Room.databaseBuilder(ctx, OtterDatabase::class.java, "otter.db")
            .openHelperFactory(SupportOpenHelperFactory(key))
            .build()
    }
    @Provides fun accountDao(db: OtterDatabase) = db.accountDao()
    @Provides fun manifestDao(db: OtterDatabase) = db.manifestDao()
}
```

`androidTest/.../EncryptedDatabaseTest.kt`:
```kotlin
package app.ottermsg.core.database

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import app.ottermsg.core.database.entity.ManifestEntity
import kotlinx.coroutines.runBlocking
import net.zetetic.database.sqlcipher.SupportOpenHelperFactory
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class EncryptedDatabaseTest {
    @Test fun fileIsNotPlainSqlite() = runBlocking {
        System.loadLibrary("sqlcipher")
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()
        ctx.deleteDatabase("enc-test.db")
        val db = Room.databaseBuilder(ctx, OtterDatabase::class.java, "enc-test.db")
            .openHelperFactory(SupportOpenHelperFactory(ByteArray(32) { 7 })).build()
        db.manifestDao().insert(ManifestEntity(1, byteArrayOf(1)))
        db.close()
        val header = ctx.getDatabasePath("enc-test.db").readBytes().copyOf(15).decodeToString()
        assertFalse(header == "SQLite format 3")
    }
}
```
Add `androidTestImplementation(libs.coroutines.test)` is not needed (uses `runBlocking`), but add `implementation(libs.coroutines.core)` to `core/database` if Room's Flow requires it explicitly.

- [ ] **Step 4: Run** `./gradlew :core:database:testDebugUnitTest` → PASS. If an emulator/device is attached (`adb devices`), also run `:core:database:connectedDebugAndroidTest` → PASS; otherwise note it as pending in the task report.
- [ ] **Step 5: Commit** `git add -A && git commit -m "feat(database): room + sqlcipher with keystore-wrapped key"`

---

### Task 10: `core:ui` — Otter theme tokens + app uses it

**Goal:** Design tokens from `docs/10-otter-design-guidelines.md` §3–§5 as `OtterTheme`.

**Files:**
- Create: `core/ui/src/main/kotlin/app/ottermsg/core/ui/theme/Color.kt`, `Type.kt`, `Dimens.kt`, `Theme.kt`
- Modify: `app/src/main/java/app/ottermsg/MainActivity.kt` (use `OtterTheme`)
- Test: `core/ui/src/test/kotlin/app/ottermsg/core/ui/theme/ContrastTest.kt`

**Acceptance Criteria:**
- [ ] All 15 semantic tokens for light and dark exactly as in guide §3; `outgoingContainer`/`onOutgoingContainer`/`warning*`/`divider` exposed via `OtterTheme.extraColors` (CompositionLocal), the rest mapped onto Material3 `ColorScheme`
- [ ] No dynamic color
- [ ] Typography roles from §4 (sizes/line heights/weights)
- [ ] `Dimens` from §5 (spacing 4/8/12/16/24/32, radii 20/20/16/24, avatars 40/48/64, min touch 48)
- [ ] Contrast test: text pairs ≥ 4.5:1 (`onSurface/surface`, `onSurface/background`, `onSurfaceVariant/surface`, `onPrimary/primary`, `onOutgoingContainer/outgoingContainer`, `error/errorContainer`, `warning/warningContainer`) in both themes
- [ ] App renders "Otter" with `OtterTheme`

**Verify:** `./gradlew :core:ui:test assembleDebug` → BUILD SUCCESSFUL

**Steps:**

- [ ] **Step 1: Failing contrast test**

```kotlin
package app.ottermsg.core.ui.theme

import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.pow

class ContrastTest {
    private fun lum(argb: Long): Double {
        fun ch(v: Long): Double { val c = v / 255.0; return if (c <= 0.03928) c / 12.92 else ((c + 0.055) / 1.055).pow(2.4) }
        return 0.2126 * ch((argb shr 16) and 0xFF) + 0.7152 * ch((argb shr 8) and 0xFF) + 0.0722 * ch(argb and 0xFF)
    }
    private fun ratio(a: Long, b: Long): Double { val (x, y) = listOf(lum(a), lum(b)).sortedDescending(); return (x + 0.05) / (y + 0.05) }

    @Test fun textPairsMeetAA() {
        for (t in listOf(OtterPalette.Light, OtterPalette.Dark)) {
            val pairs = mapOf(
                "onSurface/surface" to (t.onSurface to t.surface),
                "onSurface/background" to (t.onSurface to t.background),
                "onSurfaceVariant/surface" to (t.onSurfaceVariant to t.surface),
                "onPrimary/primary" to (t.onPrimary to t.primary),
                "onOutgoing/outgoing" to (t.onOutgoingContainer to t.outgoingContainer),
                "error/errorContainer" to (t.error to t.errorContainer),
                "warning/warningContainer" to (t.warning to t.warningContainer),
            )
            for ((name, p) in pairs) { val r = ratio(p.first, p.second); assertTrue("$name = $r", r >= 4.5) }
        }
    }
}
```

- [ ] **Step 2: Run** → FAIL.

- [ ] **Step 3: Implement**

`Color.kt` (raw ARGB longs so the palette is testable on the JVM without Compose):
```kotlin
package app.ottermsg.core.ui.theme

data class OtterPalette(
    val background: Long, val surface: Long, val surfaceVariant: Long, val onSurface: Long, val onSurfaceVariant: Long,
    val primary: Long, val onPrimary: Long, val outgoingContainer: Long, val onOutgoingContainer: Long,
    val outline: Long, val divider: Long, val error: Long, val errorContainer: Long, val warning: Long, val warningContainer: Long,
) {
    companion object {
        val Light = OtterPalette(
            background = 0xFFFAF7F2, surface = 0xFFFFFFFF, surfaceVariant = 0xFFECEFEA, onSurface = 0xFF202724,
            onSurfaceVariant = 0xFF5D6963, primary = 0xFF006B60, onPrimary = 0xFFFFFFFF, outgoingContainer = 0xFFDCF1E3,
            onOutgoingContainer = 0xFF17382D, outline = 0xFF738079, divider = 0xFFDFE4DE, error = 0xFFB3261E,
            errorContainer = 0xFFFCEAE7, warning = 0xFF775800, warningContainer = 0xFFFFF2CC,
        )
        val Dark = OtterPalette(
            background = 0xFF151B19, surface = 0xFF202925, surfaceVariant = 0xFF2A3530, onSurface = 0xFFF0F4F1,
            onSurfaceVariant = 0xFFB8C5BD, primary = 0xFF83D5C4, onPrimary = 0xFF00382F, outgoingContainer = 0xFF25463A,
            onOutgoingContainer = 0xFFE0F4E7, outline = 0xFF89988F, divider = 0xFF39463F, error = 0xFFFFB4AB,
            errorContainer = 0xFF4B2522, warning = 0xFFE7C86B, warningContainer = 0xFF40371C,
        )
    }
}
```

`Type.kt`:
```kotlin
package app.ottermsg.core.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

private fun s(size: Int, line: Int, w: Int) = TextStyle(fontSize = size.sp, lineHeight = line.sp, fontWeight = FontWeight(w))

/** Guide §4. Mapping: titleLarge=screen title, headlineSmall=profile name, bodyLarge=message/input,
 *  titleMedium=settings row title, labelLarge(600)=sender name & buttons, bodyMedium=caption, bodySmall=time/status,
 *  titleSmall=section header. */
val OtterTypography = Typography(
    titleLarge = s(22, 28, 600),
    headlineSmall = s(24, 32, 600),
    bodyLarge = s(16, 24, 400),
    titleMedium = s(16, 24, 500),
    labelLarge = s(14, 20, 600),
    bodyMedium = s(14, 20, 400),
    bodySmall = s(12, 16, 400),
    titleSmall = s(14, 20, 600),
)
```

`Dimens.kt`:
```kotlin
package app.ottermsg.core.ui.theme

import androidx.compose.ui.unit.dp

object Dimens {
    val s4 = 4.dp; val s8 = 8.dp; val s12 = 12.dp; val s16 = 16.dp; val s24 = 24.dp; val s32 = 32.dp
    val screenGutter = 16.dp; val messageListGutter = 12.dp
    val sameAuthorGap = 4.dp; val groupGap = 12.dp
    val minTouch = 48.dp; val icon = 24.dp
    val bubbleRadius = 20.dp; val cardRadius = 20.dp; val photoRadius = 16.dp; val inputRadius = 24.dp
    val avatarTopBar = 40.dp; val avatarList = 48.dp; val avatarProfile = 64.dp
    val settingsRowMin = 56.dp; val settingsRowWithCaptionMin = 72.dp
    val topBarHeight = 64.dp
    val bubbleMaxWidth = 480.dp; const val bubbleMaxFraction = 0.84f; const val bubbleMaxFractionLargeFont = 0.94f
    val photoPreviewMaxHeight = 320.dp
}
```

`Theme.kt`:
```kotlin
package app.ottermsg.core.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

@Immutable
data class OtterExtraColors(
    val outgoingContainer: Color, val onOutgoingContainer: Color, val divider: Color,
    val warning: Color, val warningContainer: Color,
)

private val LocalExtra = staticCompositionLocalOf { extra(OtterPalette.Light) }

private fun extra(p: OtterPalette) = OtterExtraColors(Color(p.outgoingContainer), Color(p.onOutgoingContainer),
    Color(p.divider), Color(p.warning), Color(p.warningContainer))

private fun scheme(p: OtterPalette, dark: Boolean) = (if (dark) darkColorScheme() else lightColorScheme()).copy(
    background = Color(p.background), onBackground = Color(p.onSurface),
    surface = Color(p.surface), onSurface = Color(p.onSurface),
    surfaceVariant = Color(p.surfaceVariant), onSurfaceVariant = Color(p.onSurfaceVariant),
    primary = Color(p.primary), onPrimary = Color(p.onPrimary),
    outline = Color(p.outline), outlineVariant = Color(p.divider),
    error = Color(p.error), errorContainer = Color(p.errorContainer), onErrorContainer = Color(p.error),
)

enum class ThemeMode { SYSTEM, LIGHT, DARK }

@Composable
fun OtterTheme(mode: ThemeMode = ThemeMode.SYSTEM, content: @Composable () -> Unit) {
    val dark = when (mode) { ThemeMode.SYSTEM -> isSystemInDarkTheme(); ThemeMode.LIGHT -> false; ThemeMode.DARK -> true }
    val p = if (dark) OtterPalette.Dark else OtterPalette.Light
    CompositionLocalProvider(LocalExtra provides extra(p)) {
        MaterialTheme(colorScheme = scheme(p, dark), typography = OtterTypography, content = content)
    }
}

object OtterTheme {
    val extraColors: OtterExtraColors @Composable get() = LocalExtra.current
}
```

`MainActivity.kt`: replace `MaterialTheme {` with `OtterTheme {` and `import app.ottermsg.core.ui.theme.OtterTheme`; `Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background)`.

- [ ] **Step 4: Run** `./gradlew :core:ui:test assembleDebug` → PASS. If a contrast pair fails, report the exact ratio to the user — do not silently change the guide's colors (guide is normative; changes need sign-off).
- [ ] **Step 5: Commit** `git add -A && git commit -m "feat(ui): otter theme tokens, typography, dimens"`

---

## M0 Done checklist

- [ ] `cd otter-server && make check` green
- [ ] `cd otter-android && ./gradlew assembleDebug test` green
- [ ] Android `VectorsTest` verifies the Go-signed manifest and derives the same account key from the same seed
- [ ] Both repos committed on `main`
- [ ] Next: write M1 plan (single node, 1:1 text) — `docs/superpowers/plans/YYYY-MM-DD-m1-single-node-chat.md`
