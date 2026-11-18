# M9.5 Member privacy and the network code — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Phones see only the members they are related to (direct inviter and invitees, chat and group partners,
members who chose to be listed), anyone stays reachable by exact `@username`, and every member can check a 15-digit
network code.

**Architecture:** Nodes keep replicating every directory entry (delivery needs the keys). The answering node filters:
`directory.sync`/`directory.list` return the caller's visible set plus the **invite ancestry** each entry needs for the
phone's chain check (D104); `directory.get` refreshes chat and group partners by id; `directory.lookup` finds one exact
username under a 30/hour, 200/day limit. The phone stores what it receives and shows a **catalog** filtered by signed
data it can check itself (`listed`, invite relation, chat, group), so a lying node cannot list anyone.

**Tech Stack:** Go 1.26 (otter-server), protobuf/buf, SQLite; Kotlin, Jetpack Compose, Room (AutoMigration),
Robolectric (otter-android).

**Spec:** `docs/superpowers/specs/2026-11-15-m9-5-member-privacy-design.md` (approved 2026-11-15/16).
**Versions:** server **0.11.0**, app **0.11.0** (versionCode 15). M10 video moves to 0.12.0 (Task 12 updates its docs).

---

## Facts from the code (main, 2026-11-18: server 0.10.1 at 5a8a9e6, app 0.10.1 at 6f11d8d)

| Question | Answer | Source |
|---|---|---|
| Free proto fields | `DirectoryEntry` ends at `invite_proof = 11` → `listed = 12`; `LoginResponse` ends at `install = 3` → `server_version = 4` (not `Hello`: hello goes out before login, and the spec shows versions to members only) | `proto/otter/v1/records.proto:45-57`, `api.proto:118-122` |
| `directory.sync` today | `svc.Directory(ctx)`: every entry + every REVOCATION/INVITE_RIGHTS + winning REKEYs; body ignored (no `since`, although `02-protocol.md:258` says so) | `internal/gateway/methods.go:221`, `internal/service/service.go:252-277` |
| `admin.users` | uses the same `svc.Directory` → must stay unfiltered | `methods.go:183-195` |
| Unknown method | `STATUS_INVALID`, error `unknown method "x"` | `methods.go:341-342` |
| `directory` event | broadcast to every logged-in session, `Notifier.Directory()` without arguments | `gateway.go:105-111` |
| Invite chain on the node | `redemptions(invite_id, user_id, rank, inviter)`; founding members have no row; a network-invited member's `inviter` is the network's id16 (not a user) | `migrations/0011_membership.sql:7-9`, `store/membership.go:22-27` |
| Re-keys | `rekeys(old_user_id PK, new_user_id, …)` | `migrations/0015_rekeys.sql` |
| Username clash tag | **8 hex** (`name#1a2b3c4d`), not 4 as the spec wrote; `ResolveUsername` handles it | `store/typed.go:496`, `store/membership.go:251` |
| Hourly limits | `windowCounter.allow(now, window, key, limit)` → `ErrQuota` (`STATUS_QUOTA`) | `service/ratelimit.go`, `service/submit.go:51` |
| Phone admission | an entry becomes a contact only if its invite chain verifies against the network key or an **already accepted** inviter (D104) → a filtered answer must carry each entry's inviter chain | `core/data/.../directory/DirectorySync.kt:207-244` |
| Phone lists | «Написать» = `NewChatRoute` (no search); group pickers have a search; both read `ContactDao.observeAll()` | `feature/chats/.../NewChatViewModel.kt:16-21`, `feature/groups/.../NewGroupViewModel.kt:28-32` |
| Unknown sender | `MailboxReceiver` re-syncs the whole directory | `core/data/.../MailboxReceiver.kt:64-70`, `GroupApplier.kt:122-133` |
| Foreign manifest | `ManifestVerifier` checks the signature first ("bad signature"), "foreign network" only after; `ManifestUpdater.offer` logs and returns `IGNORED` | `core/crypto/.../ManifestVerifier.kt:16-30`, `core/data/.../sync/ManifestUpdater.kt:40-52` |
| Links in text | only `NewsBubble` (`urlRegex`, `LinkAnnotation.Clickable`); `MessageBubble` shows plain `Text` | `feature/conversation/.../NewsBubble.kt:54-101`, `MessageBubble.kt:126,132` |
| DB | Room version 9, AutoMigrations only | `core/database/.../OtterDatabase.kt:48-51` |
| Settings storage | Room `settings` table (`Settings.kt`, `putInt`/`observeInt`) | `core/data/.../settings/Settings.kt` |
| Shared vectors | `scripts/sync-proto.sh` copies server `testdata/vectors/*.json` to `core/{crypto,signal,network}/src/test/resources/vectors/` | `otter-android/scripts/sync-proto.sh:6-10` |
| Last decision | D134 → this plan uses **D135–D139** | `docs/00-decisions.md` |

## Decisions this plan adds (owner sees them in Task 12)

- **D135 Visible set.** `directory.sync` and `directory.list` return: own entry, entries with signed `listed = true`,
  the direct inviter and invitees (from `redemptions`, following re-keys both ways), and, for each of these, its
  **invite ancestry** (inviter, inviter's inviter, … up to a founding member or the network) and **rivals** (other
  redemptions of the same invite, so D102 still works on the phone); plus every REVOCATION, INVITE_RIGHTS and REKEY
  as today. Ancestry entries are stored on the phone but never shown in its catalog. Consequence: a phone holds
  the entries of its contacts' inviters (usually the family heads and the admin).
- **D136 Phone catalog.** «Написать» and the group pickers show a contact only if: its signed entry has `listed`,
  or it is my direct inviter or invitee (checked from the signed invite chain), or a 1:1 conversation with it exists,
  or it is in a group with me. A node that lists an unlisted member therefore changes nothing on screen.
- **D137 `directory.get` and `directory.lookup`.** `get{user_ids ≤ 256}` returns those entries plus their ancestry
  (ids are random 16 bytes, learned from chats and groups; no extra limit). `lookup{username}` returns one exact match
  plus ancestry, or NOT_FOUND; 30 per hour and 200 per day per account, failed lookups included (QUOTA). Revoked
  accounts are not found. The phone looks at its own store first and only then asks the node.
- **D138 Directory event stays a broadcast.** The `directory` event carries no data. Targeting it (spec) would stop
  chat partners from learning a new display name, so every logged-in phone still gets it and then refreshes its own
  visible set and its chat/group partners by id. **This differs from the spec's line "the event goes only to …".**
- **D139 Network code and node versions.** Code = first 8 bytes of `SHA-256("otter-network-code" ‖ network_pub)`,
  big-endian, mod 10^15, zero-padded, `ddddd ddddd ddddd`. `LoginResponse.server_version` tells a logged-in phone the
  node's version (strangers never see it);
  «Состояние сети» shows each node's last seen version. A manifest signed for another network shows «Сеть
  изменилась» once per session (not persisted: one hostile node must not lock the app on every node).

Spec deviations recorded above: the clash tag has 8 hex digits; `directory.list` has no `since` (no code ever had it);
the event stays a broadcast (D138); old apps (≤ 0.10.1) also receive the ancestry entries and, having no catalog
filter, show them until they update.

## Branches, worktrees, commits

```bash
cd ~/Documents/Projects/OttterMSG
for r in otter-server otter-android docs; do
  git -C $r fetch origin && git -C $r worktree add ../$r-m95 -b m9-5-privacy origin/main
done
```
Work only in `otter-server-m95`, `otter-android-m95`, `docs-m95`. Commit with the `oc` function (copy it from
`docs/superpowers/plans/2026-11-15-m9-0b-frozen-links.md:72-85`; UTC 12:00:SS dates, D57). Every message ends with
`-m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`; never a `Claude-Session:` line.
Env: `export PATH=/usr/lib/go-1.26/bin:$HOME/go/bin:$PATH`, `export JAVA_HOME=~/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2`.
**Laptop limits:** `go test -p 4`, heavy runs under `nice -n 15 ionice -c3`, never Go race tests, Gradle and an
emulator at the same time; prefer the targeted test commands given in each task.

## File map

Server (`otter-server-m95/`):
- `proto/otter/v1/records.proto`, `api.proto` — `listed`, `LoginResponse.server_version`, `DirectoryGetRequest`, `DirectoryLookupRequest`
- `internal/netcode/netcode.go` (+ test) — network code; `testdata/vectors/network_code.json`
- `cmd/otter-admin/main.go` — `network code`
- `internal/store/visibility.go` (+ test) — relation queries
- `internal/service/visibility.go` (+ test) — visible set, ancestry closure, get, lookup
- `internal/gateway/methods.go`, `gateway.go`, `cmd/otter-node/main.go` — methods, version in the login answer
- `internal/gateway/privacy_test.go` — end-to-end

App (`otter-android-m95/`):
- `core/proto/...` (synced), `core/network/.../NodeApi.kt` — new calls + old-node fallback
- `core/data/src/test/.../FakeNode.kt`, `FakeNodeTransport.kt` — fake node support
- `core/crypto/.../NetworkCode.kt` (+ test)
- `core/database/.../ContactEntity.kt`, `ContactDao.kt`, `OtterDatabase.kt` (v10) — `listed`, `related`, catalog query
- `core/data/.../directory/DirectorySync.kt`, `ContactRepository.kt`, `MailboxReceiver.kt`, `GroupApplier.kt`
- `core/data/.../directory/UsernameLookup.kt` (new)
- `core/data/.../account/DirectoryEntries.kt`, `profile/ProfileRepository.kt`, `settings/Settings.kt`
- `core/data/.../sync/ManifestUpdater.kt`, `SyncEngine.kt`, `network/NetworkStatus.kt`
- `app/.../MainActivity.kt`, `app/.../NetworkChangedScreen.kt` (new)
- `feature/onboarding/...` (code on join), `feature/settings/...` (switch, share, «Сеть»), `feature/chats/...` (search, card), `feature/conversation/...` (`@username` links), `feature/groups/...` (catalog)

---

### Task 1: Server protos, network code, `otter-admin network code`

**Goal:** The wire format has `listed`, `server_version` and the two request messages; Go can compute the network code
and the admin can print it.

**Files:**
- Modify: `otter-server-m95/proto/otter/v1/records.proto`, `proto/otter/v1/api.proto`; regenerate `internal/proto/otterv1/*.pb.go`
- Create: `otter-server-m95/internal/netcode/netcode.go`, `internal/netcode/netcode_test.go`, `testdata/vectors/network_code.json`
- Modify: `otter-server-m95/cmd/otter-admin/main.go` (usage const and the `switch a[0] + " " + a[1]` at ~135), `cmd/otter-admin/main_test.go`

**Acceptance Criteria:**
- [ ] `DirectoryEntry.listed = 12`, `LoginResponse.server_version = 4`, `DirectoryGetRequest{repeated bytes user_ids = 1}`, `DirectoryLookupRequest{string username = 1}` exist and `make gen` is clean (buf lint passes).
- [ ] `netcode.Code` matches all three vectors.
- [ ] `otter-admin --dir D network code` prints `network code: ddddd ddddd ddddd` without asking for a passphrase.

**Verify:** `cd otter-server-m95 && go test -p 4 ./internal/netcode/ ./cmd/otter-admin/ -run 'Code|NetworkCode'` → `ok` twice

**Steps:**

- [ ] **Step 1: Protos.** In `records.proto`, inside `message DirectoryEntry` after `invite_proof = 11;`:
```proto
  bool listed = 12;          // M9.5 (D135): «Показывать меня в каталоге сети»; signed by the account, default off
```
In `api.proto`, inside `message LoginResponse` after `Record install = 3;`:
```proto
  string server_version = 4;   // M9.5 (D139): the node's release, e.g. "0.11.0"; members only, information only (a node can lie)
```
and after `message RecordBatch { … }`:
```proto
// directory.get (M9.5, D137): entries for known ids, at most 256.
message DirectoryGetRequest {
  repeated bytes user_ids = 1;
}

// directory.lookup (M9.5, D137): one exact username, "name" or "name#1a2b3c4d"; answer is a RecordBatch.
message DirectoryLookupRequest {
  string username = 1;
}
```
Run `make gen`; expect no
lint error and changed `internal/proto/otterv1/records.pb.go`, `api.pb.go`.

- [ ] **Step 2: Failing test** `internal/netcode/netcode_test.go`:
```go
package netcode

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
)

func TestCodeVectors(t *testing.T) {
	raw, err := os.ReadFile("../../testdata/vectors/network_code.json")
	if err != nil {
		t.Fatal(err)
	}
	var vs []struct {
		NetworkPub string `json:"network_pub"`
		Code       string `json:"code"`
	}
	if err := json.Unmarshal(raw, &vs); err != nil || len(vs) != 3 {
		t.Fatalf("vectors: %v (%d)", err, len(vs))
	}
	for _, v := range vs {
		pub, _ := hex.DecodeString(v.NetworkPub)
		if got := Code(pub); got != v.Code {
			t.Errorf("Code(%s…) = %q, want %q", v.NetworkPub[:8], got, v.Code)
		}
	}
}
```
and `testdata/vectors/network_code.json` (values computed independently with Python's hashlib):
```json
[
  {"network_pub": "0000000000000000000000000000000000000000000000000000000000000000", "code": "92144 18366 54483"},
  {"network_pub": "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20", "code": "23184 67527 63503"},
  {"network_pub": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "code": "40464 54489 28113"}
]
```
Run `go test ./internal/netcode/` → FAIL `undefined: Code`.

- [ ] **Step 3: Implement** `internal/netcode/netcode.go`:
```go
// Package netcode derives the network code a new member compares with the person who invited them (M9.5, D139).
package netcode

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
)

// Code returns "ddddd ddddd ddddd": the first 8 bytes of SHA-256("otter-network-code" ‖ networkPub), big-endian,
// mod 10^15, zero-padded. Digits read the same in every language and over the phone.
func Code(networkPub []byte) string {
	h := sha256.Sum256(append([]byte("otter-network-code"), networkPub...))
	s := fmt.Sprintf("%015d", binary.BigEndian.Uint64(h[:8])%1_000_000_000_000_000)
	return s[:5] + " " + s[5:10] + " " + s[10:]
}
```
Run → PASS.

- [ ] **Step 4: Admin command test** in `cmd/otter-admin/main_test.go`:
```go
func TestNetworkCode(t *testing.T) {
	dir := t.TempDir()
	var out bytes.Buffer
	if err := run([]string{"--dir", dir, "network", "init"}, &out, strings.NewReader("")); err != nil {
		t.Fatal(err)
	}
	st, err := admin.LoadState(dir)
	if err != nil {
		t.Fatal(err)
	}
	out.Reset()
	if err := run([]string{"--dir", dir, "network", "code"}, &out, strings.NewReader("")); err != nil {
		t.Fatal(err)
	}
	if want := "network code: " + netcode.Code(st.NetworkPub) + "\n"; out.String() != want {
		t.Fatalf("got %q, want %q", out.String(), want)
	}
}
```
(`network init` needs the passphrase env that `TestCLIFlow` sets; copy its `t.Setenv("OTTER_ADMIN_PASSPHRASE", …)`
line to the top of this test. Add imports `ottermsg/server/internal/admin` and `ottermsg/server/internal/netcode` if
missing.) Run → FAIL `unknown command`.

- [ ] **Step 5: Implement** in `main.go`'s switch, next to `case "network init":`:
```go
	case "network code":
		st, err := admin.LoadState(*dir)
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "network code: %s\n", netcode.Code(st.NetworkPub))
		return nil
```
and in the `usage` const under `network init`: `  network code                 print the 15-digit network code members compare when joining`.
Run the Verify command → `ok`.

- [ ] **Step 6: Commit**
```bash
git add proto internal/proto internal/netcode testdata/vectors/network_code.json cmd/otter-admin
oc -m "proto: DirectoryEntry.listed, LoginResponse.server_version, directory.get/lookup requests; network code (M9.5)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Server visible set (store relations, ancestry closure)

**Goal:** `Service.VisibleDirectory(ctx, user)` returns exactly the D135 set; `Service.Directory` stays complete.

**Files:**
- Create: `otter-server-m95/internal/store/visibility.go`, `internal/store/visibility_test.go`
- Create: `otter-server-m95/internal/service/visibility.go`, `internal/service/visibility_test.go`

**Acceptance Criteria:**
- [ ] A invites B, B invites C, D is network-invited and unlisted, E is listed: A sees {A, B, E}; B sees {A, B, C, E}; C sees {B, C, E} **plus A as ancestry** (A is B's inviter); D sees {D, E}.
- [ ] Every answer contains all REVOCATION, INVITE_RIGHTS and REKEY records, as `Directory` does.
- [ ] A re-keyed account keeps its relations: if B re-keys to B2, A sees B2 (and the revoked B).
- [ ] An unlisted member never appears for an unrelated caller unless as ancestry of someone the caller may see.
- [ ] `Directory(ctx)` output is unchanged (admin list).

**Verify:** `go test -p 4 ./internal/store/ ./internal/service/ -run 'Visib|Relations'` → `ok` twice

**Steps:**

- [ ] **Step 1: Store queries** `internal/store/visibility.go`:
```go
package store

import "context"

// DirRow is one member's current directory entry (the raw Record).
type DirRow struct {
	UserID []byte
	Raw    []byte
}

// DirectoryRows returns every member's current entry with its id, in DirectoryEntries order.
func (s *Store) DirectoryRows(ctx context.Context) ([]DirRow, error) {
	rows, err := s.r.QueryContext(ctx,
		`SELECT u.user_id, r.raw FROM users u JOIN records r ON r.record_key=u.entry_key ORDER BY u.created_ms, u.user_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []DirRow
	for rows.Next() {
		var d DirRow
		if err := rows.Scan(&d.UserID, &d.Raw); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

func (s *Store) ids(ctx context.Context, q string, args ...any) ([][]byte, error) {
	rows, err := s.r.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out [][]byte
	for rows.Next() {
		var id []byte
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// Inviters: who redeemed-for user (the INVITE authors; the network's id16 for a bootstrap invite). Founding: none.
func (s *Store) Inviters(ctx context.Context, user []byte) ([][]byte, error) {
	return s.ids(ctx, `SELECT inviter FROM redemptions WHERE user_id=?`, user)
}

// Invitees: members who redeemed an invite written by user.
func (s *Store) Invitees(ctx context.Context, user []byte) ([][]byte, error) {
	return s.ids(ctx, `SELECT user_id FROM redemptions WHERE inviter=?`, user)
}

// Rivals: other members who redeemed the same invite as user (D102 needs all of them on the phone).
func (s *Store) Rivals(ctx context.Context, user []byte) ([][]byte, error) {
	return s.ids(ctx, `SELECT b.user_id FROM redemptions a JOIN redemptions b ON a.invite_id=b.invite_id
		WHERE a.user_id=? AND b.user_id<>a.user_id`, user)
}

// RekeyedTo: the new account of old (nil when none). RekeyedFrom: the old accounts that moved to newID.
func (s *Store) RekeyedTo(ctx context.Context, old []byte) ([]byte, error) {
	ids, err := s.ids(ctx, `SELECT new_user_id FROM rekeys WHERE old_user_id=?`, old)
	if err != nil || len(ids) == 0 {
		return nil, err
	}
	return ids[0], nil
}

func (s *Store) RekeyedFrom(ctx context.Context, newID []byte) ([][]byte, error) {
	return s.ids(ctx, `SELECT old_user_id FROM rekeys WHERE new_user_id=?`, newID)
}
```
Before writing, confirm the column names with `sqlite3`-free reading of `internal/store/migrations/0011_membership.sql`
and `0015_rekeys.sql` (`redemptions(invite_id, user_id, rank, inviter)`, `rekeys(old_user_id, new_user_id, …)`).

- [ ] **Step 2: Store test** `internal/store/visibility_test.go` — build the chain through the service fixture is
not possible from package `store`, so test the SQL directly on a fresh store with raw inserts:
```go
package store

import (
	"bytes"
	"context"
	"testing"
)

func TestRelations(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	a, b, c, d := []byte("aaaaaaaaaaaaaaaa"), []byte("bbbbbbbbbbbbbbbb"), []byte("cccccccccccccccc"), []byte("dddddddddddddddd")
	for _, q := range []struct {
		inv, user, inviter []byte
	}{{[]byte("i1"), b, a}, {[]byte("i2"), c, b}, {[]byte("i2"), d, b}} {
		if _, err := s.w.ExecContext(ctx, `INSERT INTO redemptions(invite_id,user_id,rank,inviter) VALUES(?,?,?,?)`,
			q.inv, q.user, []byte{1}, q.inviter); err != nil {
			t.Fatal(err)
		}
	}
	if got, _ := s.Inviters(ctx, c); len(got) != 1 || !bytes.Equal(got[0], b) {
		t.Fatalf("inviters of c: %x", got)
	}
	if got, _ := s.Invitees(ctx, b); len(got) != 2 {
		t.Fatalf("invitees of b: %x", got)
	}
	if got, _ := s.Rivals(ctx, c); len(got) != 1 || !bytes.Equal(got[0], d) {
		t.Fatalf("rivals of c: %x", got)
	}
	if got, _ := s.RekeyedTo(ctx, a); got != nil {
		t.Fatalf("rekeyed: %x", got)
	}
}
```
Use the package's existing test opener: `grep -n "func open.*testing.T\|func newTestStore\|func testStore" internal/store/*_test.go`
and replace `openTestStore(t)` with it; the write handle is `s.w` if `grep -n "w \*sql.DB\|w  *\*sql" internal/store/store.go`
confirms, else use the field it shows. Run → PASS (queries were written in Step 1; this pins them).

- [ ] **Step 3: Failing service test** `internal/service/visibility_test.go`:
```go
package service

import (
	"context"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"
	pb "ottermsg/server/internal/proto/otterv1"
)

// entryUsers returns the user ids of the DIRECTORY_ENTRY records in recs, and how many other records there are.
func entryUsers(t *testing.T, recs []*pb.Record) (map[string]bool, int) {
	t.Helper()
	ids, other := map[string]bool{}, 0
	for _, r := range recs {
		var b pb.RecordBody
		if err := proto.Unmarshal(r.Body, &b); err != nil {
			t.Fatal(err)
		}
		if b.Type != pb.RecordType_DIRECTORY_ENTRY {
			other++
			continue
		}
		ids[string(b.Author)] = true
	}
	return ids, other
}

func TestVisibleDirectory(t *testing.T) {
	f := newFx(t)
	ctx := context.Background()
	a := f.mustRegister(f.invite(nil, time.Hour), "anna")
	b := f.mustRegister(f.invite(a, time.Hour), "boris")
	c := f.mustRegister(f.invite(b, time.Hour), "clara")
	d := f.mustRegister(f.invite(nil, time.Hour), "dima")
	e := f.mustRegister(f.invite(nil, time.Hour), "elena")
	listed := entryV(e, "elena", "Елена", 2, 1)
	listed.Listed = true
	if err := f.svc.UpdateDirectoryEntry(ctx, e.id, sign(t, pb.RecordType_DIRECTORY_ENTRY, e.id, listed, e.priv)); err != nil {
		t.Fatal(err)
	}
	want := map[*user][]*user{a: {a, b, e}, b: {a, b, c, e}, c: {a, b, c, e}, d: {d, e}}
	names := map[string]string{string(a.id): "anna", string(b.id): "boris", string(c.id): "clara", string(d.id): "dima", string(e.id): "elena"}
	for who, ws := range want {
		recs, err := f.svc.VisibleDirectory(ctx, who.id)
		if err != nil {
			t.Fatal(err)
		}
		got, _ := entryUsers(t, recs)
		if len(got) != len(ws) {
			t.Errorf("%s sees %d entries, want %d", names[string(who.id)], len(got), len(ws))
		}
		for _, w := range ws {
			if !got[string(w.id)] {
				t.Errorf("%s does not see %s", names[string(who.id)], names[string(w.id)])
			}
		}
	}
	all, _ := f.svc.Directory(ctx)
	if got, _ := entryUsers(t, all); len(got) != 5 {
		t.Fatalf("Directory (admin) shows %d entries, want 5", len(got))
	}
}

func TestVisibleDirectoryCarriesMembershipRecords(t *testing.T) {
	f := newFx(t)
	ctx := context.Background()
	a := f.mustRegister(f.invite(nil, time.Hour), "anna")
	b := f.mustRegister(f.invite(nil, time.Hour), "boris")
	f.netRecord(pb.RecordType_REVOCATION, &pb.Revocation{UserId: b.id, Reason: "test"})
	recs, err := f.svc.VisibleDirectory(ctx, a.id)
	if err != nil {
		t.Fatal(err)
	}
	if _, other := entryUsers(t, recs); other != 1 {
		t.Fatalf("membership records: %d, want 1 (the REVOCATION)", other)
	}
}
```
(`sign` is the helper `directory_test.go` uses; `f.netRecord` is in `membership_test.go:75`.) Run → FAIL
`f.svc.VisibleDirectory undefined`.

- [ ] **Step 4: Implement** `internal/service/visibility.go`:
```go
package service

import (
	"context"

	"google.golang.org/protobuf/proto"
	pb "ottermsg/server/internal/proto/otterv1"
)

// entryListed reports the signed `listed` flag of a raw DIRECTORY_ENTRY Record (false when unreadable).
func entryListed(raw []byte) bool {
	var r pb.Record
	var b pb.RecordBody
	var e pb.DirectoryEntry
	if proto.Unmarshal(raw, &r) != nil || proto.Unmarshal(r.Body, &b) != nil || proto.Unmarshal(b.Payload, &e) != nil {
		return false
	}
	return e.Listed
}

type idSet map[string]bool

func (s idSet) add(ids ...[]byte) {
	for _, id := range ids {
		s[string(id)] = true
	}
}

// related: the direct inviter(s) and invitees of user, following re-keys (D111) both ways (D135).
func (s *Service) related(ctx context.Context, user []byte) (idSet, error) {
	lineage, todo := idSet{}, [][]byte{user}
	for len(todo) > 0 { // user and every older account that was re-keyed into it
		id := todo[0]
		todo = todo[1:]
		if lineage[string(id)] {
			continue
		}
		lineage.add(id)
		olds, err := s.Store.RekeyedFrom(ctx, id)
		if err != nil {
			return nil, err
		}
		todo = append(todo, olds...)
	}
	out := idSet{}
	for l := range lineage {
		for _, q := range []func(context.Context, []byte) ([][]byte, error){s.Store.Inviters, s.Store.Invitees} {
			ids, err := q(ctx, []byte(l))
			if err != nil {
				return nil, err
			}
			for _, id := range ids {
				for cur, n := id, 0; cur != nil && n < 16; n++ { // the account and every newer one it moved to
					out.add(cur)
					next, err := s.Store.RekeyedTo(ctx, cur)
					if err != nil {
						return nil, err
					}
					cur = next
				}
			}
		}
	}
	return out, nil
}

// closure adds what a phone needs to admit the seeds (D104, D135): every invite ancestor, every rival redemption of
// the same invite (D102) and every older account of a re-keyed one.
func (s *Service) closure(ctx context.Context, seeds idSet) (idSet, error) {
	out, todo := idSet{}, make([][]byte, 0, len(seeds))
	for id := range seeds {
		todo = append(todo, []byte(id))
	}
	for len(todo) > 0 {
		id := todo[0]
		todo = todo[1:]
		if out[string(id)] {
			continue
		}
		out.add(id)
		for _, q := range []func(context.Context, []byte) ([][]byte, error){s.Store.Inviters, s.Store.Rivals, s.Store.RekeyedFrom} {
			more, err := q(ctx, id)
			if err != nil {
				return nil, err
			}
			todo = append(todo, more...)
		}
	}
	return out, nil
}

// entries returns the current entries of the members in keep (ids without an entry, such as the network's id16
// as a bootstrap inviter, are skipped).
func (s *Service) entries(ctx context.Context, keep idSet) ([]*pb.Record, error) {
	rows, err := s.Store.DirectoryRows(ctx)
	if err != nil {
		return nil, err
	}
	var out []*pb.Record
	for _, row := range rows {
		if !keep[string(row.UserID)] {
			continue
		}
		r := &pb.Record{}
		if err := proto.Unmarshal(row.Raw, r); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, nil
}

// VisibleDirectory is what directory.sync and directory.list return to user (D135): own entry, listed members,
// direct inviter and invitees, the ancestry of all of these, and every REVOCATION, INVITE_RIGHTS and REKEY.
func (s *Service) VisibleDirectory(ctx context.Context, user []byte) ([]*pb.Record, error) {
	rows, err := s.Store.DirectoryRows(ctx)
	if err != nil {
		return nil, err
	}
	seeds, err := s.related(ctx, user)
	if err != nil {
		return nil, err
	}
	seeds.add(user)
	for _, row := range rows {
		if entryListed(row.Raw) {
			seeds.add(row.UserID)
		}
	}
	keep, err := s.closure(ctx, seeds)
	if err != nil {
		return nil, err
	}
	out, err := s.entries(ctx, keep)
	if err != nil {
		return nil, err
	}
	extra, err := s.membershipRecords(ctx)
	if err != nil {
		return nil, err
	}
	return append(out, extra...), nil
}
```
Then refactor `Directory` in `service.go:252-277`: move its "MembershipRecords + Rekeys" part into
`func (s *Service) membershipRecords(ctx context.Context) ([]*pb.Record, error)` (same code, same order) and call it
from both `Directory` and `VisibleDirectory`. Run the Verify command → `ok`.

- [ ] **Step 5: Re-key test** — append to `visibility_test.go`, using the REKEY helper already in
`rekey_test.go` (`grep -n "^func (f \*fx).*[Rr]ekey\|^func rekey" internal/service/rekey_test.go`); the test re-keys
`b` to a new account `b2` with that helper and asserts `entryUsers(VisibleDirectory(a.id))` contains `b2.id` and
`b.id`. Name it `TestVisibleDirectoryFollowsRekey`. Run → PASS.

- [ ] **Step 6: Commit**
```bash
git add internal/store/visibility.go internal/store/visibility_test.go internal/service/visibility.go internal/service/visibility_test.go internal/service/service.go
oc -m "service: visible directory set with invite ancestry (M9.5, D135)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Server `DirectoryGet` and `LookupUsername`

**Goal:** Fetch entries by id and one exact username, with ancestry, under the lookup limit.

**Files:**
- Modify: `otter-server-m95/internal/service/visibility.go`, `internal/service/service.go` (two `windowCounter` fields)
- Test: `otter-server-m95/internal/service/visibility_test.go`

**Acceptance Criteria:**
- [ ] `DirectoryGet` with > 256 ids → `ErrInvalid`; with known ids → their entries plus ancestry; unknown ids are skipped.
- [ ] `LookupUsername("@Boris")` finds `boris` (case, `@`, spaces ignored); `name#tag` resolves through `ResolveUsername`; unknown or revoked → `ErrNotFound`.
- [ ] The 31st lookup within an hour → `ErrQuota`, failed lookups count; the day limit is 200.

**Verify:** `go test -p 4 ./internal/service/ -run 'DirectoryGet|Lookup'` → `ok`

**Steps:**

- [ ] **Step 1: Failing tests** (append to `visibility_test.go`; add imports `errors`, `fmt`):
```go
func TestDirectoryGet(t *testing.T) {
	f := newFx(t)
	ctx := context.Background()
	a := f.mustRegister(f.invite(nil, time.Hour), "anna")
	b := f.mustRegister(f.invite(a, time.Hour), "boris")
	recs, err := f.svc.DirectoryGet(ctx, [][]byte{b.id, []byte("unknown-id-16byt")})
	if err != nil {
		t.Fatal(err)
	}
	if got, other := entryUsers(t, recs); len(got) != 2 || !got[string(a.id)] || !got[string(b.id)] || other != 0 {
		t.Fatalf("get boris: %d entries (want boris + inviter anna), %d other", len(got), other)
	}
	if _, err := f.svc.DirectoryGet(ctx, make([][]byte, MaxDirectoryGet+1)); !errors.Is(err, ErrInvalid) {
		t.Fatalf("too many ids: %v", err)
	}
}

func TestLookupUsername(t *testing.T) {
	f := newFx(t)
	ctx := context.Background()
	a := f.mustRegister(f.invite(nil, time.Hour), "anna")
	b := f.mustRegister(f.invite(nil, time.Hour), "boris")
	recs, err := f.svc.LookupUsername(ctx, a.id, "  @Boris ")
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := entryUsers(t, recs); !got[string(b.id)] {
		t.Fatal("boris not found")
	}
	for _, q := range []string{"nobody", "x", "boris#zz", ""} {
		if _, err := f.svc.LookupUsername(ctx, a.id, q); !errors.Is(err, ErrNotFound) {
			t.Errorf("%q: %v, want not found", q, err)
		}
	}
	f.netRecord(pb.RecordType_REVOCATION, &pb.Revocation{UserId: b.id, Reason: "test"})
	if _, err := f.svc.LookupUsername(ctx, a.id, "boris"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("revoked: %v", err)
	}
}

func TestLookupLimit(t *testing.T) {
	f := newFx(t)
	ctx := context.Background()
	a := f.mustRegister(f.invite(nil, time.Hour), "anna")
	for i := 0; i < LookupsPerHour-1; i++ {
		if _, err := f.svc.LookupUsername(ctx, a.id, fmt.Sprintf("nobody%d", i)); !errors.Is(err, ErrNotFound) {
			t.Fatalf("lookup %d: %v", i, err)
		}
	}
	if _, err := f.svc.LookupUsername(ctx, a.id, "anna"); err != nil {
		t.Fatalf("30th lookup: %v", err)
	}
	if _, err := f.svc.LookupUsername(ctx, a.id, "anna"); !errors.Is(err, ErrQuota) {
		t.Fatalf("31st lookup: %v, want quota", err)
	}
}
```
Run → FAIL `undefined: f.svc.DirectoryGet` / `LookupUsername` / `MaxDirectoryGet` / `LookupsPerHour`.

- [ ] **Step 2: Implement.** In `service.go`, next to `submits windowCounter`:
```go
	lookupsHour windowCounter // directory.lookup per account per hour (D137)
	lookupsDay  windowCounter // directory.lookup per account per day (D137)
```
Append to `visibility.go` (add imports `encoding/hex`, `fmt`, `regexp`, `strings`, `time`):
```go
// Limits of D137.
const (
	MaxDirectoryGet = 256
	LookupsPerHour  = 30
	LookupsPerDay   = 200
)

var lookupRe = regexp.MustCompile(`^[a-z0-9_]{3,32}(#[0-9a-f]{8})?$`)

// DirectoryGet returns the entries of known ids plus their ancestry (D137). Ids are random 16 bytes learned from a
// chat or group, so there is no extra limit; unknown ids are skipped.
func (s *Service) DirectoryGet(ctx context.Context, ids [][]byte) ([]*pb.Record, error) {
	if len(ids) > MaxDirectoryGet {
		return nil, fmt.Errorf("%w: at most %d ids", ErrInvalid, MaxDirectoryGet)
	}
	seeds := idSet{}
	seeds.add(ids...)
	keep, err := s.closure(ctx, seeds)
	if err != nil {
		return nil, err
	}
	return s.entries(ctx, keep)
}

// LookupUsername finds one exact username ("name" or "name#1a2b3c4d", any case, an optional "@") for user and
// returns its entry plus ancestry (D137). Every call counts, found or not.
func (s *Service) LookupUsername(ctx context.Context, user []byte, typed string) ([]*pb.Record, error) {
	now, key := time.Now(), hex.EncodeToString(user)
	if !s.lookupsHour.allow(now, time.Hour, key, LookupsPerHour) || !s.lookupsDay.allow(now, 24*time.Hour, key, LookupsPerDay) {
		return nil, fmt.Errorf("%w: at most %d username lookups an hour and %d a day", ErrQuota, LookupsPerHour, LookupsPerDay)
	}
	q := strings.ToLower(strings.TrimPrefix(strings.TrimSpace(typed), "@"))
	if !lookupRe.MatchString(q) {
		return nil, fmt.Errorf("%w: user", ErrNotFound)
	}
	stored := q
	if strings.Contains(q, "#") {
		name, _, err := s.Store.ResolveUsername(ctx, q)
		if err != nil {
			return nil, err
		}
		stored = name
	}
	id, err := s.Store.UsernameOwner(ctx, stored)
	if err != nil || id == nil {
		return nil, fmt.Errorf("%w: user", ErrNotFound)
	}
	u, err := s.Store.UserByID(ctx, id)
	if err != nil {
		return nil, err
	}
	if u == nil || u.Revoked {
		return nil, fmt.Errorf("%w: user", ErrNotFound)
	}
	return s.DirectoryGet(ctx, [][]byte{id})
}
```
Check `UsernameOwner`'s not-found result (`store/query.go:71`): if it returns `ErrNotFound`/`sql.ErrNoRows` instead
of `nil, nil`, the `err != nil` branch above already maps it to NOT_FOUND. Run the Verify command → `ok`.

- [ ] **Step 3: Commit**
```bash
git add internal/service/visibility.go internal/service/visibility_test.go internal/service/service.go
oc -m "service: directory get by id and exact username lookup, 30/h 200/day (M9.5, D137)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Server gateway methods and the version in the login answer

**Goal:** `directory.sync`/`directory.list` filtered, `directory.get`, `directory.lookup` callable, `LoginResponse.server_version` set.

**Files:**
- Modify: `otter-server-m95/internal/gateway/methods.go` (cases at ~221/233), `internal/gateway/gateway.go` (`Gateway` struct), the `auth.login` case in `methods.go` (~149-164), `cmd/otter-node/main.go` (after `gw := gateway.New(a.svc, a.log)` at ~325)
- Create: `otter-server-m95/internal/gateway/privacy_test.go`

**Acceptance Criteria:**
- [ ] Over the wire, `directory.sync` and `directory.list` return the same filtered set; `admin.users` still returns all.
- [ ] `directory.lookup` for an unknown name → `STATUS_NOT_FOUND`; the 31st → `STATUS_QUOTA`.
- [ ] `LoginResponse.server_version` equals the binary's version; `hello` carries no version.
- [ ] `directory.lookup` is in the per-user write bucket (`userWrites`) as a second brake.

**Verify:** `go test -p 4 ./internal/gateway/ -run 'Privacy|LoginVersion'` → `ok`

**Steps:**

- [ ] **Step 1: Failing test** `internal/gateway/privacy_test.go`:
```go
package gateway

import (
	"testing"

	pb "ottermsg/server/internal/proto/otterv1"
)

func TestPrivacyMethods(t *testing.T) {
	n := startNode(t)
	us := members(t, n, "anna", "boris") // both network-invited: unrelated, unlisted
	anna := us[0]
	var listResp, syncResp pb.RecordBatch
	if st, msg := anna.c.call("directory.list", &pb.Empty{}, &listResp); st != pb.Status_STATUS_OK {
		t.Fatalf("list: %v %s", st, msg)
	}
	anna.c.call("directory.sync", &pb.Empty{}, &syncResp)
	if len(listResp.Records) != len(syncResp.Records) {
		t.Fatalf("list %d != sync %d", len(listResp.Records), len(syncResp.Records))
	}
	if displayNameOf(t, listResp.Records, us[1].a.id) != "" {
		t.Fatal("anna sees unrelated, unlisted boris")
	}
	var found pb.RecordBatch
	if st, msg := anna.c.call("directory.lookup", &pb.DirectoryLookupRequest{Username: "boris"}, &found); st != pb.Status_STATUS_OK {
		t.Fatalf("lookup: %v %s", st, msg)
	}
	if displayNameOf(t, found.Records, us[1].a.id) == "" {
		t.Fatal("lookup did not return boris")
	}
	if st, _ := anna.c.call("directory.lookup", &pb.DirectoryLookupRequest{Username: "nobody"}, nil); st != pb.Status_STATUS_NOT_FOUND {
		t.Fatalf("unknown: %v", st)
	}
	var got pb.RecordBatch
	if st, _ := anna.c.call("directory.get", &pb.DirectoryGetRequest{UserIds: [][]byte{us[1].a.id}}, &got); st != pb.Status_STATUS_OK || len(got.Records) != 1 {
		t.Fatalf("get: %v %d", st, len(got.Records))
	}
}

func TestLoginVersion(t *testing.T) {
	n := startNode(t, func(g *Gateway) { g.Version = "9.9.9" })
	c := dial(t, n)
	a := newTestUser(t, n, "anna")
	resp := loginResp(t, c, a)
	if resp.ServerVersion != "9.9.9" {
		t.Fatalf("server_version %q", resp.ServerVersion)
	}
}
```
Adapt the two helper uses to the real ones before running: `members(t, n, names...)` in `blob_test.go:39` — read its
return type and use its client and account fields in place of `.c` and `.a.id`; `displayNameOf` returns `""` for a
missing user if `profile_test.go:75` does so, else write a local `hasEntry(t, recs, id) bool` with the
`entryUsers`-style loop from Task 2; `loginResp(t, c, a) *pb.LoginResponse` is `login(t, c, a)` from
`e2e_test.go:83` changed to return the decoded `LoginResponse` (make `login` call it so other tests keep working;
`newTestUser` returns the account `login` expects — adapt if its type differs).
Run → FAIL (`unknown method "directory.list"`, `g.Version undefined`).

- [ ] **Step 2: Implement.** `gateway.go`: add to `type Gateway struct` a field
`Version string // the release, told to logged-in members only (D139); set by otter-node` and in the `auth.login`
case, just before `return login, nil` (methods.go ~164): `login.ServerVersion = s.g.Version` (use however the session
reaches its `Gateway` — `grep -n "g \*Gateway\|gw \*Gateway" internal/gateway/session.go`).
`cmd/otter-node/main.go` after `gw := gateway.New(a.svc, a.log)`: `gw.Version = version`.
`methods.go`: replace the `directory.sync` case and add three:
```go
	case "directory.sync", "directory.list": // M9.5 (D135): the same filtered set for old and new apps
		recs, err := svc.VisibleDirectory(ctx, s.user)
		if err != nil {
			return nil, err
		}
		return &pb.RecordBatch{Records: recs}, nil
	case "directory.get":
		var r pb.DirectoryGetRequest
		if err := decode(req.Body, &r); err != nil {
			return nil, err
		}
		recs, err := svc.DirectoryGet(ctx, r.UserIds)
		if err != nil {
			return nil, err
		}
		return &pb.RecordBatch{Records: recs}, nil
	case "directory.lookup":
		var r pb.DirectoryLookupRequest
		if err := decode(req.Body, &r); err != nil {
			return nil, err
		}
		recs, err := svc.LookupUsername(ctx, s.user, r.Username)
		if err != nil {
			return nil, err
		}
		return &pb.RecordBatch{Records: recs}, nil
```
Add `"directory.lookup"` to the `userWrites` set (methods.go:22-23). Leave `admin.users` on `svc.Directory`. Run the
Verify command, then the whole package: `go test -p 4 ./internal/gateway/` → `ok` (existing tests that expected the
full directory from `directory.sync`, e.g. `profile_test.go`, still pass because they use related members; if one
fails because two unrelated users no longer see each other, give one an invite from the other in that test and say
so in the commit message).

- [ ] **Step 3: Full server suite** (one heavy job at a time):
`nice -n 15 ionice -c3 go test -race -p 4 ./...` → all `ok`; `go vet ./...` clean; `scripts/secrets-check.sh` → `secrets check: ok`.

- [ ] **Step 4: Commit**
```bash
git add internal/gateway cmd/otter-node/main.go
oc -m "gateway: filtered directory.sync/list, directory.get, directory.lookup, server version in the login answer (M9.5)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: App protos, `NodeApi` calls and old-node fallback, fake node

**Goal:** The app can call `directory.list/get/lookup`, falls back on an old node, and tests can serve all of it.

**Files:**
- Sync: `otter-android-m95/core/proto/src/main/proto/otter/v1/*.proto`, `core/{crypto,signal,network}/src/test/resources/vectors/` via `OTTER_SERVER_DIR=../otter-server-m95 scripts/sync-proto.sh`
- Modify: `otter-android-m95/core/network/src/main/kotlin/app/ottermsg/core/network/NodeApi.kt`
- Modify: `otter-android-m95/core/data/src/test/kotlin/app/ottermsg/core/data/FakeNode.kt`, `FakeNodeTransport.kt`
- Test: `otter-android-m95/core/network/src/test/kotlin/app/ottermsg/core/network/DirectoryFallbackTest.kt`

**Acceptance Criteria:**
- [ ] `NodeApi` has `directoryList()`, `directoryGet(ids)`, `directoryLookup(username)` with defaults that fall back to `directory()` (list, get) or throw `OldNodeException` (lookup).
- [ ] `RemoteNodeApi.directoryList()` on a node that answers `STATUS_INVALID "unknown method …"` calls `directory.sync` instead, and remembers that for the session.
- [ ] `directoryLookup` maps `STATUS_NOT_FOUND` → `null`, `STATUS_QUOTA` → `LookupLimitException`.
- [ ] `FakeNode` serves the three methods with the server's rules (visible set = own + listed + direct relation + ancestry).

**Verify:** `./gradlew :core:network:testDebugUnitTest --tests '*DirectoryFallback*' :core:data:testDebugUnitTest --tests '*DirectorySync*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Sync protos** `OTTER_SERVER_DIR=../otter-server-m95 scripts/sync-proto.sh`; `git diff --stat` shows the
two proto files and three copies of `network_code.json`.

- [ ] **Step 2: Failing test** `core/network/src/test/kotlin/app/ottermsg/core/network/DirectoryFallbackTest.kt`.
Find how existing network tests drive `RemoteNodeApi` with a fake RPC: `grep -rln "RemoteNodeApi(" core/network/src/test`.
Write the test with that fake so that `directory.list` answers `RpcException(Status.STATUS_INVALID, "unknown method \"directory.list\"")`
and `directory.sync` answers a `RecordBatch` with one record:
```kotlin
@Test fun listFallsBackToSyncOnAnOldNode() = runBlocking {
    val api = remoteWith(mapOf(
        "directory.list" to { throw RpcException(Status.STATUS_INVALID, "unknown method \"directory.list\"") },
        "directory.sync" to { RecordBatch.newBuilder().addRecords(sample).build().toByteString() },
    ))
    assertEquals(listOf(sample), api.directoryList())
    assertEquals(listOf(sample), api.directoryList()) // second call goes straight to sync
    assertEquals(1, calls.count { it == "directory.list" })
}

@Test fun lookupMapsStatuses() = runBlocking {
    val api = remoteWith(mapOf("directory.lookup" to { throw RpcException(Status.STATUS_NOT_FOUND, "user") }))
    assertNull(api.directoryLookup("nobody"))
    val limited = remoteWith(mapOf("directory.lookup" to { throw RpcException(Status.STATUS_QUOTA, "limit") }))
    assertThrows(LookupLimitException::class.java) { runBlocking { limited.directoryLookup("x") } }
    val old = remoteWith(mapOf("directory.lookup" to { throw RpcException(Status.STATUS_INVALID, "unknown method \"directory.lookup\"") }))
    assertThrows(OldNodeException::class.java) { runBlocking { old.directoryLookup("x") } }
}
```
`remoteWith`, `calls` and `sample` are local helpers over the fake found above (record each method name in `calls`).
If no such fake exists, make `RemoteNodeApi`'s RPC dependency an interface `fun interface Caller { suspend fun call(method: String, body: MessageLite): ByteString }`
that `RpcClient` already satisfies through a method reference, and pass a lambda in the test. Run → FAIL (unresolved).

- [ ] **Step 3: Implement** in `NodeApi.kt`. Interface (next to `directory()` at :45):
```kotlin
    /** M9.5 (D135): the caller's visible set; an old node's full `directory.sync` is the fallback. */
    suspend fun directoryList(): List<Record> = directory()
    /** M9.5 (D137): entries for known ids (≤ 256) plus their invite ancestry. */
    suspend fun directoryGet(ids: List<ByteArray>): List<Record> = directory()
    /** M9.5 (D137): one exact username plus ancestry; null = not found. */
    suspend fun directoryLookup(username: String): List<Record>? = throw OldNodeException()
```
Top level in the same file:
```kotlin
/** The node runs a release without this method (M9.5 rollout: nodes first, then the app). */
class OldNodeException : Exception("node too old")
/** directory.lookup refused: 30 an hour / 200 a day (D137). */
class LookupLimitException : Exception("lookup limit")

internal fun RpcException.isUnknownMethod() = status == Status.STATUS_INVALID && message.orEmpty().contains("unknown method")
```
In `RemoteNodeApi` (NodeApi.kt:86-146):
```kotlin
    @Volatile private var legacyDirectory = false

    override suspend fun directoryList(): List<Record> {
        if (!legacyDirectory) try {
            return RecordBatch.parseFrom(rpc.call("directory.list", Empty.getDefaultInstance())).recordsList
        } catch (e: RpcException) {
            if (!e.isUnknownMethod()) throw e
            legacyDirectory = true
        }
        return directory()
    }

    override suspend fun directoryGet(ids: List<ByteArray>): List<Record> {
        if (legacyDirectory) return directory()
        return try {
            ids.chunked(256).flatMap { part ->
                RecordBatch.parseFrom(rpc.call("directory.get",
                    DirectoryGetRequest.newBuilder().addAllUserIds(part.map { ByteString.copyFrom(it) }).build())).recordsList
            }
        } catch (e: RpcException) {
            if (!e.isUnknownMethod()) throw e
            legacyDirectory = true
            directory()
        }
    }

    override suspend fun directoryLookup(username: String): List<Record>? = try {
        RecordBatch.parseFrom(rpc.call("directory.lookup", DirectoryLookupRequest.newBuilder().setUsername(username).build())).recordsList
    } catch (e: RpcException) {
        when {
            e.status == Status.STATUS_NOT_FOUND -> null
            e.status == Status.STATUS_QUOTA -> throw LookupLimitException()
            e.isUnknownMethod() -> throw OldNodeException()
            else -> throw e
        }
    }
```
Run the network test → PASS.

- [ ] **Step 4: Fake node.** In `FakeNode.kt` `inner class Session` add overrides that apply the server rules to
`directoryRecords()` so data tests exercise them:
```kotlin
        override suspend fun directoryList(): List<Record> { check(); val me = me(); return visibleFor(me) }
        override suspend fun directoryGet(ids: List<ByteArray>): List<Record> { check(); me(); return withAncestry(ids.map { it.hex() }.toSet()) }
        override suspend fun directoryLookup(username: String): List<Record>? {
            check(); me()
            lookupAnswer?.let { return it(username) }
            val id = entries().firstOrNull { it.second.username == username.removePrefix("@").lowercase() }?.first ?: return null
            return withAncestry(setOf(id))
        }
```
with, in `FakeNode` (outer class): `@Volatile var lookupAnswer: ((String) -> List<Record>?)? = null`, and helpers:
```kotlin
    /** (user hex, entry) of every DIRECTORY_ENTRY in [directoryRecords]. */
    fun entries(): List<Pair<String, DirectoryEntry>> = directoryRecords().mapNotNull { r ->
        val b = RecordBody.parseFrom(r.body)
        if (b.type != RecordType.DIRECTORY_ENTRY) null else b.author.toByteArray().hex() to DirectoryEntry.parseFrom(b.payload)
    }
    /** Inviter of an entry from its signed invite record (null for network invites and founding members). */
    private fun inviterOf(e: DirectoryEntry): String? = if (e.inviteRecord.isEmpty) null
        else RecordBody.parseFrom(Record.parseFrom(e.inviteRecord).body).author.toByteArray().hex().takeIf { it != networkId16Hex }
    fun withAncestry(seeds: Set<String>): List<Record> {
        val byId = entries().toMap()
        val keep = HashSet<String>(); val todo = ArrayDeque(seeds)
        while (todo.isNotEmpty()) { val id = todo.removeFirst(); if (!keep.add(id)) continue; byId[id]?.let(::inviterOf)?.let(todo::add) }
        return directoryRecords().filter { r -> RecordBody.parseFrom(r.body).let { it.type == RecordType.DIRECTORY_ENTRY && it.author.toByteArray().hex() in keep } }
    }
    fun visibleFor(me: ByteArray): List<Record> {
        val mine = me.hex(); val all = entries()
        val seeds = all.filter { (id, e) -> id == mine || e.listed || inviterOf(e) == mine || all.any { (m, me2) -> m == mine && inviterOf(me2) == id } }
            .map { it.first }.toSet()
        val membership = directoryRecords().filter { RecordBody.parseFrom(it.body).type != RecordType.DIRECTORY_ENTRY }
        return (directoryAnswer?.invoke(withAncestry(seeds)) ?: withAncestry(seeds)) + membership
    }
```
`networkId16Hex` = `Ids.id16(network.publicKey).hex()` (add as a `val` in `FakeNode`; reuse the file's existing hex
helper). `me()` must return the logged-in user id (adapt to what it returns now). In `FakeNodeTransport.kt` (:98-140)
add next to `"directory.sync"`:
```kotlin
            "directory.list" -> RecordBatch.newBuilder().addAllRecords(s.directoryList()).build()
            "directory.get" -> RecordBatch.newBuilder().addAllRecords(s.directoryGet(DirectoryGetRequest.parseFrom(body).userIdsList.map { it.toByteArray() })).build()
            "directory.lookup" -> s.directoryLookup(DirectoryLookupRequest.parseFrom(body).username)
                ?.let { RecordBatch.newBuilder().addAllRecords(it).build() } ?: throw RpcException(Status.STATUS_NOT_FOUND, "user")
```
Leave `directory()` (full) as it is: it plays the old node. Run the Verify command → `BUILD SUCCESSFUL` (existing
DirectorySync tests use `directory()` and stay green).

- [ ] **Step 5: Commit**
```bash
git add core/proto core/crypto/src/test/resources core/signal/src/test/resources core/network core/data/src/test
oc -m "network: directory.list/get/lookup with old-node fallback; fake node serves the M9.5 rules" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: App contacts catalog (DB v10, filtered sync, fetch by id)

**Goal:** The phone stores `listed` and `related` per contact, syncs the visible set, refreshes chat/group partners
by id, fetches unknown senders by id, and «Написать» plus the group pickers show only the catalog.

**Files:**
- Modify: `otter-android-m95/core/database/src/main/kotlin/app/ottermsg/core/database/entity/ContactEntity.kt`, `dao/ContactDao.kt`, `OtterDatabase.kt` (version 10, `AutoMigration(from = 9, to = 10)`); generated `core/database/schemas/.../10.json`
- Modify: `otter-android-m95/core/data/src/main/kotlin/app/ottermsg/core/data/directory/DirectorySync.kt`, `directory/ContactRepository.kt`, `MailboxReceiver.kt:64-70`, `GroupApplier.kt:122-133`, `account/Registration.kt:147-152`
- Modify: `otter-android-m95/feature/chats/.../NewChatViewModel.kt`, `feature/groups/.../GroupRepository.kt:55`
- Test: `otter-android-m95/core/data/src/test/kotlin/app/ottermsg/core/data/CatalogTest.kt`

**Acceptance Criteria:**
- [ ] `contacts` has `listed` and `related` (default 0); `ContactDao.observeCatalog()` returns non-revoked contacts that are listed, related, a 1:1 peer (`conversations.peer_user_id`) or a group member (`group_members.user_id`).
- [ ] **Hostile node:** an entry served by the node whose signed `listed` is false and that has no relation stays out of the catalog (it is stored, for chain checks).
- [ ] Ancestry entries (inviter of my inviter) are stored but not in the catalog.
- [ ] A message from a sender not in the store triggers `directoryGet([sender])`, not a full sync.
- [ ] `DirectorySync.sync` calls `directoryList()` then `directoryGet(peers ∪ group members)`.
- [ ] The inviter placeholder from the invite link (entryVersion 0) is `related = true`.

**Verify:** `./gradlew :core:database:testDebugUnitTest :core:data:testDebugUnitTest --tests '*Catalog*' --tests '*DirectorySync*' --tests '*Mailbox*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Entity and DAO.** `ContactEntity` add after `resetMs`:
```kotlin
    @ColumnInfo(defaultValue = "0") val listed: Boolean = false,   // signed «Показывать меня в каталоге сети» (D136)
    @ColumnInfo(defaultValue = "0") val related: Boolean = false,  // my direct inviter or invitee, from the signed chain
```
`ContactDao`:
```kotlin
    /** «Написать» and group pickers (D136): only people this phone can justify from signed data or its own chats. */
    @Query("""SELECT * FROM contacts c WHERE c.revoked = 0 AND (c.listed = 1 OR c.related = 1
        OR EXISTS (SELECT 1 FROM conversations v WHERE v.peer_user_id = c.user_id)
        OR EXISTS (SELECT 1 FROM group_members m WHERE m.user_id = c.user_id))
        ORDER BY c.display_name COLLATE NOCASE""")
    fun observeCatalog(): Flow<List<ContactEntity>>
    @Query("SELECT * FROM contacts WHERE username = :username LIMIT 1") suspend fun byUsername(username: String): ContactEntity?
```
`OtterDatabase`: `version = 10`, append `AutoMigration(from = 9, to = 10)`. Build once
(`./gradlew :core:database:compileDebugKotlin`) so Room writes `schemas/.../10.json`; add it to git.

- [ ] **Step 2: Failing test** `core/data/src/test/kotlin/app/ottermsg/core/data/CatalogTest.kt` (Robolectric, same
setup as `DirectorySyncTest`; copy its private helpers `entry`, `member`, `invitedBy`, `uid` into this file or move them
to a shared `DirectoryFixtures.kt` in the same test package and use them from both):
```kotlin
@RunWith(RobolectricTestRunner::class)
class CatalogTest {
    private val clock = FakeClock()
    private val node = FakeNode(clock)
    private val g = TestGraph(node, clock)
    @After fun close() = g.close()

    private suspend fun catalog() = g.db.contactDao().observeCatalog().first().map { it.username }.toSet()

    @Test fun showsOnlyRelatedAndListed() = runBlocking {
        g.register(node.bootstrapLink(), "Я", "me_user").getOrThrow()
        val myId = g.me.userId
        node.putDirectoryEntry(invitedBy(myId, 2, "kid"))           // my invitee
        node.putDirectoryEntry(member(3, "stranger"))               // unrelated, unlisted
        node.putDirectoryEntry(member(4, "open", listed = true))    // listed
        g.online(); g.directory.sync(g.session!!)
        assertEquals(setOf("kid", "open"), catalog())
    }

    @Test fun hostileNodeListingAnUnlistedMemberChangesNothing() = runBlocking {
        g.register(node.bootstrapLink(), "Я", "me_user").getOrThrow()
        g.online()
        node.directoryAnswer = { it + member(5, "hidden") } // the node adds someone who is not listed
        g.directory.sync(g.session!!)
        assertNotNull(g.db.contactDao().byUsername("hidden")) // stored (chain checks)
        assertEquals(emptySet<String>(), catalog())
    }

    @Test fun unknownSenderIsFetchedById() = runBlocking {
        g.register(node.bootstrapLink(), "Я", "me_user").getOrThrow()
        g.online()
        val calls = node.recordCalls()
        g.directory.fetch(g.session!!, listOf(uid(6)))
        assertTrue("directory.get" in calls && "directory.sync" !in calls)
    }
}
```
Extend the helpers: `member(seed, name, listed = false)` sets `.setListed(listed)` on the entry before signing;
`invitedBy(by, seed, name)` must take the inviter's user id (adapt to its current parameter). `node.recordCalls()` —
add to `FakeNode` a `val calls = CopyOnWriteArrayList<String>()` filled at the top of each `Session` override
(`directory`, `directoryList`, `directoryGet`, `directoryLookup`) and `fun recordCalls() = calls.also { it.clear() }`.
Run → FAIL (`observeCatalog`/`fetch` unresolved).

- [ ] **Step 3: Implement `DirectorySync`.**
  - `sync(api)`:
```kotlin
    suspend fun sync(api: NodeApi) {
        apply(api.directoryList())
        val partners = (conversations.peerIds() + groups.memberIds()).distinctBy { it.toList() }
        if (partners.isNotEmpty()) apply(api.directoryGet(partners)) // chat and group partners (D137)
        _synced.value = true
    }

    /** One or more ids not in the store (a sender, a group member): fetch them with their ancestry (D137). */
    suspend fun fetch(api: NodeApi, ids: List<ByteArray>) { if (ids.isNotEmpty()) apply(api.directoryGet(ids)) }
```
  Add the two DAO reads it needs: `ConversationDao` `@Query("SELECT peer_user_id FROM conversations WHERE peer_user_id IS NOT NULL") suspend fun peerIds(): List<ByteArray>`
  and `GroupDao` `@Query("SELECT DISTINCT user_id FROM group_members") suspend fun memberIds(): List<ByteArray>`;
  inject `GroupDao` into `DirectorySync` the way `ConversationDao` (`conversations`) already is (check the constructor
  at :38-41; if conversations is a repository, add `peerIds()` there).
  - In `apply`, compute once before the `for ((e, _) in accepted)` loop:
```kotlin
        val meHex = me.userId.hex()
        val myInviter = settings.ownInvite()?.first?.let { runCatching {
            RecordBody.parseFrom(Record.parseFrom(it).body).author.toByteArray().hex() }.getOrNull() }
```
  and in the `ContactEntity(...)` call add:
```kotlin
                listed = e.listed,
                related = userId.hex() == myInviter || inviters[userId.hex()]?.contains(meHex) == true,
```
  (`inviters` is the map the loop already builds and stores with `setContactInviters`; confirm its name at :160-166.)
- [ ] **Step 4: Callers.** `MailboxReceiver.kt:64-70`: replace `directory.sync(api)` with
`directory.fetch(api, listOf(body.author.toByteArray()))` (keep the once-per-batch flag, rename it `directoryFetched`).
`GroupApplier.kt:132`: same with the signer's id. `Registration.kt:147-152`: the inviter placeholder gets `related = true`.
`ContactRepository.observeContacts()` → `contacts.observeCatalog()` (NewChat uses it).
`GroupRepository.kt:55` `observeContacts()` → `db.contactDao().observeCatalog()`. Keep `observeAllKnown()` users
(names in chats) unchanged. `ProfileRepository.kt:92,105` (`api.directory()` for the newest own version) →
`api.directoryList()` (own entry is always in it).
- [ ] **Step 5:** Run the Verify command, then `./gradlew :core:data:testDebugUnitTest :feature:chats:testDebugUnitTest :feature:groups:testDebugUnitTest`
→ `BUILD SUCCESSFUL`. A pre-existing test that expected an unrelated member in «Написать» must now make that member
related or listed; change the test data, not the rule, and name the test in the commit message.

- [ ] **Step 6: Commit**
```bash
git add core/database core/data feature/chats feature/groups
oc -m "contacts: catalog of listed, related, chat and group partners; visible-set sync, fetch by id (M9.5, D136)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: «Показывать меня в каталоге сети»

**Goal:** A member can publish `listed = true` in their own signed entry from Settings; default off.

**Files:**
- Modify: `otter-android-m95/core/data/src/main/kotlin/app/ottermsg/core/data/settings/Settings.kt`, `account/DirectoryEntries.kt`, `profile/ProfileRepository.kt`
- Modify: `otter-android-m95/feature/settings/src/main/kotlin/app/ottermsg/feature/settings/SettingsScreen.kt` (`SettingsViewModel`, row after `SecurityRows`), `res/values/strings.xml`, `res/values-en/strings.xml`
- Test: `otter-android-m95/core/data/src/test/kotlin/app/ottermsg/core/data/ListedEntryTest.kt`, `feature/settings/src/test/.../SettingsOrderTest.kt`

**Acceptance Criteria:**
- [ ] Default off; switching on publishes a new entry version with `listed = true` through the existing `ProfileRepository` pending/publish path (also retried after a CONFLICT).
- [ ] Every later entry (name change) keeps the current `listed` value.
- [ ] Row «Показывать меня в каталоге сети», subtitle «Узлы и администратор всё равно видят всех участников», is a `Role.Switch` row directly after «Запрет скриншотов»; `SettingsOrderTest` updated.

**Verify:** `./gradlew :core:data:testDebugUnitTest --tests '*ListedEntry*' :feature:settings:testDebugUnitTest` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing test** `ListedEntryTest.kt` (Robolectric, `TestGraph`):
```kotlin
@Test fun switchingOnPublishesListedEntry() = runBlocking {
    g.register(node.bootstrapLink(), "Я", "me_user").getOrThrow()
    g.online()
    g.profile.setListed(true)
    g.profile.run(g.session!!)
    val mine = node.entries().single { it.first == g.me.userId.hex() }.second
    assertTrue(mine.listed)
    assertEquals(2L, mine.version)
}
```
(`g.profile` — expose the `ProfileRepository` in `TestGraph` if it is not there; `node.entries()` from Task 5.)
Run → FAIL.
- [ ] **Step 2: Implement.**
  - `Settings.kt`: `suspend fun catalogListed(): Boolean = (int(CATALOG_LISTED) ?: 0) != 0`,
    `suspend fun setCatalogListed(v: Boolean) = putInt(CATALOG_LISTED, if (v) 1 else 0)`,
    `fun observeCatalogListed(): Flow<Boolean> = observeInt(CATALOG_LISTED, 0).map { it != 0 }`,
    `const val CATALOG_LISTED = "catalog_listed"`.
  - `DirectoryEntries.build(..., listed: Boolean = false)` → `.setListed(listed)`; `record(..., listed: Boolean = false)` passes it.
  - `ProfileRepository`: `suspend fun setListed(v: Boolean) { settings.setCatalogListed(v); markPending() }` where
    `markPending()` is whatever `setDisplayName` does to set `PROFILE_PENDING` and kick (extract it if inline), and
    `publishIfPending` passes `listed = settings.catalogListed()` to `DirectoryEntries.record`.
  - `SettingsViewModel`: like `callsRelayOnly` — internal constructor params `listed: Flow<Boolean> = flowOf(false)`,
    `saveListed: suspend (Boolean) -> Unit = {}`; `@Inject` wires `settings.observeCatalogListed()` and
    `{ profile.setListed(it) }` (inject `ProfileRepository`); `val catalogListed: StateFlow<Boolean>`, `fun setCatalogListed(v)`.
  - `SettingsScreen.kt`, after `SecurityRows(...)`: a switch row built like `CallSettingsRows` (toggleable, `Role.Switch`,
    title + subtitle, icon `Icons.Outlined.TravelExplore`).
  - Strings (`values` / `values-en`): `settings_catalog_listed` «Показывать меня в каталоге сети» / "Show me in the network directory";
    `settings_catalog_listed_sub` «Узлы и администратор всё равно видят всех участников» / "Nodes and the admin still see every member".
- [ ] **Step 3:** Update `SettingsOrderTest.kt:46-48` with the new row after «Запрет скриншотов». Run Verify → `BUILD SUCCESSFUL`.
- [ ] **Step 4: Commit**
```bash
git add core/data feature/settings
oc -m "settings: «Показывать меня в каталоге сети», signed in the own entry, off by default (M9.5)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Exact username lookup and «Написать» search

**Goal:** «Написать» filters the catalog as you type and offers «Найти @name»; the answer is checked and shown as a
person card with «Написать».

**Files:**
- Create: `otter-android-m95/core/data/src/main/kotlin/app/ottermsg/core/data/directory/UsernameLookup.kt`
- Create: `otter-android-m95/feature/chats/src/main/kotlin/app/ottermsg/feature/chats/PersonCard.kt`
- Modify: `otter-android-m95/feature/chats/.../NewChatScreen.kt`, `NewChatViewModel.kt`, `res/values{,-en}/strings.xml`
- Test: `otter-android-m95/core/data/src/test/kotlin/app/ottermsg/core/data/UsernameLookupTest.kt`, `feature/chats/src/test/.../NewChatSearchTest.kt`

**Acceptance Criteria:**
- [ ] `UsernameLookup.find("@Name")` returns `Found(contact)` from the local store without a network call when the username is known; else asks the node.
- [ ] **Hostile node:** a lookup answer whose verified entry has another username → `NotFound` (nothing stored as a catalog contact).
- [ ] Results: `Found`, `NotFound` («Пользователь не найден»), `Limited` («Слишком много поисков, попробуйте позже»), `OldNode` («Сервер устарел, попробуйте позже»), `Offline` («Нет подключения»).
- [ ] «Написать» has a search field; typing filters the catalog by name or `@username` (reuse `pickList` logic); a query that is a valid username and not an exact catalog match shows the row «Найти @name».
- [ ] The card shows avatar, display name, `@username` and «Написать» (or «Открыть чат» if a conversation exists); «Написать» opens the conversation.

**Verify:** `./gradlew :core:data:testDebugUnitTest --tests '*UsernameLookup*' :feature:chats:testDebugUnitTest --tests '*NewChatSearch*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing test** `UsernameLookupTest.kt`:
```kotlin
@Test fun findsVerifiesAndRefusesAMismatch() = runBlocking {
    g.register(node.bootstrapLink(), "Я", "me_user").getOrThrow()
    g.online()
    node.putDirectoryEntry(member(7, "vera"))
    val lookup = g.usernameLookup
    val found = lookup.find(g.session!!, "@Vera")
    assertTrue(found is UsernameLookup.Result.Found && found.contact.username == "vera")
    node.lookupAnswer = { node.withAncestry(setOf(uid(7).hex())) } // asks for "ivan", gets vera's entry
    assertEquals(UsernameLookup.Result.NotFound, lookup.find(g.session!!, "ivan"))
    val calls = node.recordCalls()
    assertTrue(lookup.find(g.session!!, "vera") is UsernameLookup.Result.Found) // now local
    assertTrue(calls.isEmpty())
}
```
(expose `usernameLookup` in `TestGraph`.) Run → FAIL.
- [ ] **Step 2: Implement** `UsernameLookup.kt`:
```kotlin
package app.ottermsg.core.data.directory

/** Exact `@username` lookup (D137): local store first, then the node; the answer must carry that exact username. */
class UsernameLookup @Inject constructor(private val contacts: ContactDao, private val directory: DirectorySync) {
    sealed interface Result {
        data class Found(val contact: ContactEntity) : Result
        data object NotFound : Result
        data object Limited : Result
        data object OldNode : Result
        data object Offline : Result
    }

    suspend fun find(api: NodeApi?, typed: String): Result {
        val q = typed.trim().removePrefix("@").lowercase()
        if (!VALID.matches(q)) return Result.NotFound
        contacts.byUsername(q)?.takeIf { !it.revoked && it.entryVersion > 0 }?.let { return Result.Found(it) }
        if (api == null) return Result.Offline
        val records = try { api.directoryLookup(q) ?: return Result.NotFound }
            catch (e: LookupLimitException) { return Result.Limited }
            catch (e: OldNodeException) { return Result.OldNode }
            catch (e: IOException) { return Result.Offline }
        directory.apply(records) // verified and admitted by the normal rules; ancestry stays out of the catalog
        return contacts.byUsername(q)?.takeIf { !it.revoked && it.entryVersion > 0 }?.let { Result.Found(it) } ?: Result.NotFound
    }

    companion object { val VALID = Regex("^[a-z0-9_]{3,32}(#[0-9a-f]{8})?$") }
}
```
A tagged name (`name#tag`) is stored by the phone as `name` (the signed username); for a tagged query also accept
`contacts.byUsername(base)` whose `userId` hex starts with the tag — add that check in both `byUsername` places via a
small `local(q)` helper. Run → PASS.
- [ ] **Step 3: UI.** `NewChatViewModel`: add `query: MutableStateFlow<String>`, `lookup: MutableStateFlow<UsernameLookup.Result?>`,
`fun onQuery(q)`, `fun find()` (launches `usernameLookup.find(sync.currentApi(), query.value)` — use how other
ViewModels get the live `NodeApi`: `grep -rn "currentApi\|session()" core/data/src/main/kotlin/app/ottermsg/core/data/sync/SyncEngine.kt`),
and a pure `fun searchList(all, q) = pickList(all, emptySet(), q)`-style filter (copy the 4-line filter, not the
groups module). `NewChatScreen`: an `OutlinedTextField` under the top bar (label `newchat_search` «Имя или @имя_пользователя»),
the filtered list, and when `UsernameLookup.VALID.matches(q)` and no row has exactly that username, a row
`newchat_find` «Найти @%1$s». Result `Found` → `PersonCard(contact, hasChat, onWrite = { vm.open(contact.userId, onOpened) })`
in a `ModalBottomSheet`; other results → the strings in the criteria under the field.
`PersonCard.kt`: `OtterAvatar` (64 dp), display name (`titleLarge`), `@username` (`bodyMedium`, `onSurfaceVariant`),
a filled button `person_write` «Написать» / `person_open_chat` «Открыть чат».
- [ ] **Step 4: UI test** `NewChatSearchTest.kt` (Robolectric Compose, `@Config(qualifiers = "ru")`): render
`NewChatScreen` with two catalog contacts, type `ann` → only «Анна» shown; type `@zoya_k` → row «Найти @zoya_k» exists.
Run Verify → `BUILD SUCCESSFUL`.
- [ ] **Step 5: Commit**
```bash
git add core/data feature/chats
oc -m "chats: search in «Написать» and exact @username lookup with a person card (M9.5, D137)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: `@username` links in messages and «Поделиться именем пользователя»

**Goal:** `@name` in a message opens the person card; the profile can share `@username`.

**Files:**
- Create: `otter-android-m95/feature/conversation/src/main/kotlin/app/ottermsg/feature/conversation/UsernameLinks.kt`
- Modify: `otter-android-m95/feature/conversation/.../MessageBubble.kt` (signature at :65, `Text(text, …)` at :126 and :132), `ConversationScreen.kt` (call at :317, a sheet), `ConversationViewModel` (lookup via `UsernameLookup`)
- Move: `PersonCard.kt` from `feature/chats` to `otter-android-m95/core/ui/src/main/kotlin/app/ottermsg/core/ui/components/PersonCard.kt` (both features use it; strings move to `core/ui`)
- Modify: `otter-android-m95/feature/settings/.../ProfileScreen.kt` (row after the username row), strings
- Test: `otter-android-m95/feature/conversation/src/test/.../UsernameLinksTest.kt`, `feature/settings/src/test/.../ProfileShareTest.kt`

**Acceptance Criteria:**
- [ ] `findUsernames("Пиши @vera_k или @Ivan#1a2b3c4d, mail a@b.c")` → ranges of `@vera_k` and `@Ivan#1a2b3c4d` only (not inside an e-mail or word).
- [ ] In a text bubble each match is a `LinkAnnotation.Clickable` in the link style; tap → lookup → the card (or the not-found / limited / old-node text in a snackbar).
- [ ] TalkBack: each username link is reachable as a button labelled «Открыть @vera_k».
- [ ] Profile row «Поделиться именем пользователя» (icon `Icons.Outlined.Share`) sends `@username` with `ACTION_SEND` through a chooser.

**Verify:** `./gradlew :feature:conversation:testDebugUnitTest --tests '*UsernameLinks*' --tests '*MessageBubble*' :feature:settings:testDebugUnitTest --tests '*ProfileShare*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing test** `UsernameLinksTest.kt`:
```kotlin
class UsernameLinksTest {
    @Test fun findsOnlyStandaloneUsernames() {
        val t = "Пиши @vera_k или @Ivan#1a2b3c4d, mail a@b.c и @no"
        assertEquals(listOf("@vera_k", "@Ivan#1a2b3c4d"), findUsernames(t).map { t.substring(it) })
    }
}
```
Run → FAIL.
- [ ] **Step 2: Implement** `UsernameLinks.kt`:
```kotlin
package app.ottermsg.feature.conversation

/** `@name` or `@name#1a2b3c4d` not preceded by a letter, digit, `_` or `@` (so e-mail addresses are skipped). */
internal val usernameRegex = Regex("""(?<![\p{L}\p{N}_@])@[A-Za-z0-9_]{3,32}(?:#[0-9a-fA-F]{8})?(?![A-Za-z0-9_])""")

internal fun findUsernames(text: String): List<IntRange> = usernameRegex.findAll(text).map { it.range }.toList()
```
and a composable `UsernameText(text, style, color, fontStyle, linkColor, onUsername: (String) -> Unit)` that builds
the `AnnotatedString` the way `NewsBubble.kt:88-101` does (same `LinkAnnotation.Clickable` + `TextLinkStyles`), and
adds the TalkBack buttons the way `NewsBubble.kt:115-133` does, label `username_link_label` «Открыть %1$s».
Replace the two `Text(text, …)` calls in `MessageBubble` with `UsernameText(...)`; add parameter
`onUsername: (String) -> Unit = {}` to `MessageBubble` after `onPhotoDownload`. Messages with `m.system == true`
keep plain `Text`.
- [ ] **Step 3: Wire.** `ConversationScreen.kt:317` passes `onUsername = vm::openUsername`; the ViewModel calls
`UsernameLookup.find` and exposes a `person: StateFlow<UsernameLookup.Result?>`; the screen shows `PersonCard` in a
`ModalBottomSheet` for `Found` («Написать» → open or create the conversation with `MessageRepository.conversationWith`
and navigate as `NewChatRoute` does) and a snackbar for the others.
- [ ] **Step 4: Profile share.** `ProfileScreen` gets `onShareUsername: () -> Unit`; the row
`profile_share_username` «Поделиться именем пользователя» / "Share username". `ProfileRoute` implements it like
`feature/chats/.../InviteScreen.kt:62-63`:
```kotlin
val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "@${me.username}")
runCatching { context.startActivity(Intent.createChooser(send, shareTitle)) }
```
`ProfileShareTest`: render `ProfileScreen` with a fake `onShareUsername`, click the row, assert it was called.
- [ ] **Step 5:** Run Verify, then `./gradlew :feature:conversation:testDebugUnitTest :feature:chats:testDebugUnitTest :feature:settings:testDebugUnitTest` → `BUILD SUCCESSFUL`.
- [ ] **Step 6: Commit**
```bash
git add core/ui feature/conversation feature/chats feature/settings
oc -m "conversation: @username links open a person card; profile shares @username (M9.5)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Network code on join and in «Состояние сети», node versions

**Goal:** The join step shows the network code; «Состояние сети» shows the code and each node's last seen version.

**Files:**
- Create: `otter-android-m95/core/crypto/src/main/kotlin/app/ottermsg/core/crypto/NetworkCode.kt`, `core/crypto/src/test/kotlin/app/ottermsg/core/crypto/NetworkCodeTest.kt`
- Modify: `otter-android-m95/feature/onboarding/.../OnboardingState.kt` (`networkCode: String? = null`), `OnboardingViewModel.kt:33-41`, `screens/ProfileScreen.kt:25`, strings
- Modify: `otter-android-m95/core/data/.../settings/Settings.kt` (node versions), `sync/SyncEngine.kt` (after `checkAfterLogin`), `network/NetworkStatus.kt` (`NodeRow.version`)
- Modify: `otter-android-m95/feature/settings/.../NetworkStatusScreen.kt` (code row, version in `NodeCard`), strings
- Test: `NetworkStatusScreenTest.kt`, `feature/onboarding/src/test/.../NetworkCodeOnJoinTest.kt`

**Acceptance Criteria:**
- [ ] `NetworkCode.of(pub)` matches the three shared vectors (`vectors/network_code.json`).
- [ ] After a valid link, the profile step shows «Код сети: 92144 18366 54483» and «Сверьте его с тем, кто вас пригласил» under «Вас приглашает …».
- [ ] «Состояние сети» shows «Код сети» at the top and «Версия 0.11.0» on each node card the phone has connected to (no line for nodes never reached).
- [ ] The version is recorded from `LoginResponse.server_version` on each login, keyed by the connected node's label.

**Verify:** `./gradlew :core:crypto:test --tests '*NetworkCode*' :feature:onboarding:testDebugUnitTest :feature:settings:testDebugUnitTest --tests '*NetworkStatus*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing test** `NetworkCodeTest.kt` — read `vectors/network_code.json` from test resources the way
other crypto vector tests do (`grep -rn "vectors/" core/crypto/src/test | head -3`) and assert
`NetworkCode.of(hex(pub)) == code` for each. Run → FAIL.
- [ ] **Step 2: Implement** `NetworkCode.kt`:
```kotlin
package app.ottermsg.core.crypto

import java.security.MessageDigest

/** The 15-digit network code (D139): SHA-256("otter-network-code" ‖ network_pub), first 8 bytes BE, mod 10^15. */
object NetworkCode {
    fun of(networkPub: ByteArray): String {
        val h = MessageDigest.getInstance("SHA-256").run { update("otter-network-code".toByteArray()); digest(networkPub) }
        val n = java.math.BigInteger(1, h.copyOf(8)).mod(java.math.BigInteger.TEN.pow(15))
        val s = n.toString().padStart(15, '0')
        return "${s.substring(0, 5)} ${s.substring(5, 10)} ${s.substring(10)}"
    }
}
```
(`BigInteger(1, …)` keeps the 64-bit value unsigned, as Go's `Uint64`.) Run → PASS.
- [ ] **Step 3: Join.** `OnboardingViewModel.submitLink()` at :39: `copy(inviterName = …, networkCode = NetworkCode.of(b.networkPub.toByteArray()), step = PROFILE)`.
`screens/ProfileScreen.kt` after the inviter line:
```kotlin
state.networkCode?.let {
    Text(stringResource(R.string.onb_network_code, it), style = MaterialTheme.typography.titleMedium,
        modifier = Modifier.semantics { contentDescription = it.replace(" ", "") .toCharArray().joinToString(" ") })
    Text(stringResource(R.string.onb_network_code_hint), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
}
```
Strings: `onb_network_code` «Код сети: %1$s» / "Network code: %1$s"; `onb_network_code_hint` «Сверьте его с тем, кто вас пригласил» / "Check it with the person who invited you".
Test `NetworkCodeOnJoinTest`: a ViewModel test that submits `FakeNode(...).bootstrapLink()`-style link (or the
existing onboarding test link helper: `grep -rn "otter://join" feature/onboarding/src/test`) and asserts
`state.networkCode == NetworkCode.of(thatNetworkPub)`.
- [ ] **Step 4: Node versions.** `Settings.kt`:
```kotlin
    /** Last `LoginResponse.server_version` per node label (D139), "label=version" lines. */
    suspend fun nodeVersions(): Map<String, String> = dao.get(NODE_VERSIONS)?.decodeToString().orEmpty()
        .lines().filter { '=' in it }.associate { it.substringBefore('=') to it.substringAfter('=') }
    suspend fun setNodeVersion(label: String, version: String) {
        if (version.isEmpty() || '\n' in label + version) return
        val m = nodeVersions() + (label to version)
        dao.put(SettingEntity(NODE_VERSIONS, m.entries.joinToString("\n") { "${it.key}=${it.value}" }.toByteArray()))
    }
    const val NODE_VERSIONS = "node_versions"
```
`SyncEngine` right after the `when (manifests.checkAfterLogin(api)) { … }` block (`login` is the `LoginResponse`
kept at SyncEngine.kt:128):
```kotlin
        (connection.value as? ConnectionState.Online)?.let { settings.setNodeVersion(it.nodeLabel, login.serverVersion) }
```
(use the engine's existing `settings`/`connection` fields; inject `Settings` if missing).
`NetworkStatus`: `data class NodeRow(val label: String, val endpoints: List<EndpointRow>, val version: String? = null)`;
the `@Inject` constructor also takes `Settings`; `nodes()` sets `version = versions[label]` with
`val versions = settings.nodeVersions()`. Keep the internal test constructor working by adding a
`versions: suspend () -> Map<String, String> = { emptyMap() }` parameter.
- [ ] **Step 5: Screen.** `NetworkStatusScreen`: a first row «Код сети» with the code (from `NetworkCode.of(settings.networkPub())`,
added to `NetworkStatusUi` as `networkCode: String`), and in `NodeCard` a line `network_node_version` «Версия %1$s» when `version != null`.
Extend `NetworkStatusScreenTest` with one node having `version = "0.11.0"` → text «Версия 0.11.0» exists, and the code row exists.
- [ ] **Step 6:** Run Verify → `BUILD SUCCESSFUL`. **Commit**
```bash
git add core/crypto core/data feature/onboarding feature/settings
oc -m "network code on join and in «Состояние сети»; node versions from the login answer (M9.5, D139)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: «Сеть изменилась» warning

**Goal:** A manifest signed for another network shows a full-screen warning once per app process instead of being
silently ignored.

**Files:**
- Modify: `otter-android-m95/core/crypto/src/main/kotlin/app/ottermsg/core/crypto/ManifestVerifier.kt` (a helper), `core/data/.../sync/ManifestUpdater.kt`, `sync/SyncEngine.kt` (both `when` blocks at ~146 and ~247)
- Create: `otter-android-m95/app/src/main/java/app/ottermsg/NetworkChangedScreen.kt`
- Modify: `otter-android-m95/app/src/main/java/app/ottermsg/MainActivity.kt:97-98` and its ViewModel, `app/src/main/res/values{,-en}/strings.xml`
- Test: `otter-android-m95/core/crypto/src/test/.../ManifestVerifierTest.kt`, `core/data/src/test/.../ManifestUpdaterTest.kt`

**Acceptance Criteria:**
- [ ] `ManifestVerifier.foreignNetwork(raw, ours)` is true only when the manifest is validly self-signed by a `network_pub` different from ours.
- [ ] `ManifestUpdater.offer` returns `Result.FOREIGN` then, stores nothing, and sets `SyncEngine.networkChanged` (`StateFlow<Boolean>`, in memory only).
- [ ] A manifest with a broken signature still returns `IGNORED` (no warning: that is noise, not a network change).
- [ ] `MainActivity` shows `NetworkChangedScreen` while `networkChanged` is true: title «Сеть изменилась», text «Не вводите пароли и обратитесь к администратору. Этот узел выдаёт себя за другую сеть.», button «Понятно» (dismisses until the app restarts).

**Verify:** `./gradlew :core:crypto:test --tests '*ManifestVerifier*' :core:data:testDebugUnitTest --tests '*ManifestUpdater*' :app:testDebugUnitTest` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing tests.** `ManifestVerifierTest`: a manifest built and signed with a second key pair whose
`network_pub` is that key → `foreignNetwork(raw, ours) == true`; the same bytes with a flipped signature byte →
`false`; our own valid manifest → `false`. `ManifestUpdaterTest`: offering the foreign manifest → `Result.FOREIGN`,
`manifests.latest()` unchanged. Run → FAIL.
- [ ] **Step 2: Implement.** `ManifestVerifier`:
```kotlin
    /** True when [raw] is a manifest validly signed by the network key it names, and that key is not [ours] (D139). */
    fun foreignNetwork(raw: ByteArray, ours: ByteArray, ctx: SigContext): Boolean = runCatching {
        val rec = Record.parseFrom(raw)
        val m = Manifest.parseFrom(RecordBody.parseFrom(rec.body).payload)
        val theirs = m.networkPub.toByteArray()
        !theirs.contentEquals(ours) && RecordCodec.verify(rec, theirs, ctx)
    }.getOrDefault(false)
```
Build `ctx` exactly as `verify` builds its `SigContext` at :19 but with `theirs` (read :16-20 and mirror it; if the
context is derived from the network key, derive it from `theirs`). `ManifestUpdater`: `enum class Result { IGNORED, STORED, STORED_NODE_REMOVED, FOREIGN }`;
in the `catch (e: ManifestException)` branch: `if (ManifestVerifier.foreignNetwork(raw, settings.networkPub(), …)) return@withLock Result.FOREIGN`
before logging `IGNORED`. `SyncEngine`: `private val _networkChanged = MutableStateFlow(false); val networkChanged: StateFlow<Boolean> = _networkChanged`
and `fun dismissNetworkChanged() { _networkChanged.value = false }`; both `when` blocks get
`ManifestUpdater.Result.FOREIGN -> { log.warning("manifest of another network from this node"); _networkChanged.value = true }`.
- [ ] **Step 3: Screen.** `NetworkChangedScreen(onDismiss: () -> Unit)` styled like `RevokedScreen.kt` (same layout),
strings `network_changed_title`, `network_changed_text`, `network_changed_ok` (en: "The network changed",
"Do not enter passwords and contact the admin. This node claims to be a different network.", "OK").
`MainActivity.kt:97`: before `revoked ->` add `networkChanged -> NetworkChangedScreen(onDismiss = vm::dismissNetworkChanged)`,
with `networkChanged` collected from `SyncEngine.networkChanged` in the activity's ViewModel.
- [ ] **Step 4:** Run Verify → `BUILD SUCCESSFUL`. **Commit**
```bash
git add core/crypto core/data app
oc -m "app: «Сеть изменилась» warning for a manifest of another network (M9.5, D139)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Docs, versions, full checks, owner test, merge, rollout

**Goal:** Docs match the code, both repos are green, the owner checks it on two phones, then merges and rolls out.

**Files:**
- Modify: `docs-m95/00-decisions.md` (D135–D139 as in "Decisions this plan adds"), `docs-m95/02-protocol.md` (`directory.sync{since}` → the four methods; `LoginResponse.server_version`; `DirectoryEntry.listed`), `docs-m95/09-roadmap.md` (M9.5 row: server/app 0.11.0; M10 row → 0.12.0), `docs-m95/07-android-architecture.md` (catalog, `UsernameLookup`), `docs-m95/10-otter-design-guidelines.md` §10 (new switch row) and the «Написать» section (search, card)
- Modify: `docs-m95/superpowers/specs/2026-11-15-m9-5-member-privacy-design.md` (the clash tag has 8 hex digits; event stays a broadcast, D138; ancestry entries, D135), `docs-m95/superpowers/specs/2026-11-15-m10-video-calls-design.md` and `superpowers/plans/2026-11-15-m10-video-calls.md` (versions 0.11.0 → 0.12.0, "after M9.4's 0.10.1" → "after M9.5's 0.11.0")
- Modify: `otter-android-m95/app/build.gradle.kts:37` (`versionCode = 15; versionName = "0.11.0"`)

**Acceptance Criteria:**
- [ ] Server: `nice -n 15 ionice -c3 go test -race -p 4 ./...` all `ok`; `go vet ./...` clean; `scripts/secrets-check.sh` ok.
- [ ] App (after the server run has finished): `nice -n 15 ./gradlew test lintDebug assembleDebug assembleRelease` → `BUILD SUCCESSFUL`; `scripts/secrets-check.sh` ok.
- [ ] Docs: `scripts/secrets-check.sh` ok in `docs-m95`.
- [ ] Owner test passed and owner said "merge".

**Verify:** the three commands above.

**Steps:**

- [ ] **Step 1:** Edit the docs as listed; commit in `docs-m95`:
  `oc -m "docs: M9.5 member privacy and network code (D135–D139), versions 0.11.0, M10 → 0.12.0" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`.
- [ ] **Step 2:** Bump the app version; commit `oc -m "app 0.11.0 (versionCode 15)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`.
- [ ] **Step 3:** Run the checks one after another (server first, then app, never together).
- [ ] **Step 4: Ask the owner → build and install** the server and APK the usual way (`make release VERSION=0.11.0`
  in `otter-server-m95`; the release APK from `otter-android-m95`). Give the owner the commands; never ssh yourself.
  Owner rollout order: **every node first**, then the APK through Otter news (as for 0.10.1):
```bash
cd ~/Documents/Projects/OttterMSG/otter-server-m95 && make release VERSION=0.11.0
# then, as for 0.10.1: deploy/upgrade-all.sh 0.11.0   (eeee and ru-1; ru-1 keeps its own parameters)
```
- [ ] **Step 5: Ask the owner → test on two phones** (both on 0.11.0, nodes on 0.11.0):
  1. Settings → «Состояние сети»: the network code equals `otter-admin network code`; each node shows «Версия 0.11.0».
  2. «Написать» on phone 2 (invited by phone 1) lists phone 1; a third member who is unrelated is not listed.
  3. Phone 1 switches «Показывать меня в каталоге сети» on → a phone that is unrelated now lists it after the next sync.
  4. Search «@username» of an unrelated, unlisted member → card → «Написать» → the chat works both ways.
  5. Send «@имя» in a chat → tap opens the card. Profile → «Поделиться именем пользователя» opens the share sheet.
  6. 31 lookups in an hour → «Слишком много поисков, попробуйте позже».
- [ ] **Step 6: Ask the owner → merge** (through temporary worktrees, so busy trees stay untouched):
```bash
cd ~/Documents/Projects/OttterMSG
for r in otter-server otter-android docs; do
  git -C $r fetch origin && git -C $r worktree add ../$r-merge origin/main --detach
  (cd $r-merge && git merge --no-ff --no-commit m9-5-privacy && oc -m "Merge M9.5: member privacy (catalog, exact @username, invite relations) and the network code (server 0.11.0, app 0.11.0)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && scripts/secrets-check.sh && git push origin HEAD:main)
  git -C $r worktree remove ../$r-merge
done
for r in otter-server otter-android docs; do git -C $r worktree remove ../$r-m95; done
```
