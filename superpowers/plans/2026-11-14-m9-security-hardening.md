# M9 Security Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every finding of the 2026-11-13 security audit (C1–C26; C27 and the publish-safety part of C28 are done, D57) and its four design limits, under the owner's threat model "any one node may be hostile", then the M9 operations work.

**Architecture:** Five phases, each on its own branch per repo and merged `--no-ff` only after the owner's OK: M9.0 server hotfix (host takeover, malformed peer input) → M9.1 the phone verifies everything a node says (restore, install claims, envelopes, manifests, sizes) plus the push switches → M9.2 membership is decided by signed records every node checks itself (revocation, invite chain, single-use invites, username rank, limits) plus the M8 hostile-node review → M9.3 signatures bound to the network, lost-phone re-key, no backups on dial-out nodes with a restore tunnel → M9.4 operations (limits, keep-alive, monitoring, sandboxing, app lock, deployment guide).

**Tech Stack:** Go 1.26, SQLite, Pion TURN v5; Android Kotlin 2.2.21, Room, Hilt, Compose, OkHttp, libsignal; protobuf shared by both repos.

**Spec:** `docs/superpowers/specs/2026-11-14-m9-security-hardening-design.md`. Audit (private): `~/Documents/otter-private/review/security 1/security-audit-combined.md`.

**Ground rules (owner):**
* Branches: `m9-0-hotfix`, `m9-1-client`, `m9-2-membership`, `m9-3-network`, `m9-4-ops` in each repo touched. TDD, small commits. Merge with `--no-ff` **only after the owner says so**. Run `scripts/secrets-check.sh` in every repo before any push.
* Never touch `root@eeee`, ru-1, DNS, `~/.otter-admin` or the phones without asking. Passphrases are typed only in the owner's terminal, never in chat. Never delete anything in `otter-server/dist/`. Run `deploy/test/scripts_test.sh` only in a scratch copy.
* Never create, print or commit `google-services.json`, `fcm*.json`, `release.jks`, `keystore.properties`. Never write to the desktop keyring without asking. Real IPs never in repos (`<eeee-ip>`, `203.0.113.x`).
* Every fix has a test in which a fake or hostile node plays the attack and loses.
* Environment: `export PATH=/usr/lib/go-1.26/bin:$HOME/go/bin:$PATH`; `export JAVA_HOME=~/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2`.
* **Commits (D57):** UTC date, time of day shown as 12:00:SS, no `Claude-Session` line. Define once per shell:
  ```bash
  oc() {  # otter commit: D57 date, then normal git commit args
    local day last n d
    day=$(date -u +%F)
    last=$(TZ=UTC git log -1 --format=%cd --date=format-local:'%F %M %S' 2>/dev/null)
    if [ "${last%% *}" = "$day" ]; then
      n=$(( 10#$(echo "$last" | cut -d' ' -f2) * 60 + 10#$(echo "$last" | cut -d' ' -f3) + 1 ))
    else n=0; fi
    d=$(printf '%sT12:%02d:%02d+0000' "$day" $((n / 60)) $((n % 60)))
    TZ=UTC GIT_AUTHOR_DATE=$d GIT_COMMITTER_DATE=$d git commit "$@"
  }
  ```
  Every message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` (pass it as a second `-m`).

## Phase map

| Phase | Tasks | Server | App | Findings |
|---|---|---|---|---|
| M9.0 Server hotfix | 1–9, 74 | 0.8.3 | — | C3 (+3 more root-handles-otter-files cases), C11, C25, C26, C28 rest |
| M9.1a Restore trusts no node | 10–19 | 0.9.0 | 0.9.0 (11) | C1, C13, C14, C18, C20 |
| M9.1b Client hardening + push | 20–29 | 0.9.0 | 0.9.0 (11) | C15, C16, C17, C19, C21, C22, C23, C24, design limit 4 (push option B) |
| M9.2a Membership | 30–39 | 0.9.1 | 0.9.1 (12) | C2, C5, C6, C12, design limit 3 |
| M9.2b Limits + M8 review | 40–49 | 0.9.1 | 0.9.1 (12) | C4, C8, C9, C10, M8 hostile-node issues (TURN after revocation, call-push spam, TURN answer bounds) |
| M9.3 Network binding, re-key, backups | 50–59 | 0.10.0 | 0.10.0 (13) | C7, design limit 2 (re-key), design limit 1 (no backups on dial-out nodes + restore tunnel) |
| M9.4 Operations | 60–73 | 0.10.1 | 0.10.1 (14) | roadmap M9 ops: keep-alive, disk floor, per-IP/per-user limits, monitoring, sandboxing, harden-check, app lock, network screen, guide |

Rollout order: M9.0 → M9.1 → M9.2 → M9.3 → ru-1 may hold backups → M9.4. ru-1 may join earlier with backups off (Task 56 ships alone). In every phase **all nodes upgrade before the APK is published** (older nodes reject the new record types and their cursor moves past them).

## Coordinator reconciliation (applies across sections; wins over a section's text)

1. **Server migrations** are numbered in phase order: `0009_installs` (T11), `0010_push_switches` (T20), `0011_membership` (T31), `0012_restore_limits` (T40), `0013_record_budgets` (T42), `0014_invite_budget` (T43), `0015_rekeys` (T52), `0016_records_author` (T63). If a file number is taken when you get there, use the next free number and rename consistently.
2. **Room versions:** current is 8. Each task that adds an entity/column bumps by one from whatever the database version is at that moment, with `AutoMigration(from = N, to = N + 1)`; never reuse a number.
3. **`network.publish`** is defined once, in Task 32 (public, network-signed records only). Task 52 does **not** add a second RPC: it extends Task 32's handler to accept `REKEY` (the text was renamed from `admin.publish`).
4. **`MessageKind`:** `SYSTEM_MEMBER = 7` (Task 37), `SYSTEM_KEY_CHANGED = 8` (Task 54).
5. **`SecureWindow`** moves to `core/ui` with a per-window hold counter in Task 25. Task 68 reuses that component (adds app-wide FLAG_SECURE on top) instead of moving it again.
6. **`DirectoryEntry` field 11** is `invite_proof` (a signature by a one-time key derived from the invite secret), not the raw secret — the secret never leaves the inviter's and invitee's phones (Task 30).
7. **Manifest:** `sig_v1_until_ms = 7` (T50), `founding_members = 8` (T33). **`BackupAuthResponse.candidates = 10`** (T34).
8. **Restore code** (`RestoreManager`): Tasks 13–15 (profile, signatures, directory check) live inside `download`/`withWords`; Task 39's candidate loop wraps `download`; Task 58 adds the tunnel candidates to `Endpoints`. Apply in task order.
9. **`BackupAuth` server path:** Task 34's username-resolution step runs first, then Task 12's decoy handling, then Task 40's throttling.
10. **`status.sh`:** all additions go into its single SSH call (Tasks 9, 64, 65).
11. Decision numbers D82–D124 are assigned in this plan; if `00-decisions.md` has grown, shift them consistently.

## Owner questions (each task assumes the recommendation; answer before the phase starts)

The full questions sit at the end of each phase section. Summary:

| Phase | Question | Recommendation |
|---|---|---|
| M9.0 | Upgrade ru-1 in the hotfix too | yes |
| M9.0 | Delete all but 3 pre-upgrade DB copies on eeee | yes (copy off first if wanted) |
| M9.1 | Recovery button «Этот телефон снова главный» on the "replaced" screen (Settings unreachable there) | yes |
| M9.1 | C20 via a decoy backup record published by the phone (no shared node secret exists) | yes |
| M9.1 | RPC frame limit 4 MiB (1 MiB would cut honest APK chunks) | yes |
| M9.1 | News announcements also skip phones with notifications off | yes |
| M9.1 | A link-only inviter can't be messaged until the directory confirms them | yes |
| M9.2 | Only admin-invited/founding accounts may invite by default | yes |
| M9.2 | Invite links made before the 0.9.1 upgrade stop working | accept |
| M9.2 | Revocation is permanent and deletes the account's queued mail, prekeys, push tokens | yes |
| M9.2 | Recovery lockout replaced by slow-down (5 fails/h per source, then 30 s doubling to 15 min) | yes |
| M9.3 | Phones sign v2 only after you publish the cut-over manifest (+48 h margin) | yes |
| M9.3 | Re-key in two admin steps; the person reads «Код аккаунта» aloud; their own old history is not recovered | yes |
| M9.3 | Build the restore tunnel (vs "restore only abroad") | build |
| M9.4 | No D31 rename screen (`name#abcd` display is enough) | yes |
| M9.4 | App lock: «Забыли PIN?» via phone screen lock, 1 min default timeout, notifications without text while locked | yes |
| M9.4 | Limits: 32 conn / 30 new per min per IP, 50 req/s, public 20/min, disk floor 1 GiB, 256 MiB undelivered per author | yes |
| M9.4 | `/metrics` on by default, loopback only | yes |

---

## M9.0 — Server hotfix (server 0.8.3)

Repos: `otter-server` and `docs` only (no Android change). Branch `m9-0-hotfix` in both. Server version **0.8.3**.
Rule this phase establishes (D82): **a root-run deploy step never opens, writes, chowns or chmods a path inside a
directory the `otter` user can write.** Work on such paths runs as `otter` (`runuser -u otter --`), and files reach
`otter` as an already-open descriptor on stdin.

**Proto additions:** none beyond the fixed allocations (this phase changes no proto).

**Verified facts** (read 2026-11-14 on `main` = `9a6c3fa`):

| Question | Answer | Source |
|---|---|---|
| How does a release APK reach a node today? | `release-apk.sh` `scp`s it as root to the predictable `/tmp/otter-$sha.apk`, then runs `otter-node apk import` **as root** on that path | `deploy/release-apk.sh:30-31` |
| What does the root import do? | `os.Open(src)` follows symlinks; `os.CreateTemp(d.path)` + `os.Chown(tmp)` + **`os.Chown(d.path)`** to the owner of the data dir. `d.path` = `/var/lib/otter/apk`, inside the otter-owned 0700 `/var/lib/otter`, so `otter` can replace `apk` with a symlink to `/etc` → root chowns `/etc` to `otter` at the next release = root. A symlink at `/tmp/otter-$sha.apk` also makes root `scp` write through it | `internal/apk/dir.go:34-63` |
| Does `apk import` open the DB? | No (`importApks`, "deploy runs it as root while the node is running") | `cmd/otter-node/main.go:124-146` |
| Other root deploy steps that touch otter-writable paths (same class as C3) | **Yes, three.** (1) `install.sh` runs `install -d -o otter -m 0755 /var/lib/otter/site` + `cp -r site/. /var/lib/otter/site/` as root: `install -d` **follows** a symlink planted at `site` (checked locally: `install -d -m 0700 link` changed the target's mode), and `cp` writes **through** symlinks planted inside (checked locally). otter plants `site → /etc`, the next `push.sh` chowns `/etc` to otter. (2) `install.sh` writes invites as root to the predictable `/var/lib/otter/import-<name>` (GNU `install` unlinks first, but the step is the same class). (3) `upgrade.sh` rollback runs `install -o otter … "$backup" /var/lib/otter/node.db` as root reading `$backup` from otter-owned `/var/backups/otter`: a symlink there to `/root/.ssh/id_ed25519` or `/etc/shadow` hands the file to otter. Not affected: `rm -f`/`rm -rf`/`du` (do not follow symlinks), everything under `/etc/otter` (`root:otter 0750`, otter cannot write), `turn keygen`/`reality keygen` (write under `/etc/otter`), `backup.sh --run` (runs as otter) | `deploy/bundle/install.sh:38-43,61-67`, `deploy/upgrade.sh:37-38`, `deploy/bundle/uninstall.sh`, `deploy/status.sh:20` |
| `/var/lib/otter`, `/var/backups/otter` ownership | both `otter:otter 0700`, parents `/var/lib`, `/var/backups` root-owned → otter cannot swap the directories themselves, only their contents | `deploy/bundle/install.sh:37,39` |
| Empty blob key path | `PeerFrame_BlobGet` → goroutine → `svc.LocalChunk` → `Blobs.Read` → `blobDir` slices `h[:2]` → **panic** on a 0-byte key (no recover) → process exits; a 1-byte key does not panic but builds a path from it | `internal/replication/session.go:89-104`, `internal/blobs/dir.go:20-23`, `internal/service/blobs.go:208-217` |
| Other blob-key entry points | client `blob.put/get`: `PutChunk`/`GetChunk` already check `len(key) == 32` (`service/blobs.go:144,162`); replicated `BLOB_META`/`BLOB_FETCHED` checked in `records/validate.go:183,364`; `Keys()` already skips non-32-byte names | as listed |
| Test seam for a hostile peer | `newMesh` + raw `websocket.Dial` to `/x/peer` (as `TestRejectUnknownNode`); `b.repl.dialHandshake(ctx, c, aInfo)` authenticates as a real member node; mesh nodes have `svc.Blobs == nil` (test must set it) | `internal/replication/replication_test.go:85-129,241-267`, `handshake.go:86` |
| DB backup file mode | `VACUUM INTO` creates the file with the process umask → **0644** under `runuser` from a root shell (checked with modernc sqlite v1.62.0 in a scratch module). Pre-creating an **empty** 0600 file with `O_EXCL` works: `VACUUM INTO` fills it and keeps 0600; a non-empty file is refused ("output file already exists") | `internal/store/backup.go:10-15`, scratch test |
| Pre-upgrade copies | `/var/backups/otter/pre-upgrade-<YYYYmmdd-HHMMSS>.db` per upgrade, never pruned (eeee has one per release since 0.1.x). Daily `node-*.db` copies are already pruned to 7 by `backup.sh --run` (as otter) | `deploy/upgrade.sh:18-21`, `deploy/bundle/backup.sh:12-15` |
| Rejected peer IPs | `ServeHTTP` on a failed handshake adds a netlog line `Peer: <source IP>`, direction `in`, result `fail`, class `handshake`; `netlog` keeps the newest 200 lines with no age limit; `Store.Expire` (janitor) does not touch `netlog`. (The same IP is also in the journal via `r.log.Info("peer rejected", "remote", …)`: system journal retention, out of scope) | `internal/replication/replicator.go:99-107`, `internal/store/netlog.go`, `internal/store/janitor.go` |
| Where is the server version? | Only `-ldflags -X main.version=$(VERSION)` at `make release VERSION=x.y.z`; `upgrade-all.sh VERSION` builds it if `dist/otter-node_VERSION_linux_*` is missing. **No version file to bump.** Nodes run **0.8.1** (eeee and ru-1); `dist/` holds up to 0.8.1 | `Makefile:4-7,21-29`, `deploy/upgrade-all.sh:25-28`, `cmd/otter-node/main.go:44` |
| Deploy tests | `deploy/test/scripts_test.sh` (offline, stubbed ssh; **writes into `dist/`**, run only in a scratch copy), `bundle_test.sh`, `e2e.sh` (disposable Debian VM, runs real root steps) | `deploy/test/` |
| `version_ge` helper | `version_ge V MIN` in `deploy/lib.sh` (dev builds and `unknown` are not ≥) | `deploy/lib.sh` |

**Decisions to record:**

- **D82 — Root never handles the node user's files.** A root-run deploy step (`install.sh`, `upgrade.sh`,
  `release-apk.sh`, and any later script) never opens, writes, chowns or chmods a path inside a directory `otter`
  can write (`/var/lib/otter/**`, `/var/backups/otter/**`). Such work runs as `otter` (`runuser -u otter --`); a
  file root holds reaches `otter` as an open descriptor on stdin (`otter-node apk import … -`,
  `otter-node import … -`). Root may create/chmod the top directories `/var/lib/otter` and `/var/backups/otter`
  themselves (their parents are root's). `otter-node apk import` refuses to run as root. `release-apk.sh` streams the
  APK over ssh stdin into a fresh `mktemp -d` (0700, root, unpredictable name under `/root`), checks the SHA-256
  there, then feeds it to the otter-run importer on stdin; it refuses nodes older than 0.8.3. *Why:* a compromised
  node process must not become root (threat model point 4); C3 and three more instances of the same pattern were
  found. Supersedes the "data-dir owner" wording of D68.
- **D83 — Blob keys are exactly 32 bytes everywhere.** `blobs.Dir` returns `blobs.ErrBadKey` for any other length
  (never panics); a peer's `PeerBlobGet` with a malformed key is answered "missing" and logged, the session
  continues; serving one chunk recovers from a panic instead of stopping the node. *Why:* C11, an authenticated
  peer stopped the node with an empty key.
- **D84 — Database copies are private and bounded.** `otter-node backup` creates its output `O_EXCL|O_NOFOLLOW`
  with mode 0600 before `VACUUM INTO`; `upgrade.sh` keeps `/var/backups/otter` at 0700, sets every `*.db` there to
  0600 and keeps the newest **3** `pre-upgrade-*.db` (daily copies stay at 7). Copies stay plaintext: they hold
  ciphertext and metadata, and encryption at rest would need a key on the same host. *Why:* C26.
- **D85 — Connectivity log age limit.** The janitor deletes `netlog` lines not updated for **7 days** (on top of the
  200-line cap, D74); a source IP that keeps knocking stays visible until 7 days after its last attempt. *Why:*
  C25, rejected source IPs were kept forever.

---

### Task 1: Blob keys are exactly 32 bytes in `blobs.Dir` and at the peer boundary

**Goal:** No blob key of the wrong length from a peer (or anywhere) can panic the node or name a directory.

**Findings closed:** C11

**Files:**
- Modify: `otter-server/internal/blobs/dir.go` (whole file, `blobDir` at 20-23)
- Modify: `otter-server/internal/replication/session.go:89-104` (`PeerFrame_BlobGet` case)
- Test: `otter-server/internal/blobs/dir_test.go` (append), `otter-server/internal/replication/hostile_test.go` (new)

**Acceptance Criteria:**
- [ ] Branch `m9-0-hotfix` exists in `otter-server` and `docs` (from `main`).
- [ ] `blobs.Dir.Write/Read/Remove` return an error wrapping `blobs.ErrBadKey` for 0, 1, 31 and 33-byte keys and
  create nothing on disk.
- [ ] A peer authenticated with a real member node key sends `PeerBlobGet` with 0/1/31/33-byte keys: each is
  answered `Missing`, the node keeps running, the same session then serves a well-formed request.
- [ ] The blob-chunk goroutine in `session.run` recovers a panic, logs it and answers "missing".

**Verify:** `cd otter-server && go test -race -count=1 ./internal/blobs/ ./internal/replication/` → `ok` twice

**Steps:**

- [ ] **Step 1: Branches**

```bash
cd ~/Documents/Projects/OttterMSG
for r in otter-server docs; do git -C $r checkout main && git -C $r pull --ff-only && git -C $r checkout -b m9-0-hotfix; done
export PATH=/usr/lib/go-1.26/bin:$HOME/go/bin:$PATH
```

- [ ] **Step 2: Failing test for `blobs.Dir`** — append to `otter-server/internal/blobs/dir_test.go`:

```go
func TestBadKeysRefused(t *testing.T) {
	root := filepath.Join(t.TempDir(), "blobs")
	d, err := New(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, k := range [][]byte{nil, {0xab}, make([]byte, 31), make([]byte, 33)} {
		if err := d.Write(k, 0, []byte("x")); !errors.Is(err, ErrBadKey) {
			t.Fatalf("write %d-byte key: %v", len(k), err)
		}
		if _, err := d.Read(k, 0); !errors.Is(err, ErrBadKey) {
			t.Fatalf("read %d-byte key: %v", len(k), err)
		}
		if err := d.Remove(k); !errors.Is(err, ErrBadKey) {
			t.Fatalf("remove %d-byte key: %v", len(k), err)
		}
	}
	if e, _ := os.ReadDir(root); len(e) != 0 {
		t.Fatalf("bad keys created %d entries", len(e))
	}
}
```

- [ ] **Step 3: Failing hostile-peer test** — create `otter-server/internal/replication/hostile_test.go`:

```go
package replication

import (
	"bytes"
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"ottermsg/server/internal/blobs"
	pb "ottermsg/server/internal/proto/otterv1"
)

// A member node turned hostile (it holds b's real node key) asks node a for blob chunks with malformed keys.
// Before the fix an empty key panicked a's chunk goroutine and stopped the whole node (C11).
func TestHostilePeerMalformedBlobKeys(t *testing.T) {
	m := newMesh(t, 2, false)
	a, b := m.nodes[0], m.nodes[1]
	bd, err := blobs.New(filepath.Join(t.TempDir(), "blobs"))
	if err != nil {
		t.Fatal(err)
	}
	a.svc.Blobs = bd
	var aInfo *pb.NodeInfo
	for _, n := range b.svc.CurrentManifest().Nodes {
		if bytes.Equal(n.NodeId, a.id) {
			aInfo = n
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	c, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(a.srv.URL, "http")+"/x/peer", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer c.CloseNow()
	c.SetReadLimit(maxFrame)
	if err := b.repl.dialHandshake(ctx, c, aInfo); err != nil {
		t.Fatal(err)
	}
	ask := func(req uint64, key []byte) *pb.PeerBlobChunk {
		t.Helper()
		if err := writeFrame(ctx, c, &pb.PeerFrame{Kind: &pb.PeerFrame_BlobGet{BlobGet: &pb.PeerBlobGet{Req: req, BlobKey: key}}}); err != nil {
			t.Fatalf("req %d: send: %v", req, err)
		}
		for {
			f, _, err := readFrame(ctx, c)
			if err != nil {
				t.Fatalf("req %d (%d-byte key): session closed: %v", req, len(key), err)
			}
			if ch := f.GetBlobChunk(); ch != nil && ch.Req == req {
				return ch
			}
		}
	}
	for i, k := range [][]byte{nil, {0xab}, make([]byte, 31), make([]byte, 33)} {
		if ch := ask(uint64(i+1), k); !ch.Missing || ch.Data != nil {
			t.Fatalf("%d-byte key answered %+v", len(k), ch)
		}
	}
	// the same session still serves a well-formed request (unknown blob → missing)
	if ch := ask(99, make([]byte, 32)); !ch.Missing {
		t.Fatalf("valid key: %+v", ch)
	}
	if !a.repl.reg.has(b.id) {
		t.Fatal("session dropped")
	}
}
```

- [ ] **Step 4: Run, expect FAIL**

```bash
cd ~/Documents/Projects/OttterMSG/otter-server
go test -count=1 -run 'TestBadKeysRefused' ./internal/blobs/        # FAIL: undefined: ErrBadKey
go test -count=1 -run 'TestHostilePeer' ./internal/replication/     # FAIL: panic: runtime error: slice bounds out of range [:2] with length 0
```

- [ ] **Step 5: Implement `blobs.Dir`** — in `otter-server/internal/blobs/dir.go` add `errors`, `fmt` imports and
  replace `blobDir`, `Write` head, `Read`, `Remove`, and the `len(k) != 32` in `Keys`:

```go
// KeyLen is the only valid blob key length: 16-byte owner ‖ 16 random bytes (D45).
const KeyLen = 32

// ErrBadKey: a key that is not KeyLen bytes; it never names a file (C11).
var ErrBadKey = errors.New("blobs: key must be 32 bytes")

func (d *Dir) blobDir(key []byte) (string, error) {
	if len(key) != KeyLen {
		return "", fmt.Errorf("%w (got %d)", ErrBadKey, len(key))
	}
	h := hex.EncodeToString(key)
	return filepath.Join(d.root, h[:2], h), nil
}

// Write stores a chunk atomically (temp file, fsync, rename).
func (d *Dir) Write(key []byte, idx uint32, data []byte) error {
	dir, err := d.blobDir(key)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	// … rest of Write unchanged (CreateTemp … Rename) …
}

// Read returns a chunk; os.ErrNotExist when missing, ErrBadKey for a malformed key.
func (d *Dir) Read(key []byte, idx uint32) ([]byte, error) {
	dir, err := d.blobDir(key)
	if err != nil {
		return nil, err
	}
	return os.ReadFile(filepath.Join(dir, strconv.FormatUint(uint64(idx), 10)))
}

// Remove deletes every chunk of a blob.
func (d *Dir) Remove(key []byte) error {
	dir, err := d.blobDir(key)
	if err != nil {
		return err
	}
	err = os.RemoveAll(dir)
	os.Remove(filepath.Dir(dir)) // prefix dir, only if empty
	return err
}
```

In `Keys`: `if !e.IsDir() || err != nil || len(k) != KeyLen {`.

- [ ] **Step 6: Implement the peer boundary** — in `otter-server/internal/replication/session.go` import
  `"ottermsg/server/internal/blobs"` and replace the `case *pb.PeerFrame_BlobGet:` block:

```go
		case *pb.PeerFrame_BlobGet:
			g := k.BlobGet
			if len(g.BlobKey) != blobs.KeyLen { // hostile or broken peer: answer "missing", keep the session (C11)
				s.r.log.Warn("peer asked for a malformed blob key", "peer", fmt.Sprintf("%x", s.peer), "len", len(g.BlobKey))
				s.send(blobChunk(g.Req, nil))
				continue
			}
			select {
			case s.serveSem <- struct{}{}:
			default: // busy: answer "missing" rather than block replication
				s.send(blobChunk(g.Req, nil))
				continue
			}
			go func() {
				defer func() { <-s.serveSem }()
				defer func() {
					if p := recover(); p != nil { // one bad request must never stop the node (D83)
						s.r.log.Error("serving a blob chunk panicked", "peer", fmt.Sprintf("%x", s.peer), "panic", p)
						s.send(blobChunk(g.Req, nil))
					}
				}()
				data, ok, err := s.r.svc.LocalChunk(s.ctx, g.BlobKey, g.Index)
				if err != nil || !ok {
					data = nil
				}
				s.send(blobChunk(g.Req, data))
			}()
```

- [ ] **Step 7: Run, expect PASS**

```bash
go test -race -count=1 ./internal/blobs/ ./internal/replication/ ./internal/service/ && go vet ./...
```
Expected: `ok` for each package, vet silent.

- [ ] **Step 8: Commit**

```bash
git add internal/blobs/dir.go internal/blobs/dir_test.go internal/replication/session.go internal/replication/hostile_test.go
oc -m "server: refuse blob keys that are not 32 bytes (C11)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `apk.Dir` imports only regular files, never follows a symlink, never chowns

**Goal:** The APK store cannot be steered by symlinks or special files, and has no root-only code path left.

**Findings closed:** C3 (Go half)

**Files:**
- Modify: `otter-server/internal/apk/dir.go:32-66` (`Import`), new `ImportReader`, errors
- Test: `otter-server/internal/apk/dir_test.go` (append)

**Acceptance Criteria:**
- [ ] `Import` of a symlink fails with `ELOOP`; of a FIFO or a directory fails with `ErrNotRegular` without blocking;
  nothing is stored.
- [ ] A symlink planted at the destination name `<sha>.apk` is replaced by the regular file; its target is untouched.
- [ ] `ImportReader` stores a stream; an empty stream fails with `ErrEmpty` and stores nothing (a broken pipe must
  not push a good APK out of the newest-2 set).
- [ ] `grep -n 'Chown\|Geteuid' internal/apk/dir.go` prints nothing.

**Verify:** `cd otter-server && go test -race -count=1 ./internal/apk/` → `ok`

**Steps:**

- [ ] **Step 1: Failing tests** — append to `otter-server/internal/apk/dir_test.go` (add imports `syscall`):

```go
func TestImportRefusesSymlinkAndSpecialFiles(t *testing.T) {
	d, err := New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	orig, _ := writeTemp(t, 100)
	link := filepath.Join(t.TempDir(), "link.apk")
	if err := os.Symlink(orig, link); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Import(link); !errors.Is(err, syscall.ELOOP) {
		t.Fatalf("symlink source: %v", err)
	}
	fifo := filepath.Join(t.TempDir(), "fifo.apk")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { _, err := d.Import(fifo); done <- err }()
	select {
	case err := <-done:
		if !errors.Is(err, ErrNotRegular) {
			t.Fatalf("fifo: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("import blocked on a FIFO")
	}
	if _, err := d.Import(t.TempDir()); !errors.Is(err, ErrNotRegular) {
		t.Fatalf("directory: %v", err)
	}
	if e, _ := os.ReadDir(d.path); len(e) != 0 {
		t.Fatalf("stored %d entries", len(e))
	}
}

// Regression guard: rename replaces a planted link and never writes through it.
func TestImportReplacesPlantedSymlinkAtDestination(t *testing.T) {
	d, err := New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	src, data := writeTemp(t, 100)
	sum := sha256.Sum256(data)
	victim := filepath.Join(t.TempDir(), "victim")
	if err := os.WriteFile(victim, []byte("keep me"), 0o600); err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(d.path, hexName(sum[:]))
	if err := os.Symlink(victim, dst); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Import(src); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(victim); string(b) != "keep me" {
		t.Fatal("wrote through the planted symlink")
	}
	if st, err := os.Lstat(dst); err != nil || !st.Mode().IsRegular() {
		t.Fatalf("destination: %v %v", st, err)
	}
}

func TestImportReader(t *testing.T) {
	d, err := New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	data := bytes.Repeat([]byte{7}, 3000)
	sum, err := d.ImportReader(bytes.NewReader(data))
	want := sha256.Sum256(data)
	if err != nil || !bytes.Equal(sum, want[:]) {
		t.Fatalf("import: %x %v", sum, err)
	}
	if _, err := d.ImportReader(bytes.NewReader(nil)); !errors.Is(err, ErrEmpty) {
		t.Fatalf("empty stream: %v", err)
	}
	if files, _ := filepath.Glob(filepath.Join(d.path, "*.apk")); len(files) != 1 {
		t.Fatalf("files: %v", files)
	}
}
```

- [ ] **Step 2: Run, expect FAIL**

```bash
go test -count=1 ./internal/apk/
```
Expected: build failure `undefined: ErrNotRegular` / `d.ImportReader undefined` (and, with stubs, the symlink
import succeeding and the FIFO test blocking).

- [ ] **Step 3: Implement** — in `otter-server/internal/apk/dir.go` add `errors` to the imports (keep `syscall` for
  the open flags) and replace `Import`:

```go
var (
	ErrNotRegular = errors.New("apk: not a regular file")
	ErrEmpty      = errors.New("apk: empty file")
)

// Import copies the regular file src into the directory under its SHA-256 and prunes old files. Returns the sum.
// src is opened without following a symlink and must be a regular file (O_NONBLOCK: a FIFO cannot stall it).
// Runs as the node user only: `otter-node apk import` refuses root (C3, D82).
func (d *Dir) Import(src string) ([]byte, error) {
	in, err := os.OpenFile(src, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	defer in.Close()
	st, err := in.Stat()
	if err != nil {
		return nil, err
	}
	if !st.Mode().IsRegular() {
		return nil, fmt.Errorf("%s: %w", src, ErrNotRegular)
	}
	return d.ImportReader(in)
}

// ImportReader stores everything read from r (deploy streams the APK on stdin) and prunes old files.
func (d *Dir) ImportReader(r io.Reader) ([]byte, error) {
	tmp, err := os.CreateTemp(d.path, ".import-*")
	if err != nil {
		return nil, err
	}
	defer os.Remove(tmp.Name())
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(tmp, h), r)
	if err != nil {
		tmp.Close()
		return nil, err
	}
	if n == 0 {
		tmp.Close()
		return nil, ErrEmpty
	}
	if err := tmp.Chmod(0o640); err != nil {
		tmp.Close()
		return nil, err
	}
	if err := tmp.Close(); err != nil {
		return nil, err
	}
	sum := h.Sum(nil)
	// rename replaces whatever holds the final name (a planted symlink included) and never writes through it
	if err := os.Rename(tmp.Name(), filepath.Join(d.path, hexName(sum))); err != nil {
		return nil, err
	}
	d.prune()
	return sum, nil
}
```

The old `Import` body with the `os.Stat(filepath.Dir(d.path))` / `os.Geteuid()` / two `os.Chown` calls is deleted.

- [ ] **Step 4: Run, expect PASS**

```bash
go test -race -count=1 ./internal/apk/ && grep -n 'Chown\|Geteuid' internal/apk/dir.go; echo "grep exit $?"
```
Expected: `ok`, then `grep exit 1`.

- [ ] **Step 5: Commit**

```bash
git add internal/apk/dir.go internal/apk/dir_test.go
oc -m "apk: import regular files only, no symlinks, no chown (C3)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `otter-node apk import` refuses root; `apk import` and `import` read `-` from stdin

**Goal:** The CLI can take an APK or a record as an open descriptor from root, and cannot be run as root for APKs.

**Findings closed:** C3 (CLI half), D82 prerequisite for Tasks 4–5

**Files:**
- Modify: `otter-server/cmd/otter-node/main.go:46-58` (usage), `:112-122` (`importFile`), `:124-146` (`importApks`)
- Test: `otter-server/cmd/otter-node/main_test.go` (append; add `"errors"` import)

**Acceptance Criteria:**
- [ ] `otter-node apk import` with euid 0 fails with "never as root" before creating `<data_dir>/apk`.
- [ ] `otter-node apk import --config F -` stores stdin and prints `-: stored <hex>`; a symlink path is refused.
- [ ] `otter-node import --config F -` applies a record read from stdin (`-: applied`).
- [ ] Usage text shows `APK...|-` and `FILE...|-`.

**Verify:** `cd otter-server && go test -race -count=1 ./cmd/otter-node/ -run 'Apk|Import'` → `ok`

**Steps:**

- [ ] **Step 1: Failing tests** — append to `otter-server/cmd/otter-node/main_test.go`:

```go
func TestApkImportRefusesRoot(t *testing.T) {
	cfg, _, _, _, _ := testNode(t)
	apkFile := filepath.Join(t.TempDir(), "x.apk")
	if err := os.WriteFile(apkFile, []byte("apk"), 0o644); err != nil {
		t.Fatal(err)
	}
	geteuid = func() int { return 0 }
	defer func() { geteuid = os.Geteuid }()
	err := run(context.Background(), []string{"apk", "import", "--config", cfg, apkFile}, io.Discard)
	if err == nil || !strings.Contains(err.Error(), "never as root") {
		t.Fatalf("root import: %v", err)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(cfg), "data", "apk")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("apk dir touched as root: %v", err)
	}
}

func TestApkImportFromStdin(t *testing.T) {
	cfg, _, _, _, _ := testNode(t)
	data := bytes.Repeat([]byte("apk!"), 1000)
	stdin = bytes.NewReader(data)
	defer func() { stdin = os.Stdin }()
	var out bytes.Buffer
	if err := run(context.Background(), []string{"apk", "import", "--config", cfg, "-"}, &out); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(data)
	if want := fmt.Sprintf("-: stored %x\n", sum); out.String() != want {
		t.Fatalf("output %q, want %q", out.String(), want)
	}
	orig := filepath.Join(t.TempDir(), "orig.apk")
	os.WriteFile(orig, data, 0o644)
	link := filepath.Join(t.TempDir(), "link.apk")
	os.Symlink(orig, link)
	if err := run(context.Background(), []string{"apk", "import", "--config", cfg, link}, &out); err == nil {
		t.Fatal("symlink imported")
	}
}

func TestImportRecordFromStdin(t *testing.T) {
	cfg, manifest, _, _, _ := testNode(t)
	raw, err := os.ReadFile(manifest)
	if err != nil {
		t.Fatal(err)
	}
	stdin = bytes.NewReader(raw)
	defer func() { stdin = os.Stdin }()
	var out bytes.Buffer
	if err := run(context.Background(), []string{"import", "--config", cfg, "-"}, &out); err != nil {
		t.Fatal(err)
	}
	if out.String() != "-: applied\n" {
		t.Fatalf("output %q", out.String())
	}
}
```

- [ ] **Step 2: Run, expect FAIL** — `go test -count=1 ./cmd/otter-node/ -run 'Apk|Import'` → build failure
  `undefined: geteuid`, `undefined: stdin`.

- [ ] **Step 3: Implement** in `otter-server/cmd/otter-node/main.go`:

```go
// geteuid and stdin are variables so tests can play root and feed stdin.
var (
	geteuid           = os.Geteuid
	stdin   io.Reader = os.Stdin
)
```

Usage lines:

```
  import --config FILE FILE...|-   apply signed record files (manifest, bootstrap invite); - = stdin
  apk import --config FILE APK...|-   store app update files served by apk.get (keeps the newest 2); - = stdin; never as root
```

`importFile`:

```go
func importFile(ctx context.Context, svc *service.Service, path string) (bool, error) {
	var raw []byte
	var err error
	if path == "-" { // deploy hands a root-held file to the otter user as an open descriptor (D82)
		raw, err = io.ReadAll(stdin)
	} else {
		raw, err = os.ReadFile(path)
	}
	if err != nil {
		return false, err
	}
	var rec pb.Record
	if err := proto.Unmarshal(raw, &rec); err != nil {
		return false, fmt.Errorf("%s: not a record: %w", path, err)
	}
	return svc.ImportRecord(ctx, &rec)
}
```

`importApks`:

```go
// importApks stores APK files in <data_dir>/apk (D68). It does not open the database, so it runs while the node
// runs. Never as root (C3, D82): deploy runs `runuser -u otter -- otter-node apk import --config F - < file`.
func importApks(cfgPath string, files []string, out io.Writer) error {
	if len(files) == 0 {
		return errors.New("usage: otter-node apk import --config FILE APK...|-")
	}
	if geteuid() == 0 {
		return errors.New("apk import: run it as the node user (runuser -u otter -- otter-node apk import ...), never as root")
	}
	cfg, err := config.Load(cfgPath)
	if err != nil {
		return err
	}
	d, err := apk.New(filepath.Join(cfg.DataDir, "apk"))
	if err != nil {
		return err
	}
	for _, f := range files {
		var sum []byte
		if f == "-" {
			sum, err = d.ImportReader(stdin)
		} else {
			sum, err = d.Import(f)
		}
		if err != nil {
			return fmt.Errorf("%s: %w", f, err)
		}
		fmt.Fprintf(out, "%s: stored %x\n", f, sum)
	}
	return nil
}
```

Also change the two other usage strings `"usage: otter-node apk import --config FILE APK..."` in `run` (lines 176-179)
to end in `APK...|-`.

- [ ] **Step 4: Run, expect PASS** — `go test -race -count=1 ./cmd/otter-node/` → `ok` (the existing
  `TestApkImport` still passes as a normal user).

- [ ] **Step 5: Commit**

```bash
git add cmd/otter-node/main.go cmd/otter-node/main_test.go
oc -m "otter-node: apk import refuses root; import and apk import read - from stdin (C3)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `release-apk.sh` streams the APK into a root-only temp dir and imports it as `otter`

**Goal:** Releasing an APK never lets root touch a path `otter` can write, and refuses nodes older than 0.8.3.

**Findings closed:** C3 (deploy half)

**Files:**
- Modify: `otter-server/deploy/release-apk.sh:24-33`
- Test: `otter-server/deploy/test/scripts_test.sh:136-182` (release-apk section)

**Acceptance Criteria:**
- [ ] No `scp`, no `/tmp/otter-…` path; the APK goes over `ssh` stdin.
- [ ] The remote command creates `mktemp -d /root/otter-apk.XXXXXX`, writes `app.apk` there, checks the SHA-256,
  runs `runuser -u otter -- /usr/local/bin/otter-node apk import --config /etc/otter/node.toml - < "$d/app.apk"`
  and removes the dir on exit (trap).
- [ ] Executed locally against stubs: a good stream is imported byte-identical and the temp dir is gone; a wrong
  SHA imports nothing.
- [ ] A node reporting `0.8.1` stops the release before anything is sent ("upgrade it to 0.8.3").
- [ ] A failing import on one node stops with `apk import on n2 failed`.

**Verify:** scratch copy (the test writes `dist/`):
`d=$(mktemp -d) && rsync -a --exclude dist --exclude .dev-mesh --exclude .vm ~/Documents/Projects/OttterMSG/otter-server/ $d/srv/ && (cd $d/srv && deploy/test/scripts_test.sh)` → `scripts test: ok`

**Steps:**

- [ ] **Step 1: Failing test** — in `otter-server/deploy/test/scripts_test.sh`, keep the stubs for `apksigner`,
  `aapt2`, `otter-admin` and the debug/old-APK cases (lines 136-169), and replace the lines from
  `out=$(PATH="$work/stub:$PATH" deploy/release-apk.sh 0.0.0-st "$work/good.apk" < /dev/null 2>&1) || fail …`
  through `grep -q 'upload to n2 failed' …` (lines 171-181) with:

```bash
# release-apk uses its own ssh stub: it answers 'version', records the remote command as the remote shell would
# split it, and keeps what arrived on stdin (C3: the APK travels on ssh stdin, never via scp or /tmp)
mkdir -p "$work/stub-apk"
cat > "$work/stub-apk/ssh" <<STUB
#!/bin/bash
echo "ssh \$*" >> "$work/ssh.log"
target=\$3; shift 3
case "\$*" in *"otter-node version"*) echo "\${NODE_VERSION:-0.8.3}"; exit 0 ;; esac
eval "set -- \$*"
printf '%s\n' "\$@" > "$work/remote-\$target.cmd"
cat > "$work/remote-\$target.stdin"
case "\$target" in *"\$SSH_FAIL"*) [ -n "\$SSH_FAIL" ] && exit 1 ;; esac
exit 0
STUB
chmod +x "$work/stub-apk/ssh"
apkpath="$work/stub-apk:$work/stub:$PATH"
if out=$(NODE_VERSION=0.8.1 PATH="$apkpath" deploy/release-apk.sh 0.0.0-st "$work/good.apk" --no-news 2>&1); then fail "release to a 0.8.1 node accepted"; fi
grep -q 'runs otter-node 0.8.1: upgrade it to 0.8.3' <<< "$out" || fail "old node message: $out"
[[ ! -e "$work/remote-root@n1.example.stdin" ]] || fail "APK sent to an old node"
out=$(PATH="$apkpath" deploy/release-apk.sh 0.0.0-st "$work/good.apk" < /dev/null 2>&1) || fail "release-apk: $out"
sha=$(sha256sum "$work/good.apk" | cut -d' ' -f1)
if grep -q '^scp\|/tmp/otter-' "$work/ssh.log"; then fail "release-apk still uses scp or /tmp: $(cat "$work/ssh.log")"; fi
for t in root@n1.example root@n2.example; do
  cmp -s "$work/remote-$t.stdin" "$work/good.apk" || fail "$t: APK not streamed on stdin"
  c="$work/remote-$t.cmd"
  [[ "$(sed -n 1,2p "$c" | tr '\n' ' ')" == "bash -c " ]] || fail "$t: not bash -c: $(cat "$c")"
  grep -qF 'd=$(mktemp -d /root/otter-apk.XXXXXX)' "$c" || fail "$t: no root-only temp dir: $(cat "$c")"
  grep -qF 'sha256sum --quiet -c' "$c" || fail "$t: no checksum: $(cat "$c")"
  grep -qF 'runuser -u otter -- /usr/local/bin/otter-node apk import --config /etc/otter/node.toml - < "$d/app.apk"' "$c" ||
    fail "$t: import not as otter from stdin: $(cat "$c")"
  [[ "$(sed -n 5p "$c")" == "$sha" ]] || fail "$t: sha not passed: $(cat "$c")"
done
grep -q "news: deploy/news-dialog.sh 0.0.0-st --apk .*good.apk --version-code 6" <<< "$out" || fail "release-apk news hint: $out"
[[ ! -e "$work/announce.log" ]] || fail "release-apk announced without a terminal"
# run the remote script itself with stub runuser/otter-node: imported as sent, temp dir removed; a bad sum imports nothing
ra="$work/remote-apk"; mkdir -p "$ra/bin" "$ra/root"
printf '#!/bin/sh\nshift 3; exec "$@"\n' > "$ra/bin/runuser"
printf '#!/bin/sh\ncat > "%s/imported"\n' "$ra" > "$ra/bin/otter-node"
chmod +x "$ra/bin/"*
script=$(sed -n 3p "$work/remote-root@n1.example.cmd" | sed -e "s#/root/otter-apk#$ra/root/otter-apk#" -e "s#/usr/local/bin/otter-node#otter-node#")
PATH="$ra/bin:$PATH" bash -c "$script" import "$sha" < "$work/good.apk" || fail "remote script failed"
cmp -s "$ra/imported" "$work/good.apk" || fail "remote script: imported bytes differ"
[[ -z "$(ls -A "$ra/root")" ]] || fail "remote script left its temp dir"
rm -f "$ra/imported"
if PATH="$ra/bin:$PATH" bash -c "$script" import "$(printf '0%.0s' {1..64})" < "$work/good.apk" 2>/dev/null; then fail "bad sum accepted"; fi
[[ ! -e "$ra/imported" ]] || fail "bad sum imported"
rm -f "$work/ssh.log" "$work"/remote-root@*
if out=$(SSH_FAIL=n2.example PATH="$apkpath" deploy/release-apk.sh 0.0.0-st "$work/good.apk" --no-news 2>&1); then fail "failed import ignored"; fi
grep -q 'apk import on n2 failed' <<< "$out" || fail "import failure message: $out"
```

- [ ] **Step 2: Run in a scratch copy, expect FAIL** (Verify command) → `scripts test: FAIL: release to a 0.8.1 node accepted`.

- [ ] **Step 3: Implement** — in `otter-server/deploy/release-apk.sh` replace lines 24-33 (from `labels=$(node_labels)`
  through the end of the copy loop) with:

```bash
labels=$(node_labels)
for l in $labels; do host_lookup "$l" || die "node $l has no SSH target: deploy/hosts.sh set $l root@HOST"; done
# C3 (D82): nodes before 0.8.3 import APKs as root; refuse them before anything is sent
for l in $labels; do
  host_lookup "$l"
  export OTTER_SSH_PORT=$TARGET_PORT SSH_PORT=$TARGET_PORT
  v=$(remote "$TARGET" /usr/local/bin/otter-node version < /dev/null) || die "cannot reach $l"
  version_ge "$v" 0.8.3 || die "node $l runs otter-node $v: upgrade it to 0.8.3 or newer first (deploy/upgrade-all.sh)"
done
# The APK arrives on ssh stdin in a fresh root-only directory (mktemp -d: 0700, unpredictable name), is checked
# there, and reaches the importer, which runs as otter, only as an open file on its stdin. Root never opens a path
# the node user can write (C3, D82).
import_cmd='set -euo pipefail; d=$(mktemp -d /root/otter-apk.XXXXXX); trap '"'"'rm -rf "$d"'"'"' EXIT; cat > "$d/app.apk"; echo "$1  $d/app.apk" | sha256sum --quiet -c; runuser -u otter -- /usr/local/bin/otter-node apk import --config /etc/otter/node.toml - < "$d/app.apk"'
for l in $labels; do
  host_lookup "$l"
  export OTTER_SSH_PORT=$TARGET_PORT SSH_PORT=$TARGET_PORT
  say "copying APK $version ($code) to $l"
  remote "$TARGET" "bash -c $(printf '%q' "$import_cmd") import $sha" < "$apk" \
    || die "apk import on $l failed (run release-apk.sh again)"
done
```

  `printf '%q'` yields a backslash-escaped single word (no newlines in `import_cmd`), so the remote login shell
  passes it to `bash -c` unchanged; `$1` inside is the SHA.

- [ ] **Step 4: Run in a scratch copy, expect PASS** (Verify command) → `scripts test: ok`.

- [ ] **Step 5: Commit**

```bash
git add deploy/release-apk.sh deploy/test/scripts_test.sh
oc -m "deploy: release-apk streams the APK to a root-only temp dir and imports it as otter (C3)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `install.sh` and the `upgrade.sh` rollback stop writing into otter's directories as root

**Goal:** The other three root steps of the C3 class (site copy, invite import, DB restore) run as `otter`.

**Findings closed:** C3 class (found in this review, no audit number): `install.sh:38-43,61-67`, `upgrade.sh:37-38`

**Files:**
- Modify: `otter-server/deploy/bundle/install.sh:36-43` (dirs, site), `:59-67` (invites)
- Modify: `otter-server/deploy/upgrade.sh:37-38` (rollback restore)
- Test: `otter-server/deploy/test/scripts_test.sh` (static section after line 268), `otter-server/deploy/test/e2e.sh`
  (VM attack steps)

**Acceptance Criteria:**
- [ ] `install.sh`: no `install -d … /var/lib/otter/site`, no root `cp` into `/var/lib/otter`, no `chown -R` there;
  the site is unpacked by `tar` running as otter; invites are imported with
  `runuser -u otter -- /usr/local/bin/otter-node import --config /etc/otter/node.toml - < "$f"`.
- [ ] `upgrade.sh` rollback restores with `runuser -u otter -- install -m 0600 "$backup" /var/lib/otter/node.db`
  and removes WAL/SHM as otter.
- [ ] Static check in `scripts_test.sh`: every line of `install.sh`, `upgrade.sh`, `release-apk.sh` that names
  `/var/lib/otter` or `/var/backups/otter` either runs under `runuser -u otter --`, is the root `install -d … 0700`
  of the top directory, or is the `backup=` assignment.
- [ ] `e2e.sh` (VM): with `site → /etc` and `apk → /etc` planted by otter, a re-install fails and an otter import
  fails, `/etc` stays `root`; a root `apk import` is refused.

**Verify:** scratch copy → `scripts test: ok`; owner-optional VM run: `cd otter-server && deploy/test/e2e.sh` → ends
with the e2e ok line (needs qemu and the cached Debian image; local only, no real server).

**Steps:**

- [ ] **Step 1: Failing static test** — insert in `otter-server/deploy/test/scripts_test.sh` after the
  `grep -q 'OTTER_TURN_UFW=\$turn_ufw ./bundle-' deploy/push.sh …` line:

```bash
# --- root-run steps never write into the node user's directories (C3 class, D82)
grep -nH '/var/lib/otter\|/var/backups/otter' deploy/bundle/install.sh deploy/upgrade.sh deploy/release-apk.sh |
  grep -v -e 'runuser -u otter --' -e 'install -d -o otter -g otter -m 0700 /var/\(lib\|backups\)/otter$' \
    -e ':backup=/var/backups/otter/pre-upgrade-' > "$work/rootwrites" || true
[[ ! -s "$work/rootwrites" ]] || fail "root-run lines touching otter's directories: $(cat "$work/rootwrites")"
grep -qF 'runuser -u otter -- /usr/local/bin/otter-node import --config /etc/otter/node.toml - < "$f"' deploy/bundle/install.sh ||
  fail "install.sh: invites not imported as otter from stdin"
```

- [ ] **Step 2: Run in a scratch copy, expect FAIL** → `root-run lines touching otter's directories:
  deploy/bundle/install.sh:38:install -d -o otter -g otter -m 0755 /var/lib/otter/site …`.

- [ ] **Step 3: Implement `install.sh`** — replace lines 36-43:

```bash
say "installing files"
install -d -o root -g otter -m 0750 /etc/otter
install -d -o otter -g otter -m 0700 /var/lib/otter
install -d -o otter -g otter -m 0700 /var/backups/otter
install -d -o root -g root -m 0755 /usr/local/lib/otter
install -o root -g otter -m 0640 node.key tls.key node.toml manifest.bin tls.crt probe.env /etc/otter/
# otter's data directory: root never writes inside it (D82). otter unpacks the decoy site itself, so a link
# planted there can only point otter at what otter may already write. (Comments here must not name the path:
# scripts_test.sh flags every root line that does.)
runuser -u otter -- mkdir -p -m 0755 /var/lib/otter/site
tar -C site -cf - . | runuser -u otter -- tar -C /var/lib/otter/site --no-same-owner --no-same-permissions -xf -
```

  and replace the invite loop (lines 60-67):

```bash
shopt -s nullglob
for f in invites/*.bin; do
  say "importing $(basename "$f")"
  # the bundle directory is root-only: root opens the file, otter reads it on stdin (D82)
  runuser -u otter -- /usr/local/bin/otter-node import --config /etc/otter/node.toml - < "$f"
done
```

  (The bundle's binary is installed to `/usr/local/bin/otter-node` earlier in the same run, so `-` is supported.)

- [ ] **Step 4: Implement `upgrade.sh` rollback** — replace lines 37-38:

```bash
runuser -u otter -- rm -f /var/lib/otter/node.db-wal /var/lib/otter/node.db-shm
# as otter: the backup sits in otter's directory and could be a planted link (D82)
runuser -u otter -- install -m 0600 "$backup" /var/lib/otter/node.db
```

- [ ] **Step 5: VM attack steps** — in `otter-server/deploy/test/e2e.sh`, after the line
  `[[ "$(vmsh /usr/local/bin/otter-node version)" == 0.0.1-e2e ]] || fail "installed version"` add:

```bash
step "root deploy steps never follow the node user's links (C3, D82)"
if vmsh /usr/local/bin/otter-node apk import --config /etc/otter/node.toml /etc/hostname; then fail "apk import ran as root"; fi
vmsh 'runuser -u otter -- sh -c "rm -rf /var/lib/otter/apk && ln -s /etc /var/lib/otter/apk"'
if printf 'apk' | vmsh 'runuser -u otter -- /usr/local/bin/otter-node apk import --config /etc/otter/node.toml -'; then
  fail "otter wrote an APK into /etc"
fi
vmsh 'runuser -u otter -- sh -c "mv /var/lib/otter/site /var/lib/otter/site.real && ln -s /etc /var/lib/otter/site"'
deploy/make-bundle.sh vm 0.0.1-e2e >/dev/null
if deploy/push.sh vm "$T" >/dev/null 2>&1; then fail "install followed the planted site link"; fi
[[ "$(vmsh stat -c %U:%G /etc)" == root:root ]] || fail "/etc owner changed"
vmsh 'test -z "$(find /etc -maxdepth 1 -user otter)"' || fail "otter-owned files in /etc"
vmsh 'rm /var/lib/otter/apk /var/lib/otter/site && mv /var/lib/otter/site.real /var/lib/otter/site'
deploy/make-bundle.sh vm 0.0.1-e2e >/dev/null
deploy/push.sh vm "$T" >/dev/null || fail "re-install after cleanup"
```

  (`push.sh` exits non-zero when `install.sh` fails under `set -e` because otter's `tar` cannot write into `/etc`.
  If `make-bundle.sh` refuses a second bundle because the bootstrap invite is already delivered, run it with the
  same arguments the first `push.sh` used; check this when first running the step.)

- [ ] **Step 6: Run** the scratch-copy scripts test → `scripts test: ok`; `bash -n deploy/bundle/install.sh deploy/upgrade.sh`
  silent. Ask the owner whether to run `deploy/test/e2e.sh` now (local VM, ~5 min).

- [ ] **Step 7: Commit**

```bash
git add deploy/bundle/install.sh deploy/upgrade.sh deploy/test/scripts_test.sh deploy/test/e2e.sh
oc -m "deploy: install and rollback handle otter's files as otter, never as root (C3 class)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Database copies are 0600 in a 0700 directory; 3 pre-upgrade copies kept

**Goal:** Backups cannot be read by other local users and pre-upgrade copies stop piling up.

**Findings closed:** C26

**Files:**
- Modify: `otter-server/internal/store/backup.go:10-15`
- Modify: `otter-server/deploy/upgrade.sh:18-21`
- Test: `otter-server/internal/store/backup_test.go` (append), `otter-server/deploy/test/scripts_test.sh` (after the
  `# --- upgrade.sh keeps node.toml.prev …` block, line 83)

**Acceptance Criteria:**
- [ ] `Store.Backup` output is mode 0600 under umask 022; a planted (dangling) symlink at `--out` is refused and its
  target is not created; an existing file is still refused; a failed `VACUUM INTO` leaves no empty file.
- [ ] `upgrade.sh` (remote part, run locally against a fake tree): `/var/backups/otter` ends 0700, every `*.db` 0600,
  exactly the newest 3 `pre-upgrade-*.db` remain, `node-*.db` daily copies untouched; all pruning/chmod run as otter.

**Verify:** `cd otter-server && go test -race -count=1 ./internal/store/ -run Backup` → `ok`; scratch-copy
`scripts_test.sh` → `scripts test: ok`

**Steps:**

- [ ] **Step 1: Failing Go test** — append to `otter-server/internal/store/backup_test.go` (imports `errors`,
  `io/fs`, `os`, `syscall`):

```go
func TestBackupIsPrivateAndRefusesLinks(t *testing.T) {
	old := syscall.Umask(0o022)
	defer syscall.Umask(old)
	s, _ := open(t)
	ctx := context.Background()
	out := filepath.Join(t.TempDir(), "copy.db")
	if err := s.Backup(ctx, out); err != nil {
		t.Fatal(err)
	}
	if st, err := os.Stat(out); err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("backup mode: %v %v", st.Mode(), err)
	}
	target := filepath.Join(t.TempDir(), "victim.db")
	link := filepath.Join(t.TempDir(), "link.db")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if err := s.Backup(ctx, link); err == nil {
		t.Fatal("backup through a planted link")
	}
	if _, err := os.Lstat(target); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("link target created: %v", err)
	}
}
```

- [ ] **Step 2: Run, expect FAIL** — `go test -count=1 ./internal/store/ -run Backup` → `backup mode: -rw-r--r-- <nil>`.

- [ ] **Step 3: Implement** — `otter-server/internal/store/backup.go`:

```go
package store

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"syscall"
)

// Backup writes a consistent copy of the database to path, which must not exist yet. Safe while the node runs.
// The copy is created 0600 whatever the umask (C26), and O_EXCL|O_NOFOLLOW refuses an existing file or a planted
// link; VACUUM INTO fills an existing empty file and keeps its mode.
func (s *Store) Backup(ctx context.Context, path string) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		if errors.Is(err, fs.ErrExist) {
			return fmt.Errorf("%s already exists", path)
		}
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(path)
		return err
	}
	if _, err := s.r.ExecContext(ctx, `VACUUM INTO ?`, path); err != nil {
		os.Remove(path)
		return err
	}
	return nil
}
```

- [ ] **Step 4: Run, expect PASS** — `go test -race -count=1 ./internal/store/` → `ok` (old `TestBackup` still
  refuses overwriting).

- [ ] **Step 5: Failing shell test** — insert after line 83 of `otter-server/deploy/test/scripts_test.sh`:

```bash
# --- upgrade.sh (remote part, run locally): backup dir 0700, copies 0600, newest 3 pre-upgrade copies (C26)
up="$work/up"; mkdir -p "$up/bin" "$up/etc" "$up/lib" "$up/backups"
printf '#!/bin/sh\nshift 3; exec "$@"\n' > "$up/bin/runuser"
printf '#!/bin/bash\nargs=(); while (($#)); do case "$1" in -o|-g) shift 2;; *) args+=("$1"); shift;; esac; done\nexec /usr/bin/install "${args[@]}"\n' > "$up/bin/install"
cat > "$up/bin/otter-node" <<'STUB'
#!/bin/bash
case "$1" in
  version) echo 0.8.1 ;;
  backup) while (($#)); do [[ "$1" == --out ]] && { umask 022; echo db > "$2"; }; shift; done ;;
esac
STUB
printf '#!/bin/sh\nexit 0\n' > "$up/bin/systemctl"; printf '#!/bin/sh\nexit 0\n' > "$up/bin/health.sh"
chmod +x "$up/bin/"*
cp "$up/bin/otter-node" "$up/bin/otter-node.new"; echo 'x = 1' > "$up/etc/node.toml"
chmod 0755 "$up/backups"
for d in 20250101 20250201 20250301 20250401; do (umask 022; echo old > "$up/backups/pre-upgrade-$d-000000.db"); done
(umask 022; echo daily > "$up/backups/node-2026-11-01.db")
sed -n "/^remote \"\$target\" bash -s -- \"\$sum\" <<'REMOTE'$/,/^REMOTE$/p" deploy/upgrade.sh | sed '1d;$d' |
  sed -e "s#/usr/local/bin/otter-node#$up/bin/otter-node#g" -e "s#/var/backups/otter#$up/backups#g" \
      -e "s#/var/lib/otter#$up/lib#g" -e "s#/etc/otter#$up/etc#g" -e "s#/usr/local/lib/otter/health.sh#health.sh#g" > "$work/upgrade-local.sh"
sum=$(sha256sum "$up/bin/otter-node.new" | cut -d' ' -f1)
PATH="$up/bin:$PATH" bash "$work/upgrade-local.sh" "$sum" > "$work/upgrade-local.out" 2>&1 || fail "upgrade remote part: $(cat "$work/upgrade-local.out")"
[[ "$(stat -c %a "$up/backups")" == 700 ]] || fail "backup dir mode $(stat -c %a "$up/backups")"
[[ -z "$(find "$up/backups" -name '*.db' ! -perm 0600)" ]] || fail "backup files not 0600: $(ls -l "$up/backups")"
[[ "$(ls "$up/backups" | grep -c '^pre-upgrade-')" == 3 ]] || fail "pre-upgrade copies kept: $(ls "$up/backups")"
[[ ! -e "$up/backups/pre-upgrade-20250101-000000.db" && ! -e "$up/backups/pre-upgrade-20250201-000000.db" ]] || fail "oldest copies not pruned"
[[ -e "$up/backups/node-2026-11-01.db" ]] || fail "daily copy pruned"
pr=$(grep -n 'pre-upgrade-\*\.db' deploy/upgrade.sh)
grep -q 'runuser -u otter -- find .* | sort -zr | tail -zn +4 | runuser -u otter -- xargs -0r rm -f --' <<< "$pr" || fail "prune not as otter: $pr"
```

- [ ] **Step 6: Run in a scratch copy, expect FAIL** → `backup dir mode 755`.

- [ ] **Step 7: Implement `upgrade.sh`** — replace lines 18-21 (from `ts=` through the `runuser … backup` line):

```bash
ts=$(date +%Y%m%d-%H%M%S)
install -d -o otter -g otter -m 0700 /var/backups/otter
backup=/var/backups/otter/pre-upgrade-$ts.db
say "backing up the database to $backup (installed binary: $(/usr/local/bin/otter-node version))"
runuser -u otter -- /usr/local/bin/otter-node backup --config /etc/otter/node.toml --out "$backup"
# C26 (D84): copies made before 0.8.3 are 0644; keep the newest 3 pre-upgrade copies. All as otter (D82).
runuser -u otter -- find /var/backups/otter -maxdepth 1 -type f -name '*.db' -exec chmod 0600 {} +
runuser -u otter -- find /var/backups/otter -maxdepth 1 -type f -name 'pre-upgrade-*.db' -print0 | sort -zr | tail -zn +4 | runuser -u otter -- xargs -0r rm -f --
```

  (Names sort by their `YYYYmmdd-HHMMSS` stamp; the copy just taken is the newest, so a rollback always has it.)

- [ ] **Step 8: Run, expect PASS** — scratch-copy `scripts_test.sh` → `scripts test: ok` (the Task 5 static check
  accepts the new lines: all run under `runuser -u otter --` or are the top-dir `install -d`).

- [ ] **Step 9: Commit**

```bash
git add internal/store/backup.go internal/store/backup_test.go deploy/upgrade.sh deploy/test/scripts_test.sh
oc -m "backups: 0600 copies in a 0700 dir, keep the newest 3 pre-upgrade copies (C26)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: The janitor purges connectivity-log lines older than 7 days

**Goal:** Source IPs of rejected peers (and every other netlog line) disappear 7 days after their last update.

**Findings closed:** C25

**Files:**
- Modify: `otter-server/internal/store/janitor.go` (constant + one `exec` in `Expire`, before the final `oplog` delete)
- Test: `otter-server/internal/store/netlog_test.go` (append; add `time` import)

**Acceptance Criteria:**
- [ ] After `Expire(now)`, a line last updated 8 days ago is gone, one updated 6 days ago stays.
- [ ] `NetlogMaxAgeMs` is 7 days; the 200-line cap still applies.

**Verify:** `cd otter-server && go test -race -count=1 ./internal/store/ -run Netlog` → `ok`

**Steps:**

- [ ] **Step 1: Failing test** — append to `otter-server/internal/store/netlog_test.go`:

```go
func TestJanitorPurgesOldNetlogLines(t *testing.T) {
	s, _ := open(t)
	ctx := context.Background()
	const day = int64(24 * 60 * 60 * 1000)
	now := int64(1_800_000_000_000)
	at := now - 8*day
	s.now = func() time.Time { return time.UnixMilli(at) }
	rejected := NetlogEntry{Peer: "198.51.100.7", Endpoint: "wss", Direction: "in", Result: "fail", Class: "handshake",
		Detail: "peer: node 01 not in manifest"}
	if err := s.NetlogAdd(ctx, rejected); err != nil {
		t.Fatal(err)
	}
	at = now - 6*day
	recent := rejected
	recent.Peer = "198.51.100.8"
	if err := s.NetlogAdd(ctx, recent); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Expire(ctx, now); err != nil {
		t.Fatal(err)
	}
	got, err := s.Netlog(ctx, 10)
	if err != nil || len(got) != 1 || got[0].Peer != "198.51.100.8" {
		t.Fatalf("after expire: %+v %v", got, err)
	}
}
```

- [ ] **Step 2: Run, expect FAIL** — `go test -count=1 ./internal/store/ -run Netlog` → `after expire: [{… 198.51.100.8 …} {… 198.51.100.7 …}]`.

- [ ] **Step 3: Implement** — in `otter-server/internal/store/janitor.go` add after `OrphanBackupMs`:

```go
// NetlogMaxAgeMs: connectivity-log lines not updated for this long are deleted; they hold source IPs of rejected
// peers (C25, D85).
const NetlogMaxAgeMs = int64(7 * 24 * 60 * 60 * 1000)
```

  and in `Expire`, right after the `auth_failures` delete:

```go
		if err := exec(&ignore, `DELETE FROM netlog WHERE last_ms < ?`, now-NetlogMaxAgeMs); err != nil {
			return err
		}
```

- [ ] **Step 4: Run, expect PASS** — `go test -race -count=1 ./internal/store/ ./internal/service/` → `ok`.

- [ ] **Step 5: Commit**

```bash
git add internal/store/janitor.go internal/store/netlog_test.go
oc -m "janitor: drop connectivity-log lines after 7 days (C25)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Docs and decisions for 0.8.3

**Goal:** Decisions, the deployment guide and the deploy README describe what 0.8.3 does.

**Findings closed:** documentation for C3, C11, C25, C26

**Files:**
- Modify: `docs/00-decisions.md` (D68 row; D74 row; new rows D82–D85 with the numbers the coordinator assigns)
- Modify: `docs/11-deployment.md` §6 "Upgrade a node" step 2, §6 "Backups", §8 "Security checklist"
- Modify: `otter-server/deploy/README.md:165-170` (release-apk paragraph)

**Acceptance Criteria:**
- [ ] D68 says "imported as the node user (`runuser -u otter`), 0640; `apk import` refuses root" instead of
  "(data-dir owner, 0640)"; D74 adds "lines not updated for 7 days are deleted by the janitor".
- [ ] D82–D85 rows added verbatim from this section's "Decisions to record".
- [ ] docs/11 §6 step 2 adds "(0600; the newest 3 pre-upgrade copies are kept)"; Backups says copies are 0600 in a
  0700 directory; §8 gets the bullet "Root never handles files in `/var/lib/otter` or `/var/backups/otter`; deploy
  scripts do that as `otter` (D82)".
- [ ] deploy/README: "streams the APK over ssh into a root-only temp directory, checks its SHA-256 and imports it as
  `otter` (nodes must run 0.8.3+)".

**Verify:** `grep -n 'data-dir owner' docs/00-decisions.md` → nothing; `grep -n '0.8.3' otter-server/deploy/README.md` → the new line.

**Steps:**

- [ ] **Step 1:** Edit the files as listed (wording above).
- [ ] **Step 2: Commit**

```bash
cd ~/Documents/Projects/OttterMSG/docs
git add 00-decisions.md 11-deployment.md
oc -m "docs: M9.0 hotfix decisions (root never handles otter's files, blob keys, backups, netlog age)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
cd ../otter-server
git add deploy/README.md
oc -m "deploy: README for the otter-run APK import" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Release 0.8.3 and rollout to eeee (each step asked first)

**Goal:** Nodes run 0.8.3 with the fixes live; nothing on a server happens without the owner's OK.

**Findings closed:** C3, C11, C25, C26 (in production)

**Files:**
- No source version bump: the version exists only as `make release VERSION=0.8.3` (`Makefile:4-7,21-29`);
  `upgrade-all.sh 0.8.3` builds `dist/otter-node_0.8.3_linux_{amd64,arm64}` + `dist/otter-admin_0.8.3_*` + `SHA256SUMS`
  if missing. Never delete anything in `dist/`.
- Modify after rollout: `docs/09-roadmap.md` (M9.0 done)

**Acceptance Criteria:**
- [ ] `make check` passes; scripts and bundle tests pass in a scratch copy; `scripts/secrets-check.sh` passes in
  `otter-server` and `docs`.
- [ ] Merged `--no-ff` and pushed only after the owner's OK.
- [ ] eeee (and ru-1 if the owner agrees) report `0.8.3`; on each: `/var/backups/otter` is `700 otter`, every `*.db`
  is `600`, at most 3 `pre-upgrade-*.db`; `deploy/status.sh` healthy.

**Verify:** `deploy/status.sh` → each upgraded node `0.8.3 active`; `ssh root@eeee 'stat -c "%a %U %n" /var/backups/otter /var/backups/otter/*.db'`
→ `700 otter …`, `600 otter …` lines only.

**Steps:**

- [ ] **Step 1: Local checks (no server)**

```bash
cd ~/Documents/Projects/OttterMSG/otter-server
make check
d=$(mktemp -d) && rsync -a --exclude dist --exclude .dev-mesh --exclude .vm ./ $d/srv/ && (cd $d/srv && mkdir -p dist && deploy/test/scripts_test.sh && deploy/test/bundle_test.sh)
scripts/secrets-check.sh && (cd ../docs && scripts/secrets-check.sh)
```
Expected: `ok` for every package, `scripts test: ok`, `bundle test: ok`, secrets checks clean. Optionally (ask): `deploy/test/e2e.sh` (local VM).

- [ ] **Step 2: Ask the owner → merge and push**

```bash
for r in otter-server docs; do git -C ~/Documents/Projects/OttterMSG/$r checkout main && git -C ~/Documents/Projects/OttterMSG/$r merge --no-ff m9-0-hotfix -m "Merge M9.0: server hotfix 0.8.3 (C3, C11, C25, C26)"; done
# after a second OK:
for r in otter-server docs; do git -C ~/Documents/Projects/OttterMSG/$r push origin main; done
```
(The merge commits go through `oc` like every other commit: replace `git merge … -m` by `git merge --no-ff --no-commit m9-0-hotfix && oc -m "…"`.)

- [ ] **Step 3: Ask the owner → build the release (local, writes `dist/`)**

```bash
cd ~/Documents/Projects/OttterMSG/otter-server && make release VERSION=0.8.3 && ls dist/otter-node_0.8.3_linux_*
```

- [ ] **Step 4: Ask the owner → upgrade eeee** (binary only; TURN and news untouched)

```bash
deploy/upgrade-all.sh 0.8.3 --only eeee --no-news --no-turn
```
Expected summary: `eeee  upgraded 0.8.1 → 0.8.3`. Exit 2 = rolled back (still 0.8.1: stop, read the output), 3 = act now.
This upgrade runs the new `upgrade.sh`: it chmods the old copies to 0600 and prunes the old pre-upgrade copies to 3.

- [ ] **Step 5: Ask the owner → check eeee**

```bash
deploy/status.sh
ssh root@eeee 'stat -c "%a %U %n" /var/backups/otter /var/backups/otter/*.db; ls /var/backups/otter/pre-upgrade-*.db | wc -l; ls -ld /var/lib/otter/apk /var/lib/otter/apk/*.apk'
```
Expected: `0.8.3 active`; `700 otter`, `600 otter` lines; count ≤ 3; apk dir and files owned by `otter`.

- [ ] **Step 6: Ask the owner → upgrade ru-1 the same way** (see Owner question 1)

```bash
deploy/upgrade-all.sh 0.8.3 --only ru-1 --no-news --no-turn && deploy/status.sh
```

- [ ] **Step 7: Ask the owner → the pending family APK release** (only after every node runs 0.8.3; the script
  refuses older nodes): `deploy/release-apk.sh 0.8.2 <path to app-release.apk>` with its news dialog. Check on eeee
  that no `/tmp/otter-*.apk` and no `/root/otter-apk.*` remain: `ssh root@eeee 'ls /tmp/otter-*.apk /root/otter-apk.* 2>&1'`
  → "No such file" lines.

- [ ] **Step 8: Roadmap** — mark M9.0 done in `docs/09-roadmap.md` (date, server 0.8.3, which nodes), commit with
  `oc -m "roadmap: M9.0 server hotfix 0.8.3 rolled out" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`,
  push after the owner's OK.

No news announcement: 0.8.3 changes nothing a phone can see.

---

### Task 74: `secrets-check.sh` closes the rest of C28 (do before Task 9)

**Goal:** the publication check fails when its private lists are missing, judges each private-IP match on its own, and never prints what it found.
**Findings closed:** C28 (rest; the history, timezone, trailer and image parts were done under D57)

**Files:**
- Modify: `otter-server/scripts/secrets-check.sh`, `otter-android/scripts/secrets-check.sh`, `docs/scripts/secrets-check.sh` (same hunks in each; the docs copy has no gitleaks step, leave that as is)
- Create: `otter-server/scripts/secrets-check_test.sh` (runs the check in throw-away repos; copy it to the other two repos)

**Acceptance Criteria:**
- [ ] Missing `~/.otter-real-ips` or `~/.otter-private-words` → exit 2 with a message naming the file (no silent pass).
- [ ] A line holding `10.0.2.2` **and** a real private address (e.g. `10.1.2.3`) fails; a line with only `10.0.2.2`/`10.0.2.15` passes.
- [ ] Findings print `file:line` only (no matched text) for private IPs, home paths and e-mail addresses; the real-IP and private-word checks print no matches at all (already quiet).
- [ ] `scripts/secrets-check_test.sh` passes in all three repos; `scripts/secrets-check.sh` still prints `secrets check: ok` on the real repos.

**Verify:** `bash scripts/secrets-check_test.sh` → `secrets-check tests: ok`; `bash scripts/secrets-check.sh | tail -1` → `secrets check: ok`

**Steps:**

- [ ] **Step 1: Write the failing test** `otter-server/scripts/secrets-check_test.sh`:

```bash
#!/usr/bin/env bash
# Tests for secrets-check.sh (C28). Builds throw-away repos in a temp dir; never touches the real lists.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export GITLEAKS=/bin/true  # gitleaks is not under test here
mk() {  # mk <name> <file content> → repo with scripts/secrets-check.sh and one tracked file
  local r=$tmp/$1; mkdir -p "$r/scripts"; cp "$here/secrets-check.sh" "$r/scripts/"; touch "$r/.gitleaks.toml"
  printf '%s\n' "$2" > "$r/f.txt"
  git -C "$r" init -q; git -C "$r" add -A
  TZ=UTC GIT_AUTHOR_DATE=2026-01-01T12:00:00+0000 GIT_COMMITTER_DATE=2026-01-01T12:00:00+0000 \
    git -C "$r" -c user.name=t -c user.email=t@users.noreply.invalid commit -qm init
  echo "$r"
}
printf '203.0.113.250\n' > "$tmp/ips"; printf 'nosuchword\n' > "$tmp/words"
run() { OTTER_REAL_IPS=${IPS:-$tmp/ips} OTTER_PRIVATE_WORDS=${WORDS:-$tmp/words} bash "$1/scripts/secrets-check.sh" >"$tmp/out" 2>&1; }
ok=$(mk ok 'emulator 10.0.2.2 and 10.0.2.15 only')
run "$ok" || { cat "$tmp/out"; echo "FAIL: clean repo"; exit 1; }
mixed=$(mk mixed 'emulator 10.0.2.2 but also 10.1.2.3')
if run "$mixed"; then echo "FAIL: real private IP hidden by the emulator filter"; exit 1; fi
grep -q 'f.txt:1' "$tmp/out" || { echo "FAIL: no file:line"; exit 1; }
if grep -q '10\.1\.2\.3' "$tmp/out"; then echo "FAIL: match printed"; exit 1; fi
mail=$(mk mail 'write to someone@'"gmail"'.com')  # split so this test file never matches itself
if run "$mail"; then echo "FAIL: e-mail passed"; exit 1; fi
if grep -q 'someone@' "$tmp/out"; then echo "FAIL: e-mail printed"; exit 1; fi
set +e; IPS=$tmp/none run "$ok"; rc=$?; set -e
[[ $rc == 2 ]] || { echo "FAIL: missing IP list gave $rc"; exit 1; }
set +e; WORDS=$tmp/none run "$ok"; rc=$?; set -e
[[ $rc == 2 ]] || { echo "FAIL: missing word list gave $rc"; exit 1; }
echo "secrets-check tests: ok"
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd otter-server && bash scripts/secrets-check_test.sh`
Expected: `FAIL: real private IP hidden by the emulator filter`

- [ ] **Step 3: Change `scripts/secrets-check.sh`** (all three repos)

Replace the private-address, home-path and e-mail block with per-match checks that print `file:line` only:

```bash
echo "==> tracked files: private addresses, home paths, e-mail addresses"
# private IPv4 ranges (RFC 1918); each match is judged alone, so an emulator address cannot hide a real one
priv=$(git grep -noIE '\b(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})\b' \
     -- ':!*.lock' ':!**/testdata/**' ':!**/vectors/**' ':!scripts/secrets-check_test.sh' | grep -vE ':(10\.0\.2\.2|10\.0\.2\.15)$' | cut -d: -f1,2 | sort -u || true)
if [[ -n "$priv" ]]; then
  echo "$priv"; echo "private IP address in a tracked file (use 192.168.x.y / 203.0.113.x placeholders)"; fail=1
fi
homes=$(git grep -nI '/hom[e]/' -- ':!scripts/secrets-check.sh' ':!scripts/secrets-check_test.sh' | cut -d: -f1,2 || true)
if [[ -n "$homes" ]]; then echo "$homes"; echo "home path in a tracked file"; fail=1; fi
mails=$(git grep -nIE '[A-Za-z0-9._%+-]+@(gmail|yandex|mail|outlook|hotmail|icloud)\.[a-z]+' \
     -- ':!scripts/secrets-check.sh' ':!scripts/secrets-check_test.sh' | cut -d: -f1,2 || true)
if [[ -n "$mails" ]]; then echo "$mails"; echo "personal e-mail address in a tracked file"; fail=1; fi
```

Make both private lists mandatory (replace each `else echo "warning: … skipped …"` branch):

```bash
else
  echo "missing $IPS: create it with one real server IP per line (it never goes into git)" >&2; exit 2
fi
```

```bash
else
  echo "missing $WORDS: create it with one extended regex per line (it never goes into git)" >&2; exit 2
fi
```

(The 192.168.x.y placeholders never match the regex, which needs digits; `10.0.2.2`/`10.0.2.15` are dropped per match by the `grep -vE ':(…)$'` on `git grep -o` output.)

- [ ] **Step 4: Run the tests and the real check**

Run: `bash scripts/secrets-check_test.sh && bash scripts/secrets-check.sh | tail -1`
Expected: `secrets-check tests: ok` then `secrets check: ok`. Copy the script and the test to `otter-android/scripts/` and `docs/scripts/`, and run both there too (same expected output).

- [ ] **Step 5: Commit** (in each of the three repos, on `m9-0-hotfix`)

```bash
git add scripts/secrets-check.sh scripts/secrets-check_test.sh
oc -m "secrets-check: require the private lists, judge each private-IP match alone, print file:line only (C28)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```


**Owner questions (M9.0)**

1. **Upgrade ru-1 in this hotfix too?** Recommended: **yes**, right after eeee. C3 applies to ru-1 as well, and
   `release-apk.sh` now refuses to release while any node runs < 0.8.3.
2. **`--no-turn` for the 0.8.3 upgrade?** Recommended: **yes**: the hotfix changes only the binary; TURN on ru-1 (if
   wanted) stays a separate decision.
3. **Netlog age limit for all lines or only rejected inbound ones?** Recommended: **all lines** after 7 days without
   an update (simpler; a node that keeps failing keeps its line fresh, so nothing useful is lost).
4. **Old pre-upgrade copies on eeee:** the 0.8.3 upgrade deletes all but the newest 3 (one of them taken by that
   upgrade). Recommended: **yes**; if the owner wants an archive, copy them off first (`scp root@eeee:/var/backups/otter/pre-upgrade-*.db` into encrypted storage).
5. **Backups stay plaintext** (0600 in a 0700 dir). Recommended: **yes**: the copy holds the same data as the live
   DB next to it, and an at-rest key would live on the same host.

---

## M9.1a — Restore and backups trust no node

Closes C1, C13, C18, C14, C20. Server parts ship in server 0.9.0 (branch `m9-1-client`), app parts in app 0.9.0 /
versionCode 11 (same branch name in `otter-android`). **Order constraint:** every node runs server 0.9.0 before app
0.9.0 is published, because a 0.8.x node rejects record type 17 and decoy `BACKUP_META`s as `INVALID`, and replication
then *advances its cursor past them* (`replication/session.go:196-201`): that node would never get them later.

**Proto additions:**
- Fixed allocations used here: `RecordType INSTALL = 17`; `message Install { uint32 registration_id = 1; int64 installed_ms = 2; }`.
- Chosen in this section: `LoginResponse.install` — `Record install = 3;` (the newest INSTALL record the node holds for
  the account). New RPC method name **`install.publish`** (request `RecordRequest{Record INSTALL}`, answer `Empty`).
- No new message for decoys: a decoy is a `BACKUP_META` with `version = 0`, `size = 0`,
  `blob_key = author ‖ 16 zero bytes` (rule change only).
- Server migration `internal/store/migrations/0009_installs.sql` (table `installs`). If another M9.1 section also
  adds a migration, the coordinator renumbers (files apply in name order).

**Verified facts:**

| Question | Answer | Source |
|---|---|---|
| Where restore derives keys | `download()` passes `auth.kdfMKib/kdfT/kdfP` from the node straight into `derive`, then sends `authSecret` | `RestoreManager.kt:109-112` |
| KDF code | `BackupKeys.derive(password, salt, mKib = M_KIB, t = T, p = P)`; constants `M_KIB=65536, T=3, P=1`; `newSalt()` = 16 bytes; no bounds on caller params | `core/crypto/.../BackupKeys.kt:10-39` |
| Restore checks today | only chunk SHA-256 and `author(BACKUP_META) == id16(seed account key)`; no signature check of either record; `keepBackupOn` stores `meta.salt` (not the salt the keys came from) | `RestoreManager.kt:113-133,167-173` |
| Record signature helper | `RecordCodec.verify(record, publicKey)` (Ed25519 over exact body bytes) | `core/crypto/.../RecordCodec.kt:23-24` |
| Directory verification | `DirectorySync.verify(rec)` (private): type, `author == user_id == id16(account_pub)`, signature by `account_pub`, identity binding | `core/data/.../directory/DirectorySync.kt:74-86` |
| Words restore today | first `DIRECTORY_ENTRY` whose `user_id` matches, **no** verification | `RestoreManager.kt:144-151` |
| Superseded decision today | `resp.installedMs > settings.installedMs()` — the unsigned `LoginResponse.installed_ms` | `InstallGuard.kt:29-32` |
| What the node puts in `LoginResponse` | `devices.registration_id/installed_ms` | `service/service.go:210-214`, `store/backups.go:31-41` |
| Where `devices.installed_ms` comes from | account-signed `PREKEYS.installed_ms`: newer → prekeys deleted; older → ignored; equal → merge (D52) | `store/typed.go:66-120` |
| D56 cut-off | session remembers `installedMs` at login; `replaced()` = `devices.installed_ms > mine`; delivery loop closes, `msg.ack` refused; a session uploading newer `PREKEYS` raises its own `installedMs` | `gateway/session.go:58-79`, `gateway/methods.go:96,243-260` |
| Unknown RPC on an old node | `STATUS_INVALID "unknown method"` | `gateway/methods.go:262-263` |
| Replication and invalid records | logged and skipped, cursor advances | `replication/session.go:196-201` |
| Unknown author from a peer | `ErrRetryLater` (redial re-sends) | `service/replicated.go:28-29` |
| `backup.auth` today | real salt + stored params, or `fakeSalt` = HMAC(SHA-256("otter/fake-salt/v1" ‖ **node** private key), name)[:16] with 65536/3/1 | `service/backup.go:28-34,56-66` |
| Shared secret among nodes? | none: TURN secret is per node and never leaves it; network private key is offline (`otter-admin`, P14) | `deploy/README.md:115-116`, `00-decisions.md` P14 |
| `BACKUP_META` rules | version ≥ 1, salt 16, verifier 32, m 19456–262144, t 1–10, p 1–4, `blob_key` 32 starting with author, size 1..100 MiB; `PublishBackup` requires the author's persistent blob | `records/validate.go:355-368`, `service/backup.go:117-141` |
| `backups.blob_key` | `NOT NULL` → a decoy must carry a 32-byte key | `store/migrations/0005_backups.sql` |
| Superseded UI | `SupersededScreen()` has no action; `MainActivity` shows it instead of the app; `SyncEngine.superseded` never resets in-process | `app/.../SupersededScreen.kt`, `MainActivity.kt:37,58-59`, `SyncEngine.kt:87-89,104-111` |
| Reset machinery | `SessionResets.send(peer)` deletes our local session and queues a reset; `finishRestore` uploads fresh prekeys then `sendToAll()` | `SessionResets.kt:23-30,40`, `InstallGuard.kt:35-55` |
| Test fakes | `FakeNode` (in-memory node, `Session : NodeApi`), `TestGraph` (wires one client; `restore`/`backups` get cheap `derive`) | `core/data/src/test/.../FakeNode.kt`, `TestGraph.kt:88-106` |
| Versions | app 0.8.2 / versionCode 10 | `app/build.gradle.kts:35` |
| Go proto generation | `make gen` (buf v1.75.0, protoc-gen-go v1.36.12) | `otter-server/Makefile:9-12` |

**Decisions to record:**

- **D86 — Client-owned KDF profiles (C1).** The phone knows a fixed table of Argon2id profiles: **profile 1 =
  m 65536 KiB, t 3, p 1, salt exactly 16 bytes** (`BackupKeys.Profile.P1`). The numbers a node returns in
  `backup.auth` are only an ID: they must equal a known profile exactly, otherwise the restore ends with «Копия
  повреждена» **before the password is used** (no Argon2 run, no `auth_secret` sent). The profile used for a backup is
  stored on the phone (`backup_profile`); a future stronger profile 2 is added to the table and chosen by the phone
  (`Profile.CURRENT`) when a password is set, never by a node. Floor: a node can at most make a profile-2 backup look
  like profile 1 (the phone then derives wrong keys and fails); it can never go below profile 1.
- **D87 — Restore verifies what it installs (C13).** After decrypting, the phone checks with the account key from the
  decrypted seed: `BACKUP_META` and `BLOB_META` signatures, both authored by that account, `BLOB_META` key ==
  `BackupMeta.blob_key`, signed `salt` == salt from `backup.auth`, signed KDF numbers == the profile used. Any failure →
  `Corrupt`, nothing is written. A restored phone continues backup versions from `max(restored version, now ms)`, so a
  node serving an older genuine backup cannot make the phone's later backups lose to a newer one ("latest wins", D50).
- **D88 — Words restore uses directory verification (C18).** `DirectorySync.verifyEntry` (the sync rule) on every
  record; only entries of the derived account key count; the highest `version` wins. No valid entry → «Аккаунт не найден».
- **D89 — Signed install record (C14), supersedes the client half of D52.** New record `INSTALL{registration_id,
  installed_ms}` (type 17) signed by the account key. A phone publishes it with `install.publish` after registration
  (first login), at the end of every restore (before the new `PREKEYS`), on first start of 0.9.0, and after «Этот
  телефон снова главный». Nodes validate it (author = registered, not revoked user; registration_id 1–16380;
  0 ≤ installed_ms ≤ now + 10 min; no expiry), keep the newest per user by (installed_ms, registration_id) and delete
  the losing record, raise `devices` like a newer `PREKEYS` (old prekeys deleted), and return it in
  `LoginResponse.install`. A phone believes "another phone replaced me" **only** from an `INSTALL` that verifies with
  its own account key and is newer than its own; the unsigned `installed_ms`/`registration_id` are kept for 0.8.x
  phones and ignored (logged) by 0.9.0. D56 keeps working: `devices` is now raised by `INSTALL` or `PREKEYS`, both
  account-signed; a session that publishes `INSTALL` itself is the new install. Recovery: the superseded screen offers
  «Этот телефон снова главный»: a new `installed_ms` on this phone, then the restore finish (INSTALL, fresh prekeys,
  reset to every contact). **Limit (design limit 2):** whoever holds the 12 words can still sign `INSTALL` and take
  the account; the fix is the admin-signed `REKEY` in M9.3.
- **D90 — Every member looks like it has a backup (C20), replaces the "fake salts differ per node" limit of D51.**
  An account without a backup publishes once a decoy `BACKUP_META`: `version 0`, random 16-byte salt, profile-1
  numbers, random 32-byte verifier, `size 0`, `blob_key = author ‖ 0¹⁶`, no blob. It replicates like any backup, so
  every node answers `backup.auth` for that member with the same salt and the same numbers as for a member with a real
  backup; `backup.fetch` against a decoy always fails like a wrong password (and counts). A real backup (version ≥ 1)
  replaces the decoy; a decoy never replaces a real backup. Unknown usernames keep the node-local fake salt: they
  differ between nodes, which only tells someone with two nodes' addresses that a name is **not a member** — not
  secret (usernames are visible to every member, and the probe already needs a family link to find nodes). Chosen
  over the spec's "HMAC(network key, username) on every node" because nodes share no secret (the network private key
  is offline, TURN secrets are per node), and a shared secret would need new key distribution; decoys need none and
  are signed, so a node cannot fake or remove one without it showing. Leaks that remain: a salt change over time (a
  password set or changed) and members whose phone is still on 0.8.x (no decoy yet).

---

### Task 10: Proto — `INSTALL`, `Install`, `LoginResponse.install`

**Goal:** Both proto copies carry the install record and the login field; Go code is regenerated.

**Findings closed:** none on its own (groundwork for C14).

**Files:**
- Modify: `otter-server/proto/otter/v1/records.proto` (`enum RecordType` lines 8-26; new `message Install` after
  `BackupMeta`, line ~114)
- Modify: `otter-server/proto/otter/v1/api.proto` (`message LoginResponse`, lines 118-121)
- Regenerate: `otter-server/internal/proto/otterv1/records.pb.go`, `api.pb.go` (`make gen`)
- Modify (identical copies): `otter-android/core/proto/src/main/proto/otter/v1/records.proto`, `.../api.proto`

**Acceptance Criteria:**
- [ ] `RecordType.INSTALL = 17` exists; `REKEY = 18` is **not** added here (M9.3).
- [ ] `message Install { uint32 registration_id = 1; int64 installed_ms = 2; }` in `records.proto`.
- [ ] `LoginResponse` has `Record install = 3;`.
- [ ] `diff -r otter-server/proto/otter/v1 otter-android/core/proto/src/main/proto/otter/v1` prints nothing.
- [ ] `make gen` passes `buf lint`; `go build ./...` and `./gradlew :core:proto:build` pass.

**Verify:** `cd otter-server && make gen && go build ./... && cd .. && diff -r otter-server/proto/otter/v1 otter-android/core/proto/src/main/proto/otter/v1 && echo same` → `same`

**Steps:**

- [ ] **Step 1: Edit `records.proto`.** In `enum RecordType` after `ANNOUNCEMENT_DELETED = 16;`:

```proto
  INSTALL = 17;               // M9.1 (C14): the account's current install, signed by the account key
```

  After `message BackupMeta { … }`:

```proto
// INSTALL payload (M9.1, C14). Signed by the account key. Per user the newest (installed_ms, registration_id) is the
// account's current install; a phone believes that another phone replaced it only from a valid INSTALL record.
message Install {
  uint32 registration_id = 1;  // 1..16380, the Signal registration id of this install
  int64 installed_ms = 2;      // when this install was created (registration, restore or "this phone is main again")
}
```

- [ ] **Step 2: Edit `api.proto`** `LoginResponse`:

```proto
message LoginResponse {
  uint32 registration_id = 1;  // of the newest install this node knows (D52); unsigned, ignored by 0.9.0+ phones (C14)
  int64 installed_ms = 2;      // unsigned, ignored by 0.9.0+ phones (C14)
  Record install = 3;          // the newest INSTALL record of the account, if this node has one (M9.1, C14)
}
```

- [ ] **Step 3: Regenerate and copy.**

```bash
cd ~/Documents/Projects/OttterMSG/otter-server
export PATH=/usr/lib/go-1.26/bin:$HOME/go/bin:$PATH
make gen && go build ./... && go vet ./...
cp proto/otter/v1/records.proto proto/otter/v1/api.proto ../otter-android/core/proto/src/main/proto/otter/v1/
cd ../otter-android && JAVA_HOME=~/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2 ./gradlew :core:proto:build -q
```

  Expected: no output from `go vet`, Gradle `BUILD SUCCESSFUL` (quiet), `diff -r` empty.

- [ ] **Step 4: Commit (both repos).**

```bash
cd ~/Documents/Projects/OttterMSG/otter-server
git add proto/otter/v1/records.proto proto/otter/v1/api.proto internal/proto/otterv1/records.pb.go internal/proto/otterv1/api.pb.go
oc -m "proto: INSTALL record and LoginResponse.install (C14)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
cd ../otter-android
git add core/proto/src/main/proto/otter/v1/records.proto core/proto/src/main/proto/otter/v1/api.proto
oc -m "proto: INSTALL record and LoginResponse.install (C14)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Server — `INSTALL` validated, newest wins, returned at login, drives D56

**Goal:** Nodes accept only account-signed, sane `INSTALL` records (local or replicated), keep the newest per user,
raise the device install like `PREKEYS`, hand the record out in `auth.login`, and cut off the replaced session.

**Findings closed:** C14 (server half).

**Files:**
- Create: `otter-server/internal/store/migrations/0009_installs.sql`
- Modify: `otter-server/internal/records/validate.go` (constants 18-30; `checkPayload` 166-234)
- Modify: `otter-server/internal/store/typed.go` (`PREKEYS` case 66-120 → shared `raiseInstall`; new `INSTALL` case)
- Modify: `otter-server/internal/store/backups.go` (new `InstallRecord`, next to `DeviceInstall` 31-41)
- Modify: `otter-server/internal/service/service.go` (`VerifyLogin` 189-215)
- Modify: `otter-server/internal/gateway/methods.go` (generic record case 235-261)
- Test: `otter-server/internal/service/install_test.go` (new), `otter-server/internal/gateway/install_test.go` (new)

**Acceptance Criteria:**
- [ ] Replicated `INSTALL` signed by another key, by another member, with `installed_ms` > now + 10 min,
  `registration_id` 0 or > 16380, or with an expiry → `ErrInvalid`; an INSTALL of a user not yet known → `ErrRetryLater`.
- [ ] Newest (installed_ms, registration_id) per user wins; an older or equal one is not stored; the superseded record is deleted.
- [ ] A newer `INSTALL` deletes the device's prekeys and sets `devices.registration_id/installed_ms` (same rule as `PREKEYS`).
- [ ] `auth.login` returns the stored record in `LoginResponse.install` (byte-identical) plus the old fields.
- [ ] `install.publish` by the new phone: old phone's `msg.ack` refused / connection closed; new phone's ack accepted.
- [ ] Existing tests (`TestReplacedInstallIsDisconnected`, `TestLoginReturnsInstall`, store tests) still pass.

**Verify:** `cd otter-server && go test -race -count=1 ./internal/records/ ./internal/store/ ./internal/service/ ./internal/gateway/` → all `ok`

**Steps:**

- [ ] **Step 1: Failing service test** `internal/service/install_test.go` (plays a hostile peer):

```go
package service

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"
	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
)

func installRec(t *testing.T, author []byte, rid uint32, inst int64, k ed25519.PrivateKey) *pb.Record {
	return sign(t, pb.RecordType_INSTALL, author, &pb.Install{RegistrationId: rid, InstalledMs: inst}, k)
}

func (f *fx) login(u *user) *pb.LoginResponse {
	nonce := make([]byte, 32)
	rand.Read(nonce)
	ts := time.Now().UnixMilli()
	resp, err := f.svc.VerifyLogin(context.Background(), nonce, &pb.LoginRequest{UserId: u.id, DeviceId: 1, TsMs: ts,
		Signature: ed25519.Sign(u.priv, keys.AuthMessage(f.svc.NodeID, nonce, ts))})
	if err != nil {
		f.t.Fatal(err)
	}
	return resp
}

// C14: a hostile peer can neither plant nor roll back an account's install; the newest signed INSTALL wins and is
// what auth.login hands to the phone.
func TestInstallRecordFromHostilePeer(t *testing.T) {
	f := newFx(t)
	ctx := context.Background()
	anna := f.mustRegister(f.invite(nil, time.Hour), "anna")
	boris := f.mustRegister(f.invite(anna, time.Hour), "boris")
	now := time.Now().UnixMilli()
	_, mallory, _ := ed25519.GenerateKey(nil)

	for name, rec := range map[string]*pb.Record{
		"signed by another key":    installRec(t, anna.id, 77, now, mallory),
		"signed by another member": installRec(t, anna.id, 77, now, boris.priv),
		"far future":               installRec(t, anna.id, 77, now+time.Hour.Milliseconds(), anna.priv),
		"no registration id":       installRec(t, anna.id, 0, now, anna.priv),
		"registration id too big":  installRec(t, anna.id, 16381, now, anna.priv),
	} {
		if _, err := f.svc.ApplyReplicated(ctx, peerID, rec); !errors.Is(err, ErrInvalid) {
			t.Fatalf("%s: %v", name, err)
		}
	}
	_, ghostPriv, _ := ed25519.GenerateKey(nil)
	ghost := keys.ID16(ghostPriv.Public().(ed25519.PublicKey))
	if _, err := f.svc.ApplyReplicated(ctx, peerID, installRec(t, ghost, 7, now, ghostPriv)); !errors.Is(err, ErrRetryLater) {
		t.Fatalf("unknown author: %v", err)
	}
	if resp := f.login(anna); resp.Install != nil {
		t.Fatalf("an invalid INSTALL reached the login answer: %+v", resp)
	}

	newer := installRec(t, anna.id, 77, now, anna.priv)
	if applied, err := f.svc.ApplyReplicated(ctx, peerID, newer); err != nil || !applied {
		t.Fatalf("genuine install: %v %v", applied, err)
	}
	if _, err := f.svc.ApplyReplicated(ctx, peerID, installRec(t, anna.id, 66, now-1000, anna.priv)); err != nil {
		t.Fatalf("replayed older install: %v", err) // accepted as a record, but it must not win
	}
	resp := f.login(anna)
	if resp.Install == nil || !proto.Equal(resp.Install, newer) || resp.RegistrationId != 77 || resp.InstalledMs != now {
		t.Fatalf("login: %+v", resp)
	}
	// the replaced install's one-time prekeys are gone (D52)
	if b, err := f.svc.FetchPrekeys(ctx, &pb.PreKeyFetchRequest{UserId: anna.id, DeviceId: 1}); err == nil && b.OneTime != nil {
		t.Fatal("one-time prekey of the replaced install handed out")
	}
	// the same install published again keeps the stored record
	if _, err := f.svc.Submit(ctx, anna.id, installRec(t, anna.id, 77, now, anna.priv), pb.RecordType_INSTALL); err != nil {
		t.Fatal(err)
	}
	if !proto.Equal(f.login(anna).Install, newer) {
		t.Fatal("an equal install replaced the stored record")
	}
	// boris' install never touches anna's
	if _, err := f.svc.Submit(ctx, boris.id, installRec(t, boris.id, 5, now+1, boris.priv), pb.RecordType_INSTALL); err != nil {
		t.Fatal(err)
	}
	if !proto.Equal(f.login(anna).Install, newer) {
		t.Fatal("boris' install changed anna's")
	}
}
```

- [ ] **Step 2: Failing gateway test** `internal/gateway/install_test.go`:

```go
package gateway

import (
	"crypto/ed25519"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"
	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
)

// C14 + D56: the restored phone signs INSTALL over its own session; the old phone is cut off, the new one is not,
// and a later login hands out exactly that record. A forged INSTALL is refused.
func TestInstallPublishReplacesOldPhone(t *testing.T) {
	n := startNode(t)
	as, cs := members(t, n, "anna", "boris")
	anna, boris := as[0], as[1]
	oldPhone := cs[0]
	newPhone := dial(t, n)
	login(t, newPhone, anna)

	forged := sign(t, pb.RecordType_INSTALL, anna.id, &pb.Install{RegistrationId: 77, InstalledMs: time.Now().UnixMilli()}, boris.priv)
	if s, _ := newPhone.call("install.publish", &pb.RecordRequest{Record: forged}, nil); s != pb.Status_STATUS_INVALID {
		t.Fatalf("forged install: %v", s)
	}
	inst := sign(t, pb.RecordType_INSTALL, anna.id, &pb.Install{RegistrationId: 77, InstalledMs: time.Now().UnixMilli()}, anna.priv)
	if s, msg := newPhone.call("install.publish", &pb.RecordRequest{Record: inst}, nil); s != pb.Status_STATUS_OK {
		t.Fatalf("install: %v %s", s, msg)
	}
	ack := sign(t, pb.RecordType_ACK, anna.id, &pb.Ack{EnvelopeIds: [][]byte{make([]byte, 32)}, DeviceId: 1}, anna.priv)
	if s, ok := tryCall(oldPhone, "msg.ack", &pb.RecordRequest{Record: ack}); ok && s != pb.Status_STATUS_UNAUTHORIZED {
		t.Fatalf("ack from the replaced install: %v", s)
	}
	if s, msg := newPhone.call("msg.ack", &pb.RecordRequest{Record: ack}, nil); s != pb.Status_STATUS_OK {
		t.Fatalf("ack from the new install: %v %s", s, msg)
	}
	var resp pb.LoginResponse
	c := dial(t, n)
	ts := time.Now().UnixMilli()
	c.call("auth.login", &pb.LoginRequest{UserId: anna.id, DeviceId: 1, TsMs: ts,
		Signature: ed25519.Sign(anna.priv, keys.AuthMessage(c.hello.NodeId, c.hello.Nonce, ts))}, &resp)
	if resp.Install == nil || !proto.Equal(resp.Install, inst) || resp.RegistrationId != 77 {
		t.Fatalf("login response: %+v", &resp)
	}
}
```

- [ ] **Step 3: Run — fails.** `go test ./internal/service/ -run TestInstallRecordFromHostilePeer` → one of the
  payload cases (`far future`, `no registration id`, `registration id too big`) fails with `<nil>` (no payload rule yet); `go test ./internal/gateway/ -run TestInstallPublish` → `forged install:
  STATUS_INVALID` passes by accident, then `install: STATUS_INVALID unknown method "install.publish"`.

- [ ] **Step 4: Migration** `internal/store/migrations/0009_installs.sql`:

```sql
-- M9.1 (C14): the newest account-signed INSTALL record per user.
CREATE TABLE installs(user_id BLOB PRIMARY KEY, record_key BLOB NOT NULL, installed_ms INTEGER NOT NULL,
                      registration_id INTEGER NOT NULL);
```

- [ ] **Step 5: Validator** (`records/validate.go`). Constants block:

```go
	MaxInstallSkew    = 10 * time.Minute // INSTALL.installed_ms may be at most this far ahead of the node clock (C14)
	MaxRegistrationID = 16380            // Signal registration ids are 1..16380
```

  In `checkPayload`'s switch:

```go
	case pb.RecordType_INSTALL:
		var in pb.Install
		if err := proto.Unmarshal(b.Payload, &in); err != nil || in.RegistrationId < 1 || in.RegistrationId > MaxRegistrationID ||
			in.InstalledMs < 0 || in.InstalledMs > v.Now().Add(MaxInstallSkew).UnixMilli() || b.ExpiresMs != 0 {
			return ErrBadPayload
		}
```

  The signer is the `default` branch of `signerKey` (registered, non-revoked author) — no change there.
  `installed_ms = 0` stays allowed for installs from before M6 (D52).

- [ ] **Step 6: Store** (`store/typed.go`). Extract the device rule from the `PREKEYS` case into a helper and use it
  from both cases:

```go
// raiseInstall applies an install time to a (user, device) (D52): a newer install deletes the device's prekeys and
// stores its registration id; an equal one updates the row; an older one changes nothing and returns false.
func raiseInstall(ctx context.Context, tx *sql.Tx, user []byte, device, rid uint32, inst int64) (bool, error) {
	var cur int64
	err := tx.QueryRowContext(ctx, `SELECT installed_ms FROM devices WHERE user_id=? AND device_id=?`, user, device).Scan(&cur)
	exists := err == nil
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return false, err
	}
	switch {
	case exists && inst < cur:
		return false, nil // an older install (a phone that was replaced): its keys must not be handed out
	case exists && inst > cur:
		if _, err := tx.ExecContext(ctx, `DELETE FROM prekeys WHERE user_id=? AND device_id=?`, user, device); err != nil {
			return false, err
		}
	}
	_, err = tx.ExecContext(ctx,
		`INSERT INTO devices(user_id,device_id,registration_id,installed_ms) VALUES(?,?,?,?)
		 ON CONFLICT(user_id,device_id) DO UPDATE SET registration_id=excluded.registration_id, installed_ms=excluded.installed_ms`,
		user, device, rid, inst)
	return err == nil, err
}
```

  The `PREKEYS` case becomes (the `put` closure and one-time loop below it stay unchanged):

```go
	case pb.RecordType_PREKEYS:
		var p pb.PreKeys
		if err := proto.Unmarshal(b.Payload, &p); err != nil {
			return err
		}
		if ok, err := raiseInstall(ctx, tx, b.Author, p.DeviceId, p.RegistrationId, p.InstalledMs); err != nil || !ok {
			return err
		}
		put := func(kind int, k *pb.SignedPreKey) error {
		// … unchanged …
```

  New case (before `PUSH_TOKEN`):

```go
	case pb.RecordType_INSTALL: // C14: newest (installed_ms, registration_id) per user; raises device 1 like PREKEYS
		var in pb.Install
		if err := proto.Unmarshal(b.Payload, &in); err != nil {
			return err
		}
		var curKey []byte
		var curInst int64
		var curRid uint32
		err := tx.QueryRowContext(ctx, `SELECT record_key, installed_ms, registration_id FROM installs WHERE user_id=?`,
			b.Author).Scan(&curKey, &curInst, &curRid)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		if err == nil && (in.InstalledMs < curInst || (in.InstalledMs == curInst && in.RegistrationId <= curRid)) {
			_, err := tx.ExecContext(ctx, `DELETE FROM records WHERE record_key=?`, it.key) // older or the same install
			return err
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT OR REPLACE INTO installs(user_id,record_key,installed_ms,registration_id) VALUES(?,?,?,?)`,
			b.Author, it.key, in.InstalledMs, in.RegistrationId); err != nil {
			return err
		}
		if curKey != nil {
			if _, err := tx.ExecContext(ctx, `DELETE FROM records WHERE record_key=?`, curKey); err != nil {
				return err
			}
		}
		_, err = raiseInstall(ctx, tx, b.Author, 1, in.RegistrationId, in.InstalledMs)
		return err
```

  (Deleting the losing/superseded record follows the `BACKUP_META` precedent in the same file; `INSTALL` is not in
  `expiring()`, so the winner stays in the oplog for nodes added later.)

  `store/backups.go`:

```go
// InstallRecord returns the newest INSTALL record of a user (serialized pb.Record), or ErrNotFound (C14).
func (s *Store) InstallRecord(ctx context.Context, user []byte) ([]byte, error) {
	var raw []byte
	err := s.r.QueryRowContext(ctx, `SELECT r.raw FROM installs i JOIN records r ON r.record_key = i.record_key
		WHERE i.user_id = ?`, user).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return raw, err
}
```

- [ ] **Step 7: Login answer** (`service/service.go`, end of `VerifyLogin`):

```go
	rid, inst, err := s.Store.DeviceInstall(ctx, req.UserId, req.DeviceId)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		return nil, err
	}
	resp := &pb.LoginResponse{RegistrationId: rid, InstalledMs: inst} // unsigned: for 0.8.x phones only (C14)
	raw, err := s.Store.InstallRecord(ctx, req.UserId)
	switch {
	case err == nil:
		resp.Install = &pb.Record{}
		if err := proto.Unmarshal(raw, resp.Install); err != nil {
			return nil, err
		}
	case !errors.Is(err, store.ErrNotFound):
		return nil, err
	}
	return resp, nil
```

- [ ] **Step 8: Gateway** (`gateway/methods.go`). Add `"install.publish"` to the case list and the `allowed` map, and
  raise the session's install for `INSTALL` as for `PREKEYS`:

```go
	case "prekeys.upload", "msg.send", "msg.ack", "invite.create", "blob.ack", "push.register", "install.publish":
		// … decode unchanged …
		allowed := map[string]pb.RecordType{"prekeys.upload": pb.RecordType_PREKEYS, "msg.send": pb.RecordType_ENVELOPE,
			"msg.ack": pb.RecordType_ACK, "invite.create": pb.RecordType_INVITE, "blob.ack": pb.RecordType_BLOB_FETCHED,
			"push.register": pb.RecordType_PUSH_TOKEN, "install.publish": pb.RecordType_INSTALL}[req.Method]
		// … replaced() check for msg.ack unchanged …
		body, err := svc.Submit(ctx, s.userID(), r.Record, allowed)
		if err == nil {
			// a phone that signs a newer install over its own session is that install (D56): it is not cut off
			if inst, ok := installOf(body); ok {
				s.mu.Lock()
				s.installedMs = max(s.installedMs, inst)
				s.mu.Unlock()
			}
		}
		return &pb.Empty{}, err
```

  and at the end of the file:

```go
// installOf is the install time a PREKEYS or INSTALL record declares (D52, C14).
func installOf(b *pb.RecordBody) (int64, bool) {
	switch b.Type {
	case pb.RecordType_PREKEYS:
		var p pb.PreKeys
		if proto.Unmarshal(b.Payload, &p) == nil {
			return p.InstalledMs, true
		}
	case pb.RecordType_INSTALL:
		var in pb.Install
		if proto.Unmarshal(b.Payload, &in) == nil {
			return in.InstalledMs, true
		}
	}
	return 0, false
}
```

- [ ] **Step 9: Run** `go test -race -count=1 ./internal/records/ ./internal/store/ ./internal/service/ ./internal/gateway/`
  → all `ok`; then `go vet ./... && go test -race -count=1 ./...` → all `ok`.

- [ ] **Step 10: Commit.**

```bash
git add internal/store/migrations/0009_installs.sql internal/records/validate.go internal/store/typed.go \
  internal/store/backups.go internal/service/service.go internal/gateway/methods.go \
  internal/service/install_test.go internal/gateway/install_test.go
oc -m "node: account-signed INSTALL decides the current install; login returns it (C14)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Server — decoy `BACKUP_META` (C20)

**Goal:** Nodes accept and replicate a decoy `BACKUP_META` (version 0, no blob), answer `backup.auth` from it exactly
like from a real backup, and never let `backup.fetch` succeed against it.

**Findings closed:** C20 (server half).

**Files:**
- Modify: `otter-server/internal/records/validate.go` (`checkBackupMeta`, 355-368)
- Modify: `otter-server/internal/service/backup.go` (`BackupFetch` 70-115, `PublishBackup` 117-141; comment of `fakeSalt` 28)
- Test: `otter-server/internal/service/decoy_test.go` (new)

**Acceptance Criteria:**
- [ ] A decoy (version 0, size 0, `blob_key` = author ‖ 16 zero bytes, salt 16, verifier 32, params in range) is
  accepted by `backup.publish` without a blob and by replication.
- [ ] `backup.auth` for that member returns the decoy salt and its numbers; a second node that received the decoy by
  replication returns the identical answer.
- [ ] `backup.fetch` against a decoy fails `UNAUTHORIZED` and counts a failure, for any secret.
- [ ] Decoys with `size > 0`, a non-zero blob id, or a wrong signature are `ErrInvalid` from a peer.
- [ ] A real backup (version ≥ 1) replaces the decoy; a later decoy does not replace a real backup.

**Verify:** `cd otter-server && go test -race -count=1 ./internal/service/ ./internal/records/ -run 'Decoy|Backup'` → `ok`

**Steps:**

- [ ] **Step 1: Failing test** `internal/service/decoy_test.go`:

```go
package service

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"
	pb "ottermsg/server/internal/proto/otterv1"
)

func decoyMeta(u *user, salt []byte) *pb.BackupMeta {
	v := make([]byte, 32)
	rand.Read(v)
	return &pb.BackupMeta{Salt: salt, KdfMKib: 65536, KdfT: 3, KdfP: 1, AuthVerifier: v,
		BlobKey: append(append([]byte{}, u.id...), make([]byte, 16)...)}
}

// C20: a member without a backup answers backup.auth exactly like one with a backup, on every node.
func TestBackupDecoy(t *testing.T) {
	f1 := newFx(t)
	withBlobs(t, f1)
	ctx := context.Background()
	anna := f1.mustRegister(f1.invite(nil, time.Hour), "anna")
	salt := bytes.Repeat([]byte{7}, 16)
	decoy := sign(t, pb.RecordType_BACKUP_META, anna.id, decoyMeta(anna, salt), anna.priv)
	if err := f1.svc.PublishBackup(ctx, anna.id, decoy); err != nil {
		t.Fatalf("decoy: %v", err)
	}
	a1, err := f1.svc.BackupAuth(ctx, "anna")
	if err != nil || !bytes.Equal(a1.Salt, salt) || a1.KdfMKib != 65536 || a1.KdfT != 3 || a1.KdfP != 1 {
		t.Fatalf("auth: %+v %v", a1, err)
	}

	// a second node that got the entry and the decoy by replication answers the same
	f2 := newFx(t)
	f2.svc.NetworkPub = f1.svc.NetworkPub
	entry, _ := f1.svc.Store.UserByID(ctx, anna.id)
	var entryRec pb.Record
	proto.Unmarshal(entry.EntryRaw, &entryRec)
	if _, err := f2.svc.ApplyReplicated(ctx, peerID, &entryRec); err != nil {
		t.Fatal(err)
	}
	if applied, err := f2.svc.ApplyReplicated(ctx, peerID, decoy); err != nil || !applied {
		t.Fatalf("replicated decoy: %v %v", applied, err)
	}
	if a2, _ := f2.svc.BackupAuth(ctx, "anna"); !proto.Equal(a1, a2) {
		t.Fatalf("node answers differ: %+v %+v", a1, a2)
	}

	// any secret fails like a wrong password and is counted
	if _, _, err := f1.svc.BackupFetch(ctx, "anna", make([]byte, 32)); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("fetch against a decoy: %v", err)
	}
	if n, _ := f1.svc.Store.AuthFailures(ctx, "anna", 0); n != 1 {
		t.Fatalf("failures %d", n)
	}

	// shapes a hostile peer might send
	_, mallory, _ := ed25519.GenerateKey(nil)
	sized, named := decoyMeta(anna, salt), decoyMeta(anna, salt)
	sized.Size = 10
	named.BlobKey[31] = 1
	for name, rec := range map[string]*pb.Record{
		"decoy with a size":   sign(t, pb.RecordType_BACKUP_META, anna.id, sized, anna.priv),
		"decoy naming a blob": sign(t, pb.RecordType_BACKUP_META, anna.id, named, anna.priv),
		"decoy by another key": sign(t, pb.RecordType_BACKUP_META, anna.id, decoyMeta(anna, salt), mallory),
	} {
		if _, err := f2.svc.ApplyReplicated(ctx, peerID, rec); !errors.Is(err, ErrInvalid) {
			t.Fatalf("%s: %v", name, err)
		}
	}

	// a real backup replaces the decoy; a later decoy never replaces a real backup
	realSalt := f1.publishBackup(anna, bytes.Repeat([]byte{1}, 32))
	later := sign(t, pb.RecordType_BACKUP_META, anna.id, decoyMeta(anna, bytes.Repeat([]byte{8}, 16)), anna.priv)
	if err := f1.svc.PublishBackup(ctx, anna.id, later); err != nil {
		t.Fatal(err)
	}
	if a3, _ := f1.svc.BackupAuth(ctx, "anna"); !bytes.Equal(a3.Salt, realSalt) {
		t.Fatalf("decoy replaced the real backup: %x", a3.Salt)
	}
}
```

- [ ] **Step 2: Run — fails** at `decoy:` with `INVALID … payload invalid` (version 0 refused).

- [ ] **Step 3: Validator** — replace `checkBackupMeta`:

```go
// checkBackupMeta: a user's password backup pointer (D50), or a decoy (version 0, C20): no blob, size 0 and blob key
// author ‖ 16 zero bytes, so backup.auth answers alike for members with and without a backup.
func checkBackupMeta(b *pb.RecordBody) error {
	var m pb.BackupMeta
	if err := proto.Unmarshal(b.Payload, &m); err != nil {
		return ErrBadPayload
	}
	switch {
	case b.ExpiresMs != 0, len(m.Salt) != 16, len(m.AuthVerifier) != 32,
		m.KdfMKib < 19456 || m.KdfMKib > 262144, m.KdfT < 1 || m.KdfT > 10, m.KdfP < 1 || m.KdfP > 4,
		len(m.BlobKey) != 32 || !bytes.Equal(m.BlobKey[:16], b.Author):
		return ErrBadPayload
	case m.Version == 0:
		if m.Size != 0 || !bytes.Equal(m.BlobKey[16:], make([]byte, 16)) {
			return ErrBadPayload
		}
	case m.Size == 0 || m.Size > MaxBlobSize:
		return ErrBadPayload
	}
	return nil
}
```

- [ ] **Step 4: Service** (`service/backup.go`). In `PublishBackup`, after unmarshalling `m`:

```go
	if m.Version == 0 { // a decoy has no blob (C20)
		_, err = s.Submit(ctx, user, rec, pb.RecordType_BACKUP_META)
		return err
	}
```

  (`err` is the variable already declared by `body, err := s.validator(nil).Validate(rec)`.) In `BackupFetch`, right after
  `b, m, err := s.currentBackup(ctx, username)` and its error checks:

```go
	if m.Version == 0 { // a decoy (C20): no secret opens it; counted like a wrong password
		return nil, nil, fail()
	}
```

  Change the `fakeSalt` comment to: `// fakeSalt answers backup.auth for unknown usernames (node-local; members publish a
  decoy BACKUP_META instead, C20).` The `typed.go` `BACKUP_META` case needs no change: version 0 loses to any real
  version, and superseding a decoy calls `gcBlob` with a key that has no `blobs` row (returns nil).

- [ ] **Step 5: Run** `go test -race -count=1 ./internal/service/ ./internal/records/ ./internal/store/` → `ok`.

- [ ] **Step 6: Commit.**

```bash
git add internal/records/validate.go internal/service/backup.go internal/service/decoy_test.go
oc -m "node: accept decoy BACKUP_META so every member answers backup.auth alike (C20)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Android — client-owned KDF profiles (C1)

**Goal:** A node's KDF numbers only select one of the phone's own profiles; anything else fails the restore before
the password is used, and the phone remembers which profile its backup keys belong to.

**Findings closed:** C1.

**Files:**
- Modify: `otter-android/core/crypto/src/main/kotlin/app/ottermsg/core/crypto/BackupKeys.kt` (all, 1-40)
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/backup/RestoreManager.kt` (73, 106-112, 167-173)
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/backup/BackupManager.kt` (51, 61-71, 113-116)
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/settings/Settings.kt` (backup block ~64-75, keys 128-132)
- Modify: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/TestGraph.kt` (90, 106)
- Modify: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/FakeNode.kt` (`backupAuth`/`backupFetch` 395-413)
- Test: `otter-android/core/crypto/src/test/kotlin/app/ottermsg/core/crypto/BackupKeysTest.kt`,
  `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/HostileRestoreTest.kt` (new)

**Acceptance Criteria:**
- [ ] `BackupKeys.Profile.match(m, t, p, saltLen)` returns `P1` only for 65536/3/1 with a 16-byte salt, else `null`.
- [ ] Restore against a node answering cheap (8 KiB/1/1), huge (4 GiB), other t/p, or a short salt → `RestoreError.Corrupt`,
  `derive` never called, `backup.fetch` never called, no account row written.
- [ ] Honest answer still restores; `BackupMeta` written by the phone carries the stored profile's numbers.
- [ ] Existing `RestoreFlowTest`, `BackupManagerTest`, `FakeNodeBackupTest`, `BackupKeysTest` pass.

**Verify:** `cd otter-android && ./gradlew :core:crypto:test :core:data:testDebugUnitTest --tests '*BackupKeysTest*' --tests '*HostileRestoreTest*' --tests '*RestoreFlowTest*' --tests '*BackupManagerTest*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: FakeNode hostile hooks** (`FakeNode.kt`, next to `grantBlob`):

```kotlin
    // ---- hostile node (M9.1): answers rewritten before they leave the node ----
    /** Rewrites every backup.auth answer. */
    @Volatile var authAnswer: ((BackupAuthResponse) -> BackupAuthResponse)? = null
    /** backup.fetch calls received (an auth_secret left the phone). */
    @Volatile var backupFetches = 0; private set
```

  `backupFetches` must live on `FakeNode` (outer class, next to `backups`), `authAnswer` too. In `backupAuth` wrap
  the built answer: `return (authAnswer ?: { it })(answer)` where `answer` is the existing `if/else` value. In
  `backupFetch`, first line inside `synchronized(lock)`: `backupFetches++`.

- [ ] **Step 2: Failing tests.** `BackupKeysTest.kt` add:

```kotlin
    @Test fun onlyKnownProfilesMatch() {
        assertEquals(BackupKeys.Profile.P1, BackupKeys.Profile.match(65536, 3, 1, 16))
        assertNull(BackupKeys.Profile.match(8, 1, 1, 16))          // cheap: offline guessing
        assertNull(BackupKeys.Profile.match(4_194_304, 3, 1, 16))  // huge: out of memory
        assertNull(BackupKeys.Profile.match(65536, 1, 1, 16))
        assertNull(BackupKeys.Profile.match(65536, 3, 4, 16))
        assertNull(BackupKeys.Profile.match(65536, 3, 1, 8))
        assertEquals(BackupKeys.Profile.P1, BackupKeys.Profile.CURRENT)
        assertThrows(IllegalArgumentException::class.java) { BackupKeys.derive("x", ByteArray(15), BackupKeys.Profile.P1) }
    }
```

  (add imports `org.junit.Assert.assertNull`, `org.junit.Assert.assertThrows`). New
  `core/data/src/test/kotlin/app/ottermsg/core/data/HostileRestoreTest.kt`:

```kotlin
package app.ottermsg.core.data

import app.ottermsg.core.crypto.BackupKeys
import app.ottermsg.core.crypto.Ed25519
import app.ottermsg.core.data.backup.BackupManager
import app.ottermsg.core.data.backup.RestoreError
import app.ottermsg.core.data.backup.RestoreManager
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** M9.1: a node lies in its restore answers; the phone refuses before it installs anything. */
@RunWith(RobolectricTestRunner::class)
class HostileRestoreTest {
    private val clock = TestClock()
    private val node = FakeNode(clock::now)
    private val anna = TestGraph(node, clock)
    private val graphs = mutableListOf(anna)
    private val pw = "корова лодка зима семь"
    private val mallory = Ed25519.keyPairFromSeed(ByteArray(32) { 7 })
    private var derivations = 0

    @After fun tearDown() = graphs.forEach { it.close() }

    private fun fresh() = TestGraph(node, clock).also { graphs += it }

    /** A restore whose (cheap) key derivation counts its calls: a refused answer must not use the password. */
    private fun TestGraph.counting(): RestoreManager = restore.apply {
        derive = { pass, salt, _ -> derivations++; BackupKeys.derive(pass, salt, mKib = 1024, t = 1, p = 1) }
    }

    private suspend fun annaBacksUp() {
        anna.register(node.bootstrapLink(), "Анна", "anna").getOrThrow(); anna.online()
        assertEquals(BackupManager.OK, anna.backups.setPassword(pw))
        anna.offline()
    }

    @Test fun nodeChosenKdfIsRefusedBeforeThePasswordIsUsed() = runBlocking<Unit> {
        annaBacksUp()
        val link = node.bootstrapLink()
        val bad = listOf(Triple(8, 1, 1), Triple(4_194_304, 3, 1), Triple(65536, 1, 1), Triple(65536, 3, 4))
        for ((m, t, p) in bad) {
            node.authAnswer = { it.toBuilder().setKdfMKib(m).setKdfT(t).setKdfP(p).build() }
            val phone = fresh()
            assertEquals(RestoreError.Corrupt, phone.counting().withPassword(link, "anna", pw).exceptionOrNull())
            assertNull(phone.db.accountDao().get())
        }
        node.authAnswer = { it.toBuilder().setSalt(bs(ByteArray(8))).build() }
        assertEquals(RestoreError.Corrupt, fresh().counting().withPassword(link, "anna", pw).exceptionOrNull())
        assertEquals(0, derivations)
        assertEquals(0, node.backupFetches) // no auth_secret left the phone

        node.authAnswer = null
        fresh().counting().withPassword(link, "anna", pw).getOrThrow() // the honest answer still restores
    }
}
```

- [ ] **Step 3: Run — fails** (`Profile` unresolved; `derive` takes 5 arguments).

- [ ] **Step 4: `BackupKeys.kt`** — replace the object body above `argon2id` with:

```kotlin
object BackupKeys {
    const val INFO_ENC = "otter/backup/enc/v1"
    const val INFO_AUTH = "otter/backup/auth/v1"
    const val SALT_LEN = 16

    /**
     * Client-owned KDF profiles (C1). The numbers a node returns are only an ID: they must equal one of these exactly,
     * or the restore stops before the password is used. A stronger profile is added here and chosen by the phone
     * ([CURRENT]) when a password is set — never by a node.
     */
    enum class Profile(val mKib: Int, val t: Int, val p: Int) {
        P1(65536, 3, 1);

        companion object {
            val CURRENT = P1
            fun match(mKib: Int, t: Int, p: Int, saltLen: Int): Profile? =
                if (saltLen != SALT_LEN) null else entries.firstOrNull { it.mKib == mKib && it.t == t && it.p == p }
        }
    }

    class Keys(val backupKey: ByteArray, val authSecret: ByteArray) {
        val verifier: ByteArray get() = MessageDigest.getInstance("SHA-256").digest(authSecret)
    }

    fun newSalt(): ByteArray = ByteArray(SALT_LEN).also(SecureRandom()::nextBytes)
```

  and replace `derive`:

```kotlin
    /** master = Argon2id(password) with [profile] → 64 bytes; backup_key / auth_secret = HKDF(master, info). */
    fun derive(password: String, salt: ByteArray, profile: Profile): Keys {
        require(salt.size == SALT_LEN) { "salt must be $SALT_LEN bytes" }
        return derive(password, salt, profile.mKib, profile.t, profile.p)
    }

    /** Raw parameters: only for [derive] with a profile and for tests (cheap parameters). */
    fun derive(password: String, salt: ByteArray, mKib: Int, t: Int, p: Int): Keys {
        val master = argon2id(password.toByteArray(Charsets.UTF_8), salt, mKib, t, p, 64)
        return Keys(Hkdf.computeHkdf("HMACSHA256", master, ByteArray(0), INFO_ENC.toByteArray(), 32),
            Hkdf.computeHkdf("HMACSHA256", master, ByteArray(0), INFO_AUTH.toByteArray(), 32))
    }
```

  (`M_KIB`, `T`, `P` are removed; their only user is `BackupManager.kt:115`, changed below.)

- [ ] **Step 5: `Settings.kt`** — next to the other backup accessors and in the key list:

```kotlin
    /** Profile of the stored backup keys (C1); P1 for backups made before 0.9.0. */
    suspend fun backupProfile(): BackupKeys.Profile =
        dao.get(BACKUP_PROFILE)?.decodeToString()?.let { n -> BackupKeys.Profile.entries.firstOrNull { it.name == n } }
            ?: BackupKeys.Profile.P1
    suspend fun setBackupProfile(p: BackupKeys.Profile) = dao.put(SettingEntity(BACKUP_PROFILE, p.name.encodeToByteArray()))
```

```kotlin
        const val BACKUP_PROFILE = "backup_profile"
```

  (import `app.ottermsg.core.crypto.BackupKeys`).

- [ ] **Step 6: `BackupManager.kt`.**

```kotlin
    /** Key derivation; tests swap in cheap parameters. */
    internal var derive: (String, ByteArray, BackupKeys.Profile) -> BackupKeys.Keys = { pw, salt, p -> BackupKeys.derive(pw, salt, p) }
```

  `setPassword`: `val profile = BackupKeys.Profile.CURRENT`, `val keys = withContext(Dispatchers.Default) { derive(password,
  salt, profile) }`, and inside the lock add `settings.setBackupProfile(profile)`. In `run`, replace the KDF setters:

```kotlin
            val profile = settings.backupProfile()
            val bm = BackupMeta.newBuilder().setVersion(version).setSalt(bs(checkNotNull(settings.backupSalt())))
                .setKdfMKib(profile.mKib).setKdfT(profile.t).setKdfP(profile.p)
```

- [ ] **Step 7: `RestoreManager.kt`.**

```kotlin
    /** Key derivation; tests swap in cheap parameters (the profile's numbers are ignored then). */
    internal var derive: (String, ByteArray, BackupKeys.Profile) -> BackupKeys.Keys = { pw, salt, p -> BackupKeys.derive(pw, salt, p) }
```

```kotlin
    private class Downloaded(val snapshot: BackupSnapshot, val keys: BackupKeys.Keys, val meta: BackupMeta, val profile: BackupKeys.Profile)

    private suspend fun download(api: NodeApi, username: String, password: String): Downloaded {
        val auth = api.backupAuth(username)
        // C1: the node's numbers only select one of our profiles; anything else ends here, before the password is used
        val profile = BackupKeys.Profile.match(auth.kdfMKib, auth.kdfT, auth.kdfP, auth.salt.size()) ?: throw RestoreError.Corrupt
        val keys = withContext(Dispatchers.Default) { derive(password, auth.salt.toByteArray(), profile) }
        // … rest unchanged; the return becomes Downloaded(snapshot, keys, meta, profile)
```

  `keepBackupOn` adds `settings.setBackupProfile(d.profile)`.

- [ ] **Step 8: `TestGraph.kt`** lines 90 and 106:

```kotlin
        .apply { derive = { pw, salt, _ -> app.ottermsg.core.crypto.BackupKeys.derive(pw, salt, mKib = 1024, t = 1, p = 1) } }
```

  (same lambda shape for `backups` and `restore`).

- [ ] **Step 9: Run** the Verify command → `BUILD SUCCESSFUL`; then `./gradlew :core:data:testDebugUnitTest` → all pass.

- [ ] **Step 10: Commit.**

```bash
git add core/crypto/src/main/kotlin/app/ottermsg/core/crypto/BackupKeys.kt \
  core/crypto/src/test/kotlin/app/ottermsg/core/crypto/BackupKeysTest.kt \
  core/data/src/main/kotlin/app/ottermsg/core/data/backup/RestoreManager.kt \
  core/data/src/main/kotlin/app/ottermsg/core/data/backup/BackupManager.kt \
  core/data/src/main/kotlin/app/ottermsg/core/data/settings/Settings.kt \
  core/data/src/test/kotlin/app/ottermsg/core/data/TestGraph.kt core/data/src/test/kotlin/app/ottermsg/core/data/FakeNode.kt \
  core/data/src/test/kotlin/app/ottermsg/core/data/HostileRestoreTest.kt
oc -m "restore: only client-owned KDF profiles; refuse node-chosen Argon2 numbers before the password is used (C1)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: Android — restore verifies the signed metas, salt and profile (C13)

**Goal:** Restore installs nothing unless both records are signed by the account in the decrypted seed and the signed
meta names the salt and profile the keys came from; a restored phone's next backup always wins.

**Findings closed:** C13 (and the backup-version rollback a node could cause through it).

**Files:**
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/backup/RestoreManager.kt` (`download` 109-135, `keepBackupOn` 167-173)
- Modify: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/FakeNode.kt` (`backupFetch`)
- Modify: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/RestoreFlowTest.kt` (line 86)
- Test: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/HostileRestoreTest.kt`

**Acceptance Criteria:**
- [ ] `BACKUP_META` re-signed by another key with another salt → `Corrupt`, no account row, no backup settings.
- [ ] A genuinely signed `BACKUP_META` whose salt differs from the `backup.auth` salt → `Corrupt`.
- [ ] `BLOB_META` re-signed by another key, or whose key ≠ `BackupMeta.blob_key` → `Corrupt`.
- [ ] After a restore of an older backup, the phone's next backup replaces a newer one already on the node.
- [ ] `RestoreFlowTest` passes with its version check changed to `> 1L`.

**Verify:** `cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*HostileRestoreTest*' --tests '*RestoreFlowTest*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: FakeNode hook** (outer class): `@Volatile var fetchAnswer: ((BackupFetchResponse) -> BackupFetchResponse)? = null`;
  in `backupFetch` return `(fetchAnswer ?: { it })(BackupFetchResponse.newBuilder().setBackupMeta(cur.first).setBlobMeta(blob.record).build())`.

- [ ] **Step 2: Failing tests** — add to `HostileRestoreTest` (imports: `app.ottermsg.core.crypto.RecordCodec`,
  `app.ottermsg.proto.v1.BackupMeta`, `app.ottermsg.proto.v1.RecordBody`, `app.ottermsg.proto.v1.RecordType`,
  `org.junit.Assert.assertTrue`):

```kotlin
    private fun resignedMeta(rec: app.ottermsg.proto.v1.Record, key: Ed25519.KeyPair, edit: (BackupMeta.Builder) -> Unit): app.ottermsg.proto.v1.Record {
        val body = RecordBody.parseFrom(rec.body)
        val m = BackupMeta.parseFrom(body.payload).toBuilder().also(edit).build()
        return RecordCodec.sign(body.toBuilder().setPayload(m.toByteString()).build(), key)
    }

    @Test fun swappedOrForgedMetaIsCorruptAndNothingIsInstalled() = runBlocking<Unit> {
        annaBacksUp()
        val link = node.bootstrapLink()
        val otherSalt = bs(ByteArray(16) { 1 })
        val cases = listOf<(app.ottermsg.proto.v1.BackupFetchResponse) -> app.ottermsg.proto.v1.BackupFetchResponse>(
            // a node swaps the salt and re-signs with its own key
            { r -> r.toBuilder().setBackupMeta(resignedMeta(r.backupMeta, mallory) { it.setSalt(otherSalt) }).build() },
            // a genuinely signed but different meta (an older password's salt)
            { r -> r.toBuilder().setBackupMeta(resignedMeta(r.backupMeta, anna.me.accountKey) { it.setSalt(otherSalt) }).build() },
            // the blob meta re-signed by another key (same chunk hashes)
            { r -> r.toBuilder().setBlobMeta(RecordCodec.sign(RecordBody.parseFrom(r.blobMeta.body), mallory)).build() },
            // a blob meta of another blob of the same author
            { r -> r.toBuilder().setBlobMeta(RecordCodec.sign(RecordBody.parseFrom(r.blobMeta.body).toBuilder()
                .setId(bs(ByteArray(16) { 3 })).build(), anna.me.accountKey)).build() },
        )
        for (lie in cases) {
            node.fetchAnswer = lie
            val phone = fresh()
            assertEquals(RestoreError.Corrupt, phone.counting().withPassword(link, "anna", pw).exceptionOrNull())
            assertNull(phone.db.accountDao().get())
            assertNull(phone.settings.backupSecret())
        }
        node.fetchAnswer = null
        fresh().counting().withPassword(link, "anna", pw).getOrThrow()
    }

    @Test fun restoredPhonesNextBackupWinsOverANewerOne() = runBlocking<Unit> {
        annaBacksUp() // version 1 on the node
        val phone = fresh()
        phone.counting().withPassword(node.bootstrapLink(), "anna", pw).getOrThrow()
        // other nodes had a newer backup than the one this node served
        anna.online(); anna.settings.setBackupVersion(4); assertEquals(BackupManager.OK, anna.backups.runNow()); anna.offline()
        assertEquals(5L, node.backupOf(anna.me.userId)!!.version)
        phone.online()
        eventually(what = "the restored phone's backup wins") { node.backupOf(anna.me.userId)!!.version > 5L }
        assertTrue(phone.settings.backupVersion() > 5L)
    }
```

- [ ] **Step 3: Run — fails**: the first case installs the account (no signature check); the second test times out
  (version 2 loses to 5).

- [ ] **Step 4: Implement** in `RestoreManager.kt` (imports `app.ottermsg.core.crypto.RecordCodec`,
  `app.ottermsg.proto.v1.Record`). Replace the part of `download` after `backupFetch`:

```kotlin
        val res = api.backupFetch(username, keys.authSecret)
        val metaBody = RecordBody.parseFrom(res.backupMeta.body)
        val meta = BackupMeta.parseFrom(metaBody.payload)
        val blobBody = RecordBody.parseFrom(res.blobMeta.body)
        val blob = BlobMeta.parseFrom(blobBody.payload)
        // the blob meta must be the one the backup meta names, and no bigger than a blob can be (D44)
        if (!(blobBody.author.toByteArray() + blobBody.id.toByteArray()).contentEquals(meta.blobKey.toByteArray()) ||
            blob.chunkSha256Count > MAX_CHUNKS) throw RestoreError.Corrupt
        val tmp = File.createTempFile("restore", ".otb")
        try {
            // … chunk download + decrypt unchanged …
            // C13: both records signed by the account in the snapshot; the signed meta names our salt and profile
            val account = SeedKeys.accountKeyPair(snapshot.seed.toByteArray())
            val author = Ids.id16(account.publicKey)
            if (snapshot.format != SnapshotCodec.FORMAT ||
                !signedBy(res.backupMeta, metaBody, RecordType.BACKUP_META, account.publicKey, author) ||
                !signedBy(res.blobMeta, blobBody, RecordType.BLOB_META, account.publicKey, author) ||
                meta.salt != auth.salt ||
                BackupKeys.Profile.match(meta.kdfMKib, meta.kdfT, meta.kdfP, meta.salt.size()) != profile) throw RestoreError.Corrupt
            return Downloaded(snapshot, keys, meta, profile)
        } finally { tmp.delete() }
    }

    private fun signedBy(rec: Record, body: RecordBody, type: RecordType, pub: ByteArray, author: ByteArray) =
        body.type == type && body.author.toByteArray().contentEquals(author) && RecordCodec.verify(rec, pub)
```

  Add `companion object { const val MAX_CHUNKS = 400 }` (100 MiB / 256 KiB). `keepBackupOn`:

```kotlin
    /**
     * The restored phone keeps backing up with the same password. Versions continue from max(restored, now): a node
     * that served an older backup must not make this phone's next backups lose to a newer one (D87).
     */
    private suspend fun keepBackupOn(d: Downloaded) {
        settings.setBackupSalt(d.meta.salt.toByteArray())
        settings.setBackupSecret(vault.wrap(d.keys.backupKey + d.keys.authSecret))
        settings.setBackupProfile(d.profile)
        settings.setBackupVersion(maxOf(d.meta.version, clock.now()))
        settings.setBackupLastMs(0) // back up from this phone at the first session
    }
```

  `RestoreFlowTest.kt:86`: `eventually(what = "restored phone backs up with the same password") { node.backupOf(anna.me.userId)!!.version > 1L }`.

- [ ] **Step 5: Run** Verify → `BUILD SUCCESSFUL`.

- [ ] **Step 6: Commit.**

```bash
git add core/data/src/main/kotlin/app/ottermsg/core/data/backup/RestoreManager.kt \
  core/data/src/test/kotlin/app/ottermsg/core/data/FakeNode.kt core/data/src/test/kotlin/app/ottermsg/core/data/RestoreFlowTest.kt \
  core/data/src/test/kotlin/app/ottermsg/core/data/HostileRestoreTest.kt
oc -m "restore: verify BACKUP_META and BLOB_META signatures, salt and profile before installing (C13)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: Android — words restore uses the verified directory entry (C18)

**Goal:** A words-only restore takes username, name and version only from a directory entry that verifies like in
normal sync and belongs to the key derived from the words; the newest such entry wins.

**Findings closed:** C18.

**Files:**
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/directory/DirectorySync.kt` (74-86)
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/backup/RestoreManager.kt` (144-151)
- Modify: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/FakeNode.kt` (`directory()` 236)
- Test: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/HostileRestoreTest.kt`

**Acceptance Criteria:**
- [ ] A forged entry for the account (other username, higher version, wrong signature) next to the genuine one → the
  restore uses the genuine entry (`username == "anna"`).
- [ ] Only forged entries → `RestoreError.UnknownAccount`, nothing installed.
- [ ] `DirectorySyncTest` and `RestoreFlowTest.restoreWithWordsThenHistory` still pass.

**Verify:** `cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*HostileRestoreTest*' --tests '*DirectorySyncTest*' --tests '*RestoreFlowTest*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: FakeNode hook**: `@Volatile var directoryAnswer: ((List<Record>) -> List<Record>)? = null`;
  `override suspend fun directory(): List<Record> { check(); me(); val d = directoryRecords(); return directoryAnswer?.invoke(d) ?: d }`.

- [ ] **Step 2: Failing test** (add to `HostileRestoreTest`; imports `app.ottermsg.core.crypto.Bip39`,
  `app.ottermsg.proto.v1.DirectoryEntry`):

```kotlin
    @Test fun wordsRestoreIgnoresForgedDirectoryEntries() = runBlocking<Unit> {
        anna.register(node.bootstrapLink(), "Анна", "anna").getOrThrow()
        val genuine = node.directoryRecords().first { RecordBody.parseFrom(it.body).author.toByteArray().contentEquals(anna.me.userId) }
        val body = RecordBody.parseFrom(genuine.body)
        val e = DirectoryEntry.parseFrom(body.payload).toBuilder().setUsername("mallory").setDisplayName("Мэллори").setVersion(99).build()
        val forged = RecordCodec.sign(body.toBuilder().setPayload(e.toByteString()).build(), mallory)
        val words = Bip39.toMnemonic(anna.seed)

        node.directoryAnswer = { it + forged }
        val phone = fresh()
        phone.restore.withWords(node.bootstrapLink(), words).getOrThrow()
        assertEquals("anna", phone.me.username)
        assertEquals("Анна", phone.me.displayName)

        node.directoryAnswer = { listOf(forged) }
        val other = fresh()
        assertEquals(RestoreError.UnknownAccount, other.restore.withWords(node.bootstrapLink(), words).exceptionOrNull())
        assertNull(other.db.accountDao().get())
    }
```

- [ ] **Step 3: Run — fails** (`phone.me.username` is `mallory` or the forged entry is taken).

- [ ] **Step 4: Implement.** `DirectorySync.kt`: move `verify` into a companion and call it from `apply`
  (`val e = verifyEntry(rec) ?: continue`):

```kotlin
    companion object {
        /** The entry if [rec] is a self-certifying, correctly bound DIRECTORY_ENTRY (sync and words restore, C18). */
        fun verifyEntry(rec: Record): DirectoryEntry? = runCatching {
            val body = RecordBody.parseFrom(rec.body)
            if (body.type != RecordType.DIRECTORY_ENTRY) return null
            val e = DirectoryEntry.parseFrom(body.payload)
            val accountPub = e.accountPub.toByteArray()
            val ok = accountPub.size == 32 &&
                body.author == e.userId &&
                e.userId.toByteArray().contentEquals(Ids.id16(accountPub)) &&
                RecordCodec.verify(rec, accountPub) &&
                IdentityKeys.verifyBinding(e.identityPub.toByteArray(), accountPub, e.identitySig.toByteArray())
            if (ok) e else null
        }.getOrNull()
    }
```

  `RestoreManager.withWords`, the block inside `withNode`:

```kotlin
            // C18: only entries that verify like in sync and belong to the key from the words; the newest wins
            api.directory().mapNotNull { DirectorySync.verifyEntry(it) }
                .filter { it.userId.toByteArray().contentEquals(userId) && it.accountPub.toByteArray().contentEquals(account.publicKey) }
                .maxByOrNull { it.version }
```

  (import `app.ottermsg.core.data.directory.DirectorySync`; remove the now-unused `RecordType` import only if nothing
  else uses it — `download` does.)

- [ ] **Step 5: Run** Verify → `BUILD SUCCESSFUL`.

- [ ] **Step 6: Commit.**

```bash
git add core/data/src/main/kotlin/app/ottermsg/core/data/directory/DirectorySync.kt \
  core/data/src/main/kotlin/app/ottermsg/core/data/backup/RestoreManager.kt \
  core/data/src/test/kotlin/app/ottermsg/core/data/FakeNode.kt core/data/src/test/kotlin/app/ottermsg/core/data/HostileRestoreTest.kt
oc -m "restore: words restore takes only a verified directory entry of its own key (C18)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 16: Android — only a signed `INSTALL` can supersede this phone (C14)

**Goal:** The phone publishes its own signed install and believes "replaced" only from an `INSTALL` that verifies
with its account key and is newer; unsigned or invalid claims are ignored and logged.

**Findings closed:** C14 (client half).

**Files:**
- Modify: `otter-android/core/network/src/main/kotlin/app/ottermsg/core/network/NodeApi.kt` (interface 38-74, `RemoteNodeApi` 76-125)
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/backup/InstallGuard.kt` (all)
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/settings/Settings.kt`
- Modify: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/FakeNode.kt` (`login` 225-233, new `publishInstall`, hooks)
- Test: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/InstallGuardTest.kt` (rewrite)

**Acceptance Criteria:**
- [ ] After registration + first login the node holds an `INSTALL` with this phone's `installed_ms` and
  `registration_id`; `settings.installPublished()` is true.
- [ ] A restore publishes `INSTALL` before its `PREKEYS` (in `finishRestore`).
- [ ] Login answers with an unsigned `installed_ms = Long.MAX_VALUE`, an `INSTALL` signed by another key, one of
  another author, an undecodable record, or a replay of this phone's own older install → **not** superseded.
- [ ] A genuine newer `INSTALL` (signed by the account) → superseded; a later start stops before login.
- [ ] A node answering `install.publish` with `INVALID` (0.8.x) does not break the session; it is retried next login.
- [ ] `RestoreFlowTest` (old phone superseded at the end) still passes.

**Verify:** `cd otter-android && ./gradlew :core:network:testDebugUnitTest :core:data:testDebugUnitTest --tests '*InstallGuardTest*' --tests '*RestoreFlowTest*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: NodeApi.** Interface (next to `registerPush`):

```kotlin
    /** install.publish (C14): this phone's account-signed INSTALL. Old nodes answer INVALID ("unknown method"). */
    suspend fun publishInstall(record: Record) { throw RpcException(Status.STATUS_INVALID, "install.publish") }
```

  `RemoteNodeApi`: `override suspend fun publishInstall(record: Record) { rpc.call("install.publish", req(record)) }`.

- [ ] **Step 2: FakeNode** (outer class, near `backups`):

```kotlin
    // ---- installs (C14): same rule as the Go node ----
    private val installs = HashMap<String, Pair<Record, app.ottermsg.proto.v1.Install>>()
    /** Hostile node: an unsigned installed_ms in every login answer. */
    @Volatile var lieInstalledMs: Long? = null
    /** Hostile node: this record in every login answer instead of the stored INSTALL. */
    @Volatile var fakeInstall: Record? = null
    fun installOf(user: ByteArray): app.ottermsg.proto.v1.Install? = synchronized(lock) { installs[user.hex()]?.second }
```

  `Session.login` return:

```kotlin
            val k = keys[userId.hex()]
            val b = LoginResponse.newBuilder().setRegistrationId(k?.registrationId ?: 0).setInstalledMs(lieInstalledMs ?: k?.installedMs ?: 0)
            (fakeInstall ?: installs[userId.hex()]?.first)?.let { b.setInstall(it) }
            return b.build()
```

  New `Session` method:

```kotlin
        override suspend fun publishInstall(record: Record) { check(); synchronized(lock) {
            val b = verifyUser(record)
            if (b.type != RecordType.INSTALL || !b.author.toByteArray().contentEquals(me())) fail(Status.STATUS_INVALID, "install")
            val i = app.ottermsg.proto.v1.Install.parseFrom(b.payload)
            val cur = installs[b.author.hex()]?.second
            if (cur != null && (i.installedMs < cur.installedMs || (i.installedMs == cur.installedMs && i.registrationId <= cur.registrationId))) return
            installs[b.author.hex()] = record to i
            val k = keys[b.author.hex()] ?: return
            if (i.installedMs > k.installedMs) { k.oneTime.clear(); k.installedMs = i.installedMs }
            if (i.installedMs >= k.installedMs) k.registrationId = i.registrationId
        } }
```

- [ ] **Step 3: Failing test** — replace `InstallGuardTest.kt`:

```kotlin
package app.ottermsg.core.data

import app.ottermsg.core.crypto.Ed25519
import app.ottermsg.core.crypto.Ids
import app.ottermsg.core.crypto.RecordCodec
import app.ottermsg.proto.v1.Install
import app.ottermsg.proto.v1.Record
import app.ottermsg.proto.v1.RecordType
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** D52 + C14: a phone stops only for an account-signed newer INSTALL; nothing a node says on its own can stop it. */
@RunWith(RobolectricTestRunner::class)
class InstallGuardTest {
    private val clock = TestClock()
    private val node = FakeNode(clock::now)
    private val a = TestGraph(node, clock)
    private val mallory = Ed25519.keyPairFromSeed(ByteArray(32) { 7 })

    @After fun tearDown() = a.close()

    private fun install(rid: Int, installedMs: Long, key: Ed25519.KeyPair = a.me.accountKey, author: ByteArray = a.me.userId): Record =
        RecordCodec.sign(RecordCodec.body(RecordType.INSTALL, author, Install.newBuilder().setRegistrationId(rid)
            .setInstalledMs(installedMs).build().toByteArray(), createdMs = clock.now()), key)

    @Test fun registrationPublishesSignedInstall() = runBlocking<Unit> {
        a.register(node.bootstrapLink(), "Мама", "mama").getOrThrow()
        val installed = a.settings.installedMs()
        a.online()
        assertEquals(installed, node.installOf(a.me.userId)!!.installedMs)
        assertEquals(a.me.registrationId, node.installOf(a.me.userId)!!.registrationId)
        assertTrue(a.settings.installPublished())
        a.prekeys.refill(a.session!!, node.nodeId)
        assertEquals(installed, node.loginInfo(a.me.userId).second) // a refill is not a new install
        assertFalse(a.settings.superseded())
    }

    @Test fun hostileNodeCannotSupersedeThisPhone() = runBlocking<Unit> {
        a.register(node.bootstrapLink(), "Мама", "mama").getOrThrow()
        a.online(); a.offline()
        val far = a.settings.installedMs() + 1_000_000
        node.lieInstalledMs = Long.MAX_VALUE // unsigned claim
        a.online(); a.offline()
        assertFalse(a.settings.superseded())
        val lies = listOf(
            install(77, far, key = mallory),                                        // another key
            install(77, far, key = mallory, author = Ids.id16(mallory.publicKey)),  // another author
            Record.newBuilder().setBody(bs(ByteArray(10) { 1 })).setSignature(bs(ByteArray(64))).build(), // garbage
            install(a.me.registrationId, a.settings.installedMs() - 1),             // replay of an older own install
        )
        for (lie in lies) {
            node.fakeInstall = lie
            a.online(); a.offline()
            assertFalse(a.settings.superseded())
        }
    }

    @Test fun signedNewerInstallSupersedesThisPhone() = runBlocking<Unit> {
        a.register(node.bootstrapLink(), "Мама", "mama").getOrThrow()
        a.online(); a.offline()
        val other = node.connect().apply { login(a.me.userId, a.me.accountKey) }
        other.publishInstall(install(77, a.settings.installedMs() + 1000))
        a.online()
        assertTrue(a.settings.superseded())
        assertEquals(77, node.loginInfo(a.me.userId).first) // the node keeps the newer install
        a.online() // a later start stops before logging in
        assertTrue(a.settings.superseded())
    }
}
```

- [ ] **Step 4: Run — fails** (`installPublished` unresolved; with it stubbed: `hostileNodeCannotSupersedeThisPhone`
  fails on the unsigned claim).

- [ ] **Step 5: Settings** — accessors and key:

```kotlin
    /** This install's INSTALL record reached a node (C14); cleared by «Этот телефон снова главный». */
    suspend fun installPublished(): Boolean = (int(INSTALL_PUBLISHED) ?: 0) != 0
    suspend fun setInstallPublished(v: Boolean) = putInt(INSTALL_PUBLISHED, if (v) 1 else 0)
```

```kotlin
        const val INSTALL_PUBLISHED = "install_published"
```

- [ ] **Step 6: InstallGuard** — new body (constructor unchanged; imports `RecordCodec`, `RpcException`,
  `app.ottermsg.proto.v1.Install`, `app.ottermsg.proto.v1.Record`, `app.ottermsg.proto.v1.RecordBody`,
  `java.util.logging.Logger`):

```kotlin
/** Runs right after every login (D52, C14): finishes a restore, or notices that another phone replaced this one. */
@Singleton
class InstallGuard @Inject constructor(
    private val db: OtterDatabase, private val accounts: AccountRepository, private val settings: Settings,
    private val signal: SignalService, private val resets: SessionResets, private val clock: Clock,
    private val directory: DirectorySync,
) {
    private val log = Logger.getLogger("InstallGuard")

    /** False when this install is superseded: the caller must stop syncing. */
    suspend fun afterLogin(api: NodeApi, resp: LoginResponse): Boolean {
        if (settings.restorePending()) { finishRestore(api); return true }
        val me = accounts.require()
        val signed = if (resp.hasInstall()) verified(resp.install, me.userId, me.accountKey.publicKey) else null
        if (signed != null && isNewer(signed, settings.installedMs(), me.registrationId)) {
            settings.setSuperseded(true)
            return false
        }
        if (resp.hasInstall() && signed == null) log.warning("INSTALL in the login answer does not verify: ignored (C14)")
        if (resp.installedMs > settings.installedMs()) log.warning("unsigned newer installed_ms from the node: ignored (C14)")
        if (!settings.installPublished()) publishInstall(api)
        return true
    }

    /** The INSTALL in [rec] if it is ours and signed by our account key; else null. */
    private fun verified(rec: Record, userId: ByteArray, accountPub: ByteArray): Install? = runCatching {
        val body = RecordBody.parseFrom(rec.body)
        if (body.type != RecordType.INSTALL || !body.author.toByteArray().contentEquals(userId) || !RecordCodec.verify(rec, accountPub)) null
        else Install.parseFrom(body.payload)
    }.getOrNull()

    /** Same order as the nodes: later install time, then the higher registration id. */
    private fun isNewer(i: Install, installedMs: Long, registrationId: Int) =
        i.installedMs > installedMs || (i.installedMs == installedMs && i.registrationId > registrationId)

    /** Signs this phone's install. A node older than 0.9.0 answers INVALID: tried again after the next login. */
    private suspend fun publishInstall(api: NodeApi) {
        val me = accounts.require()
        val payload = Install.newBuilder().setRegistrationId(me.registrationId).setInstalledMs(settings.installedMs()).build()
        try {
            api.publishInstall(RecordCodec.sign(RecordCodec.body(RecordType.INSTALL, me.userId, payload.toByteArray(),
                createdMs = clock.now()), me.accountKey))
            settings.setInstallPublished(true)
        } catch (e: RpcException) {
            log.warning("install.publish refused: ${e.status}")
        }
    }

    /** INSTALL first (every node raises the install), then fresh prekeys, then a reset to every contact. */
    private suspend fun finishRestore(api: NodeApi) {
        publishInstall(api)
        // … the existing body of finishRestore, unchanged …
    }
}
```

  `Registration` and `RestoreManager.install` need no change: both leave `install_published` unset, so the first
  login (or `finishRestore`) publishes; an existing 0.8.x install upgraded to 0.9.0 also publishes at its first login.

- [ ] **Step 7: Run** Verify → `BUILD SUCCESSFUL`; `./gradlew :core:data:testDebugUnitTest` → all pass.
  (`LiveRestoreTest` needs a dev node built from server 0.9.0; it runs in this phase's live run.)

- [ ] **Step 8: Commit.**

```bash
git add core/network/src/main/kotlin/app/ottermsg/core/network/NodeApi.kt \
  core/data/src/main/kotlin/app/ottermsg/core/data/backup/InstallGuard.kt \
  core/data/src/main/kotlin/app/ottermsg/core/data/settings/Settings.kt \
  core/data/src/test/kotlin/app/ottermsg/core/data/FakeNode.kt core/data/src/test/kotlin/app/ottermsg/core/data/InstallGuardTest.kt
oc -m "app: only an account-signed newer INSTALL supersedes this phone; publish our own (C14)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 17: Android — «Этот телефон снова главный»

**Goal:** A superseded phone can take the account back: a new install time, then the restore finish (INSTALL,
fresh prekeys, reset to every contact); the other phone becomes superseded.

**Findings closed:** C14 (recovery path). Design limit 2 remains (see D89; M9.3 `REKEY`).

**Files:**
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/backup/InstallGuard.kt`
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/sync/SyncEngine.kt` (85-90)
- Modify: `otter-android/app/src/main/java/app/ottermsg/MainActivity.kt` (`MainViewModel` 30-43, `setContent` 58-59)
- Modify: `otter-android/app/src/main/java/app/ottermsg/SupersededScreen.kt`
- Modify: `otter-android/app/src/main/res/values/strings.xml`, `values-en/strings.xml` (lines 3-4 + new strings)
- Test: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/RestoreFlowTest.kt`

**Acceptance Criteria:**
- [ ] `InstallGuard.reclaim()` sets `installed_ms = now`, `install_published = false`, `restore_pending = true`,
  `superseded = false`.
- [ ] After reclaim and a login: node's `INSTALL` = this phone's new install; contacts get a reset and can write to
  this phone; the restored phone, at its next login, is superseded.
- [ ] `SupersededScreen` shows the button with a confirmation dialog; confirming calls `MainViewModel.reclaim()`,
  which also restarts sync (`SyncEngine.resume()`).
- [ ] `assembleDebug` passes.

**Verify:** `cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*RestoreFlowTest*' :app:assembleDebug` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing test** — add to `RestoreFlowTest`:

```kotlin
    @Test fun oldPhoneTakesTheAccountBack() = runBlocking<Unit> {
        history()
        val restored = newGraph()
        restored.restore.withWords(boris.invites.create().link, Bip39.toMnemonic(anna.seed)).getOrThrow()
        restored.online(); restored.offline()
        anna.online()
        assertTrue(anna.settings.superseded())
        anna.offline()

        anna.guard.reclaim() // «Этот телефон снова главный»
        assertFalse(anna.settings.superseded())
        anna.online()
        assertFalse(anna.settings.superseded())
        assertEquals(anna.settings.installedMs(), node.installOf(anna.me.userId)!!.installedMs)
        eventually(what = "boris sees anna's second reset") { boris.direct(anna.me.userId).count { it.kind == MessageKind.SYSTEM_RESET } >= 2 }
        boris.messages.sendText(boris.messages.conversationWith(anna.me.userId), "снова тут")
        eventually(what = "anna reads it") { "снова тут" in anna.texts(boris.me.userId) }

        restored.online()
        assertTrue(restored.settings.superseded())
    }
```

- [ ] **Step 2: Run — fails** (`reclaim` unresolved).

- [ ] **Step 3: Implement.** `InstallGuard`:

```kotlin
    /**
     * «Этот телефон снова главный» (C14): this phone becomes a new install. The next login runs the restore finish:
     * INSTALL (newer than the other phone's), fresh prekeys, a reset to every contact.
     */
    suspend fun reclaim() {
        settings.setInstalledMs(clock.now())
        settings.setInstallPublished(false)
        settings.setRestorePending(true)
        settings.setSuperseded(false)
    }
```

  `SyncEngine` (below `fun start()`):

```kotlin
    /** After InstallGuard.reclaim: this install may connect again. */
    @Synchronized fun resume() { superseded = false; if (leases.isNotEmpty()) start() }
```

  `MainActivity.kt` — `MainViewModel` gets `private val guard: InstallGuard, private val engine: SyncEngine` in its
  `@Inject constructor` (imports `app.ottermsg.core.data.backup.InstallGuard`, `app.ottermsg.core.data.sync.SyncEngine`) and:

```kotlin
    /** «Этот телефон снова главный». */
    fun reclaim() { viewModelScope.launch { guard.reclaim(); engine.resume() } }
```

  and the call site: `if (superseded) SupersededScreen(onReclaim = vm::reclaim) else …`.
  `SupersededScreen.kt`:

```kotlin
/** Shown instead of the app when another phone signed a newer install of this account (D52, C14). */
@Composable
fun SupersededScreen(onReclaim: () -> Unit) {
    var confirm by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().safeDrawingPadding().padding(Dimens.screenGutter),
        verticalArrangement = Arrangement.spacedBy(Dimens.s16, Alignment.CenterVertically)) {
        OtterIllustration(UiR.drawable.otter_welcome, maxSize = 160.dp, modifier = Modifier.align(Alignment.CenterHorizontally))
        Text(stringResource(R.string.superseded_title), style = MaterialTheme.typography.headlineSmall,
            color = MaterialTheme.colorScheme.onBackground, modifier = Modifier.semantics { heading() })
        Text(stringResource(R.string.superseded_text), style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onBackground)
        OutlinedButton(onClick = { confirm = true }, modifier = Modifier.align(Alignment.CenterHorizontally)) {
            Text(stringResource(R.string.superseded_reclaim))
        }
    }
    if (confirm) AlertDialog(
        onDismissRequest = { confirm = false },
        title = { Text(stringResource(R.string.superseded_reclaim_title)) },
        text = { Text(stringResource(R.string.superseded_reclaim_text)) },
        confirmButton = { TextButton(onClick = { confirm = false; onReclaim() }) { Text(stringResource(R.string.superseded_reclaim_yes)) } },
        dismissButton = { TextButton(onClick = { confirm = false }) { Text(stringResource(R.string.superseded_reclaim_no)) } },
    )
}
```

  (imports `androidx.compose.material3.AlertDialog`, `OutlinedButton`, `TextButton`, `androidx.compose.runtime.getValue`,
  `setValue`, `mutableStateOf`, `remember`). Strings, `values/strings.xml`:

```xml
    <string name="superseded_text">Аккаунт восстановлен на другом телефоне, и этот телефон больше не получает сообщения. Если это сделали не вы, кто-то знает ваши 12 слов: верните аккаунт сюда и сообщите администратору семьи.</string>
    <string name="superseded_reclaim">Этот телефон снова главный</string>
    <string name="superseded_reclaim_title">Сделать этот телефон главным?</string>
    <string name="superseded_reclaim_text">Другой телефон с этим аккаунтом перестанет получать сообщения. Контакты увидят, что сеанс обновился.</string>
    <string name="superseded_reclaim_yes">Да, этот</string>
    <string name="superseded_reclaim_no">Отмена</string>
```

  `values-en/strings.xml`:

```xml
    <string name="superseded_text">This account was restored on another phone, and this phone no longer receives messages. If that was not you, someone knows your 12 words: take the account back here and tell your family admin.</string>
    <string name="superseded_reclaim">This phone is the main one again</string>
    <string name="superseded_reclaim_title">Make this phone the main one?</string>
    <string name="superseded_reclaim_text">The other phone with this account will stop receiving messages. Your contacts will see that the session was renewed.</string>
    <string name="superseded_reclaim_yes">Yes, this one</string>
    <string name="superseded_reclaim_no">Cancel</string>
```

- [ ] **Step 4: Run** Verify → `BUILD SUCCESSFUL`.

- [ ] **Step 5: Commit.**

```bash
git add core/data/src/main/kotlin/app/ottermsg/core/data/backup/InstallGuard.kt \
  core/data/src/main/kotlin/app/ottermsg/core/data/sync/SyncEngine.kt \
  app/src/main/java/app/ottermsg/MainActivity.kt app/src/main/java/app/ottermsg/SupersededScreen.kt \
  app/src/main/res/values/strings.xml app/src/main/res/values-en/strings.xml \
  core/data/src/test/kotlin/app/ottermsg/core/data/RestoreFlowTest.kt
oc -m "app: «Этот телефон снова главный» re-signs the install and resets sessions (C14)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 18: Android — decoy backup meta for accounts without a backup (C20)

**Goal:** Every account without a backup publishes one decoy `BACKUP_META`, so `backup.auth` cannot tell members
with and without a backup apart.

**Findings closed:** C20 (app half).

**Files:**
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/backup/BackupManager.kt` (`runIfDue` 80-83, new function)
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/settings/Settings.kt`
- Modify: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/FakeNode.kt` (`backupPublish` 415-426, `backupFetch` 400-413)
- Test: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/BackupManagerTest.kt`

**Acceptance Criteria:**
- [ ] After registration and the first session the node holds a decoy for the account: version 0, 16-byte salt,
  profile-1 numbers, size 0, `blob_key` = user id ‖ 16 zero bytes; published once (a second session keeps it).
- [ ] `backup.auth` for that username returns the decoy salt with 65536/3/1; a restore with any password →
  `WrongPassword`.
- [ ] Setting a password replaces the decoy with version ≥ 1; existing `BackupManagerTest` assertions still hold.
- [ ] A node refusing the decoy (`INVALID`) leaves the flag unset (retried next session) and the session continues.

**Verify:** `cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*BackupManagerTest*' --tests '*FakeNodeBackupTest*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: FakeNode** — `backupPublish` accepts decoys like the Go node:

```kotlin
            val m = BackupMeta.parseFrom(b.payload)
            if (m.version == 0L) { // decoy (C20): no blob
                if (m.size != 0L || !m.blobKey.toByteArray().contentEquals(b.author.toByteArray() + ByteArray(16))) fail(Status.STATUS_INVALID, "decoy")
            } else {
                val blob = blobs[m.blobKey.hex()] ?: fail(Status.STATUS_INVALID, "backup blob unknown here")
                if (blob.author != b.author.hex() || !blob.meta.persistent) fail(Status.STATUS_INVALID, "not the author's persistent blob")
            }
            val cur = backups[b.author.hex()]
            if (cur != null && cur.second.version >= m.version) return // latest version wins (D50)
            backups[b.author.hex()] = meta to m
            if (cur != null && cur.second.version > 0 && cur.second.blobKey != m.blobKey) {
                blobs.remove(cur.second.blobKey.hex()); goneBlobs += cur.second.blobKey.hex()
            }
```

  `backupFetch`: treat a decoy like a wrong password — change the condition to
  `if (cur == null || cur.second.version == 0L || !sha(authSecret).contentEquals(cur.second.authVerifier.toByteArray()))`.

- [ ] **Step 2: Failing test** — add to `BackupManagerTest` (imports `app.ottermsg.core.data.backup.RestoreError`):

```kotlin
    @Test fun accountWithoutBackupLooksLikeOneWithBackup() = runBlocking<Unit> {
        family()
        eventually(what = "decoys published") { node.backupOf(a.me.userId) != null && node.backupOf(b.me.userId) != null }
        val decoy = node.backupOf(a.me.userId)!!
        assertEquals(0L, decoy.version)
        assertEquals(16, decoy.salt.size())
        assertEquals(0L, decoy.size)
        assertArrayEquals(a.me.userId + ByteArray(16), decoy.blobKey.toByteArray())
        val auth = node.connect().backupAuth("mama")
        assertEquals(decoy.salt, auth.salt)
        assertEquals(listOf(65536, 3, 1), listOf(auth.kdfMKib, auth.kdfT, auth.kdfP))
        val phone = TestGraph(node, clock)
        try {
            assertEquals(RestoreError.WrongPassword, phone.restore.withPassword(node.bootstrapLink(), "mama", "любой пароль здесь").exceptionOrNull())
        } finally { phone.close() }

        a.offline(); a.online() // once per install
        assertEquals(decoy, node.backupOf(a.me.userId))
        assertEquals(BackupManager.OK, a.backups.setPassword("корова лодка зима семь"))
        assertEquals(1L, node.backupOf(a.me.userId)!!.version)
    }
```

- [ ] **Step 3: Run — fails** (`decoys published` times out).

- [ ] **Step 4: Settings** — `BACKUP_DECOY = "backup_decoy_done"`, `backupDecoyDone()` / `setBackupDecoyDone(v)` in
  the same int-flag style as `installPublished` (Task 16).

- [ ] **Step 5: BackupManager** (imports `app.ottermsg.proto.v1.BackupMeta` exists; add nothing else):

```kotlin
    /** From each sync session: back up if the last success is older than 24 h; without a backup, make sure of the decoy. */
    suspend fun runIfDue(api: NodeApi) {
        if (settings.backupSecret() == null) { publishDecoyIfNeeded(api); return }
        if (clock.now() - settings.backupLastMs() < DAY_MS) return
        run(api)
    }

    /**
     * C20: an account without a backup publishes one decoy BACKUP_META (version 0, random salt and verifier, no blob),
     * so every node answers backup.auth for it exactly as for an account with a backup. A real backup replaces it.
     * A node older than 0.9.0 refuses it (INVALID): tried again next session.
     */
    internal suspend fun publishDecoyIfNeeded(api: NodeApi) {
        if (settings.backupDecoyDone() || settings.backupVersion() != 0L) return
        val me = accounts.require()
        val profile = BackupKeys.Profile.CURRENT
        val meta = BackupMeta.newBuilder().setVersion(0).setSalt(bs(BackupKeys.newSalt()))
            .setKdfMKib(profile.mKib).setKdfT(profile.t).setKdfP(profile.p)
            .setAuthVerifier(bs(ByteArray(32).also(SecureRandom()::nextBytes)))
            .setBlobKey(bs(me.userId + ByteArray(16))).setSize(0).build()
        try {
            api.backupPublish(RecordCodec.sign(RecordCodec.body(RecordType.BACKUP_META, me.userId, meta.toByteArray(),
                createdMs = clock.now()), me.accountKey))
            settings.setBackupDecoyDone(true)
        } catch (e: RpcException) {
            // refused (an older node): next session
        }
    }
```

  A words-restored phone (`backupVersion() == 0`) also publishes one; if the account has a real backup, the decoy
  (version 0) loses on every node and changes nothing.

- [ ] **Step 6: Run** Verify → `BUILD SUCCESSFUL`; full `./gradlew :core:data:testDebugUnitTest` → pass.

- [ ] **Step 7: Commit.**

```bash
git add core/data/src/main/kotlin/app/ottermsg/core/data/backup/BackupManager.kt \
  core/data/src/main/kotlin/app/ottermsg/core/data/settings/Settings.kt \
  core/data/src/test/kotlin/app/ottermsg/core/data/FakeNode.kt core/data/src/test/kotlin/app/ottermsg/core/data/BackupManagerTest.kt
oc -m "app: publish a decoy backup meta when there is no backup (C20)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 19: Docs — protocol, security and decisions for M9.1a

**Goal:** The docs describe what the code now does: KDF profiles, verified restore, `INSTALL`, decoys.

**Findings closed:** documentation for C1, C13, C14, C18, C20.

**Files:**
- Modify: `docs/02-protocol.md` (record table ~57-66: `PREKEYS` row, `BACKUP_META` row, new `INSTALL` row; line 227
  `auth.login`; line 246 `backup.auth`; line 248 `backup.publish`; new `install.publish` row; restore steps 305-308)
- Modify: `docs/04-security.md` (backup section ~71-115: KDF profiles, restore checks, fake salts → decoys; install record and design limit 2)
- Modify: `docs/00-decisions.md` (append D86–D90 from this section with the numbers the merged plan assigns; add
  "superseded by …" notes to D51 (fake-salt limit) and D52 (client decision now from `INSTALL`))

**Acceptance Criteria:**
- [ ] `02-protocol.md` lists `INSTALL` (type 17), `LoginResponse.install`, `install.publish`, decoy `BACKUP_META`
  (version 0) and says the phone ignores the unsigned login fields.
- [ ] `04-security.md` states profile 1 numbers, "node numbers are an ID only", the five restore checks, the decoy
  rule and its remaining leaks, and design limit 2 (seed holder can sign `INSTALL`; `REKEY` in M9.3).
- [ ] D51 and D52 rows point to the new entries; no other D row changes.

**Verify:** `cd docs && grep -c "INSTALL" 02-protocol.md 04-security.md` → both ≥ 2; `grep -n "decoy" 00-decisions.md` → at least one line

**Steps:**

- [ ] **Step 1:** In `02-protocol.md` add after the `BACKUP_META` row:

```markdown
| `INSTALL` (type 17) | user | `Install{registration_id (1–16380), installed_ms (0 … node time + 10 min)}`; no expiry | Newest (installed_ms, registration_id) per user wins, the loser is deleted; a newer one deletes the device's prekeys like a newer `PREKEYS` (D52). Returned in `LoginResponse.install`. The only thing a phone believes about "another phone replaced me" (M9.1, C14) |
```

  Change the `BACKUP_META` row's rule text to add: "`version 0` = decoy (C20): `size 0`, `blob_key = author ‖ 16
  zero bytes`, no blob; loses to any real version; `backup.fetch` never opens it." Change line 227 to
  "`auth.login` answers `LoginResponse{registration_id, installed_ms, install}`; 0.9.0+ phones use only the signed
  `install`." Change the `backup.auth` row: "Members without a backup have a decoy (C20), answered like a backup;
  unknown usernames get the node-local fake salt (differs per node: reveals only non-membership)." Add a method row:
  "`install.publish{Record INSTALL}` | logged in; the session that publishes a newer install is that install (D56)".
  In the restore steps: "→ salt and KDF numbers, which must equal a client profile (else stop) → Argon2id → … → verify
  `BACKUP_META`/`BLOB_META` signatures, blob key, salt and profile against the decrypted seed's account key".

- [ ] **Step 2:** In `04-security.md` replace the "Fake salts (D51)" bullet with the decoy rule and its remaining
  leaks (salt change on password set/change; 0.8.x phones until they update), and add bullets "KDF profiles (C1)",
  "Restore checks (C13, C18)" and "Install record (C14)" with the texts of D86–D89 above, including the design-limit-2
  sentence.

- [ ] **Step 3:** In `00-decisions.md` append the five entries (D86–D90 text above, numbered as assigned) and add
  to D51's "Limits" cell: "Replaced by D<D90> for members." and to D52: "Phone side replaced by D<D89> (signed
  `INSTALL`); the node rule stays."

- [ ] **Step 4: Commit.**

```bash
cd ~/Documents/Projects/OttterMSG/docs
git add 02-protocol.md 04-security.md 00-decisions.md
oc -m "docs: KDF profiles, verified restore, INSTALL record, backup decoys (M9.1a)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Owner questions (M9.1a)

1. **Where is «Этот телефон снова главный»?** The spec says Settings, but a superseded phone shows only
   `SupersededScreen` (`MainActivity.kt:58-59`) and never reaches Settings. **Recommendation:** the button lives on
   the superseded screen with a confirmation dialog (Task 17); nothing in Settings.
2. **C20 mechanism.** The spec says "fake salt = HMAC(network key, username), the same on every node". Nodes share no
   secret (network private key is offline; TURN secrets are per node), so that needs a new secret on every node.
   **Recommendation:** decoy `BACKUP_META` published by the phone (D90, Tasks 12 and 18); unknown usernames keep the
   node-local fake salt (reveals only that a name is not a member).
3. **Message for a refused KDF answer.** **Recommendation:** reuse «Копия повреждена. Попробуйте ещё раз позже»
   (`RestoreError.Corrupt`) — a retry races the nodes again; no new string.
4. **Rollout order.** All nodes on server 0.9.0 before app 0.9.0 is published (0.8.x nodes drop `INSTALL` and decoys
   from replication for good). **Recommendation:** accept; the M9.1 rollout task upgrades every node first.

---

## M9.1b — Client hardening and push switches

Repos: `otter-android` (most tasks), `otter-server` (Tasks 20–21, push decision and envelope batch size), `docs`
(decisions, protocol rows; Task 29). Branch `m9-1-client` in all three (created in Task 10; if it does not exist yet,
create it from `main` as in Task 20 Step 1). Versions: app **0.9.0 / versionCode 11**, server **0.9.0**.

**Proto additions:** none beyond the fixed allocations (`PushToken.messages_off = 4`, `PushToken.withdrawn = 5`).
No new RPC. One new server migration: `internal/store/migrations/0010_push_switches.sql` (M9.0 adds none; if a Task
10–19 migration already took `0009`, use the next free number).

**Verified facts** (read 2026-11-14 on `main`: android `143b981`, server `9a6c3fa`):

| Question | Answer | Source |
|---|---|---|
| C15: order in `MailboxReceiver.handle` | `seen.insert(...)` runs **before** the sender lookup and `RecordCodec.verify`; a bad signature then still does `acks += key`. The ACK is a signed record that replicates: every node deletes the mailbox entry for `author‖id` and keeps a tombstone (`DELETE FROM mailbox … record_key=?` + `INSERT INTO tombstones`). So a forged copy both marks the id seen **and** makes the phone delete the real envelope network-wide | `core/data/.../messaging/MailboxReceiver.kt:53-65`, `otter-server/internal/store/typed.go:166-190` |
| Can the seen row go into the same transaction as the decrypt? | No: libsignal state is written through `RoomSignalKeyValue` inside `SignalService.withSessions` (own mutex, `Dispatchers.IO`), outside any Room transaction; nesting it in `db.withTransaction` would deadlock Room's transaction thread. The seen row goes into the transaction that stores the message; the crash window between decrypt and commit is covered by treating libsignal's `DuplicateMessageException` as "already processed" | `core/data/.../signal/SignalService.kt:30-45`, `GroupReceiver.kt:27` (same exception already used for groups) |
| C16: fallback rule today | `candidates()` adds **every** endpoint of the previous manifest not in the latest one for 7 days after the update, including nodes the admin removed and pins the admin withdrew | `core/data/.../sync/ManifestUpdater.kt:55-70` |
| Largest legitimate frame a node sends | `apk.get`: `ApkChunk{data ≤ 1 MiB, total_size}` → **> 1 MiB** with framing (`apk.ChunkSize = 1 << 20`). `envelopes` event: up to `deliverBatch = 100` records, each body ≤ `MaxBodySize` 300 KiB → up to ~30 MiB in theory (no byte cap today). `blob.get`: 256 KiB. `directory.sync`: one entry per member (< 1 KiB each). `news.list`: every announcement ever (text ≤ 4000 runes × 2 languages ≈ ≤ 24 KiB each). The server's own Go client reads with a **4 MiB** limit; the node reads client frames with 1 MiB | `otter-server/internal/apk/dir.go:16`, `internal/gateway/gateway.go:19-23`, `session.go:155-199`, `internal/records/validate.go:18-29`, `internal/client/client.go:90` |
| → chosen client frame limit | **4 MiB**, not 1 MiB: 1 MiB would break `apk.get` (the 1 MiB chunk plus header). With Task 21 capping an `envelopes` batch at 768 KiB, every legitimate frame is ≤ ~1.1 MiB; 4 MiB leaves room for `news.list` (~170 max-size or ~1000 typical announcements) and matches the server's own client | as above |
| Where the phone could bound a frame | Only after OkHttp has buffered the whole WebSocket message: OkHttp 5.2.1 has no inbound size option (`OkHttpClient.Builder` has only `webSocketCloseTimeout`, `minWebSocketMessageToCompress`); `RealWebSocket` always offers `permessage-deflate` and refuses a user-set `Sec-WebSocket-Extensions` header; **network interceptors do not run for web sockets** (only application interceptors). The node (coder/websocket 1.8.15) never enables compression (`CompressionMode` defaults to disabled) | `javap` on `okhttp-jvm-5.2.1.jar` (`RealWebSocket`, `RealWebSocket$connect$1`), `go doc github.com/coder/websocket AcceptOptions` |
| Event queue | `RpcClient._events = Channel(UNLIMITED)`: a node can queue unlimited events while the phone decrypts | `core/network/.../RpcClient.kt:29-33` |
| Blob chunk size | Blob chunks are 256 KiB slices of the **ciphertext** file (`BlobCipher.CHUNK = 256 * 1024`; AEAD segment 1 MiB inside the file). So every chunk except the last is exactly 256 KiB and the last is `size - idx*CHUNK`: the phone can demand the exact size (stricter than "256 KiB + overhead") | `core/crypto/.../BlobCipher.kt:16-17`, `MediaTransfers.kt:136-150`, `otter-server/internal/service/blobs.go:112-116` |
| APK download | Loop runs while `index*CHUNK < u.size` and appends whatever a chunk holds: a node can make the `.part` file grow without bound; `u.size` (signed `AppUpdate.size`) is checked only after the download | `core/data/.../news/ApkUpdater.kt:49-66` |
| Who handles an oversize session | `ConnectionManager.loop`: when a session ends it sets `remaining = emptyList()` and waits/backoffs; only a failure **during** connect filters the candidate out and tries the others at once | `core/network/.../ConnectionManager.kt:80-130` |
| C19: release signing | `signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")`; `staging` sets debug signing itself. Unit tests (`testDebugUnitTest`, `testReleaseUnitTest`) do not run `packageRelease` | `app/build.gradle.kts:24-53` |
| C21: decode | `load()` samples to roughly `maxPx` but has no pixel cap (the viewer asks for `MAX_PX = 4096`, so a 30000×30000 photo decodes at 7500×7500 = 225 MB); `thumb()` decodes the sender's thumbnail bytes (≤ 16 KiB, D-check in `IncomingAttachments`) with no bounds at all. `PhotoStore`/`PhotoSource` have no "corrupt" state: a failed decode leaves a spinner (viewer) or the thumbnail | `core/data/.../media/PhotoLoader.kt:23-49`, `IncomingAttachments.kt:14-16`, `feature/conversation/.../PhotoViewerScreen.kt:56-73`, `PhotoMessage.kt:49-62` |
| C22: screens with secrets | Already `SecureWindow()`: `PhraseScreen`, `PhraseConfirmScreen`, `RestoreWordsScreen`. **Missing:** `RestorePasswordScreen`, `RestoreHistoryScreen` (both type the backup password), `BackupScreen`'s `PasswordForm` (sets it). No settings screen shows the words again. `SecureWindow` is `internal` to `:feature:onboarding` and clears the flag on dispose even when the next screen also set it (navigation transitions dispose the old screen after the new one entered) | `feature/onboarding/.../screens/PhraseScreen.kt:45-60`, `RestoreScreens.kt:63-147`, `feature/settings/.../BackupScreen.kt:203-225` |
| C23: link contact | Stored `verified = true`, `entryVersion = 0`, keys straight from the unsigned link fields; `inviter_user_id` is not even checked against `Ids.id16(inviter_account_pub)`. `Outbox.process` encrypts to `contact.identityPub` and `MailboxReceiver` verifies with `contact.accountPub`, so a forged link + a node that serves matching prekeys and omits the real entry = a MITM of the inviter chat. Directory entries always have `version ≥ 1` (server refuses 0), so `entryVersion == 0` means "only from a link". `verified` is not shown anywhere in the UI today | `core/data/.../registration/Registration.kt:118-126`, `Outbox.kt:124-140`, `DirectorySync.kt:40-58`, `otter-server/internal/records/validate.go:196` |
| C24: shared log | `NetLogRoute` shares exactly the on-screen lines: endpoint with host/IP (`wss://203.0.113.7:27443`), mobile operator, exception text with IPs. Times are already minute resolution (`dd.MM HH:mm`) | `feature/settings/.../NetLogScreen.kt:46-90`, `core/network/.../NetLog.kt:13` |
| Push decision today | `Service.maybePush`: call envelopes → `Waker.WakeCall`, others → `Wake` unless online; `Pusher.wake` reads the token (`Tokens.PushToken`) in a goroutine and sends. Announcements use `Wake` via `pushNews`/`PushTargets`. `PUSH_TOKEN` apply: newest `created_ms` per (user, device) wins; `checkPushToken` requires a 1–4096-byte token. `push.status` = "this node holds a non-empty token" | `otter-server/internal/service/push.go:55-75`, `internal/push/pusher.go:18-95`, `internal/store/typed.go:121-141`, `internal/store/push.go`, `internal/store/news.go:62-78`, `internal/records/validate.go:263-271`, `internal/service/calls.go:25-33` |
| Push on the phone | `PushRegistrar` sends when `pushToken != pushTokenSent`; `PushMonitor.modeOf` → SAVER when the token is empty; `OtterApp` always fetches the FCM token when push is available; `OtterMessagingService.onNewToken` always stores it. The «Показывать уведомления» switch only gates local notifications (`MessageNotifier`) | `core/data/.../push/PushRegistrar.kt`, `PushMonitor.kt:57-58`, `app/.../OtterApp.kt:50-54`, `app/.../push/OtterMessagingService.kt:24-29`, `app/.../notify/MessageNotifier.kt:41` |
| Proto generation | Server: `make gen` (buf v1.75.0 + protoc-gen-go v1.36.12). Android copies with `otter-android/scripts/sync-proto.sh` | `otter-server/Makefile:9-12`, `otter-android/scripts/sync-proto.sh` |

**Decisions to record:**

- **D91 — Envelopes are marked seen only after verification (C15).** The receiver checks `seen` first (only
  verified, processed envelopes are ever in it), then verifies the signature with the sender's directory key. A copy
  that fails verification is **neither marked seen nor acknowledged** (an ACK would tombstone the real envelope on
  every node) and is logged; it stays on the node that served it. The seen row is written in the same Room transaction
  that stores the message; content handled outside a transaction (calls, group control, resets, SENDER_KEY) marks
  seen right after it is handled. libsignal's `DuplicateMessageException` on a 1:1 envelope means "decrypted before a
  crash cut the commit": marked seen, acked, nothing shown, no session reset.
- **D92 — Manifest fallback only for what the newest manifest authorizes (C16).** For 7 days after a manifest
  update, an endpoint of the previous manifest stays a low-priority candidate only if the newest manifest still lists
  the same `node_id` and every pin of that endpoint is among the pins the newest manifest gives that node. A removed
  node or a withdrawn pin is unusable at once; a node that moved host keeps its old address for 7 days.
- **D93 — Receive limits (C17).** Frame ≤ **4 MiB** (largest legitimate: `apk.get` 1 MiB + header); events received
  but not yet handled ≤ **16 MiB**; `blob.get` chunk ≤ 256 KiB and exactly the expected size; `apk.get` chunk ≤ 1 MiB
  and exactly `min(1 MiB, size − offset)`; APK total = signed `AppUpdate.size` and ≤ 100 MiB. Over a limit the phone
  drops the connection, records an endpoint failure and a «Журнал подключений» line `limit: …`, and races the other
  candidates at once. The phone never offers or accepts WebSocket compression (`permessage-deflate`), so a few KB on
  the wire can never inflate to gigabytes. Nodes cap one `envelopes` event at 768 KiB (always at least one record).
  *Accepted residual:* OkHttp buffers a whole WebSocket message before the app sees it, so a hostile node can still
  make the phone buffer one huge **uncompressed** frame, at the cost of sending all those bytes (see Owner question 2).
- **D94 — Push switches (owner option B; design limit 4).** Settings → «Уведомления» has two switches:
  «Показывать уведомления» (D62) and «Пробуждение через Google» (default on). `PushToken` gains
  `messages_off = 4` and `withdrawn = 5`. Notifications off → the phone re-sends `PUSH_TOKEN` with
  `messages_off = true`; nodes then send no message or announcement pushes to that device, but still send call
  pushes. Google wake off → the phone deletes its FCM token (`FirebaseMessaging.deleteToken`, auto-init off) and sends
  `PUSH_TOKEN{withdrawn = true, token = ""}`; nodes erase the token (the row keeps only `created_ms`/`record_key`, so
  an older token record replicated later cannot bring it back); the phone runs in battery-saver mode (D61) and the
  screen says «Без пробуждения через Google звонки не будут приходить». `push.status` reports false for a withdrawn
  device. Validation: `withdrawn` ⇒ empty token and `messages_off = false`; otherwise a 1–4096-byte token. Old
  `PUSH_TOKEN` records holding the token string are removed by the per-author compaction of M9.2 (C8).
- **D95 — The inviter from a link is unconfirmed (C23).** Registration stores the inviter from the link only if
  `inviter_user_id = ID16(inviter_account_pub)`, always with `verified = false` and `entryVersion = 0`. A contact
  with `entryVersion = 0` is a name in the chat list only: the outbox does not encrypt to it and the receiver does not
  accept envelopes signed with its link key, until a verified directory entry replaces it (keys that differ from the
  link set `identityChanged`).
- **D96 — The shared connection log is redacted (C24).** «Поделиться» sends lines with the node label instead of the
  host (`wss:27443`), no mobile operator, IP addresses and the endpoint's host removed from the error text (the host
  replaced by the node label, other IPs by `<ip>`), times at minute resolution (as on screen). The on-screen log is
  unchanged.
- **D97 — Release builds require the release key (C19).** `packageRelease` / `signReleaseBundle` fail without
  `keystore.properties`; there is no debug-key fallback. Debug and staging builds stay debug-signed; unit tests do not
  need the key. Supersedes the fallback sentence of D68.
- **D98 — Bounded picture decoding and secure secret screens (C21, C22).** Photos and thumbnails are decoded with
  `inJustDecodeBounds` first; a source over 100 megapixels or with no size is refused and shows «Фото повреждено»;
  the decoded long edge is at most 4096 px (thumbnails 256 px). `FLAG_SECURE` (reference-counted per window) on
  every screen that shows or takes the recovery words or a backup password: phrase, phrase check, restore by words,
  restore by password, restore history, backup password form.

---

### Task 20: Server — `PushToken.messages_off` / `withdrawn`, call-only pushes, token withdrawal

**Goal:** A phone can tell every node "calls only" or "forget my token", and the push decision honours it.

**Findings closed:** design limit 4 (FCM: registration continued while notifications were off), push option B (server half)

**Files:**
- Modify: `otter-server/proto/otter/v1/records.proto:115-124` (`PushToken`), regenerate `internal/proto/otterv1/*.pb.go`
- Create: `otter-server/internal/store/migrations/0010_push_switches.sql`
- Modify: `otter-server/internal/records/validate.go:263-271` (`checkPushToken`)
- Modify: `otter-server/internal/store/typed.go:121-141` (`PUSH_TOKEN` apply), `internal/store/push.go` (new `PushTarget`),
  `internal/store/news.go:62-78` (`PushTargets`)
- Modify: `otter-server/internal/push/pusher.go:18-22,78-92` (`Tokens` interface, `wake`)
- Modify: `otter-android/core/proto/src/main/proto/otter/v1/records.proto` (via `scripts/sync-proto.sh`)
- Test: `otter-server/internal/records/validate_test.go` (`TestCheckPushToken`), `internal/store/push_test.go`,
  `internal/push/pusher_test.go`

**Acceptance Criteria:**
- [ ] Both proto copies are identical (`diff` prints nothing) and carry `bool messages_off = 4; bool withdrawn = 5;`.
- [ ] `checkPushToken` accepts `messages_off = true` with a token and `withdrawn = true` with an empty token; refuses
  `withdrawn` with a token, `withdrawn` + `messages_off`, and an empty token without `withdrawn`.
- [ ] After applying token → `messages_off` → `withdrawn`, `Store.PushTarget` returns `("t1", false)`, `("t1", true)`,
  `("", false)`; an **older** token record applied afterwards does not bring the token back; `PushTargets` skips the
  withdrawn device.
- [ ] `Pusher.Wake` sends nothing to a `messages_off` device and logs `push skipped … reason=messages_off`;
  `Pusher.WakeCall` still sends to it.

**Verify:** `cd otter-server && go test -race -count=1 ./internal/records/ ./internal/store/ ./internal/push/ ./internal/service/ ./internal/gateway/` → `ok` for each; `diff otter-server/proto/otter/v1/records.proto otter-android/core/proto/src/main/proto/otter/v1/records.proto` → no output

**Steps:**

- [ ] **Step 1: Branches** (skip a repo whose `m9-1-client` exists from Task 10):

```bash
cd ~/Documents/Projects/OttterMSG
for r in otter-server otter-android docs; do
  git -C $r rev-parse --verify -q m9-1-client >/dev/null && git -C $r checkout m9-1-client || { git -C $r checkout main && git -C $r pull --ff-only && git -C $r checkout -b m9-1-client; }
done
export PATH=/usr/lib/go-1.26/bin:$HOME/go/bin:$PATH
```

- [ ] **Step 2: Proto.** In `otter-server/proto/otter/v1/records.proto` replace the `PushToken` fields:

```proto
// PUSH_TOKEN payload (D60): the newest record per (author, device) is that device's push token.
message PushToken {
  enum Kind {
    KIND_UNSPECIFIED = 0;
    FCM = 1;
  }
  uint32 device_id = 1;
  Kind kind = 2;
  string token = 3;       // 1–4096 bytes of UTF-8; empty exactly when withdrawn
  bool messages_off = 4;  // M9.1: notifications off on the phone: wake this device for calls only
  bool withdrawn = 5;     // M9.1: Google wake-ups off: nodes forget the token, no pushes at all
}
```

Then `cd otter-server && make gen && cd ../otter-android && scripts/sync-proto.sh` → `synced from …`.

- [ ] **Step 3: Failing tests.**

`internal/records/validate_test.go`, in `TestCheckPushToken` after the first `if`:

```go
	good := map[string]func(*pb.PushToken){
		"messages off": func(p *pb.PushToken) { p.MessagesOff = true },
		"withdrawn":    func(p *pb.PushToken) { p.Token = ""; p.Withdrawn = true },
	}
	for name, mut := range good {
		if err := checkPushToken(pushTokenBody(a, mut)); err != nil {
			t.Errorf("%s: rejected: %v", name, err)
		}
	}
```

and add to the `bad` map:

```go
		"withdrawn with a token":       func(p *pb.PushToken) { p.Withdrawn = true },
		"withdrawn and messages off":   func(p *pb.PushToken) { p.Token = ""; p.Withdrawn = true; p.MessagesOff = true },
```

`internal/store/push_test.go`, append:

```go
func TestPushTokenSwitches(t *testing.T) {
	s, _ := open(t)
	ctx := context.Background()
	u := r16()
	tok := func(token string, off, withdrawn bool, created int64) Item {
		return mkItemAt(t, pb.RecordType_PUSH_TOKEN, u,
			&pb.PushToken{DeviceId: 1, Kind: pb.PushToken_FCM, Token: token, MessagesOff: off, Withdrawn: withdrawn}, created)
	}
	check := func(step, wantTok string, wantOff bool) {
		t.Helper()
		got, off, err := s.PushTarget(ctx, u, 1)
		if err != nil || got != wantTok || off != wantOff {
			t.Fatalf("%s: got (%q, %v, %v), want (%q, %v)", step, got, off, err, wantTok, wantOff)
		}
	}
	for _, step := range []struct {
		name string
		it   Item
		tok  string
		off  bool
	}{
		{"token", tok("t1", false, false, 100), "t1", false},
		{"messages off", tok("t1", true, false, 200), "t1", true},
		{"withdrawn", tok("", false, true, 300), "", false},
		{"older token replicated late", tok("t0", false, false, 150), "", false},
	} {
		if err := apply(t, s, step.it); err != nil {
			t.Fatalf("%s: %v", step.name, err)
		}
		check(step.name, step.tok, step.off)
	}
	if got, _ := s.PushToken(ctx, u, 1); got != "" {
		t.Fatalf("withdrawn token still served: %q", got)
	}
	if got, err := s.PushTargets(ctx); err != nil || len(got) != 0 {
		t.Fatalf("withdrawn device is still an announcement target: %v %v", got, err)
	}
}
```

`internal/push/pusher_test.go`: give `memTokens` an `off` map and the new interface method (keep `PushToken` as a
test helper), add `"bytes"` to the imports, and append the test:

```go
type memTokens struct {
	mu   sync.Mutex
	toks map[string]string
	off  map[string]bool
}

func (m *memTokens) PushTarget(_ context.Context, user []byte, device uint32) (string, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.toks[string(user)], m.off[string(user)], nil
}

// PushToken: test helper only (not part of Tokens any more).
func (m *memTokens) PushToken(ctx context.Context, user []byte, device uint32) (string, error) {
	tok, _, err := m.PushTarget(ctx, user, device)
	return tok, err
}

func TestPusherMessagesOffStillRingsCalls(t *testing.T) {
	s := &fakeSender{}
	toks := &memTokens{toks: map[string]string{"bob": "tok-b"}, off: map[string]bool{"bob": true}}
	var logs bytes.Buffer
	p := New(s, toks, slog.New(slog.NewTextHandler(&logs, nil)))
	ctx := context.Background()
	p.Wake(ctx, []byte("bob"), 1)
	p.Wait()
	if len(s.sent) != 0 {
		t.Fatalf("message push sent to a calls-only device: %v", s.sent)
	}
	if !strings.Contains(logs.String(), "reason=messages_off") {
		t.Fatalf("skip not logged: %s", logs.String())
	}
	p.WakeCall(ctx, []byte("bob"), 1)
	p.Wait()
	if len(s.sent) != 1 || s.sent[0] != "tok-b" {
		t.Fatalf("call push to a calls-only device: %v", s.sent)
	}
}
```

- [ ] **Step 4: Run** `go test ./internal/records/ ./internal/store/ ./internal/push/` → FAIL (`PushTarget`
  undefined, withdrawn rejected).

- [ ] **Step 5: Implement.**

`internal/store/migrations/0010_push_switches.sql`:

```sql
-- M9.1 push switches (D94): a device may ask for call pushes only. A withdrawn device keeps its row with token ''.
ALTER TABLE push_tokens ADD COLUMN messages_off INTEGER NOT NULL DEFAULT 0;
```

`internal/records/validate.go`:

```go
// checkPushToken: device 1, kind FCM; a 1..MaxPushToken-byte UTF-8 token, or withdrawn with no token (D60, D94).
func checkPushToken(b *pb.RecordBody) error {
	var p pb.PushToken
	if err := proto.Unmarshal(b.Payload, &p); err != nil || p.DeviceId != 1 || p.Kind != pb.PushToken_FCM {
		return ErrBadPayload
	}
	if p.Withdrawn {
		if p.Token != "" || p.MessagesOff {
			return ErrBadPayload
		}
		return nil
	}
	if len(p.Token) == 0 || len(p.Token) > MaxPushToken || !utf8.ValidString(p.Token) {
		return ErrBadPayload
	}
	return nil
}
```

`internal/store/typed.go`, the `INSERT` of the `PUSH_TOKEN` case (the ordering check above it stays):

```go
		// A withdrawn record (D94) has an empty token: the row keeps created_ms/record_key so an older token record
		// replicated later loses the ordering check above and cannot bring the token back.
		_, err = tx.ExecContext(ctx,
			`INSERT INTO push_tokens(user_id,device_id,kind,token,created_ms,record_key,messages_off) VALUES(?,?,?,?,?,?,?)
			 ON CONFLICT(user_id,device_id) DO UPDATE SET kind=excluded.kind, token=excluded.token,
			   created_ms=excluded.created_ms, record_key=excluded.record_key, messages_off=excluded.messages_off`,
			b.Author, p.DeviceId, int32(p.Kind), p.Token, b.CreatedMs, it.key, p.MessagesOff)
		return err
```

`internal/store/push.go`, add:

```go
// PushTarget returns the device's push token ("" = none or withdrawn) and whether it wants call pushes only (D94).
func (s *Store) PushTarget(ctx context.Context, user []byte, device uint32) (string, bool, error) {
	var tok string
	var off bool
	err := s.r.QueryRowContext(ctx, `SELECT token, messages_off FROM push_tokens WHERE user_id=? AND device_id=?`,
		user, device).Scan(&tok, &off)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	return tok, off, err
}
```

`internal/store/news.go` `PushTargets`: `SELECT user_id, device_id FROM push_tokens WHERE token != '' ORDER BY user_id, device_id`.

`internal/push/pusher.go`:

```go
// Tokens is the store side (internal/store implements it).
type Tokens interface {
	// PushTarget: the device's token ("" = none or withdrawn) and whether it wants call pushes only (D94).
	PushTarget(ctx context.Context, user []byte, device uint32) (token string, messagesOff bool, err error)
	DropPushToken(ctx context.Context, user []byte, device uint32, token string) error
}
```

and in `wake`'s goroutine replace the token lookup:

```go
		tok, off, err := p.tokens.PushTarget(ctx, user, device)
		if err != nil || tok == "" {
			return
		}
		if off && !call { // notifications off on the phone: calls still ring (D94)
			p.log.Info("push skipped", "user", tag, "device", device, "kind", kind, "reason", "messages_off")
			return
		}
```

(`service.PushStatus` keeps `Store.PushToken`: a withdrawn device reports `has_push = false`, a calls-only one
`true`, which is what the caller's ringing warning needs.)

- [ ] **Step 6: Run** the Verify command → all `ok`, `diff` empty. Also `go vet ./...` → no output.

- [ ] **Step 7: Commit** (two repos):

```bash
cd ~/Documents/Projects/OttterMSG/otter-server
git add proto/otter/v1/records.proto internal/proto/otterv1/ internal/store/migrations/0010_push_switches.sql \
  internal/records/ internal/store/typed.go internal/store/push.go internal/store/news.go internal/store/push_test.go internal/push/
oc -m "push: PushToken messages_off (calls only) and withdrawn (token erased) (M9.1 push switches)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
cd ../otter-android
git add core/proto/src/main/proto/otter/v1/records.proto
oc -m "proto: PushToken messages_off and withdrawn (sync from otter-server)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 21: Server — one `envelopes` event stays under 768 KiB

**Goal:** Every frame a node sends a phone is far below the phone's 4 MiB limit, so Task 24 never cuts an honest node.

**Findings closed:** C17 (server half: makes the client frame limit safe for legitimate traffic)

**Files:**
- Modify: `otter-server/internal/gateway/gateway.go:19-24` (constant), `internal/gateway/session.go:155-199` (`deliverLoop`)
- Test: `otter-server/internal/gateway/batch_test.go` (new)

**Acceptance Criteria:**
- [ ] 8 queued envelopes of 250 KiB each arrive in several `envelopes` events, each event body ≤ 768 KiB + one record;
  all 8 arrive, in order.
- [ ] A single record larger than the budget is still delivered (alone).
- [ ] Existing gateway tests still pass (100-record batches for small envelopes unchanged).

**Verify:** `cd otter-server && go test -race -count=1 ./internal/gateway/` → `ok`

**Steps:**

- [ ] **Step 1: Failing test** — create `internal/gateway/batch_test.go`:

```go
package gateway

import (
	"bytes"
	"testing"

	"google.golang.org/protobuf/proto"
	pb "ottermsg/server/internal/proto/otterv1"
)

// TestEnvelopeBatchesStayUnderTheByteBudget: queued big envelopes reach the phone in several events, none bigger
// than deliverBatchBytes plus one record (M9.1, D93), so a phone's 4 MiB frame limit never cuts an honest node.
func TestEnvelopeBatchesStayUnderTheByteBudget(t *testing.T) {
	n := startNode(t)
	anna, ca := newTestUser(t, n, "anna") // stays logged out while boris sends
	boris, cb := newTestUser(t, n, "boris")
	login(t, cb, boris)
	var sent [][]byte
	for i := 0; i < 8; i++ {
		env := sign(t, pb.RecordType_ENVELOPE, boris.id, &pb.Envelope{SenderUser: boris.id, SenderDevice: 1, Kind: pb.Envelope_SIGNAL,
			Recipients: []*pb.Recipient{{User: anna.id, Device: 1, Content: bytes.Repeat([]byte{byte(i)}, 250<<10)}}}, boris.priv)
		if st, msg := cb.call("msg.send", &pb.RecordRequest{Record: env}, nil); st != pb.Status_STATUS_OK {
			t.Fatalf("send %d: %v %s", i, st, msg)
		}
		sent = append(sent, env.Body)
	}
	login(t, ca, anna)
	var got [][]byte
	events := 0
	for len(got) < len(sent) {
		e := ca.nextEvent("envelopes")
		events++
		if len(e.Body) > deliverBatchBytes+(300<<10) {
			t.Fatalf("event %d is %d bytes", events, len(e.Body))
		}
		var b pb.RecordBatch
		if err := proto.Unmarshal(e.Body, &b); err != nil {
			t.Fatal(err)
		}
		for _, r := range b.Records {
			got = append(got, r.Body)
		}
	}
	if events < 3 {
		t.Fatalf("8 × 250 KiB came in %d events", events)
	}
	for i := range sent {
		if !bytes.Equal(sent[i], got[i]) {
			t.Fatalf("envelope %d out of order", i)
		}
	}
}
```

- [ ] **Step 2: Run** `go test ./internal/gateway/ -run TestEnvelopeBatches` → FAIL (`deliverBatchBytes` undefined;
  with the constant only, the 2 MB event exceeds the test client's 1 MiB read limit and `nextEvent` fails).

- [ ] **Step 3: Implement.** `gateway.go` constants:

```go
	deliverBatch      = 100
	deliverBatchBytes = 768 << 10 // one envelopes event; phones refuse frames over 4 MiB (D93)
```

`session.go` `deliverLoop`, the inner batch building:

```go
			next := make(map[string]bool, len(entries))
			batch := &pb.RecordBatch{}
			size, full := 0, false
			for _, e := range entries {
				k := string(e.Key)
				next[k] = true
				if sent[k] || full {
					continue
				}
				if len(batch.Records) >= deliverBatch || (len(batch.Records) > 0 && size+len(e.Raw) > deliverBatchBytes) {
					full = true // the rest goes in the next event
					continue
				}
				r := &pb.Record{}
				if proto.Unmarshal(e.Raw, r) == nil {
					batch.Records = append(batch.Records, r)
					size += len(e.Raw)
				}
				sent[k] = true
			}
```

and replace `if len(batch.Records) < deliverBatch { break }` by `if !full { break }`.

- [ ] **Step 4: Run** the Verify command → `ok`.

- [ ] **Step 5: Commit**

```bash
cd ~/Documents/Projects/OttterMSG/otter-server
git add internal/gateway/gateway.go internal/gateway/session.go internal/gateway/batch_test.go
oc -m "gateway: one envelopes event carries at most 768 KiB (C17)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 22: Android — envelopes are marked seen only after verification, together with the message

**Goal:** A forged copy of an envelope can neither hide the real one on this phone nor delete it from the network.

**Findings closed:** C15

**Files:**
- Modify: `otter-android/core/database/src/main/kotlin/app/ottermsg/core/database/dao/SeenEnvelopeDao.kt` (add `exists`)
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/messaging/MailboxReceiver.kt:51-125`
- Test: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/ForgedEnvelopeTest.kt` (new),
  `core/database/src/test/kotlin/app/ottermsg/core/database/MessagingDaoTest.kt` (existing seen test, add `exists`)

**Acceptance Criteria:**
- [ ] Hostile node: a copy of B's envelope with the same author‖id but a signature by another key is handed to A
  first: A sends **no ACK** (the real envelope is still in the node's mailbox), shows nothing, and when the real
  envelope arrives A shows it.
- [ ] A body-altered copy (different payload, same author‖id, re-signed by an attacker) behaves the same.
- [ ] Redelivery of an already processed envelope is acked without a duplicate or an «не удалось прочитать» line
  (existing `offlineRecipientGetsAllInOrder` stays green).
- [ ] The seen row is inserted inside the `db.withTransaction` that stores the message.

**Verify:** `cd otter-android && ./gradlew :core:database:testDebugUnitTest :core:data:testDebugUnitTest --tests '*ForgedEnvelopeTest*' --tests '*MessagingFlowTest*' --tests '*GroupFlowTest*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing test** — create `core/data/src/test/kotlin/app/ottermsg/core/data/ForgedEnvelopeTest.kt`:

```kotlin
package app.ottermsg.core.data

import app.ottermsg.core.crypto.Ed25519
import app.ottermsg.core.crypto.RecordCodec
import app.ottermsg.core.database.entity.MessageEntity
import app.ottermsg.proto.v1.Envelope
import app.ottermsg.proto.v1.RecordBody
import com.google.protobuf.ByteString
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** C15: a hostile node serves a forged copy of an envelope (same author‖id) before the real one. */
@RunWith(RobolectricTestRunner::class)
class ForgedEnvelopeTest {
    private val clock = TestClock()
    private val node = FakeNode(clock::now)
    private val a = TestGraph(node, clock)
    private val b = TestGraph(node, clock)
    private val attacker = Ed25519.keyPairFromSeed(ByteArray(32) { 7 })

    @After fun tearDown() { a.close(); b.close() }

    private suspend fun TestGraph.thread(peer: TestGraph): List<MessageEntity> =
        messages.observeMessages(messages.conversationWith(peer.me.userId)).first()

    /** A and B know each other; A is offline; B's "настоящее" waits on the node. Returns the real record. */
    private suspend fun realEnvelopeWaiting(): app.ottermsg.proto.v1.Record {
        a.register(node.bootstrapLink(), "Мама", "mama").getOrThrow(); a.online()
        b.register(a.invites.create().link, "Боря", "borya").getOrThrow(); b.online()
        eventually(what = "A sees B") { a.db.contactDao().get(b.me.userId)?.entryVersion ?: 0 > 0 }
        a.offline()
        b.messages.sendText(b.messages.conversationWith(a.me.userId), "настоящее")
        eventually(what = "node holds it for A") { node.mailbox(a.me.userId).size == 1 }
        return node.mailbox(a.me.userId).single()
    }

    private suspend fun handOver(forged: app.ottermsg.proto.v1.Record) {
        val s = node.connect().also { it.login(a.me.userId, a.me.accountKey) }
        a.receiver.handle(s, listOf(forged))
        s.close()
        assertEquals("a forged copy must not be acknowledged", 1, node.mailbox(a.me.userId).size)
        assertTrue(a.thread(b).isEmpty())
        a.online()
        eventually(what = "the real message is shown") { a.thread(b).any { it.body == "настоящее" } }
    }

    @Test fun copySignedByAnotherKey() = runBlocking {
        val real = realEnvelopeWaiting()
        handOver(RecordCodec.sign(RecordBody.parseFrom(real.body), attacker))
    }

    @Test fun alteredBodyWithTheSameId() = runBlocking {
        val real = realEnvelopeWaiting()
        val body = RecordBody.parseFrom(real.body)
        val env = Envelope.parseFrom(body.payload).toBuilder().apply {
            setRecipients(0, getRecipients(0).toBuilder().setContent(ByteString.copyFrom(ByteArray(64) { 1 })))
        }.build()
        handOver(RecordCodec.sign(body.toBuilder().setPayload(env.toByteString()).build(), attacker))
    }
}
```

In `MessagingDaoTest` (seen-envelope test, after the first insert) add `assertTrue(s.exists(key))` and before it on a
fresh key `assertFalse(s.exists(ByteArray(32) { 9 }))`.

- [ ] **Step 2: Run** `./gradlew :core:data:testDebugUnitTest --tests '*ForgedEnvelopeTest*'` → FAIL
  ("a forged copy must not be acknowledged": expected 1, was 0).

- [ ] **Step 3: DAO** — `SeenEnvelopeDao`:

```kotlin
    @Query("SELECT EXISTS(SELECT 1 FROM seen_envelopes WHERE record_key = :k)") suspend fun exists(k: ByteArray): Boolean
```

- [ ] **Step 4: Receiver.** In `MailboxReceiver.handle`, replace the loop body from `val key = …` up to the
  `db.withTransaction {` line, and the first line inside it (imports: `org.signal.libsignal.protocol.DuplicateMessageException`,
  `java.util.logging.Logger`):

```kotlin
            val key = body.author.toByteArray() + body.id.toByteArray()
            // Only verified, processed envelopes are ever in `seen` (C15): a hit is a redelivery we already handled.
            if (seen.exists(key)) { acks += key; continue }
            var sender = contacts.get(body.author.toByteArray())
            if (sender == null && !directorySynced) {
                directorySynced = true
                runCatching { directory.sync(api) }.onFailure { if (it is CancellationException) throw it }
                sender = contacts.get(body.author.toByteArray())
            }
            if (sender == null) continue // keep it on the node; retry on a later delivery
            if (!RecordCodec.verify(rec, sender.accountPub)) {
                // A forged copy: not seen, not acked. An ACK would tombstone the real envelope on every node.
                log.warning("envelope ${key.toHex()} fails its signature: ignored")
                continue
            }
            val env = runCatching { Envelope.parseFrom(body.payload) }.getOrNull()
            val mine = env?.recipientsList?.firstOrNull { it.user.toByteArray().contentEquals(me.userId) && it.device == 1 }
            if (env == null || mine == null) { markSeen(key); acks += key; continue }
            if (env.kind == Envelope.Kind.SENDER_KEY) {
                groups.onEnvelope(sender.userId, key, rec, body, env) // shown, parked or dropped: the node copy is not needed
                markSeen(key); acks += key
                continue
            }
            var duplicate = false
            val plain = try {
                signal.withSessions { _, s -> s.decrypt(s.address(sender.userId), env.kind, mine.content.toByteArray()) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: DuplicateMessageException) {
                duplicate = true; null // decrypted before, the commit was cut (process death): nothing new to show
            } catch (e: Exception) {
                null
            }
            if (duplicate) { markSeen(key); acks += key; continue }
            val content = plain?.let { runCatching { Content.parseFrom(it) }.getOrNull() }
            // Group control content touches libsignal state and may sync the directory; call content drives the call
            // layer (D78): outside any DB transaction, marked seen right after. Call content never creates a chat.
            when (content?.bodyCase) {
                Content.BodyCase.CALL -> {
                    calls.onCallMessage(sender.userId, sender.displayName, content.call, body.createdMs)
                    markSeen(key); acks += key; continue
                }
                Content.BodyCase.RECEIPT -> if (calls.isCallReceipt(content.receipt)) {
                    calls.onCallReceipt(sender.userId, content.receipt); markSeen(key); acks += key; continue
                }
                Content.BodyCase.GROUP_UPDATE -> {
                    groups.onGroupUpdate(sender.userId, content.groupUpdate.state, api); markSeen(key); acks += key; continue
                }
                Content.BodyCase.SENDER_KEY -> { groups.onSenderKey(sender.userId, content.senderKey); markSeen(key); acks += key; continue }
                Content.BodyCase.SESSION_RESET -> { resets.onReceived(sender.userId); markSeen(key); acks += key; continue }
                else -> {}
            }
            val shown = db.withTransaction {
                seen.insert(SeenEnvelopeEntity(key, clock.now() + SEEN_TTL_MS)) // C15: seen commits with the message
```

Add to the class:

```kotlin
    private suspend fun markSeen(key: ByteArray) { seen.insert(SeenEnvelopeEntity(key, clock.now() + SEEN_TTL_MS)) }
    private fun ByteArray.toHex() = joinToString("") { "%02x".format(it) }
```

and in the companion `private val log: Logger = Logger.getLogger("MailboxReceiver")`. Remove the old
`seen.delete(key)` line (nothing is inserted before the lookup any more).

- [ ] **Step 5: Run** the Verify command → `BUILD SUCCESSFUL`.

- [ ] **Step 6: Commit**

```bash
cd ~/Documents/Projects/OttterMSG/otter-android
git add core/database/src/main/kotlin/app/ottermsg/core/database/dao/SeenEnvelopeDao.kt core/database/src/test/ \
  core/data/src/main/kotlin/app/ottermsg/core/data/messaging/MailboxReceiver.kt core/data/src/test/kotlin/app/ottermsg/core/data/ForgedEnvelopeTest.kt
oc -m "receiver: mark envelopes seen only after verification, with the message; never ack a forged copy (C15)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 23: Android — manifest fallback only for nodes and pins the newest manifest keeps

**Goal:** When the admin removes a node or withdraws a pin, the phone stops using it immediately.

**Findings closed:** C16

**Files:**
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/sync/ManifestUpdater.kt:55-70`
- Test: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/ManifestUpdaterTest.kt:37-47` (replace
  `previousEndpointsAreAFallbackForSevenDays`)

**Acceptance Criteria:**
- [ ] Manifest v2 lists node A (host `a1`, pin P) and node B (host `b1`, pin Q); v3 lists only A at host `a2` with
  pin P → candidates `a2` then `a1` (fallback, lower priority); nothing for B.
- [ ] v4 lists A at `a3` with pin R only (P withdrawn) → candidates `a3` only.
- [ ] A removed node (v2 without the bootstrap node) is not a candidate at all; after 7 days only the newest
  manifest's endpoints remain (as before).

**Verify:** `cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*ManifestUpdaterTest*' --tests '*SyncEngineManifestTest*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing test** — in `ManifestUpdaterTest` replace `previousEndpointsAreAFallbackForSevenDays` by:

```kotlin
    private fun nodeInfo(id: Int, label: String, host: String, pin: ByteArray): NodeInfo =
        NodeInfo.newBuilder().setNodeId(bs(ByteArray(16) { id.toByte() })).setLabel(label)
            .addEndpoints(Endpoint.newBuilder().setKind(Endpoint.Kind.WSS).setHost(host).setPort(443).setPath("/p")
                .addTlsSpkiPins(bs(pin))).build()

    private fun manifest(version: Long, vararg nodes: NodeInfo): ByteArray {
        val m = Manifest.newBuilder().setVersion(version).setIssuedMs(version).setNetworkPub(bs(node.network.publicKey))
            .addAllNodes(nodes.toList()).build()
        return RecordCodec.sign(RecordCodec.body(RecordType.MANIFEST, Ids.id16(node.network.publicKey), m.toByteArray(),
            createdMs = version), node.network).toByteArray()
    }

    private suspend fun hosts() = m.candidates(allowPlaintext = false).map { it.host }

    @Test fun fallbackOnlyForNodesAndPinsTheNewestManifestKeeps() = runBlocking {
        g.register(node.bootstrapLink(), "Мама", "mama").getOrThrow()
        val p = ByteArray(32) { 1 }; val q = ByteArray(32) { 2 }; val r = ByteArray(32) { 3 }
        m.offer(manifest(2, nodeInfo(1, "a", "a1", p), nodeInfo(2, "b", "b1", q)), null)
        m.offer(manifest(3, nodeInfo(1, "a", "a2", p)), null)            // A moved, B removed
        val c = m.candidates(false)
        assertEquals(listOf("a2", "a1"), c.map { it.host })               // B's b1 is gone at once
        assertTrue(c[1].priority >= ManifestUpdater.FALLBACK_PRIORITY)
        m.offer(manifest(4, nodeInfo(1, "a", "a3", r)), null)            // pin P withdrawn
        assertEquals(listOf("a3"), hosts())
    }

    @Test fun removedNodeIsDroppedAtOnceAndFallbackEndsAfterSevenDays() = runBlocking {
        g.register(node.bootstrapLink(), "Мама", "mama").getOrThrow() // v1: fake
        m.offer(node.signManifest(2, withSelf = false, extraHosts = listOf("b", "c")).toByteArray(), null)
        assertEquals(listOf("b", "c"), m.candidates(true).map { it.label }) // "fake" was removed: no fallback
        val p = ByteArray(32) { 1 }
        m.offer(manifest(3, nodeInfo(1, "b", "b2", p)), null)
        m.offer(manifest(4, nodeInfo(1, "b", "b3", p)), null)
        assertEquals(listOf("b3", "b2"), hosts())
        clock.advance(ManifestUpdater.FALLBACK_MS)
        assertEquals(listOf("b3"), hosts())
    }
```

Imports: `app.ottermsg.core.crypto.Ids`, `app.ottermsg.core.crypto.RecordCodec`, `app.ottermsg.proto.v1.Endpoint`,
`app.ottermsg.proto.v1.Manifest`, `app.ottermsg.proto.v1.NodeInfo`, `app.ottermsg.proto.v1.RecordType`.
(`FakeNode.signManifest` gives extra nodes ids `1, 2, …`, so node "b" of v2 has id 1, the same as `nodeInfo(1, …)`.)

- [ ] **Step 2: Run** → FAIL (`[b, c, fake]` and `[a2, a1, b1]`).

- [ ] **Step 3: Implement** `candidates`:

```kotlin
    /**
     * Latest manifest's endpoints, plus — for [FALLBACK_MS] after an update — the previous manifest's endpoints that are
     * not in the latest one, at lower priority, but only for a node the latest manifest still lists and only with pins
     * it still gives that node (C16): a removed node or a withdrawn pin stops working at once.
     */
    suspend fun candidates(allowPlaintext: Boolean): List<Candidate> {
        val two = manifests.latestTwo()
        val latest = two.firstOrNull() ?: return emptyList()
        val networkPub = settings.networkPub()
        val newest = parse(latest.raw, networkPub) ?: return emptyList()
        val current = Endpoints.candidates(newest, allowPlaintext)
        val previous = two.getOrNull(1) ?: return current
        if (clock.now() - latest.receivedMs >= FALLBACK_MS) return current
        val old = parse(previous.raw, networkPub) ?: return current
        val pinsByNode: Map<String, Set<String>> = newest.nodesList.associate { n ->
            n.nodeId.toByteArray().hex() to n.endpointsList.flatMap { e -> e.tlsSpkiPinsList.map { it.toByteArray().hex() } }.toSet()
        }
        val known = current.map { it.key }.toSet()
        val fallback = Endpoints.candidates(old, allowPlaintext, priorityOffset = FALLBACK_PRIORITY).filter { c ->
            val allowed = pinsByNode[c.nodeId.hex()] ?: return@filter false
            c.key !in known && c.pins.all { it.hex() in allowed }
        }
        return current + fallback
    }

    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }
```

- [ ] **Step 4: Run** the Verify command → `BUILD SUCCESSFUL`.

- [ ] **Step 5: Commit**

```bash
git add core/data/src/main/kotlin/app/ottermsg/core/data/sync/ManifestUpdater.kt core/data/src/test/kotlin/app/ottermsg/core/data/ManifestUpdaterTest.kt
oc -m "manifest: fall back only to nodes and pins the newest manifest still authorizes (C16)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 24: Android — receive limits: frames, queued events, blob and APK chunks, no WebSocket compression

**Goal:** A node can refuse service but cannot make the phone buffer or write unbounded data; breaking a limit costs
it the connection and the phone moves on at once.

**Findings closed:** C17

**Files:**
- Create: `otter-android/core/network/src/main/kotlin/app/ottermsg/core/network/ReceiveLimits.kt`
- Modify: `core/network/.../RpcClient.kt:26-66` (frame check, event budget, `abort`), `NodeApi.kt:106-121`
  (`RemoteNodeApi.blobGet`, `apkGet`), `ConnectionManager.kt:96-114` (oversize ending), `OkHttpTransport.kt:18-56`
  (`NoCompression` interceptor)
- Modify: `core/data/.../media/MediaTransfers.kt:136-150` (exact chunk size), `core/data/.../news/ApkUpdater.kt:38-66`
- Test: `core/network/src/test/.../RpcClientTest.kt`, `NodeApiCallsTest.kt`, `ConnectionManagerTest.kt`,
  `NoCompressionTest.kt` (new); `core/data/src/test/.../news/ApkUpdaterTest.kt`; `core/data/src/test/.../PhotoFlowTest.kt`

**Acceptance Criteria:**
- [ ] A frame over 4 MiB ends the connection with `OversizeFrame`; more than 16 MiB of unhandled events too.
- [ ] `blob.get` returning more than 256 KiB, or `apk.get` more than 1 MiB, throws `OversizeFrame` and closes the
  connection.
- [ ] `ConnectionManager`: a session that ends with `OversizeFrame` records a failure for that endpoint, logs
  `limit: …`, and the next candidate is raced **without** a backoff wait.
- [ ] Media download refuses a chunk whose size is not `min(256 KiB, size − idx·256 KiB)` (nothing appended, retried
  later). APK: `AppUpdate.size` ≤ 0 or > 100 MiB → `Corrupt` without a request; a chunk of the wrong size → `.part`
  deleted, `Corrupt`.
- [ ] The WebSocket upgrade request carries no `Sec-WebSocket-Extensions`; a node that answers with one is refused
  (`ProtocolException`).
- [ ] Every existing `core:network` and `core:data` test stays green.

**Verify:** `cd otter-android && ./gradlew :core:network:test :core:data:testDebugUnitTest --tests '*ApkUpdaterTest*' --tests '*PhotoFlowTest*' --tests '*LiveBlobTest*'` → `BUILD SUCCESSFUL` (Live* tests skip without a dev mesh, as today)

**Steps:**

- [ ] **Step 1: Limits** — create `ReceiveLimits.kt`:

```kotlin
package app.ottermsg.core.network

import java.io.IOException

/**
 * What a node may send before the phone drops it (C17, D93). Legitimate maxima: `apk.get` = 1 MiB + header;
 * `envelopes` ≤ 768 KiB + one record (server 0.9.0); `blob.get` = 256 KiB.
 */
object ReceiveLimits {
    const val MAX_FRAME = 4 shl 20
    const val MAX_QUEUED_EVENT_BYTES = 16L shl 20
    const val BLOB_CHUNK = 256 * 1024 // == BlobCipher.CHUNK: one slice of the ciphertext file
    const val APK_CHUNK = 1 shl 20
    const val APK_MAX = 100L shl 20
}

/** A node broke a receive limit; the connection is dropped and the other nodes are tried. */
class OversizeFrame(what: String, size: Long, limit: Long) : IOException("$what: $size bytes > $limit")

/** The [OversizeFrame] anywhere in this cause chain, if any. */
fun Throwable?.oversize(): OversizeFrame? = generateSequence(this) { it.cause }.filterIsInstance<OversizeFrame>().firstOrNull()
```

- [ ] **Step 2: Failing tests (network).** `RpcClientTest`, append (imports `com.google.protobuf.ByteString`,
  `org.junit.Assert.assertTrue`):

```kotlin
    @Test fun frameOverTheLimitClosesTheConnection() = runTest {
        val conn = FakeTransport { ok() }.connect(cand("x")) as FakeTransport.FakeConnection
        val rpc = RpcClient(conn, backgroundScope)
        rpc.hello.await()
        conn.incoming.trySend(ByteArray(ReceiveLimits.MAX_FRAME + 1))
        assertTrue(rpc.closed.await() is OversizeFrame)
    }

    @Test fun unhandledEventsAreBounded() = runTest {
        val conn = FakeTransport { ok() }.connect(cand("x")) as FakeTransport.FakeConnection
        val rpc = RpcClient(conn, backgroundScope)
        rpc.hello.await()
        val big = Event.newBuilder().setType("envelopes").setBody(ByteString.copyFrom(ByteArray(1 shl 20))).build()
        repeat(17) { conn.push(Frame.newBuilder().setEvent(big).build()) } // nobody collects
        assertTrue(rpc.closed.await() is OversizeFrame)
    }
```

`NodeApiCallsTest`, append (imports `app.ottermsg.proto.v1.BlobChunk`, `app.ottermsg.proto.v1.ApkChunk`,
`com.google.protobuf.ByteString`):

```kotlin
    private suspend fun apiAnswering(method: String, body: ByteString, scope: kotlinx.coroutines.CoroutineScope):
        Pair<RemoteNodeApi, FakeTransport.FakeConnection> {
        val conn = FakeTransport { r -> if (r.method == method) ok(body) else ok() }.connect(cand("x")) as FakeTransport.FakeConnection
        val rpc = RpcClient(conn, scope).also { it.hello.await() }
        return RemoteNodeApi(rpc) to conn
    }

    @Test fun oversizeBlobChunkDropsTheConnection() = runTest {
        val body = BlobChunk.newBuilder().setData(ByteString.copyFrom(ByteArray(ReceiveLimits.BLOB_CHUNK + 1))).build().toByteString()
        val (api, conn) = apiAnswering("blob.get", body, backgroundScope)
        assertTrue(runCatching { api.blobGet(ByteArray(32), 0) }.exceptionOrNull() is OversizeFrame)
        assertTrue(conn.closed)
    }

    @Test fun oversizeApkChunkDropsTheConnection() = runTest {
        val body = ApkChunk.newBuilder().setData(ByteString.copyFrom(ByteArray(ReceiveLimits.APK_CHUNK + 1))).build().toByteString()
        val (api, conn) = apiAnswering("apk.get", body, backgroundScope)
        assertTrue(runCatching { api.apkGet(ByteArray(32), 0) }.exceptionOrNull() is OversizeFrame)
        assertTrue(conn.closed)
    }
```

`ConnectionManagerTest`, append (import `kotlinx.coroutines.withTimeout`):

```kotlin
    @Test fun oversizeFrameDropsTheNodeAndTriesTheNextAtOnce() = runTest {
        val t = FakeTransport(delays = mapOf("good" to 500)) { ok() }
        val stats = InMemoryEndpointStats()
        val log = RecordingNetLog()
        val cm = manager(t, listOf(cand("hostile"), cand("good")), backgroundScope, { currentTime }, stats, log)
        cm.start()
        assertEquals("hostile", (cm.state.first { it is ConnectionState.Online } as ConnectionState.Online).url)
        val t0 = currentTime
        t.byUrl["hostile"]!!.last().incoming.trySend(ByteArray(ReceiveLimits.MAX_FRAME + 1))
        withTimeout(10_000) { cm.state.first { it is ConnectionState.Online && it.url == "good" } }
        assertTrue("no backoff wait", currentTime - t0 < 1_000)
        assertEquals(1, stats.get("hostile")!!.failures)
        assertTrue(log.entries.any { it.endpoint == "hostile" && it.detail.startsWith("limit:") })
        cm.stop()
    }
```

Create `core/network/src/test/kotlin/app/ottermsg/core/network/NoCompressionTest.kt` (confirm the mockwebserver3
names with `javap -cp <mockwebserver3 jar> mockwebserver3.MockResponse\$Builder | grep -i websocket` first):

```kotlin
package app.ottermsg.core.network

import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.junit.After
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.ProtocolException

/** D93: the phone never negotiates permessage-deflate, so a node cannot send a decompression bomb. */
class NoCompressionTest {
    private val server = MockWebServer()
    private val quiet = object : WebSocketListener() {}
    @Before fun setUp() = server.start()
    @After fun tearDown() = server.close()
    private fun candidate() = Candidate(ByteArray(16), "n", server.url("/ws").toString().replaceFirst("http", "ws"), "localhost", emptyList(), 0)

    @Test fun neverOffersCompression() = runBlocking {
        server.enqueue(MockResponse.Builder().webSocketUpgrade(quiet).build())
        val c = OkHttpTransport().connect(candidate())
        assertNull(server.takeRequest().headers["Sec-WebSocket-Extensions"])
        c.close()
    }

    @Test fun refusesANodeThatTurnsCompressionOn() = runBlocking {
        server.enqueue(MockResponse.Builder().webSocketUpgrade(quiet).addHeader("Sec-WebSocket-Extensions", "permessage-deflate").build())
        val e = runCatching { OkHttpTransport().connect(candidate()) }.exceptionOrNull()
        assertTrue("$e", e.oversize() == null && generateSequence(e) { it.cause }.any { it is ProtocolException })
    }
}
```

- [ ] **Step 3: Run** `./gradlew :core:network:test` → FAIL (`ReceiveLimits` is new but nothing enforces it:
  `closed` never completes / completes with a parse error, `blobGet` returns, the manager waits a backoff, the request
  carries `permessage-deflate`).

- [ ] **Step 4: Implement `RpcClient`** (imports `kotlinx.coroutines.flow.onEach`):

```kotlin
    private val _events = Channel<Event>(Channel.UNLIMITED)
    /** Bytes of events received but not yet collected (C17): bounded by [ReceiveLimits.MAX_QUEUED_EVENT_BYTES]. */
    private val queuedEventBytes = AtomicLong()
    val events: Flow<Event> = _events.receiveAsFlow().onEach { queuedEventBytes.addAndGet(-it.serializedSize.toLong()) }
    @Volatile private var abortCause: OversizeFrame? = null

    private val reader = scope.launch {
        var cause: Throwable? = null
        try {
            for (bytes in conn.incoming) {
                if (bytes.size > ReceiveLimits.MAX_FRAME) throw OversizeFrame("frame", bytes.size.toLong(), ReceiveLimits.MAX_FRAME.toLong())
                val f = Frame.parseFrom(bytes)
                when (f.kindCase) {
                    Frame.KindCase.RESPONSE -> pending.remove(f.response.id)?.complete(f.response)
                    Frame.KindCase.EVENT -> if (f.event.type == "hello") hello.complete(Hello.parseFrom(f.event.body)) else {
                        val queued = queuedEventBytes.addAndGet(f.event.serializedSize.toLong())
                        if (queued > ReceiveLimits.MAX_QUEUED_EVENT_BYTES) throw OversizeFrame("queued events", queued, ReceiveLimits.MAX_QUEUED_EVENT_BYTES)
                        _events.trySend(f.event)
                    }
                    else -> {}
                }
            }
        } catch (e: Throwable) {
            cause = e
        } finally {
            val end = abortCause ?: cause
            val err = IOException("connection closed", end)
            pending.values.forEach { it.completeExceptionally(err) }
            pending.clear()
            hello.completeExceptionally(err)
            _events.close()
            if (end is OversizeFrame) conn.close()
            closed.complete(end)
        }
    }

    /** Drops the connection because the node broke a limit seen above the frame level (a chunk size); returns [e]. */
    fun abort(e: OversizeFrame): OversizeFrame {
        abortCause = e
        conn.close()
        reader.cancel()
        return e
    }
```

- [ ] **Step 5: `RemoteNodeApi`:**

```kotlin
    override suspend fun blobGet(key: ByteArray, index: Int): ByteArray {
        val data = BlobChunk.parseFrom(rpc.call("blob.get", BlobGetRequest.newBuilder().setBlobKey(ByteString.copyFrom(key)).setIndex(index).build())).data
        if (data.size() > ReceiveLimits.BLOB_CHUNK) throw rpc.abort(OversizeFrame("blob chunk", data.size().toLong(), ReceiveLimits.BLOB_CHUNK.toLong()))
        return data.toByteArray()
    }
    override suspend fun apkGet(sha256: ByteArray, index: Int): ApkChunk {
        val c = ApkChunk.parseFrom(rpc.call("apk.get", ApkGetRequest.newBuilder().setSha256(ByteString.copyFrom(sha256)).setIndex(index).build()))
        if (c.data.size() > ReceiveLimits.APK_CHUNK) throw rpc.abort(OversizeFrame("apk chunk", c.data.size().toLong(), ReceiveLimits.APK_CHUNK.toLong()))
        return c
    }
```

- [ ] **Step 6: `ConnectionManager.loop`** — right after `val cause = w.rpc.closed.await()`:

```kotlin
                    val lived = clock() - connectedAt
                    val over = cause.oversize()
                    if (over != null) {
                        // The node broke a receive limit (C17): count it as a failure and race the others now.
                        stats.failure(w.candidate.key, clock())
                        netLog.add(NetLogEntry(w.candidate.label, w.candidate.logName(), FailureClass.RESET, "limit: ${over.message}"))
                        lastError = "node broke a size limit"
                        remaining = remaining.filter { it.key != w.candidate.key }
                    } else {
                        // Our own close (stop, reconnect, network change) ends the reader by cancellation: not the censor.
                        if (cause != null && cause !is CancellationException && lived < THROTTLE_WINDOW_MS && w.rpc.bytesIn >= THROTTLE_BYTES) {
                            stats.throttled(w.candidate.key, clock())
                            netLog.add(NetLogEntry(w.candidate.label, w.candidate.logName(), FailureClass.RESET_AFTER_KB,
                                "${w.rpc.bytesIn} bytes in ${lived / 1000} s: ${cause.message}"))
                        }
                        lastError = "connection lost"
                        remaining = emptyList() // session ended: race all again (after a short wait unless reconnect())
                    }
```

- [ ] **Step 7: `OkHttpTransport`** — no WebSocket compression (application interceptor: OkHttp skips network
  interceptors for web sockets):

```kotlin
    companion object {
        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS).pingInterval(60, TimeUnit.SECONDS)
            .addInterceptor(NoCompression).build()
    }

    /**
     * OkHttp offers permessage-deflate on every web socket; a node that accepted it could inflate a few KB into
     * gigabytes before the app sees the message (C17, D93). Nodes never compress, so the offer is removed and an
     * answer that enables it is refused.
     */
    internal object NoCompression : Interceptor {
        override fun intercept(chain: Interceptor.Chain): Response {
            val res = chain.proceed(chain.request().newBuilder().removeHeader("Sec-WebSocket-Extensions").build())
            if (res.header("Sec-WebSocket-Extensions") != null) {
                res.close()
                throw java.net.ProtocolException("node enabled WebSocket compression")
            }
            return res
        }
    }
```

(import `okhttp3.Interceptor`). Pinned clients are built with `base.newBuilder()` and inherit the interceptor.

- [ ] **Step 8: Failing tests (data).** `ApkUpdaterTest`: give `FakeApi` a `chunkSize: (Int) -> Int?` hook (null =
  normal) and append:

```kotlin
    @Test fun sizeOverTheLimitIsRefusedWithoutARequest() = runBlocking {
        val api = FakeApi(apk)
        val r = updater(api).download(update.toBuilder().setSize(ReceiveLimits.APK_MAX + 1).build()) {}
        assertEquals(UpdateResult.Corrupt, r)
        assertEquals(emptyList<Int>(), api.requested)
    }

    @Test fun aChunkOfTheWrongSizeIsCorrupt() = runBlocking {
        val r = updater(FakeApi(apk, chunkSize = { i -> if (i == 0) 10 else null })).download(update) {}
        assertEquals(UpdateResult.Corrupt, r)
        assertTrue(dir().listFiles().orEmpty().isEmpty())
    }
```

with `FakeApi(val data: ByteArray?, val corruptAt: Int = -1, val chunkSize: (Int) -> Int? = { null })` and, in
`apkGet`, `val n = chunkSize(index) ?: chunk.size` → `setData(bs(chunk.copyOf(n)))` (import
`app.ottermsg.core.network.ReceiveLimits`).

`PhotoFlowTest`, append (imports `app.ottermsg.core.network.NodeApi`; `noise = true` makes the photo span more than
one chunk):

```kotlin
    @Test fun aChunkOfTheWrongSizeIsRefusedBeforeItTouchesTheDisk() = runBlocking {
        family(policy = Settings.AUTO_MANUAL)
        a.messages.sendPhoto(a.messages.conversationWith(b.me.userId), picture(2000, 1500, noise = true), "")
        eventually(what = "B receives") { b.lastIncoming()?.kind == MessageKind.PHOTO }
        val id = b.lastIncoming()!!.localId
        b.offline()                 // no worker of its own: we drive the download through a hostile node
        b.photos.download(id)       // REMOTE → QUEUED
        assertTrue("needs ≥ 2 chunks", b.db.attachmentDao().forMessage(id)!!.size > 256 * 1024)
        val s = node.connect().also { it.login(b.me.userId, b.me.accountKey) }
        var gets = 0
        val hostile = object : NodeApi by s {
            override suspend fun blobGet(key: ByteArray, index: Int): ByteArray { gets++; return s.blobGet(key, index).let { it.copyOf(it.size - 1) } }
        }
        b.media.drainOnce(hostile)
        val att = b.db.attachmentDao().forMessage(id)!!
        assertEquals("stops at the first bad chunk (today it fetches them all and fails only the final digest)", 1, gets)
        assertEquals(0, att.doneChunks)
        assertTrue(att.attempts >= 1)
        assertTrue(att.state != AttachmentState.DOWNLOADED)
        s.close()
    }
```

- [ ] **Step 9: Implement (data).** `MediaTransfers.download`, inside the loop:

```kotlin
            for (idx in start until chunks) {
                val data = api.blobGet(a.blobKey, idx)
                val expected = minOf(BlobCipher.CHUNK.toLong(), a.size - idx.toLong() * BlobCipher.CHUNK).toInt()
                // C17: a chunk is an exact slice of the ciphertext; anything else is refused before it touches the disk.
                if (data.size != expected) throw IOException("blob chunk $idx: ${data.size} bytes, expected $expected")
                withContext(Dispatchers.IO) { part.appendBytes(data) }
                dao.progress(a.id, idx + 1)
            }
```

(`IOException` → the existing generic catch → `backoff(a)`.)

`ApkUpdater.download`, first line inside `withContext`:

```kotlin
        if (u.size <= 0 || u.size > ReceiveLimits.APK_MAX) return@withContext UpdateResult.Corrupt // C17
```

and in the loop:

```kotlin
                    val c = api.apkGet(u.sha256.toByteArray(), index)
                    val want = minOf(CHUNK, u.size - index.toLong() * CHUNK)
                    if (c.data.size().toLong() != want) { // C17: the file never grows past the signed size
                        out.close(); part.delete()
                        return@withContext UpdateResult.Corrupt
                    }
                    out.write(c.data.toByteArray())
```

- [ ] **Step 10: Run** the Verify command → `BUILD SUCCESSFUL`.

- [ ] **Step 11: Commit**

```bash
git add core/network/ core/data/src/main/kotlin/app/ottermsg/core/data/media/MediaTransfers.kt \
  core/data/src/main/kotlin/app/ottermsg/core/data/news/ApkUpdater.kt core/data/src/test/
oc -m "network: receive limits for frames, events, blob and APK chunks; no WebSocket compression (C17)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 25: Android — bounded picture decoding and secure secret screens

**Goal:** No photo or thumbnail can exhaust memory, and no screen that shows or takes the words or a backup password
can be captured.

**Findings closed:** C21, C22

**Files:**
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/media/PhotoLoader.kt` (whole file),
  `MediaRepository.kt:18-55` (`PhotoStore.corrupt`)
- Modify: `feature/conversation/.../PhotoSource.kt`, `ConversationViewModel.kt:145-149`, `PhotoMessage.kt:49-90`,
  `PhotoViewerScreen.kt:56-80`, `feature/conversation/src/main/res/values{,-en}/strings.xml`
- Create: `core/ui/src/main/kotlin/app/ottermsg/core/ui/components/SecureWindow.kt`
- Modify: `feature/onboarding/.../screens/PhraseScreen.kt:45-66` (remove the local `SecureWindow`),
  `PhraseConfirmScreen.kt`, `RestoreScreens.kt:63-147`, `feature/settings/.../BackupScreen.kt:203-225`
- Test: `core/data/src/test/.../media/PhotoHelpersTest.kt`, `feature/conversation/src/test/.../PhotoMessageTest.kt`,
  `feature/settings/src/test/.../SecureScreensTest.kt` (new), `feature/onboarding/src/test/.../SecureRestoreTest.kt` (new)

**Acceptance Criteria:**
- [ ] `PhotoLoader.sampleFor(w, h, maxPx)`: `null` for `w·h > 100 000 000` or a non-positive size; otherwise a power
  of two with `max(w,h)/s ≤ 4096` and roughly `maxPx`.
- [ ] A stored photo whose header claims 20000×20000 → `load()` = null, `isCorrupt()` = true; the bubble shows
  «Фото повреждено» and the viewer shows it instead of a spinner.
- [ ] `thumb()` decodes with bounds first and refuses > 100 MP.
- [ ] `FLAG_SECURE` is set while `RestorePasswordScreen`, `RestoreHistoryScreen`, `RestoreWordsScreen`,
  `PhraseScreen`, `PhraseConfirmScreen` or the backup password form is shown, and cleared after; two secure screens
  overlapping (navigation) keep it until both are gone.

**Verify:** `cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*PhotoHelpersTest*' :feature:conversation:testDebugUnitTest :feature:settings:testDebugUnitTest :feature:onboarding:testDebugUnitTest` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing tests (decode).** `PhotoHelpersTest`, append:

```kotlin
    @Test fun sampleForBoundsDecodedSizeAndRefusesHugeSources() {
        assertNull(PhotoLoader.sampleFor(20_000, 20_000, 400))   // 400 MP
        assertNull(PhotoLoader.sampleFor(0, 100, 400))
        assertEquals(4, PhotoLoader.sampleFor(2000, 1000, 400))  // 500 px long edge, as before
        val s = PhotoLoader.sampleFor(9000, 9000, 4096)!!         // 81 MP, viewer size
        assertTrue(9000 / s <= PhotoLoader.MAX_DECODED_EDGE)
    }

    @Test fun hugeHeaderIsCorruptNotDecoded() = runBlocking {
        val db = Room.inMemoryDatabaseBuilder(context, OtterDatabase::class.java).allowMainThreadQueries().build()
        val files = MediaFiles(context)
        val name = files.newName()
        val key = BlobCipher.newKey(); val blobKey = ByteArray(32) { 4 }
        val sealed = BlobCipher.encrypt(ByteArrayInputStream(pngHeader(20_000, 20_000)), files.file(name), key, blobKey)
        db.attachmentDao().insert(AttachmentEntity(messageLocalId = 11, blobKey = blobKey, key = key, digest = sealed.sha256,
            size = sealed.size, mime = "image/png", width = 1, height = 1, thumb = null, file = name, state = AttachmentState.DOWNLOADED))
        val loader = PhotoLoader(db, files)
        assertNull(loader.load(11, 4096))
        assertTrue(loader.isCorrupt(11))
        assertNull(loader.thumb(pngHeader(20_000, 20_000)))
        db.close()
    }

    /** A PNG with only IHDR (+ IEND): enough for inJustDecodeBounds to report the claimed size. */
    private fun pngHeader(w: Int, h: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        out.write(byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A))
        fun chunk(type: String, data: ByteArray) {
            out.write(java.nio.ByteBuffer.allocate(4).putInt(data.size).array())
            val td = type.toByteArray() + data
            out.write(td)
            out.write(java.nio.ByteBuffer.allocate(4).putInt(java.util.zip.CRC32().apply { update(td) }.value.toInt()).array())
        }
        chunk("IHDR", java.nio.ByteBuffer.allocate(13).putInt(w).putInt(h).put(8).put(2).put(0).put(0).put(0).array())
        chunk("IEND", ByteArray(0))
        return out.toByteArray()
    }
```

`PhotoMessageTest`, append (imports `androidx.compose.runtime.CompositionLocalProvider`, `androidx.compose.ui.unit.dp`,
`androidx.compose.ui.graphics.ImageBitmap`):

```kotlin
    @Test fun corruptPhotoSaysSo() {
        val src = object : PhotoSource {
            override suspend fun load(localId: Long, maxPx: Int): ImageBitmap? = null
            override suspend fun thumb(localId: Long): ImageBitmap? = null
            override suspend fun corrupt(localId: Long) = true
        }
        compose.setContent { OtterTheme { CompositionLocalProvider(LocalPhotoSource provides src) {
            PhotoContent(1L, PhotoUi(800, 600, PhotoState.Ready), 240.dp, onDownload = {})
        } } }
        compose.waitUntil(5_000) { compose.onAllNodesWithText("Фото повреждено", useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty() }
    }
```

- [ ] **Step 2: Failing tests (secure).** Create `feature/settings/src/test/kotlin/app/ottermsg/feature/settings/SecureScreensTest.kt`:

```kotlin
package app.ottermsg.feature.settings

import android.view.WindowManager.LayoutParams.FLAG_SECURE
import androidx.activity.ComponentActivity
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import app.ottermsg.core.data.backup.BackupState
import app.ottermsg.core.ui.components.SecureWindow
import app.ottermsg.core.ui.theme.OtterTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "ru")
class SecureScreensTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private fun secure() = compose.activity.window.attributes.flags and FLAG_SECURE

    @Test fun backupPasswordFormIsSecureOnlyWhileOpen() {
        val form = mutableStateOf(BackupViewModel.Form(open = true))
        compose.setContent { OtterTheme {
            BackupScreen(BackupState.Off, true, form.value, SnackbarHostState(), {}, {}, {}, {}, {}, {})
        } }
        compose.waitForIdle(); assertNotEquals(0, secure())
        form.value = BackupViewModel.Form()
        compose.waitForIdle(); assertEquals(0, secure())
    }

    @Test fun overlappingSecureScreensKeepTheFlag() {
        val first = mutableStateOf(true); val second = mutableStateOf(true)
        compose.setContent { if (first.value) SecureWindow(); if (second.value) SecureWindow() }
        compose.waitForIdle()
        first.value = false
        compose.waitForIdle(); assertNotEquals(0, secure()) // the other one still needs it
        second.value = false
        compose.waitForIdle(); assertEquals(0, secure())
    }
}
```

Create `feature/onboarding/src/test/kotlin/app/ottermsg/feature/onboarding/SecureRestoreTest.kt` the same way with
`RestorePasswordScreen(OnboardingUiState(), {}, {}, {}, {})` and `RestoreHistoryScreen(OnboardingUiState(), {}, {}, {})`,
each asserting `secure() != 0` while shown.

- [ ] **Step 3: Run** → FAIL (no `sampleFor`, no `corrupt`, no public `SecureWindow`, flag not set).

- [ ] **Step 4: `PhotoLoader`** (keep the cache and `jpeg`; `import java.util.concurrent.ConcurrentHashMap`):

```kotlin
    /** Photos whose file exists but cannot be shown safely or at all (C21): «Фото повреждено». */
    private val corrupt: MutableSet<Long> = ConcurrentHashMap.newKeySet()
    fun isCorrupt(localId: Long): Boolean = localId in corrupt

    suspend fun load(localId: Long, maxPx: Int): Bitmap? = withContext(Dispatchers.IO) {
        val k = "$localId:$maxPx"
        cache.get(k)?.let { return@withContext it }
        val a = db.attachmentDao().forMessage(localId) ?: return@withContext null
        if (a.state != AttachmentState.DOWNLOADED && a.state != AttachmentState.UPLOADED && a.state != AttachmentState.UPLOADING &&
            a.state != AttachmentState.UPLOAD_FAILED) return@withContext null
        val f = files.file(a.file ?: return@withContext null)
        if (!f.exists()) return@withContext null
        val bmp = runCatching {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BlobCipher.decrypt(f, a.key, a.blobKey).use { BitmapFactory.decodeStream(it, null, bounds) }
            val sample = sampleFor(bounds.outWidth, bounds.outHeight, maxPx) ?: return@runCatching null
            BlobCipher.decrypt(f, a.key, a.blobKey).use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) }
        }.getOrNull()
        if (bmp == null) { corrupt += localId; return@withContext null }
        corrupt -= localId
        bmp.also { cache.put(k, it) }
    }

    /** The sender's thumbnail (≤ 16 KiB of JPEG, but its header can claim any size): bounded like a photo. */
    fun thumb(bytes: ByteArray?): Bitmap? = bytes?.let { b ->
        runCatching {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(b, 0, b.size, bounds)
            val s = sampleFor(bounds.outWidth, bounds.outHeight, THUMB_MAX_PX) ?: return@runCatching null
            BitmapFactory.decodeByteArray(b, 0, b.size, BitmapFactory.Options().apply { inSampleSize = s })
        }.getOrNull()
    }

    companion object {
        const val MAX_SOURCE_PIXELS = 100_000_000L
        const val MAX_DECODED_EDGE = 4096
        const val THUMB_MAX_PX = 256

        /** inSampleSize for a [w]×[h] source shown at about [maxPx] (≤ 2× larger, never above 4096); null = refuse (C21). */
        fun sampleFor(w: Int, h: Int, maxPx: Int): Int? {
            if (w <= 0 || h <= 0 || w.toLong() * h > MAX_SOURCE_PIXELS) return null
            val edge = max(w, h)
            var s = 1
            while (edge / (s * 2) >= minOf(maxPx, MAX_DECODED_EDGE)) s *= 2
            while (edge / s > MAX_DECODED_EDGE) s *= 2
            return s
        }
    }
```

`MediaRepository`: in `PhotoStore` add `suspend fun corrupt(localId: Long): Boolean = false` (default keeps the test
fakes compiling) and in `MediaRepository` `override suspend fun corrupt(localId: Long) = loader.isCorrupt(localId)`.

- [ ] **Step 5: UI.** `PhotoSource`: `suspend fun corrupt(localId: Long): Boolean = false`. `ConversationViewModel.photoSource`:
  `override suspend fun corrupt(localId: Long) = photos.corrupt(localId)`. `PhotoContent`:

```kotlin
    var corrupt by remember(localId) { mutableStateOf(false) }
    LaunchedEffect(localId, p.state) {
        if (p.state == PhotoState.Ready || p.state == PhotoState.Uploading) {
            source.load(localId, maxPx)?.let { image = it; full = true; return@LaunchedEffect }
            corrupt = source.corrupt(localId)
        }
        if (!full) image = source.thumb(localId)
    }
```

and `PhotoState.Ready -> if (corrupt) Label(stringResource(R.string.conv_photo_corrupt))`. `PhotoViewerViewModel`:
`private val _corrupt = MutableStateFlow(false); val corrupt: StateFlow<Boolean> = _corrupt`; `init { viewModelScope.launch {
val b = photos.load(localId, MAX_PX); _image.value = b?.asImageBitmap(); if (b == null) _corrupt.value = photos.corrupt(localId) } }`;
`PhotoViewerRoute`: `image?.let { ZoomableImage(it) } ?: if (corrupt) Text(stringResource(R.string.conv_photo_corrupt),
color = Color.White, modifier = Modifier.align(Alignment.Center)) else CircularProgressIndicator(…)`.
Strings: `conv_photo_corrupt` «Фото повреждено» / "Photo is damaged".

- [ ] **Step 6: `SecureWindow`** — create `core/ui/src/main/kotlin/app/ottermsg/core/ui/components/SecureWindow.kt`:

```kotlin
package app.ottermsg.core.ui.components

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.view.Window
import android.view.WindowManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.platform.LocalContext
import java.util.WeakHashMap

/** Screens per window that asked for FLAG_SECURE; main thread only. */
private val secureScreens = WeakHashMap<Window, Int>()

/**
 * FLAG_SECURE while the recovery words or a backup password are on screen (C22, D98): no screenshots, hidden in the
 * recents preview. Reference-counted, so the next secure screen keeps the flag when the previous one leaves.
 */
@Composable
fun SecureWindow() {
    val window = LocalContext.current.findActivity()?.window
    DisposableEffect(window) {
        if (window != null) {
            val n = secureScreens[window] ?: 0
            secureScreens[window] = n + 1
            if (n == 0) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
        onDispose {
            if (window != null) {
                val n = (secureScreens[window] ?: 1) - 1
                if (n <= 0) { secureScreens.remove(window); window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE) }
                else secureScreens[window] = n
            }
        }
    }
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
```

Delete `SecureWindow` and `findActivity` from `PhraseScreen.kt` (and their now unused imports); import
`app.ottermsg.core.ui.components.SecureWindow` in `PhraseScreen.kt`, `PhraseConfirmScreen.kt`, `RestoreScreens.kt`.
Add `SecureWindow()` as the first line of `RestorePasswordScreen` and `RestoreHistoryScreen`, and of `PasswordForm` in
`BackupScreen.kt`. (Any screen Tasks 10–19 add that shows the words or takes a backup password calls it too.)

- [ ] **Step 7: Run** the Verify command → `BUILD SUCCESSFUL`.

- [ ] **Step 8: Commit**

```bash
git add core/data/src/main/kotlin/app/ottermsg/core/data/media/ core/data/src/test/kotlin/app/ottermsg/core/data/media/ \
  core/ui/src/main/kotlin/app/ottermsg/core/ui/components/SecureWindow.kt feature/conversation/ feature/onboarding/ feature/settings/
oc -m "media: bounded photo and thumbnail decoding with «Фото повреждено»; FLAG_SECURE on every secret screen (C21, C22)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 26: Android — the inviter from a link stays unconfirmed until the directory verifies it

**Goal:** A forged invite link cannot plant keys for a contact: nothing is encrypted to or accepted from link keys.

**Findings closed:** C23

**Files:**
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/registration/Registration.kt:117-126`
- Modify: `core/data/.../messaging/Outbox.kt:124-128` (`process`), `MailboxReceiver.kt` (sender lookup, as left by Task 22)
- Test: `core/data/src/test/kotlin/app/ottermsg/core/data/InviterContactTest.kt` (new),
  `MessagingFlowTest.kt:37-40` (the inviter is no longer `verified`)

**Acceptance Criteria:**
- [ ] After registering with a real link the inviter contact exists with `verified = false`, `entryVersion = 0`;
  after the first directory sync `entryVersion > 0`, `verified = false`, `identityChanged = false`.
- [ ] A link whose `inviter_user_id ≠ ID16(inviter_account_pub)` stores no inviter contact.
- [ ] Before the directory confirms the inviter, `Outbox.drainOnce` sends nothing to them (the item stays queued,
  not failed); after the sync it is sent.
- [ ] `MailboxReceiver` treats an `entryVersion = 0` contact like an unknown sender (sync, else leave on the node).

**Verify:** `cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*InviterContactTest*' --tests '*MessagingFlowTest*' --tests '*RegistrationTest*' --tests '*ForgedEnvelopeTest*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing test** — create `core/data/src/test/kotlin/app/ottermsg/core/data/InviterContactTest.kt`:

```kotlin
package app.ottermsg.core.data

import app.ottermsg.core.crypto.Ed25519
import app.ottermsg.core.crypto.InviteLink
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** C23: the inviter fields of a link are unauthenticated. */
@RunWith(RobolectricTestRunner::class)
class InviterContactTest {
    private val clock = TestClock()
    private val node = FakeNode(clock::now)
    private val a = TestGraph(node, clock)
    private val b = TestGraph(node, clock)
    @After fun tearDown() { a.close(); b.close() }

    private suspend fun inviterOnline(): String {
        a.register(node.bootstrapLink(), "Мама", "mama").getOrThrow(); a.online()
        return a.invites.create().link
    }

    @Test fun linkContactIsUnconfirmedUntilTheDirectory() = runBlocking {
        b.register(inviterOnline(), "Боря", "borya").getOrThrow()
        val c = b.db.contactDao().get(a.me.userId)!!
        assertFalse(c.verified); assertEquals(0, c.entryVersion)

        // Not sent while only the link vouches for A.
        b.messages.sendText(b.messages.conversationWith(a.me.userId), "рано")
        val s = node.connect().also { it.login(b.me.userId, b.me.accountKey) }
        b.outbox.drainOnce(s)
        assertTrue(node.mailbox(a.me.userId).isEmpty())
        assertEquals(1, b.db.outboxDao().due(Long.MAX_VALUE).size)

        b.directory.sync(s)
        val confirmed = b.db.contactDao().get(a.me.userId)!!
        assertTrue(confirmed.entryVersion > 0); assertFalse(confirmed.verified); assertFalse(confirmed.identityChanged)
        clock.advance(120_000) // past the retry backoff
        b.outbox.drainOnce(s)
        assertEquals(1, node.mailbox(a.me.userId).size)
        s.close()
    }

    @Test fun linkWithAMismatchedInviterStoresNoContact() = runBlocking {
        val real = InviteLink.decode(inviterOnline())
        val evil = Ed25519.keyPairFromSeed(ByteArray(32) { 5 })
        // Same user id as A, someone else's key: a hostile node or a tampered message hands this out.
        val forged = InviteLink.encode(real.toBuilder().setInviterAccountPub(bs(evil.publicKey)).build())
        b.register(forged, "Боря", "borya").getOrThrow()
        assertNull(b.db.contactDao().get(a.me.userId))
        b.online()
        eventually(what = "A from the directory") { b.db.contactDao().get(a.me.userId)?.entryVersion ?: 0 > 0 }
        assertTrue(b.db.contactDao().get(a.me.userId)!!.accountPub.contentEquals(a.me.accountKey.publicKey))
    }
}
```

In `MessagingFlowTest.sendDeliverRead` change the first assertion to
`assertFalse(b.db.contactDao().get(a.me.userId)!!.verified)` with the comment
`// B's inviter (A) is never "verified" from a link alone (C23)` (import `assertFalse`).

- [ ] **Step 2: Run** → FAIL (`verified` is true; the message is sent before the sync; the mismatched link stores A
  with the evil key).

- [ ] **Step 3: Registration** — replace the inviter upsert inside the transaction:

```kotlin
            // C23: the link's inviter fields are not signed. Keep them only as a placeholder (name in the chat list):
            // entryVersion 0 = "only from a link", never verified; the directory entry replaces it.
            val inviterPub = bundle.inviterAccountPub.toByteArray()
            if (!bundle.inviterUserId.isEmpty && inviterPub.size == 32 &&
                bundle.inviterUserId.toByteArray().contentEquals(Ids.id16(inviterPub))) db.contactDao().upsert(ContactEntity(
                bundle.inviterUserId.toByteArray(), "", bundle.inviterName, inviterPub,
                bundle.inviterIdentityPub.toByteArray(), verified = false, identityChanged = false, revoked = false, entryVersion = 0))
```

- [ ] **Step 4: Outbox** — in `process`, replace the contact line:

```kotlin
            val contact = contacts.get(item.recipientUserId) ?: throw PermanentFailure("unknown contact")
            // C23: keys known only from an invite link are not used until the directory confirms them (retried later).
            if (contact.entryVersion == 0) throw java.io.IOException("contact not confirmed by the directory yet")
```

- [ ] **Step 5: Receiver** — in `MailboxReceiver.handle` the two lookups become
  `contacts.get(body.author.toByteArray())?.takeIf { it.entryVersion > 0 }` (comment: `// a link-only contact (C23) is
  not trusted to sign envelopes`).

- [ ] **Step 6: Run** the Verify command → `BUILD SUCCESSFUL`.

- [ ] **Step 7: Commit**

```bash
git add core/data/src/main/kotlin/app/ottermsg/core/data/registration/Registration.kt core/data/src/main/kotlin/app/ottermsg/core/data/messaging/ \
  core/data/src/test/kotlin/app/ottermsg/core/data/InviterContactTest.kt core/data/src/test/kotlin/app/ottermsg/core/data/MessagingFlowTest.kt
oc -m "registration: the inviter from a link is unconfirmed until its directory entry verifies (C23)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 27: Android — the shared connection log hides hosts, operator and IP addresses

**Goal:** «Поделиться» gives a helper what they need to debug, but no server addresses, operator or extra timing.

**Findings closed:** C24

**Files:**
- Modify: `otter-android/feature/settings/src/main/kotlin/app/ottermsg/feature/settings/NetLogScreen.kt:46-90`
- Test: `otter-android/feature/settings/src/test/kotlin/app/ottermsg/feature/settings/NetLogFormatTest.kt`

**Acceptance Criteria:**
- [ ] `shareLine` of `ru-1  wss://203.0.113.7:27443  mobile MTS  timeout  "Failed to connect to /203.0.113.7:27443"`
  = `14.11 22:13–22:23  ru-1  wss:27443  моб.  timeout  ×3 (Failed to connect to /ru-1:27443)`.
- [ ] A hostname endpoint and an IPv6 endpoint lose their host the same way; any other IPv4/IPv6 in the detail
  becomes `<ip>`; call lines keep `call:<path>`, outcome and duration.
- [ ] Shared times are minute resolution (no seconds); the on-screen lines are unchanged (`formatLine` tests green).

**Verify:** `cd otter-android && ./gradlew :feature:settings:testDebugUnitTest --tests '*NetLogFormatTest*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing tests** — append to `NetLogFormatTest`:

```kotlin
    @Test fun sharedLineHidesHostOperatorAndIps() {
        val e = NetLogEntity(1, "ru-1", "wss://203.0.113.7:27443", "mobile", "MTS", "timeout",
            "Failed to connect to /203.0.113.7:27443", 0, 3, 1_700_000_000_000, 1_700_000_600_000)
        assertEquals("14.11 22:13–22:23  ru-1  wss:27443  моб.  timeout  ×3 (Failed to connect to /ru-1:27443)",
            shareLine(e, utc, "моб."))
    }

    @Test fun sharedLineHidesHostnamesIpv6AndOtherIps() {
        val named = NetLogEntity(2, "eeee", "wss://eeee.example:443", "wifi", "", "tls",
            "eeee.example via 198.51.100.4: pin mismatch", 0, 1, 1_700_000_000_000, 1_700_000_000_000)
        assertEquals("14.11 22:13  eeee  wss:443  Wi-Fi  tls  ×1 (eeee via <ip>: pin mismatch)", shareLine(named, utc, "моб."))
        val v6 = NetLogEntity(3, "ru-1", "wss://[2001:db8::7]:443", "wifi", "", "refused",
            "connect to [2001:db8::7]:443 failed", 0, 1, 1_700_000_000_000, 1_700_000_000_000)
        assertEquals("14.11 22:13  ru-1  wss:443  Wi-Fi  refused  ×1 (connect to [ru-1]:443 failed)", shareLine(v6, utc, "моб."))
    }

    @Test fun sharedCallLineKeepsOutcome() {
        val ok = NetLogEntity(4, "eeee", "call:relay-udp", "mobile", "MTS", "ok", "OUTGOING 1:05", 40, 2,
            1_700_000_000_000, 1_700_000_600_000)
        assertEquals("14.11 22:13–22:23  eeee  call:relay-udp  моб.  ok  ×2 (OUTGOING 1:05, 40 ms)", shareLine(ok, utc, "моб."))
    }
```

- [ ] **Step 2: Run** → FAIL (`shareLine` unresolved).

- [ ] **Step 3: Implement** in `NetLogScreen.kt`:

```kotlin
private val IPV4 = Regex("""\b\d{1,3}(?:\.\d{1,3}){3}\b""")
private val IPV6 = Regex("""\b(?:[0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{0,4}\b|(?:[0-9a-fA-F]{1,4})?::(?:[0-9a-fA-F]{1,4}:?){1,6}""")

/**
 * The shared form of a line (C24, D96): node label instead of host (`wss:27443`), no mobile operator, the endpoint's
 * host replaced by the label and any other IP address by `<ip>` in the error text. Times stay at minute resolution.
 */
internal fun shareLine(e: NetLogEntity, zone: ZoneId, mobileLabel: String): String {
    if (e.endpoint.startsWith("call:")) return formatLine(e.copy(operator = ""), zone, mobileLabel)
    val hostPort = e.endpoint.substringAfter("://", "")
    val host = hostPort.substringBeforeLast(':').removeSurrounding("[", "]")
    val endpoint = e.endpoint.substringBefore("://") + ":" + hostPort.substringAfterLast(':')
    var detail = if (host.isNotEmpty()) e.detail.replace(host, e.nodeLabel) else e.detail
    detail = IPV6.replace(IPV4.replace(detail, "<ip>"), "<ip>")
    return formatLine(e.copy(endpoint = endpoint, operator = "", detail = detail), zone, mobileLabel)
}
```

and in `NetLogRoute` build the shared text from `rows.map { shareLine(it, zone, mobile) }` (the screen keeps `lines`).

- [ ] **Step 4: Run** the Verify command → `BUILD SUCCESSFUL`.

- [ ] **Step 5: Commit**

```bash
git add feature/settings/src/main/kotlin/app/ottermsg/feature/settings/NetLogScreen.kt feature/settings/src/test/kotlin/app/ottermsg/feature/settings/NetLogFormatTest.kt
oc -m "netlog: shared log uses node labels, no operator, no IP addresses (C24)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 28: Android — release builds fail without the release key; push switches in Settings

**Goal:** No debug-signed release can be built by accident, and the member controls both push switches.

**Findings closed:** C19; design limit 4 / push option B (phone half)

**Files:**
- Modify: `otter-android/app/build.gradle.kts:24-53`
- Modify: `core/data/.../settings/Settings.kt:81-125` (`googleWake`), `core/data/.../push/PushRegistrar.kt`
- Create: `core/data/src/main/kotlin/app/ottermsg/core/data/push/PushSwitches.kt`
- Create: `app/src/main/java/app/ottermsg/push/FirebasePushTokens.kt`; Modify: `app/src/main/java/app/ottermsg/AppModule.kt`,
  `OtterApp.kt:50-54`, `push/OtterMessagingService.kt:24-29`
- Modify: `feature/settings/.../NotificationsScreen.kt`, `feature/settings/src/main/res/values{,-en}/strings.xml`
- Test: `core/data/src/test/.../push/PushSwitchesTest.kt` (new), `PushRegistrarTest.kt`, `FakeNode.kt:119-123,380-384`,
  `feature/settings/src/test/.../NotificationsViewModelTest.kt`

**Acceptance Criteria:**
- [ ] `./gradlew :app:packageRelease -PotterKeystore=missing.properties` fails with "Release builds need
  keystore.properties"; `:app:testDebugUnitTest`, `assembleDebug`, `assembleStaging` succeed with the same flag; with
  the owner's `keystore.properties`, `assembleRelease` is release-signed.
- [ ] Notifications off → the node holds `PUSH_TOKEN{token, messages_off = true}`; on again → `messages_off = false`.
- [ ] Google wake off → `PushTokenSource.delete()` called, the node holds `{withdrawn = true, token = ""}`,
  `push.status` false, `PushMonitor.mode()` = SAVER; on again → a fresh token is fetched and registered with the
  current `messages_off`.
- [ ] A phone that never registered a token sends no withdrawal.
- [ ] Settings → «Уведомления» shows «Показывать уведомления» and «Пробуждение через Google»; with the latter off it
  shows «Без пробуждения через Google звонки не будут приходить» and the saver hint «Проверяем каждые 15 минут:
  пробуждение через Google выключено».

**Verify:** `cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*Push*' :feature:settings:testDebugUnitTest :app:testDebugUnitTest && ./gradlew :app:packageRelease -PotterKeystore=missing.properties` → first `BUILD SUCCESSFUL`, second `BUILD FAILED` with `Release builds need keystore.properties`

**Steps:**

- [ ] **Step 1: C19 build rule** — in `app/build.gradle.kts` replace the comment and `keystoreProps` lines:

```kotlin
// Release signing (D68, C19): the owner's keystore.properties (gitignored: storeFile, storePassword, keyAlias,
// keyPassword) next to settings.gradle.kts. Without it a release build FAILS (no debug-key fallback); debug and
// staging builds stay debug-signed and unit tests never need it. -PotterKeystore=FILE points elsewhere (tests).
val keystoreProps = rootProject.file(providers.gradleProperty("otterKeystore").getOrElse("keystore.properties"))
val hasReleaseKeystore = keystoreProps.exists()
```

in `release { … }`: `signingConfig = signingConfigs.findByName("release") // null without the keystore: requireReleaseKeystore stops packaging`,
and after the `android { }` block:

```kotlin
val requireReleaseKeystore = tasks.register("requireReleaseKeystore") {
    val ok = hasReleaseKeystore
    doLast { if (!ok) throw GradleException("Release builds need keystore.properties (D68, C19); there is no debug-key fallback") }
}
tasks.configureEach { if (name == "packageRelease" || name == "signReleaseBundle") dependsOn(requireReleaseKeystore) }
```

Run `./gradlew :app:packageRelease -PotterKeystore=missing.properties` → `BUILD FAILED … Release builds need
keystore.properties`; `./gradlew :app:assembleDebug :app:assembleStaging -PotterKeystore=missing.properties` →
`BUILD SUCCESSFUL`. Commit:

```bash
git add app/build.gradle.kts
oc -m "build: release builds fail without the release keystore, no debug-key fallback (C19)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 2: FakeNode records the flags.** In `FakeNode`: `val pushRecords = mutableMapOf<String, app.ottermsg.proto.v1.PushToken>()`
  and in `registerPush` after `verifyUser`:

```kotlin
            val p = app.ottermsg.proto.v1.PushToken.parseFrom(b.payload)
            pushTokens[b.author.hex()] = p.token // "" when withdrawn: hasPush() is false, like a 0.9.0 node
            pushRecords[b.author.hex()] = p
```

- [ ] **Step 3: Failing tests.** Create `core/data/src/test/kotlin/app/ottermsg/core/data/push/PushSwitchesTest.kt`:

```kotlin
package app.ottermsg.core.data.push

import app.ottermsg.core.data.FakeNode
import app.ottermsg.core.data.TestClock
import app.ottermsg.core.data.TestGraph
import app.ottermsg.core.data.invite.OnlineApi
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class PushSwitchesTest {
    private val clock = TestClock()
    private val node = FakeNode(clock::now)
    private val g = TestGraph(node, clock)
    @After fun tearDown() = g.close()

    private class FakeTokens(var next: String? = "tok-1") : PushTokenSource {
        var deleted = 0
        override suspend fun fetch(): String? = next
        override suspend fun delete() { deleted++ }
    }

    private suspend fun setup(): Pair<PushSwitches, FakeTokens> {
        g.register(node.bootstrapLink(), "Мама", "mama").getOrThrow()
        val api = node.connect().also { it.login(g.me.userId, g.me.accountKey) }
        val src = FakeTokens()
        return PushSwitches(g.settings, PushRegistrar(g.accounts, g.settings, g.clock), OnlineApi { api }, src) to src
    }

    private fun record() = node.pushRecords.values.single()

    @Test fun notificationsOffMeansCallsOnly() = runBlocking {
        val (sw, _) = setup()
        g.settings.setPushAvailable(true)
        sw.setGoogleWake(true) // first start: fetch + register
        assertEquals("tok-1", record().token); assertFalse(record().messagesOff)
        sw.setNotifications(false)
        assertEquals("tok-1", record().token); assertTrue(record().messagesOff)
        assertTrue(node.hasPush(g.me.userId)) // calls still wake the phone
        sw.setNotifications(true)
        assertFalse(record().messagesOff)
    }

    @Test fun googleWakeOffWithdrawsTheToken() = runBlocking {
        val (sw, src) = setup()
        g.settings.setPushAvailable(true)
        sw.setGoogleWake(true)
        sw.setNotifications(false)
        sw.setGoogleWake(false)
        assertTrue(record().withdrawn); assertEquals("", record().token)
        assertEquals(1, src.deleted)
        assertFalse(node.hasPush(g.me.userId))
        assertEquals(PushMode.SAVER, g.pushMonitor.mode())
        src.next = "tok-2"
        sw.setGoogleWake(true)
        assertFalse(record().withdrawn); assertEquals("tok-2", record().token); assertTrue(record().messagesOff)
    }

    @Test fun noWithdrawalWhenNothingWasEverRegistered() = runBlocking {
        val (sw, _) = setup()
        sw.setGoogleWake(false)
        assertTrue(node.pushRecords.isEmpty())
    }
}
```

`NotificationsViewModelTest.mapsModeAndSwitch`: construct with the new signature
`NotificationsViewModel(mode, enabled, wake, { saved = it }, { savedWake = it })` (`val wake = MutableStateFlow(true)`,
`var savedWake: Boolean? = null`), expect `NotificationsUi(PushMode.FAST, true, true)`, then `vm.setGoogleWake(false)`,
`advanceUntilIdle()`, `assertEquals(false, savedWake)`. Append:

```kotlin
    @Test fun googleWakeOffWarnsAboutCalls() {
        var wake: Boolean? = null
        compose.setContent {
            OtterTheme { NotificationsScreen(NotificationsUi(PushMode.SAVER, true, googleWake = false), systemOn = true, {}, {}, {},
                onGoogleWake = { wake = it }) }
        }
        compose.onNodeWithText("Пробуждение через Google").assertExists()
        compose.onNodeWithText("Без пробуждения через Google звонки не будут приходить").assertExists()
        compose.onNodeWithText("Проверяем каждые 15 минут: пробуждение через Google выключено").assertExists()
        compose.onNodeWithText("Пробуждение через Google").performClick()
        compose.waitForIdle()
        assertEquals(true, wake)
    }
```

- [ ] **Step 4: Run** → FAIL (`PushSwitches`, `PushTokenSource`, `googleWake` unresolved).

- [ ] **Step 5: Settings** — next to the push settings:

```kotlin
    /** «Пробуждение через Google» (D94): off = FCM token deleted and withdrawn, battery saver. Default on. */
    suspend fun googleWake(): Boolean = (int(GOOGLE_WAKE) ?: 1) != 0
    suspend fun setGoogleWake(v: Boolean) = putInt(GOOGLE_WAKE, if (v) 1 else 0)
    fun observeGoogleWake(): Flow<Boolean> = observeInt(GOOGLE_WAKE, 1).map { it != 0 }
```

and `const val GOOGLE_WAKE = "google_wake"` in the companion.

- [ ] **Step 6: `PushRegistrar`** — the sent state now includes the flags (the plain token string stays the state of
  "token, notifications on", so existing installs do not re-send):

```kotlin
/** Sends this device's push state as a signed PUSH_TOKEN record when it changed (D60, D94). It replicates to every node. */
@Singleton
class PushRegistrar @Inject constructor(
    private val accounts: AccountRepository, private val settings: Settings, private val clock: Clock,
) {
    private val mutex = Mutex()

    suspend fun registerIfNeeded(api: NodeApi) = mutex.withLock {
        val sent = settings.pushTokenSent()
        val payload = PushToken.newBuilder().setDeviceId(1).setKind(PushToken.Kind.FCM)
        if (!settings.googleWake()) {
            if (sent == null || sent == WITHDRAWN) return@withLock // never registered, or already withdrawn
            payload.setWithdrawn(true)
        } else {
            val token = settings.pushToken()?.takeIf { it.isNotEmpty() } ?: return@withLock
            payload.setToken(token).setMessagesOff(!settings.notificationsEnabled())
        }
        val p = payload.build()
        val state = stateOf(p)
        if (state == sent) return@withLock
        val me = accounts.require()
        api.registerPush(RecordCodec.sign(RecordCodec.body(RecordType.PUSH_TOKEN, me.userId, p.toByteArray(),
            createdMs = clock.now()), me.accountKey))
        settings.setPushTokenSent(state)
    }

    companion object {
        const val WITHDRAWN = "withdrawn"
        fun stateOf(p: PushToken): String = when {
            p.withdrawn -> WITHDRAWN
            p.messagesOff -> "${p.token}|calls-only"
            else -> p.token
        }
    }
}
```

- [ ] **Step 7: `PushSwitches`** — create `core/data/src/main/kotlin/app/ottermsg/core/data/push/PushSwitches.kt`:

```kotlin
package app.ottermsg.core.data.push

import app.ottermsg.core.data.invite.OnlineApi
import app.ottermsg.core.data.settings.Settings
import java.util.logging.Level
import java.util.logging.Logger
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.cancellation.CancellationException

/** The push provider's token (Firebase in the app module). */
interface PushTokenSource {
    /** A fresh token (re-enables automatic token creation), or null when push is unavailable. */
    suspend fun fetch(): String?
    /** Deletes the token at the provider and stops automatic re-creation. */
    suspend fun delete()
}

/** The two switches of «Уведомления» (D94): they save the setting and tell the nodes at once when online. */
@Singleton
class PushSwitches @Inject constructor(
    private val settings: Settings, private val registrar: PushRegistrar, private val online: OnlineApi,
    private val tokens: PushTokenSource,
) {
    /** «Показывать уведомления»: off also asks the nodes for call pushes only. */
    suspend fun setNotifications(on: Boolean) {
        settings.setNotificationsEnabled(on)
        registerNow()
    }

    /** «Пробуждение через Google»: off deletes the FCM token and withdraws it; the phone falls back to SAVER (D61). */
    suspend fun setGoogleWake(on: Boolean) {
        settings.setGoogleWake(on)
        try {
            if (on) tokens.fetch()?.let { settings.setPushToken(it) } else { tokens.delete(); settings.setPushToken("") }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log.log(Level.WARNING, "push token ${if (on) "fetch" else "delete"} failed", e) // fetched again at the next start
            if (!on) settings.setPushToken("")
        }
        registerNow()
    }

    private suspend fun registerNow() {
        val api = online.current() ?: return // sent at the next login (SyncEngine.runSession)
        try { registrar.registerIfNeeded(api) }
        catch (e: CancellationException) { throw e }
        catch (e: Exception) { log.log(Level.WARNING, "push state not sent; next login", e) }
    }

    private companion object { val log: Logger = Logger.getLogger("PushSwitches") }
}
```

- [ ] **Step 8: App module.** Create `app/src/main/java/app/ottermsg/push/FirebasePushTokens.kt`:

```kotlin
package app.ottermsg.push

import android.content.Context
import app.ottermsg.core.data.push.PushTokenSource
import com.google.android.gms.tasks.Task
import com.google.firebase.messaging.FirebaseMessaging
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.suspendCancellableCoroutine
import java.io.IOException
import javax.inject.Inject
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class FirebasePushTokens @Inject constructor(@param:ApplicationContext private val ctx: Context) : PushTokenSource {
    override suspend fun fetch(): String? {
        if (!PushAvailability.check(ctx)) return null
        val m = FirebaseMessaging.getInstance()
        m.isAutoInitEnabled = true
        return m.token.await()
    }

    override suspend fun delete() {
        if (!PushAvailability.check(ctx)) return
        val m = FirebaseMessaging.getInstance()
        m.isAutoInitEnabled = false // no new token at the next start
        m.deleteToken().await()
    }

    private suspend fun <T> Task<T>.await(): T = suspendCancellableCoroutine { c ->
        addOnCompleteListener { t ->
            if (t.isSuccessful) c.resume(t.result) else c.resumeWithException(t.exception ?: IOException("FCM task failed"))
        }
    }
}
```

`AppModule`: `@Provides fun pushTokens(f: app.ottermsg.push.FirebasePushTokens): app.ottermsg.core.data.push.PushTokenSource = f`.
`OtterApp.onCreate`:

```kotlin
            if (available && settings.googleWake())
                FirebaseMessaging.getInstance().token.addOnSuccessListener { t -> appScope.launch { settings.setPushToken(t) } }
            else if (available) FirebaseMessaging.getInstance().isAutoInitEnabled = false // wake-ups off (D94)
```

`OtterMessagingService.onNewToken`: first line inside `launch`: `if (!settings.googleWake()) return@launch`.

- [ ] **Step 9: Settings screen.** `NotificationsScreen.kt`:

```kotlin
data class NotificationsUi(val mode: PushMode, val enabled: Boolean, val googleWake: Boolean = true)

@HiltViewModel
class NotificationsViewModel internal constructor(
    mode: Flow<PushMode>, enabled: Flow<Boolean>, wake: Flow<Boolean>,
    private val save: suspend (Boolean) -> Unit, private val saveWake: suspend (Boolean) -> Unit,
) : ViewModel() {
    @Inject constructor(monitor: PushMonitor, settings: AppSettings, switches: PushSwitches) :
        this(monitor.observeMode(), settings.observeNotificationsEnabled(), settings.observeGoogleWake(),
            { switches.setNotifications(it) }, { switches.setGoogleWake(it) })

    val ui: StateFlow<NotificationsUi?> = combine(mode, enabled, wake) { m, e, w -> NotificationsUi(m, e, w) }
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    fun setEnabled(v: Boolean) { viewModelScope.launch { save(v) } }
    fun setGoogleWake(v: Boolean) { viewModelScope.launch { saveWake(v) } }
}
```

`NotificationsRoute` passes `onGoogleWake = vm::setGoogleWake`. `NotificationsScreen(ui, systemOn, onBack, onEnabled, onSystem,
onGoogleWake: (Boolean) -> Unit = {})`: saver hint `if (!u.googleWake) R.string.notif_mode_saver_off_hint else
R.string.notif_mode_saver_hint`; the existing switch row becomes a private `SwitchRow(title, subtitle: String?, checked,
onChange)` used for «Показывать уведомления» and a second row `SwitchRow(stringResource(R.string.notif_google_wake),
stringResource(R.string.notif_google_wake_hint), u.googleWake, onGoogleWake)`; when `!u.googleWake` add
`OtterSettingsRow(stringResource(R.string.notif_google_wake_off_warning), icon = Icons.Outlined.NotificationsOff)`.
Strings (RU / EN):

```xml
    <string name="notif_google_wake">Пробуждение через Google</string>
    <string name="notif_google_wake_hint">Google видит только, когда телефон будят, но не сообщения</string>
    <string name="notif_google_wake_off_warning">Без пробуждения через Google звонки не будут приходить</string>
    <string name="notif_mode_saver_off_hint">Проверяем каждые 15 минут: пробуждение через Google выключено</string>
```

```xml
    <string name="notif_google_wake">Wake-up via Google</string>
    <string name="notif_google_wake_hint">Google only sees when the phone is woken, never the messages</string>
    <string name="notif_google_wake_off_warning">Without wake-up via Google, calls will not come through</string>
    <string name="notif_mode_saver_off_hint">Checking every 15 minutes: wake-up via Google is off</string>
```

- [ ] **Step 10: Run** the Verify command → as stated. Also `./gradlew :app:assembleDebug` → `BUILD SUCCESSFUL` (Hilt
  graph has `PushTokenSource`).

- [ ] **Step 11: Commit**

```bash
git add core/data/ app/src/main/java/app/ottermsg/ feature/settings/
oc -m "push: «Пробуждение через Google» switch (token withdrawn), notifications off = call pushes only (M9.1 push switches)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 29: Release app 0.9.0 + server 0.9.0 and rollout (each step asked first)

**Goal:** All of M9.1 (Tasks 10–19 and 20–28) is merged, every node runs server 0.9.0, then the phones get app 0.9.0.

**Findings closed:** C1, C13, C14, C18, C20 (Tasks 10–19), C15, C16, C17, C19, C21, C22, C23, C24, design limit 4 (in production)

**Files:**
- Modify: `otter-android/app/build.gradle.kts:35` (`versionCode = 11; versionName = "0.9.0"`)
- Modify: `docs/00-decisions.md` (DX entries of M9.1a and of this section, numbered by the coordinator; D68 fallback
  sentence superseded by D97), `docs/02-protocol.md:63,249,253` (`PUSH_TOKEN` row: `messages_off`, `withdrawn`;
  `push.register`/`push.status` notes), `docs/07-android-architecture.md` (receive limits, push switches),
  `docs/09-roadmap.md` (M9.1 done after rollout)
- Create (not in git): `otter-server/dist/news/0.9.0.md`
- No server source version: `make release VERSION=0.9.0` / `upgrade-all.sh 0.9.0` build it (never delete in `dist/`)

**Acceptance Criteria:**
- [ ] `otter-server`: `make check` ok; `go test ./internal/meshsim/ -count=3 -race` ok; scripts and bundle tests ok in
  a scratch copy. `otter-android`: `./gradlew test lintDebug assembleRelease` → `BUILD SUCCESSFUL`, APK
  release-signed (`apksigner verify --print-certs` shows the release certificate), `versionCode='11' versionName='0.9.0'`.
- [ ] `scripts/secrets-check.sh` → ok in all three repos immediately before each push.
- [ ] Merged `--no-ff` (all three repos) and pushed only after the owner's OK.
- [ ] **Every** node runs 0.9.0 before the APK is released (0.8.x nodes refuse withdrawn `PUSH_TOKEN` records and
  still send envelope batches with no byte cap).
- [ ] Both family phones on 0.9.0 via the news dialog; on one phone «Пробуждение через Google» off → the node log shows
  no token for it and `push.status` false; back on → token again; notifications off → a test message gives no push,
  a test call still rings.

**Verify:** `deploy/status.sh` → every node `0.9.0 active`; on a phone Settings → О приложении shows `0.9.0 (…)`;
`ssh root@eeee journalctl -u otter-node --since -10min | grep -E "push (sent|skipped)"` shows `reason=messages_off`
for the test message and `kind=call` sent for the test call.

**Steps:**

- [ ] **Step 1: Version** — `versionCode = 11; versionName = "0.9.0"` in `app/build.gradle.kts`; commit
  `oc -m "app: version 0.9.0 (11)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`.

- [ ] **Step 2: Docs** — decisions (coordinator's numbers), protocol rows, architecture notes as listed under Files;
  commit in `docs` with `oc -m "docs: M9.1 decisions, PUSH_TOKEN flags, receive limits" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`.

- [ ] **Step 3: Local checks (no server)**

```bash
cd ~/Documents/Projects/OttterMSG/otter-server
make check && go test ./internal/meshsim/ -count=3 -race
d=$(mktemp -d) && rsync -a --exclude dist --exclude .dev-mesh --exclude .vm ./ $d/srv/ && (cd $d/srv && mkdir -p dist && deploy/test/scripts_test.sh && deploy/test/bundle_test.sh)
cd ../otter-android && JAVA_HOME=~/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2 ./gradlew test lintDebug assembleRelease
apksigner verify --print-certs app/build/outputs/apk/release/app-release.apk | grep -v "CN=Android Debug"
aapt2 dump badging app/build/outputs/apk/release/app-release.apk | grep versionCode
for r in otter-server otter-android docs; do (cd ../$r && scripts/secrets-check.sh); done
```

Expected: every Go package `ok`, `scripts test: ok`, `bundle test: ok`, `BUILD SUCCESSFUL`, release certificate,
`versionCode='11' versionName='0.9.0'`, three `secrets check: ok`. (`keystore.properties` signs the APK; never print
or copy the keystore or its passwords.) Optional, ask first: dev mesh + two emulators: send a message with the
receiver's notifications off (no push line), place a call (call push sent), switch Google wake off (token row
emptied: `bin/otter-node --dir .dev-mesh/n1 …` per `scripts/dev-mesh.sh`).

- [ ] **Step 4: Ask the owner → merge** (summary first: findings closed, test counts, APK size, open owner questions)

```bash
for r in otter-server otter-android docs; do
  git -C ~/Documents/Projects/OttterMSG/$r checkout main && git -C ~/Documents/Projects/OttterMSG/$r merge --no-ff --no-commit m9-1-client
  (cd ~/Documents/Projects/OttterMSG/$r && oc -m "Merge M9.1: the phone trusts no node (app 0.9.0, server 0.9.0)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>")
done
# after a second OK, secrets checks first:
for r in otter-server otter-android docs; do (cd ~/Documents/Projects/OttterMSG/$r && scripts/secrets-check.sh && git push origin main); done
```

- [ ] **Step 5: Ask the owner → build the server release** (local, writes `dist/`):
  `cd otter-server && make release VERSION=0.9.0 && ls dist/otter-node_0.9.0_linux_*`.

- [ ] **Step 6: Ask the owner → upgrade eeee**: `deploy/upgrade-all.sh 0.9.0 --only eeee --no-news --no-turn` →
  `eeee upgraded 0.8.3 → 0.9.0` (exit 2 = rolled back: stop and read; 3 = act now). Then `deploy/status.sh`;
  check the host's other services still answer (`ssh root@eeee ss -ltnp`).

- [ ] **Step 7: Ask the owner → upgrade ru-1** the same way (`--only ru-1`), then `deploy/status.sh` shows both
  `0.9.0 active`. Do not continue while any node is older.

- [ ] **Step 8: Write the news** `otter-server/dist/news/0.9.0.md` (RU and EN, plain words): «Выдра 0.9.0: телефон
  сам проверяет всё, что приходит от серверов; новые переключатели в Настройки → Уведомления: можно выключить
  пробуждение через Google (тогда звонки не приходят, пока Выдра закрыта); с выключенными уведомлениями звонки всё
  равно приходят» / the English equivalent. Show it to the owner.

- [ ] **Step 9: Owner runs** `deploy/release-apk.sh 0.9.0 <path to app-release.apk>` (refuses debug-signed APKs and
  nodes older than 0.8.3) with the news dialog for `dist/news/0.9.0.md`; phones update via «Обновить».

- [ ] **Step 10: Owner, on the phones** (asked first): check the acceptance rows above (switches, message vs call
  push, `push.status` warning on the caller's side when the callee's Google wake is off); open «Журнал подключений» →
  «Поделиться» and confirm no IP or host is in the text. Record results in `docs/superpowers/` manual checklist of
  M9.1 (or the roadmap note).

- [ ] **Step 11: Roadmap** — mark M9.1 done in `docs/09-roadmap.md` (date, app 0.9.0 / 11, server 0.9.0, nodes);
  `oc -m "roadmap: M9.1 rolled out" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`; push after the
  owner's OK.

---

**Owner questions (M9.1b)**

1. **Client frame limit 4 MiB instead of 1 MiB?** Recommended: **4 MiB**. A 1 MiB limit would cut every `apk.get`
   answer (the APK chunk alone is 1 MiB); with Task 21 the largest honest frame is ~1.1 MiB, and 4 MiB is what the
   node's own Go client uses.
2. **Residual: one huge uncompressed WebSocket frame.** OkHttp reads a whole message into memory before the app can
   check its size, and offers no limit; the phone now refuses compression, so a hostile node must really send the
   bytes (hundreds of MB to exhaust memory). Recommended: **accept for M9.1** and record it in D93; revisit in M9.4
   only if it is ever seen (options: Conscrypt engine sockets to count bytes below TLS, ~4 MB more APK, or our own
   WebSocket frame reader).
3. **Withdrawn token: erase the token but keep the row** (so an older token record replicated later cannot restore
   it) rather than deleting the row. The old `PUSH_TOKEN` records that hold the token string stay in the replicated
   record log until M9.2's per-author compaction (C8). Recommended: **yes**; M9.2 compacts superseded `PUSH_TOKEN`
   records on every node.
4. **Announcements («Новости Выдры») to a device with notifications off:** treated like messages (no push).
   Recommended: **yes**; they arrive at the next connection.
5. **Link-only inviter is not messaged until the directory confirms it** (a few seconds after registration on a
   healthy network; a node that hides the inviter's entry blocks that chat until another node serves it).
   Recommended: **yes**; it is the only way the link fields cannot be used for a MITM.
6. **«Пробуждение через Google» shown when Google services are missing** (no effect then). Recommended: **show it
   anyway** (the screen already says the phone is in battery-saver mode); simpler and honest.

---

## M9.2a — Nodes cannot change who is a member

Branch `m9-2-membership` in `otter-server`, `otter-android`, `docs`. Server 0.9.1, app 0.9.1 / versionCode 12.
Findings: C2, design limit 3 + C6, C5, C12.

**Proto additions** (beyond the fixed allocations; both copies of every file stay identical):

| File | Addition | Why |
|---|---|---|
| `records.proto` `DirectoryEntry` | `bytes invite_record = 10;` (fixed) | the inviter's full signed `INVITE` record |
| `records.proto` `DirectoryEntry` | **field 11 renamed `invite_proof`** (`bytes`, number unchanged, see owner question 1) | Ed25519 signature by the invite's one-time key over the new account; replaces the raw secret |
| `records.proto` `Invite` | `bytes redeem_pub = 3;` | public half of the one-time key derived from the link secret |
| `invite.proto` `InviteBundle` | `Record invite = 8;` | the signed `INVITE` record travels in the link |
| `manifest.proto` `Manifest` | `repeated bytes founding_members = 8;` | user_ids admitted by the admin without an invite chain (accounts from before M9.2) |
| `api.proto` `BackupAuthResponse` | `repeated string candidates = 10;` | a clashed username: the `name#tag` forms to try (C12) |
| `api.proto` | `message AdminRequest { int64 ts_ms = 1; bytes signature = 2; }` | network-key signature over the session nonce for `admin.users` |
| RPC (no new message) | `network.publish` (public, `RecordRequest` → `Empty`) | accepts network-signed `REVOCATION` / `INVITE_RIGHTS` |
| RPC | `admin.users` (public, `AdminRequest` → `RecordBatch`) | the admin's verified member list |
| `MessageKind` (Room int, no migration) | `SYSTEM_MEMBER = 7` | «Участник удалён» line in a 1:1 chat |

No new `RecordType`, no new `Status`. Server migration `0011_membership.sql` (coordinator: renumber to the next free
number after M9.0/M9.1 migrations).

**Verified facts**

| Question | Answer | Source |
|---|---|---|
| Who may sign `REVOCATION` / `INVITE_RIGHTS`? | Only the network (admin) key: author must be `ID16(network_pub)` | `internal/records/validate.go:74-76,112-116` |
| Are they applied? | No: `applyTyped` has no case for either; `users.revoked` is never written | `internal/store/typed.go:33-307`, `migrations/0001_init.sql` |
| What already honours `users.revoked`? | `VerifyLogin`, `signerKey` (author revoked), `Submit` recipients, `FetchPrekeys`, `BackupFor` | `service/service.go:204`, `records/validate.go:127-129,159-161`, `service/submit.go:40`, `service.go:261`, `store/backups.go:21` |
| What ignores it? | `turn.credentials`, `directory.sync`, `blob.get`, open sessions | `service/calls.go:171-178`, `gateway/methods.go:141-146,177-190` |
| Session registry | `Gateway.sessions` map; `dropReplaced` shows the close pattern (`cancel` + `conn.Close`) | `gateway/gateway.go:26-59`, `gateway/session.go:71-79` |
| A replicated record by a revoked author | `invalid()` maps `records.ErrRevoked` to `ErrRevoked`, which is not `ErrInvalid`, so the peer session stops and retries forever | `service/errors.go:24-29`, `service/replicated.go:17-38`, `replication/session.go:196-200` |
| Where `can_invite` comes from | the applicant's own entry | `store/typed.go:401-405` |
| Invite single use | `invites.used_by` per node; replicated `INVITE_USED` never fails | `service/register.go:23-35`, `store/typed.go:52-64` |
| Username clash rank | `registered_ms` (self-claimed), recomputed on every new version | `store/typed.go:361-410` |
| Replicated record with `ErrInvalid` | logged and skipped, cursor advances | `replication/session.go:196-202` |
| Bootstrap invite | network-signed `INVITE`, imported with `otter-node import` | `admin/invite.go:49-92`, `cmd/otter-admin/main.go:387-404` |
| Link contents | network pub, manifest, secret, inviter contact; **no `INVITE` record** | `proto/otter/v1/invite.proto`, `InviteRepository.kt:44-63` |
| Registration sends the raw secret to the node | yes (`RegisterRequest.invite_secret`) | `Registration.kt:103-127`, `api.proto:65-70` |
| Android contact `revoked` column | exists; `DirectorySync` always writes `false` | `ContactEntity.kt:16`, `DirectorySync.kt:55` |
| Group rotation on removal | `GroupApplier` deletes `my_distribution` and `sender_key_shared` when a member leaves the state | `GroupApplier.kt:133-138` |
| Groups of a member | `GroupDao.groupsWithMember(userId)` | `GroupDao.kt:30` |
| Clash loser's stored name | literally `name#<hex(user_id[:4])>` (8 hex), so `BackupFor("name#hex")` already finds the loser | `store/typed.go:349-351`, `store/backups.go:17-30` |
| TURN auth hook | our `auth` wrapper runs on every authenticated TURN request | `turnsrv/server.go:221-229` |
| Migrations | `0001`…`0008` | `internal/store/migrations/` |
| Proto codegen | `make gen` (`buf generate`); Android copies the `.proto` files | `otter-server/Makefile:9-13` |

**Decisions to record**

- **D99 — Revocation and invite rights are state (C2).** A network-signed `REVOCATION{user_id, reason}` is applied in
  the same transaction that stores it, on the node that accepts it and on every node it replicates to: the account is
  marked revoked, its mailbox, prekeys and push tokens are deleted, its open sessions are closed, it cannot log in,
  submit, invite, fetch blobs or get TURN credentials (refused also on TURN refresh). Revocations are permanent (no
  un-revoke record); the earliest `created_ms` of several revocations of one user is kept. `INVITE_RIGHTS{user_id,
  can_invite, version}`: the highest version wins; equal versions: "no" wins. Records of a revoked author that
  arrive later by replication are skipped (no stall). `directory.sync` also returns all `REVOCATION` and
  `INVITE_RIGHTS` records, so phones verify them with the network key. `otter-admin user list/revoke/invite-rights`.
- **D100 — The invite chain travels with the account (limit 3, C6).** The link carries the inviter's signed `INVITE`
  (with `redeem_pub` = Ed25519 public key of `HKDF-SHA256(secret, info "otter/invite-redeem/v1")`). The new account's
  directory entry carries that record (`invite_record`) and `invite_proof` = Ed25519 signature by the redeem key over
  `"otter-invite-redeem-v1" ‖ invite_id ‖ user_id ‖ account_pub`. The raw secret never leaves the invitee's phone.
  Every node checks, for any entry of a user it does not know (registration **and** replication): `INVITE` signed by
  the network key or by a known member; proof valid; `invite.created_ms ≤ registered_ms ≤ invite.expires_ms`; the
  inviter was not revoked and had invite rights **as of the invite's `created_ms`** (deterministic on every node).
  A registration on a node additionally needs the invite unexpired now and the inviter allowed now. No chain →
  refused (`INVALID`), except user_ids in the manifest's `founding_members`. Inviter not yet known → `RETRY_LATER`.
  Later versions copy both fields (like `registered_ms`).
- **D101 — Who may invite.** `DirectoryEntry.can_invite` is ignored. Default rights: accounts invited by the network
  key (bootstrap) and founding members may invite; accounts invited by a member may not, until the admin signs
  `INVITE_RIGHTS`. A newer `INVITE_RIGHTS` overrides the default.
- **D102 — Single use network-wide (C5).** Of all accounts that redeemed one `invite_id`, the one with the lowest
  `SHA-256(invite_proof)` (then `user_id`) stays; every other one is disabled on every node exactly like a revoked
  account (reason `duplicate invite`). A node refuses a second local redemption outright. Phones apply the same
  rule to the directory batch; the inviter's phone shows the notice in the disabled account's chat. (The rank is the
  proof hash rather than the entry record hash because the entry changes with every profile version; Ed25519
  signatures are deterministic and Go rejects non-canonical ones, so the proof hash is stable.)
- **D103 — Username clash rank and restore (C12, revises D31/D40).** The clash rank is fixed when the account is
  admitted: the `INVITE` record's `created_ms` (signed by the inviter, not the applicant); founding members keep their
  `registered_ms` rank. Later versions never change it. Every username that ever clashed is remembered
  (`username_clashes`). `backup.auth` with such a plain name returns `candidates` (`name#<8 hex>` of every account
  sharing it) and no salt; `backup.fetch` with it → `CONFLICT`. Both `name#tag` forms are accepted (the winner's and
  the loser's). The phone tries every candidate with the typed password, so nobody needs to know their tag.
- **D104 — Phones verify membership themselves.** A directory entry becomes a *new* contact only if it is a founding
  member (signed manifest) or its invite chain verifies (inviter = network key or an already accepted member);
  `REVOCATION` records are verified with the network key. A revoked contact: 1:1 chat shows «Участник удалён» instead
  of the composer, no call button, outbox items to it fail, envelopes from it are dropped; every group containing it
  rotates our sender key, and the lowest-id admin of each group removes it from the signed state.

### Task 30: Proto, invite redeem key and cross-language vectors

**Goal:** Both repos get the M9.2 proto fields and one shared definition of the invite redeem key and proof, pinned by vectors.
**Findings closed:** none alone (groundwork for C2, C5, C6, C12, limit 3).

**Files:**
- Modify: `otter-server/proto/otter/v1/records.proto` (`DirectoryEntry` 43-53, `Invite` 66-69), `invite.proto`,
  `manifest.proto`, `api.proto` (`BackupAuthResponse` 124-129, new `AdminRequest`); regenerate `internal/proto/otterv1/*.pb.go`
- Create: `otter-server/internal/keys/invite.go`, `otter-server/internal/records/invite.go`
- Modify: `otter-server/internal/vectors/vectors_test.go` (`V1`, `generate`), `otter-server/testdata/vectors/v1.json` (regenerated)
- Modify: `otter-android/core/proto/src/main/proto/otter/v1/{records,invite,manifest,api}.proto` (copies)
- Create: `otter-android/core/crypto/src/main/kotlin/app/ottermsg/core/crypto/InviteKeys.kt`
- Modify: `otter-android/core/{crypto,network,signal}/src/test/resources/vectors/v1.json` (copies),
  `otter-android/core/crypto/src/test/kotlin/app/ottermsg/core/crypto/VectorsTest.kt`
- Modify: `docs/02-protocol.md` (record table rows 70-71, `directory.sync` row 236, registration section)
- Test: `otter-server/internal/keys/keys_test.go`

**Acceptance Criteria:**
- [ ] `diff -r otter-server/proto/otter/v1 otter-android/core/proto/src/main/proto/otter/v1` prints nothing.
- [ ] `keys.InviteRedeemKey(secret)` and `InviteKeys.redeemKey(secret)` give the same public key; `RedeemMessage` is
  byte-identical in Go and Kotlin (vector `invite_proof_hex` verifies in Kotlin).
- [ ] `records.Redeem(entry, inviteRecord, secret)` fills `invite_record` and `invite_proof`.
- [ ] Old vectors unchanged (only new keys appended to `v1.json`).

**Verify:** `cd otter-server && go test ./internal/keys/ ./internal/vectors/ -count=1` → `ok`;
`cd otter-android && ./gradlew :core:crypto:testDebugUnitTest --tests '*VectorsTest*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Proto.** In `records.proto`:

```proto
message DirectoryEntry {
  // … fields 1-9 unchanged …
  bytes invite_record = 10; // M9.2 (D100): the inviter's signed INVITE Record (serialized); copied into later versions
  bytes invite_proof = 11;  // M9.2 (D100): Ed25519 by the invite's redeem key over RedeemMessage(invite_id, user_id, account_pub)
}

message Invite {
  bytes invite_id = 1;   // SHA-256(secret)
  int64 expires_ms = 2;
  bytes redeem_pub = 3;  // M9.2 (D100): Ed25519 public key of HKDF-SHA256(secret, "otter/invite-redeem/v1")
}
```

  `invite.proto`: `Record invite = 8; // M9.2: the signed INVITE (its redeem_pub matches secret)`.
  `manifest.proto`: `repeated bytes founding_members = 8; // M9.2 (D100): user_ids admitted without an invite chain`
  (leave 7 to M9.3). `api.proto`:

```proto
message BackupAuthResponse {
  bytes salt = 1;
  uint32 kdf_m_kib = 2;
  uint32 kdf_t = 3;
  uint32 kdf_p = 4;
  repeated string candidates = 10; // M9.2 (D103): the name is shared after a clash; retry with each "name#tag"
}

// admin.users: Ed25519 by the network key over AdminAuthMessage(node_id, hello nonce, ts_ms).
message AdminRequest {
  int64 ts_ms = 1;
  bytes signature = 2;
}
```

  Copy the four files to `otter-android/core/proto/src/main/proto/otter/v1/`. Run `cd otter-server && make gen`.

- [ ] **Step 2: Failing test** — append to `otter-server/internal/keys/keys_test.go`:

```go
func TestInviteRedeemKey(t *testing.T) {
	secret := bytes.Repeat([]byte{7}, 32)
	k1, err := InviteRedeemKey(secret)
	if err != nil {
		t.Fatal(err)
	}
	k2, _ := InviteRedeemKey(secret)
	if !k1.Equal(k2) {
		t.Fatal("not deterministic")
	}
	if _, err := InviteRedeemKey(secret[:31]); err == nil {
		t.Fatal("short secret accepted")
	}
	m := RedeemMessage(bytes.Repeat([]byte{1}, 32), bytes.Repeat([]byte{2}, 16), bytes.Repeat([]byte{3}, 32))
	if len(m) != len("otter-invite-redeem-v1")+80 || string(m[:22]) != "otter-invite-redeem-v1" {
		t.Fatalf("message %x", m)
	}
}
```

  (add `"bytes"` to the imports if missing). Run `go test ./internal/keys/ -run InviteRedeem` → FAIL (undefined).

- [ ] **Step 3: Implement** `otter-server/internal/keys/invite.go`:

```go
package keys

import (
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/sha256"
	"fmt"
)

const (
	InfoInviteRedeem = "otter/invite-redeem/v1"
	redeemContext    = "otter-invite-redeem-v1"
)

// InviteRedeemKey derives an invite's one-time signing key from the 32-byte secret in the link (D100). Only the
// invitee's phone holds the secret; nodes see the public key (in the INVITE) and one signature (the proof).
// Must match Android InviteKeys.redeemKey.
func InviteRedeemKey(secret []byte) (ed25519.PrivateKey, error) {
	if len(secret) != 32 {
		return nil, fmt.Errorf("invite secret must be 32 bytes, got %d", len(secret))
	}
	k, err := hkdf.Key(sha256.New, secret, nil, InfoInviteRedeem, ed25519.SeedSize)
	if err != nil {
		return nil, err
	}
	return ed25519.NewKeyFromSeed(k), nil
}

// RedeemMessage is what the redeem key signs: it binds one redemption to one account.
func RedeemMessage(inviteID, userID, accountPub []byte) []byte {
	m := make([]byte, 0, len(redeemContext)+len(inviteID)+len(userID)+len(accountPub))
	m = append(m, redeemContext...)
	m = append(m, inviteID...)
	m = append(m, userID...)
	return append(m, accountPub...)
}
```

  and `otter-server/internal/records/invite.go` (used by the admin, tests and as the Go reference of the app's code):

```go
package records

import (
	"crypto/ed25519"
	"crypto/sha256"

	"google.golang.org/protobuf/proto"
	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
)

// InvitePayload is the INVITE payload for a link secret (D100).
func InvitePayload(secret []byte, expiresMs int64) (*pb.Invite, error) {
	k, err := keys.InviteRedeemKey(secret)
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(secret)
	return &pb.Invite{InviteId: sum[:], ExpiresMs: expiresMs, RedeemPub: k.Public().(ed25519.PublicKey)}, nil
}

// Redeem fills the invite chain of a new account's directory entry: the inviter's signed INVITE and the proof made
// with the key derived from the link secret. e.UserId and e.AccountPub must be set.
func Redeem(e *pb.DirectoryEntry, invite *pb.Record, secret []byte) error {
	k, err := keys.InviteRedeemKey(secret)
	if err != nil {
		return err
	}
	raw, err := proto.Marshal(invite)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(secret)
	e.InviteRecord = raw
	e.InviteProof = ed25519.Sign(k, keys.RedeemMessage(sum[:], e.UserId, e.AccountPub))
	return nil
}
```

- [ ] **Step 4: Vectors.** In `vectors_test.go` append to `V1` (after `TLSSPKIPinHex`, so older keys keep their order):

```go
	InviteSecretHex    string `json:"invite_secret_hex"`
	InviteRedeemPubHex string `json:"invite_redeem_pub_hex"`
	InviteProofHex     string `json:"invite_proof_hex"`
```

  and in `generate`, before `out, _ := json.MarshalIndent(v, "", "  ")`:

```go
	isec := seq(32, 9) // the secret already used in v.InviteLink
	rk, err := keys.InviteRedeemKey(isec)
	if err != nil {
		t.Fatal(err)
	}
	isum := sha256.Sum256(isec)
	v.InviteSecretHex = hex.EncodeToString(isec)
	v.InviteRedeemPubHex = hex.EncodeToString(rk.Public().(ed25519.PublicKey))
	v.InviteProofHex = hex.EncodeToString(ed25519.Sign(rk, keys.RedeemMessage(isum[:], keys.ID16(accPub), accPub)))
```

  `OTTER_WRITE_VECTORS=1 go test ./internal/vectors/ -run VectorsV1` then `git diff testdata/vectors/v1.json` must show
  only three added lines (the `InviteBundle` of `invite_link` has no `invite` field set, so it is unchanged). Copy the
  file to the three Android `src/test/resources/vectors/` folders.

- [ ] **Step 5: Kotlin failing test** — append to `VectorsTest.kt`:

```kotlin
    @Test fun inviteRedeemMatchesGo() {
        val secret = hex(v.getValue("invite_secret_hex"))
        val k = InviteKeys.redeemKey(secret)
        assertArrayEquals(hex(v.getValue("invite_redeem_pub_hex")), k.publicKey)
        val inviteId = java.security.MessageDigest.getInstance("SHA-256").digest(secret)
        val accPub = hex(v.getValue("account_pub_hex"))
        val msg = InviteKeys.redeemMessage(inviteId, hex(v.getValue("user_id_hex")), accPub)
        assertTrue(Ed25519.verify(k.publicKey, msg, hex(v.getValue("invite_proof_hex"))))
        assertArrayEquals(hex(v.getValue("invite_proof_hex")), k.sign(msg)) // Ed25519 is deterministic
    }
```

  Run → FAIL (`InviteKeys` unresolved).

- [ ] **Step 6: Implement** `core/crypto/src/main/kotlin/app/ottermsg/core/crypto/InviteKeys.kt`:

```kotlin
package app.ottermsg.core.crypto

import com.google.crypto.tink.subtle.Hkdf

/** The invite's one-time key (D100). Must match Go `keys.InviteRedeemKey` / `keys.RedeemMessage`. */
object InviteKeys {
    const val INFO_REDEEM = "otter/invite-redeem/v1"
    private const val CONTEXT = "otter-invite-redeem-v1"

    fun redeemKey(secret: ByteArray): Ed25519.KeyPair {
        require(secret.size == 32) { "invite secret must be 32 bytes" }
        return Ed25519.keyPairFromSeed(Hkdf.computeHkdf("HMACSHA256", secret, ByteArray(0), INFO_REDEEM.toByteArray(), 32))
    }

    fun redeemMessage(inviteId: ByteArray, userId: ByteArray, accountPub: ByteArray): ByteArray =
        CONTEXT.toByteArray() + inviteId + userId + accountPub
}
```

  Run the Kotlin test → PASS; `go test ./internal/keys/ ./internal/vectors/` → PASS.

- [ ] **Step 7: Protocol doc.** In `docs/02-protocol.md`: row 70 → "`REVOCATION` | network | user_id, reason | applied on accept and
  replication: no login/submit/invite/TURN, sessions closed, mailbox/prekeys/push dropped (D99)"; row 71 →
  "`INVITE_RIGHTS` | network | user_id, can_invite, version | highest version wins, ties → false; overrides the default
  rights (D101)"; row 236 → "`directory.sync` | current entries of all users (revoked included) + every `REVOCATION` and
  `INVITE_RIGHTS`"; in the registration section describe `invite_record`, `invite_proof`, `redeem_pub`,
  `InviteBundle.invite`, `founding_members`, `network.publish`, `admin.users`, `BackupAuthResponse.candidates`.

- [ ] **Step 8: Commit** (one per repo):

```bash
cd otter-server && git add proto internal/proto internal/keys/invite.go internal/keys/keys_test.go internal/records/invite.go internal/vectors testdata/vectors/v1.json
oc -m "proto: invite chain fields, founding members, admin request; invite redeem key (M9.2)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
cd ../otter-android && git add core/proto core/crypto core/network/src/test/resources core/signal/src/test/resources
oc -m "proto: invite chain fields; InviteKeys matches the Go vectors (M9.2)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
cd ../docs && git add 02-protocol.md
oc -m "protocol: invite chain, revocation and invite rights state, admin RPCs (M9.2)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 31: Node — REVOCATION and INVITE_RIGHTS change the store

**Goal:** Accepting or replicating a network-signed revocation or invite-rights record changes `users` in the same transaction, in any arrival order.
**Findings closed:** C2 (store part), C6 (rights no longer from the entry)

**Files:**
- Create: `otter-server/internal/store/migrations/0011_membership.sql`, `otter-server/internal/store/membership.go`
- Modify: `otter-server/internal/store/typed.go` (`applyTyped` 33-307, `applyDirectoryEntry` 361-411),
  `otter-server/internal/store/apply.go` (`Item`, `item`, `toItem` 19-59), `otter-server/internal/records/validate.go` (`checkPayload` 166-234)
- Test: `otter-server/internal/store/membership_test.go`, `otter-server/internal/records/validate_test.go`

**Acceptance Criteria:**
- [ ] A `REVOCATION` sets `users.revoked=1`, `revoke_reason`, deletes the user's `mailbox`, `prekeys`, `push_tokens` rows.
- [ ] A `REVOCATION` that arrives **before** the user's directory entry still revokes the user when the entry arrives.
- [ ] `INVITE_RIGHTS`: highest version wins regardless of order; equal versions → `can_invite=0`; rights that arrive
  before the entry apply when it arrives.
- [ ] A new user's `can_invite` never comes from `DirectoryEntry.can_invite`.
- [ ] `CanInviteAt(user, at)` answers from rights with `created_ms ≤ at`, else the user's default.
- [ ] Validator: `REVOCATION` needs a 16-byte `user_id` and a reason ≤ 200 runes; `INVITE_RIGHTS` a 16-byte `user_id` and `version > 0`.

**Verify:** `cd otter-server && go test ./internal/store/ ./internal/records/ -count=1 -race` → `ok`

**Steps:**

- [ ] **Step 1: Migration** `internal/store/migrations/0011_membership.sql`:

```sql
-- M9.2 (D99-D103): membership state from network-signed records and invite chains.
CREATE TABLE revocations(user_id BLOB PRIMARY KEY, created_ms INTEGER NOT NULL, reason TEXT NOT NULL);
CREATE TABLE invite_rights(user_id BLOB NOT NULL, version INTEGER NOT NULL, created_ms INTEGER NOT NULL,
                           can_invite INTEGER NOT NULL, PRIMARY KEY(user_id, version));
CREATE TABLE redemptions(invite_id BLOB NOT NULL, user_id BLOB NOT NULL, rank BLOB NOT NULL,
                         PRIMARY KEY(invite_id, user_id));
CREATE TABLE username_clashes(username TEXT PRIMARY KEY);
ALTER TABLE users ADD COLUMN revoke_reason TEXT NOT NULL DEFAULT '';
-- default rights when no INVITE_RIGHTS exists; accounts from before M9.2 keep what they had
ALTER TABLE users ADD COLUMN invite_default INTEGER NOT NULL DEFAULT 1;
UPDATE users SET invite_default = can_invite;
INSERT OR IGNORE INTO username_clashes(username)
  SELECT substr(username, 1, instr(username, '#') - 1) FROM users WHERE username_conflict = 1;
```

- [ ] **Step 2: Failing tests** `internal/store/membership_test.go`:

```go
package store

import (
	"context"
	"testing"

	pb "ottermsg/server/internal/proto/otterv1"
)

var netAuthor = []byte("network-network1")

func revocation(t *testing.T, user []byte, created int64) Item {
	return mkItemAt(t, pb.RecordType_REVOCATION, netAuthor, &pb.Revocation{UserId: user, Reason: "left"}, created)
}

func rights(t *testing.T, user []byte, can bool, version uint64, created int64) Item {
	return mkItemAt(t, pb.RecordType_INVITE_RIGHTS, netAuthor, &pb.InviteRights{UserId: user, CanInvite: can, Version: version}, created)
}

func TestRevocationAppliesInBothOrders(t *testing.T) {
	ctx := context.Background()
	for _, order := range []string{"entry-first", "revocation-first"} {
		s, _ := open(t)
		u := r16()
		e := mkItemAt(t, pb.RecordType_DIRECTORY_ENTRY, u, entry(u, "anna", 1), 1000)
		r := revocation(t, u, 2000)
		if order == "entry-first" {
			replicate(t, s, e)
			if err := s.write(ctx, func(ctx context.Context, tx *sql.Tx) error { // a queued envelope and a push token
				_, err := tx.ExecContext(ctx, `INSERT INTO mailbox(user_id,device_id,record_key,origin_node,received_ms) VALUES(?,1,?,?,1)`, u, r16(), r16())
				if err != nil {
					return err
				}
				_, err = tx.ExecContext(ctx, `INSERT INTO push_tokens(user_id,device_id,kind,token,created_ms) VALUES(?,1,1,'t',1)`, u)
				return err
			}); err != nil {
				t.Fatal(err)
			}
			replicate(t, s, r)
		} else {
			replicate(t, s, r)
			replicate(t, s, e)
		}
		got, _ := s.UserByID(ctx, u)
		if got == nil || !got.Revoked {
			t.Fatalf("%s: not revoked: %+v", order, got)
		}
		var queued int
		if err := s.r.QueryRow(`SELECT COUNT(*) FROM mailbox WHERE user_id=?`, u).Scan(&queued); err != nil || queued != 0 {
			t.Fatalf("%s: mailbox kept (%d, %v)", order, queued, err)
		}
		if tok, _ := s.PushToken(ctx, u, 1); tok != "" {
			t.Fatalf("%s: push token kept", order)
		}
		if at, ok, _ := s.RevokedAt(ctx, u); !ok || at != 2000 {
			t.Fatalf("%s: revoked at %d %v", order, at, ok)
		}
	}
}

func TestInviteRightsNewestVersionWins(t *testing.T) {
	ctx := context.Background()
	s, _ := open(t)
	u := r16()
	replicate(t, s, rights(t, u, true, 2, 2000)) // before the entry
	e := entry(u, "anna", 1)
	e.CanInvite = false // ignored (C6)
	replicate(t, s, mkItemAt(t, pb.RecordType_DIRECTORY_ENTRY, u, e, 1000))
	if got, _ := s.UserByID(ctx, u); !got.CanInvite {
		t.Fatal("rights v2 not applied to the late entry")
	}
	replicate(t, s, rights(t, u, false, 1, 3000)) // older version arrives later: ignored
	if got, _ := s.UserByID(ctx, u); !got.CanInvite {
		t.Fatal("older version won")
	}
	replicate(t, s, rights(t, u, true, 3, 4000))
	replicate(t, s, rights(t, u, false, 3, 4001)) // same version, other value: "no" wins on every node
	if got, _ := s.UserByID(ctx, u); got.CanInvite {
		t.Fatal("tie must resolve to false")
	}
	if ok, _ := s.CanInviteAt(ctx, u, 2500); !ok {
		t.Fatal("as of 2500 the user could invite (v2)")
	}
	if ok, _ := s.CanInviteAt(ctx, u, 1500); ok {
		t.Fatal("as of 1500 no rights record existed and the default of an unadmitted entry is false")
	}
}

func TestEntryCanInviteIgnored(t *testing.T) {
	ctx := context.Background()
	s, _ := open(t)
	u := r16()
	replicate(t, s, mkItemAt(t, pb.RecordType_DIRECTORY_ENTRY, u, entry(u, "anna", 1), 1000)) // entry says CanInvite: true
	if got, _ := s.UserByID(ctx, u); got.CanInvite {
		t.Fatal("can_invite taken from the applicant's own entry (C6)")
	}
	v := r16()
	it := mkItemAt(t, pb.RecordType_DIRECTORY_ENTRY, v, entry(v, "boris", 1), 1000)
	it.Admission = &Admission{RankMs: 1000, CanInvite: true}
	if _, _, err := s.ApplyReplicatedItem(ctx, it, peer); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.UserByID(ctx, v); !got.CanInvite {
		t.Fatal("admission default not applied")
	}
}
```

  (imports: add `"database/sql"`). In `internal/records/validate_test.go` add table cases next to the existing
  `INVITE_USED` ones: network-signed `REVOCATION` with `UserId: make([]byte, 15)` → `ErrBadPayload`; reason of 201
  runes → `ErrBadPayload`; `INVITE_RIGHTS` with `Version: 0` → `ErrBadPayload`; well-formed ones → nil. Run →
  FAIL (no `RevokedAt`, `CanInviteAt`, `ApplyReplicatedItem`, `Admission`; validator accepts bad payloads).

- [ ] **Step 3: Validator.** In `checkPayload` add:

```go
	case pb.RecordType_REVOCATION:
		var r pb.Revocation
		if err := proto.Unmarshal(b.Payload, &r); err != nil || len(r.UserId) != 16 || !utf8.ValidString(r.Reason) ||
			utf8.RuneCountInString(r.Reason) > 200 || b.ExpiresMs != 0 {
			return ErrBadPayload
		}
	case pb.RecordType_INVITE_RIGHTS:
		var r pb.InviteRights
		if err := proto.Unmarshal(b.Payload, &r); err != nil || len(r.UserId) != 16 || r.Version == 0 || b.ExpiresMs != 0 {
			return ErrBadPayload
		}
```

- [ ] **Step 4: Store items carry the admission.** In `apply.go`:

```go
// Item is a validated record with its parsed body.
type Item struct {
	Record *pb.Record
	Body   *pb.RecordBody
	// Admission: for a DIRECTORY_ENTRY of a user this node does not know yet, what the service derived from its
	// invite chain (D100). nil for everything else (and in store tests: legacy rank, no invite rights).
	Admission *Admission
}

type item struct {
	key, raw []byte
	body     *pb.RecordBody
	origin   []byte
	fromPeer bool // replicated: business conflicts never fail
	adm      *Admission
}
```

  `toItem` ends with `return item{key: key, raw: raw, body: it.Body, origin: origin, adm: it.Admission}, nil`. Add:

```go
// ApplyReplicatedItem is ApplyReplicated for an item that may carry an Admission.
func (s *Store) ApplyReplicatedItem(ctx context.Context, in Item, from []byte) (int64, bool, error) {
	it, err := toItem(in, from)
	if err != nil {
		return 0, false, err
	}
	it.fromPeer = true
	r, err := s.submit(ctx, &applyReq{items: []item{it}})
	if err != nil {
		return 0, false, err
	}
	return r.seqs[0], r.applied[0], nil
}
```

  and make `ApplyReplicated` `return s.ApplyReplicatedItem(ctx, Item{Record: rec, Body: body}, from)`. `ApplyFrom`
  (apply.go:68) builds `Item{rec, body}` positionally: change it to `Item{Record: rec, Body: body}` (the new field
  breaks positional literals).

- [ ] **Step 5: Implement** `internal/store/membership.go`:

```go
package store

import (
	"context"
	"database/sql"
	"errors"

	pb "ottermsg/server/internal/proto/otterv1"
)

// ReasonDuplicateInvite is users.revoke_reason of an account that lost a double redemption (D102).
const ReasonDuplicateInvite = "duplicate invite"

// Admission is what the service derived from a new account's invite chain (D100).
type Admission struct {
	InviteID  []byte // nil for founding members
	Rank      []byte // SHA-256(invite_proof): the lowest keeps a doubly redeemed invite (D102)
	RankMs    int64  // username clash rank: the INVITE's created_ms, or registered_ms of a founding member (D103)
	CanInvite bool   // default invite rights: network-signed invite or founding member (D101)
}

// revokeUser disables an account on this node: no login, no queued mail, no new sessions with it, no wake-ups.
func revokeUser(ctx context.Context, tx *sql.Tx, user []byte, reason string) error {
	if _, err := tx.ExecContext(ctx, `UPDATE users SET revoked=1, revoke_reason=? WHERE user_id=? AND revoked=0`, reason, user); err != nil {
		return err
	}
	for _, q := range []string{`DELETE FROM mailbox WHERE user_id=?`, `DELETE FROM prekeys WHERE user_id=?`,
		`DELETE FROM push_tokens WHERE user_id=?`} {
		if _, err := tx.ExecContext(ctx, q, user); err != nil {
			return err
		}
	}
	return nil
}

func applyRevocation(ctx context.Context, tx *sql.Tx, b *pb.RecordBody, r *pb.Revocation) error {
	// several revocations of one user: the earliest time counts (it decides which of their invites still count)
	if _, err := tx.ExecContext(ctx, `INSERT INTO revocations(user_id,created_ms,reason) VALUES(?,?,?)
		ON CONFLICT(user_id) DO UPDATE SET created_ms=MIN(created_ms, excluded.created_ms)`, r.UserId, b.CreatedMs, r.Reason); err != nil {
		return err
	}
	return revokeUser(ctx, tx, r.UserId, r.Reason)
}

func applyInviteRights(ctx context.Context, tx *sql.Tx, b *pb.RecordBody, r *pb.InviteRights) error {
	if _, err := tx.ExecContext(ctx, `INSERT INTO invite_rights(user_id,version,created_ms,can_invite) VALUES(?,?,?,?)
		ON CONFLICT(user_id,version) DO UPDATE SET can_invite=MIN(can_invite, excluded.can_invite)`,
		r.UserId, r.Version, b.CreatedMs, boolInt(r.CanInvite)); err != nil {
		return err
	}
	_, err := tx.ExecContext(ctx, `UPDATE users SET can_invite=COALESCE(
		(SELECT can_invite FROM invite_rights WHERE user_id=?1 ORDER BY version DESC LIMIT 1), invite_default) WHERE user_id=?1`, r.UserId)
	return err
}

// RevokedAt returns the created_ms of the user's (earliest) revocation.
func (s *Store) RevokedAt(ctx context.Context, user []byte) (int64, bool, error) {
	var at int64
	err := s.r.QueryRowContext(ctx, `SELECT created_ms FROM revocations WHERE user_id=?`, user).Scan(&at)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, false, nil
	}
	return at, err == nil, err
}

// CanInviteAt reports the user's invite rights as of atMs: the newest INVITE_RIGHTS created at or before atMs,
// else the user's default (D101). Unknown user: false.
func (s *Store) CanInviteAt(ctx context.Context, user []byte, atMs int64) (bool, error) {
	var v sql.NullInt64
	err := s.r.QueryRowContext(ctx, `SELECT COALESCE(
		(SELECT can_invite FROM invite_rights WHERE user_id=?1 AND created_ms<=?2 ORDER BY version DESC LIMIT 1),
		(SELECT invite_default FROM users WHERE user_id=?1))`, user, atMs).Scan(&v)
	if err != nil {
		return false, err
	}
	return v.Valid && v.Int64 != 0, nil
}

// RevokedUsers lists every revoked or disabled account (TURN refusal, session closing).
func (s *Store) RevokedUsers(ctx context.Context) ([][]byte, error) {
	rows, err := s.r.QueryContext(ctx, `SELECT user_id FROM users WHERE revoked=1`)
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

// MembershipRecords returns every stored REVOCATION and INVITE_RIGHTS (serialized), oldest first, for directory.sync.
func (s *Store) MembershipRecords(ctx context.Context) ([][]byte, error) {
	rows, err := s.r.QueryContext(ctx, `SELECT raw FROM records WHERE type IN (?,?) ORDER BY created_ms, record_key`,
		int32(pb.RecordType_REVOCATION), int32(pb.RecordType_INVITE_RIGHTS))
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
```

  In `typed.go` `applyTyped` add:

```go
	case pb.RecordType_REVOCATION:
		var r pb.Revocation
		if err := proto.Unmarshal(b.Payload, &r); err != nil {
			return err
		}
		return applyRevocation(ctx, tx, b, &r)

	case pb.RecordType_INVITE_RIGHTS:
		var r pb.InviteRights
		if err := proto.Unmarshal(b.Payload, &r); err != nil {
			return err
		}
		return applyInviteRights(ctx, tx, b, &r)
```

  In `applyDirectoryEntry` replace the `if !exists { … INSERT … }` block (402-406) with `return insertUser(ctx, tx, it, e, name, conflict, rank, now)` and add:

```go
// insertUser creates the account row with the state the network-signed records and its admission give it (D99-D101).
func insertUser(ctx context.Context, tx *sql.Tx, it item, e *pb.DirectoryEntry, name string, conflict int, rank, now int64) error {
	def := it.adm != nil && it.adm.CanInvite
	revoked, reason := false, ""
	err := tx.QueryRowContext(ctx, `SELECT reason FROM revocations WHERE user_id=?`, e.UserId).Scan(&reason)
	switch {
	case err == nil:
		revoked = true
	case !errors.Is(err, sql.ErrNoRows):
		return err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO users(user_id,username,account_pub,entry_key,version,can_invite,invite_default,created_ms,entry_created_ms,
		   username_conflict,revoked,revoke_reason)
		 VALUES(?1,?2,?3,?4,?5,COALESCE((SELECT can_invite FROM invite_rights WHERE user_id=?1 ORDER BY version DESC LIMIT 1),?6),
		   ?6,?7,?8,?9,?10,?11)`,
		e.UserId, name, e.AccountPub, it.key, e.Version, boolInt(def), now, rank, conflict, boolInt(revoked), reason); err != nil {
		return err
	}
	if revoked {
		return revokeUser(ctx, tx, e.UserId, reason)
	}
	return nil
}
```

  (`redeem` for C5 is added in Task 34.) Run Step 2's tests → PASS; `go test ./internal/store/ ./internal/records/ -race` → all `ok`.

- [ ] **Step 6: Commit**

```bash
git add internal/store/migrations/0011_membership.sql internal/store/membership.go internal/store/membership_test.go internal/store/typed.go internal/store/apply.go internal/records/validate.go internal/records/validate_test.go
oc -m "store: apply REVOCATION and INVITE_RIGHTS in the same transaction; can_invite never from the entry (C2, C6)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 32: Node — revoked accounts lose every door; admin records published and replicated

**Goal:** A revocation closes the user's sessions and blocks login, every logged-in method and TURN on every node; only the network key can produce one.
**Findings closed:** C2 (enforcement), M8 note in `service/calls.go:172`

**Files:**
- Modify: `otter-server/internal/service/service.go` (`Notifier` 28-37, `nopNotifier`, `Service` fields, `Directory` 217-231),
  `internal/service/replicated.go` (`ApplyReplicated` 17-38, `afterApply` 52-79), `internal/service/calls.go` (`TurnCredentials`)
- Create: `otter-server/internal/service/membership.go` (`PublishNetworkRecord`, `RefreshRevoked`, `TurnTagRevoked`)
- Modify: `otter-server/internal/gateway/gateway.go` (add `Revoked`), `internal/gateway/methods.go` (`public`, `dispatch`)
- Modify: `otter-server/internal/turnsrv/server.go` (`Config`, `auth` 221-229), `cmd/otter-node/main.go` (wiring after `LoadManifest`, `startTurn`)
- Modify: `otter-server/internal/meshsim/harness_test.go` (`start`: `svc.RefreshRevoked`), `internal/service/service_test.go` (`rec.Revoked`)
- Test: `otter-server/internal/meshsim/membership_test.go` (new), `internal/service/membership_test.go` (new), `internal/turnsrv/server_test.go`

**Acceptance Criteria:**
- [ ] `network.publish` accepts a network-signed `REVOCATION`/`INVITE_RIGHTS` (idempotent), refuses any other type and any other signer with `INVALID`.
- [ ] After a revocation published on A replicates: on every node `auth.login` → `REVOKED`, an open session on C is closed
  within 1 s, `msg.send` to the user → `NOT_FOUND`, `turn.credentials` → `REVOKED`, TURN `Allocate` with the user's
  earlier credentials fails.
- [ ] A logged-in session of a revoked user gets `REVOKED` for any request even if the close raced.
- [ ] A forged revocation (signed by a node key, or by a member) is refused on publish and on replication; the user still logs in.
- [ ] A replicated record by an already revoked author is skipped (no stall of the peer session).
- [ ] `directory.sync` returns all entries plus every `REVOCATION` and `INVITE_RIGHTS`.

**Verify:** `cd otter-server && go test ./internal/meshsim/ -run 'Revocation|Forged' -count=1 -race && go test ./internal/service/ ./internal/turnsrv/ ./internal/gateway/ -count=1 -race` → `ok`

**Steps:**

- [ ] **Step 1: Failing meshsim tests** `internal/meshsim/membership_test.go`:

```go
package meshsim

import (
	"context"
	"crypto/ed25519"
	"errors"
	"testing"
	"time"

	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/service"
)

// tryLogin dials n and returns the status of a login as a.
func (s *sim) tryLogin(n *simNode, a *account) pb.Status {
	c := s.dial(n)
	defer c.close()
	ts := time.Now().UnixMilli()
	st, _ := c.call("auth.login", &pb.LoginRequest{UserId: a.id, DeviceId: 1, TsMs: ts,
		Signature: ed25519.Sign(a.priv, keys.AuthMessage(c.hello.NodeId, c.hello.Nonce, ts))}, nil)
	return st
}

// closed waits until the node closes c's connection.
func closed(t *testing.T, c *client) {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case _, ok := <-c.events:
			if !ok {
				return
			}
		case <-deadline:
			t.Fatal("session of a revoked user still open")
		}
	}
}

func (s *sim) revoke(a *account) *pb.Record {
	return s.sign(pb.RecordType_REVOCATION, keys.ID16(s.netPub), &pb.Revocation{UserId: a.id, Reason: "left the family"}, s.netPriv)
}

// C2: an admin-signed revocation published on one node reaches all; the account loses login, mail, sessions and TURN.
func TestRevocationReplicatesAndBlocks(t *testing.T) {
	s := newSimWith(t, map[string]nodeOpts{"c": {turn: true}}, "a", "b", "c")
	a, b, c := s.node("a"), s.node("b"), s.node("c")
	anna := s.register(a, "anna")
	boris := s.register(a, "boris")
	eventually(t, "users everywhere", func() bool { return s.all(func(n *simNode) bool { return n.knows(anna) && n.knows(boris) }) })
	borisC := s.login(c, boris)
	var creds pb.TurnCredentials
	borisC.mustCall("turn.credentials", &pb.Empty{}, &creds)

	pub := s.dial(a)
	pub.mustCall("network.publish", &pb.RecordRequest{Record: s.revoke(boris)}, nil)
	pub.mustCall("network.publish", &pb.RecordRequest{Record: s.revoke(boris)}, nil) // another record, same effect: still OK
	ctx := context.Background()
	eventually(t, "revoked everywhere", func() bool {
		return s.all(func(n *simNode) bool { u, _ := n.st.UserByID(ctx, boris.id); return u != nil && u.Revoked })
	})
	closed(t, borisC)
	for _, n := range s.nodes {
		if st := s.tryLogin(n, boris); st != pb.Status_STATUS_REVOKED {
			t.Fatalf("%s: login of a revoked user: %v", n.label, st)
		}
	}
	annaB := s.login(b, anna)
	r := s.signAs(anna, pb.RecordType_ENVELOPE, &pb.Envelope{SenderUser: anna.id, SenderDevice: 1, Kind: pb.Envelope_SIGNAL,
		Recipients: []*pb.Recipient{{User: boris.id, Device: 1, Content: []byte("x")}}})
	if st, _ := annaB.call("msg.send", &pb.RecordRequest{Record: r}, nil); st != pb.Status_STATUS_NOT_FOUND {
		t.Fatalf("send to revoked: %v", st)
	}
	if !c.svc.TurnTagRevoked(turnTag(boris.id)) {
		t.Fatal("TURN still accepts the revoked user's tag")
	}
	var batch pb.RecordBatch
	annaB.mustCall("directory.sync", &pb.Empty{}, &batch)
	if countType(&batch, pb.RecordType_REVOCATION) != 2 {
		t.Fatal("directory.sync must carry the revocations")
	}
}

// Threat model: a hostile node cannot revoke (or un-revoke) a member; its records are refused everywhere.
func TestForgedRevocationRefused(t *testing.T) {
	s := newSim(t, "a", "b")
	a, b := s.node("a"), s.node("b")
	anna := s.register(a, "anna")
	boris := s.register(a, "boris")
	eventually(t, "users on b", func() bool { return b.knows(anna) && b.knows(boris) })
	ctx := context.Background()
	forged := []*pb.Record{
		s.sign(pb.RecordType_REVOCATION, keys.ID16(s.netPub), &pb.Revocation{UserId: anna.id}, a.key), // network author, node key
		s.sign(pb.RecordType_REVOCATION, a.id, &pb.Revocation{UserId: anna.id}, a.key),                 // node-authored
		s.signAs(boris, pb.RecordType_REVOCATION, &pb.Revocation{UserId: anna.id}),                     // member-authored
		s.sign(pb.RecordType_INVITE_RIGHTS, keys.ID16(s.netPub), &pb.InviteRights{UserId: boris.id, CanInvite: true, Version: 9}, a.key),
	}
	for i, r := range forged {
		if _, err := b.svc.ApplyReplicated(ctx, a.id, r); !errors.Is(err, service.ErrInvalid) {
			t.Fatalf("forged #%d replicated: %v", i, err)
		}
		cl := s.dial(b)
		if st, _ := cl.call("network.publish", &pb.RecordRequest{Record: r}, nil); st != pb.Status_STATUS_INVALID {
			t.Fatalf("forged #%d published: %v", i, st)
		}
	}
	if st := s.tryLogin(b, anna); st != pb.Status_STATUS_OK {
		t.Fatalf("anna locked out by a forgery: %v", st)
	}
	// once really revoked, a newer entry or rights record by anyone cannot bring the account back
	pub := s.dial(b)
	pub.mustCall("network.publish", &pb.RecordRequest{Record: s.revoke(anna)}, nil)
	newer := s.signAs(anna, pb.RecordType_DIRECTORY_ENTRY, &pb.DirectoryEntry{UserId: anna.id, Username: "anna", DisplayName: "A",
		AccountPub: anna.priv.Public().(ed25519.PublicKey), IdentityPub: make([]byte, 33), IdentitySig: make([]byte, 64), Version: 2})
	if applied, err := b.svc.ApplyReplicated(ctx, a.id, newer); err != nil || applied {
		t.Fatalf("revoked author's record: applied=%v err=%v (must be skipped without error)", applied, err)
	}
	if st := s.tryLogin(b, anna); st != pb.Status_STATUS_REVOKED {
		t.Fatalf("revocation undone: %v", st)
	}
}

func countType(b *pb.RecordBatch, t pb.RecordType) int {
	n := 0
	for _, r := range b.Records {
		var body pb.RecordBody
		if proto.Unmarshal(r.Body, &body) == nil && body.Type == t {
			n++
		}
	}
	return n
}
```

  (imports also `"google.golang.org/protobuf/proto"` and `"ottermsg/server/internal/turnsrv"`; `turnTag := turnsrv.UserTag`
  as a package-level `var turnTag = turnsrv.UserTag`.) Run → FAIL (`network.publish` unknown method, `TurnTagRevoked` undefined).

- [ ] **Step 2: Failing TURN test** — append to `internal/turnsrv/server_test.go`:

```go
func TestRefusedUserCannotAllocate(t *testing.T) {
	secret := bytes.Repeat([]byte{6}, SecretLen)
	nl := &memLog{}
	cfg := testConfig(secret, 4, 41, nl)
	revoked := UserTag([]byte("boris-0000000000"))
	cfg.Refuse = func(tag string) bool { return tag == revoked }
	_, addr := startCfg(t, cfg)
	u, p := Credentials(secret, []byte("boris-0000000000"), time.Now(), time.Hour)
	if _, err := client(t, addr, u, p).Allocate(); err == nil {
		t.Fatal("revoked user allocated")
	}
	waitFor(t, "auth netlog line", func() bool { return nl.count(netlog.Auth) == 1 })
	ua, pa := Credentials(secret, []byte("anna-00000000000"), time.Now(), time.Hour)
	if _, err := client(t, addr, ua, pa).Allocate(); err != nil {
		t.Fatal(err)
	}
}
```

- [ ] **Step 3: TURN hook.** In `turnsrv.Config` add
  `Refuse func(userTag string) bool // revoked accounts (C2); nil = nobody`, and in `Start`'s `auth`:

```go
	auth := func(ra *turn.RequestAttributes) (string, []byte, bool) {
		if expired(ra.Username, cfg.now()) {
			nl(ra.SrcAddr, netlog.Auth, "expired or malformed credentials")
			return "", nil, false
		}
		if _, tag, _ := strings.Cut(ra.Username, ":"); cfg.Refuse != nil && cfg.Refuse(tag) {
			nl(ra.SrcAddr, netlog.Auth, "revoked user") // also on Refresh: a running relay stops at the next refresh
			return "", nil, false
		}
		return rest(ra)
	}
```

- [ ] **Step 4: Service.** `Notifier` gains `Revoked(user []byte) // the account was revoked or disabled: close its sessions`;
  add `func (nopNotifier) Revoked([]byte) {}` and `func (r *rec) Revoked([]byte) {}` in `service_test.go`.
  `Service` gains `revokedTags map[string]bool` (guarded by `mu`). Create `internal/service/membership.go`:

```go
package service

import (
	"context"
	"fmt"

	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/turnsrv"
)

// PublishNetworkRecord accepts an admin-signed REVOCATION or INVITE_RIGHTS (otter-admin user …). Idempotent.
func (s *Service) PublishNetworkRecord(ctx context.Context, rec *pb.Record) error {
	body, err := s.validator(nil).Validate(rec)
	if err != nil {
		return invalid(err)
	}
	if body.Type != pb.RecordType_REVOCATION && body.Type != pb.RecordType_INVITE_RIGHTS {
		return fmt.Errorf("%w: %v is not published here", ErrInvalid, body.Type)
	}
	_, applied, err := s.Store.ApplyFrom(ctx, rec, body, s.NodeID)
	if err != nil {
		return err
	}
	if applied {
		s.afterApply(ctx, body, nil)
	}
	return nil
}

// RefreshRevoked reloads the revoked accounts (TURN tags) and closes the sessions of newly revoked ones.
// Called at start and after every record that can revoke or disable an account.
func (s *Service) RefreshRevoked(ctx context.Context) {
	ids, err := s.Store.RevokedUsers(ctx)
	if err != nil {
		s.Log.Warn("revoked users not loaded", "err", err)
		return
	}
	tags := make(map[string]bool, len(ids))
	var fresh [][]byte
	s.mu.Lock()
	for _, id := range ids {
		t := turnsrv.UserTag(id)
		tags[t] = true
		if !s.revokedTags[t] {
			fresh = append(fresh, id)
		}
	}
	s.revokedTags = tags
	s.mu.Unlock()
	for _, id := range fresh {
		s.Notify.Revoked(id)
	}
}

// TurnTagRevoked implements turnsrv.Config.Refuse.
func (s *Service) TurnTagRevoked(tag string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.revokedTags[tag]
}
```

  `afterApply` (replicated.go): replace the `DIRECTORY_ENTRY` case and add one:

```go
	case pb.RecordType_DIRECTORY_ENTRY:
		s.RefreshRevoked(ctx) // a double redemption may have disabled an account (D102)
		s.Notify.Directory()
	case pb.RecordType_REVOCATION, pb.RecordType_INVITE_RIGHTS:
		s.RefreshRevoked(ctx)
		s.Notify.Directory() // phones re-sync and verify the record themselves (D104)
```

  `ApplyReplicated`: before `case err != nil:` add

```go
	case errors.Is(err, records.ErrRevoked):
		// the author was revoked after writing it; refusing with a retry would stall this peer forever
		s.Log.Debug("skipping record of a revoked author")
		return false, nil
```

  `TurnCredentials(user)` becomes `TurnCredentials(ctx context.Context, user []byte)` and checks first:

```go
	if k, ok := s.Store.UserKey(user); !ok || k.Revoked {
		return nil, ErrRevoked
	}
```

  (remove the M9 comment at `calls.go:172`; update the gateway call to `svc.TurnCredentials(ctx, s.userID())`).
  `Directory` appends the membership records:

```go
	more, err := s.Store.MembershipRecords(ctx)
	if err != nil {
		return nil, err
	}
	for _, raw := range append(raws, more...) { … unchanged body … }
```

- [ ] **Step 5: Gateway.** In `gateway.go`:

```go
// Revoked implements service.Notifier: every session of the account ends at once (C2).
func (g *Gateway) Revoked(user []byte) {
	for _, s := range g.snapshot() {
		if u := s.userID(); u != nil && bytes.Equal(u, user) {
			s.cancel()
			go s.conn.Close(websocket.StatusPolicyViolation, "revoked")
		}
	}
}
```

  In `methods.go` add `"network.publish": true, "admin.users": true` to `public` (admin.users is wired in Task 35), and at
  the top of `dispatch`, after the login check:

```go
	if u := s.userID(); u != nil {
		if k, ok := s.g.svc.Store.UserKey(u); ok && k.Revoked { // the close may have raced this request
			s.cancel()
			go s.conn.Close(websocket.StatusPolicyViolation, "revoked")
			return nil, service.ErrRevoked
		}
	}
```

  and a case:

```go
	case "network.publish":
		var r pb.RecordRequest
		if err := decode(req.Body, &r); err != nil {
			return nil, err
		}
		if r.Record == nil {
			return nil, fmt.Errorf("%w: record missing", service.ErrInvalid)
		}
		return &pb.Empty{}, svc.PublishNetworkRecord(ctx, r.Record)
```

- [ ] **Step 6: Wiring.** `cmd/otter-node/main.go`: right after `a.svc.LoadManifest(ctx)` (line ~285) add
  `a.svc.RefreshRevoked(ctx)`; in `startTurn` pass `Refuse: a.svc.TurnTagRevoked` in `turnsrv.Config{…}`.
  `meshsim/harness_test.go` `start`: after `svc.LoadManifest(...)` add `svc.RefreshRevoked(context.Background())`, and in
  `startTurn` pass `Refuse: n.svc.TurnTagRevoked` — `n.svc` is not set yet there, so pass a closure over the local `svc`:
  change `startTurn(n)` to `startTurn(n, svc)` and use `Refuse: svc.TurnTagRevoked`.

- [ ] **Step 7: Service unit test** `internal/service/membership_test.go`:

```go
package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
)

type stubTurn struct{}

func (stubTurn) Issue([]byte, time.Time) *pb.TurnCredentials { return &pb.TurnCredentials{Username: "u"} }

func TestRevokedGetsNoTurnAndRecordsAreSkipped(t *testing.T) {
	f := newFx(t)
	ctx := context.Background()
	f.svc.Turn = stubTurn{}
	anna := f.mustRegister(f.invite(nil, time.Hour), "anna")
	if _, err := f.svc.TurnCredentials(ctx, anna.id); err != nil {
		t.Fatal(err)
	}
	rev := sign(t, pb.RecordType_REVOCATION, keys.ID16(f.svc.NetworkPub), &pb.Revocation{UserId: anna.id}, f.netPriv)
	if err := f.svc.PublishNetworkRecord(ctx, rev); err != nil {
		t.Fatal(err)
	}
	if _, err := f.svc.TurnCredentials(ctx, anna.id); !errors.Is(err, ErrRevoked) {
		t.Fatalf("turn for revoked: %v", err)
	}
	inv := sign(t, pb.RecordType_INVITE, anna.id, &pb.Invite{InviteId: make([]byte, 32), ExpiresMs: time.Now().Add(time.Hour).UnixMilli()}, anna.priv)
	if applied, err := f.svc.ApplyReplicated(ctx, r16(), inv); err != nil || applied {
		t.Fatalf("revoked author's invite: applied=%v err=%v", applied, err)
	}
	if err := f.svc.PublishNetworkRecord(ctx, f.manifestRec(5)); !errors.Is(err, ErrInvalid) {
		t.Fatalf("manifest through network.publish: %v", err)
	}
}
```

- [ ] **Step 8: Run** all the tests above → PASS; `go test ./... -count=1 -race` → all `ok`.

- [ ] **Step 9: Commit**

```bash
git add internal/service internal/gateway internal/turnsrv cmd/otter-node/main.go internal/meshsim
oc -m "node: revoked accounts lose sessions, login, methods and TURN; network.publish for admin records (C2)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 33: Node — an account needs a verified invite chain on every node

**Goal:** Every node admits a new account (registered locally or replicated) only after verifying the invite chain itself; invite rights come only from the invite or `INVITE_RIGHTS`.
**Findings closed:** design limit 3, C6

**Files:**
- Modify: `otter-server/internal/service/membership.go` (add `admitChain`, `admitIfNew`, `founding`),
  `internal/service/register.go` (whole `Register`), `internal/service/replicated.go` (`ApplyReplicated`),
  `internal/service/service.go` (`ImportRecord` 296-307), `internal/service/submit.go` (`INVITE` case 44-47)
- Modify (test helpers): `internal/service/service_test.go` (`invite`, `registerReqWith` 85-131, `TestRegisterFlow`
  unknown-invite case 159-162, rights case 312-321), `internal/meshsim/harness_test.go` (`invite` 384-393),
  `internal/meshsim/client_test.go` (`account`, `register` 150-177), `internal/gateway/e2e_test.go` (`registerReq` 35-51
  and its callers), `internal/replication/replication_test.go` (`register` 168-190)
- Test: `otter-server/internal/service/membership_test.go`, `otter-server/internal/meshsim/membership_test.go`

**Acceptance Criteria:**
- [ ] A replicated entry of an unknown user with no chain → `INVALID`, user not stored; a founding member (manifest) is accepted without chain.
- [ ] Chain checks: wrong `INVITE` signature, proof made for another account (copied chain), proof by a wrong key,
  `registered_ms` outside the invite's lifetime, inviter revoked before the invite, inviter without rights at the invite's
  `created_ms` → `INVALID`; inviter unknown here → `RETRY_LATER`.
- [ ] `Register` needs no `invite_secret` and works on a node that never saw the `INVITE` record.
- [ ] New accounts: `can_invite` true only when the invite is network-signed (or founding); entry's `can_invite` ignored.
- [ ] `invite.create` refuses an `INVITE` without a 32-byte `redeem_pub` (`INVALID`, "update the app").
- [ ] `ImportRecord` refuses directory entries.
- [ ] Meshsim hostile-peer test: a peer injecting a self-signed account or a stolen chain cannot add a member on another node.

**Verify:** `cd otter-server && go test ./internal/service/ ./internal/meshsim/ ./internal/gateway/ ./internal/replication/ -count=1 -race` → `ok`

**Steps:**

- [ ] **Step 1: Test helpers.** In `service_test.go` replace `invite` and `registerReqWith`:

```go
// ticket is an invite as the inviter's app hands it over: the signed INVITE and the secret from the link.
type ticket struct {
	secret []byte
	rec    *pb.Record
}

func (f *fx) invite(inviter *user, ttl time.Duration) *ticket {
	secret := make([]byte, 32)
	rand.Read(secret)
	inv, err := records.InvitePayload(secret, time.Now().Add(ttl).UnixMilli())
	if err != nil {
		f.t.Fatal(err)
	}
	tk := &ticket{secret: secret}
	if inviter == nil {
		tk.rec = sign(f.t, pb.RecordType_INVITE, keys.ID16(f.svc.NetworkPub), inv, f.netPriv)
		if _, err := f.svc.ImportRecord(context.Background(), tk.rec); err != nil {
			f.t.Fatal(err)
		}
	} else {
		tk.rec = sign(f.t, pb.RecordType_INVITE, inviter.id, inv, inviter.priv)
		if _, err := f.svc.Submit(context.Background(), inviter.id, tk.rec, pb.RecordType_INVITE); err != nil {
			f.t.Fatal(err)
		}
	}
	return tk
}

func (f *fx) registerReq(tk *ticket, username string) (*user, *pb.RegisterRequest) {
	return f.registerReqWith(tk, username, nil)
}

func (f *fx) registerReqWith(tk *ticket, username string, mod func(*pb.DirectoryEntry, *pb.PreKeys, *pb.InviteUsed)) (*user, *pb.RegisterRequest) {
	pub, priv, _ := ed25519.GenerateKey(nil)
	id := keys.ID16(pub)
	u := &user{id: id, priv: priv}
	entry := &pb.DirectoryEntry{UserId: id, Username: username, DisplayName: username, AccountPub: pub,
		IdentityPub: make([]byte, 33), IdentitySig: make([]byte, 64), Version: 1, CanInvite: true,
		RegisteredMs: time.Now().UnixMilli()}
	if err := records.Redeem(entry, tk.rec, tk.secret); err != nil {
		f.t.Fatal(err)
	}
	// … prekeys exactly as before …
	sum := sha256.Sum256(tk.secret)
	used := &pb.InviteUsed{InviteId: sum[:], UserId: id}
	if mod != nil {
		mod(entry, pk, used)
	}
	return u, &pb.RegisterRequest{
		DirectoryEntry: sign(f.t, pb.RecordType_DIRECTORY_ENTRY, id, entry, priv),
		Prekeys:        sign(f.t, pb.RecordType_PREKEYS, id, pk, priv),
		InviteUsed:     sign(f.t, pb.RecordType_INVITE_USED, id, used, priv)}
}
```

  `mustRegister(tk *ticket, name string)`. In `TestRegisterFlow` replace the "unknown invite" case with an invite
  signed by a stranger:

```go
	pubX, privX, _ := ed25519.GenerateKey(nil)
	stranger := &user{id: keys.ID16(pubX), priv: privX}
	inv, _ := records.InvitePayload(make([]byte, 32), time.Now().Add(time.Hour).UnixMilli())
	_, unknown := f.registerReq(&ticket{secret: make([]byte, 32), rec: sign(t, pb.RecordType_INVITE, stranger.id, inv, stranger.priv)}, "gleb")
	if _, err := f.svc.Register(ctx, unknown); !errors.Is(err, ErrRetryLater) {
		t.Fatalf("invite by an unknown inviter: %v", err)
	}
```

  and in the rights case (312-321) drop the `e.CanInvite = false` mod: boris-like accounts invited by anna have no
  rights anyway; assert that `Submit` of an INVITE by them is `ErrUnauthorized` and that the test's `short` request at
  275 (`InviteSecret: []byte{1}` only) still gives `ErrInvalid`. Apply the same pattern to:
  `meshsim`: `func (s *sim) invite(n *simNode) *ticket` (same body as above, `ImportRecord` on `n`), `account` gains
  `proof []byte`, `register` calls `records.Redeem(e, tk.rec, tk.secret)`, sets `e.RegisteredMs = time.Now().UnixMilli()`,
  stores `a.proof = e.InviteProof`, drops `InviteSecret`; add `registerWith(n *simNode, name string, tk *ticket) *account`
  (the same body taking the ticket; `register` = `registerWith(n, name, s.invite(n))`); `gateway/e2e_test.go`
  `registerReq(t, n, tk *ticket, name)` and `replication_test.go` `register` the same way (they build the INVITE with
  `records.InvitePayload` and fill the entry with `records.Redeem`).

- [ ] **Step 2: Failing tests** — append to `internal/service/membership_test.go`:

```go
// replicatedEntry builds a version-1 entry for a fresh account, chained to tk (nil = no chain).
func (f *fx) replicatedEntry(tk *ticket, name string, mod func(*pb.DirectoryEntry)) (*user, *pb.Record) {
	pub, priv, _ := ed25519.GenerateKey(nil)
	u := &user{id: keys.ID16(pub), priv: priv}
	e := &pb.DirectoryEntry{UserId: u.id, Username: name, DisplayName: name, AccountPub: pub, IdentityPub: make([]byte, 33),
		IdentitySig: make([]byte, 64), Version: 1, CanInvite: true, RegisteredMs: time.Now().UnixMilli()}
	if tk != nil {
		if err := records.Redeem(e, tk.rec, tk.secret); err != nil {
			f.t.Fatal(err)
		}
	}
	if mod != nil {
		mod(e)
	}
	return u, sign(f.t, pb.RecordType_DIRECTORY_ENTRY, u.id, e, priv)
}

func TestAdmissionChain(t *testing.T) {
	f := newFx(t)
	ctx := context.Background()
	f.withManifest(1)
	peer := r16()
	anna := f.mustRegister(f.invite(nil, time.Hour), "anna") // network invite: may invite
	if u, _ := f.svc.Store.UserByID(ctx, anna.id); !u.CanInvite {
		t.Fatal("network-invited account must be able to invite")
	}
	boris := f.mustRegister(f.invite(anna, time.Hour), "boris") // member invite: may not (D101), entry says true
	if u, _ := f.svc.Store.UserByID(ctx, boris.id); u.CanInvite {
		t.Fatal("can_invite came from the applicant (C6)")
	}

	// a hostile peer: a self-signed account without any chain
	_, bare := f.replicatedEntry(nil, "mallory", nil)
	if _, err := f.svc.ApplyReplicated(ctx, peer, bare); !errors.Is(err, ErrInvalid) {
		t.Fatalf("no chain: %v", err)
	}
	// boris's chain copied into another account: the proof binds boris's key
	borisRaw, _ := f.svc.Store.UserByID(ctx, boris.id)
	stolen := chainOf(t, borisRaw.EntryRaw)
	_, copied := f.replicatedEntry(nil, "mallory", func(e *pb.DirectoryEntry) { e.InviteRecord, e.InviteProof = stolen.InviteRecord, stolen.InviteProof })
	if _, err := f.svc.ApplyReplicated(ctx, peer, copied); !errors.Is(err, ErrInvalid) {
		t.Fatalf("copied chain: %v", err)
	}
	// an INVITE "by the network" signed with another key
	inv, _ := records.InvitePayload(bytes.Repeat([]byte{3}, 32), time.Now().Add(time.Hour).UnixMilli())
	_, nodeKey, _ := ed25519.GenerateKey(nil)
	fake := &ticket{secret: bytes.Repeat([]byte{3}, 32), rec: sign(t, pb.RecordType_INVITE, keys.ID16(f.svc.NetworkPub), inv, nodeKey)}
	_, forged := f.replicatedEntry(fake, "mallory", nil)
	if _, err := f.svc.ApplyReplicated(ctx, peer, forged); !errors.Is(err, ErrInvalid) {
		t.Fatalf("forged invite: %v", err)
	}
	// boris has no rights: his invite cannot admit anyone, even arriving by replication
	binv, _ := records.InvitePayload(bytes.Repeat([]byte{4}, 32), time.Now().Add(time.Hour).UnixMilli())
	btk := &ticket{secret: bytes.Repeat([]byte{4}, 32), rec: sign(t, pb.RecordType_INVITE, boris.id, binv, boris.priv)}
	_, byBoris := f.replicatedEntry(btk, "vera", nil)
	if _, err := f.svc.ApplyReplicated(ctx, peer, byBoris); !errors.Is(err, ErrInvalid) {
		t.Fatalf("invite without rights: %v", err)
	}
	// registered outside the invite's lifetime
	_, late := f.replicatedEntry(f.invite(anna, time.Hour), "late", func(e *pb.DirectoryEntry) { e.RegisteredMs = time.Now().Add(2 * time.Hour).UnixMilli() })
	if _, err := f.svc.ApplyReplicated(ctx, peer, late); !errors.Is(err, ErrInvalid) {
		t.Fatalf("outside lifetime: %v", err)
	}
	// a valid chain by anna replicates fine
	vera, ok := f.replicatedEntry(f.invite(anna, time.Hour), "vera", nil)
	if _, err := f.svc.ApplyReplicated(ctx, peer, ok); err != nil {
		t.Fatal(err)
	}
	if u, _ := f.svc.Store.UserByID(ctx, vera.id); u == nil || u.CanInvite {
		t.Fatalf("vera: %+v", u)
	}
	// rights granted by the admin later apply
	grant := sign(t, pb.RecordType_INVITE_RIGHTS, keys.ID16(f.svc.NetworkPub), &pb.InviteRights{UserId: vera.id, CanInvite: true, Version: 1}, f.netPriv)
	if err := f.svc.PublishNetworkRecord(ctx, grant); err != nil {
		t.Fatal(err)
	}
	if u, _ := f.svc.Store.UserByID(ctx, vera.id); !u.CanInvite {
		t.Fatal("INVITE_RIGHTS not applied")
	}
}

func TestFoundingMembersNeedNoChain(t *testing.T) {
	f := newFx(t)
	ctx := context.Background()
	old, bare := f.replicatedEntry(nil, "mama", nil)
	m := &pb.Manifest{Version: 2, NetworkPub: f.svc.NetworkPub, FoundingMembers: [][]byte{old.id},
		Nodes: []*pb.NodeInfo{{NodeId: f.svc.NodeID, NodePub: f.svc.NodeKeyPriv.Public().(ed25519.PublicKey), Label: "self"}}}
	if _, err := f.svc.ImportRecord(ctx, sign(t, pb.RecordType_MANIFEST, keys.ID16(f.svc.NetworkPub), m, f.netPriv)); err != nil {
		t.Fatal(err)
	}
	if _, err := f.svc.ApplyReplicated(ctx, r16(), bare); err != nil {
		t.Fatalf("founding member refused: %v", err)
	}
	if u, _ := f.svc.Store.UserByID(ctx, old.id); u == nil || !u.CanInvite {
		t.Fatalf("founding member: %+v", u)
	}
	if _, err := f.svc.ImportRecord(ctx, bare); !errors.Is(err, ErrInvalid) {
		t.Fatalf("ImportRecord of a directory entry: %v", err)
	}
}

func TestInviteNeedsRedeemKey(t *testing.T) {
	f := newFx(t)
	anna := f.mustRegister(f.invite(nil, time.Hour), "anna")
	old := sign(t, pb.RecordType_INVITE, anna.id, &pb.Invite{InviteId: make([]byte, 32), ExpiresMs: time.Now().Add(time.Hour).UnixMilli()}, anna.priv)
	if _, err := f.svc.Submit(context.Background(), anna.id, old, pb.RecordType_INVITE); !errors.Is(err, ErrInvalid) {
		t.Fatalf("invite without redeem_pub: %v", err)
	}
}

func chainOf(t *testing.T, raw []byte) *pb.DirectoryEntry {
	var r pb.Record
	var b pb.RecordBody
	var e pb.DirectoryEntry
	if proto.Unmarshal(raw, &r) != nil || proto.Unmarshal(r.Body, &b) != nil || proto.Unmarshal(b.Payload, &e) != nil {
		t.Fatal("bad entry")
	}
	return &e
}
```

  (imports: `bytes`, `crypto/ed25519`, `google.golang.org/protobuf/proto`, `ottermsg/server/internal/records`.)
  Meshsim hostile test, append to `internal/meshsim/membership_test.go`:

```go
// Limit 3: a hostile peer cannot introduce an account: neither self-signed nor with a chain copied from a real one.
func TestHostilePeerCannotAdmit(t *testing.T) {
	s := newSim(t, "a", "b")
	a, b := s.node("a"), s.node("b")
	anna := s.register(a, "anna")
	eventually(t, "anna on b", func() bool { return b.knows(anna) })
	ctx := context.Background()
	pub, priv, _ := ed25519.GenerateKey(nil)
	mal := &account{id: keys.ID16(pub), priv: priv, name: "mallory"}
	e := &pb.DirectoryEntry{UserId: mal.id, Username: "mallory", DisplayName: "Мама", AccountPub: pub, IdentityPub: make([]byte, 33),
		IdentitySig: make([]byte, 64), Version: 1, RegisteredMs: time.Now().UnixMilli()}
	if _, err := b.svc.ApplyReplicated(ctx, a.id, s.signAs(mal, pb.RecordType_DIRECTORY_ENTRY, e)); !errors.Is(err, service.ErrInvalid) {
		t.Fatalf("self-signed account: %v", err)
	}
	ua, _ := a.st.UserByID(ctx, anna.id)
	var r pb.Record
	var body pb.RecordBody
	var ae pb.DirectoryEntry
	proto.Unmarshal(ua.EntryRaw, &r)
	proto.Unmarshal(r.Body, &body)
	proto.Unmarshal(body.Payload, &ae)
	e.InviteRecord, e.InviteProof = ae.InviteRecord, ae.InviteProof
	if _, err := b.svc.ApplyReplicated(ctx, a.id, s.signAs(mal, pb.RecordType_DIRECTORY_ENTRY, e)); !errors.Is(err, service.ErrInvalid) {
		t.Fatalf("stolen chain: %v", err)
	}
	if b.knows(mal) || s.tryLogin(b, mal) == pb.Status_STATUS_OK {
		t.Fatal("hostile account admitted")
	}
}
```

  Run → FAIL (fields unused; replicated entries without chain still accepted).

- [ ] **Step 3: Implement** — add to `internal/service/membership.go`:

```go
// founding reports whether the current manifest lists the user as admitted without an invite chain (D100).
func (s *Service) founding(user []byte) bool {
	m := s.CurrentManifest()
	if m == nil {
		return false
	}
	for _, f := range m.FoundingMembers {
		if bytes.Equal(f, user) {
			return true
		}
	}
	return false
}

// admitIfNew returns the admission of a DIRECTORY_ENTRY whose user this node does not know, nil for a known user.
func (s *Service) admitIfNew(ctx context.Context, body *pb.RecordBody) (*store.Admission, error) {
	var e pb.DirectoryEntry
	if err := proto.Unmarshal(body.Payload, &e); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalid, err)
	}
	if _, known := s.Store.UserKey(e.UserId); known {
		return nil, nil
	}
	if s.founding(e.UserId) {
		rank := body.CreatedMs
		if e.RegisteredMs > 0 {
			rank = e.RegisteredMs
		}
		return &store.Admission{RankMs: rank, CanInvite: true}, nil
	}
	return s.admitChain(ctx, &e, false)
}

// admitChain verifies the invite chain of a new account (D100). Everything it checks is in signed records, so every
// node reaches the same answer. strict = registration on this node: the invite must also be valid now and its inviter
// allowed now.
func (s *Service) admitChain(ctx context.Context, e *pb.DirectoryEntry, strict bool) (*store.Admission, error) {
	if len(e.InviteRecord) == 0 || len(e.InviteProof) != ed25519.SignatureSize {
		return nil, fmt.Errorf("%w: no invite chain (update the app)", ErrInvalid)
	}
	var rec pb.Record
	var ib pb.RecordBody
	var inv pb.Invite
	if proto.Unmarshal(e.InviteRecord, &rec) != nil || len(rec.Signature) != ed25519.SignatureSize ||
		proto.Unmarshal(rec.Body, &ib) != nil || ib.Type != pb.RecordType_INVITE || len(ib.Author) != 16 ||
		proto.Unmarshal(ib.Payload, &inv) != nil || len(inv.InviteId) != 32 || len(inv.RedeemPub) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("%w: malformed invite record", ErrInvalid)
	}
	fromNetwork := bytes.Equal(ib.Author, s.networkID())
	signer := s.NetworkPub
	if !fromNetwork {
		k, ok := s.Store.UserKey(ib.Author) // a revoked inviter still verifies; when it was revoked is checked below
		if !ok {
			return nil, fmt.Errorf("%w: inviter %x not known here yet", ErrRetryLater, ib.Author)
		}
		signer = k.Pub
	}
	if !ed25519.Verify(signer, rec.Body, rec.Signature) {
		return nil, fmt.Errorf("%w: invite signature", ErrInvalid)
	}
	if !ed25519.Verify(inv.RedeemPub, keys.RedeemMessage(inv.InviteId, e.UserId, e.AccountPub), e.InviteProof) {
		return nil, fmt.Errorf("%w: invite proof", ErrInvalid)
	}
	if strict && inv.ExpiresMs < s.Now().UnixMilli() {
		return nil, fmt.Errorf("%w: invite expired", ErrConflict)
	}
	if e.RegisteredMs < ib.CreatedMs || e.RegisteredMs > inv.ExpiresMs {
		return nil, fmt.Errorf("%w: registration outside the invite's lifetime", ErrInvalid)
	}
	if !fromNetwork {
		at, revoked, err := s.Store.RevokedAt(ctx, ib.Author)
		if err != nil {
			return nil, err
		}
		if revoked && at <= ib.CreatedMs {
			return nil, fmt.Errorf("%w: inviter was revoked before the invite", ErrInvalid)
		}
		ok, err := s.Store.CanInviteAt(ctx, ib.Author, ib.CreatedMs)
		if err != nil {
			return nil, err
		}
		if !ok {
			return nil, fmt.Errorf("%w: inviter had no invite rights", ErrInvalid)
		}
		if strict {
			if err := s.inviterAllowed(ctx, ib.Author); err != nil {
				return nil, err
			}
		}
	}
	h := sha256.Sum256(e.InviteProof)
	return &store.Admission{InviteID: inv.InviteId, Rank: h[:], RankMs: ib.CreatedMs, CanInvite: fromNetwork}, nil
}
```

  (imports: `bytes`, `crypto/ed25519`, `crypto/sha256`, `google.golang.org/protobuf/proto`, `ottermsg/server/internal/keys`,
  `ottermsg/server/internal/store`.)

  `ApplyReplicated` after the validator switch:

```go
	var adm *store.Admission
	if body.Type == pb.RecordType_DIRECTORY_ENTRY {
		if adm, err = s.admitIfNew(ctx, body); err != nil {
			return false, err // INVALID: skipped by the peer session; RETRY_LATER: the inviter's entry comes first
		}
	}
	_, applied, err := s.Store.ApplyReplicatedItem(ctx, store.Item{Record: rec, Body: body, Admission: adm}, from)
```

  `ImportRecord`: after `Validate`, `if body.Type == pb.RecordType_DIRECTORY_ENTRY { return false, fmt.Errorf("%w: accounts
  arrive by registration or replication", ErrInvalid) }`.

  `Submit` `INVITE` case:

```go
	case pb.RecordType_INVITE:
		var inv pb.Invite
		if err := proto.Unmarshal(body.Payload, &inv); err != nil || len(inv.RedeemPub) != ed25519.PublicKeySize {
			return nil, fmt.Errorf("%w: invite without a redeem key (update the app)", ErrInvalid)
		}
		if err := s.inviterAllowed(ctx, user); err != nil {
			return nil, err
		}
```

  `Register` (whole function):

```go
// Register creates an account from an invite chain (D100). The INVITE travels inside the entry, so any node can
// register it, and the link secret never reaches a node.
func (s *Service) Register(ctx context.Context, req *pb.RegisterRequest) ([]byte, error) {
	if req.DirectoryEntry == nil || req.Prekeys == nil || req.InviteUsed == nil {
		return nil, fmt.Errorf("%w: incomplete registration", ErrInvalid)
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
	adm, err := s.admitChain(ctx, &e, true)
	if err != nil {
		return nil, err
	}
	var invRec pb.Record
	var invBody pb.RecordBody
	_ = proto.Unmarshal(e.InviteRecord, &invRec) // parsed and verified by admitChain
	_ = proto.Unmarshal(invRec.Body, &invBody)

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
	if usedBody.Type != pb.RecordType_INVITE_USED || !bytes.Equal(used.InviteId, adm.InviteID) {
		return nil, fmt.Errorf("%w: invite_used", ErrInvalid)
	}
	_, err = s.Store.ApplyAll(ctx, s.NodeID, []store.Item{
		{Record: &invRec, Body: &invBody}, // this node may not have the INVITE yet; idempotent if it has
		{Record: req.DirectoryEntry, Body: dirBody, Admission: adm},
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

  (`crypto/sha256` import of register.go goes away.) Run Step 2 and the updated older tests → PASS;
  `go test ./... -count=1 -race` → all `ok`.

- [ ] **Step 4: Commit**

```bash
git add internal/service internal/meshsim internal/gateway/e2e_test.go internal/replication/replication_test.go
oc -m "node: every node verifies the invite chain of a new account; rights only from the invite or INVITE_RIGHTS (limit 3, C6)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 34: Node — single use network-wide and a username rank nobody can backdate

**Goal:** Two redemptions of one invite converge to the same survivor on every node; the clash rank is fixed at admission; restore by a clashed name is never silently resolved.
**Findings closed:** C5, C12

**Files:**
- Modify: `otter-server/internal/store/membership.go` (add `redeem`, `ResolveUsername`), `internal/store/typed.go`
  (`applyDirectoryEntry`: rank fixed, `username_clashes`, call `redeem`)
- Modify: `otter-server/internal/service/backup.go` (`BackupAuth`, `BackupFetch`)
- Test: `otter-server/internal/store/membership_test.go`, `internal/store/mesh_test.go` (`TestClashRankUsesRegisteredMs` stays green),
  `internal/service/backup_test.go`, `internal/meshsim/membership_test.go`

**Acceptance Criteria:**
- [ ] Partitioned nodes A and B each accept one redemption of the same invite by different accounts; after healing both
  nodes keep the account with the lower `SHA-256(invite_proof)` and disable the other (`revoke_reason = "duplicate invite"`,
  login → `REVOKED` on both).
- [ ] A second local redemption of an invite already redeemed (by replication) is refused with `CONFLICT "invite already used"`.
- [ ] A newer version with a backdated `registered_ms` does not change the clash winner; a new account's rank is its invite's `created_ms`.
- [ ] `backup.auth("anna")` for a clashed name returns `candidates = ["anna#<w>", "anna#<l>"]` and no salt;
  `backup.auth("anna#<w>")` resolves to the winner; `backup.fetch("anna", …)` → `CONFLICT`.

**Verify:** `cd otter-server && go test ./internal/store/ ./internal/service/ -count=1 -race && go test ./internal/meshsim/ -run 'DoubleRedemption' -count=1 -race` → `ok`

**Steps:**

- [ ] **Step 1: Failing store tests** (append to `membership_test.go`):

```go
// admitted: a version-1 entry claiming registeredMs, admitted with the given invite, rank and rank time.
func admitted(t *testing.T, user []byte, name string, invite, rank []byte, rankMs, registeredMs int64) Item {
	e := entry(user, name, 1)
	e.RegisteredMs = registeredMs
	it := mkItemAt(t, pb.RecordType_DIRECTORY_ENTRY, user, e, max(registeredMs, rankMs))
	it.Admission = &Admission{InviteID: invite, Rank: rank, RankMs: rankMs}
	return it
}

func TestDoubleRedemptionLowestRankStays(t *testing.T) {
	ctx := context.Background()
	inv := bytes.Repeat([]byte{1}, 32)
	x, y := r16(), r16()
	lo, hi := bytes.Repeat([]byte{0x10}, 32), bytes.Repeat([]byte{0x20}, 32)
	for _, order := range []string{"x-first", "y-first"} {
		s, _ := open(t)
		ix := admitted(t, x, "xenia", inv, hi, 1000, 1000)
		iy := admitted(t, y, "yuri", inv, lo, 1000, 1000)
		apply2 := func(it Item) {
			if _, _, err := s.ApplyReplicatedItem(ctx, it, peer); err != nil {
				t.Fatal(err)
			}
		}
		if order == "x-first" {
			apply2(ix)
			apply2(iy)
		} else {
			apply2(iy)
			apply2(ix)
		}
		ux, _ := s.UserByID(ctx, x)
		uy, _ := s.UserByID(ctx, y)
		if !ux.Revoked || uy.Revoked {
			t.Fatalf("%s: x revoked=%v y revoked=%v", order, ux.Revoked, uy.Revoked)
		}
	}
	// locally a second redemption is refused
	s, _ := open(t)
	if _, _, err := s.ApplyReplicatedItem(ctx, admitted(t, x, "xenia", inv, hi, 1000, 1000), peer); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ApplyAll(ctx, nil, []Item{admitted(t, y, "yuri", inv, lo, 1000, 1000)}); !errors.Is(err, ErrInviteUnavailable) {
		t.Fatalf("local second redemption: %v", err)
	}
}

func TestClashRankFixedAtAdmission(t *testing.T) {
	ctx := context.Background()
	s, _ := open(t)
	victim, attacker := r16(), r16()
	if _, _, err := s.ApplyReplicatedItem(ctx, admitted(t, victim, "anna", r16(), r16(), 5000, 5000), peer); err != nil {
		t.Fatal(err)
	}
	// the attacker claims registered_ms 1 but was invited later (rank 9000): loses
	if _, _, err := s.ApplyReplicatedItem(ctx, admitted(t, attacker, "anna", r16(), r16(), 9000, 1), peer); err != nil {
		t.Fatal(err)
	}
	// and a newer version with a backdated registered_ms changes nothing
	e2 := entry(attacker, "anna", 2)
	e2.RegisteredMs = 1
	replicate(t, s, mkItemAt(t, pb.RecordType_DIRECTORY_ENTRY, attacker, e2, 9999))
	uv, _ := s.UserByID(ctx, victim)
	ua, _ := s.UserByID(ctx, attacker)
	if uv.Username != "anna" || ua.Username != "anna#"+hex.EncodeToString(attacker[:4]) {
		t.Fatalf("victim=%s attacker=%s", uv.Username, ua.Username)
	}
	name, cands, err := s.ResolveUsername(ctx, "anna")
	if err != nil || name != "" || len(cands) != 2 {
		t.Fatalf("ambiguous name: %q %v %v", name, cands, err)
	}
	if name, _, _ := s.ResolveUsername(ctx, "anna#"+hex.EncodeToString(victim[:4])); name != "anna" {
		t.Fatalf("winner's tag resolves to %q", name)
	}
	if name, _, _ := s.ResolveUsername(ctx, "anna#"+hex.EncodeToString(attacker[:4])); name != "anna#"+hex.EncodeToString(attacker[:4]) {
		t.Fatalf("loser's tag resolves to %q", name)
	}
}
```

  (imports `bytes`, `encoding/hex`, `errors`.) Run → FAIL.

- [ ] **Step 2: Implement.** In `membership.go`:

```go
// redeem records the account's redemption and applies the network-wide single-use rule (D102): of all accounts that
// redeemed one invite, the lowest rank (then user_id) stays and every other one is disabled. A redemption on this
// node of an invite already redeemed by someone else is refused instead. Returns whether the new account lost.
func redeem(ctx context.Context, tx *sql.Tx, it item, user []byte) (bool, error) {
	a := it.adm
	if a == nil || a.InviteID == nil {
		return false, nil
	}
	if !it.fromPeer {
		var x int
		err := tx.QueryRowContext(ctx, `SELECT 1 FROM redemptions WHERE invite_id=? AND user_id<>?`, a.InviteID, user).Scan(&x)
		if err == nil {
			return false, ErrInviteUnavailable
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return false, err
		}
	}
	if _, err := tx.ExecContext(ctx, `INSERT OR IGNORE INTO redemptions(invite_id,user_id,rank) VALUES(?,?,?)`, a.InviteID, user, a.Rank); err != nil {
		return false, err
	}
	var best []byte
	if err := tx.QueryRowContext(ctx, `SELECT user_id FROM redemptions WHERE invite_id=? ORDER BY rank, user_id LIMIT 1`,
		a.InviteID).Scan(&best); err != nil {
		return false, err
	}
	rows, err := tx.QueryContext(ctx, `SELECT user_id FROM redemptions WHERE invite_id=? AND user_id<>? AND user_id<>?`, a.InviteID, best, user)
	if err != nil {
		return false, err
	}
	var losers [][]byte
	for rows.Next() {
		var id []byte
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return false, err
		}
		losers = append(losers, id)
	}
	rows.Close()
	for _, id := range losers {
		if err := revokeUser(ctx, tx, id, ReasonDuplicateInvite); err != nil {
			return false, err
		}
	}
	return !bytes.Equal(best, user), nil
}

// ResolveUsername maps a name typed for a restore to the stored username (D103): a name that never clashed as is;
// "name#<8 hex>" to either side of a clash (the winner is stored as plain "name"). A clashed plain name returns the
// candidates instead of guessing.
func (s *Store) ResolveUsername(ctx context.Context, typed string) (string, []string, error) {
	base, tag, tagged := strings.Cut(typed, "#")
	var x int
	err := s.r.QueryRowContext(ctx, `SELECT 1 FROM username_clashes WHERE username=?`, base).Scan(&x)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return "", nil, err
	}
	clashed := err == nil
	if !tagged {
		if !clashed {
			return typed, nil, nil
		}
		rows, err := s.r.QueryContext(ctx, `SELECT user_id FROM users WHERE username=?1 OR substr(username,1,length(?1)+1)=?1||'#'
			ORDER BY username`, base)
		if err != nil {
			return "", nil, err
		}
		defer rows.Close()
		var out []string
		for rows.Next() {
			var id []byte
			if err := rows.Scan(&id); err != nil {
				return "", nil, err
			}
			out = append(out, base+"#"+hex.EncodeToString(id[:4]))
		}
		return "", out, rows.Err()
	}
	var id []byte
	err = s.r.QueryRowContext(ctx, `SELECT user_id FROM users WHERE username=?`, base).Scan(&id)
	if err == nil && hex.EncodeToString(id[:4]) == tag {
		return base, nil, nil
	}
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return "", nil, err
	}
	return typed, nil, nil // the loser's row is literally "name#tag"; anything else finds nothing
}
```

  (imports `bytes`, `encoding/hex`, `strings`.) In `insertUser` (Task 31), replace the lines from
  `revoked, reason := false, ""` to the end of the revocation `switch` with:

```go
	lost, err := redeem(ctx, tx, it, e.UserId)
	if err != nil {
		return err
	}
	revoked, reason := lost, ""
	if lost {
		reason = ReasonDuplicateInvite
	}
	var rr string
	err = tx.QueryRowContext(ctx, `SELECT reason FROM revocations WHERE user_id=?`, e.UserId).Scan(&rr)
	switch {
	case err == nil:
		revoked, reason = true, rr
	case !errors.Is(err, sql.ErrNoRows):
		return err
	}
```

  In `applyDirectoryEntry` (C12): read the current rank with the row and never update it:

```go
	var curRank int64
	err := tx.QueryRowContext(ctx, `SELECT version, username, username_conflict, entry_created_ms FROM users WHERE user_id=?`, e.UserId).
		Scan(&cur, &curName, &curConflict, &curRank)
	…
	// D103: the clash rank is fixed when the account is admitted (the INVITE's created_ms, signed by the inviter);
	// later versions cannot move it, whatever registered_ms they claim.
	rank := curRank
	if !exists {
		rank = created
		if e.RegisteredMs > 0 {
			rank = e.RegisteredMs
		}
		if it.adm != nil && it.adm.InviteID != nil {
			rank = it.adm.RankMs
		}
	}
```

  replace the clash `case wins(…)` / `default` arms with one arm that first remembers the clash:

```go
	default:
		if _, err := tx.ExecContext(ctx, `INSERT OR IGNORE INTO username_clashes(username) VALUES(?)`, e.Username); err != nil {
			return err
		}
		if wins(rank, e.UserId, ownerCreated, owner) {
			if _, err := tx.ExecContext(ctx, `UPDATE users SET username=?, username_conflict=1 WHERE user_id=?`,
				conflictName(e.Username, owner), owner); err != nil {
				return err
			}
		} else {
			name, conflict = conflictName(e.Username, e.UserId), 1
		}
```

  and the final update without `entry_created_ms`:
  `UPDATE users SET username=?, entry_key=?, version=?, username_conflict=? WHERE user_id=?`.
  Update the comments of `applyDirectoryEntry` and `TestClashRankUsesRegisteredMs` ("first version seen fixes the rank").

- [ ] **Step 3: Backup by a clashed name.** Failing test in `internal/service/backup_test.go` (two accounts made to clash by
  replicating a second "anna" through `ApplyReplicated` with a chain; reuse `replicatedEntry` from Task 33):

```go
func TestBackupAuthAmbiguousName(t *testing.T) {
	f := newFx(t)
	ctx := context.Background()
	f.withManifest(1)
	anna := f.mustRegister(f.invite(nil, time.Hour), "anna")
	other, rec := f.replicatedEntry(f.invite(anna, time.Hour), "anna", nil) // a clash from another partition
	if _, err := f.svc.ApplyReplicated(ctx, r16(), rec); err != nil {
		t.Fatal(err)
	}
	res, err := f.svc.BackupAuth(ctx, "anna")
	if err != nil || len(res.Candidates) != 2 || len(res.Salt) != 0 {
		t.Fatalf("ambiguous: %+v %v", res, err)
	}
	for _, c := range res.Candidates {
		if r, err := f.svc.BackupAuth(ctx, c); err != nil || len(r.Candidates) != 0 || len(r.Salt) == 0 {
			t.Fatalf("%s: %+v %v", c, r, err)
		}
	}
	if _, _, err := f.svc.BackupFetch(ctx, "anna", make([]byte, 32)); !errors.Is(err, ErrConflict) {
		t.Fatalf("fetch by an ambiguous name: %v", err)
	}
	_ = other
}
```

  Implement: at the top of `BackupAuth`:

```go
	name, cands, err := s.Store.ResolveUsername(ctx, username)
	if err != nil {
		return nil, err
	}
	if cands != nil {
		return &pb.BackupAuthResponse{Candidates: cands}, nil // D103: the phone tries each with the typed password
	}
```

  then use `name` for `currentBackup` (keep `fakeSalt(username)` on the typed string). In `BackupFetch`, before the
  failure counters:

```go
	name, cands, err := s.Store.ResolveUsername(ctx, username)
	if err != nil {
		return nil, nil, err
	}
	if cands != nil {
		return nil, nil, fmt.Errorf("%w: ambiguous username, use name#tag", ErrConflict)
	}
	username = name // one failure counter per account, typed with or without its tag
```

  (Coordinator: M9.1 C20 changes the fake salt and M9.2 C4 the throttling key in these two functions; keep the
  resolution step first in both.)

- [ ] **Step 4: Meshsim C5 scenario** (append to `membership_test.go`):

```go
// C5: one invite redeemed on both sides of a partition by two accounts converges to one survivor on every node.
func TestDoubleRedemptionConverges(t *testing.T) {
	s := newSim(t, "a", "b")
	a, b := s.node("a"), s.node("b")
	s.part.Block(a, b)
	tk := s.invite(a)
	if _, err := b.svc.ImportRecord(context.Background(), tk.rec); err != nil { // the same network invite on b
		t.Fatal(err)
	}
	x := s.registerWith(a, "xenia", tk)
	y := s.registerWith(b, "yuri", tk)
	s.part.Heal(a, b)
	eventually(t, "both accounts on both nodes", func() bool { return s.all(func(n *simNode) bool { return n.knows(x) && n.knows(y) }) })
	hx, hy := sha256.Sum256(x.proof), sha256.Sum256(y.proof)
	winner, loser := x, y
	if bytes.Compare(hx[:], hy[:]) > 0 {
		winner, loser = y, x
	}
	ctx := context.Background()
	eventually(t, "same verdict everywhere", func() bool {
		return s.all(func(n *simNode) bool {
			w, _ := n.st.UserByID(ctx, winner.id)
			l, _ := n.st.UserByID(ctx, loser.id)
			return w != nil && l != nil && !w.Revoked && l.Revoked
		})
	})
	for _, n := range s.nodes {
		if st := s.tryLogin(n, loser); st != pb.Status_STATUS_REVOKED {
			t.Fatalf("%s: loser login %v", n.label, st)
		}
		if st := s.tryLogin(n, winner); st != pb.Status_STATUS_OK {
			t.Fatalf("%s: winner login %v", n.label, st)
		}
	}
}
```

- [ ] **Step 5: Run** all → PASS; `go test ./... -count=1 -race` → `ok`.

- [ ] **Step 6: Commit**

```bash
git add internal/store internal/service/backup.go internal/service/backup_test.go internal/meshsim/membership_test.go
oc -m "node: invites single use network-wide; clash rank fixed at admission; restore never guesses a clashed name (C5, C12)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 35: otter-admin — `user list`, `user revoke`, `user invite-rights`, `user found`

**Goal:** The admin lists members (verified on the admin's machine), revokes them, sets invite rights and grandfathers the existing accounts; bootstrap links carry the chain.
**Findings closed:** C2 (admin side), limit 3 (founding members, bootstrap invite chain)

**Files:**
- Modify: `otter-server/internal/keys/auth.go` (add `AdminAuthMessage`)
- Create: `otter-server/internal/admin/users.go`, `otter-server/internal/admin/users_test.go`
- Modify: `otter-server/internal/admin/invite.go` (`BootstrapInvite`), `internal/admin/manifest.go` (`SignManifest`: founding members)
- Modify: `otter-server/internal/service/membership.go` (`VerifyAdmin`), `internal/gateway/methods.go` (`admin.users`)
- Modify: `otter-server/cmd/otter-admin/main.go` (`usage`, `run`), `cmd/otter-admin/main_test.go`
- Modify: `docs/08-operations.md` (admin commands)

**Acceptance Criteria:**
- [ ] `admin.users` answers only a request signed by the network key over this connection's nonce (else `UNAUTHORIZED`).
- [ ] `admin.Members` drops any entry, revocation or rights record whose signature does not verify (a node cannot add or fake members in the list).
- [ ] `user revoke anna` refuses an ambiguous name (asks for `name#tag` or the user id), asks «Revoke …? [y/N]» unless `--yes`,
  signs, saves `revocations/<hex>.bin`, publishes to every node (or `--via`), succeeds if one node took it.
- [ ] `user invite-rights anna --on|--off` uses version = highest known + 1.
- [ ] `user found <user_id_hex>...` stores `founding.json`; the next `manifest sign` lists them in `founding_members`.
- [ ] `invite bootstrap` links carry `InviteBundle.invite`; the `INVITE` has `redeem_pub`.

**Verify:** `cd otter-server && go test ./internal/admin/ ./cmd/otter-admin/ ./internal/gateway/ -count=1` → `ok`

**Steps:**

- [ ] **Step 1: Failing tests** `internal/admin/users_test.go`:

```go
package admin

import (
	"crypto/ed25519"
	"testing"
	"time"

	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/records"
)

func signed(t *testing.T, typ pb.RecordType, author []byte, m proto.Message, k ed25519.PrivateKey) *pb.Record {
	p, _ := proto.Marshal(m)
	r, err := records.Sign(&pb.RecordBody{Id: make([]byte, 16), Type: typ, Author: author, CreatedMs: time.Now().UnixMilli(), Payload: p}, k)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestMembersVerifiesEverything(t *testing.T) {
	netPub, netPriv, _ := ed25519.GenerateKey(nil)
	_, nodePriv, _ := ed25519.GenerateKey(nil)
	mk := func(name string) (*pb.Record, []byte) {
		pub, priv, _ := ed25519.GenerateKey(nil)
		id := keys.ID16(pub)
		return signed(t, pb.RecordType_DIRECTORY_ENTRY, id, &pb.DirectoryEntry{UserId: id, Username: name, DisplayName: name,
			AccountPub: pub, Version: 1}, priv), id
	}
	anna, annaID := mk("anna")
	boris, borisID := mk("boris")
	tampered := proto.Clone(boris).(*pb.Record)
	tampered.Signature[0] ^= 1
	rev := signed(t, pb.RecordType_REVOCATION, keys.ID16(netPub), &pb.Revocation{UserId: borisID, Reason: "x"}, netPriv)
	fakeRev := signed(t, pb.RecordType_REVOCATION, keys.ID16(netPub), &pb.Revocation{UserId: annaID}, nodePriv)
	rights := signed(t, pb.RecordType_INVITE_RIGHTS, keys.ID16(netPub), &pb.InviteRights{UserId: borisID, CanInvite: true, Version: 4}, netPriv)
	ms := Members([]*pb.Record{anna, tampered, boris, rev, fakeRev, rights}, netPub, [][]byte{annaID})
	if len(ms) != 2 {
		t.Fatalf("%d members", len(ms))
	}
	if !ms[0].Founding || ms[0].Revoked || !ms[0].CanInvite {
		t.Fatalf("anna: %+v", ms[0])
	}
	if !ms[1].Revoked || ms[1].RightsVersion != 4 {
		t.Fatalf("boris: %+v", ms[1])
	}
	if _, err := Find(ms, "boris"); err != nil {
		t.Fatal(err)
	}
	if _, err := Find(ms, "nobody"); err == nil {
		t.Fatal("unknown name resolved")
	}
}
```

  (imports also `google.golang.org/protobuf/proto`.) In
  `cmd/otter-admin/main_test.go` add a test against an in-process node (follow the existing `manifest publish` test there:
  `grep -n "manifest publish" cmd/otter-admin/main_test.go`) that runs `user revoke anna --yes` and then checks the node's
  `UserByID(anna).Revoked`, and `user found <hex>` + `manifest sign` → `founding_members` contains the id.
  Run → FAIL.

- [ ] **Step 2: Implement.** `keys/auth.go`:

```go
const adminContext = "otter-admin-v1"

// AdminAuthMessage is what the network key signs for admin.users (M9.2).
func AdminAuthMessage(nodeID, nonce []byte, tsMs int64) []byte {
	m := make([]byte, 0, len(adminContext)+len(nodeID)+len(nonce)+8)
	m = append(m, adminContext...)
	m = append(m, nodeID...)
	m = append(m, nonce...)
	return binary.BigEndian.AppendUint64(m, uint64(tsMs))
}
```

  `service/membership.go`:

```go
// VerifyAdmin checks an admin.users request: the network key over this session's nonce, within the clock skew.
func (s *Service) VerifyAdmin(nonce []byte, r *pb.AdminRequest) error {
	skew := s.Now().Sub(time.UnixMilli(r.TsMs))
	if skew > MaxClockSkew || skew < -MaxClockSkew || !ed25519.Verify(s.NetworkPub, keys.AdminAuthMessage(s.NodeID, nonce, r.TsMs), r.Signature) {
		return fmt.Errorf("%w: admin signature", ErrUnauthorized)
	}
	return nil
}
```

  `gateway/methods.go`:

```go
	case "admin.users":
		var r pb.AdminRequest
		if err := decode(req.Body, &r); err != nil {
			return nil, err
		}
		if err := svc.VerifyAdmin(s.nonce, &r); err != nil {
			return nil, err
		}
		recs, err := svc.Directory(ctx)
		if err != nil {
			return nil, err
		}
		return &pb.RecordBatch{Records: recs}, nil
```

  `internal/admin/users.go`:

```go
package admin

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"google.golang.org/protobuf/proto"
	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/records"
)

// Member is one account as the admin sees it after verifying every record on this machine.
type Member struct {
	UserID              []byte
	Username, Display   string
	Revoked             bool
	Reason              string
	CanInvite, Founding bool
	RightsVersion       uint64
}

func (m Member) Tag() string { return m.Username + "#" + hex.EncodeToString(m.UserID[:4]) }

// Members builds the member list from an admin.users batch. Records that do not verify are dropped: a node can
// hide accounts or revocations (refusal), it cannot invent or alter them. Duplicates (C5) and node-side clash names
// are not reproduced here; the list shows each account's own entry.
func Members(batch []*pb.Record, netPub ed25519.PublicKey, founding [][]byte) []Member {
	netID := keys.ID16(netPub)
	byID := map[string]*Member{}
	type rights struct {
		v   uint64
		can bool
	}
	rs := map[string]rights{}
	revoked := map[string]string{}
	inviterNet := map[string]bool{}
	for _, r := range batch {
		var b pb.RecordBody
		if proto.Unmarshal(r.Body, &b) != nil {
			continue
		}
		switch b.Type {
		case pb.RecordType_DIRECTORY_ENTRY:
			var e pb.DirectoryEntry
			if proto.Unmarshal(b.Payload, &e) != nil || len(e.AccountPub) != ed25519.PublicKeySize ||
				!bytes.Equal(e.UserId, keys.ID16(e.AccountPub)) || !bytes.Equal(b.Author, e.UserId) ||
				!ed25519.Verify(e.AccountPub, r.Body, r.Signature) {
				continue
			}
			byID[string(e.UserId)] = &Member{UserID: e.UserId, Username: e.Username, Display: e.DisplayName}
			var ir pb.Record
			var ib pb.RecordBody
			if proto.Unmarshal(e.InviteRecord, &ir) == nil && proto.Unmarshal(ir.Body, &ib) == nil && bytes.Equal(ib.Author, netID) &&
				ed25519.Verify(netPub, ir.Body, ir.Signature) {
				inviterNet[string(e.UserId)] = true
			}
		case pb.RecordType_REVOCATION, pb.RecordType_INVITE_RIGHTS:
			if !bytes.Equal(b.Author, netID) || !ed25519.Verify(netPub, r.Body, r.Signature) {
				continue
			}
			if b.Type == pb.RecordType_REVOCATION {
				var v pb.Revocation
				if proto.Unmarshal(b.Payload, &v) == nil {
					revoked[string(v.UserId)] = v.Reason
				}
				continue
			}
			var v pb.InviteRights
			if proto.Unmarshal(b.Payload, &v) == nil {
				cur, ok := rs[string(v.UserId)]
				if !ok || v.Version > cur.v || (v.Version == cur.v && !v.CanInvite) {
					rs[string(v.UserId)] = rights{v.Version, v.CanInvite}
				}
			}
		}
	}
	var out []Member
	for id, m := range byID {
		for _, f := range founding {
			if string(f) == id {
				m.Founding = true
			}
		}
		m.CanInvite = m.Founding || inviterNet[id]
		if r, ok := rs[id]; ok {
			m.CanInvite, m.RightsVersion = r.can, r.v
		}
		m.Reason, m.Revoked = revoked[id]
		out = append(out, *m)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Username < out[j].Username || (out[i].Username == out[j].Username && bytes.Compare(out[i].UserID, out[j].UserID) < 0) })
	return out
}

// Find resolves a user id (32 hex), "name#tag" or a unique username.
func Find(ms []Member, who string) (Member, error) {
	var hits []Member
	for _, m := range ms {
		if hex.EncodeToString(m.UserID) == strings.ToLower(who) || m.Tag() == who || m.Username == who {
			hits = append(hits, m)
		}
	}
	switch len(hits) {
	case 1:
		return hits[0], nil
	case 0:
		return Member{}, fmt.Errorf("no member %q", who)
	}
	var tags []string
	for _, h := range hits {
		tags = append(tags, h.Tag())
	}
	return Member{}, fmt.Errorf("%q is ambiguous: use one of %s", who, strings.Join(tags, ", "))
}

// SignRevocation signs a REVOCATION and keeps a copy in DIR/revocations/<user hex>.bin.
func SignRevocation(dir string, priv ed25519.PrivateKey, user []byte, reason string, now time.Time) (*pb.Record, error) {
	return signNetwork(dir, "revocations", priv, pb.RecordType_REVOCATION, user, &pb.Revocation{UserId: user, Reason: reason}, now)
}

// SignInviteRights signs INVITE_RIGHTS version v and keeps a copy in DIR/invite-rights/<user hex>.bin.
func SignInviteRights(dir string, priv ed25519.PrivateKey, user []byte, can bool, v uint64, now time.Time) (*pb.Record, error) {
	return signNetwork(dir, "invite-rights", priv, pb.RecordType_INVITE_RIGHTS, user, &pb.InviteRights{UserId: user, CanInvite: can, Version: v}, now)
}

func signNetwork(dir, sub string, priv ed25519.PrivateKey, typ pb.RecordType, user []byte, payload proto.Message, now time.Time) (*pb.Record, error) {
	p, err := proto.Marshal(payload)
	if err != nil {
		return nil, err
	}
	id := make([]byte, 16)
	rand.Read(id)
	rec, err := records.Sign(&pb.RecordBody{Id: id, Type: typ, Author: keys.ID16(priv.Public().(ed25519.PublicKey)),
		CreatedMs: now.UnixMilli(), Payload: p}, priv)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Join(dir, sub), 0o700); err != nil {
		return nil, err
	}
	raw, _ := proto.Marshal(rec)
	return rec, os.WriteFile(filepath.Join(dir, sub, hex.EncodeToString(user)+".bin"), raw, 0o600)
}

// LoadFounding / AddFounding keep DIR/founding.json (hex user ids) for 'manifest sign' (D100).
func LoadFounding(dir string) ([][]byte, error) {
	b, err := os.ReadFile(filepath.Join(dir, "founding.json"))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var hs []string
	if err := json.Unmarshal(b, &hs); err != nil {
		return nil, err
	}
	var out [][]byte
	for _, h := range hs {
		id, err := hex.DecodeString(h)
		if err != nil || len(id) != 16 {
			return nil, fmt.Errorf("founding.json: bad user id %q", h)
		}
		out = append(out, id)
	}
	return out, nil
}

func AddFounding(dir string, ids [][]byte) error {
	cur, err := LoadFounding(dir)
	if err != nil {
		return err
	}
	seen := map[string]bool{}
	var hs []string
	for _, id := range append(cur, ids...) {
		h := hex.EncodeToString(id)
		if !seen[h] {
			seen[h] = true
			hs = append(hs, h)
		}
	}
	b, _ := json.MarshalIndent(hs, "", "  ")
	return os.WriteFile(filepath.Join(dir, "founding.json"), append(b, '\n'), 0o600)
}
```

  (import `crypto/rand`.) `SignManifest`: `founding, err := LoadFounding(dir)` and `FoundingMembers: founding` in the
  `pb.Manifest{…}` literal. `BootstrapInvite`: build the payload with `records.InvitePayload(secret, exp)` and pass
  `Invite: rec` in the `InviteBundle`.

- [ ] **Step 3: Commands.** `usage` gains:

```
  user list [--via LABEL] [--allow-plain]
  user revoke NAME|NAME#TAG|USER_ID [--reason TEXT] [--yes] [--via LABEL]... [--allow-plain]
  user invite-rights NAME|NAME#TAG|USER_ID --on|--off [--via LABEL]... [--allow-plain]
  user found USER_ID...            (then 'manifest sign' and 'manifest publish')
```

  In `run`:

```go
	case "user list", "user revoke", "user invite-rights":
		return userCmd(out, in, *dir, a[1], a[2:])
	case "user found":
		var ids [][]byte
		for _, h := range a[2:] {
			id, err := hex.DecodeString(h)
			if err != nil || len(id) != 16 {
				return fmt.Errorf("user found: %q is not a 32-hex user id", h)
			}
			ids = append(ids, id)
		}
		if len(ids) == 0 {
			return errors.New("user found USER_ID...")
		}
		if err := admin.AddFounding(*dir, ids); err != nil {
			return err
		}
		fmt.Fprintln(out, "Stored. Run 'manifest sign' and 'manifest publish' so every node and phone accepts these accounts without an invite.")
```

  and:

```go
// userCmd fetches the member list from one node (signed request, verified here), then lists, revokes or sets rights.
func userCmd(out io.Writer, in io.Reader, dir, sub string, args []string) error {
	fs := flag.NewFlagSet("user "+sub, flag.ContinueOnError)
	var via multi
	fs.Var(&via, "via", "node label (repeatable; list uses the first)")
	allowPlain := fs.Bool("allow-plain", false, "allow plain ws:// endpoints (development only)")
	reason := fs.String("reason", "", "revocation reason (shown to nobody but the admin)")
	yes := fs.Bool("yes", false, "do not ask")
	on := fs.Bool("on", false, "allow inviting")
	off := fs.Bool("off", false, "forbid inviting")
	who := ""
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		who, args = args[0], args[1:]
	}
	if err := fs.Parse(args); err != nil {
		return err
	}
	st, err := admin.LoadState(dir)
	if err != nil {
		return err
	}
	p, err := passphrase(in, false)
	if err != nil {
		return err
	}
	priv, err := keys.ReadEncryptedKey(filepath.Join(dir, "network.key.enc"), p)
	if err != nil {
		return err
	}
	nodes, err := manifestNodes(dir, via) // nodes of manifest.bin filtered by --via (same parsing as publishNews)
	if err != nil {
		return err
	}
	founding, err := admin.LoadFounding(dir)
	if err != nil {
		return err
	}
	var ms []admin.Member
	var lastErr error
	for _, n := range nodes {
		if ms, lastErr = fetchMembers(n, priv, st.NetworkPub, founding, *allowPlain); lastErr == nil {
			break
		}
	}
	if lastErr != nil {
		return lastErr
	}
	if sub == "list" {
		for _, m := range ms {
			state := "active"
			if m.Revoked {
				state = "revoked: " + m.Reason
			}
			fmt.Fprintf(out, "%-24s %x  invite=%-5v founding=%-5v %s  «%s»\n", m.Tag(), m.UserID, m.CanInvite, m.Founding, state, m.Display)
		}
		return nil
	}
	m, err := admin.Find(ms, who)
	if err != nil {
		return err
	}
	var rec *pb.Record
	switch sub {
	case "revoke":
		if !*yes && !confirm(in, fmt.Sprintf("Revoke %s «%s» (%x)? This cannot be undone. [y/N] ", m.Tag(), m.Display, m.UserID)) {
			return errors.New("cancelled")
		}
		rec, err = admin.SignRevocation(dir, priv, m.UserID, *reason, time.Now())
	case "invite-rights":
		if *on == *off {
			return errors.New("user invite-rights: exactly one of --on, --off")
		}
		rec, err = admin.SignInviteRights(dir, priv, m.UserID, *on, m.RightsVersion+1, time.Now())
	}
	if err != nil {
		return err
	}
	good := 0
	for _, n := range nodes {
		res := publishTo(n, "network.publish", rec, *allowPlain)
		if res == "ok" {
			good++
		}
		fmt.Fprintf(out, "%-12s %s\n", n.Label, res)
	}
	if good == 0 {
		return errors.New("not published to any node (the record is saved in the admin dir; retry later)")
	}
	return nil
}

func fetchMembers(n *pb.NodeInfo, priv ed25519.PrivateKey, netPub ed25519.PublicKey, founding [][]byte, allowPlain bool) ([]admin.Member, error) {
	var lastErr error = errors.New("no usable endpoint")
	for _, ep := range n.Endpoints {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		c, err := client.Dial(ctx, ep, allowPlain)
		if err != nil {
			cancel()
			lastErr = err
			continue
		}
		ts := time.Now().UnixMilli()
		var batch pb.RecordBatch
		err = c.Call(ctx, "admin.users", &pb.AdminRequest{TsMs: ts,
			Signature: ed25519.Sign(priv, keys.AdminAuthMessage(c.Hello().NodeId, c.Hello().Nonce, ts))}, &batch)
		c.Close()
		cancel()
		if err == nil {
			return admin.Members(batch.Records, netPub, founding), nil
		}
		lastErr = err
	}
	return nil, fmt.Errorf("%s: %w", n.Label, lastErr)
}

func confirm(in io.Reader, prompt string) bool {
	fmt.Fprint(os.Stderr, prompt)
	line, _ := bufio.NewReader(in).ReadString('\n')
	return strings.EqualFold(strings.TrimSpace(line), "y")
}
```

  Factor the "read manifest.bin, select `--via` nodes" part of `publishNews` (main.go:515-538) into
  `manifestNodes(dir string, via []string) ([]*pb.NodeInfo, error)` and use it in `publishNews` too. Note the
  passphrase is read from `in` before `confirm`; both share `in` (the existing `passphrase` uses `term.ReadPassword` on
  a terminal and a line otherwise), so in tests feed `"passphrase\ny\n"` or use `--yes` with `OTTER_ADMIN_PASSPHRASE`.

- [ ] **Step 4: Docs.** `docs/08-operations.md`: a "Members" section: `user list` (verify the list on two nodes),
  `user revoke`, `user invite-rights`, `user found` + `manifest sign` + `manifest publish`.

- [ ] **Step 5: Run** Step 1 tests → PASS; `go test ./... -count=1` → `ok`.

- [ ] **Step 6: Commit**

```bash
git add internal/keys/auth.go internal/admin internal/service/membership.go internal/gateway/methods.go cmd/otter-admin
oc -m "otter-admin: user list/revoke/invite-rights/found; admin.users with a network-key signature; bootstrap links carry the INVITE (C2)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
cd ../docs && git add 08-operations.md && oc -m "operations: member commands (M9.2)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 36: App — registration and invites carry the chain; the secret stays on the phone

**Goal:** New invites carry `redeem_pub` and the signed record in the link; registration fills `invite_record`/`invite_proof`, sends no secret, and later profile versions keep the chain.
**Findings closed:** limit 3, C6 (app side)

**Files:**
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/invite/InviteRepository.kt` (`create` 44-63)
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/registration/Registration.kt` (`doRegister` 96-151, `map`, `RegistrationError`)
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/account/DirectoryEntries.kt` (`build`, `record`)
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/profile/ProfileRepository.kt:82`
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/settings/Settings.kt` (own invite chain)
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/directory/DirectorySync.kt` (`applyOwn` keeps the chain)
- Modify: `otter-android/feature/chats/src/main/kotlin/app/ottermsg/feature/chats/InviteViewModel.kt`, `InviteScreen.kt`, `res/values{,-en}/strings.xml`
- Modify: `otter-android/feature/onboarding/src/main/kotlin/app/ottermsg/feature/onboarding/OnboardingViewModel.kt` (error text), strings
- Modify (tests): `core/data/src/test/kotlin/app/ottermsg/core/data/FakeNode.kt` (`bootstrapLink`, `register`, invite creation)
- Test: `core/data/src/test/kotlin/app/ottermsg/core/data/RegistrationTest.kt`

**Acceptance Criteria:**
- [ ] `InviteRepository.create` publishes an `INVITE` with `redeem_pub = InviteKeys.redeemKey(secret).publicKey` and the link's bundle has `invite` = that record.
- [ ] `RegisterRequest` has no `invite_secret`; the entry carries `invite_record` = bundle.invite bytes and a proof that verifies.
- [ ] A link without `invite` (made by 0.9.0 or older) fails with `RegistrationError.InviteOutdated` («Ссылка устарела…») without contacting a node.
- [ ] Profile updates (version ≥ 2) carry the same `invite_record` and `invite_proof`; after a restore the first directory sync stores them.
- [ ] `invite.create` → `UNAUTHORIZED` shows «Приглашать могут только участники, которым это разрешил администратор».
- [ ] FakeNode verifies the chain like the Go node (proof and inviter signature) — a hostile FakeNode test is in Task 37.

**Verify:** `cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*Registration*' --tests '*Invite*' --tests '*Profile*' :feature:chats:testDebugUnitTest :feature:onboarding:testDebugUnitTest` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: FakeNode.** In `FakeNode.kt`: `bootstrapLink` creates a network-signed `INVITE` with `redeem_pub` and puts it in
  the bundle; `register` verifies like `Service.admitChain`:

```kotlin
    fun bootstrapLink(ttlMs: Long = 3_600_000): String {
        val secret = ByteArray(32).also(SecureRandom()::nextBytes)
        val inv = Invite.newBuilder().setInviteId(bs(sha(secret))).setExpiresMs(clock() + ttlMs)
            .setRedeemPub(bs(InviteKeys.redeemKey(secret).publicKey)).build()
        val rec = RecordCodec.sign(RecordCodec.body(RecordType.INVITE, Ids.id16(network.publicKey), inv.toByteArray(),
            expiresMs = clock() + ttlMs, createdMs = clock()), network)
        synchronized(lock) { invites[sha(secret).hex()] = InviteState(Ids.id16(network.publicKey), clock() + ttlMs) }
        return InviteLink.encode(InviteBundle.newBuilder().setNetworkPub(bs(network.publicKey)).setManifest(manifest)
            .setSecret(bs(secret)).setInvite(rec).build())
    }
```

  In `Session.register`, replace the secret lookup with:

```kotlin
            val dirBody = body(req.directoryEntry)
            val entry = DirectoryEntry.parseFrom(dirBody.payload)
            if (entry.inviteRecord.isEmpty) fail(Status.STATUS_INVALID, "no invite chain (update the app)")
            val invRec = Record.parseFrom(entry.inviteRecord)
            val invBody = body(invRec)
            val inv = Invite.parseFrom(invBody.payload)
            val signer = if (invBody.author.toByteArray().contentEquals(Ids.id16(network.publicKey))) network.publicKey
                else users[invBody.author.hex()]?.entry?.accountPub?.toByteArray() ?: fail(Status.STATUS_RETRY_LATER, "inviter not known")
            if (!RecordCodec.verify(invRec, signer)) fail(Status.STATUS_INVALID, "invite signature")
            if (!Ed25519.verify(inv.redeemPub.toByteArray(), InviteKeys.redeemMessage(inv.inviteId.toByteArray(),
                    entry.userId.toByteArray(), entry.accountPub.toByteArray()), entry.inviteProof.toByteArray()))
                fail(Status.STATUS_INVALID, "invite proof")
            val inviteId = inv.inviteId.toByteArray()
            val st = invites.getOrPut(inviteId.hex()) { InviteState(invBody.author.toByteArray(), inv.expiresMs) }
            if (st.usedBy != null) fail(Status.STATUS_CONFLICT, "invite already used")
            if (st.expiresMs < clock()) fail(Status.STATUS_CONFLICT, "invite expired")
```

  (the rest — binding, username, prekeys, `invite_used` matching `inviteId` — unchanged). In `createInvite` reject an
  `Invite` whose `redeemPub.size() != 32` with `STATUS_INVALID`.

- [ ] **Step 2: Failing test** — add to `RegistrationTest.kt`:

```kotlin
    @Test fun registrationCarriesChainNotSecret() = runBlocking {
        val sent = mutableListOf<RegisterRequest>()
        node.onRegister = { sent += it } // a hook in FakeNode.register: records the request (add `var onRegister: (RegisterRequest) -> Unit = {}`)
        g.register(node.bootstrapLink(), "Я", "me_user").getOrThrow()
        val req = sent.single()
        assertTrue(req.inviteSecret.isEmpty)
        val e = DirectoryEntry.parseFrom(RecordBody.parseFrom(req.directoryEntry.body).payload)
        assertFalse(e.inviteRecord.isEmpty)
        assertEquals(64, e.inviteProof.size())
        // a profile update keeps the chain (publish it the way ProfileTest does after setDisplayName)
        g.online()
        g.profile.setDisplayName("Я2").getOrThrow()
        eventually { node.directoryUpdates(g.me.userId) == 1 }
        val v2 = node.directoryRecords().map { DirectoryEntry.parseFrom(RecordBody.parseFrom(it.body).payload) }
            .single { it.userId.toByteArray().contentEquals(g.me.userId) }
        assertEquals(e.inviteRecord, v2.inviteRecord)
        assertEquals(e.inviteProof, v2.inviteProof)
    }

    @Test fun oldLinkIsRefusedLocally() = runBlocking {
        val old = InviteLink.decode(node.bootstrapLink()).toBuilder().clearInvite().build()
        val r = g.register(InviteLink.encode(old), "Я", "me_user")
        assertEquals(RegistrationError.InviteOutdated, r.exceptionOrNull())
        assertEquals(0, node.registrations) // FakeNode counter of register calls (add it)
    }
```

  (`ProfileRepository.setDisplayName` stores the change; copy from `ProfileTest.kt:42-55` how that test lets it reach
  the node.) Run → FAIL.

- [ ] **Step 3: Implement.** `Settings.kt` (keys in the companion with the others):

```kotlin
    /** Our invite chain (D100): copied into every new version of our directory entry. */
    suspend fun ownInvite(): Pair<ByteArray, ByteArray>? {
        val rec = dao.get(OWN_INVITE_RECORD) ?: return null
        val proof = dao.get(OWN_INVITE_PROOF) ?: return null
        return rec to proof
    }
    suspend fun setOwnInvite(record: ByteArray, proof: ByteArray) {
        dao.put(SettingEntity(OWN_INVITE_RECORD, record)); dao.put(SettingEntity(OWN_INVITE_PROOF, proof))
    }
    // companion: const val OWN_INVITE_RECORD = "own_invite_record"; const val OWN_INVITE_PROOF = "own_invite_proof"
```

  `DirectoryEntries.kt`:

```kotlin
    fun build(userId: ByteArray, username: String, displayName: String, seed: ByteArray, version: Int, registeredMs: Long,
              invite: Pair<ByteArray, ByteArray>? = null): DirectoryEntry {
        val account = SeedKeys.accountKeyPair(seed)
        val identity = IdentityKeys.fromSeed(seed)
        val b = DirectoryEntry.newBuilder().setUserId(bs(userId)).setUsername(username).setDisplayName(displayName)
            .setAccountPub(bs(account.publicKey)).setIdentityPub(bs(identity.publicKey.serialize()))
            .setIdentitySig(bs(IdentityKeys.bindAccount(identity, account.publicKey)))
            .setVersion(version.toLong()).setRegisteredMs(registeredMs)
        invite?.let { (rec, proof) -> b.setInviteRecord(bs(rec)).setInviteProof(bs(proof)) }
        return b.build()
    }

    fun record(me: LocalAccount, displayName: String, version: Int, nowMs: Long, invite: Pair<ByteArray, ByteArray>?): Record =
        RecordCodec.sign(RecordCodec.body(RecordType.DIRECTORY_ENTRY, me.userId,
            build(me.userId, me.username, displayName, me.seed, version, me.createdMs, invite).toByteArray(), createdMs = nowMs), me.accountKey)
```

  (`can_invite` is no longer set: nodes ignore it.) `ProfileRepository.kt:82`: pass `settings.ownInvite()`.
  `Registration.doRegister`, after decoding the bundle:

```kotlin
        if (!bundle.hasInvite()) throw RegistrationError.InviteOutdated
        val secret = bundle.secret.toByteArray()
        val inviteId = MessageDigest.getInstance("SHA-256").digest(secret)
        val inviteRecord = bundle.invite.toByteArray()
        // … keys and prekeys as before …
        val proof = InviteKeys.redeemKey(secret).sign(InviteKeys.redeemMessage(inviteId, userId, account.publicKey))
        val entry = DirectoryEntries.build(userId, user, name, seed, version = 1, registeredMs = now, invite = inviteRecord to proof)
        // …
        val req = RegisterRequest.newBuilder() // no invite secret: it never leaves this phone (D100)
            .setDirectoryEntry(rec(RecordType.DIRECTORY_ENTRY, entry)).setPrekeys(rec(RecordType.PREKEYS, prekeys))
            .setInviteUsed(rec(RecordType.INVITE_USED, used)).build()
```

  and inside the persisting transaction `settings.setOwnInvite(inviteRecord, proof)`. Add
  `data object InviteOutdated : RegistrationError() { private fun readResolve(): Any = InviteOutdated }`; in `map`:
  `e.status == Status.STATUS_INVALID && "invite chain" in msg -> RegistrationError.InviteOutdated`.
  `DirectorySync.applyOwn`: `if (settings.ownInvite() == null && !e.inviteRecord.isEmpty) settings.setOwnInvite(e.inviteRecord.toByteArray(), e.inviteProof.toByteArray())`
  (a restored phone learns its chain from its own verified entry).
  `InviteRepository.create`:

```kotlin
        val inv = Invite.newBuilder().setInviteId(bs(MessageDigest.getInstance("SHA-256").digest(secret))).setExpiresMs(expires)
            .setRedeemPub(bs(InviteKeys.redeemKey(secret).publicKey)).build()
        val rec = RecordCodec.sign(RecordCodec.body(RecordType.INVITE, me.userId, inv.toByteArray(), expiresMs = expires, createdMs = now), me.accountKey)
        try { api.createInvite(rec) } catch (e: RpcException) {
            if (e.status == Status.STATUS_UNAUTHORIZED) throw NoInviteRightsException()
            throw e
        }
        val bundle = InviteBundle.newBuilder() /* … as before … */ .setInvite(rec).build()
```

  with `class NoInviteRightsException : Exception("no invite rights")`. `InviteViewModel`: a new state
  `data object NoRights : InviteUiState` for that exception; `InviteScreen` shows `R.string.invite_no_rights`:
  ru «Приглашать могут только участники, которым это разрешил администратор.», en «Only members the administrator
  allowed can invite.». Onboarding: `RegistrationError.InviteOutdated -> R.string.onb_err_invite_outdated`
  (ru «Ссылка устарела. Попросите новое приглашение.», en «This link is outdated. Ask for a new invite.»).
  Run → PASS (fix the other tests that build entries by hand only if they break; `DirectorySyncTest.entry` is updated in Task 37).

- [ ] **Step 4: Commit**

```bash
git add core/data feature/chats feature/onboarding
oc -m "app: invites carry a redeem key and the signed record; registration proves the invite without sending the secret (limit 3)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 37: App — the phone checks membership itself; removed members are shown and unreachable

**Goal:** `DirectorySync` admits a new contact only with a verified chain or founding membership, applies network-signed revocations and the double-redemption rule, and the UI/outbox/receiver treat revoked contacts as gone.
**Findings closed:** C2 (app), C5 (inviter notice), limit 3 against a hostile node feeding the directory

**Files:**
- Create: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/directory/Membership.kt`
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/directory/DirectorySync.kt` (whole `apply`; constructor gains `ManifestDao`, `MessageDao`)
- Modify: `otter-android/core/database/src/main/kotlin/app/ottermsg/core/database/model/MessageStatus.kt` (`SYSTEM_MEMBER = 7`)
- Modify: `otter-android/core/database/src/main/kotlin/app/ottermsg/core/database/dao/ContactDao.kt` (`observeRevokedIds`)
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/messaging/Outbox.kt` (`process` 124-128),
  `MailboxReceiver.kt` (after the signature check, ~line 66), `MessageRepository.kt` (`ConversationStore.observeRevokedIds`)
- Modify: `otter-android/feature/conversation/src/main/kotlin/app/ottermsg/feature/conversation/ConversationViewModel.kt`
  (`ConversationUi`, `conversationUi`, `ui`), `ConversationScreen.kt` (bottom bar 265-268, chips 287-290, `PeerRemovedNotice`),
  `MessageGrouping.kt` (`MessageUi.memberNote`), `res/values{,-en}/strings.xml`
- Modify (tests): `core/data/src/test/kotlin/app/ottermsg/core/data/TestGraph.kt:71`, `LiveClient.kt:52`, `FakeNode.kt` (`revoke`, `directoryRecords`), `DirectorySyncTest.kt` (`entry` helper)
- Test: `core/data/src/test/kotlin/app/ottermsg/core/data/DirectorySyncTest.kt`, `feature/conversation/src/test/.../ConversationUiTest.kt` (existing mapping test file; `grep -rln conversationUi feature/conversation/src/test`)

**Acceptance Criteria:**
- [ ] Hostile node: an entry without chain (not founding), with a chain copied from another account, or with an `INVITE`
  "by the network" signed by another key is not added as a contact; a valid chain or a manifest founding member is.
- [ ] A `REVOCATION` signed by the network key marks the contact revoked (sticky across later syncs); one signed by any
  other key is ignored.
- [ ] Two contacts that redeemed one invite: the higher `SHA-256(invite_proof)` is marked revoked; if we were the
  inviter, its chat gets a `SYSTEM_MEMBER` line «Приглашение использовали дважды, этот аккаунт отключён».
- [ ] A newly revoked contact's 1:1 chat gets a `SYSTEM_MEMBER` line «Участник удалён»; the composer is replaced by the
  notice «Участник удалён», no call button; queued outbox items to it fail permanently; envelopes from it are acked and dropped.

**Verify:** `cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*DirectorySync*' --tests '*MessagingFlow*' :feature:conversation:testDebugUnitTest` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Test helpers.** `FakeNode`: `private val membership = mutableListOf<Record>()`,
  `fun revoke(user: ByteArray, signer: Ed25519.KeyPair = network) { synchronized(lock) { membership += RecordCodec.sign(
  RecordCodec.body(RecordType.REVOCATION, Ids.id16(network.publicKey), Revocation.newBuilder().setUserId(bs(user)).build().toByteArray()), signer) } }`,
  and `directoryRecords()` returns `users.values.map { it.record } + membership`. `DirectorySyncTest.entry(...)` gains
  `invite: Pair<Record, ByteArray>? = null` (record + secret) and fills `inviteRecord`/`inviteProof` with
  `InviteKeys`; add a helper `networkInvite(secret)` signing an `INVITE` with `node.network`.

- [ ] **Step 2: Failing tests** (append to `DirectorySyncTest.kt`):

```kotlin
    private fun invite(signer: Ed25519.KeyPair, author: ByteArray, secret: ByteArray): Record {
        val inv = Invite.newBuilder().setInviteId(bs(sha256(secret))).setExpiresMs(Long.MAX_VALUE / 2)
            .setRedeemPub(bs(InviteKeys.redeemKey(secret).publicKey)).build()
        return RecordCodec.sign(RecordCodec.body(RecordType.INVITE, author, inv.toByteArray(), createdMs = 1), signer)
    }
    private fun chained(seed: Byte, name: String, inv: Record, secret: ByteArray, copyFrom: Record? = null): Record {
        val acc = SeedKeys.accountKeyPair(ByteArray(32) { seed })
        val id = IdentityKeys.fromSeed(ByteArray(32) { seed })
        val uid = Ids.id16(acc.publicKey)
        val b = DirectoryEntry.newBuilder().setUserId(bs(uid)).setUsername(name).setDisplayName(name.uppercase())
            .setAccountPub(bs(acc.publicKey)).setIdentityPub(bs(id.publicKey.serialize()))
            .setIdentitySig(bs(IdentityKeys.bindAccount(id, acc.publicKey))).setVersion(1).setRegisteredMs(2)
        if (copyFrom != null) {
            val src = DirectoryEntry.parseFrom(RecordBody.parseFrom(copyFrom.body).payload)
            b.setInviteRecord(src.inviteRecord).setInviteProof(src.inviteProof)
        } else {
            b.setInviteRecord(inv.toByteString()).setInviteProof(bs(InviteKeys.redeemKey(secret)
                .sign(InviteKeys.redeemMessage(sha256(secret), uid, acc.publicKey))))
        }
        return RecordCodec.sign(RecordCodec.body(RecordType.DIRECTORY_ENTRY, uid, b.build().toByteArray()), acc)
    }

    @Test fun hostileDirectoryCannotAddMembers() = runBlocking {
        g.register(node.bootstrapLink(), "Я", "me_user").getOrThrow()
        val s1 = ByteArray(32) { 1 }
        val good = chained(2, "anna", invite(node.network, Ids.id16(node.network.publicKey), s1), s1)
        val bare = entry(3, "mallory")                                        // no chain
        val copied = chained(4, "mallory2", invite(node.network, Ids.id16(node.network.publicKey), s1), s1, copyFrom = good)
        val rogue = Ed25519.keyPairFromSeed(ByteArray(32) { 77 })            // a node's key pretending to be the network
        val s2 = ByteArray(32) { 2 }
        val forged = chained(5, "mallory3", invite(rogue, Ids.id16(node.network.publicKey), s2), s2)
        g.directory.apply(listOf(bare, copied, forged, good))
        val c = g.db.contactDao()
        assertNotNull(c.get(uid(2)))
        assertNull(c.get(uid(3))); assertNull(c.get(uid(4))); assertNull(c.get(uid(5)))
    }

    @Test fun revocationAndDuplicateInvite() = runBlocking {
        g.register(node.bootstrapLink(), "Я", "me_user").getOrThrow()
        val s = ByteArray(32) { 6 }
        val myInvite = invite(g.me.accountKey, g.me.userId, s) // we invited both: one link used twice
        val x = chained(7, "xenia", myInvite, s)
        val y = chained(8, "yuri", myInvite, s)
        g.directory.apply(listOf(x, y))
        val proofHash = { r: Record -> sha256(DirectoryEntry.parseFrom(RecordBody.parseFrom(r.body).payload).inviteProof.toByteArray()) }
        val loser = if (compare(proofHash(x), proofHash(y)) < 0) uid(8) else uid(7)
        val winner = if (loser.contentEquals(uid(7))) uid(8) else uid(7)
        val c = g.db.contactDao()
        assertTrue(c.get(loser)!!.revoked)
        assertFalse(c.get(winner)!!.revoked)
        val cid = g.db.conversationDao().byPeer(loser)!!.id
        assertTrue(g.db.messageDao().observe(cid).first().any { it.kind == MessageKind.SYSTEM_MEMBER && String(it.systemData!!) == "duplicate_invite" })

        node.revoke(winner, signer = Ed25519.keyPairFromSeed(ByteArray(32) { 77 })) // forged: ignored
        g.directory.apply(node.directoryRecords() + x + y)
        assertFalse(c.get(winner)!!.revoked)
        node.revoke(winner)
        g.directory.apply(node.directoryRecords() + x + y)
        assertTrue(c.get(winner)!!.revoked)
        g.directory.apply(listOf(x, y)) // a later sync without the revocation does not un-revoke
        assertTrue(c.get(winner)!!.revoked)
    }
```

  (helpers `sha256(b) = MessageDigest.getInstance("SHA-256").digest(b)`, `compare(a, b) = Membership.compareUnsigned(a, b)`;
  `MessageDao.observe(cid)` is the existing per-conversation flow.) Run → FAIL.

- [ ] **Step 3: Implement** `Membership.kt`:

```kotlin
package app.ottermsg.core.data.directory

import app.ottermsg.core.crypto.Ed25519
import app.ottermsg.core.crypto.Ids
import app.ottermsg.core.crypto.InviteKeys
import app.ottermsg.core.crypto.RecordCodec
import app.ottermsg.proto.v1.DirectoryEntry
import app.ottermsg.proto.v1.Invite
import app.ottermsg.proto.v1.Record
import app.ottermsg.proto.v1.RecordBody
import app.ottermsg.proto.v1.RecordType
import app.ottermsg.proto.v1.Revocation
import java.security.MessageDigest

/** A verified invite redemption (D100/D102). */
class Redemption(val inviteId: ByteArray, val rank: ByteArray, val inviter: ByteArray)

/** Membership rules the phone checks itself (D104): a node can hide entries, it cannot invent members. */
object Membership {
    /** The redemption of [e] if its chain verifies; [keyOf] gives the account key of an already accepted member. */
    fun chain(e: DirectoryEntry, networkPub: ByteArray, keyOf: (ByteArray) -> ByteArray?): Redemption? = runCatching {
        if (e.inviteRecord.isEmpty || e.inviteProof.size() != 64) return null
        val rec = Record.parseFrom(e.inviteRecord)
        val body = RecordBody.parseFrom(rec.body)
        if (body.type != RecordType.INVITE) return null
        val inv = Invite.parseFrom(body.payload)
        val author = body.author.toByteArray()
        val signer = if (author.contentEquals(Ids.id16(networkPub))) networkPub else keyOf(author) ?: return null
        if (!RecordCodec.verify(rec, signer) || inv.redeemPub.size() != 32) return null
        val msg = InviteKeys.redeemMessage(inv.inviteId.toByteArray(), e.userId.toByteArray(), e.accountPub.toByteArray())
        if (!Ed25519.verify(inv.redeemPub.toByteArray(), msg, e.inviteProof.toByteArray())) return null
        Redemption(inv.inviteId.toByteArray(), MessageDigest.getInstance("SHA-256").digest(e.inviteProof.toByteArray()), author)
    }.getOrNull()

    /** user_id of a REVOCATION signed by the network key, else null. */
    fun revoked(rec: Record, networkPub: ByteArray): ByteArray? = runCatching {
        val body = RecordBody.parseFrom(rec.body)
        if (body.type != RecordType.REVOCATION || !body.author.toByteArray().contentEquals(Ids.id16(networkPub)) ||
            !RecordCodec.verify(rec, networkPub)) return null
        Revocation.parseFrom(body.payload).userId.toByteArray().takeIf { it.size == 16 }
    }.getOrNull()

    fun compareUnsigned(a: ByteArray, b: ByteArray): Int {
        for (i in 0 until minOf(a.size, b.size)) {
            val d = (a[i].toInt() and 0xff) - (b[i].toInt() and 0xff)
            if (d != 0) return d
        }
        return a.size - b.size
    }
}
```

  `DirectorySync` (constructor adds `private val manifests: ManifestDao, private val messages: MessageDao, private val clock: Clock`;
  Hilt needs nothing else; update both hand-built graphs, `TestGraph.kt:71` and `LiveClient.kt:52`, to
  `DirectorySync(accounts, db.contactDao(), db.conversationDao(), settings, db.accountDao(), db.manifestDao(), db.messageDao(), clock)`):

```kotlin
    suspend fun apply(records: List<Record>) = mutex.withLock {
        val me = accounts.require()
        val networkPub = settings.networkPub()
        val founding = manifests.latest()?.let { runCatching { ManifestVerifier.verify(it.raw, networkPub, 0) }.getOrNull() }
            ?.foundingMembersList?.map { it.toByteArray().hex() }?.toSet().orEmpty()
        val keys = HashMap<String, ByteArray>()
        keys[me.userId.hex()] = me.accountKey.publicKey
        contacts.all().forEach { keys[it.userId.hex()] = it.accountPub }
        // accept: known contacts, founding members, and entries whose inviter is accepted (fixpoint over the batch)
        val pending = records.mapNotNull { verify(it) }.toMutableList()
        val accepted = mutableListOf<Pair<DirectoryEntry, Redemption?>>()
        var progress = true
        while (progress) {
            progress = false
            val it = pending.iterator()
            while (it.hasNext()) {
                val e = it.next()
                val id = e.userId.toByteArray()
                val red = Membership.chain(e, networkPub) { a -> keys[a.hex()] }
                if (red != null || keys.containsKey(id.hex()) || id.hex() in founding) {
                    accepted += e to red
                    keys[id.hex()] = e.accountPub.toByteArray()
                    it.remove(); progress = true
                }
            }
        }
        if (pending.isNotEmpty()) log.info("${pending.size} directory entr(ies) without a verifiable invite ignored")
        // D102: of several redemptions of one invite, the lowest SHA-256(proof) stays
        val duplicates = accepted.mapNotNull { (e, r) -> r?.let { e to it } }.groupBy { it.second.inviteId.hex() }.values
            .filter { it.size > 1 }
            .flatMap { g -> g.sortedWith { a, b -> Membership.compareUnsigned(a.second.rank, b.second.rank) }.drop(1) }
        val dupIds = duplicates.associate { (e, r) -> e.userId.toByteArray().hex() to r }
        val revokedIds = records.mapNotNull { Membership.revoked(it, networkPub)?.hex() }.toSet()
        for ((e, _) in accepted) {
            val userId = e.userId.toByteArray()
            if (userId.contentEquals(me.userId)) { applyOwn(e); continue }
            val old = contacts.get(userId)
            if (old != null && old.entryVersion > e.version) continue // stale entry
            val identity = e.identityPub.toByteArray()
            val changed = old != null && !old.identityPub.contentEquals(identity)
            val dup = dupIds[userId.hex()]
            val revoked = (old?.revoked ?: false) || userId.hex() in revokedIds || dup != null
            contacts.upsert(ContactEntity(
                userId = userId, username = e.username, displayName = e.displayName,
                accountPub = e.accountPub.toByteArray(), identityPub = identity,
                verified = (old?.verified ?: false) && !changed,
                identityChanged = (old?.identityChanged ?: false) || changed,
                revoked = revoked, entryVersion = e.version, resetMs = old?.resetMs ?: 0,
            ))
            if (old == null || old.displayName != e.displayName) conversations.setTitle(userId, e.displayName)
            if (revoked && old?.revoked != true) {
                val reason = if (dup != null) "duplicate_invite" else "revoked"
                if (dup == null || dup.inviter.contentEquals(me.userId)) memberLine(userId, e.displayName, reason)
            }
        }
        // a revocation of a contact whose entry is not in this batch
        for (hex in revokedIds) {
            val c = contacts.all().firstOrNull { it.userId.hex() == hex && !it.revoked } ?: continue
            contacts.upsert(c.copy(revoked = true)); memberLine(c.userId, c.displayName, "revoked")
        }
    }

    /** A «Участник удалён» line in the 1:1 chat (created if missing, so the inviter sees a duplicate notice). */
    private suspend fun memberLine(userId: ByteArray, title: String, reason: String) {
        val now = clock.now()
        val cid = conversations.getOrCreateDirect(userId, title, now)
        messages.insert(MessageEntity(messageId = ByteArray(16).also(SecureRandom()::nextBytes), conversationId = cid, senderId = userId,
            outgoing = false, sentMs = now, receivedMs = now, body = "", status = MessageStatus.DELIVERED,
            kind = MessageKind.SYSTEM_MEMBER, systemData = reason.toByteArray()))
        conversations.touch(cid, now)
    }
```

  (`private fun ByteArray.hex()`, `companion object { private val log = java.util.logging.Logger.getLogger("DirectorySync") }`;
  for a "revoked" reason without an existing chat, `getOrCreateDirect` creates one: acceptable, the chat shows why.)
  `MessageStatus.kt`: `/** M9.2 (D104): a member was removed; system_data = "revoked" | "duplicate_invite". */ const val SYSTEM_MEMBER = 7`.
  `ContactDao`: `@Query("SELECT user_id FROM contacts WHERE revoked = 1") fun observeRevokedIds(): Flow<List<ByteArray>>`.
  `Outbox.process`: `val contact = contacts.get(item.recipientUserId) ?: throw PermanentFailure("unknown contact")` then
  `if (contact.revoked) throw PermanentFailure("member removed")`. `MailboxReceiver.handle` after
  `if (!RecordCodec.verify(rec, sender.accountPub)) { … }`: `if (sender.revoked) { acks += key; continue } // D104`.

- [ ] **Step 4: UI.** `ConversationStore` gains `fun observeRevokedIds(): Flow<Set<String>> = flowOf(emptySet())`
  (implemented in `MessageRepository` as `contacts.observeRevokedIds().map { l -> l.map { it.hex() }.toSet() }`).
  `ConversationUi` gains `val peerRemoved: Boolean = false`; `conversationUi(..., revoked: Set<String> = emptySet())`:

```kotlin
    val peerRemoved = !isGroup && !isNews && conv?.peerUserId?.hex() in revoked
    // …
        canWrite = !isNews && !peerRemoved && (!isGroup || group?.group?.iAmMember == true),
        canCall = !isGroup && !isNews && !peerRemoved && conv?.peerUserId != null, peerRemoved = peerRemoved,
```

  and in the message mapping `memberNote = if (it.kind == MessageKind.SYSTEM_MEMBER) it.systemData?.decodeToString() else null`
  (`MessageUi.memberNote: String? = null`, included in `isEvent`); exclude `SYSTEM_MEMBER` in `lastIncomingId` like
  `SYSTEM_GROUP`. ViewModel: the outer `combine(..., photos.observe(conversationId), store.observeRevokedIds())
  { p, att, rev -> conversationUi(p.conv, p.msgs, p.group, p.contacts, p.me, zone, att, rev) }`. Screen bottom bar:

```kotlin
            if (ui.canWrite) MessageComposer(/* unchanged */)
            else if (ui.peerRemoved) PeerRemovedNotice(Modifier.navigationBarsPadding())
            else if (!ui.isNews) NotMemberNotice(Modifier.navigationBarsPadding())
```

  `PeerRemovedNotice` = `NotMemberNotice` with `R.string.conv_peer_removed`; chips:
  `item.message.memberNote != null -> SystemEventChip(stringResource(if (item.message.memberNote == "duplicate_invite")
  R.string.conv_member_duplicate else R.string.conv_member_removed))`. Strings: ru `conv_peer_removed` «Участник удалён»,
  `conv_member_removed` «Участник удалён», `conv_member_duplicate` «Приглашение использовали дважды, этот аккаунт отключён»;
  en «Member removed», «Member removed», «The invite was used twice; this account is disabled». Mapping test:
  `conversationUi(conv(peer = x), …, revoked = setOf(x.hex()))` → `!canWrite && !canCall && peerRemoved`.

- [ ] **Step 5: Run** the Verify command → PASS (existing `DirectorySyncTest` cases now use chained entries or
  founding members; adjust `verifiesAndFlagsIdentityChanges` to build its entries with `chained(...)`).

- [ ] **Step 6: Commit**

```bash
git add core/data core/database feature/conversation
oc -m "app: phones verify invite chains and revocations themselves; removed members shown and unreachable (C2, C5, limit 3)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 38: App — groups drop revoked members and rotate sender keys

**Goal:** When a contact becomes revoked, every group containing it stops encrypting to it at once (our sender key rotates), and the group's designated admin removes it from the signed state.
**Findings closed:** C2 (groups)

**Files:**
- Create: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/group/GroupRevocations.kt`
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/messaging/GroupSender.kt` (`ensureShared` 33-52, `buildRecord` 58-70)
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/messaging/GroupReceiver.kt` (`onSenderKey` 68: drop from revoked)
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/sync/SyncEngine.kt` (after both `directory.sync(api)` calls, 127 and 170)
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/settings/Settings.kt` (`revocationsHandled`)
- Modify (tests): `core/data/src/test/kotlin/app/ottermsg/core/data/TestGraph.kt`, `LiveClient.kt` (`groupRevocations`, `SyncEngine` arg)
- Test: `core/data/src/test/kotlin/app/ottermsg/core/data/GroupRevocationTest.kt` (new)

**Acceptance Criteria:**
- [ ] After a contact in groups G1, G2 is revoked: our `my_distribution` and `sender_key_shared` rows of G1 and G2 are
  deleted (next group send makes and shares a new sender key with the remaining members only).
- [ ] `GroupSender.buildRecord` and `ensureShared` never include a revoked contact, even while the signed state still lists it.
- [ ] Only the group's non-revoked admin with the lowest user id signs the removal (`GroupRepository.removeMember`);
  other admins and plain members only rotate. A refused change (e.g. we are no longer admin) is logged, not fatal.
- [ ] Each revoked user is handled once per phone (persisted), also across restarts.
- [ ] SKDMs from a revoked sender are dropped.

**Verify:** `cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*GroupRevocation*' --tests '*GroupFlow*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing test** `GroupRevocationTest.kt` (three graphs on one FakeNode, as `GroupFlowTest` does; read its
  `lifecycle` setup for the helper names that create members and exchange messages):

```kotlin
@RunWith(RobolectricTestRunner::class)
class GroupRevocationTest {
    private val clock = TestClock()
    private val node = FakeNode(clock::now)

    @Test fun revokedMemberIsDroppedAndKeysRotate() = runBlocking {
        val admin = TestGraph(node, clock); val bob = TestGraph(node, clock); val eve = TestGraph(node, clock)
        try {
            admin.register(node.bootstrapLink(), "Админ", "admin1").getOrThrow()
            bob.register(node.bootstrapLink(), "Боб", "bob1").getOrThrow()
            eve.register(node.bootstrapLink(), "Ева", "eve1").getOrThrow()
            listOf(admin, bob, eve).forEach { it.online(); it.directory.sync(node.connect()) }
            admin.groups.create("Семья", family = true, members = listOf(bob.me.userId, eve.me.userId))
            val gid = admin.db.groupDao().all().single().groupId
            eventually { bob.db.groupDao().get(gid) != null && eve.db.groupDao().get(gid) != null }
            val bobConv = { bob.db.conversationDao().byGroup(gid)!!.id }
            bob.messages.sendText(bobConv(), "до")
            eventually { bob.db.groupDao().myDistribution(gid) != null }

            node.revoke(eve.me.userId)
            listOf(admin, bob).forEach { g -> g.directory.sync(node.connect()); g.groupRevocations.handle() }

            assertNull(bob.db.groupDao().myDistribution(gid))   // rotated
            assertTrue(bob.db.groupDao().sharedWith(gid, ByteArray(16)).isEmpty())
            eventually { admin.db.groupDao().members(gid).none { it.userId.contentEquals(eve.me.userId) } }
            eventually { bob.db.groupDao().members(gid).none { it.userId.contentEquals(eve.me.userId) } }
            // bob's next message is not addressed to eve
            bob.messages.sendText(bobConv(), "после")
            eventually { node.mailbox(eve.me.userId).none { isSenderKeyFrom(it, bob.me.userId, after = true) } }
            // handled once: a second pass changes nothing
            val v = admin.db.groupDao().get(gid)!!.version
            admin.groupRevocations.handle()
            assertEquals(v, admin.db.groupDao().get(gid)!!.version)
        } finally { admin.close(); bob.close(); eve.close() }
    }
}
```

  (`isSenderKeyFrom` = small helper parsing the record body: `ENVELOPE`, author bob, kind `SENDER_KEY`, created after
  the revocation.) Run → FAIL (`groupRevocations` missing).

- [ ] **Step 2: Implement** `GroupRevocations.kt`:

```kotlin
package app.ottermsg.core.data.group

import androidx.room.withTransaction
import app.ottermsg.core.data.account.AccountRepository
import app.ottermsg.core.data.settings.Settings
import app.ottermsg.core.database.OtterDatabase
import java.util.logging.Level
import java.util.logging.Logger
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.cancellation.CancellationException

/**
 * D104: a revoked member must not read new group messages. Every phone rotates its own sender key in every group that
 * still lists the member (GroupSender also never addresses revoked contacts); the group's non-revoked admin with the
 * lowest user id removes the member from the signed state, so the change reaches phones that missed the revocation.
 */
@Singleton
class GroupRevocations @Inject constructor(
    private val db: OtterDatabase, private val accounts: AccountRepository, private val groups: GroupRepository,
    private val settings: Settings,
) {
    suspend fun handle() {
        val me = accounts.require().userId
        val done = settings.revocationsHandled()
        val contacts = db.contactDao()
        val revoked = contacts.all().filter { it.revoked && it.userId.hex() !in done }
        for (c in revoked) {
            for (gid in db.groupDao().groupsWithMember(c.userId)) {
                db.withTransaction {
                    db.groupDao().deleteMyDistribution(gid)
                    db.groupDao().clearShared(gid)
                }
                val admins = db.groupDao().members(gid).filter { it.admin }.map { it.userId }
                    .filter { a -> a.contentEquals(me) || contacts.get(a)?.revoked != true }
                val designated = admins.minWithOrNull { a, b -> compareUnsigned(a, b) }
                if (designated != null && designated.contentEquals(me)) {
                    try { groups.removeMember(gid, c.userId) }
                    catch (e: CancellationException) { throw e }
                    catch (e: Exception) { log.log(Level.WARNING, "could not remove a revoked member", e) }
                }
            }
            settings.addRevocationHandled(c.userId.hex())
        }
    }

    private fun compareUnsigned(a: ByteArray, b: ByteArray): Int =
        app.ottermsg.core.data.directory.Membership.compareUnsigned(a, b)
    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }
    companion object { private val log = Logger.getLogger("GroupRevocations") }
}
```

  `Settings`: `suspend fun revocationsHandled(): Set<String>` / `suspend fun addRevocationHandled(hex: String)` stored as
  newline-joined text under `REVOCATIONS_HANDLED` (same pattern as `PENDING_REFILLS`).
  `GroupSender.ensureShared`: `val lacking = groups.members(groupId).map { it.userId }.filter { !it.contentEquals(me) &&
  it.toList() !in have && db.contactDao().get(it)?.revoked != true }`. `buildRecord`: `val to = frozen.filter {
  it.toList() in current && !it.contentEquals(me.userId) && db.contactDao().get(it)?.revoked != true }`.
  `GroupReceiver.onSenderKey`: first line `if (db.contactDao().get(sender)?.revoked == true) return`.
  `SyncEngine`: constructor gains `private val groupRevocations: GroupRevocations`; after `directory.sync(api)` at line
  127 and in the `"directory"` event branch call
  `try { groupRevocations.handle() } catch (e: CancellationException) { throw e } catch (e: Exception) { log.log(Level.WARNING, "group revocations", e) }`.
  `TestGraph` and `LiveClient.kt:76`: `val groupRevocations = GroupRevocations(db, accounts, groups, settings)` and pass
  it to `SyncEngine` (declare it before the engine).

- [ ] **Step 3: Run** → PASS; `./gradlew :core:data:testDebugUnitTest` → `BUILD SUCCESSFUL`.

- [ ] **Step 4: Commit**

```bash
git add core/data
oc -m "app: groups stop encrypting to revoked members, rotate sender keys, lowest admin removes them (C2)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 39: App — restore with a clashed username tries every candidate

**Goal:** A password restore by a name that two accounts share tries each `name#tag` candidate with the typed password; addHistory always uses the tagged name.
**Findings closed:** C12 (app side)

**Files:**
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/backup/RestoreManager.kt` (`withPassword`, `download`, `addHistory`, `map`)
- Modify (tests): `core/data/src/test/kotlin/app/ottermsg/core/data/FakeNode.kt` (`backupAuth`, `backupFetch`: clash support)
- Test: `core/data/src/test/kotlin/app/ottermsg/core/data/RestoreFlowTest.kt`

**Acceptance Criteria:**
- [ ] `backup.auth` answering `candidates` makes the phone run `download` for each candidate in order; the first whose
  password verifies is installed; if none, `WrongPassword`.
- [ ] A hostile node listing only a stranger's tag cannot make the phone install anything (the stranger's backup does
  not decrypt with the typed password; M9.1's signature checks still apply).
- [ ] `addHistory` asks for `"<username>#<hex(user_id[:4])>"` (never ambiguous).
- [ ] At most 4 candidates are tried (a node cannot make the phone run Argon2 forever).

**Verify:** `cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*Restore*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: FakeNode.** Add `val clashed = mutableSetOf<String>()` and a `fun clash(name: String)` used by tests: when
  the typed name is in `clashed` and has no `#`, `backupAuth` returns `BackupAuthResponse.newBuilder().addAllCandidates(
  users.values.filter { it.entry.username == name }.map { name + "#" + it.entry.userId.toByteArray().copyOf(4).hex() })`
  and `backupFetch` fails with `STATUS_CONFLICT`; a `name#tag` resolves to the user whose username is `name` and id
  starts with `tag` (mirror of `Store.ResolveUsername`).

- [ ] **Step 2: Failing test** (append to `RestoreFlowTest.kt`; reuse its existing "make a backup, restore on a fresh
  graph" helpers — `grep -n "@Test fun" core/data/src/test/kotlin/app/ottermsg/core/data/RestoreFlowTest.kt`):

```kotlin
    @Test fun clashedNameTriesCandidates() = runBlocking {
        val first = TestGraph(node, clock); val second = TestGraph(node, clock)
        try {
            first.register(node.bootstrapLink(), "Анна", "anna").getOrThrow()
            second.register(node.bootstrapLink(), "Анна 2", "anna_x").getOrThrow()
            node.renameForTest(second.me.userId, "anna") // the clash a partition would produce (FakeNode helper)
            node.clash("anna")
            backupWithPassword(first, "first-password-1")   // existing helper in this file
            backupWithPassword(second, "second-password-2")
            val fresh = TestGraph(node, clock)
            try {
                fresh.restore.withPassword(node.bootstrapLink(), "anna", "second-password-2").getOrThrow()
                assertArrayEquals(second.me.userId, fresh.me.userId)
            } finally { fresh.close() }
        } finally { first.close(); second.close() }
    }
```

  Run → FAIL (empty salt → wrong password).

- [ ] **Step 3: Implement** in `RestoreManager`:

```kotlin
    override suspend fun withPassword(link: String, username: String, password: String): Result<Unit> = guarded {
        check(accounts.account.value == null) { "an account is already installed" }
        val net = network(link)
        val d = connector.withNode(Endpoints.candidates(net.manifest, allowPlaintext)) { api ->
            val name = username.trim().lowercase()
            val auth = api.backupAuth(name)
            if (auth.candidatesCount == 0) download(api, name, password, auth)
            else tryCandidates(api, auth.candidatesList.take(MAX_CANDIDATES), password) // D103: a clashed name
        }
        install(net, d.snapshot, d)
    }

    /** Each candidate with the same password; the first that decrypts wins (the others fail their own verifier). */
    private suspend fun tryCandidates(api: NodeApi, names: List<String>, password: String): Downloaded {
        for (n in names) {
            try { return download(api, n, password, api.backupAuth(n)) }
            catch (e: RpcException) { if (e.status != Status.STATUS_UNAUTHORIZED) throw e }
        }
        throw RestoreError.WrongPassword
    }
```

  `download(api, username, password, auth: BackupAuthResponse)` takes the already fetched `auth` instead of calling
  `api.backupAuth` itself (if `auth.candidatesCount > 0` here, throw `RestoreError.WrongPassword`: a candidate must not
  be ambiguous). `addHistory`: `download(api, tagged, password, api.backupAuth(tagged))` with
  `val tagged = me.username + "#" + me.userId.copyOf(4).joinToString("") { "%02x".format(it) }`.
  `companion object { const val MAX_CANDIDATES = 4 }`. Coordinator: M9.1 (C1/C13) also rewrites `download`; apply this
  change on top of it — the candidate loop is outside `download`.

- [ ] **Step 4: Run** → PASS.

- [ ] **Step 5: Commit**

```bash
git add core/data
oc -m "app: restore by a clashed username tries each name#tag with the typed password (C12)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

#### Notes for the M9.2 rollout task (coordinator)

1. Before deploying server 0.9.1: `otter-admin user list --via <each node>` on 0.9.0 is not possible (`admin.users` is
   new) — so deploy 0.9.1 to all nodes first, then `user list` against every node and check they show the same accounts
   (2 today). Then `user found <id> <id>`, `manifest sign`, `manifest publish`. Existing rows stay members on existing
   nodes without this; the manifest list is what a **new** node (ru-1) and the phones need.
2. Outstanding invite links made by app ≤ 0.9.0 stop working at the server upgrade (no `redeem_pub`). Release app 0.9.1
   together with the server and tell the family in the news.
3. App 0.9.0 phones keep working (login, messages); they cannot register new accounts or create invites until updated.
4. Phones need the manifest with `founding_members` before 0.9.1's stricter directory check matters for *new* contacts;
   existing contacts are never removed by it.

#### Owner questions

1. **Field 11 is a proof, not the secret** (deviates from the fixed allocation's name `invite_secret`, same number and
   type). With the raw secret in a replicated entry, a hostile node that sees a registration (or any member reading the
   directory) can redeem the same invite for its own account and, by grinding, win the C5 rule — admitting itself and
   disabling the real invitee. A signature by a key derived from the secret binds the redemption to one account; the
   secret never leaves the phone. **Recommended: yes, rename to `invite_proof`.**
2. **Who may invite after M9.2?** Recommended: only accounts the admin invited (bootstrap) and the founding members;
   member-invited accounts need `otter-admin user invite-rights NAME --on`. Alternative: inherit the inviter's rights.
3. **Old invite links die at the upgrade** (they lack `redeem_pub`). Recommended: accept (2 users; create new links after updating).
4. **Grandfathering via `Manifest.founding_members`** (the two current accounts). Recommended: yes; the admin may add
   later accounts the same way (admission without invite).
5. **Rights and revocation are judged at the invite's `created_ms`** (deterministic on all nodes). A member whose rights
   were withdrawn could still collude by backdating an invite; the remedy is to revoke that member. Recommended: accept
   and document.
6. **Restore with a clashed name**: the phone tries every candidate with the typed password (no tag to remember; a lost
   phone cannot know its tag). Recommended: yes.
7. **Revocation is permanent** and deletes the account's queued mail, prekeys and push tokens on every node; re-joining
   needs a new invite and a new account (or M9.3 `REKEY`). Recommended: yes.
8. **Group removal is done by the lowest-id non-revoked admin**; all members rotate their keys immediately anyway.
   Recommended: yes.

---

## M9.2b — Limits, races and the M8 hostile-node review

Branch `m9-2-membership` in `otter-server`, `otter-android` and `docs` (shared with M9.2a, Tasks 30–39, which come
first). Server **0.9.1**, app **0.9.1 / versionCode 12**. Environment: `export PATH=/usr/lib/go-1.26/bin:$HOME/go/bin:$PATH`;
`export JAVA_HOME=~/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2`.

**Proto additions:** none beyond the fixed allocations. (No RPC, field or message changes: the restore slow-down is
reported with the existing `STATUS_RETRY_LATER` and a message text; budgets use the existing `STATUS_QUOTA`.)

**Store migrations added by this section:** `0012_restore_limits.sql` (Task 40), `0013_record_budgets.sql`
(Task 42), `0014_invite_budget.sql` (Task 43). Today the last file is `0008_netlog.sql`; M9.0/M9.1/Tasks 30–39 may add
files. Migrations run in name order and only once: before Task 40, run `ls otter-server/internal/store/migrations`
and, if the last number is not 0011, renumber these three to follow it (contents unchanged).

**Verified facts** (2026-11-14, `otter-server` main @ `9a6c3fa`, `otter-android` main, read-only):

| Question | Answer | Source |
|---|---|---|
| Restore limits today | `BackupFetch` reads `AuthFailures` (5/h per username) and `AuthFailuresTotal` (**20/day for the whole node**) on the *reader* pool, compares the verifier, and only then `AddAuthFailure` in a separate write. → anybody can lock every restore on a node for a day with 20 bad requests (C4); N parallel wrong attempts all pass the check before any is counted (C10). | `internal/service/backup.go:22-23,70-98`, `internal/store/backups.go:50-70` |
| `auth_failures` | `(username TEXT, at_ms INTEGER)`, indexes `(username, at_ms)`, `(at_ms)`; rows older than 24 h deleted by the janitor. No source column. | `migrations/0001_init.sql:21`, `0005_backups.sql:8-9`, `store/janitor.go` |
| Where the client IP is | Phones only use WSS (D70/D75: no CDN, no REALITY in the app). `gateway.ServeHTTP` gets the `*http.Request` from `wss.NewServer` → `http.Server` with Go's own TLS → `r.RemoteAddr` **is the phone's TCP source**. The same gateway is also mounted on the REALITY inbound's internal listener (`startReality`: `net.Listen("tcp","127.0.0.1:0")`, Xray `freedom` forwards) → there `RemoteAddr` is always loopback. No reverse proxy in `deploy/`; nothing reads `X-Forwarded-For`. | `cmd/otter-node/main.go:328-345,371-394`, `internal/transport/wss/server.go`, `internal/gateway/gateway.go:117-130` |
| Writer model | One writer goroutine, batches of requests, each in `SAVEPOINT req`; `Store.write(fn)` runs `fn` inside it. Count + insert inside one `fn` is therefore atomic against every other write. | `internal/store/apply.go:104-218` |
| Blob limits today | `CreateBlob` reads `PersistentBlobs` and `UserBlobBytes` on the reader pool, then `ApplyFrom` → parallel creates overshoot (C9). Replicated `BLOB_META` are never quota-checked (by design; they are signed by the author). | `internal/service/blobs.go:78-110` |
| PREKEYS storage | Every `prekeys.upload` is a new record kept forever; one-time keys `INSERT OR IGNORE` with no per-device cap (one record ≤ 200 keys, `MaxOneTimePrekeys`); rows only drop on a newer install. Key ids are unique per (user, device, kind) (PRIMARY KEY) and the phone never reuses them (`settings.nextOneTimeId`); a restore restarts ids at 1 with a newer `installed_ms`. Refill: 50 keys (`PrekeyRefill.BATCH`) when a node reports < 10 (`LowPrekeys`); registration/restore upload 50 per manifest node. `TakePrekeys` hands out the lowest unconsumed id **owned by this node**. | `store/typed.go:67-119`, `store/query.go:135-185`, `records/validate.go:298-313`, `PrekeyRefill.kt`, `InstallGuard.kt:36-55`, `Registration.kt:143` |
| PUSH_TOKEN storage | Derived row = newest `(created_ms, record_key)` per (user, device); **every** older record stays in `records` and replicates. Device is always 1 (validator). | `store/typed.go:121-142`, `records/validate.go:262-270` |
| INVITE storage | `invites(invite_id, inviter, expires_ms, used_by)`; INVITE records never deleted; no per-author cap; validator checks only id length and `expires_ms > 0`. App invites: 7 days, record `expires_ms` = invite expiry; admin bootstrap `--ttl` default 168 h. Test helpers sign INVITEs **without** a record `expires_ms`. | `store/typed.go:43-50`, `records/validate.go:212-216`, `InviteRepository.kt:34-43`, `cmd/otter-admin/main.go:389`, `service/service_test.go:86-104`, `meshsim/harness_test.go:384-393` |
| Deleting records vs anti-entropy | `Since(cursor)` joins `oplog` with `records`, so a deleted record is skipped; the janitor then deletes oplog rows without a record. docs/03: "Since(cursor) always yields exactly the live set". A peer re-sending a deleted record re-inserts it unless something stops it (expiry, `blob_tombstones`, `news_deleted`, the 30-day retention guard for expiring types). Peer batches: `ErrInvalid` → logged and skipped; any other error stops the session; `(false, nil)` = silently dropped. | `store/apply.go:184-191,269-288`, `store/janitor.go:110`, `replication/session.go:189-215`, `docs/03-mesh-replication.md:124-147` |
| Can a hostile node forge PREKEYS/PUSH_TOKEN/INVITE? | No: all three are signed by the author's account key (`signerKey` default branch). It **can** replay old valid records and relay a misbehaving member's flood that an honest node's submit path would refuse. Budgets therefore must hold on the replicated path, and compacted records must not come back. | `records/validate.go:111-160` |
| TURN credentials | TURN-REST, per-node secret, 12 h, user part = `hex(sha256(user_id))[:16]` (`UserTag`); our auth wrapper checks expiry on **every** authenticated request (Allocate/Refresh/CreatePermission/ChannelBind) then pion's HMAC. `TurnCredentials` does not look at the user (comment: "M9 must make this refuse revoked users"; Tasks 30–39 do that for new requests). Already-issued credentials of a revoked user keep working up to 12 h. | `turnsrv/creds.go`, `turnsrv/server.go:203-213`, `service/calls.go:15-23` |
| Relay abuse | UDP relays only, IPv4, ports 49160–49200; 12 allocations/user, node cap = port range, 200 kbit/s per allocation and direction; peer deny list (private, loopback, link-local, multicast, CGNAT, NAT64, 6to4, Teredo, …; IPv4-mapped IPv6 handled because `IsPrivate`/`IPNet.Contains` use `To4`); writes to the node's own addresses only to relay ports. **No change needed.** | `turnsrv/peers.go`, `turnsrv/relay.go:61-89`, D77 |
| Call pushes | Any urgent envelope with `0 < expires-created ≤ 150 s` is a "call" → `WakeCall` for every recipient, **never coalesced, no budget**; future-dated `created_ms` is pushed too (only `< now-10 min` is refused). A member can make another member's phone receive unlimited high-priority FCM pushes (battery; Android also demotes apps whose high-priority pushes show nothing). A hostile node cannot (records need the member's signature; a replay hits the oplog or `ErrExpired`). | `service/push.go:49-77`, `push/pusher.go:47-80` |
| Phone side of calls | Staleness uses the record's `created_ms` (signed by the sender) against the phone's own clock: `nowMs - createdMs >= 45 s` → missed; a **future** `createdMs` always rings. No node time is used (the phone never reads `Hello.server_time_ms`). `MailboxReceiver` passes call content of **any** directory member, revoked or not, to `CallManager`. `TurnCache` passes the node's answer (any number of URLs, any scheme/host, any username) straight to WebRTC. `prekeys_low` from the node makes the phone generate and upload 50 keys for **any** owner id the node names, every time. | `CallStateMachine.kt:50-58`, `MailboxReceiver.kt:56-89`, `TurnCache.kt:24-35`, `SyncEngine.kt:172`, `PrekeyRefill.kt:29-41` |
| Call media | SDP and DTLS fingerprints only inside Signal-encrypted envelopes; call ids are 16 random bytes inside them (a node or a third member cannot learn one, so it cannot inject an answer/hangup into someone's call). | D78, `CallManager.kt:122-145` |
| Contacts | `ContactEntity.revoked` exists; today `DirectorySync` always writes `revoked = false` (Tasks 30–39 set it). | `ContactEntity.kt:16`, `DirectorySync.kt:55` |

**Decisions to record** (coordinator assigns numbers):

- **D105 — Restore attempt limits (revises D51; C4, C10).** A `backup.fetch` attempt is written to `auth_failures`
  (username, source, time) **in the same write transaction that checks the limits, before the secret is compared**;
  a correct secret (or a node error) removes the row again. Limits per node: per (username, source) **5 failures per
  hour** → `RETRY_LATER` for that source only; per username across all sources **10 failures per 24 h free**, then
  each further attempt must wait **30 s × 2^(n−10) after the last failure, at most 15 min**; per source across all
  usernames **30 per 24 h free**, then the same slow-down. The node-wide 20/day lock is gone: a stranger can slow a
  name down to one attempt per 15 min on one node, never lock it, and other nodes count separately. Source = the TCP
  peer of the WSS listener: IPv4 address, IPv6 /64; a loopback peer (the in-process REALITY listener, tests) is
  `local`. No forwarding header is trusted (no CDN, D75). Answer text «too many attempts, retry in Ns».
- **D106 — Limits are reserved, not raced (C9).** Blob quota and the persistent-blob limit are counted in the write
  transaction that inserts the `BLOB_META`; the same rule as D105. Replicated metas stay unchecked (they are signed by
  the author; the origin node checked them).
- **D107 — Record budgets and compaction (C8).** Enforced in `applyTyped`, i.e. for local submits **and** replicated
  records, so a hostile peer relaying a flood or replaying old records changes nothing:
  one-time prekeys ≤ **200 unconsumed per (user, device, owner node)** (the newest ids are kept, older ones marked
  consumed); `PREKEYS` records of a replaced install, or whose one-time keys are all consumed and that are not the
  newest record with the signed prekeys, are deleted by the janitor ≥ 1 h after creation; a per-(user, device, owner)
  **floor** stops consumed ids from coming back. `PUSH_TOKEN`: only the **newest record per author** is stored (an
  older one is deleted on arrival, as for `BACKUP_META`). `INVITE`: lifetime ≤ **30 days**; ≤ **50 unexpired invites
  per author**, ranked by (created_ms, record key) so every node keeps the same 50 (a local 51st → `QUOTA`, a
  replicated one past the rank → dropped, an unused one pushed past the rank → evicted); expired invite records are
  deleted 1 day after expiry, unused rows with them (used rows stay for single-use checks). Deleted record keys go to
  `compacted` for 30 days, so a peer re-sending them is ignored. Local submits only: `created_ms` at most 5 min ahead;
  `PREKEYS` ≤ 20 and `PUSH_TOKEN` ≤ 30 per author per hour (in memory). docs/03 deletion table updated.
- **D108 — Calls under a hostile node / member (M8 review).** TURN auth refuses a revoked user's still-valid
  credentials (checked on every request; the revoked set is re-read at most every 30 s), so the relay stops within
  one permission refresh (≤ 5 min). Call pushes: ≤ **8 per (sender, recipient device) per minute**; beyond that the
  push is an ordinary coalesced wake-up; no push at all for an envelope dated > 5 min ahead. Phone: a TURN answer
  is used only with 1–4 `turn:`/`turns:` URLs on one IPv4 host, `?transport=udp|tcp`, an expiry in the future and
  ≤ 24 h away, username/password ≤ 256 chars; otherwise «Звонки недоступны» on that node. Call content from a
  **revoked** contact is acked and dropped (no ring, no line). An offer dated > 5 min in the future is a missed call,
  not a ring. `prekeys_low` is obeyed only for owner nodes in the verified manifest (or the connected node), at most
  once per owner per 5 min and 6 times per owner per 24 h (persisted).

---

### Task 40: Restore attempts are reserved in the write transaction and throttled per (account, source)

**Goal:** A stranger cannot lock someone's restore on a node, and parallel wrong attempts cannot exceed the limits.

**Findings closed:** C4, C10

**Files:**
- Create: `otter-server/internal/store/migrations/0012_restore_limits.sql`
- Modify: `otter-server/internal/store/backups.go:50-70` (`AddAuthFailure`, new `ReserveAuthAttempt`, `ClearAuthAttempt`, `AuthLimits`, `SlowDown`)
- Modify: `otter-server/internal/service/backup.go:18-98` (limits, `BackupFetch` signature), new `otter-server/internal/service/source.go`
- Modify: `otter-server/internal/gateway/session.go:15-32` (field `source`), `otter-server/internal/gateway/gateway.go:117-127` (set it), `otter-server/internal/gateway/methods.go:197-202` (pass it)
- Test: `otter-server/internal/service/backup_test.go` (replace `TestBackupFetchAndRateLimit`, `TestBackupFetchNodeLimit`, adapt `TestBackupFetchUnknownCountsFailure`), new `otter-server/internal/service/source_test.go`, `otter-server/internal/store/backups_test.go` (callers of `AddAuthFailure`)

**Acceptance Criteria:**
- [ ] 5 wrong attempts from source A → A gets `RETRY_LATER`; the owner from source B succeeds right after.
- [ ] 10 failures from 10 sources → the next attempt within 30 s is `RETRY_LATER` with «retry in»; after 30 s the
  owner succeeds; with 40 failures the wait never exceeds 15 min.
- [ ] 20 parallel wrong attempts from one source → exactly 5 `UNAUTHORIZED`, 15 `RETRY_LATER`, 5 rows counted (C10).
- [ ] A correct attempt leaves no row; an unknown username leaves one.
- [ ] `SourceOf`: `203.0.113.7:5000` → `203.0.113.7`; `[2001:db8:1:2:3:4:5:6]:443` → `2001:db8:1:2::/64`;
  `127.0.0.1:1` and `[::1]:1` → `local`; garbage → `unknown`.
- [ ] `go test ./... -race` green.

**Verify:** `cd otter-server && go test ./internal/service/ -run 'BackupFetch|SourceOf' -count=1 -race` → `ok`

**Steps:**

- [ ] **Step 1: Migration** `internal/store/migrations/0012_restore_limits.sql`:

```sql
-- M9.2 (C4, C10): restore failures are counted per source; the attempt is reserved before the secret is compared.
ALTER TABLE auth_failures ADD COLUMN source TEXT NOT NULL DEFAULT '';
CREATE INDEX IF NOT EXISTS auth_failures_name_source ON auth_failures(username, source, at_ms);
CREATE INDEX IF NOT EXISTS auth_failures_source ON auth_failures(source, at_ms);
```

- [ ] **Step 2: Failing tests.** `internal/service/source_test.go`:

```go
package service

import "testing"

func TestSourceOf(t *testing.T) {
	for in, want := range map[string]string{
		"203.0.113.7:5000":            "203.0.113.7",
		"[2001:db8:1:2:3:4:5:6]:443":  "2001:db8:1:2::/64",
		"[::ffff:203.0.113.9]:80":     "203.0.113.9",
		"127.0.0.1:1":                 "local",
		"[::1]:1":                     "local",
		"not an address":              "unknown",
	} {
		if got := SourceOf(in); got != want {
			t.Errorf("SourceOf(%q) = %q, want %q", in, got, want)
		}
	}
}
```

  In `internal/service/backup_test.go` replace `TestBackupFetchAndRateLimit` and `TestBackupFetchNodeLimit` with the
  tests below and change `TestBackupFetchUnknownCountsFailure` to `f.svc.BackupFetch(ctx, "ghost", "203.0.113.5",
  make([]byte, 32))` and `f.svc.Store.AuthFailures(ctx, "ghost", 0)` (unchanged signature). Add `"sync"` to the imports.

```go
const owner, stranger = "198.51.100.7", "203.0.113.66"

// A stranger hammering one name is limited to his own source; the owner still gets in (C4).
func TestBackupFetchStrangerCannotLock(t *testing.T) {
	f := newFx(t)
	withBlobs(t, f)
	ctx := context.Background()
	now := time.UnixMilli(1_800_000_000_000)
	f.svc.Now = func() time.Time { return now }
	u := f.mustRegister(f.invite(nil, time.Hour), "anna")
	secret := bytes.Repeat([]byte{9}, 32)
	f.publishBackup(u, secret)
	for i := 0; i < 5; i++ {
		if _, _, err := f.svc.BackupFetch(ctx, "anna", stranger, make([]byte, 32)); !errors.Is(err, ErrUnauthorized) {
			t.Fatalf("wrong secret %d: %v", i, err)
		}
	}
	if _, _, err := f.svc.BackupFetch(ctx, "anna", stranger, secret); !errors.Is(err, ErrRetryLater) {
		t.Fatalf("6th attempt from the same source in an hour: %v", err)
	}
	if _, _, err := f.svc.BackupFetch(ctx, "anna", owner, secret); err != nil {
		t.Fatalf("owner from another source must get in: %v", err)
	}
	if n, _ := f.svc.Store.AuthFailures(ctx, "anna", 0); n != 5 {
		t.Fatalf("a correct attempt must not count: %d failures", n)
	}
}

// Many sources slow a name down but never lock it longer than MaxDelay.
func TestBackupFetchSlowsDownAcrossSources(t *testing.T) {
	f := newFx(t)
	withBlobs(t, f)
	ctx := context.Background()
	now := time.UnixMilli(1_800_000_000_000)
	f.svc.Now = func() time.Time { return now }
	u := f.mustRegister(f.invite(nil, time.Hour), "anna")
	secret := bytes.Repeat([]byte{9}, 32)
	f.publishBackup(u, secret)
	for i := 0; i < RestoreLimits.FreePerName; i++ {
		src := fmt.Sprintf("203.0.113.%d", i+1)
		if _, _, err := f.svc.BackupFetch(ctx, "anna", src, make([]byte, 32)); !errors.Is(err, ErrUnauthorized) {
			t.Fatalf("failure %d: %v", i, err)
		}
	}
	_, _, err := f.svc.BackupFetch(ctx, "anna", owner, secret)
	if !errors.Is(err, ErrRetryLater) || !strings.Contains(err.Error(), "retry in") {
		t.Fatalf("11th attempt right away must wait: %v", err)
	}
	now = now.Add(RestoreLimits.BaseDelay)
	if _, _, err := f.svc.BackupFetch(ctx, "anna", owner, secret); err != nil {
		t.Fatalf("after the delay: %v", err)
	}
	for i := 0; i < 40; i++ { // a long attack: the wait stays capped
		if err := f.svc.Store.AddAuthFailure(ctx, "anna", fmt.Sprintf("192.0.2.%d", i), now.UnixMilli()); err != nil {
			t.Fatal(err)
		}
	}
	now = now.Add(RestoreLimits.MaxDelay)
	if _, _, err := f.svc.BackupFetch(ctx, "anna", owner, secret); err != nil {
		t.Fatalf("never locked longer than MaxDelay: %v", err)
	}
}

// Parallel wrong attempts are reserved one by one: never more than the limit get compared (C10).
func TestBackupFetchParallelAttemptsReserved(t *testing.T) {
	f := newFx(t)
	withBlobs(t, f)
	ctx := context.Background()
	u := f.mustRegister(f.invite(nil, time.Hour), "anna")
	f.publishBackup(u, bytes.Repeat([]byte{9}, 32))
	var wg sync.WaitGroup
	var mu sync.Mutex
	unauthorized, later := 0, 0
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, _, err := f.svc.BackupFetch(ctx, "anna", stranger, make([]byte, 32))
			mu.Lock()
			defer mu.Unlock()
			switch {
			case errors.Is(err, ErrUnauthorized):
				unauthorized++
			case errors.Is(err, ErrRetryLater):
				later++
			default:
				t.Errorf("unexpected: %v", err)
			}
		}()
	}
	wg.Wait()
	if unauthorized != RestoreLimits.PerSourceHour || later != 20-RestoreLimits.PerSourceHour {
		t.Fatalf("compared %d, refused %d", unauthorized, later)
	}
	if n, _ := f.svc.Store.AuthFailures(ctx, "anna", 0); n != RestoreLimits.PerSourceHour {
		t.Fatalf("%d failures counted", n)
	}
}
```

  (Imports to add: `"fmt"`, `"strings"`, `"sync"`.) Fix `internal/store/backups_test.go` callers of
  `AddAuthFailure(ctx, name, at)` to `AddAuthFailure(ctx, name, "203.0.113.1", at)`.

- [ ] **Step 3: Run** `go test ./internal/service/ -run 'BackupFetch|SourceOf' -count=1` → FAIL (`SourceOf`
  undefined, too many arguments to `BackupFetch`).

- [ ] **Step 4: Store.** In `internal/store/backups.go` replace `AddAuthFailure` and add (imports `fmt`, `time`):

```go
// AuthLimits are the restore attempt limits (D105). Delays apply after the free failures of the last 24 h.
type AuthLimits struct {
	PerSourceHour       int           // failures per (username, source) per hour
	FreePerName         int           // failures per username, all sources, per 24 h before slowing down
	FreePerSource       int           // failures per source, all usernames, per 24 h before slowing down
	BaseDelay, MaxDelay time.Duration // wait after the last failure: BaseDelay·2^(n-free), at most MaxDelay
}

// SlowDown: the attempt is not allowed yet.
type SlowDown struct{ Wait time.Duration }

func (e *SlowDown) Error() string { return fmt.Sprintf("too many attempts, retry in %s", e.Wait.Round(time.Second)) }

// AddAuthFailure records a failed backup.fetch (tests and imports; the service uses ReserveAuthAttempt).
func (s *Store) AddAuthFailure(ctx context.Context, username, source string, atMs int64) error {
	return s.write(ctx, func(ctx context.Context, tx *sql.Tx) error {
		_, err := tx.ExecContext(ctx, `INSERT INTO auth_failures(username, source, at_ms) VALUES(?,?,?)`, username, source, atMs)
		return err
	})
}

// ReserveAuthAttempt checks the limits and records the attempt as a failure in one write transaction, before the
// secret is compared, so parallel attempts cannot overshoot (C10). It returns the row id for ClearAuthAttempt, or a
// *SlowDown error.
func (s *Store) ReserveAuthAttempt(ctx context.Context, username, source string, nowMs int64, l AuthLimits) (int64, error) {
	var id int64
	err := s.write(ctx, func(ctx context.Context, tx *sql.Tx) error {
		hour, day := nowMs-time.Hour.Milliseconds(), nowMs-24*time.Hour.Milliseconds()
		var oldest sql.NullInt64 // the PerSourceHour-th newest failure of this (username, source) in the last hour
		err := tx.QueryRowContext(ctx, `SELECT at_ms FROM auth_failures WHERE username=? AND source=? AND at_ms>=?
			ORDER BY at_ms DESC LIMIT 1 OFFSET ?`, username, source, hour, l.PerSourceHour-1).Scan(&oldest)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		if oldest.Valid {
			return &SlowDown{Wait: time.Duration(oldest.Int64+time.Hour.Milliseconds()-nowMs) * time.Millisecond}
		}
		slow := func(q, arg string, free int) error {
			var n int
			var last sql.NullInt64
			if err := tx.QueryRowContext(ctx, q, arg, day).Scan(&n, &last); err != nil {
				return err
			}
			if n < free || !last.Valid {
				return nil
			}
			d := l.MaxDelay
			if shift := n - free; shift < 30 {
				d = min(l.BaseDelay<<shift, l.MaxDelay)
			}
			if wait := time.Duration(last.Int64+d.Milliseconds()-nowMs) * time.Millisecond; wait > 0 {
				return &SlowDown{Wait: wait}
			}
			return nil
		}
		if err := slow(`SELECT COUNT(*), MAX(at_ms) FROM auth_failures WHERE username=? AND at_ms>=?`, username, l.FreePerName); err != nil {
			return err
		}
		if err := slow(`SELECT COUNT(*), MAX(at_ms) FROM auth_failures WHERE source=? AND at_ms>=?`, source, l.FreePerSource); err != nil {
			return err
		}
		res, err := tx.ExecContext(ctx, `INSERT INTO auth_failures(username, source, at_ms) VALUES(?,?,?)`, username, source, nowMs)
		if err != nil {
			return err
		}
		id, err = res.LastInsertId()
		return err
	})
	return id, err
}

// ClearAuthAttempt removes a reserved attempt (the secret was right, or the node failed).
func (s *Store) ClearAuthAttempt(ctx context.Context, id int64) error {
	return s.write(ctx, func(ctx context.Context, tx *sql.Tx) error {
		_, err := tx.ExecContext(ctx, `DELETE FROM auth_failures WHERE rowid=?`, id)
		return err
	})
}
```

  Delete `AuthFailuresTotal` (no caller left; `grep -rn AuthFailuresTotal internal` must be empty after Step 5).

- [ ] **Step 5: Service.** New `internal/service/source.go`:

```go
package service

import "net"

// SourceOf maps a connection's remote address to its restore rate-limit source (D105): the IPv4 address, the IPv6
// /64, "local" for loopback (the in-process REALITY listener, tests). No forwarding header is ever trusted: phones
// connect straight to the node's WSS listener (no CDN, D75).
func SourceOf(remoteAddr string) string {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		host = remoteAddr
	}
	ip := net.ParseIP(host)
	switch {
	case ip == nil:
		return "unknown"
	case ip.IsLoopback():
		return "local"
	case ip.To4() != nil:
		return ip.To4().String()
	}
	m := net.CIDRMask(64, 128)
	return (&net.IPNet{IP: ip.Mask(m), Mask: m}).String()
}
```

  In `internal/service/backup.go` replace the constants block's two failure limits with the exported
  `RestoreLimits` and rewrite `BackupFetch` (rest of the file unchanged):

```go
// Restore authentication (D51, D105).
const (
	DefaultKdfMKib     = 65536
	DefaultKdfT        = 3
	DefaultKdfP        = 1
	MaxPersistentBlobs = 3 // live backup blobs per user (D50)
)

// RestoreLimits (D105): a stranger can slow a name down on one node, never lock it.
var RestoreLimits = store.AuthLimits{PerSourceHour: 5, FreePerName: 10, FreePerSource: 30,
	BaseDelay: 30 * time.Second, MaxDelay: 15 * time.Minute}

// BackupFetch checks auth_secret against the verifier; on success returns both meta records and the blob key.
// The attempt is reserved as a failure before the comparison and cleared when the secret is right (C10).
func (s *Service) BackupFetch(ctx context.Context, username, source string, secret []byte) (*pb.BackupFetchResponse, []byte, error) {
	id, err := s.Store.ReserveAuthAttempt(ctx, username, source, s.Now().UnixMilli(), RestoreLimits)
	var sd *store.SlowDown
	if errors.As(err, &sd) {
		return nil, nil, fmt.Errorf("%w: %v", ErrRetryLater, sd)
	}
	if err != nil {
		return nil, nil, err
	}
	keep := true // the reserved row stays as a failure unless the secret was right or this node failed
	defer func() {
		if !keep {
			if err := s.Store.ClearAuthAttempt(context.WithoutCancel(ctx), id); err != nil {
				s.logger().Warn("clearing a restore attempt failed", "err", err)
			}
		}
	}()
	wrong := fmt.Errorf("%w: wrong username or password", ErrUnauthorized)
	b, m, err := s.currentBackup(ctx, username)
	if errors.Is(err, store.ErrNotFound) {
		return nil, nil, wrong
	}
	if err != nil {
		keep = false
		return nil, nil, err
	}
	v := sha256.Sum256(secret)
	if len(secret) != 32 || subtle.ConstantTimeCompare(v[:], m.AuthVerifier) != 1 {
		return nil, nil, wrong
	}
	keep = false
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
```

  (`s.logger()` is in `push.go`.) If M9.1 (C1/C20) already changed `BackupAuth`/`fakeSalt` in this file, keep those
  changes; only the constants and `BackupFetch` change here.

- [ ] **Step 6: Gateway.** `internal/gateway/session.go`: add to `session` after `nonce []byte`:

```go
	source string // restore rate-limit source of this connection (service.SourceOf, D105)
```

  `internal/gateway/gateway.go` `ServeHTTP`: in the `&session{...}` literal add `source: service.SourceOf(r.RemoteAddr),`.
  `internal/gateway/methods.go` `case "backup.fetch"`: `res, key, err := svc.BackupFetch(ctx, r.Username, s.source, r.AuthSecret)`.

- [ ] **Step 7: Run** `go test ./internal/service/ ./internal/store/ ./internal/gateway/ -count=1 -race` → `ok`;
  `go vet ./... && go test ./... -count=1` → all `ok`.

- [ ] **Step 8: Commit**

```bash
git add internal/store/migrations/0012_restore_limits.sql internal/store/backups.go internal/store/backups_test.go \
  internal/service/backup.go internal/service/backup_test.go internal/service/source.go internal/service/source_test.go \
  internal/gateway/session.go internal/gateway/gateway.go internal/gateway/methods.go
oc -m "server: restore attempts reserved in the write transaction, throttled per account and source (C4, C10)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 41: Blob quota and backup-blob limit are reserved in the write transaction

**Goal:** Parallel `blob.create` calls cannot push an author past the byte quota or the 3 live backup blobs.

**Findings closed:** C9

**Files:**
- Modify: `otter-server/internal/store/apply.go:31-35,193-218` (`applyReq.check`, `runReq`), `otter-server/internal/store/blobs.go` (new `ApplyBlobMeta`, `BlobLimits`, `ErrOverLimit`)
- Modify: `otter-server/internal/service/blobs.go:78-102` (`CreateBlob`)
- Test: `otter-server/internal/service/blobs_test.go` (new `TestCreateBlobLimitsHoldUnderParallelCreates`)

**Acceptance Criteria:**
- [ ] Quota 1000 bytes, 10 parallel 300-byte creates → exactly 3 succeed, 7 `QUOTA`; live bytes ≤ 1000.
- [ ] 10 parallel persistent creates → exactly 3 succeed (`MaxPersistentBlobs`).
- [ ] Re-creating an existing blob (same id) at the quota boundary still answers its status (idempotent).
- [ ] `PersistentBlobs`/`UserBlobBytes` remain for stats; `CreateBlob` no longer calls them.

**Verify:** `cd otter-server && go test ./internal/service/ -run 'CreateBlob' -count=5 -race` → `ok`

**Steps:**

- [ ] **Step 1: Failing test** in `internal/service/blobs_test.go` (add `"sync"` to the imports):

```go
// blobMeta signs a one-chunk blob of size bytes for u (persistent: a backup blob).
func blobMeta(t *testing.T, u *user, size uint64, persistent bool) *pb.Record {
	h := sha256.Sum256([]byte("x"))
	m := &pb.BlobMeta{Size: size, ChunkSize: records.BlobChunkSize, ChunkSha256: [][]byte{h[:]}, Persistent: persistent}
	body := &pb.RecordBody{Id: r16(), Type: pb.RecordType_BLOB_META, Author: u.id, CreatedMs: time.Now().UnixMilli()}
	if !persistent {
		m.Readers = [][]byte{u.id}
		body.ExpiresMs = time.Now().Add(24 * time.Hour).UnixMilli()
	}
	body.Payload, _ = proto.Marshal(m)
	rec, err := records.Sign(body, u.priv)
	if err != nil {
		t.Fatal(err)
	}
	return rec
}

// A client racing blob.create calls cannot overshoot its limits (C9).
func TestCreateBlobLimitsHoldUnderParallelCreates(t *testing.T) {
	f := newFx(t)
	withBlobs(t, f)
	f.svc.Limits = Limits{UserQuota: 1000, MaxBlob: 1000}
	ctx := context.Background()
	u := f.mustRegister(f.invite(nil, time.Hour), "anna")
	race := func(persistent bool) (ok, quota int) {
		var wg sync.WaitGroup
		var mu sync.Mutex
		for i := 0; i < 10; i++ {
			rec := blobMeta(t, u, 300, persistent)
			wg.Add(1)
			go func() {
				defer wg.Done()
				_, err := f.svc.CreateBlob(ctx, u.id, rec)
				mu.Lock()
				defer mu.Unlock()
				switch {
				case err == nil:
					ok++
				case errors.Is(err, ErrQuota):
					quota++
				default:
					t.Errorf("unexpected: %v", err)
				}
			}()
		}
		wg.Wait()
		return ok, quota
	}
	if ok, quota := race(false); ok != 3 || quota != 7 {
		t.Fatalf("bytes: %d created, %d refused", ok, quota)
	}
	if used, _ := f.svc.Store.UserBlobBytes(ctx, u.id); used > 1000 {
		t.Fatalf("quota overshot: %d", used)
	}
	f.svc.Limits.UserQuota = 1 << 30
	if ok, _ := race(true); ok != MaxPersistentBlobs {
		t.Fatalf("persistent: %d created", ok)
	}
	again := blobMeta(t, u, 300, true)
	if _, err := f.svc.CreateBlob(ctx, u.id, again); !errors.Is(err, ErrQuota) {
		t.Fatalf("4th backup blob: %v", err)
	}
}

func TestCreateBlobIdempotentAtTheLimit(t *testing.T) {
	f := newFx(t)
	withBlobs(t, f)
	f.svc.Limits = Limits{UserQuota: 300, MaxBlob: 1000}
	u := f.mustRegister(f.invite(nil, time.Hour), "anna")
	rec := blobMeta(t, u, 300, false)
	for i := 0; i < 2; i++ {
		if _, err := f.svc.CreateBlob(context.Background(), u.id, rec); err != nil {
			t.Fatalf("create %d: %v", i, err)
		}
	}
}
```

- [ ] **Step 2: Run** `go test ./internal/service/ -run CreateBlob -count=5 -race` → FAIL (more than 3 created in
  at least one run, or the persistent count > 3). If the race does not show on this machine in 5 runs, the test still
  pins the behaviour; keep it.

- [ ] **Step 3: Store.** `internal/store/apply.go`: add the field and run it first in `runReq`:

```go
type applyReq struct {
	items []item
	fn    func(context.Context, *sql.Tx) error
	check func(context.Context, *sql.Tx) error // runs before items, same savepoint (limits, D106)
	res   chan applyRes
}
```

```go
	if r.fn != nil {
		err = r.fn(ctx, tx)
	} else {
		if r.check != nil {
			err = r.check(ctx, tx)
		}
		for _, it := range r.items {
			if err != nil {
				break
			}
			seq, applied, e := applyOne(ctx, tx, it, now)
			if e != nil {
				err = e
				break
			}
			res.seqs = append(res.seqs, seq)
			res.applied = append(res.applied, applied)
		}
	}
```

  `internal/store/blobs.go` (imports `errors`, `fmt`, `pb`):

```go
// ErrOverLimit: a per-author limit would be exceeded (blob quota, backup blobs, invites).
var ErrOverLimit = errors.New("over the limit")

// BlobLimits are checked when a client creates a blob (D44, D50).
type BlobLimits struct {
	UserQuota     int64 // live blob bytes per author
	MaxPersistent int   // live persistent (backup) blobs per author
}

// ApplyBlobMeta stores a client's BLOB_META only if its author stays within lim, counted in the same write
// transaction as the insert, so parallel creates cannot overshoot (C9). A meta already stored passes unchecked.
func (s *Store) ApplyBlobMeta(ctx context.Context, rec *pb.Record, body *pb.RecordBody, origin []byte,
	size int64, persistent bool, lim BlobLimits) (bool, error) {
	it, err := toItem(Item{rec, body}, origin)
	if err != nil {
		return false, err
	}
	check := func(ctx context.Context, tx *sql.Tx) error {
		var x int
		if err := tx.QueryRowContext(ctx, `SELECT 1 FROM oplog WHERE record_key=?`, it.key).Scan(&x); err == nil {
			return nil // idempotent re-create
		} else if !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		if persistent {
			var n int
			if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM blobs WHERE owner=? AND persistent=1`, body.Author).Scan(&n); err != nil {
				return err
			}
			if n >= lim.MaxPersistent {
				return fmt.Errorf("%w: %d backup blobs in flight", ErrOverLimit, n)
			}
		}
		var used int64
		if err := tx.QueryRowContext(ctx, `SELECT COALESCE(SUM(size),0) FROM blobs WHERE owner=?`, body.Author).Scan(&used); err != nil {
			return err
		}
		if used+size > lim.UserQuota {
			return fmt.Errorf("%w: %d of %d bytes in use", ErrOverLimit, used, lim.UserQuota)
		}
		return nil
	}
	r, err := s.submit(ctx, &applyReq{items: []item{it}, check: check})
	if err != nil {
		return false, err
	}
	return r.applied[0], nil
}
```

- [ ] **Step 4: Service.** In `CreateBlob` replace the block from `if m.Persistent {` through the `ApplyFrom` call with:

```go
	if int64(m.Size) > s.Limits.MaxBlob {
		return nil, fmt.Errorf("%w: blob of %d bytes exceeds %d", ErrQuota, m.Size, s.Limits.MaxBlob)
	}
	applied, err := s.Store.ApplyBlobMeta(ctx, rec, body, s.NodeID, int64(m.Size), m.Persistent,
		store.BlobLimits{UserQuota: s.Limits.UserQuota, MaxPersistent: MaxPersistentBlobs})
	if errors.Is(err, store.ErrOverLimit) {
		return nil, fmt.Errorf("%w: %v", ErrQuota, err)
	}
	if err != nil {
		return nil, err
	}
```

  (the following `if applied { s.afterApply(ctx, body, nil) }` stays).

- [ ] **Step 5: Run** `go test ./internal/service/ -run CreateBlob -count=5 -race` → `ok`; `go test ./... -count=1` → all `ok`.

- [ ] **Step 6: Commit**

```bash
git add internal/store/apply.go internal/store/blobs.go internal/service/blobs.go internal/service/blobs_test.go
oc -m "server: blob quota and backup-blob limit reserved in the write transaction (C9)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 42: One-time prekey budget, PREKEYS compaction and floors (local and replicated)

**Goal:** However many PREKEYS records a member uploads or a hostile peer relays/replays, a node keeps ≤ 200 live
one-time keys per (user, device, owner node), drops records that add nothing, and never resurrects consumed keys.

**Findings closed:** C8 (PREKEYS part)

**Files:**
- Create: `otter-server/internal/store/migrations/0013_record_budgets.sql`
- Modify: `otter-server/internal/store/typed.go:16-21,67-119` (constant, budget, floors), `otter-server/internal/store/apply.go:249-268` (`applyOne`: `compacted` check), `otter-server/internal/store/janitor.go` (`ExpireStats.Compacted`, `compactPrekeys`, purge of `compacted`)
- Modify: `otter-server/internal/service/janitor.go` (log `compacted`)
- Test: new `otter-server/internal/service/budget_test.go`

**Acceptance Criteria:**
- [ ] A hostile peer delivering 5 PREKEYS records × 200 keys (ids 1000–1999) for anna → `PrekeyCounts[self] == 200`,
  and the next handed-out key is id 1800 (the newest 200 kept).
- [ ] Janitor (≥ 1 h later): the 4 records whose keys are all dropped are deleted (`Stats.Compacted == 4`); the
  registration record (signed prekeys) and the record with live keys stay.
- [ ] The hostile peer replays a compacted record → not applied, counts unchanged. After the `compacted` tombstone
  lapses (31 days), a replay is stored again but none of its keys come back (floor); the next janitor removes it.
- [ ] A newer install (higher `installed_ms`) still replaces the device's keys and resets its floors.
- [ ] `go test ./... -race` green (existing prekey/meshsim tests unchanged).

**Verify:** `cd otter-server && go test ./internal/service/ -run 'PrekeyBudget' -count=1 -race -v` → `--- PASS`

**Steps:**

- [ ] **Step 1: Migration** `internal/store/migrations/0013_record_budgets.sql`:

```sql
-- M9.2 (C8): per-author budgets. compacted: keys of records deleted as superseded, ignored when re-sent (30 days).
-- prekey_floor: one-time key ids below the floor were consumed and forgotten here; they are never inserted again.
CREATE TABLE compacted(record_key BLOB PRIMARY KEY, until_ms INTEGER NOT NULL);
CREATE TABLE prekey_floor(user_id BLOB NOT NULL, device_id INTEGER NOT NULL, owner_node BLOB NOT NULL,
                          floor_id INTEGER NOT NULL, PRIMARY KEY(user_id, device_id, owner_node));
CREATE INDEX IF NOT EXISTS records_type_author ON records(type, author, created_ms);
```

- [ ] **Step 2: Failing test** `internal/service/budget_test.go`:

```go
package service

import (
	"context"
	"errors"
	"testing"
	"time"

	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/store"
)

// hostile is a peer node id that relays and replays records (a hostile node in the mesh).
var hostile = []byte("hostile-node-000")

func prekeysRec(t *testing.T, u *user, owner []byte, first uint32, n int) *pb.Record {
	pk := &pb.PreKeys{DeviceId: 1, RegistrationId: 5}
	for i := 0; i < n; i++ {
		pk.OneTime = append(pk.OneTime, &pb.OneTimePreKey{Id: first + uint32(i), PublicKey: make([]byte, 33), OwnerNode: owner})
	}
	return sign(t, pb.RecordType_PREKEYS, u.id, pk, u.priv)
}

func TestPrekeyBudgetAgainstHostilePeer(t *testing.T) {
	f := newFx(t)
	ctx := context.Background()
	anna := f.mustRegister(f.invite(nil, time.Hour), "anna") // 12 keys (ids 100–111) owned by this node
	self := f.svc.NodeID
	var flood []*pb.Record
	for i := 0; i < 5; i++ {
		r := prekeysRec(t, anna, self, uint32(1000+200*i), 200)
		flood = append(flood, r)
		if _, err := f.svc.ApplyReplicated(ctx, hostile, r); err != nil {
			t.Fatalf("batch %d: %v", i, err)
		}
	}
	count := func() int { m, _ := f.svc.Store.PrekeyCounts(ctx, anna.id, 1); return m[string(self)] }
	if n := count(); n != store.MaxLiveOneTime {
		t.Fatalf("%d live one-time keys, want %d", n, store.MaxLiveOneTime)
	}
	got, err := f.svc.Store.TakePrekeys(ctx, anna.id, 1, self)
	if err != nil || got.OneTime == nil || got.OneTime.Id != 1800 {
		t.Fatalf("handed out %v, %v; want id 1800 (the newest 200 kept)", got.OneTime, err)
	}

	later := time.Now().Add(2 * time.Hour).UnixMilli()
	st, err := f.svc.Store.Expire(ctx, later)
	if err != nil {
		t.Fatal(err)
	}
	if st.Compacted != 4 {
		t.Fatalf("compacted %d PREKEYS records, want 4", st.Compacted)
	}
	for i, r := range flood {
		_, err := f.svc.Store.Get(ctx, recordKey(r))
		if gone := errors.Is(err, store.ErrNotFound); gone != (i < 4) {
			t.Fatalf("record %d: gone=%v", i, gone)
		}
	}

	// replay inside the tombstone window: ignored
	if applied, err := f.svc.ApplyReplicated(ctx, hostile, flood[0]); err != nil || applied {
		t.Fatalf("replay applied=%v err=%v", applied, err)
	}
	if n := count(); n != store.MaxLiveOneTime-1 {
		t.Fatalf("after replay: %d", n)
	}
	// after the tombstone lapsed: stored again, but the floor keeps its consumed keys out
	if _, err := f.svc.Store.Expire(ctx, time.Now().Add(31*24*time.Hour).UnixMilli()); err != nil {
		t.Fatal(err)
	}
	if _, err := f.svc.ApplyReplicated(ctx, hostile, flood[0]); err != nil {
		t.Fatal(err)
	}
	if n := count(); n != store.MaxLiveOneTime-1 {
		t.Fatalf("resurrected keys: %d live", n)
	}
	if got, _ := f.svc.Store.TakePrekeys(ctx, anna.id, 1, self); got.OneTime.Id != 1801 {
		t.Fatalf("a dropped key came back: %d", got.OneTime.Id)
	}
}

func TestPrekeyNewInstallResetsFloor(t *testing.T) {
	f := newFx(t)
	ctx := context.Background()
	anna := f.mustRegister(f.invite(nil, time.Hour), "anna")
	self := f.svc.NodeID
	for i := 0; i < 12; i++ { // consume ids 100–111
		if _, err := f.svc.Store.TakePrekeys(ctx, anna.id, 1, self); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := f.svc.Store.Expire(ctx, time.Now().Add(2*time.Hour).UnixMilli()); err != nil {
		t.Fatal(err)
	}
	// a restore: new install, ids start again at 1 (InstallGuard.finishRestore)
	pk := &pb.PreKeys{DeviceId: 1, RegistrationId: 6, InstalledMs: time.Now().UnixMilli(),
		SignedPrekey: &pb.SignedPreKey{Id: 1, PublicKey: make([]byte, 33), Signature: make([]byte, 64)},
		KyberPrekey:  &pb.SignedPreKey{Id: 1, PublicKey: make([]byte, 1569), Signature: make([]byte, 64)}}
	for i := 0; i < 50; i++ {
		pk.OneTime = append(pk.OneTime, &pb.OneTimePreKey{Id: uint32(1 + i), PublicKey: make([]byte, 33), OwnerNode: self})
	}
	if _, err := f.svc.Submit(ctx, anna.id, sign(t, pb.RecordType_PREKEYS, anna.id, pk, anna.priv), pb.RecordType_PREKEYS); err != nil {
		t.Fatal(err)
	}
	if m, _ := f.svc.Store.PrekeyCounts(ctx, anna.id, 1); m[string(self)] != 50 {
		t.Fatalf("new install keys below the old floor were dropped: %v", m)
	}
}
```

  `recordKey` helper: if `internal/service` tests have none, add to `budget_test.go`:

```go
func recordKey(r *pb.Record) []byte {
	var b pb.RecordBody
	_ = proto.Unmarshal(r.Body, &b)
	return append(append([]byte{}, b.Author...), b.Id...)
}
```

  (import `"google.golang.org/protobuf/proto"`).

- [ ] **Step 3: Run** `go test ./internal/service/ -run PrekeyBudget -count=1` → FAIL (`store.MaxLiveOneTime`,
  `st.Compacted` undefined).

- [ ] **Step 4: Apply-time budget and floors** (`internal/store/typed.go`). Add to the constants:

```go
	// MaxLiveOneTime: unconsumed one-time prekeys kept per (user, device, owner node); the newest ids win (C8).
	MaxLiveOneTime = 200
```

  In the `PREKEYS` case, the `exists && p.InstalledMs > curInstalled` branch also drops the floors:

```go
		case exists && p.InstalledMs > curInstalled:
			for _, q := range []string{`DELETE FROM prekeys WHERE user_id=? AND device_id=?`,
				`DELETE FROM prekey_floor WHERE user_id=? AND device_id=?`} {
				if _, err := tx.ExecContext(ctx, q, b.Author, p.DeviceId); err != nil {
					return err
				}
			}
		}
```

  and the one-time loop becomes:

```go
		floors := map[string]int64{}
		touched := map[string][]byte{}
		for _, k := range p.OneTime {
			o := string(k.OwnerNode)
			floor, ok := floors[o]
			if !ok {
				err := tx.QueryRowContext(ctx, `SELECT floor_id FROM prekey_floor WHERE user_id=? AND device_id=? AND owner_node=?`,
					b.Author, p.DeviceId, k.OwnerNode).Scan(&floor)
				if err != nil && !errors.Is(err, sql.ErrNoRows) {
					return err
				}
				floors[o] = floor
			}
			if int64(k.Id) < floor {
				continue // consumed and forgotten here: a replayed record must not hand it out again (C8)
			}
			if _, err := tx.ExecContext(ctx,
				`INSERT OR IGNORE INTO prekeys(user_id,device_id,key_id,kind,owner_node,public) VALUES(?,?,?,?,?,?)`,
				b.Author, p.DeviceId, k.Id, PrekeyOneTime, k.OwnerNode, k.PublicKey); err != nil {
				return err
			}
			touched[o] = k.OwnerNode
		}
		for _, owner := range touched { // budget: keep the newest MaxLiveOneTime unconsumed ids per owner
			if _, err := tx.ExecContext(ctx, `UPDATE prekeys SET consumed=1
				WHERE user_id=? AND device_id=? AND kind=? AND owner_node=? AND consumed=0 AND key_id NOT IN
				(SELECT key_id FROM prekeys WHERE user_id=? AND device_id=? AND kind=? AND owner_node=? AND consumed=0
				 ORDER BY key_id DESC LIMIT ?)`,
				b.Author, p.DeviceId, PrekeyOneTime, owner, b.Author, p.DeviceId, PrekeyOneTime, owner, MaxLiveOneTime); err != nil {
				return err
			}
		}
		return nil
```

- [ ] **Step 5: Tombstone check** in `applyOne` (`internal/store/apply.go`), right after the oplog lookup returns
  `sql.ErrNoRows` and before the retention guard:

```go
	var gone int
	if err := tx.QueryRowContext(ctx, `SELECT 1 FROM compacted WHERE record_key=?`, it.key).Scan(&gone); err == nil {
		return 0, false, nil // deleted here as superseded (C8): a re-send changes nothing
	} else if !errors.Is(err, sql.ErrNoRows) {
		return 0, false, err
	}
```

- [ ] **Step 6: Janitor** (`internal/store/janitor.go`). `type ExpireStats struct{ Envelopes, Acks, Tombstones,
  Oplog, Blobs, Compacted int64 }`. Add (imports `errors`, `google.golang.org/protobuf/proto`):

```go
// prekeyGrace: a PREKEYS record younger than this is never compacted (its keys may still be replicating).
const prekeyGrace = int64(60 * 60 * 1000)

// compact deletes a superseded record and remembers its key for RetentionMs (C8).
func compact(ctx context.Context, tx *sql.Tx, key []byte, now int64) error {
	if _, err := tx.ExecContext(ctx, `INSERT OR REPLACE INTO compacted(record_key, until_ms) VALUES(?,?)`, key, now+RetentionMs); err != nil {
		return err
	}
	_, err := tx.ExecContext(ctx, `DELETE FROM records WHERE record_key=?`, key)
	return err
}

// compactPrekeys deletes PREKEYS records that add nothing any more (C8): a replaced install's, and those whose
// one-time keys are all consumed or dropped, except the newest record carrying the device's signed prekeys of the
// current install. Then it raises the per-owner floors and forgets consumed one-time rows below them.
func compactPrekeys(ctx context.Context, tx *sql.Tx, now int64) (int64, error) {
	type rec struct {
		key, author []byte
		created     int64
		p           pb.PreKeys
	}
	rows, err := tx.QueryContext(ctx, `SELECT record_key, author, created_ms, raw FROM records WHERE type=? ORDER BY created_ms, record_key`,
		int32(pb.RecordType_PREKEYS))
	if err != nil {
		return 0, err
	}
	var all []*rec
	for rows.Next() {
		r := &rec{}
		var raw []byte
		if err := rows.Scan(&r.key, &r.author, &r.created, &raw); err != nil {
			rows.Close()
			return 0, err
		}
		var outer pb.Record
		var body pb.RecordBody
		if proto.Unmarshal(raw, &outer) != nil || proto.Unmarshal(outer.Body, &body) != nil || proto.Unmarshal(body.Payload, &r.p) != nil {
			continue // stored records were validated; skip rather than fail the janitor
		}
		all = append(all, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}
	type dev struct {
		author string
		id     uint32
	}
	installed := map[dev]int64{}
	base := map[dev]*rec{} // newest record with signed prekeys of the current install (ordered by created_ms above)
	for _, r := range all {
		d := dev{string(r.author), r.p.DeviceId}
		if _, ok := installed[d]; !ok {
			var inst int64
			err := tx.QueryRowContext(ctx, `SELECT installed_ms FROM devices WHERE user_id=? AND device_id=?`, r.author, r.p.DeviceId).Scan(&inst)
			if err != nil && !errors.Is(err, sql.ErrNoRows) {
				return 0, err
			}
			installed[d] = inst
		}
		if r.p.SignedPrekey != nil && r.p.InstalledMs == installed[d] {
			base[d] = r
		}
	}
	var n int64
	for _, r := range all {
		d := dev{string(r.author), r.p.DeviceId}
		if r.created >= now-prekeyGrace || base[d] == r {
			continue
		}
		drop := r.p.InstalledMs < installed[d]
		if !drop {
			lo, hi := uint32(1<<32-1), uint32(0)
			for _, k := range r.p.OneTime {
				lo, hi = min(lo, k.Id), max(hi, k.Id)
			}
			live := false
			if len(r.p.OneTime) > 0 { // ids are unique per (user, device): the record's range finds its live keys
				if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM prekeys WHERE user_id=? AND device_id=? AND kind=?
					AND consumed=0 AND key_id BETWEEN ? AND ?)`, r.author, r.p.DeviceId, PrekeyOneTime, lo, hi).Scan(&live); err != nil {
					return 0, err
				}
			}
			drop = !live
		}
		if drop {
			if err := compact(ctx, tx, r.key, now); err != nil {
				return 0, err
			}
			n++
		}
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO prekey_floor(user_id, device_id, owner_node, floor_id)
		SELECT user_id, device_id, owner_node, MAX(key_id)+1 FROM prekeys WHERE kind=? AND consumed=1
		GROUP BY user_id, device_id, owner_node
		ON CONFLICT(user_id, device_id, owner_node) DO UPDATE SET floor_id=MAX(floor_id, excluded.floor_id)`, PrekeyOneTime); err != nil {
		return 0, err
	}
	_, err = tx.ExecContext(ctx, `DELETE FROM prekeys WHERE kind=? AND consumed=1 AND key_id <
		(SELECT f.floor_id FROM prekey_floor f WHERE f.user_id=prekeys.user_id AND f.device_id=prekeys.device_id
		 AND f.owner_node=prekeys.owner_node)`, PrekeyOneTime)
	return n, err
}
```

  In `Expire`, before the final oplog statement:

```go
		n, err := compactPrekeys(ctx, tx, now)
		if err != nil {
			return err
		}
		st.Compacted += n
		if err := exec(&ignore, `DELETE FROM compacted WHERE until_ms < ?`, now); err != nil {
			return err
		}
```

  Why anti-entropy still holds: only records whose effect is already fully carried by records that stay (the base
  record, records with live keys, or the newer install's record) are deleted, so `Since(cursor)` from any cursor
  still yields the live set (docs/03). A consumed key's id is below the floor, so neither a lagging peer nor a
  hostile replay can make this node hand it out again; a legitimately late record with ids below the floor only
  loses one-time keys (Signal falls back to the signed prekey).

  `internal/service/janitor.go`: add `st.Compacted` to the sum and `"compacted", st.Compacted` to the log line.

- [ ] **Step 7: Run** `go test ./internal/service/ -run PrekeyBudget -count=1 -race -v` → PASS;
  `go test ./internal/store/ ./internal/meshsim/ -count=1 -race` → `ok` (`TestPrekeyConsumptionReplicates` unchanged).

- [ ] **Step 8: Commit**

```bash
git add internal/store/migrations/0013_record_budgets.sql internal/store/typed.go internal/store/apply.go \
  internal/store/janitor.go internal/service/janitor.go internal/service/budget_test.go
oc -m "server: one-time prekey budget, PREKEYS compaction and floors, local and replicated (C8)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 43: PUSH_TOKEN keeps only the newest record; INVITE lifetime and per-author budget; submit rates

**Goal:** Push-token and invite records stay bounded on every node whatever a member submits or a hostile peer
relays; locally submitted records cannot be dated in the future.

**Findings closed:** C8 (PUSH_TOKEN and INVITE parts)

**Files:**
- Create: `otter-server/internal/store/migrations/0014_invite_budget.sql`, `otter-server/internal/service/ratelimit.go`
- Modify: `otter-server/internal/store/typed.go:43-50,121-142` (INVITE, PUSH_TOKEN cases), `otter-server/internal/store/janitor.go` (expired invites), `otter-server/internal/store/query.go` (new `LiveInvites`)
- Modify: `otter-server/internal/records/validate.go:18-30,212-216` (`MaxInviteTTL`), `otter-server/internal/admin/invite.go:50-75` (refuse a longer `--ttl`)
- Modify: `otter-server/internal/service/submit.go`, `otter-server/internal/service/service.go:59-80` (field `submits`), `otter-server/internal/service/errors.go` (map `store.ErrInviteBudget`)
- Test: `otter-server/internal/service/budget_test.go` (append), `otter-server/internal/records/validate_test.go` (invite TTL case)

**Acceptance Criteria:**
- [ ] Three tokens submitted (created −3, −2, −1 min) → only the newest record exists; `PushToken == "tok3"`. A
  hostile peer replaying the oldest after the janitor → still `tok3`, the old record not stored.
- [ ] 31st `push.register` by one author within an hour → `QUOTA`; 21st `prekeys.upload` → `QUOTA`.
- [ ] 50 invites submitted → ok; the 51st → `QUOTA`. A hostile peer relaying 60 invites by another member, in
  reverse time order → exactly the 50 oldest are live on this node (`LiveInvites == 50`).
- [ ] An INVITE living longer than 30 days → `INVALID`; `otter-admin invite bootstrap --ttl 800h` → error.
- [ ] Janitor 1 day after expiry: the expired invite records and their unused rows are gone.
- [ ] A locally submitted record with `created_ms` 10 min ahead → `INVALID`.

**Verify:** `cd otter-server && go test ./internal/service/ ./internal/records/ ./internal/admin/ -count=1 -race` → `ok`

**Steps:**

- [ ] **Step 1: Migration** `0014_invite_budget.sql`:

```sql
-- M9.2 (C8): invites are ranked per author by (created_ms, record_key); legacy rows rank first and are never evicted.
ALTER TABLE invites ADD COLUMN created_ms INTEGER NOT NULL DEFAULT 0;
ALTER TABLE invites ADD COLUMN record_key BLOB;
CREATE INDEX IF NOT EXISTS invites_inviter ON invites(inviter, expires_ms);
```

- [ ] **Step 2: Failing tests** — append to `internal/service/budget_test.go` (imports `"fmt"`, `"ottermsg/server/internal/records"`):

```go
func signAt(t *testing.T, typ pb.RecordType, u *user, payload proto.Message, created int64) *pb.Record {
	p, _ := proto.Marshal(payload)
	r, err := records.Sign(&pb.RecordBody{Id: r16(), Type: typ, Author: u.id, CreatedMs: created, Payload: p}, u.priv)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestPushTokenNewestRecordOnly(t *testing.T) {
	f := newFx(t)
	ctx := context.Background()
	anna := f.mustRegister(f.invite(nil, time.Hour), "anna")
	now := time.Now()
	var recs []*pb.Record
	for i := 1; i <= 3; i++ {
		r := signAt(t, pb.RecordType_PUSH_TOKEN, anna, &pb.PushToken{DeviceId: 1, Kind: pb.PushToken_FCM, Token: fmt.Sprintf("tok%d", i)},
			now.Add(time.Duration(i-4)*time.Minute).UnixMilli())
		recs = append(recs, r)
		if _, err := f.svc.Submit(ctx, anna.id, r, pb.RecordType_PUSH_TOKEN); err != nil {
			t.Fatal(err)
		}
	}
	for i, r := range recs[:2] {
		if _, err := f.svc.Store.Get(ctx, recordKey(r)); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("superseded token record %d kept: %v", i, err)
		}
	}
	if _, err := f.svc.Store.Expire(ctx, now.UnixMilli()); err != nil { // orphan oplog rows go
		t.Fatal(err)
	}
	if _, err := f.svc.ApplyReplicated(ctx, hostile, recs[0]); err != nil {
		t.Fatal(err)
	}
	if tok, _ := f.svc.Store.PushToken(ctx, anna.id, 1); tok != "tok3" {
		t.Fatalf("token = %q after a replay", tok)
	}
	if _, err := f.svc.Store.Get(ctx, recordKey(recs[0])); !errors.Is(err, store.ErrNotFound) {
		t.Fatal("replayed old token record stored")
	}
}

func TestSubmitRates(t *testing.T) {
	f := newFx(t)
	ctx := context.Background()
	anna := f.mustRegister(f.invite(nil, time.Hour), "anna")
	for i := 0; i <= submitRates[pb.RecordType_PUSH_TOKEN]; i++ {
		r := sign(t, pb.RecordType_PUSH_TOKEN, anna.id, &pb.PushToken{DeviceId: 1, Kind: pb.PushToken_FCM, Token: fmt.Sprint(i)}, anna.priv)
		_, err := f.svc.Submit(ctx, anna.id, r, pb.RecordType_PUSH_TOKEN)
		if i < submitRates[pb.RecordType_PUSH_TOKEN] && err != nil || i == submitRates[pb.RecordType_PUSH_TOKEN] && !errors.Is(err, ErrQuota) {
			t.Fatalf("token %d: %v", i, err)
		}
	}
	future := signAt(t, pb.RecordType_PUSH_TOKEN, anna, &pb.PushToken{DeviceId: 1, Kind: pb.PushToken_FCM, Token: "x"},
		time.Now().Add(10*time.Minute).UnixMilli())
	if _, err := f.svc.Submit(ctx, anna.id, future, pb.RecordType_PUSH_TOKEN); !errors.Is(err, ErrInvalid) {
		t.Fatalf("future-dated record: %v", err)
	}
}

func inviteRec(t *testing.T, u *user, created time.Time, ttl time.Duration) *pb.Record {
	return signAt(t, pb.RecordType_INVITE, u, &pb.Invite{InviteId: append(r16(), r16()...), ExpiresMs: created.Add(ttl).UnixMilli()},
		created.UnixMilli())
}

func TestInviteBudgetLocalAndReplicated(t *testing.T) {
	f := newFx(t)
	ctx := context.Background()
	anna := f.mustRegister(f.invite(nil, time.Hour), "anna")
	boris := f.mustRegister(f.invite(nil, time.Hour), "boris")
	now := time.Now()
	for i := 0; i < store.MaxLiveInvites; i++ {
		if _, err := f.svc.Submit(ctx, anna.id, inviteRec(t, anna, now.Add(-time.Duration(i)*time.Second), 7*24*time.Hour), pb.RecordType_INVITE); err != nil {
			t.Fatalf("invite %d: %v", i, err)
		}
	}
	if _, err := f.svc.Submit(ctx, anna.id, inviteRec(t, anna, now, 7*24*time.Hour), pb.RecordType_INVITE); !errors.Is(err, ErrQuota) {
		t.Fatalf("51st invite: %v", err)
	}
	// a hostile peer relays 60 of boris's invites, newest first: the 50 oldest stay
	var oldest []*pb.Record
	for i := 0; i < 60; i++ {
		r := inviteRec(t, boris, now.Add(-time.Duration(i)*time.Minute), 7*24*time.Hour)
		if i >= 10 {
			oldest = append(oldest, r)
		}
		if _, err := f.svc.ApplyReplicated(ctx, hostile, r); err != nil {
			t.Fatalf("replicated invite %d: %v", i, err)
		}
	}
	if n, _ := f.svc.Store.LiveInvites(ctx, boris.id, now.UnixMilli()); n != store.MaxLiveInvites {
		t.Fatalf("%d live invites for boris", n)
	}
	for _, r := range oldest {
		if _, err := f.svc.Store.Get(ctx, recordKey(r)); err != nil {
			t.Fatalf("an invite within the rank was dropped: %v", err)
		}
	}
	if _, err := f.svc.Submit(ctx, anna.id, inviteRec(t, anna, now, 31*24*time.Hour), pb.RecordType_INVITE); !errors.Is(err, ErrInvalid) {
		t.Fatalf("31-day invite: %v", err)
	}
	if _, err := f.svc.Store.Expire(ctx, now.Add(9*24*time.Hour).UnixMilli()); err != nil {
		t.Fatal(err)
	}
	if n, _ := f.svc.Store.LiveInvites(ctx, anna.id, 0); n != 0 {
		t.Fatalf("%d expired invites kept", n)
	}
	for _, r := range oldest {
		if _, err := f.svc.Store.Get(ctx, recordKey(r)); !errors.Is(err, store.ErrNotFound) {
			t.Fatal("expired invite record kept")
		}
	}
}
```

  In `internal/records/validate_test.go`
  add a table row next to the existing INVITE cases (line ~134): a user INVITE with `ExpiresMs = CreatedMs +
  31 days` → `ErrBadPayload`.

- [ ] **Step 3: Run** `go test ./internal/service/ -run 'PushToken|SubmitRates|InviteBudget' -count=1` → FAIL
  (undefined `submitRates`, `store.MaxLiveInvites`, `LiveInvites`).

- [ ] **Step 4: Validator** (`internal/records/validate.go`): constant `MaxInviteTTL = 30 * 24 * time.Hour // an
  invite lives at most this long (C8)` and the INVITE case:

```go
	case pb.RecordType_INVITE:
		var i pb.Invite
		if err := proto.Unmarshal(b.Payload, &i); err != nil || len(i.InviteId) != 32 || i.ExpiresMs <= b.CreatedMs ||
			i.ExpiresMs-b.CreatedMs > MaxInviteTTL.Milliseconds() {
			return ErrBadPayload
		}
```

  `internal/admin/invite.go` `BootstrapInvite`: first line `if ttl <= 0 || ttl > records.MaxInviteTTL { return nil,
  fmt.Errorf("invite ttl must be between 1s and %s", records.MaxInviteTTL) }`.

- [ ] **Step 5: Store** (`internal/store/typed.go`). Constants and error:

```go
// MaxLiveInvites: unexpired invites per author kept on a node (C8). Ranked by (created_ms, record_key), so every
// node keeps the same ones whatever order they arrive in.
const MaxLiveInvites = 50

// ErrInviteBudget: the author already has MaxLiveInvites unexpired invites. (typed.go: add the "fmt" import.)
var ErrInviteBudget = fmt.Errorf("%w: %d unexpired invites", ErrOverLimit, MaxLiveInvites)
```

  INVITE case:

```go
	case pb.RecordType_INVITE:
		var i pb.Invite
		if err := proto.Unmarshal(b.Payload, &i); err != nil {
			return err
		}
		var ahead int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM invites WHERE inviter=? AND expires_ms>?
			AND (created_ms<? OR (created_ms=? AND COALESCE(record_key, x'')<?))`,
			b.Author, now, b.CreatedMs, b.CreatedMs, it.key).Scan(&ahead); err != nil {
			return err
		}
		if ahead >= MaxLiveInvites {
			if !it.fromPeer {
				return ErrInviteBudget
			}
			_, err := tx.ExecContext(ctx, `DELETE FROM records WHERE record_key=?`, it.key) // past the rank: dropped
			return err
		}
		if _, err := tx.ExecContext(ctx, `INSERT OR IGNORE INTO invites(invite_id,inviter,expires_ms,created_ms,record_key) VALUES(?,?,?,?,?)`,
			i.InviteId, b.Author, i.ExpiresMs, b.CreatedMs, it.key); err != nil {
			return err
		}
		// unused invites pushed past the rank by this one are evicted (used ones stay: single use, Tasks 30–39)
		rows, err := tx.QueryContext(ctx, `SELECT invite_id, record_key FROM invites WHERE inviter=? AND expires_ms>?
			AND used_by IS NULL AND record_key IS NOT NULL ORDER BY created_ms, record_key LIMIT -1 OFFSET ?`,
			b.Author, now, MaxLiveInvites)
		if err != nil {
			return err
		}
		var evict [][2][]byte
		for rows.Next() {
			var id, key []byte
			if err := rows.Scan(&id, &key); err != nil {
				rows.Close()
				return err
			}
			evict = append(evict, [2][]byte{id, key})
		}
		rows.Close()
		for _, e := range evict {
			if _, err := tx.ExecContext(ctx, `DELETE FROM invites WHERE invite_id=? AND used_by IS NULL`, e[0]); err != nil {
				return err
			}
			if _, err := tx.ExecContext(ctx, `DELETE FROM records WHERE record_key=?`, e[1]); err != nil {
				return err
			}
		}
		return nil
```

  (The eviction query's OFFSET counts only unused rows; a used row inside the rank is kept anyway, so the live
  total can exceed 50 only by used invites, which Tasks 30–39 bound by single use.)

  PUSH_TOKEN case — prepend the supersede rule (the rest of the case stays):

```go
	case pb.RecordType_PUSH_TOKEN: // D60 + C8: only the newest record per author is stored (device is always 1)
		var newer int
		err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM records WHERE type=? AND author=? AND record_key<>?
			AND (created_ms>? OR (created_ms=? AND record_key>?))`,
			int32(pb.RecordType_PUSH_TOKEN), b.Author, it.key, b.CreatedMs, b.CreatedMs, it.key).Scan(&newer)
		if err != nil {
			return err
		}
		if newer > 0 { // an older token (lagging peer or replay): not kept, row unchanged
			_, err := tx.ExecContext(ctx, `DELETE FROM records WHERE record_key=?`, it.key)
			return err
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM records WHERE type=? AND author=? AND record_key<>?`,
			int32(pb.RecordType_PUSH_TOKEN), b.Author, it.key); err != nil {
			return err
		}
		// ... existing body from `var p pb.PushToken` on, unchanged
```

  The newest record is never deleted, so a replay of an older one is always recognised (no tombstone needed) and
  M9.1's `withdrawn` record (the newest) keeps winning.

  `internal/store/query.go`:

```go
// LiveInvites counts the author's invites that expire after nowMs (C8 budget).
func (s *Store) LiveInvites(ctx context.Context, inviter []byte, nowMs int64) (int, error) {
	var n int
	err := s.r.QueryRowContext(ctx, `SELECT COUNT(*) FROM invites WHERE inviter=? AND expires_ms>?`, inviter, nowMs).Scan(&n)
	return n, err
}
```

  `internal/store/janitor.go` `Expire`, before the `compacted` purge:

```go
		// expired invites (C8): records 1 day after expiry; unused rows with them, used rows stay (single use)
		inviteCut := now - 24*time.Hour.Milliseconds()
		rows, err = tx.QueryContext(ctx, `SELECT record_key FROM invites WHERE expires_ms < ? AND record_key IS NOT NULL`, inviteCut)
		if err != nil {
			return err
		}
		var oldInvites [][]byte
		for rows.Next() {
			var k []byte
			if err := rows.Scan(&k); err != nil {
				rows.Close()
				return err
			}
			oldInvites = append(oldInvites, k)
		}
		rows.Close()
		for _, k := range oldInvites {
			if err := compact(ctx, tx, k, now); err != nil {
				return err
			}
		}
		if err := exec(&st.Compacted, `DELETE FROM records WHERE type=? AND expires_ms > 0 AND expires_ms < ?`,
			int32(pb.RecordType_INVITE), inviteCut); err != nil { // legacy rows without record_key
			return err
		}
		st.Compacted += int64(len(oldInvites))
		if err := exec(&ignore, `DELETE FROM invites WHERE expires_ms < ? AND used_by IS NULL`, inviteCut); err != nil {
			return err
		}
```

- [ ] **Step 6: Service.** New `internal/service/ratelimit.go`:

```go
package service

import (
	"sync"
	"time"
)

// windowCounter counts events per key in a sliding window (in memory; a restart forgets it).
type windowCounter struct {
	mu   sync.Mutex
	hits map[string][]time.Time
}

// allow records one event for key and reports true when fewer than limit events happened within window before now;
// a refused event is not recorded.
func (w *windowCounter) allow(now time.Time, window time.Duration, key string, limit int) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.hits == nil {
		w.hits = map[string][]time.Time{}
	}
	for k, ts := range w.hits { // drop old events everywhere so the map stays small
		i := 0
		for i < len(ts) && now.Sub(ts[i]) >= window {
			i++
		}
		if i == len(ts) {
			delete(w.hits, k)
		} else {
			w.hits[k] = ts[i:]
		}
	}
	if len(w.hits[key]) >= limit {
		return false
	}
	w.hits[key] = append(w.hits[key], now)
	return true
}
```

  `Service` struct: add `submits windowCounter // local submit rates (C8)`. `internal/service/submit.go`
  (imports `time`, `errors`, `ottermsg/server/internal/store`):

```go
// submitRates: records per author per hour accepted from clients (C8); replication is bounded by the budgets.
var submitRates = map[pb.RecordType]int{pb.RecordType_PREKEYS: 20, pb.RecordType_PUSH_TOKEN: 30}
```

  In `Submit`, right after the `allowed` check:

```go
	now := s.Now()
	if body.CreatedMs > now.Add(MaxClockSkew).UnixMilli() {
		return nil, fmt.Errorf("%w: created_ms is in the future", ErrInvalid)
	}
	if lim, ok := submitRates[body.Type]; ok && !s.submits.allow(now, time.Hour, fmt.Sprintf("%d/%x", body.Type, user), lim) {
		return nil, fmt.Errorf("%w: more than %d %v records this hour", ErrQuota, lim, body.Type)
	}
```

  and map the store's budget error after `ApplyFrom`:

```go
	_, applied, err := s.Store.ApplyFrom(ctx, rec, body, s.NodeID)
	if errors.Is(err, store.ErrOverLimit) {
		return nil, fmt.Errorf("%w: %v", ErrQuota, err)
	}
	if err != nil {
		return nil, err
	}
```

- [ ] **Step 7: Run** `go test ./internal/service/ ./internal/records/ ./internal/admin/ ./internal/store/ -count=1 -race` →
  `ok`; `go test ./... -count=1` → all `ok` (if a test helper creates INVITEs with a TTL > 30 days, shorten it).

- [ ] **Step 8: Commit**

```bash
git add internal/store/migrations/0014_invite_budget.sql internal/store/typed.go internal/store/janitor.go \
  internal/store/query.go internal/records/validate.go internal/records/validate_test.go internal/admin/invite.go \
  internal/service/ratelimit.go internal/service/submit.go internal/service/service.go internal/service/budget_test.go
oc -m "server: newest push-token record only, invite lifetime and per-author budget, submit rates (C8)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 44: meshsim — budgets converge and a node that was away catches up after compaction

**Goal:** Prove on a real three-node mesh that budgets give the same live set on every node, compaction does not
break anti-entropy, and a replay of compacted records changes nothing.

**Findings closed:** C8 (hostile-node test across nodes)

**Files:**
- Test: new `otter-server/internal/meshsim/budget_test.go`

**Acceptance Criteria:**
- [ ] With C stopped: anna creates 55 invites on A (50 ok, 5 `QUOTA`), registers 5 push tokens, uploads 3 refills of
  150 keys owned by B; both A and B run the janitor 2 h later.
- [ ] C started → `recordKeys()` of A, B and C equal; C's live one-time keys for anna owned by B = 200; C's push
  token = the newest; C has 50 live invites for anna.
- [ ] A hostile replay of the first token record and the first refill into C (as from peer A) → C's state unchanged.

**Verify:** `cd otter-server && go test ./internal/meshsim/ -run TestBudgetsConvergeAfterCompaction -count=3 -race` → `ok`

**Steps:**

- [ ] **Step 1: Write the test** `internal/meshsim/budget_test.go` (uses `newSim`, `s.register`, `s.login`,
  `s.signAs`, `s.stop`, `s.start`, `eventually`, `n.recordKeys()`, `recordKey`, `client.call`; if Tasks 30–39
  changed `s.register`, call it as changed):

```go
package meshsim

import (
	"context"
	"crypto/rand"
	"fmt"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/records"
	"ottermsg/server/internal/store"
)

func (s *sim) signAt(a *account, typ pb.RecordType, payload proto.Message, created, expires int64) *pb.Record {
	p, _ := proto.Marshal(payload)
	id := make([]byte, 16)
	rand.Read(id)
	r, err := records.Sign(&pb.RecordBody{Id: id, Type: typ, Author: a.id, CreatedMs: created, ExpiresMs: expires, Payload: p}, a.priv)
	if err != nil {
		s.t.Fatal(err)
	}
	return r
}

// C8: per-author budgets give the same live set everywhere; compaction keeps Since(cursor) complete.
func TestBudgetsConvergeAfterCompaction(t *testing.T) {
	s := newSim(t, "a", "b", "c")
	a, b, c := s.node("a"), s.node("b"), s.node("c")
	anna := s.register(a, "anna", a, b)
	eventually(t, "anna on C", func() bool { return c.knows(anna) })
	s.stop(c)
	ctx := context.Background()
	annaA := s.login(a, anna)
	now := time.Now()
	quota := 0
	for i := 0; i < 55; i++ {
		inv := &pb.Invite{InviteId: append(make([]byte, 28), byte(i>>24), byte(i>>16), byte(i>>8), byte(i)),
			ExpiresMs: now.Add(7 * 24 * time.Hour).UnixMilli()}
		r := s.signAt(anna, pb.RecordType_INVITE, inv, now.Add(time.Duration(i)*time.Millisecond).UnixMilli(), inv.ExpiresMs)
		if st, _ := annaA.call("invite.create", &pb.RecordRequest{Record: r}, nil); st == pb.Status_STATUS_QUOTA {
			quota++
		}
	}
	if quota != 5 {
		t.Fatalf("%d invites refused, want 5", quota)
	}
	var tokens []*pb.Record
	for i := 0; i < 5; i++ {
		r := s.signAt(anna, pb.RecordType_PUSH_TOKEN, &pb.PushToken{DeviceId: 1, Kind: pb.PushToken_FCM, Token: fmt.Sprint("tok", i)},
			now.Add(time.Duration(i-10)*time.Second).UnixMilli(), 0)
		tokens = append(tokens, r)
		annaA.mustCall("push.register", &pb.RecordRequest{Record: r}, nil)
	}
	var refills []*pb.Record
	for i := 0; i < 3; i++ {
		pk := &pb.PreKeys{DeviceId: 1, RegistrationId: 4}
		for j := 0; j < 150; j++ {
			pk.OneTime = append(pk.OneTime, &pb.OneTimePreKey{Id: uint32(1000 + 150*i + j), PublicKey: make([]byte, 33), OwnerNode: b.id})
		}
		r := s.signAs(anna, pb.RecordType_PREKEYS, pk)
		refills = append(refills, r)
		annaA.mustCall("prekeys.upload", &pb.RecordRequest{Record: r}, nil)
	}
	eventually(t, "A and B equal", func() bool { return a.recordKeys() == b.recordKeys() })
	for _, n := range []*simNode{a, b} {
		if _, err := n.st.Expire(ctx, now.Add(2*time.Hour).UnixMilli()); err != nil {
			t.Fatal(err)
		}
	}
	s.start(c)
	eventually(t, "C converged", func() bool { return c.recordKeys() == a.recordKeys() && a.recordKeys() == b.recordKeys() })
	check := func(when string) {
		if m, _ := c.st.PrekeyCounts(ctx, anna.id, 1); m[string(b.id)] != store.MaxLiveOneTime {
			t.Fatalf("%s: C holds %d keys owned by B", when, m[string(b.id)])
		}
		if tok, _ := c.st.PushToken(ctx, anna.id, 1); tok != "tok4" {
			t.Fatalf("%s: C token %q", when, tok)
		}
		if n, _ := c.st.LiveInvites(ctx, anna.id, now.UnixMilli()); n != store.MaxLiveInvites {
			t.Fatalf("%s: C has %d live invites", when, n)
		}
	}
	check("caught up")
	for _, r := range []*pb.Record{tokens[0], refills[0]} { // a hostile peer replays compacted records
		if _, err := c.svc.ApplyReplicated(ctx, a.id, r); err != nil {
			t.Fatal(err)
		}
	}
	check("after replay")
}
```

  `n.knows(account)` is the existing helper used in `TestRestartCatchesUp`. The registration invites (bootstrap,
  network-authored) do not count toward anna's 50.

- [ ] **Step 2: Run** `go test ./internal/meshsim/ -run TestBudgetsConvergeAfterCompaction -count=3 -race` → `ok`
  (Tasks 42–43 are in; if it fails, the failure is real — fix the store, not the test).

- [ ] **Step 3: Commit**

```bash
git add internal/meshsim/budget_test.go
oc -m "meshsim: budgets converge and a returning node catches up after compaction (C8)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 45: TURN refuses a revoked user's still-valid credentials

**Goal:** A member revoked by the admin loses the relay within one TURN refresh, even with 12-hour credentials in hand.

**Findings closed:** M8 review (TURN credential lifetime/scope)

**Files:**
- Modify: `otter-server/internal/turnsrv/server.go:20-40,203-213` (`Config.Revoked`, auth wrapper)
- Modify: `otter-server/internal/service/calls.go` (`TurnUserRevoked`), `otter-server/internal/service/service.go` (cache fields), `otter-server/internal/store/query.go` (`RevokedUserIDs`)
- Modify: `otter-server/cmd/otter-node/main.go:371-375` (wire `Revoked`)
- Test: `otter-server/internal/turnsrv/server_test.go` (new `TestRevokedUserRefusedOnEveryRequest`), `otter-server/internal/service/calls_test.go` (new)

**Acceptance Criteria:**
- [ ] With credentials issued before the revocation: Allocate + CreatePermission work; after `Revoked` turns true the
  next CreatePermission fails and a netlog `auth` line «revoked user» is written; a fresh Allocate fails.
- [ ] `TurnUserRevoked(UserTag(anna))` is false before and true ≤ 30 s (service clock) after a REVOCATION for anna
  is applied (Tasks 30–39).
- [ ] Depends on Tasks 30–39: `users.revoked` is set when a REVOCATION applies and `turn.credentials` refuses a
  revoked user.

**Verify:** `cd otter-server && go test ./internal/turnsrv/ ./internal/service/ -run 'Revoked' -count=1 -race` → `ok`

**Steps:**

- [ ] **Step 1: Failing tests.** `internal/turnsrv/server_test.go` (add `"sync/atomic"`):

```go
func TestRevokedUserRefusedOnEveryRequest(t *testing.T) {
	secret := bytes.Repeat([]byte{7}, SecretLen)
	nl := &memLog{}
	var revoked atomic.Bool
	anna := []byte("anna-00000000000")
	cfg := testConfig(secret, 4, 41, nl)
	cfg.Revoked = func(tag string) bool { return revoked.Load() && tag == UserTag(anna) }
	_, addr := startCfg(t, cfg)
	u, p := Credentials(secret, anna, time.Now(), TTL)
	c := client(t, addr, u, p)
	if _, err := c.Allocate(); err != nil {
		t.Fatal(err)
	}
	if err := c.CreatePermission(&net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 9}); err != nil {
		t.Fatal(err)
	}
	revoked.Store(true)
	if err := c.CreatePermission(&net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 10}); err == nil {
		t.Fatal("revoked user kept the relay")
	}
	if _, err := client(t, addr, u, p).Allocate(); err == nil {
		t.Fatal("revoked user allocated")
	}
	waitFor(t, "revoked netlog line", func() bool { return strings.Contains(nl.String(), "revoked user") })
}
```

  New `internal/service/calls_test.go`:

```go
package service

import (
	"context"
	"testing"
	"time"

	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/turnsrv"
)

func TestTurnUserRevokedFollowsRevocation(t *testing.T) {
	f := newFx(t)
	now := time.Now()
	f.svc.Now = func() time.Time { return now }
	anna := f.mustRegister(f.invite(nil, time.Hour), "anna")
	tag := turnsrv.UserTag(anna.id)
	if f.svc.TurnUserRevoked(tag) {
		t.Fatal("revoked before the revocation")
	}
	rev := sign(t, pb.RecordType_REVOCATION, keys.ID16(f.svc.NetworkPub), &pb.Revocation{UserId: anna.id, Reason: "test"}, f.netPriv)
	if _, err := f.svc.ImportRecord(context.Background(), rev); err != nil {
		t.Fatal(err)
	}
	now = now.Add(31 * time.Second)
	if !f.svc.TurnUserRevoked(tag) {
		t.Fatal("revocation not seen by TURN within 30 s")
	}
}
```

  (If Tasks 30–39 apply REVOCATION through another entry point than `ImportRecord`, use that one.)

- [ ] **Step 2: Run** → FAIL (`cfg.Revoked`, `TurnUserRevoked` undefined).

- [ ] **Step 3: turnsrv.** `Config`: add after `AllowPrivatePeers bool`:

```go
	Revoked func(tag string) bool // the account behind a TURN user tag was revoked (D108); nil = none
```

  Auth wrapper in `Start`:

```go
	auth := func(ra *turn.RequestAttributes) (string, []byte, bool) {
		if expired(ra.Username, cfg.now()) {
			nl(ra.SrcAddr, netlog.Auth, "expired or malformed credentials")
			return "", nil, false
		}
		if _, tag, _ := strings.Cut(ra.Username, ":"); cfg.Revoked != nil && cfg.Revoked(tag) {
			nl(ra.SrcAddr, netlog.Auth, "revoked user")
			return "", nil, false
		}
		return rest(ra)
	}
```

  (import `strings`).

- [ ] **Step 4: Store and service.** `internal/store/query.go` (skip if Tasks 30–39 added an equivalent; then use it):

```go
// RevokedUserIDs lists revoked accounts (REVOCATION applied, Tasks 30–39).
func (s *Store) RevokedUserIDs(ctx context.Context) ([][]byte, error) {
	rows, err := s.r.QueryContext(ctx, `SELECT user_id FROM users WHERE revoked=1`)
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
```

  `Service` struct: add

```go
	turnMu        sync.Mutex
	turnRevoked   map[string]bool // TURN user tags of revoked accounts (D108)
	turnRevokedAt time.Time
```

  `internal/service/calls.go` (imports `ottermsg/server/internal/turnsrv`):

```go
// turnRevokedTTL: how stale the revoked-tag set may be; TURN asks on every request (Refresh, permissions, ...).
const turnRevokedTTL = 30 * time.Second

// TurnUserRevoked reports whether a TURN user tag (turnsrv.UserTag) belongs to a revoked account, so credentials
// issued before the revocation stop working at the next TURN request (D108). On a read error the last set is kept.
func (s *Service) TurnUserRevoked(tag string) bool {
	s.turnMu.Lock()
	defer s.turnMu.Unlock()
	if now := s.Now(); s.turnRevoked == nil || now.Sub(s.turnRevokedAt) >= turnRevokedTTL {
		ids, err := s.Store.RevokedUserIDs(context.Background())
		if err != nil {
			s.logger().Warn("turn: revoked users not readable", "err", err)
		} else {
			m := make(map[string]bool, len(ids))
			for _, id := range ids {
				m[turnsrv.UserTag(id)] = true
			}
			s.turnRevoked, s.turnRevokedAt = m, now
		}
	}
	return s.turnRevoked[tag]
}
```

  Remove the "M9 (user revocation) must make this refuse revoked users" comment line if Tasks 30–39 did not already.

- [ ] **Step 5: Wire** in `cmd/otter-node/main.go` `startTurn`: add `Revoked: a.svc.TurnUserRevoked,` to the
  `turnsrv.Config{...}` literal.

- [ ] **Step 6: Run** `go test ./internal/turnsrv/ ./internal/service/ -count=1 -race` → `ok`; `go vet ./... && go test ./... -count=1` → `ok`.

- [ ] **Step 7: Commit**

```bash
git add internal/turnsrv/server.go internal/turnsrv/server_test.go internal/service/calls.go internal/service/calls_test.go \
  internal/service/service.go internal/store/query.go cmd/otter-node/main.go
oc -m "turn: a revoked user's credentials stop working at the next TURN request (M8 review)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 46: Call pushes have a per-sender budget; future-dated envelopes never push

**Goal:** A member cannot turn call signaling into unlimited high-priority wake-ups of another member's phone.

**Findings closed:** M8 review (call pushes as a wake-spam vector)

**Files:**
- Modify: `otter-server/internal/service/push.go:49-77` (`maybePush`), `otter-server/internal/service/service.go` (field `callWakes`)
- Test: `otter-server/internal/service/push_test.go` (new `TestCallPushBudget`, `TestNoPushForFutureEnvelopes`)

**Acceptance Criteria:**
- [ ] 30 call envelopes from mallory to bob within a minute → 8 `WakeCall`, 22 `Wake` (coalesced by the pusher).
- [ ] A call from anna to bob in the same minute still gets `WakeCall` (budget is per sender).
- [ ] After a minute mallory's calls ring again.
- [ ] An urgent envelope with `created_ms` 10 min ahead → no push at all.

**Verify:** `cd otter-server && go test ./internal/service/ -run 'Push' -count=1 -race` → `ok`

**Steps:**

- [ ] **Step 1: Failing tests** in `internal/service/push_test.go`:

```go
func TestCallPushBudget(t *testing.T) {
	self := []byte("bbbbbbbbbbbbbbbb")
	now := time.UnixMilli(1_800_000_000_000)
	w := &wakeRec{}
	s := &Service{NodeID: self, Waker: w, Now: func() time.Time { return now }, Notify: nopNotifier{},
		manifest: &pb.Manifest{Nodes: []*pb.NodeInfo{{NodeId: self, PushCapable: true}}}}
	call := func(from string) {
		body := &pb.RecordBody{Author: []byte(from), CreatedMs: now.UnixMilli(), ExpiresMs: now.Add(2 * time.Minute).UnixMilli()}
		s.maybePush(context.Background(), body, &pb.Envelope{Urgent: true, Recipients: []*pb.Recipient{{User: []byte("bob"), Device: 1}}}, nil)
	}
	for i := 0; i < 30; i++ {
		call("mallory")
	}
	if len(w.calls) != maxCallWakesPerPair || len(w.woke) != 30-maxCallWakesPerPair {
		t.Fatalf("call wakes %d, message wakes %d", len(w.calls), len(w.woke))
	}
	call("anna")
	if len(w.calls) != maxCallWakesPerPair+1 {
		t.Fatal("another caller was throttled by mallory")
	}
	now = now.Add(callWakeWindow)
	call("mallory")
	if len(w.calls) != maxCallWakesPerPair+2 {
		t.Fatal("budget did not recover")
	}
}

func TestNoPushForFutureEnvelopes(t *testing.T) {
	self := []byte("bbbbbbbbbbbbbbbb")
	now := time.UnixMilli(1_800_000_000_000)
	w := &wakeRec{}
	s := &Service{NodeID: self, Waker: w, Now: func() time.Time { return now }, Notify: nopNotifier{},
		manifest: &pb.Manifest{Nodes: []*pb.NodeInfo{{NodeId: self, PushCapable: true}}}}
	ahead := now.Add(10 * time.Minute).UnixMilli()
	s.maybePush(context.Background(), &pb.RecordBody{Author: []byte("mallory"), CreatedMs: ahead, ExpiresMs: ahead + 120_000},
		&pb.Envelope{Urgent: true, Recipients: []*pb.Recipient{{User: []byte("bob"), Device: 1}}}, nil)
	if len(w.calls)+len(w.woke) != 0 {
		t.Fatal("future-dated envelope pushed")
	}
}
```

- [ ] **Step 2: Run** → FAIL (`maxCallWakesPerPair` undefined).

- [ ] **Step 3: Implement.** `Service` struct: add `callWakes windowCounter // call pushes per (sender, recipient) (D108)`.
  In `push.go`:

```go
// Call push budget (D108): beyond it a call envelope wakes like a message (coalesced, ≤ 1 per 10 s), so a flood of
// fake "calls" cannot keep a phone on high-priority pushes; a real call still rings after that wake-up.
const (
	callWakeWindow      = time.Minute
	maxCallWakesPerPair = 8 // offer, candidate batches, hangup of a couple of redials
)

func (s *Service) maybePush(ctx context.Context, body *pb.RecordBody, e *pb.Envelope, from []byte) {
	now := s.Now()
	if !e.Urgent || body.CreatedMs < now.Add(-pushMaxAge).UnixMilli() || body.CreatedMs > now.Add(MaxClockSkew).UnixMilli() ||
		!s.pushDuty(from) {
		return
	}
	call := isCall(body, e)
	for _, r := range e.Recipients {
		switch {
		case call && s.callWakes.allow(now, callWakeWindow, fmt.Sprintf("%x>%x/%d", body.Author, r.User, r.Device), maxCallWakesPerPair):
			s.Waker.WakeCall(ctx, r.User, r.Device)
		case call:
			s.logger().Info("call push over budget", "from", userTag(body.Author), "user", userTag(r.User), "device", r.Device)
			s.Waker.Wake(ctx, r.User, r.Device)
		case s.Notify.Online(r.User, r.Device):
			s.logger().Info("push skipped", "user", userTag(r.User), "device", r.Device, "kind", "message", "reason", "online")
		default:
			s.Waker.Wake(ctx, r.User, r.Device)
		}
	}
}
```

  (`TestMaybePush` keeps passing: its envelopes have `CreatedMs` in the past.)

- [ ] **Step 4: Run** `go test ./internal/service/ -run Push -count=1 -race` → `ok`; `go test ./internal/meshsim/ -run Push -count=1` → `ok`.

- [ ] **Step 5: Commit**

```bash
git add internal/service/push.go internal/service/push_test.go internal/service/service.go
oc -m "push: call wake-ups budgeted per sender and recipient; no push for future-dated envelopes (M8 review)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 47: Android — calls trust neither the node's TURN answer nor revoked or future-dated callers

**Goal:** A hostile node cannot feed WebRTC an unbounded or odd ICE-server list, and a revoked member or a
future-dated offer cannot make the phone ring.

**Findings closed:** M8 review (TURN answer from the node, CallManager accepting offers from revoked members,
call-signaling times)

**Files:**
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/calls/TurnCache.kt` (`sane`)
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/messaging/MailboxReceiver.kt:84-90` (revoked sender)
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/calls/CallStateMachine.kt:57`, `CallModels.kt:27-32` (`MAX_SKEW_MS`)
- Test: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/calls/TurnCacheTest.kt`, `CallSignalingTest.kt`, `CallStateMachineTest.kt`

**Acceptance Criteria:**
- [ ] `TurnCache.get` returns null (→ «Звонки недоступны») for: 0 or 5+ URLs, a `stun:`/`http:` URL, a hostname
  instead of an IPv4 literal, two different hosts, port 0 or > 65535, transport other than udp/tcp, an expiry in
  the past or > 24 h ahead, username or password > 256 chars. The current production answer (3 URLs, one IPv4,
  12 h) passes.
- [ ] Call content from a contact with `revoked = true` is acked and never reaches `CallInbox`.
- [ ] An offer whose `createdMs` is 10 min ahead of the phone clock → missed line, state stays `Idle`.

**Verify:** `cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*TurnCacheTest' --tests '*CallSignalingTest' --tests '*CallStateMachineTest'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing tests.** `TurnCacheTest.kt`:

```kotlin
    @Test fun oddAnswersFromAHostileNodeAreRefused() = runBlocking {
        val exp = now / 1000 + 43_200
        fun creds(vararg urls: String, user: String = "$exp:abcd", pass: String = "p") =
            TurnCredentials.newBuilder().setUsername(user).setPassword(pass).setTtlS(43_200).addAllUrls(urls.toList()).build()
        val good = creds("turn:203.0.113.7:3478?transport=udp", "turn:203.0.113.7:3478?transport=tcp",
            "turns:203.0.113.7:5349?transport=tcp")
        assertTrue(TurnCache.sane(good, now))
        val bad = listOf(
            creds(),
            creds(*Array(5) { "turn:203.0.113.7:3478?transport=udp" }),
            creds("stun:203.0.113.7:3478"),
            creds("turn:relay.example.org:3478?transport=udp"),
            creds("turn:203.0.113.7:3478?transport=udp", "turn:198.51.100.1:3478?transport=udp"),
            creds("turn:203.0.113.7:0?transport=udp"),
            creds("turn:203.0.113.7:70000?transport=udp"),
            creds("turn:203.0.113.7:3478?transport=sctp"),
            creds("turn:203.0.113.7:3478?transport=udp", user = "${now / 1000 - 1}:abcd"),
            creds("turn:203.0.113.7:3478?transport=udp", user = "${now / 1000 + 25 * 3600}:abcd"),
            creds("turn:203.0.113.7:3478?transport=udp", user = "$exp:" + "a".repeat(300)),
            creds("turn:203.0.113.7:3478?transport=udp", pass = "p".repeat(300)),
        )
        bad.forEachIndexed { i, c -> assertFalse("case $i", TurnCache.sane(c, now)) }
        val api = object : NodeApi by FakeNode({ 0L }).connect() {
            override suspend fun nodeId() = ByteArray(16) { 1 }
            override suspend fun turnCredentials() = bad[4]
        }
        assertNull(cache.get(api))
    }
```

  (add `import org.junit.Assert.assertFalse`.)

  `CallSignalingTest.kt`:

```kotlin
    @Test fun callContentFromARevokedContactNeverRings() = runBlocking {
        val (sa, sb) = setup()
        val c = checkNotNull(a.db.contactDao().get(b.me.userId))
        a.db.contactDao().upsert(c.copy(revoked = true))
        CallSignaling(b.outbox, clock).send(a.me.userId, CallMessage.newBuilder().setCallId(ByteString.copyFrom(callId.bytes()))
            .setOffer(CallOffer.newBuilder().setSdp("v=0")).build())
        b.outbox.drainOnce(sb)
        a.receiver.handle(sa, node.mailbox(a.me.userId))
        assertTrue(aInbox.messages.isEmpty())
        assertTrue("acked", node.mailbox(a.me.userId).isEmpty())
    }
```

  `CallStateMachineTest.kt`:

```kotlin
    @Test fun anOfferFromTheFutureIsMissedNotRung() {
        val m = m()
        val fx = m.on(CallEvent.RemoteOffer(high, anna, "sdp", restart = false, createdMs = 1_000_000 + 10 * 60_000,
            systemBusy = false, nowMs = 1_000_000))
        assertEquals(CallState.Idle, m.state)
        assertTrue(fx.any { it is CallEffect.Missed })
    }
```

- [ ] **Step 2: Run** the Verify command → FAIL (`sane` unresolved; revoked offer reaches the inbox; future offer rings).

- [ ] **Step 3: TurnCache.** In `get`, replace `api.turnCredentials().also { cached = node to it }` with:

```kotlin
            val c = api.turnCredentials()
            if (!sane(c, clock.now())) {
                log.warning("turn.credentials answer refused (bounds)") // a broken or hostile node: no calls via it
                cached = null
                return@withLock null
            }
            c.also { cached = node to it }
```

  Companion additions (imports `java.util.logging.Logger`):

```kotlin
        private val log = Logger.getLogger("TurnCache")
        private const val MAX_URLS = 4
        private const val MAX_FIELD = 256
        private const val MAX_TTL_MS = 24 * 3_600_000L
        private val URL = Regex("""^turns?:(\d{1,3}(?:\.\d{1,3}){3}):(\d{1,5})\?transport=(udp|tcp)$""")

        /** A node's TURN answer is used only within these bounds (D108): 1–4 TURN URLs on one IPv4 host. */
        internal fun sane(c: TurnCredentials, nowMs: Long): Boolean {
            if (c.urlsCount !in 1..MAX_URLS || c.username.length > MAX_FIELD || c.password.length > MAX_FIELD) return false
            val exp = (c.username.substringBefore(':', "").toLongOrNull() ?: return false) * 1000
            if (exp <= nowMs || exp > nowMs + MAX_TTL_MS) return false
            val hosts = c.urlsList.map { u ->
                val m = URL.matchEntire(u) ?: return false
                val (host, port) = m.destructured
                if (port.toInt() !in 1..65535 || host.split('.').any { it.toInt() > 255 }) return false
                host
            }
            return hosts.distinct().size == 1
        }
```

- [ ] **Step 4: MailboxReceiver.** In the `Content.BodyCase.CALL ->` branch, first line:

```kotlin
                Content.BodyCase.CALL -> {
                    if (sender.revoked) { acks += key; continue } // a revoked member cannot ring (D108)
                    calls.onCallMessage(sender.userId, sender.displayName, content.call, body.createdMs)
                    acks += key; continue
                }
```

  If Tasks 30–39 already skip all content from revoked senders before this `when`, keep only the test.

- [ ] **Step 5: CallStateMachine.** `CallModels.kt` `CallTimers`: add `const val MAX_SKEW_MS = 5 * 60_000L // login
  allows ±5 min (D52); an offer further ahead is not trusted to be fresh`. `CallStateMachine.kt` line 57:

```kotlin
        val age = ev.nowMs - ev.createdMs
        if (ev.id in ended || age >= RING_MS || age < -MAX_SKEW_MS) {
```

  (import `app.ottermsg.core.data.calls.CallTimers.MAX_SKEW_MS`).

- [ ] **Step 6: Run** the Verify command → `BUILD SUCCESSFUL`; then `./gradlew :core:data:testDebugUnitTest` → `BUILD SUCCESSFUL`.

- [ ] **Step 7: Commit** (in `otter-android`)

```bash
git add core/data/src/main/kotlin/app/ottermsg/core/data/calls/TurnCache.kt \
  core/data/src/main/kotlin/app/ottermsg/core/data/messaging/MailboxReceiver.kt \
  core/data/src/main/kotlin/app/ottermsg/core/data/calls/CallStateMachine.kt \
  core/data/src/main/kotlin/app/ottermsg/core/data/calls/CallModels.kt \
  core/data/src/test/kotlin/app/ottermsg/core/data/calls/TurnCacheTest.kt \
  core/data/src/test/kotlin/app/ottermsg/core/data/calls/CallSignalingTest.kt \
  core/data/src/test/kotlin/app/ottermsg/core/data/calls/CallStateMachineTest.kt
oc -m "calls: bounded TURN answers; revoked and future-dated callers do not ring (M8 review)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 48: Android — `prekeys_low` from a node is bounded

**Goal:** A hostile node cannot make the phone generate and store unlimited one-time prekeys (for real or invented
owner nodes) by repeating `prekeys_low`.

**Findings closed:** C8 (client side), threat-model rule "no unbounded input"

**Files:**
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/signal/PrekeyRefill.kt`
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/settings/Settings.kt` (`refillTimes`, key `REFILL_TIMES`)
- Test: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/PrekeyRefillTest.kt`, `TestGraph.kt:93`

**Acceptance Criteria:**
- [ ] `prekeys_low` for an owner id not in the verified manifest (and not the connected node) → no keys generated,
  nothing uploaded, `nextOneTimeId` unchanged, not added to `pendingRefills`; previously stored unknown owners are
  dropped from `pendingRefills` at the next login.
- [ ] 20 `prekeys_low` events for the connected node within a minute → exactly 1 upload; after 5 min one more; never
  more than 6 per owner per 24 h — also across a restart (times persisted in `Settings`).
- [ ] Existing `PrekeyRefillTest` cases pass (the "another owner" case now uses a node listed in the manifest).

**Verify:** `cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*PrekeyRefillTest'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing tests** in `PrekeyRefillTest.kt`. Change `refillForAnotherOwnerAndRetryAtLogin` to use a
  manifest node: first line `node.manifest = node.signManifest(1, extraHosts = listOf("other"))` and
  `val other = ByteArray(16) { 1 }` (FakeNode gives the first extra host id `ByteArray(16) { 1 }`). Add:

```kotlin
    @Test fun ownersOutsideTheManifestAreIgnored() = runBlocking {
        a.register(node.bootstrapLink(), "Мама", "mama").getOrThrow()
        a.online()
        val next = a.settings.nextOneTimeId()
        val stranger = ByteArray(16) { 0x77 }
        a.session!!.emit("prekeys_low", app.ottermsg.proto.v1.PrekeysLow.newBuilder().setRemaining(0).setOwnerNode(bs(stranger)).build())
        Thread.sleep(300)
        assertEquals(next, a.settings.nextOneTimeId())
        assertTrue(a.settings.pendingRefills().isEmpty())
        assertEquals(null, synchronized(node) { node.uploadedByOwner[stranger.joinToString("") { "%02x".format(it) }] })
    }

    @Test fun repeatedPrekeysLowIsRateLimited() = runBlocking {
        a.register(node.bootstrapLink(), "Мама", "mama").getOrThrow()
        a.online()
        val self = node.nodeId.joinToString("") { "%02x".format(it) }
        val before = synchronized(node) { node.uploadedByOwner[self] ?: 0 }
        repeat(20) { a.prekeys.refill(a.session!!, node.nodeId) }
        assertEquals(before + PrekeyRefill.BATCH, synchronized(node) { node.uploadedByOwner[self] })
        clock.advance(5 * 60_000L)
        a.prekeys.refill(a.session!!, node.nodeId)
        assertEquals(before + 2 * PrekeyRefill.BATCH, synchronized(node) { node.uploadedByOwner[self] })
        repeat(10) { clock.advance(5 * 60_000L); a.prekeys.refill(a.session!!, node.nodeId) }
        assertEquals(before + PrekeyRefill.MAX_PER_DAY * PrekeyRefill.BATCH, synchronized(node) { node.uploadedByOwner[self] })
        // a restart does not reset the count
        val fresh = PrekeyRefill(a.accounts, a.settings, a.signal, clock, a.db.manifestDao())
        fresh.refill(a.session!!, node.nodeId)
        assertEquals(before + PrekeyRefill.MAX_PER_DAY * PrekeyRefill.BATCH, synchronized(node) { node.uploadedByOwner[self] })
    }
```

  (`before` covers whatever registration already counted in `node.uploadedByOwner[self]`.)

- [ ] **Step 2: Run** the Verify command → FAIL (`MAX_PER_DAY`, 5-arg constructor unresolved).

- [ ] **Step 3: Settings** (`Settings.kt`), next to `pendingRefills`:

```kotlin
    /** Recent prekey refill times per owner node (hex), for the refill bounds (D108). */
    suspend fun refillTimes(): Map<String, List<Long>> =
        dao.get(REFILL_TIMES)?.decodeToString()?.split('\n')?.mapNotNull { line ->
            val k = line.substringBefore(':', "").takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            k to line.substringAfter(':').split(',').mapNotNull { it.toLongOrNull() }
        }?.toMap() ?: emptyMap()
    suspend fun setRefillTimes(m: Map<String, List<Long>>) =
        dao.put(SettingEntity(REFILL_TIMES, m.entries.joinToString("\n") { (k, v) -> k + ":" + v.joinToString(",") }.encodeToByteArray()))
```

  companion: `const val REFILL_TIMES = "prekeys_refill_times"`.

- [ ] **Step 4: PrekeyRefill.** Constructor gets `private val manifests: ManifestDao` (Hilt provides it, as for
  `InviteRepository`); `TestGraph.kt:93` becomes `PrekeyRefill(accounts, settings, signal, clock, db.manifestDao())`.

```kotlin
    /** Owner nodes we upload keys for: the verified manifest's nodes and the node we are connected to. */
    private suspend fun knownOwners(api: NodeApi): Set<String> {
        val m = manifests.latest()?.let { runCatching { ManifestVerifier.verify(it.raw, settings.networkPub(), 0) }.getOrNull() }
        return (m?.nodesList?.map { it.nodeId.toByteArray().toHex() } ?: emptyList()).toSet() + api.nodeId().toHex()
    }

    /** At most one refill per owner per [MIN_GAP_MS] and [MAX_PER_DAY] per 24 h; records the refill when allowed. */
    private suspend fun takeSlot(owner: String): Boolean {
        val now = clock.now()
        val all = settings.refillTimes().mapValues { (_, v) -> v.filter { now - it < DAY_MS } }.filterValues { it.isNotEmpty() }
        val mine = all[owner].orEmpty()
        if (mine.size >= MAX_PER_DAY || (mine.isNotEmpty() && now - mine.last() < MIN_GAP_MS)) {
            settings.setRefillTimes(all)
            return false
        }
        settings.setRefillTimes(all + (owner to mine + now))
        return true
    }

    suspend fun refill(api: NodeApi, owner: ByteArray? = null, count: Int = BATCH) = mutex.withLock {
        val node = owner?.takeIf { it.isNotEmpty() } ?: api.nodeId()
        val key = node.toHex()
        if (key !in knownOwners(api)) { log.warning("prekeys_low for a node outside the manifest ignored"); return@withLock }
        if (!takeSlot(key)) { log.info("prekey refill for $key skipped (rate)"); return@withLock }
        settings.setPendingRefills(settings.pendingRefills() + key) // cleared only after a successful upload
        // ... the existing body from `val me = accounts.require()` to the end, unchanged
    }

    suspend fun refillIfPending(api: NodeApi) {
        if (settings.prekeysLow()) { refill(api, null); settings.setPrekeysLow(false) }
        val known = knownOwners(api)
        val pending = settings.pendingRefills()
        if (!known.containsAll(pending)) settings.setPendingRefills(pending intersect known)
        for (owner in pending intersect known) refill(api, owner.hexToBytes())
    }

    companion object {
        const val BATCH = 50
        const val MAX_PER_DAY = 6
        const val MIN_GAP_MS = 5 * 60_000L
        private const val DAY_MS = 24 * 3_600_000L
        private val log = java.util.logging.Logger.getLogger("PrekeyRefill")
    }
```

  Imports: `app.ottermsg.core.crypto.ManifestVerifier`, `app.ottermsg.core.database.dao.ManifestDao`. A retry of an
  interrupted upload (pending marker) goes through `takeSlot` too, so a failing node also cannot loop it.

- [ ] **Step 5: Run** the Verify command → `BUILD SUCCESSFUL`; `./gradlew :core:data:testDebugUnitTest` → `BUILD SUCCESSFUL`.

- [ ] **Step 6: Commit** (in `otter-android`)

```bash
git add core/data/src/main/kotlin/app/ottermsg/core/data/signal/PrekeyRefill.kt \
  core/data/src/main/kotlin/app/ottermsg/core/data/settings/Settings.kt \
  core/data/src/test/kotlin/app/ottermsg/core/data/PrekeyRefillTest.kt core/data/src/test/kotlin/app/ottermsg/core/data/TestGraph.kt
oc -m "prekeys: refills only for manifest nodes, at most one per 5 min and six a day per owner (C8)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 49: Release server 0.9.1 + app 0.9.1 (M9.2) and rollout (each step asked first)

**Goal:** M9.2 (Tasks 30–48) merged after the owner's OK; every node on 0.9.1; phones on 0.9.1.

**Findings closed:** none new (ships C2, C4, C5, C6, C8, C9, C10, C12, limit 3, M8 review)

**Files:**
- Modify: `otter-android/app/build.gradle.kts:35` (`versionCode = 12; versionName = "0.9.1"`)
- Modify (docs, branch `m9-2-membership`): `docs/00-decisions.md` (D105–D108 as numbered by the coordinator; D51 marked
  "revised by D105"), `docs/03-mesh-replication.md` ("Deletion & garbage collection" table: superseded PREKEYS /
  PUSH_TOKEN records, expired INVITE records, `compacted` tombstones 30 d, `prekey_floor`, `auth_failures` source
  column; "Compaction & new / long-offline nodes": why compaction keeps `Since(cursor)` complete), `docs/04-security.md`
  (restore throttle, budgets, call hardening), `docs/09-roadmap.md` (M9.2 row)
- Create: `otter-server/dist/news/0.9.1.md` (gitignored; never delete files in `dist/`)

**Acceptance Criteria:**
- [ ] `otter-server`: `make check` → ok; `go test ./internal/meshsim/ -count=3 -race` → ok; `scripts_test.sh` in a
  scratch copy → `scripts_test: ok`; `make release VERSION=0.9.1` builds into `dist/`.
- [ ] `otter-android`: `./gradlew test lintDebug assembleRelease` → BUILD SUCCESSFUL; `apksigner verify
  --print-certs` shows the release certificate.
- [ ] `scripts/secrets-check.sh` → `secrets check: ok` in all three repos.
- [ ] Owner said "merge" → `git merge --no-ff m9-2-membership` in each repo, pushed.
- [ ] Every node runs 0.9.1 (`deploy/status.sh`), migrations 0012–0014 (or their renumbered names) applied, janitor
  log shows `compacted=` once; phones updated through the news dialog.

**Verify:** `deploy/status.sh` → every node `0.9.1`, health ok; on a node (asked first)
`journalctl -u otter-node --since -15min | grep janitor` shows a line with `compacted`.

**Steps:**

- [ ] **Step 1:** Bump the app version; write the docs; commit each repo:

```bash
git add app/build.gradle.kts
oc -m "app: version 0.9.1 (12)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

```bash
git add 00-decisions.md 03-mesh-replication.md 04-security.md 09-roadmap.md
oc -m "docs: M9.2 limits, budgets, restore throttle, call hardening" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 2:** Write `otter-server/dist/news/0.9.1.md` (no IPs or server names). Draft for the M9.2b part (merge
  with the M9.2a text from Tasks 30–39):

```markdown
#### ru
Otter 0.9.1
• Защита восстановления: если кто-то чужой подбирает пароль к вашей копии, это больше не блокирует восстановление на сутки — в худшем случае придётся подождать несколько минут.
• Звонки от удалённых участников больше не приходят.

#### en
Otter 0.9.1
• Restore protection: someone guessing your backup password can no longer block your restore for a day; at worst you wait a few minutes.
• Removed members can no longer call you.
```

- [ ] **Step 3:** Final verification (all Acceptance Criteria checks above; verification-before-completion skill).
  Show the owner a summary (what changed, test counts, open owner questions); wait for "merge"; then
  `scripts/secrets-check.sh` and `git checkout main && git merge --no-ff m9-2-membership && git push` in each repo.

- [ ] **Step 4 (ask):** Before upgrading, on one node (asked first) `otter-node backup` the database (the upgrade
  script also keeps a pre-upgrade copy). Then `deploy/upgrade-all.sh 0.9.1 --no-news` → each node upgraded, health
  ok. Servers go first: 0.9.0 apps keep working (no protocol change in this section; budgets are far above what an
  app sends).
- [ ] **Step 5 (ask):** `deploy/status.sh` → `0.9.1` everywhere; after ≥ 10 min, check one node's journal for the
  janitor line (`compacted=`), and `otter-node netlog` shows no new `auth` failures from phones.
- [ ] **Step 6 (owner runs):** `deploy/release-apk.sh 0.9.1 <release APK>` → news dialog with `dist/news/0.9.1.md`;
  both phones update via «Обновить».
- [ ] **Step 7 (owner):** a call between the two phones still rings and connects; a restore test on the spare phone
  (or emulator) with the right password works on the first try.

---

### Owner questions

1. **Restore slow-down vs. lock (C4).** With D105 a determined stranger can still keep one name at one attempt per
   15 min on one node (other nodes count separately); making the correct password pass during a slow-down would
   hand him a free guessing oracle. *Recommended:* accept D105 as written (5/h per source, 10 free per name per day,
   then 30 s doubling to 15 min).
2. **PUSH_TOKEN budget.** The spec says "4 per device"; storing only the newest record (as the derived row already
   does) is simpler and safer (an old token can never come back, also after M9.1's `withdrawn`). *Recommended:*
   newest record only, plus 30 submits per hour.
3. **INVITE budget wording.** "50 per month" is not the same on every node when invites arrive in different orders.
   *Recommended:* ≤ 50 **unexpired** invites per author (lifetime ≤ 30 days, app invites last 7 days), ranked so
   all nodes keep the same 50; `otter-admin invite bootstrap --ttl` capped at 30 days.
4. **Restores through the dial-out pass-through (M9.3 Limit 1).** All restores relayed by one dial-out node arrive
   at the foreign node from that node's IP, so they share one D105 source (5 failures per name per hour, 30 per day
   before slowing). *Recommended:* the M9.3 pass-through sends a PROXY protocol v2 header to the foreign node, which
   then uses the phone's address as the source; until then accept the shared source.

### Notes for the coordinator

- Depends on Tasks 30–39: `users.revoked` set when a REVOCATION applies, `turn.credentials` refusing revoked users,
  `ContactEntity.revoked` maintained by `DirectorySync`. Task 45's service test imports a REVOCATION; Task 47's
  revoked-caller rule is redundant (but harmless) if Tasks 30–39 already drop all content from revoked senders.
- Task 43 keeps **used** invite rows forever and deletes INVITE **records** one day after expiry: Tasks 30–39 carry
  the invite inside the directory entry (`DirectoryEntry.invite_record = 10`), so the standalone record is not needed
  once expired. If Tasks 30–39 look up the standalone INVITE record after expiry, exempt used invites' records in the
  janitor query (`AND invite_id NOT IN (SELECT invite_id FROM invites WHERE used_by IS NOT NULL)`).
- Task 40 changes `BackupFetch`'s signature; M9.1 (C1/C20) changes `BackupAuth`/`fakeSalt` in the same file — no
  overlap in lines, but whichever lands second rebases.
- M8 review, sub-areas checked with no fix needed: relay port abuse (UDP only, port range, per-user/per-node caps,
  rate cap, own-address rule), peer permission handler (deny list incl. IPv4-mapped IPv6), credential scope (per-node
  secret; a hostile node can only issue credentials for its own relay, which relays media it cannot decrypt),
  signaling injection (call ids are random and only inside E2E envelopes), node time (the phone never uses
  `Hello.server_time_ms`; staleness uses the sender-signed `created_ms`), replayed call envelopes (oplog dedup,
  `ErrExpired`, Signal duplicate detection).

---

## M9.3 — Bound to the network, lost phones, backups away from exposed nodes

Branch `m9-3-network` in `otter-server`, `otter-android` and `docs`. Server **0.10.0**, app **0.10.0 / versionCode 13**.
Depends on M9.2 (tasks 30–39): REVOCATION is applied on nodes and phones, and `otter-admin user list` exists.
Proto changes are made in `otter-server/proto/otter/v1/` and copied with `otter-android/scripts/sync-proto.sh`
(it also copies `testdata/vectors/*.json`); Go code is regenerated with `make gen` in `otter-server`.

**Proto additions:**

| File | Addition | Task |
|---|---|---|
| `manifest.proto` | `Manifest.int64 sig_v1_until_ms = 7;` (fixed allocation) | 50 |
| `records.proto` | `RecordType.REKEY = 18;` and `message Rekey { bytes old_user_id = 1; bytes new_user_id = 2; }` (fixed allocations) | 52 |
| `peer.proto` | `PeerFrame` oneof: `PeerHoldsQuery holds_query = 10; PeerHolds holds = 11; PeerTunnelOpen tunnel_open = 12; PeerTunnelData tunnel_data = 13; PeerTunnelAck tunnel_ack = 14; PeerTunnelClose tunnel_close = 15;` | 56, 57 |
| `peer.proto` | `message PeerHoldsQuery { uint64 req = 1; bytes record_key = 2; }` `message PeerHolds { uint64 req = 1; bool held = 2; }` | 56 |
| `peer.proto` | `message PeerTunnelOpen { uint64 stream = 1; }` `message PeerTunnelData { uint64 stream = 1; bytes data = 2; }` `message PeerTunnelAck { uint64 stream = 1; uint32 chunks = 2; }` `message PeerTunnelClose { uint64 stream = 1; string reason = 2; }` | 57 |
| RPC (no proto change, body `RecordRequest`) | client method **`network.publish`** (public, no login): accepts network-signed `REKEY`, `REVOCATION`, `INVITE_RIGHTS` and network-authored `INVITE`. **Coordinator:** if M9.2 already defines a public publish method for REVOCATION, merge the two under M9.2's name and keep REKEY in its allowed list. | 52 |
| HTTP path (no proto change) | `<wss path>/tunnel?to=<hex node id>` on dial-out nodes only | 57 |

No `Record` field is added: a verifier tries the v2 message first and falls back to v1 (Task 50).

**Verified facts (2026-11-14):**

| Question | Answer | Source |
|---|---|---|
| What is `network_id`? | `keys.ID16(network_pub)` = first 16 bytes of SHA-256(network_pub). Used as the author of network records and by `Service.networkID()`. Android: `Ids.id16(networkPub)`; cross-language vector `network_id_hex` exists. | `otter-server/internal/keys/ids.go:9`, `internal/service/service.go:167`, `otter-android/core/crypto/src/test/.../VectorsTest.kt:24` |
| What does a record signature cover today? | Ed25519 over the exact serialized `RecordBody` bytes; `Record` has only `body` and `signature`, no version. | `internal/records/sign.go:12-17`, `RecordCodec.kt:18-24`, `records.proto` `message Record` |
| Every Go signer | `admin.SignManifest` (`internal/admin/manifest.go:50`), `admin.BootstrapInvite` (`invite.go:74`), `signNews` (`news.go:176`, news key), `Service.emitConsumed` (`service.go:314`, node key, PREKEY_CONSUMED). Tests and meshsim call `records.Sign` directly (14 test sites). | `grep -rn records.Sign` |
| Every Go verifier | `records.Validator.Validate` (`validate.go:101`) — used by submit, replication, import, admin `show`, `signNews`. | `validate.go` |
| Every Android signer | `PushRegistrar.kt:27`, `Registration.kt:101`, `PrekeyRefill.kt:38`, `BlobMetaBuilder.kt:22,29`, `MediaTransfers.kt:177`, `DirectoryEntries.kt:23`, `InstallGuard.kt:51`, `Outbox.kt:141`, `GroupSender.kt:69`, `MailboxReceiver.kt:119`, `InviteRepository.kt:43`, `BackupManager.kt:102,117`; all pass `me.accountKey` (or `account` in Registration). Test signer: `FakeNode.kt:63`. | `grep -rn "RecordCodec.sign"` |
| Every Android verifier | `ManifestVerifier.kt:16`, `AnnouncementVerifier.kt:38`, `DirectorySync.kt:83`, `MailboxReceiver.kt:67`. | `grep -rn "RecordCodec.verify"` |
| Can 0.10.0 phones sign v2 from install, as the spec says? | **No.** 0.9.x phones verify directory entries and envelope records themselves (`DirectorySync.kt:83`, `MailboxReceiver.kt:67`), so a v2 envelope from a 0.10.0 phone would be dropped by a 0.9.x phone. 0.10.0 *accepts* v2 everywhere and *signs* v2 once the newest manifest carries `sig_v1_until_ms != 0` (D109). Same for nodes, admin and news key. | as above |
| Username clash rule | `applyDirectoryEntry`: local submission of a taken name → `ErrUsernameTaken`; replicated clash → lower (rank, user_id) keeps the name, the other becomes `name#<hex(user_id[:4])>`, `username_conflict=1`; rank = `registered_ms` or entry `created_ms`, stored in `users.entry_created_ms`. `Register` refuses a taken name earlier via `UsernameOwner`. | `internal/store/typed.go:364-409`, `internal/service/register.go:51-56` |
| REVOCATION on nodes today | stored as a record only; `applyTyped` has no case for it (M9.2 adds it). `users.revoked` exists and `UserKey` reports it. | `typed.go:32-307`, `query.go:43-51` |
| directory.sync contents | DIRECTORY_ENTRY records of all users (`Store.DirectoryEntries`). Android `DirectorySync.verify` returns null for other record types, so extra record types in the batch are ignored by old apps. | `query.go:81-97`, `DirectorySync.kt:75-79` |
| Android chat model | `contacts` PK `user_id` (+`revoked`, `identity_changed`, `verified`); `conversations.peer_user_id` unique for direct chats; messages reference `conversation_id`; outbox rows carry `recipient_user_id`; system lines use `MessageKind` (TEXT 0 … CALL 6) with the sender's id, e.g. `SYSTEM_RESET` rendered as «%1$s восстановил(а) аккаунт». Room version 8 with AutoMigrations. | `ContactEntity.kt`, `ConversationEntity.kt`, `OutboxEntity.kt`, `MessageStatus.kt:5-9`, `OtterDatabase.kt:46` |
| Group membership | Signed `GroupState{members, admins, version, created_by…}`; acceptance is the pure `GroupRules.evaluate(current, previous, candidate, signer, bytes)`; local changes go through `GroupApplier.change` and `GroupRepository.distribute` (sends the update to members and to removed members). A removal rotates our sender key (`deleteMyDistribution` + `clearShared`). | `GroupRules.kt`, `GroupApplier.kt:51-134`, `GroupRepository.kt:95-112` |
| Replication confirmations | `PeerBatchAck{seq}` only releases a window slot (`session.go:84-88`); the receiver acks after applying, but blob chunks are *pulled* later by the receiver's puller (`blobs.go RunPuller`). No signal says "I hold this blob completely" → new `PeerHoldsQuery/PeerHolds`. Old nodes ignore unknown frame kinds (the `switch` in `session.run` has no default), so a query to an old node times out and the dial-out node keeps its copy. | `internal/replication/session.go`, `blobs.go` |
| Is deleting a record locally safe for replication? | Yes: `Since` joins `records` and skips deleted ones (`apply.go:262-266`); `applyOne` ignores a re-sent key that still has an oplog row (`apply.go:245-251`); BLOB_META with a `blob_tombstones` row is dropped on apply (`typed.go:203-208`). | `internal/store/apply.go`, `typed.go` |
| How phones reach a node | WSS (pinned SPKI) or WS_PLAIN only; phones have no REALITY client (`Endpoints.candidates`). OkHttp 5.2.1; `core/network` tests have `okhttp-tls` and `mockwebserver3`. Restore uses `NodeConnector.withNode(Endpoints.candidates(...))`. | `Endpoints.kt:6-25`, `OkHttpTransport.kt`, `core/network/build.gradle.kts`, `RestoreManager.kt:101-108,158-165` |
| Dial-out rule today | `NodeInfo.dial_out_only` (D71): others never dial it (`replicator.go:199-201`). Phones ignore it. | `manifest.proto`, `replicator.go` |
| net.Conn over a WebSocket | `github.com/coder/websocket` has `NetConn(ctx, c, MessageBinary) net.Conn`. | `go doc github.com/coder/websocket NetConn` |
| Node HTTP mux | `wss.NewServer(cfg, ws, peer)` mounts `cfg.Path` and `cfg.Path+"/peer"`; used in `cmd/otter-node/main.go:331,401`, meshsim `harness_test.go:258,264`, `transport/wss/server_test.go`. | `internal/transport/wss/server.go` |

**Decisions to record:**

- **D109 — Record signature v2 (C7).** v2 signs `"otter-v2\x00" ‖ network_id(16) ‖ body`, network_id = ID16(network_pub).
  v1 (body only) stays valid for records with `created_ms < manifest.sig_v1_until_ms`; `sig_v1_until_ms = 0` means
  v1 is accepted for all records. A verifier tries v2, then v1 under that rule; no field in `Record`. Nodes, phones
  (from 0.10.0), the admin CLI and the news key **verify both** at once and **sign v2 only when the newest manifest
  has `sig_v1_until_ms != 0`** (deviation from the spec's "apps sign v2 from 0.9.x": older apps verify records
  themselves and would drop v2 messages). Stored v1 records stay valid forever (their `created_ms` is signed).
  Residual: a v1 record created before the cut-over can still be replayed into another network that holds the same
  key (seed reuse across networks only).
- **D110 — v2 cut-over procedure.** (1) all nodes on ≥ 0.10.0; (2) app 0.10.0 released and a v1 manifest with
  `min_app_version = 13`; (3) the owner confirms every phone runs 0.10.0; (4) `otter-admin manifest sign
  --sig-v1-until <publish time + 48 h>` and `manifest publish`. That manifest and everything after it is v2-signed.
  The value can only be set once and never lowered or cleared by the CLI.
- **D111 — Lost-phone re-key (limit 2).** Two admin steps. `otter-admin user rekey <username> --old <user id>`: signs and
  publishes `REVOCATION{old}` and a network invite (7 days) for the new install. The person installs fresh and
  registers with the same username; nodes accept it because the name's owner is revoked (the new account shows as
  `name#abcd` meanwhile). The person reads their «Код аккаунта» (32 hex characters, Settings → Профиль) to the
  admin, who runs `otter-admin user rekey <username> --new <code>`: signs `REKEY{old, new}`. On every node REKEY
  revokes `old`, hands the username to `new`, and `new` inherits `old`'s clash rank. Two REKEYs of the same `old`:
  the later `created_ms` wins, ties → lower record key. Phones: contacts map old → new (the old contact is hidden,
  the direct chat continues with the new account, «Ключ безопасности изменился» line, new contact unverified,
  unsent outbox items to `old` are dropped). The person's own history on the lost phone is not recovered.
- **D112 — Groups after a re-key.** `GroupRules` accepts a successor state signed by any current member that only
  replaces `old` by `new` in members and admins (name and everything else unchanged), when the phone knows a verified
  REKEY old → new; without it the state is parked. On learning a REKEY, a group admin's phone signs that swap at once;
  if `old` was the only admin, the remaining member with the lowest user id does. The swap rotates our sender key and
  shows «Ключ безопасности изменился» for the member instead of "removed/added".
- **D113 — No backups at rest on dial-out-only nodes (limit 1, storage half).** A node with `dial_out_only` in the
  current manifest: answers `backup.auth` and `backup.fetch` with UNAVAILABLE; never receives BACKUP_META or
  persistent BLOB_META from peers (senders skip them, it drops them if an old peer sends them, peers refuse it
  persistent chunks); keeps what phones upload to it only until `min(2, number of non-dial-out nodes)` distinct
  non-dial-out peers answer `PeerHolds{held: true}` (record stored and, for a blob, every chunk present), then deletes
  its copy (blob tombstoned 30 days). A persistent blob is handed off only once a BACKUP_META references it or it is
  1 h old, so the phone's `backup.publish` right after the upload still finds it.
- **D114 — Restore tunnel (limit 1, restore half).** A dial-out node serves `<path>/tunnel?to=<node id>`: a WebSocket
  whose binary messages are raw bytes of a TCP stream that ends **inside the foreign node's process** in a TLS server
  with its normal WSS certificate. The bytes travel over the existing outbound peer session (`PeerTunnel*` frames,
  32 KiB chunks, window 32 chunks per stream, ≤ 16 streams per peer, ≤ 4 per client IP and ≤ 32 per node, 2 min
  idle, 30 min life). Foreign nodes accept tunnels only from dial-out peers. Phones use it only for password
  restore and «Добавить историю»: tunnel candidates require a pinned WSS endpoint of the target; the dial-out node is
  never a direct restore candidate. The dial-out node sees only TLS records (sizes and timing).

### Task 50: Server and admin — record signature v2 with a manifest cut-over (C7)

**Goal:** Nodes accept v1 and v2 signatures under D109, refuse v1 records created after `sig_v1_until_ms`, and node,
admin, invite and news signers switch to v2 once the cut-over is set.

**Findings closed:** C7 (server and admin side)

**Files:**
- Modify: `otter-server/proto/otter/v1/manifest.proto` (add `sig_v1_until_ms = 7`), regenerate `internal/proto/otterv1`
- Modify: `otter-server/internal/records/sign.go` (whole file, 17 lines), `internal/records/validate.go:64-106`
- Modify: `otter-server/internal/service/service.go:189-194` (`validator`), `:309-325` (`emitConsumed`)
- Modify: `otter-server/internal/admin/manifest.go:27-63`, `internal/admin/invite.go:46-92`, `internal/admin/news.go:164-186`, new `internal/admin/sigctx.go`
- Modify: `otter-server/cmd/otter-admin/main.go:30-56` (usage), `:350-358` (`manifest sign`)
- Modify: `otter-server/internal/vectors/vectors_test.go` (v2 fields), regenerate `testdata/vectors/v1.json`
- Test: `otter-server/internal/records/sigv2_test.go` (new), `internal/admin/sigctx_test.go` (new), `internal/meshsim/sigv2_test.go` (new)

**Acceptance Criteria:**
- [ ] `records.MessageV2(netID, body)` = `"otter-v2\x00" ‖ netID ‖ body`; `records.SignWith(body, priv, SigContext{NetworkID, V2})` signs v1 or v2.
- [ ] `Validator.Validate` accepts a v2 signature always and a v1 signature only if `V1Until()` is 0 or `created_ms < V1Until()`.
- [ ] **Hostile:** a record v2-signed for network A is rejected (`ErrBadSignature`) by a validator of network B in which the same user key is registered.
- [ ] **Hostile (meshsim):** after the cut-over manifest, a v1-signed ENVELOPE created after `sig_v1_until_ms` is refused from a client (STATUS_INVALID) and from a peer (`ApplyReplicated` → `ErrInvalid`); a v1 record created before it still replicates.
- [ ] `emitConsumed` signs v2 iff the current manifest has `sig_v1_until_ms != 0`.
- [ ] `otter-admin manifest sign --sig-v1-until 2026-12-20T12:00:00Z` stores the value in `DIR/sig_v1_until_ms`, puts it in this and every later manifest, refuses to lower or clear it, and from then on manifests, bootstrap invites and announcements are v2-signed.
- [ ] `testdata/vectors/v1.json` gains `manifest_v2_record_hex` and `directory_entry_v2_record_hex`.

**Verify:** `cd otter-server && go test ./internal/records/ ./internal/admin/ ./internal/vectors/ ./internal/meshsim/ -run 'SigV2|Vectors|Cutover' -count=1 -race` → `ok` ×4; `go test ./... -count=1` → all `ok`

**Steps:**

- [ ] **Step 1: Proto.** In `proto/otter/v1/manifest.proto` add to `Manifest`:

```proto
  int64 sig_v1_until_ms = 7;    // M9.3 (D109): v1 record signatures valid only for created_ms < this; 0 = v1 still valid for all
```

  Run `make gen` → `internal/proto/otterv1/manifest.pb.go` has `GetSigV1UntilMs()`.

- [ ] **Step 2: Failing test** `internal/records/sigv2_test.go`:

```go
package records

import (
	"crypto/ed25519"
	"errors"
	"testing"
	"time"

	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
)

func TestSigV2CrossNetworkAndCutover(t *testing.T) {
	netA, _, _ := ed25519.GenerateKey(nil)
	netB, _, _ := ed25519.GenerateKey(nil)
	userPub, userPriv, _ := ed25519.GenerateKey(nil)
	uid := keys.ID16(userPub)
	users := fakeUsers{string(uid): {Pub: userPub}} // the same key is a member of both networks (seed reuse)
	ack := payload(&pb.Ack{EnvelopeIds: [][]byte{make([]byte, 32)}, DeviceId: 1})
	body := func(created int64) *pb.RecordBody {
		return &pb.RecordBody{Id: rid(), Type: pb.RecordType_ACK, Author: uid, CreatedMs: created, Payload: ack}
	}
	cut := now.Add(-time.Hour).UnixMilli()
	vA := &Validator{NetworkPub: netA, Users: users, Now: func() time.Time { return now }, V1Until: func() int64 { return cut }}
	vB := &Validator{NetworkPub: netB, Users: users, Now: func() time.Time { return now }, V1Until: func() int64 { return cut }}
	ctxA := SigContext{NetworkID: keys.ID16(netA), V2: true}

	recA, err := SignWith(body(now.UnixMilli()), userPriv, ctxA)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := vA.Validate(recA); err != nil {
		t.Fatalf("v2 for A rejected by A: %v", err)
	}
	if _, err := vB.Validate(recA); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("v2 for A accepted by B: %v", err)
	}
	if _, err := vA.Validate(mustSign(t, body(cut-1), userPriv)); err != nil {
		t.Fatalf("v1 before the cut-over rejected: %v", err)
	}
	if _, err := vA.Validate(mustSign(t, body(cut), userPriv)); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("v1 at/after the cut-over accepted: %v", err)
	}
	vA.V1Until = nil // no cut-over yet: v1 is valid for everything
	if _, err := vA.Validate(mustSign(t, body(now.UnixMilli()), userPriv)); err != nil {
		t.Fatalf("v1 without cut-over rejected: %v", err)
	}
	v1 := mustSign(t, body(now.UnixMilli()), userPriv)
	if string(MessageV2(keys.ID16(netA), v1.Body)[:9]) != "otter-v2\x00" {
		t.Fatal("prefix")
	}
}
```

- [ ] **Step 3: Run** `go test ./internal/records/ -run SigV2 -count=1` → FAIL (`undefined: SignWith`, `unknown field V1Until`).

- [ ] **Step 4: Implement** `internal/records/sign.go` (replace the file):

```go
// Package records signs and validates replicated records. It performs no I/O.
package records

import (
	"crypto/ed25519"

	"google.golang.org/protobuf/proto"
	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
)

// v2Prefix starts every v2 signed message (D109); the NUL keeps it from being a prefix of a valid protobuf body.
const v2Prefix = "otter-v2\x00"

// SigContext says how a signer signs new records (D109).
type SigContext struct {
	NetworkID []byte // keys.ID16(network_pub), 16 bytes
	V2        bool   // sign v2: the newest manifest has sig_v1_until_ms != 0
}

// ContextFor is the signing context implied by manifest m of the network networkPub (m may be nil).
func ContextFor(networkPub ed25519.PublicKey, m *pb.Manifest) SigContext {
	return SigContext{NetworkID: keys.ID16(networkPub), V2: m.GetSigV1UntilMs() != 0}
}

// MessageV2 is the byte string a v2 signature covers: "otter-v2\x00" ‖ network_id ‖ body.
func MessageV2(networkID, body []byte) []byte {
	m := make([]byte, 0, len(v2Prefix)+len(networkID)+len(body))
	m = append(m, v2Prefix...)
	m = append(m, networkID...)
	return append(m, body...)
}

// Sign serializes body deterministically and signs the exact bytes (v1). Kept for tests and pre-cut-over tooling;
// production signers use SignWith.
func Sign(body *pb.RecordBody, priv ed25519.PrivateKey) (*pb.Record, error) {
	return SignWith(body, priv, SigContext{})
}

// SignWith signs v2 when sc.V2, else v1.
func SignWith(body *pb.RecordBody, priv ed25519.PrivateKey, sc SigContext) (*pb.Record, error) {
	b, err := proto.MarshalOptions{Deterministic: true}.Marshal(body)
	if err != nil {
		return nil, err
	}
	msg := b
	if sc.V2 {
		msg = MessageV2(sc.NetworkID, b)
	}
	return &pb.Record{Body: b, Signature: ed25519.Sign(priv, msg)}, nil
}
```

  In `validate.go` add the field to `Validator` (after `News`):

```go
	// V1Until returns the manifest's sig_v1_until_ms (D109): records created at or after it need a v2 signature.
	// nil or 0: v1 signatures are accepted for every record.
	V1Until func() int64
```

  and replace `if !ed25519.Verify(key, r.Body, r.Signature) {` in `Validate` with
  `if !v.verifySig(key, r.Body, r.Signature, body.CreatedMs) {`, plus:

```go
// verifySig accepts a v2 signature for this network, or a v1 signature for a record created before the cut-over.
func (v *Validator) verifySig(key ed25519.PublicKey, body, sig []byte, createdMs int64) bool {
	if ed25519.Verify(key, MessageV2(keys.ID16(v.NetworkPub), body), sig) {
		return true
	}
	var until int64
	if v.V1Until != nil {
		until = v.V1Until()
	}
	return (until == 0 || createdMs < until) && ed25519.Verify(key, body, sig)
}
```

- [ ] **Step 5: Run** `go test ./internal/records/ -count=1` → `ok`.

- [ ] **Step 6: Node side.** In `internal/service/service.go`:

```go
func (s *Service) validator(res records.UserResolver) *records.Validator {
	if res == nil {
		res = s.Store
	}
	return &records.Validator{NetworkPub: s.NetworkPub, Users: res, Nodes: s, News: s, Now: s.Now,
		V1Until: func() int64 { return s.CurrentManifest().GetSigV1UntilMs() }}
}

// sigContext is how this node signs its own records (PREKEY_CONSUMED) under the current manifest (D109).
func (s *Service) sigContext() records.SigContext { return records.ContextFor(s.NetworkPub, s.CurrentManifest()) }
```

  In `emitConsumed` replace `records.Sign(&pb.RecordBody{...}, s.NodeKeyPriv)` by
  `records.SignWith(&pb.RecordBody{...}, s.NodeKeyPriv, s.sigContext())`.

- [ ] **Step 7: Failing meshsim test** `internal/meshsim/sigv2_test.go`. Add a helper `signAsWith` next to `signAs`
  in `client_test.go` (read `signAs` at `client_test.go:145` and reuse its body with `records.SignWith` and an explicit
  `CreatedMs`), then:

```go
package meshsim

import (
	"context"
	"errors"
	"testing"
	"time"

	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/records"
	"ottermsg/server/internal/service"
)

func TestSigCutover(t *testing.T) {
	s := newSim(t, "a", "b")
	a, b := s.node("a"), s.node("b")
	anna, bob := s.register(a, "anna"), s.register(a, "bobby")
	eventually(t, "b knows both", func() bool { return b.knows(anna) && b.knows(bob) })
	before := time.Now().UnixMilli()
	old := s.signAsWith(anna, pb.RecordType_ACK, &pb.Ack{EnvelopeIds: [][]byte{make([]byte, 32)}, DeviceId: 1}, before, records.SigContext{})

	cut := time.Now().UnixMilli()
	infos := s.nodeInfos()
	m := &pb.Manifest{Version: 2, IssuedMs: cut, NetworkPub: s.netPub, Nodes: infos, SigV1UntilMs: cut}
	s.manifest = s.signWith(pb.RecordType_MANIFEST, keys.ID16(s.netPub), m, s.netPriv,
		records.SigContext{NetworkID: keys.ID16(s.netPub), V2: true})
	for _, n := range s.nodes {
		if _, err := n.svc.ImportRecord(context.Background(), s.manifest); err != nil {
			t.Fatal(err)
		}
	}

	late := s.signAsWith(anna, pb.RecordType_ACK, &pb.Ack{EnvelopeIds: [][]byte{make([]byte, 32)}, DeviceId: 1}, cut+1, records.SigContext{})
	c := s.login(a, anna)
	if st, _ := c.call("msg.ack", &pb.RecordRequest{Record: late}, &pb.Empty{}); st != pb.Status_STATUS_INVALID {
		t.Fatalf("v1 after cut-over from a client: %v", st)
	}
	// a hostile peer injects the same record into b
	if _, err := b.svc.ApplyReplicated(context.Background(), a.id, late); !errors.Is(err, service.ErrInvalid) {
		t.Fatalf("v1 after cut-over from a peer: %v", err)
	}
	if _, err := b.svc.ApplyReplicated(context.Background(), a.id, old); err != nil {
		t.Fatalf("v1 before cut-over refused: %v", err)
	}
	v2 := s.signAsWith(anna, pb.RecordType_ACK, &pb.Ack{EnvelopeIds: [][]byte{make([]byte, 32)}, DeviceId: 1}, cut+2,
		records.SigContext{NetworkID: keys.ID16(s.netPub), V2: true})
	c.mustCall("msg.ack", &pb.RecordRequest{Record: v2}, &pb.Empty{})
}
```

  `s.signWith` is `s.sign` (`harness_test.go:213`) with a `records.SigContext` argument and `records.SignWith`;
  make `s.sign` call it with `records.SigContext{}`.

- [ ] **Step 8: Run** `go test ./internal/meshsim/ -run SigCutover -count=1 -race` → PASS (the node code from Steps 4–6 is
  already in place; if it fails, the failure names the missing piece).

- [ ] **Step 9: Failing admin test** `internal/admin/sigctx_test.go`:

```go
package admin

import (
	"crypto/ed25519"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/records"
)

func TestManifestCutoverSignsV2AndIsMonotonic(t *testing.T) {
	dir := t.TempDir()
	pass := []byte("pw")
	if err := InitNetwork(dir, pass); err != nil {
		t.Fatal(err)
	}
	now := time.UnixMilli(1_800_000_000_000)
	v1rec, err := SignManifest(dir, pass, now)
	if err != nil {
		t.Fatal(err)
	}
	st, _ := LoadState(dir)
	if !ed25519.Verify(st.NetworkPub, v1rec.Body, v1rec.Signature) {
		t.Fatal("before the cut-over the manifest must be v1 (0.9.x phones)")
	}
	until := now.Add(48 * time.Hour).UnixMilli()
	if err := SetSigV1Until(dir, until); err != nil {
		t.Fatal(err)
	}
	rec, err := SignManifest(dir, pass, now)
	if err != nil {
		t.Fatal(err)
	}
	var body pb.RecordBody
	var m pb.Manifest
	proto.Unmarshal(rec.Body, &body)
	proto.Unmarshal(body.Payload, &m)
	if m.SigV1UntilMs != until {
		t.Fatalf("until = %d", m.SigV1UntilMs)
	}
	if !ed25519.Verify(st.NetworkPub, records.MessageV2(records.ContextFor(st.NetworkPub, nil).NetworkID, rec.Body), rec.Signature) {
		t.Fatal("cut-over manifest not v2")
	}
	if err := SetSigV1Until(dir, until-1); err == nil {
		t.Fatal("lowering accepted")
	}
	if err := SetSigV1Until(dir, 0); err == nil {
		t.Fatal("clearing accepted")
	}
}
```

- [ ] **Step 10: Run** → FAIL (`undefined: SetSigV1Until`).

- [ ] **Step 11: Implement** `internal/admin/sigctx.go`:

```go
package admin

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"ottermsg/server/internal/records"
)

const sigFile = "sig_v1_until_ms"

// SigV1Until is the cut-over time stored in DIR (0 = not set).
func SigV1Until(dir string) int64 {
	b, err := os.ReadFile(filepath.Join(dir, sigFile))
	if err != nil {
		return 0
	}
	v, _ := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	return v
}

// SetSigV1Until sets the v1 signature cut-over once (D110); it can never be lowered or cleared.
func SetSigV1Until(dir string, ms int64) error {
	cur := SigV1Until(dir)
	switch {
	case ms <= 0:
		return errors.New("--sig-v1-until must be a time")
	case cur != 0 && ms != cur:
		return fmt.Errorf("the cut-over is already set to %d ms and cannot change", cur)
	}
	return os.WriteFile(filepath.Join(dir, sigFile), []byte(fmt.Sprintf("%d\n", ms)), 0o644)
}

// adminSig: network, invite and news records are v2 once the cut-over is set.
func adminSig(st *State, dir string) records.SigContext {
	sc := records.ContextFor(st.NetworkPub, nil)
	sc.V2 = SigV1Until(dir) != 0
	return sc
}
```

  `SignManifest`: build `m` with `SigV1UntilMs: SigV1Until(dir)` and sign with
  `records.SignWith(..., priv, adminSig(st, dir))`. `BootstrapInvite`: `records.SignWith(..., priv, adminSig(st, dir))`.
  `signNews`: `records.SignWith(..., priv, adminSig(st, dir))` and give its check validator
  `V1Until: func() int64 { return SigV1Until(dir) }`.

  `cmd/otter-admin/main.go` `manifest sign`:

```go
	case "manifest sign":
		fs := flag.NewFlagSet("manifest sign", flag.ContinueOnError)
		cut := fs.String("sig-v1-until", "", "RFC 3339 time: v1 record signatures stop being valid for records created after it (D110, once)")
		if err := fs.Parse(a[2:]); err != nil {
			return err
		}
		if *cut != "" {
			t, err := time.Parse(time.RFC3339, *cut)
			if err != nil {
				return fmt.Errorf("--sig-v1-until: %w", err)
			}
			if err := admin.SetSigV1Until(*dir, t.UnixMilli()); err != nil {
				return err
			}
			fmt.Fprintf(out, "v1 signatures end at %s; this and every later manifest, invite and announcement is signed v2.\n", t.UTC().Format(time.RFC3339))
		}
		p, err := passphrase(in, false)
		// ... unchanged
```

  Usage line: `manifest sign [--sig-v1-until RFC3339]`. In `show`, print `sig_v1_until` when non-zero.

- [ ] **Step 12: Vectors.** In `vectors_test.go` add to `V1`:
  `ManifestV2RecordHex string \`json:"manifest_v2_record_hex"\`` and `DirectoryEntryV2RecordHex string \`json:"directory_entry_v2_record_hex"\``,
  produced like `mrec`/`drec` with `records.SignWith(..., records.SigContext{NetworkID: keys.ID16(netPub), V2: true})`.
  Run `OTTER_WRITE_VECTORS=1 go test ./internal/vectors/ -count=1`, then `go test ./internal/vectors/ -count=1` → `ok`.

- [ ] **Step 13: Run all** `go vet ./... && go test ./... -count=1 -race` → all `ok`.

- [ ] **Step 14: Commit.**

```bash
git add proto/otter/v1/manifest.proto internal/proto/otterv1/ internal/records/ internal/service/service.go internal/admin/ cmd/otter-admin/main.go internal/meshsim/ internal/vectors/ testdata/vectors/v1.json
oc -m "records: signature v2 bound to the network id, v1 only before the manifest cut-over (C7)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 51: Android — verify v2 everywhere, sign v2 after the cut-over (C7)

**Goal:** The app verifies v1/v2 like the node (D109) and signs every record v2 once its newest manifest carries a cut-over.

**Findings closed:** C7 (app side)

**Files:**
- Sync: `otter-android/core/proto/src/main/proto/otter/v1/manifest.proto`, `core/*/src/test/resources/vectors/v1.json` (`scripts/sync-proto.sh`)
- Create: `otter-android/core/crypto/src/main/kotlin/app/ottermsg/core/crypto/SigContext.kt`
- Modify: `core/crypto/.../RecordCodec.kt` (whole), `ManifestVerifier.kt:13-16`, `AnnouncementVerifier.kt:32-38`
- Modify: `core/data/.../sync/ManifestUpdater.kt` (implements new `SigContexts`), `core/data/.../account/AccountRepository.kt`, `LocalAccount.kt`, `di/DataModule.kt:64`
- Modify (signers → `me.sign(...)`): `push/PushRegistrar.kt:27`, `signal/PrekeyRefill.kt:38`, `media/BlobMetaBuilder.kt:18-31`, `media/MediaTransfers.kt:177`, `account/DirectoryEntries.kt:22-24`, `backup/InstallGuard.kt:51`, `messaging/Outbox.kt:141`, `messaging/GroupSender.kt:69`, `messaging/MailboxReceiver.kt:119`, `invite/InviteRepository.kt:43`, `backup/BackupManager.kt:102,117`, `registration/Registration.kt:101`
- Modify (verifiers): `directory/DirectorySync.kt:75-86`, `messaging/MailboxReceiver.kt:67`, `news/NewsRepository.kt:47`, `backup/RestoreManager.kt:80,160`, `backup/InstallGuard.kt:38`, `registration/Registration.kt:79`
- Modify tests: `core/data/src/test/.../TestGraph.kt:69,109`, `FakeNode.kt:63` (+ any test that builds `AccountRepository` or calls `RecordCodec.sign/verify` — `grep -rn "RecordCodec\.\(sign\|verify\)\|AccountRepository(" */*/src/test`)
- Test: `core/crypto/src/test/.../SigContextTest.kt` (new), `VectorsTest.kt`, `core/data/src/test/.../SigCutoverTest.kt` (new)

**Acceptance Criteria:**
- [ ] `RecordCodec.verify(record, pub, ctx)` accepts v2 for `ctx.networkId`, and v1 only when `ctx.v1UntilMs == 0` or `created_ms < ctx.v1UntilMs`; the 2-argument `verify` and `sign` no longer exist.
- [ ] Go vectors `manifest_v2_record_hex` and `directory_entry_v2_record_hex` verify in Kotlin.
- [ ] **Hostile (fake node):** a directory entry and an envelope v2-signed for another network are not accepted (no contact, envelope acked and dropped); after the cut-over a v1 envelope created after `sig_v1_until_ms` is dropped.
- [ ] Before any manifest with `sig_v1_until_ms != 0` the app signs v1; after storing one it signs v2 (checked on an outgoing envelope record captured by `FakeNode`).
- [ ] `./gradlew testDebugUnitTest` green.

**Verify:** `cd otter-android && ./gradlew :core:crypto:test :core:data:testDebugUnitTest --tests '*SigContext*' --tests '*Vectors*' --tests '*SigCutover*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Sync** `scripts/sync-proto.sh` (proto + vectors from the Task 50 server commit).

- [ ] **Step 2: Failing test** `core/crypto/src/test/kotlin/app/ottermsg/core/crypto/SigContextTest.kt`:

```kotlin
package app.ottermsg.core.crypto

import app.ottermsg.proto.v1.RecordType
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SigContextTest {
    private val user = Ed25519.keyPairFromSeed(ByteArray(32) { 1 })
    private val netA = Ids.id16(Ed25519.keyPairFromSeed(ByteArray(32) { 2 }).publicKey)
    private val netB = Ids.id16(Ed25519.keyPairFromSeed(ByteArray(32) { 3 }).publicKey)
    private fun body(created: Long) = RecordCodec.body(RecordType.ACK, Ids.id16(user.publicKey), byteArrayOf(1), createdMs = created)

    @Test fun v2IsBoundToTheNetwork() {
        val rec = RecordCodec.sign(body(10), user, SigContext(netA, v1UntilMs = 5))
        assertTrue(RecordCodec.verify(rec, user.publicKey, SigContext(netA, 5)))
        assertFalse(RecordCodec.verify(rec, user.publicKey, SigContext(netB, 5))) // hostile: replay into network B
    }

    @Test fun v1OnlyBeforeTheCutover() {
        val pre = SigContext(netA, 0)
        assertTrue(RecordCodec.verify(RecordCodec.sign(body(10), user, pre), user.publicKey, pre))
        val cut = SigContext(netA, 100)
        assertTrue(RecordCodec.verify(RecordCodec.sign(body(99), user, pre), user.publicKey, cut))
        assertFalse(RecordCodec.verify(RecordCodec.sign(body(100), user, pre), user.publicKey, cut))
    }
}
```

  and in `VectorsTest.kt`:

```kotlin
    @Test fun verifiesGoV2Records() {
        val ctx = SigContext(hex(v.getValue("network_id_hex")), v1UntilMs = 1L) // v1 not acceptable at created 1.8e12
        assertTrue(RecordCodec.verify(Record.parseFrom(hex(v.getValue("directory_entry_v2_record_hex"))), hex(v.getValue("account_pub_hex")), ctx))
        assertTrue(RecordCodec.verify(Record.parseFrom(hex(v.getValue("manifest_v2_record_hex"))), hex(v.getValue("network_pub_hex")), ctx))
        assertFalse(RecordCodec.verify(Record.parseFrom(hex(v.getValue("directory_entry_record_hex"))), hex(v.getValue("account_pub_hex")), ctx))
    }
```

  Update `verifiesGoRecords` to pass `SigContext(hex(v.getValue("network_id_hex")), 0)`.

- [ ] **Step 3: Run** `./gradlew :core:crypto:test` → FAIL (`Unresolved reference: SigContext`).

- [ ] **Step 4: Implement** `SigContext.kt`:

```kotlin
package app.ottermsg.core.crypto

import app.ottermsg.proto.v1.Manifest

/**
 * Record signature context (D109). [networkId] = ID16(network_pub). [v1UntilMs] = manifest.sig_v1_until_ms:
 * 0 → v1 signatures valid for every record and new records are signed v1; otherwise v1 is valid only for records
 * created before it and new records are signed v2.
 */
class SigContext(val networkId: ByteArray, val v1UntilMs: Long) {
    val signV2: Boolean get() = v1UntilMs != 0L

    companion object {
        fun of(networkPub: ByteArray, manifest: Manifest?) = SigContext(Ids.id16(networkPub), manifest?.sigV1UntilMs ?: 0L)
    }
}
```

  `RecordCodec.kt` — replace `sign`/`verify`:

```kotlin
    private val V2_PREFIX = "otter-v2\u0000".toByteArray(Charsets.US_ASCII)

    /** "otter-v2\0" ‖ network_id ‖ body (same as Go records.MessageV2). */
    fun messageV2(networkId: ByteArray, body: ByteArray): ByteArray = V2_PREFIX + networkId + body

    /** Signs the exact serialized body bytes: v2 when [ctx] says so, else v1 (same rule as the Go node). */
    fun sign(body: RecordBody, key: Ed25519.KeyPair, ctx: SigContext): Record {
        val bytes = body.toByteArray()
        val msg = if (ctx.signV2) messageV2(ctx.networkId, bytes) else bytes
        return Record.newBuilder().setBody(ByteString.copyFrom(bytes)).setSignature(ByteString.copyFrom(key.sign(msg))).build()
    }

    /** v2 for this network, or v1 for a record created before the cut-over (D109). */
    fun verify(record: Record, publicKey: ByteArray, ctx: SigContext): Boolean {
        if (record.signature.size() != 64) return false
        val bytes = record.body.toByteArray()
        val sig = record.signature.toByteArray()
        if (Ed25519.verify(publicKey, messageV2(ctx.networkId, bytes), sig)) return true
        val created = try { RecordBody.parseFrom(bytes).createdMs } catch (e: com.google.protobuf.InvalidProtocolBufferException) { return false }
        return (ctx.v1UntilMs == 0L || created < ctx.v1UntilMs) && Ed25519.verify(publicKey, bytes, sig)
    }
```

  `ManifestVerifier.verify(recordBytes, networkPub, currentVersion, v1UntilMs: Long)`: use
  `RecordCodec.verify(rec, networkPub, SigContext(Ids.id16(networkPub), v1UntilMs))`.
  `AnnouncementVerifier.verify(record, newsKeys, ctx: SigContext)` → `RecordCodec.verify(record, pub, ctx)`.

- [ ] **Step 5: Run** `./gradlew :core:crypto:test` → PASS.

- [ ] **Step 6: The app's context.** In `ManifestUpdater.kt` add next to `NewsKeys`:

```kotlin
/** Signature context from the newest stored manifest (D109). */
interface SigContexts {
    suspend fun sigContext(): SigContext
}
```

  `ManifestUpdater` implements it (it already holds `manifests` and `settings`):

```kotlin
    override suspend fun sigContext(): SigContext {
        val latest = manifests.latest()
        val m = latest?.let { runCatching { Manifest.parseFrom(RecordBody.parseFrom(Record.parseFrom(it.raw).body).payload) }.getOrNull() }
        return SigContext.of(settings.networkPub(), m)
    }
```

  and in `offer` pass the stored manifest's cut-over: `ManifestVerifier.verify(raw, settings.networkPub(), current, sigContext().v1UntilMs)`
  (a cut-over manifest is v2-signed, which is always accepted). In `candidates` (`:79`) pass `0`
  (stored manifests were verified on insert).

  `LocalAccount` gets the signer (constructor param `private val sig: SigContexts`, copied in `copyWith`):

```kotlin
    /** Signs one of our records under the current network context (D109). */
    suspend fun sign(body: RecordBody): Record = RecordCodec.sign(body, accountKey, sig.sigContext())
```

  `AccountRepository @Inject constructor(accountDao, settings, vault, private val sig: SigContexts)` passes `sig`
  into `LocalAccount` in `build`. `DataModule`: `@Provides fun sigContexts(m: ManifestUpdater): SigContexts = m`
  (like `newsKeys`, `DataModule.kt:64`).

- [ ] **Step 7: Signers.** Replace every `RecordCodec.sign(<body>, me.accountKey)` with `me.sign(<body>)` at the
  call sites listed in Files (`BlobMetaBuilder.build/resign` and `DirectoryEntries.record` become `suspend`; their
  callers in `MessageRepository.kt:152,196,217` and `ProfileRepository.kt:82` are already in coroutines).
  `Registration.kt:101` (no account yet): `RecordCodec.sign(..., account, SigContext.of(networkPub, manifest))` with
  the invite bundle's verified manifest; `Registration.kt:79`, `RestoreManager.kt:80,160`, `InstallGuard.kt:38`:
  `ManifestVerifier.verify(..., 0)` (a first manifest or a stored one).

- [ ] **Step 8: Verifiers.** `DirectorySync.verify` becomes `suspend` and uses
  `RecordCodec.verify(rec, accountPub, sig.sigContext())` (new constructor param `sig: SigContexts`);
  `MailboxReceiver.kt:67`: `RecordCodec.verify(rec, sender.accountPub, ctx)` with `val ctx = sigs.sigContext()`
  taken once per `handle` (new constructor param `sigs: SigContexts`); `NewsRepository.kt:47`:
  `AnnouncementVerifier.verify(r, newsKeys, sigs.sigContext())` (constructor param). Update `TestGraph`
  construction order: build `manifests` (`ManifestUpdater`) before `accounts`, pass it as `SigContexts`
  everywhere. `FakeNode.signManifest` gets `sigV1UntilMs: Long = 0` and signs with
  `SigContext(Ids.id16(network.publicKey), sigV1UntilMs)`; other FakeNode signers use the same context.

- [ ] **Step 9: Failing data test** `core/data/src/test/kotlin/app/ottermsg/core/data/SigCutoverTest.kt`:

```kotlin
package app.ottermsg.core.data

import app.ottermsg.core.crypto.Ed25519
import app.ottermsg.core.crypto.Ids
import app.ottermsg.core.crypto.RecordCodec
import app.ottermsg.core.crypto.SigContext
import app.ottermsg.proto.v1.Record
import app.ottermsg.proto.v1.RecordBody
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class SigCutoverTest {
    private val clock = TestClock()
    private val node = FakeNode(clock::now)
    private val g = TestGraph(node, clock)
    @After fun tearDown() = g.close()

    private fun isV2(rec: Record, ctx: SigContext, pub: ByteArray) =
        Ed25519.verify(pub, RecordCodec.messageV2(ctx.networkId, rec.body.toByteArray()), rec.signature.toByteArray())

    @Test fun signsV1UntilTheCutoverThenV2() = runBlocking {
        g.register(node.bootstrapLink(), "Я", "me_user").getOrThrow()
        val pre = g.me.sign(RecordCodec.body(app.ottermsg.proto.v1.RecordType.ACK, g.me.userId, byteArrayOf(1)))
        val netId = Ids.id16(node.network.publicKey)
        assertFalse(isV2(pre, SigContext(netId, 0), g.me.accountKey.publicKey))
        g.manifests.offer(node.signManifest(2, sigV1UntilMs = clock.now() + 1000).toByteArray(), null)
        val post = g.me.sign(RecordCodec.body(app.ottermsg.proto.v1.RecordType.ACK, g.me.userId, byteArrayOf(1)))
        assertTrue(isV2(post, SigContext(netId, 1), g.me.accountKey.publicKey))
    }

    @Test fun foreignNetworkEntryIsNotAContact() = runBlocking {
        g.register(node.bootstrapLink(), "Я", "me_user").getOrThrow()
        val foreign = node.directoryEntryFor(seed = 7, name = "anna", ctx = SigContext(ByteArray(16) { 0x77 }, 1))
        g.directory.apply(listOf(foreign))
        assertNull(g.db.contactDao().get(RecordBody.parseFrom(foreign.body).author.toByteArray()))
    }
}
```

  Add `FakeNode.directoryEntryFor(seed: Byte, name: String, ctx: SigContext): Record` (builds a bound entry like
  `DirectorySyncTest.entry` and signs with `ctx`). For the envelope case, extend `MessagingFlowTest` with one test:
  `node.injectEnvelope(record)` of an envelope from a known contact signed with a foreign `SigContext` → after
  `g.receiver.handle(...)` no message row exists and the envelope key is in the next ACK (read the existing
  `MessagingFlowTest` helpers first and reuse their names).

- [ ] **Step 10: Run** `./gradlew :core:data:testDebugUnitTest --tests '*SigCutover*'` → FAIL before Steps 6–8 are
  complete, PASS after; then `./gradlew testDebugUnitTest` → `BUILD SUCCESSFUL`.

- [ ] **Step 11: Commit.**

```bash
git add core/proto core/crypto core/data core/network/src/test/resources core/signal/src/test/resources
oc -m "app: verify v1/v2 record signatures, sign v2 after the manifest cut-over (C7)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 52: Server — `REKEY` record: revoke, hand over the username, publish, serve in the directory (limit 2)

**Goal:** A network-signed `REKEY{old, new}` revokes `old` and moves its username and clash rank to `new` on every
node in any arrival order; a revoked owner's name can be registered (as `name#abcd`) until the REKEY arrives.

**Findings closed:** design limit 2 (server)

**Files:**
- Modify: `otter-server/proto/otter/v1/records.proto` (enum + `message Rekey`), regenerate
- Modify: `otter-server/internal/records/validate.go:72-74` (`networkAuthored`), `:155-226` (`checkPayload`)
- Create: `otter-server/internal/store/migrations/0015_rekeys.sql` (use the next free number after M9.0–M9.2's migrations; `ls internal/store/migrations`)
- Modify: `otter-server/internal/store/typed.go:32` (`applyTyped`), `:364-409` (`applyDirectoryEntry`), new `internal/store/rekey.go`
- Modify: `otter-server/internal/store/query.go` (new `Rekeys`), `internal/service/service.go:217-231` (`Directory`), `internal/service/replicated.go:50-77` (`afterApply`), new `internal/service/admin.go`, `internal/service/register.go:51-56`
- Modify: `otter-server/internal/gateway/methods.go:13-14` (`public`), dispatch
- Test: `internal/records/validate_test.go` (cases), `internal/store/rekey_test.go` (new), `internal/meshsim/rekey_test.go` (new)

**Acceptance Criteria:**
- [ ] REKEY must be authored and signed by the network key; `old`, `new` are 16 bytes and differ; `expires_ms = 0`.
- [ ] **Hostile:** a REKEY signed by the old account's key (the thief) or by a node key is rejected (`ErrBadAuthor`/`ErrBadSignature`) through `network.publish` and through `ApplyReplicated`; the username does not move.
- [ ] `Register` with the username of a **revoked** user succeeds; the new user's row is `name#<hex4>` (`username_conflict=1`); with a non-revoked owner it is still `CONFLICT`.
- [ ] After REKEY (either order: REKEY before or after the new entry, and replicated in either order) `UsernameOwner(name)` = new, old is `revoked` and named `name#<hex4(old)>`, new's `entry_created_ms` = min(own, old's).
- [ ] A later version of old's entry never takes the name back; two REKEYs for the same old: the later `created_ms` wins on every node.
- [ ] `directory.sync` returns the current REKEY records after the directory entries; the `directory` event fires on REKEY.

**Verify:** `cd otter-server && go test ./internal/records/ ./internal/store/ ./internal/meshsim/ -run 'Validate|Rekey' -count=1 -race` → `ok` ×3

**Steps:**

- [ ] **Step 1: Proto** (`records.proto`): add `REKEY = 18;` to `RecordType` (after M9.1's `INSTALL = 17`) and

```proto
// REKEY payload (M9.3, D111): signed by the network key. old_user_id is revoked; new_user_id takes over its username
// and clash rank, and contacts move their chats to it.
message Rekey {
  bytes old_user_id = 1;
  bytes new_user_id = 2;
}
```

  `make gen`.

- [ ] **Step 2: Failing validator cases** — add to the `cases` table in `TestValidate` (`validate_test.go`), using
  its `netPriv`, `netID`, `userPriv`, `userID`, `newPub`:

```go
		{"rekey ok", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_REKEY, Author: netID,
				Payload: payload(&pb.Rekey{OldUserId: userID, NewUserId: keys.ID16(newPub)})}, netPriv)
		}, nil},
		{"rekey by the old account (thief)", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_REKEY, Author: userID,
				Payload: payload(&pb.Rekey{OldUserId: userID, NewUserId: keys.ID16(newPub)})}, userPriv)
		}, ErrBadAuthor},
		{"rekey network author, user signature", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_REKEY, Author: netID,
				Payload: payload(&pb.Rekey{OldUserId: userID, NewUserId: keys.ID16(newPub)})}, userPriv)
		}, ErrBadSignature},
		{"rekey to itself", func() *pb.Record {
			return mustSign(t, &pb.RecordBody{Id: rid(), Type: pb.RecordType_REKEY, Author: netID,
				Payload: payload(&pb.Rekey{OldUserId: userID, NewUserId: userID})}, netPriv)
		}, ErrBadPayload},
```

  Run `go test ./internal/records/ -run TestValidate -count=1` → FAIL ("rekey by the old account" passes as a user record).

- [ ] **Step 3: Implement** in `validate.go`:

```go
func networkAuthored(t pb.RecordType) bool {
	return t == pb.RecordType_MANIFEST || t == pb.RecordType_REVOCATION || t == pb.RecordType_INVITE_RIGHTS ||
		t == pb.RecordType_REKEY
}
```

  and in `checkPayload`:

```go
	case pb.RecordType_REKEY:
		var k pb.Rekey
		if err := proto.Unmarshal(b.Payload, &k); err != nil || len(k.OldUserId) != 16 || len(k.NewUserId) != 16 ||
			bytes.Equal(k.OldUserId, k.NewUserId) || b.ExpiresMs != 0 {
			return ErrBadPayload
		}
```

  Run → PASS.

- [ ] **Step 4: Migration** `internal/store/migrations/0015_rekeys.sql`:

```sql
-- M9.3 (D111): lost-phone re-keys. One row per replaced account; the later REKEY wins.
CREATE TABLE rekeys(old_user_id BLOB PRIMARY KEY, new_user_id BLOB NOT NULL, record_key BLOB NOT NULL,
                    created_ms INTEGER NOT NULL);
CREATE INDEX rekeys_new ON rekeys(new_user_id);
```

- [ ] **Step 5: Failing store test** `internal/store/rekey_test.go`:

```go
package store

import (
	"context"
	"testing"

	pb "ottermsg/server/internal/proto/otterv1"
)

func rekeyItem(t *testing.T, old, nw []byte, created int64) Item {
	return mkItemAt(t, pb.RecordType_REKEY, r16(), &pb.Rekey{OldUserId: old, NewUserId: nw}, created)
}

func nameOf(t *testing.T, s *Store, id []byte) (string, bool) {
	u, err := s.UserByID(context.Background(), id)
	if err != nil || u == nil {
		t.Fatalf("user %x: %v", id, err)
	}
	return u.Username, u.Revoked
}

func TestRekeyNewRegistersFirst(t *testing.T) {
	s, _ := open(t)
	old, nw := r16(), r16()
	if err := apply(t, s, mkItemAt(t, pb.RecordType_DIRECTORY_ENTRY, old, entry(old, "anna", 1), 1000)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.w.Exec(`UPDATE users SET revoked=1 WHERE user_id=?`, old); err != nil { // M9.2 REVOCATION
		t.Fatal(err)
	}
	if err := apply(t, s, mkItemAt(t, pb.RecordType_DIRECTORY_ENTRY, nw, entry(nw, "anna", 1), 5000)); err != nil {
		t.Fatalf("a revoked owner's name must be registrable: %v", err)
	}
	if n, _ := nameOf(t, s, nw); n != conflictName("anna", nw) {
		t.Fatalf("before REKEY new = %q", n)
	}
	if err := apply(t, s, rekeyItem(t, old, nw, 6000)); err != nil {
		t.Fatal(err)
	}
	if n, _ := nameOf(t, s, nw); n != "anna" {
		t.Fatalf("after REKEY new = %q", n)
	}
	if n, rev := nameOf(t, s, old); n != conflictName("anna", old) || !rev {
		t.Fatalf("old = %q revoked=%v", n, rev)
	}
	// old's late entry (a thief editing the profile) never takes the name back
	replicate(t, s, mkItemAt(t, pb.RecordType_DIRECTORY_ENTRY, old, entry(old, "anna", 2), 7000))
	if n, _ := nameOf(t, s, nw); n != "anna" {
		t.Fatalf("old reclaimed the name: new = %q", n)
	}
}

func TestRekeyBeforeNewEntryAndRankInherited(t *testing.T) {
	s, _ := open(t)
	old, nw, other := r16(), r16(), r16()
	replicate(t, s, mkItemAt(t, pb.RecordType_DIRECTORY_ENTRY, old, entry(old, "anna", 1), 1000))
	replicate(t, s, rekeyItem(t, old, nw, 6000))
	// a third account registered between old and new must not win the name
	replicate(t, s, mkItemAt(t, pb.RecordType_DIRECTORY_ENTRY, other, entry(other, "anna", 1), 3000))
	replicate(t, s, mkItemAt(t, pb.RecordType_DIRECTORY_ENTRY, nw, entry(nw, "anna", 1), 5000))
	if n, _ := nameOf(t, s, nw); n != "anna" {
		t.Fatalf("new = %q, want the inherited rank to win", n)
	}
	if n, _ := nameOf(t, s, other); n != conflictName("anna", other) {
		t.Fatalf("other = %q", n)
	}
	recs, _ := s.Rekeys(context.Background())
	if len(recs) != 1 {
		t.Fatalf("rekeys = %d", len(recs))
	}
}
```

  (`mkItemAt` is in `mesh_test.go:17`; `s.w` is the store's write handle — check its name in `store.go` and use the
  one the other tests use for direct SQL, or apply a REVOCATION item if M9.2 already handles it.)
  Run → FAIL.

- [ ] **Step 6: Implement** `internal/store/rekey.go`:

```go
package store

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"strings"
)

// applyRekey (D111): the later REKEY per old account wins; old is revoked and gives its name and rank to new.
func applyRekey(ctx context.Context, tx *sql.Tx, key, old, nw []byte, created int64) error {
	if _, err := tx.ExecContext(ctx, `INSERT INTO rekeys(old_user_id,new_user_id,record_key,created_ms) VALUES(?,?,?,?)
		ON CONFLICT(old_user_id) DO UPDATE SET new_user_id=excluded.new_user_id, record_key=excluded.record_key,
		  created_ms=excluded.created_ms
		WHERE excluded.created_ms > rekeys.created_ms OR
		  (excluded.created_ms = rekeys.created_ms AND excluded.record_key < rekeys.record_key)`, old, nw, key, created); err != nil {
		return err
	}
	var cur []byte
	if err := tx.QueryRowContext(ctx, `SELECT new_user_id FROM rekeys WHERE old_user_id=?`, old).Scan(&cur); err != nil {
		return err
	}
	if !bytes.Equal(cur, nw) {
		return nil // a later REKEY of the same account already won; this record is kept but has no effect
	}
	if _, err := tx.ExecContext(ctx, `UPDATE users SET revoked=1 WHERE user_id=?`, old); err != nil {
		return err
	}
	return handOverName(ctx, tx, old, nw)
}

func baseName(n string) string { return strings.SplitN(n, "#", 2)[0] }

// handOverName moves old's username to nw once both rows exist; nw inherits old's clash rank.
func handOverName(ctx context.Context, tx *sql.Tx, old, nw []byte) error {
	var oldName string
	var oldConflict int
	var oldRank int64
	err := tx.QueryRowContext(ctx, `SELECT username, username_conflict, entry_created_ms FROM users WHERE user_id=?`, old).
		Scan(&oldName, &oldConflict, &oldRank)
	if errors.Is(err, sql.ErrNoRows) {
		return nil // old's entry arrives later: applyDirectoryEntry marks it a loser
	}
	if err != nil {
		return err
	}
	base := baseName(oldName)
	if oldConflict == 0 {
		if _, err := tx.ExecContext(ctx, `UPDATE users SET username=?, username_conflict=1 WHERE user_id=?`,
			conflictName(base, old), old); err != nil {
			return err
		}
	}
	var newName string
	var newRank int64
	err = tx.QueryRowContext(ctx, `SELECT username, entry_created_ms FROM users WHERE user_id=?`, nw).Scan(&newName, &newRank)
	if errors.Is(err, sql.ErrNoRows) {
		return nil // nw's entry arrives later and inherits the rank there
	}
	if err != nil {
		return err
	}
	if baseName(newName) != base {
		return nil // registered under another name: contacts still map old → new
	}
	rank := min(newRank, oldRank)
	var holder []byte
	var holderRank int64
	err = tx.QueryRowContext(ctx, `SELECT user_id, entry_created_ms FROM users WHERE username=?`, base).Scan(&holder, &holderRank)
	switch {
	case errors.Is(err, sql.ErrNoRows), err == nil && bytes.Equal(holder, nw):
	case err != nil:
		return err
	case wins(rank, nw, holderRank, holder):
		if _, err := tx.ExecContext(ctx, `UPDATE users SET username=?, username_conflict=1 WHERE user_id=?`,
			conflictName(base, holder), holder); err != nil {
			return err
		}
	default:
		_, err := tx.ExecContext(ctx, `UPDATE users SET entry_created_ms=? WHERE user_id=?`, rank, nw)
		return err
	}
	_, err = tx.ExecContext(ctx, `UPDATE users SET username=?, username_conflict=0, entry_created_ms=? WHERE user_id=?`, base, rank, nw)
	return err
}

// inheritedRank is the clash rank of the account user replaced (D111), if any.
func inheritedRank(ctx context.Context, tx *sql.Tx, user []byte) (int64, bool, error) {
	var r int64
	err := tx.QueryRowContext(ctx, `SELECT u.entry_created_ms FROM rekeys k JOIN users u ON u.user_id=k.old_user_id
		WHERE k.new_user_id=?`, user).Scan(&r)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, false, nil
	}
	return r, err == nil, err
}

// rekeyedAway: user was replaced by a REKEY and never holds a name again.
func rekeyedAway(ctx context.Context, tx *sql.Tx, user []byte) (bool, error) {
	var x int
	err := tx.QueryRowContext(ctx, `SELECT 1 FROM rekeys WHERE old_user_id=?`, user).Scan(&x)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// Rekeys returns the winning REKEY records (directory.sync).
func (s *Store) Rekeys(ctx context.Context) ([][]byte, error) {
	rows, err := s.r.QueryContext(ctx, `SELECT r.raw FROM rekeys k JOIN records r ON r.record_key=k.record_key ORDER BY k.created_ms`)
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
```

  In `applyTyped` add:

```go
	case pb.RecordType_REKEY:
		var k pb.Rekey
		if err := proto.Unmarshal(b.Payload, &k); err != nil {
			return err
		}
		return applyRekey(ctx, tx, it.key, k.OldUserId, k.NewUserId, b.CreatedMs)
```

  In `applyDirectoryEntry` (after M9.2's rank computation; today `typed.go:368-371`):

```go
	if r, ok, err := inheritedRank(ctx, tx, e.UserId); err != nil {
		return err
	} else if ok && r < rank {
		rank = r // D111: the re-keyed account keeps the replaced account's place
	}
	away, err := rekeyedAway(ctx, tx, e.UserId)
	if err != nil {
		return err
	}
```

  and replace the owner lookup and `switch` (`typed.go:385-401`) with:

```go
	var owner []byte
	var ownerCreated int64
	var ownerRevoked int
	err = tx.QueryRowContext(ctx, `SELECT user_id, entry_created_ms, revoked FROM users WHERE username=?`, e.Username).
		Scan(&owner, &ownerCreated, &ownerRevoked)
	switch {
	case err != nil && !errors.Is(err, sql.ErrNoRows):
		return err
	case away:
		name, conflict = conflictName(e.Username, e.UserId), 1
	case errors.Is(err, sql.ErrNoRows) || bytes.Equal(owner, e.UserId):
	case !it.fromPeer && !lostBefore && ownerRevoked == 0:
		return ErrUsernameTaken
	case wins(rank, e.UserId, ownerCreated, owner):
		if _, err := tx.ExecContext(ctx, `UPDATE users SET username=?, username_conflict=1 WHERE user_id=?`,
			conflictName(e.Username, owner), owner); err != nil {
			return err
		}
	default:
		name, conflict = conflictName(e.Username, e.UserId), 1
	}
```

  Run `go test ./internal/store/ -count=1 -race` → PASS.

- [ ] **Step 7: Service.** `register.go:51-56` — let a revoked owner's name through:

```go
	if owner, err := s.Store.UsernameOwner(ctx, e.Username); err != nil {
		return nil, err
	} else if owner != nil {
		if u, err := s.Store.UserByID(ctx, owner); err != nil {
			return nil, err
		} else if u == nil || !u.Revoked {
			return nil, fmt.Errorf("%w: username taken", ErrConflict)
		} // revoked owner (lost phone, D111): the new account starts as name#abcd until the admin's REKEY
	}
```

  New `internal/service/admin.go`:

```go
package service

import (
	"bytes"
	"context"
	"fmt"

	pb "ottermsg/server/internal/proto/otterv1"
)

// PublishAdmin accepts a network-signed membership record from otter-admin (network.publish, D111).
func (s *Service) PublishAdmin(ctx context.Context, rec *pb.Record) error {
	body, err := s.validator(nil).Validate(rec)
	if err != nil {
		return invalid(err)
	}
	switch {
	case body.Type == pb.RecordType_REKEY, body.Type == pb.RecordType_REVOCATION, body.Type == pb.RecordType_INVITE_RIGHTS:
	case body.Type == pb.RecordType_INVITE && bytes.Equal(body.Author, s.networkID()):
	default:
		return fmt.Errorf("%w: %v is not an admin record", ErrInvalid, body.Type)
	}
	_, applied, err := s.Store.ApplyFrom(ctx, rec, body, s.NodeID)
	if err != nil {
		return err
	}
	if !applied {
		return fmt.Errorf("%w: already stored", ErrConflict)
	}
	s.afterApply(ctx, body, nil)
	return nil
}
```

  `afterApply`: `case pb.RecordType_REKEY:` → call M9.2's "end a revoked user's sessions" helper (the one its
  REVOCATION case calls) with the payload's `OldUserId`, then `s.Notify.Directory()`.
  `Directory`: after the entries, append `s.Store.Rekeys(ctx)` records (same unmarshal loop).
  Gateway: add `"network.publish": true` to `public` and

```go
	case "network.publish":
		var r pb.RecordRequest
		if err := decode(req.Body, &r); err != nil {
			return nil, err
		}
		if r.Record == nil {
			return nil, fmt.Errorf("%w: record missing", service.ErrInvalid)
		}
		return &pb.Empty{}, svc.PublishAdmin(ctx, r.Record)
```

- [ ] **Step 8: Failing meshsim test** `internal/meshsim/rekey_test.go`:

```go
package meshsim

import (
	"context"
	"crypto/ed25519"
	"errors"
	"testing"

	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/service"
)

func (s *sim) adminPublish(n *simNode, rec *pb.Record) pb.Status {
	c := s.dial(n)
	defer c.close()
	st, _ := c.call("network.publish", &pb.RecordRequest{Record: rec}, &pb.Empty{})
	return st
}

func (n *simNode) owner(name string) []byte {
	id, _ := n.st.UsernameOwner(context.Background(), name)
	return id
}

func TestRekeyMovesUsernameEverywhere(t *testing.T) {
	s := newSim(t, "a", "b")
	a, b := s.node("a"), s.node("b")
	old := s.register(a, "anna")
	eventually(t, "b knows anna", func() bool { return b.knows(old) })
	netID := keys.ID16(s.netPub)

	// hostile: the thief holds old's key and signs a REKEY to an account of its own
	_, thiefPriv, _ := ed25519.GenerateKey(nil)
	thiefPub := thiefPriv.Public().(ed25519.PublicKey)
	forged := s.sign(pb.RecordType_REKEY, old.id, &pb.Rekey{OldUserId: old.id, NewUserId: keys.ID16(thiefPub)}, old.priv)
	if st := s.adminPublish(a, forged); st != pb.Status_STATUS_INVALID {
		t.Fatalf("forged REKEY via network.publish: %v", st)
	}
	// hostile: a node signs a REKEY and injects it through replication
	nodeSigned := s.sign(pb.RecordType_REKEY, netID, &pb.Rekey{OldUserId: old.id, NewUserId: keys.ID16(thiefPub)}, a.key)
	if _, err := b.svc.ApplyReplicated(context.Background(), a.id, nodeSigned); !errors.Is(err, service.ErrInvalid) {
		t.Fatalf("node-signed REKEY replicated: %v", err)
	}

	// step 1: the admin revokes old (M9.2) — then the person registers again with the same name on b
	s.adminPublish(a, s.sign(pb.RecordType_REVOCATION, netID, &pb.Revocation{UserId: old.id, Reason: "rekey"}, s.netPriv))
	eventually(t, "old revoked on b", func() bool { u, _ := b.st.UserByID(context.Background(), old.id); return u != nil && u.Revoked })
	nw := s.register(b, "anna")
	eventually(t, "a knows new", func() bool { return a.knows(nw) })
	if string(a.owner("anna")) != string(old.id) {
		t.Fatal("before REKEY the name stays with old")
	}
	// step 2: REKEY
	if st := s.adminPublish(a, s.sign(pb.RecordType_REKEY, netID, &pb.Rekey{OldUserId: old.id, NewUserId: nw.id}, s.netPriv)); st != pb.Status_STATUS_OK {
		t.Fatalf("REKEY: %v", st)
	}
	for _, n := range []*simNode{a, b} {
		eventually(t, n.label+": anna is the new account", func() bool { return string(n.owner("anna")) == string(nw.id) })
	}
	c := s.login(b, nw)
	var batch pb.RecordBatch
	c.mustCall("directory.sync", &pb.Empty{}, &batch)
	found := false
	for _, r := range batch.Records {
		var body pb.RecordBody
		if proto.Unmarshal(r.Body, &body) == nil && body.Type == pb.RecordType_REKEY {
			found = true
		}
	}
	if !found {
		t.Fatal("directory.sync without the REKEY")
	}
}
```

  (Add `"google.golang.org/protobuf/proto"` to the imports. Confirm `register` fails for a non-revoked owner by
  the existing `TestUsernameTaken`-style test; if none exists add `c.call("register", …)` → `STATUS_CONFLICT` here.)
  Run `go test ./internal/meshsim/ -run Rekey -count=1 -race` → PASS after Steps 3–7 (FAIL on `network.publish`
  unknown method before Step 7).

- [ ] **Step 9: Run all** `go vet ./... && go test ./... -count=1 -race` → all `ok`.

- [ ] **Step 10: Commit.**

```bash
git add proto/otter/v1/records.proto internal/proto/otterv1/ internal/records/ internal/store/ internal/service/ internal/gateway/methods.go internal/meshsim/rekey_test.go
oc -m "node: REKEY revokes a lost account and hands its username to the new one (limit 2)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 53: Admin CLI — `otter-admin user rekey` (limit 2)

**Goal:** The owner re-keys a lost phone in two commands: revoke + invite, then REKEY with the code the person reads
from the new phone.

**Findings closed:** design limit 2 (admin)

**Files:**
- Create: `otter-server/internal/admin/rekey.go`, `internal/admin/rekey_test.go`
- Modify: `otter-server/cmd/otter-admin/main.go` (usage `:30-56`, `run` switch, new `publishAdmin` next to `publishNews` `:513-549`), `cmd/otter-admin/main_test.go`

**Acceptance Criteria:**
- [ ] `user rekey <username> --old <32 hex>`: signs `REVOCATION{old, "rekey"}` and a network `INVITE` (ttl 7 days), publishes both with `network.publish` to every node (`--via` to choose), prints the invite link and QR, writes `DIR/rekeys/<username>.json` `{old, invite_id, started_ms}` (0600).
- [ ] `user rekey <username> --new <32 hex>`: requires that file, refuses `new == old` or a malformed code, signs `REKEY{old, new}`, publishes it, renames the file to `<username>.done.json`.
- [ ] Records are v1 or v2 by the cut-over state (Task 50 `adminSig`).
- [ ] At least one node took each record, else the command fails and nothing is marked done.

**Verify:** `cd otter-server && go test ./internal/admin/ ./cmd/otter-admin/ -run Rekey -count=1` → `ok` ×2

**Steps:**

- [ ] **Step 1: Failing test** `internal/admin/rekey_test.go`:

```go
package admin

import (
	"bytes"
	"encoding/hex"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"
	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/records"
)

func TestRekeyTwoSteps(t *testing.T) {
	dir := t.TempDir()
	pass := []byte("pw")
	if err := InitNetwork(dir, pass); err != nil {
		t.Fatal(err)
	}
	if _, err := SignManifest(dir, pass, time.Now()); err != nil {
		t.Fatal(err)
	}
	st, _ := LoadState(dir)
	old := bytes.Repeat([]byte{1}, 16)
	start, err := RekeyStart(dir, pass, "anna", old, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	v := &records.Validator{NetworkPub: st.NetworkPub, Users: noUsersT{}, Now: time.Now}
	for _, r := range []*pb.Record{start.Revocation, start.Invite} {
		if _, err := v.Validate(r); err != nil {
			t.Fatalf("start record invalid: %v", err)
		}
	}
	if _, err := RekeyFinish(dir, pass, "anna", old, time.Now()); err == nil {
		t.Fatal("new == old accepted")
	}
	nw := bytes.Repeat([]byte{2}, 16)
	rec, err := RekeyFinish(dir, pass, "anna", nw, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	body, err := v.Validate(rec)
	if err != nil || body.Type != pb.RecordType_REKEY || !bytes.Equal(body.Author, keys.ID16(st.NetworkPub)) {
		t.Fatalf("rekey %v %v", body, err)
	}
	var k pb.Rekey
	proto.Unmarshal(body.Payload, &k)
	if !bytes.Equal(k.OldUserId, old) || !bytes.Equal(k.NewUserId, nw) {
		t.Fatalf("payload %x→%x", k.OldUserId, k.NewUserId)
	}
	if _, err := ParseUserCode("0102 0304 0506 0708 090a 0b0c 0d0e 0f10"); err != nil {
		t.Fatal(err)
	}
	if _, err := ParseUserCode(hex.EncodeToString(nw)[:30]); err == nil {
		t.Fatal("short code accepted")
	}
}

type noUsersT struct{}

func (noUsersT) UserKey([]byte) (records.UserKey, bool) { return records.UserKey{}, false }
```

  Run → FAIL (`undefined: RekeyStart`).

- [ ] **Step 2: Implement** `internal/admin/rekey.go`:

```go
package admin

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"google.golang.org/protobuf/proto"
	"ottermsg/server/internal/keys"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/records"
)

var usernameRe = regexp.MustCompile(`^[a-z0-9_]{3,32}$`)

type rekeyState struct {
	Old       string `json:"old"`
	InviteID  string `json:"invite_id"`
	StartedMs int64  `json:"started_ms"`
}

// RekeyStartResult: the records to publish and the invite link for the new install.
type RekeyStartResult struct {
	Revocation, Invite *pb.Record
	Link               string
}

// ParseUserCode reads «Код аккаунта» as shown by the app: 32 hex digits, spaces allowed.
func ParseUserCode(s string) ([]byte, error) {
	b, err := hex.DecodeString(strings.ReplaceAll(strings.TrimSpace(s), " ", ""))
	if err != nil || len(b) != 16 {
		return nil, errors.New("the account code is 32 hex digits")
	}
	return b, nil
}

func rekeyFile(dir, username string) string { return filepath.Join(dir, "rekeys", username+".json") }

func signNetwork(dir string, pass []byte, typ pb.RecordType, payload proto.Message, now time.Time, expires int64) (*pb.Record, error) {
	st, err := LoadState(dir)
	if err != nil {
		return nil, err
	}
	priv, err := keys.ReadEncryptedKey(filepath.Join(dir, "network.key.enc"), pass)
	if err != nil {
		return nil, err
	}
	p, err := proto.MarshalOptions{Deterministic: true}.Marshal(payload)
	if err != nil {
		return nil, err
	}
	id := make([]byte, 16)
	rand.Read(id)
	return records.SignWith(&pb.RecordBody{Id: id, Type: typ, Author: keys.ID16(st.NetworkPub), CreatedMs: now.UnixMilli(),
		ExpiresMs: expires, Payload: p}, priv, adminSig(st, dir))
}

// RekeyStart (D111 step 1): revoke the lost account and invite its owner's new install.
func RekeyStart(dir string, pass []byte, username string, old []byte, now time.Time) (*RekeyStartResult, error) {
	if !usernameRe.MatchString(username) || len(old) != 16 {
		return nil, errors.New("usage: user rekey <username> --old <account code>")
	}
	rev, err := signNetwork(dir, pass, pb.RecordType_REVOCATION, &pb.Revocation{UserId: old, Reason: "rekey"}, now, 0)
	if err != nil {
		return nil, err
	}
	st, _ := LoadState(dir)
	mraw, err := os.ReadFile(filepath.Join(dir, "manifest.bin"))
	if err != nil {
		return nil, fmt.Errorf("no signed manifest: %w", err)
	}
	var manifest pb.Record
	if err := proto.Unmarshal(mraw, &manifest); err != nil {
		return nil, err
	}
	secret := make([]byte, 32)
	rand.Read(secret)
	sum := sha256.Sum256(secret)
	exp := now.Add(7 * 24 * time.Hour).UnixMilli()
	inv, err := signNetwork(dir, pass, pb.RecordType_INVITE, &pb.Invite{InviteId: sum[:], ExpiresMs: exp}, now, exp)
	if err != nil {
		return nil, err
	}
	link, err := EncodeInviteLink(&pb.InviteBundle{NetworkPub: st.NetworkPub, Manifest: &manifest, Secret: secret})
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Join(dir, "rekeys"), 0o700); err != nil {
		return nil, err
	}
	j, _ := json.MarshalIndent(rekeyState{Old: hex.EncodeToString(old), InviteID: hex.EncodeToString(sum[:]), StartedMs: now.UnixMilli()}, "", "  ")
	if err := os.WriteFile(rekeyFile(dir, username), j, 0o600); err != nil {
		return nil, err
	}
	return &RekeyStartResult{Revocation: rev, Invite: inv, Link: link}, nil
}

// RekeyFinish (D111 step 2): REKEY{old, new}; new is the code read from the new install.
func RekeyFinish(dir string, pass []byte, username string, nw []byte, now time.Time) (*pb.Record, error) {
	raw, err := os.ReadFile(rekeyFile(dir, username))
	if err != nil {
		return nil, fmt.Errorf("run 'user rekey %s --old <code>' first: %w", username, err)
	}
	var s rekeyState
	if err := json.Unmarshal(raw, &s); err != nil {
		return nil, err
	}
	old, err := hex.DecodeString(s.Old)
	if err != nil || len(old) != 16 || len(nw) != 16 || string(old) == string(nw) {
		return nil, errors.New("the new account code must differ from the old one")
	}
	return signNetwork(dir, pass, pb.RecordType_REKEY, &pb.Rekey{OldUserId: old, NewUserId: nw}, now, 0)
}

// RekeyDone marks the re-key of username finished.
func RekeyDone(dir, username string) error {
	return os.Rename(rekeyFile(dir, username), filepath.Join(dir, "rekeys", username+".done.json"))
}
```

  (If `usernameRe` clashes with an M9.2 name in package `admin`, reuse that one.)

- [ ] **Step 3: CLI** in `run` (before the two-word `switch`, like `announce`):

```go
	if len(a) >= 3 && a[0] == "user" && a[1] == "rekey" {
		return userRekey(out, in, *dir, a[2:])
	}
```

```go
// userRekey: D111. Step 1 with --old, step 2 with --new.
func userRekey(out io.Writer, in io.Reader, dir string, args []string) error {
	name := args[0]
	fs := flag.NewFlagSet("user rekey", flag.ContinueOnError)
	oldHex := fs.String("old", "", "account code of the lost account (otter-admin user list, or the contact's info screen)")
	newHex := fs.String("new", "", "account code shown by the new install (Settings → Профиль → Код аккаунта)")
	var via multi
	fs.Var(&via, "via", "node label to publish through (repeatable; default: every node)")
	allowPlain := fs.Bool("allow-plain", false, "allow plain ws:// endpoints (development only)")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if (*oldHex == "") == (*newHex == "") {
		return errors.New("usage: user rekey <username> (--old CODE | --new CODE)")
	}
	p, err := passphrase(in, false)
	if err != nil {
		return err
	}
	if *oldHex != "" {
		old, err := admin.ParseUserCode(*oldHex)
		if err != nil {
			return err
		}
		res, err := admin.RekeyStart(dir, p, name, old, time.Now())
		if err != nil {
			return err
		}
		for _, r := range []*pb.Record{res.Revocation, res.Invite} {
			if err := publishAdmin(out, dir, r, via, *allowPlain); err != nil {
				return err
			}
		}
		fmt.Fprintf(out, "%s is revoked. Invite for the new install (valid 7 days, register as %q):\n%s\n\n", name, name, res.Link)
		qrterminal.GenerateHalfBlock(res.Link, qrterminal.L, out)
		fmt.Fprintf(out, "\nThen ask for the code in Settings → Профиль → «Код аккаунта» and run:\n  otter-admin user rekey %s --new <code>\n", name)
		return nil
	}
	nw, err := admin.ParseUserCode(*newHex)
	if err != nil {
		return err
	}
	rec, err := admin.RekeyFinish(dir, p, name, nw, time.Now())
	if err != nil {
		return err
	}
	if err := publishAdmin(out, dir, rec, via, *allowPlain); err != nil {
		return err
	}
	fmt.Fprintf(out, "%s now belongs to %x. Contacts see «Ключ безопасности изменился».\n", name, nw)
	return admin.RekeyDone(dir, name)
}

// publishAdmin sends a network-signed record with network.publish to the selected nodes; ok if one took it.
func publishAdmin(out io.Writer, dir string, rec *pb.Record, via []string, allowPlain bool) error {
	// same loop as publishNews (main.go:515-549) with method "network.publish"
}
```

  Write `publishAdmin` by copying `publishNews` and changing the method string (read it first; keep its node
  selection and "not published to any node" error). Usage line: `user rekey <username> (--old CODE | --new CODE) [--via LABEL]... [--allow-plain]`.

- [ ] **Step 4: CLI test** in `cmd/otter-admin/main_test.go`: run `user rekey anna --old <hex>` against the
  in-process test node that the existing `manifest publish`/`announce` tests use (read them first and reuse their
  helper), then `--new <hex>`; assert both outputs and that the node's `UsernameOwner`/`rekeys` changed. If those
  tests use a plain-ws node, pass `--allow-plain`.

- [ ] **Step 5: Run** `go test ./internal/admin/ ./cmd/otter-admin/ -count=1` → `ok`.

- [ ] **Step 6: Commit.**

```bash
git add internal/admin/rekey.go internal/admin/rekey_test.go cmd/otter-admin/
oc -m "admin: user rekey revokes a lost phone, invites the new install and signs REKEY (limit 2)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 54: Android — apply REKEY to contacts and chats; «Код аккаунта» (limit 2)

**Goal:** A verified REKEY moves the direct chat to the new account, hides the old contact, drops unsent mail to the
old key and shows «Ключ безопасности изменился»; the profile shows the account code the admin needs.

**Findings closed:** design limit 2 (app, 1:1 part)

**Files:**
- Sync: proto (`records.proto` with REKEY/Rekey) via `scripts/sync-proto.sh`
- Create: `otter-android/core/crypto/src/main/kotlin/app/ottermsg/core/crypto/RekeyVerifier.kt`
- Create: `core/database/.../entity/RekeyEntity.kt`, `core/database/.../dao/RekeyDao.kt`
- Modify: `core/database/.../OtterDatabase.kt:39-49` (entity, dao, `version` +1, AutoMigration; the version after M9.1/M9.2's bumps), `model/MessageStatus.kt:5-9` (`SYSTEM_KEY_CHANGED = 8`)
- Modify: `core/database/.../dao/ConversationDao.kt` (`movePeer`), `MessageDao.kt` (`moveConversation`), `OutboxDao.kt` (`deleteUnsentTo`)
- Create: `core/data/.../directory/RekeyApplier.kt`; Modify: `core/data/.../directory/DirectorySync.kt:41-58`
- Modify: `feature/conversation/.../MessageGrouping.kt:20-27`, `ConversationViewModel.kt:105`, `ConversationScreen.kt:287-289`, `res/values{,-en}/strings.xml`; `feature/chats/.../ChatListViewModel.kt:73-86`, `ChatListScreen.kt:98`, strings
- Modify: `feature/settings/.../ProfileScreen.kt` (account code row), `res/values{,-en}/strings.xml`
- Test: `core/crypto/src/test/.../RekeyVerifierTest.kt`, `core/data/src/test/.../RekeyTest.kt` (new)

**Acceptance Criteria:**
- [ ] `RekeyVerifier.verify(record, networkPub, ctx)` returns `Rekey` only for type REKEY, author ID16(network_pub), valid signature, 16-byte distinct ids.
- [ ] **Hostile (fake node):** a REKEY signed by the old account, a node key or another network is ignored: no row in `rekeys`, the chat and contacts unchanged.
- [ ] A verified REKEY old → new (new's entry known): old contact `revoked = 1`; new contact `identity_changed = 1`, `verified = 0`; the direct chat's `peer_user_id` becomes new (messages of an already existing chat with new are moved into it); one `SYSTEM_KEY_CHANGED` line with `senderId = new`; outbox rows to old with `sent_ms IS NULL` are deleted. Applying the same REKEY twice changes nothing more.
- [ ] If new's entry is not known yet, the REKEY is stored and applied at the directory sync that brings new.
- [ ] The line renders «%1$s: ключ безопасности изменился» / "%1$s: security key changed" in the chat and the chat list.
- [ ] Profile shows «Код аккаунта» = hex(user_id) in 8 groups of 4, long-press copies it.

**Verify:** `cd otter-android && ./gradlew :core:crypto:test :core:data:testDebugUnitTest --tests '*Rekey*'` → `BUILD SUCCESSFUL`; `./gradlew testDebugUnitTest` → green

**Steps:**

- [ ] **Step 1: Sync proto**; failing `RekeyVerifierTest.kt`:

```kotlin
package app.ottermsg.core.crypto

import app.ottermsg.proto.v1.Rekey
import app.ottermsg.proto.v1.RecordType
import com.google.protobuf.ByteString
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class RekeyVerifierTest {
    private val net = Ed25519.keyPairFromSeed(ByteArray(32) { 9 })
    private val thief = Ed25519.keyPairFromSeed(ByteArray(32) { 1 })
    private val ctx = SigContext(Ids.id16(net.publicKey), 0)
    private val payload = Rekey.newBuilder().setOldUserId(ByteString.copyFrom(Ids.id16(thief.publicKey)))
        .setNewUserId(ByteString.copyFrom(ByteArray(16) { 5 })).build().toByteArray()

    @Test fun networkSignedIsAccepted() =
        assertNotNull(RekeyVerifier.verify(RecordCodec.sign(RecordCodec.body(RecordType.REKEY, Ids.id16(net.publicKey), payload), net, ctx), net.publicKey, ctx))

    @Test fun oldAccountCannotRekeyItself() =
        assertNull(RekeyVerifier.verify(RecordCodec.sign(RecordCodec.body(RecordType.REKEY, Ids.id16(thief.publicKey), payload), thief, ctx), net.publicKey, ctx))

    @Test fun networkAuthorWithForeignSignature() =
        assertNull(RekeyVerifier.verify(RecordCodec.sign(RecordCodec.body(RecordType.REKEY, Ids.id16(net.publicKey), payload), thief, ctx), net.publicKey, ctx))
}
```

  Run → FAIL. Implement `RekeyVerifier.kt`:

```kotlin
package app.ottermsg.core.crypto

import app.ottermsg.proto.v1.Record
import app.ottermsg.proto.v1.RecordBody
import app.ottermsg.proto.v1.RecordType
import app.ottermsg.proto.v1.Rekey
import com.google.protobuf.InvalidProtocolBufferException

/** A network-signed REKEY (D111), checked like the node does (otter-server internal/records/validate.go). */
object RekeyVerifier {
    fun verify(record: Record, networkPub: ByteArray, ctx: SigContext): Rekey? = try {
        val body = RecordBody.parseFrom(record.body)
        val k = Rekey.parseFrom(body.payload)
        when {
            body.type != RecordType.REKEY || body.expiresMs != 0L -> null
            !body.author.toByteArray().contentEquals(Ids.id16(networkPub)) -> null
            k.oldUserId.size() != 16 || k.newUserId.size() != 16 || k.oldUserId == k.newUserId -> null
            !RecordCodec.verify(record, networkPub, ctx) -> null
            else -> k
        }
    } catch (e: InvalidProtocolBufferException) { null }
}
```

  Run → PASS.

- [ ] **Step 2: Room.** `RekeyEntity.kt`:

```kotlin
package app.ottermsg.core.database.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.PrimaryKey

/** A verified REKEY (D111). [appliedMs] = 0 until the new account's entry was known and the chat moved. */
@Entity(tableName = "rekeys")
data class RekeyEntity(
    @PrimaryKey @ColumnInfo(name = "old_user_id") val oldUserId: ByteArray,
    @ColumnInfo(name = "new_user_id") val newUserId: ByteArray,
    @ColumnInfo(name = "created_ms") val createdMs: Long,
    @ColumnInfo(name = "applied_ms", defaultValue = "0") val appliedMs: Long = 0,
)
```

  `RekeyDao.kt`:

```kotlin
@Dao interface RekeyDao {
    @Query("SELECT * FROM rekeys WHERE old_user_id = :old") suspend fun get(old: ByteArray): RekeyEntity?
    @Query("SELECT * FROM rekeys") suspend fun all(): List<RekeyEntity>
    @Query("SELECT * FROM rekeys WHERE applied_ms = 0") suspend fun pending(): List<RekeyEntity>
    @Upsert suspend fun upsert(r: RekeyEntity)
    @Query("UPDATE rekeys SET applied_ms = :ms WHERE old_user_id = :old") suspend fun markApplied(old: ByteArray, ms: Long)
}
```

  DAO additions:

```kotlin
// ConversationDao
@Query("UPDATE conversations SET peer_user_id = :new WHERE peer_user_id = :old") suspend fun movePeer(old: ByteArray, new: ByteArray)
@Query("DELETE FROM conversations WHERE id = :id") suspend fun delete(id: Long)
// MessageDao
@Query("UPDATE messages SET conversation_id = :to WHERE conversation_id = :from") suspend fun moveConversation(from: Long, to: Long)
// OutboxDao
@Query("DELETE FROM outbox WHERE recipient_user_id = :user AND sent_ms IS NULL") suspend fun deleteUnsentTo(user: ByteArray)
```

  `MessageKind`: `const val SYSTEM_KEY_CHANGED = 8` with KDoc "a contact's account was re-keyed (D111); sender = the new account".
  `OtterDatabase`: add entity and `abstract fun rekeyDao(): RekeyDao`, bump `version`, add `AutoMigration(from = N, to = N+1)`;
  run `./gradlew :core:database:kspDebugKotlin` (or the module's build task) to export the schema JSON and commit it.

- [ ] **Step 3: Failing data test** `core/data/src/test/kotlin/app/ottermsg/core/data/RekeyTest.kt`:

```kotlin
package app.ottermsg.core.data

import app.ottermsg.core.crypto.Ids
import app.ottermsg.core.crypto.RecordCodec
import app.ottermsg.core.crypto.SigContext
import app.ottermsg.core.database.model.MessageKind
import app.ottermsg.proto.v1.RecordType
import app.ottermsg.proto.v1.Rekey
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class RekeyTest {
    private val clock = TestClock()
    private val node = FakeNode(clock::now)
    private val g = TestGraph(node, clock)
    @After fun tearDown() = g.close()

    private fun rekey(old: ByteArray, new: ByteArray, signer: app.ottermsg.core.crypto.Ed25519.KeyPair = node.network,
                      author: ByteArray = Ids.id16(node.network.publicKey)) =
        RecordCodec.sign(RecordCodec.body(RecordType.REKEY, author, Rekey.newBuilder().setOldUserId(bs(old)).setNewUserId(bs(new))
            .build().toByteArray()), signer, SigContext(Ids.id16(node.network.publicKey), 0))

    @Test fun chatMovesToTheNewAccount() = runBlocking {
        g.register(node.bootstrapLink(), "Я", "me_user").getOrThrow()
        val old = node.directoryEntryFor(seed = 2, name = "anna", ctx = SigContext(Ids.id16(node.network.publicKey), 0))
        val new = node.directoryEntryFor(seed = 3, name = "anna", ctx = SigContext(Ids.id16(node.network.publicKey), 0))
        val oldId = uidOf(old); val newId = uidOf(new)
        g.directory.apply(listOf(old))
        val cid = g.db.conversationDao().getOrCreateDirect(oldId, "ANNA", clock.now())
        g.messages.sendText(cid, "привет") // queued in the outbox to old (offline)
        g.directory.apply(listOf(new, rekey(oldId, newId)))

        assertTrue(g.db.contactDao().get(oldId)!!.revoked)
        val c = g.db.contactDao().get(newId)!!
        assertTrue(c.identityChanged)
        assertEquals(cid, g.db.conversationDao().byPeer(newId)!!.id)
        assertNull(g.db.conversationDao().byPeer(oldId))
        assertEquals(1, g.db.messageDao().forConversation(cid).count { it.kind == MessageKind.SYSTEM_KEY_CHANGED })
        assertTrue(g.db.outboxDao().all().none { it.recipientUserId.contentEquals(oldId) && it.sentMs == null })
        g.directory.apply(listOf(rekey(oldId, newId))) // idempotent
        assertEquals(1, g.db.messageDao().forConversation(cid).count { it.kind == MessageKind.SYSTEM_KEY_CHANGED })
    }

    @Test fun forgedRekeysAreIgnored() = runBlocking {
        g.register(node.bootstrapLink(), "Я", "me_user").getOrThrow()
        val oldKeys = app.ottermsg.core.crypto.SeedKeys.accountKeyPair(ByteArray(32) { 2 })
        val old = node.directoryEntryFor(seed = 2, name = "anna", ctx = SigContext(Ids.id16(node.network.publicKey), 0))
        val oldId = uidOf(old)
        g.directory.apply(listOf(old))
        val cid = g.db.conversationDao().getOrCreateDirect(oldId, "ANNA", clock.now())
        val thiefNew = ByteArray(16) { 0x66 }
        g.directory.apply(listOf(
            rekey(oldId, thiefNew, signer = oldKeys, author = oldId),           // the thief with the old key
            rekey(oldId, thiefNew, signer = oldKeys),                           // network author, wrong key
        ))
        assertNull(g.db.rekeyDao().get(oldId))
        assertEquals(cid, g.db.conversationDao().byPeer(oldId)!!.id)
    }

    private fun uidOf(r: app.ottermsg.proto.v1.Record) = app.ottermsg.proto.v1.RecordBody.parseFrom(r.body).author.toByteArray()
}
```

  (Use the real names for "send a text" and "messages of a conversation" — check `MessageRepository` and `MessageDao`
  first; add `MessageDao.forConversation(id)`/`OutboxDao.all()` as `@Query` helpers only if no equivalent exists.)
  Run → FAIL.

- [ ] **Step 4: Implement** `core/data/.../directory/RekeyApplier.kt`:

```kotlin
package app.ottermsg.core.data.directory

import androidx.room.withTransaction
import app.ottermsg.core.crypto.RekeyVerifier
import app.ottermsg.core.data.Clock
import app.ottermsg.core.data.settings.Settings
import app.ottermsg.core.data.sync.SigContexts
import app.ottermsg.core.database.OtterDatabase
import app.ottermsg.core.database.entity.MessageEntity
import app.ottermsg.core.database.entity.RekeyEntity
import app.ottermsg.core.database.model.MessageKind
import app.ottermsg.core.database.model.MessageStatus
import app.ottermsg.proto.v1.Record
import app.ottermsg.proto.v1.RecordBody
import java.security.SecureRandom
import javax.inject.Inject
import javax.inject.Singleton

/** Lost-phone re-keys (D111): the old account's chat continues with the new one. Groups: [onApplied] (Task 55). */
@Singleton
class RekeyApplier @Inject constructor(
    private val db: OtterDatabase, private val settings: Settings, private val sigs: SigContexts, private val clock: Clock,
) {
    /** Called after group-related work is registered (Task 55); default no-op. */
    var onApplied: suspend (old: ByteArray, new: ByteArray) -> Unit = { _, _ -> }

    /** Stores verified REKEY records from a directory batch, then applies every pending one whose new entry is known. */
    suspend fun apply(records: List<Record>) {
        val pub = settings.networkPub()
        val ctx = sigs.sigContext()
        for (r in records) {
            val k = RekeyVerifier.verify(r, pub, ctx) ?: continue
            val created = RecordBody.parseFrom(r.body).createdMs
            val cur = db.rekeyDao().get(k.oldUserId.toByteArray())
            if (cur != null && cur.createdMs >= created) continue // the later REKEY wins (as on the nodes)
            db.rekeyDao().upsert(RekeyEntity(k.oldUserId.toByteArray(), k.newUserId.toByteArray(), created))
        }
        for (p in db.rekeyDao().pending()) {
            if (db.contactDao().get(p.newUserId) == null) continue // its entry arrives with a later sync
            moveChat(p.oldUserId, p.newUserId)
            onApplied(p.oldUserId, p.newUserId)
        }
    }

    private suspend fun moveChat(old: ByteArray, new: ByteArray) = db.withTransaction {
        val contacts = db.contactDao()
        contacts.get(old)?.let { contacts.upsert(it.copy(revoked = true)) }
        contacts.markIdentityChanged(new)
        db.outboxDao().deleteUnsentTo(old)
        val conv = db.conversationDao()
        val from = conv.byPeer(old)
        val into = conv.byPeer(new)
        val cid = when {
            from != null && into != null -> { db.messageDao().moveConversation(into.id, from.id); conv.delete(into.id); conv.movePeer(old, new); from.id }
            from != null -> { conv.movePeer(old, new); from.id }
            else -> into?.id
        }
        if (cid != null) {
            val now = clock.now()
            db.messageDao().insert(MessageEntity(messageId = ByteArray(16).also(SecureRandom()::nextBytes), conversationId = cid,
                senderId = new, outgoing = false, sentMs = now, receivedMs = now, body = "", status = MessageStatus.DELIVERED,
                kind = MessageKind.SYSTEM_KEY_CHANGED))
            conv.touch(cid, now)
        }
        db.rekeyDao().markApplied(old, clock.now())
    }
}
```

  `DirectorySync`: constructor param `rekeys: RekeyApplier`; at the end of `apply(records)` (inside the mutex, after
  the entry loop) call `rekeys.apply(records)`. In the entry loop, skip an entry whose user is the old side of a
  stored REKEY so a replayed old entry never un-revokes it:
  `if (rekeyDao.get(userId) != null) continue` (inject `RekeyDao` through `OtterDatabase`).
  Wire `RekeyApplier` in `TestGraph` before `directory`.

- [ ] **Step 5: Run** `./gradlew :core:data:testDebugUnitTest --tests '*Rekey*'` → PASS.

- [ ] **Step 6: UI.** `MessageGrouping.kt`: add `val keyChangedName: String? = null` and include it in `isEvent`.
  `ConversationViewModel.kt:105`: `keyChangedName = if (it.kind == MessageKind.SYSTEM_KEY_CHANGED) (names[it.senderId.hex()] ?: title) else null`;
  `:110` also excludes `SYSTEM_KEY_CHANGED` from "last incoming". `ConversationScreen.kt` after the `resetName` branch:
  `else if (item.message.keyChangedName != null) SystemEventChip(stringResource(R.string.conv_system_key_changed, item.message.keyChangedName))`.
  Strings: ru `<string name="conv_system_key_changed">%1$s: ключ безопасности изменился</string>`, en
  `%1$s: security key changed`; same pair `chats_system_key_changed` in `feature/chats`; `ChatListViewModel`
  gets `keyChangedBy = if (s.lastKind == MessageKind.SYSTEM_KEY_CHANGED) s.title else null` and `ChatListScreen.kt:98`
  a branch like `resetBy`; the preview check at `:73-74` includes the new kind.
  `ProfileScreen.kt`: under the username a row «Код аккаунта» / "Account code" with
  `me.userId.joinToString("") { "%02x".format(it) }.chunked(4).joinToString(" ")` in a monospace style,
  `combinedClickable(onLongClick = { clipboard.setText(AnnotatedString(code)) })`; strings `profile_account_code`
  («Код аккаунта» / "Account code") and `profile_account_code_hint` («Нужен администратору, если телефон потерян» /
  "The admin needs it if a phone is lost"). Mirror an existing `ChatListViewModelTest`/`ConversationViewModelTest`
  case for `SYSTEM_RESET` with the new kind.

- [ ] **Step 7: Run** `./gradlew testDebugUnitTest` → `BUILD SUCCESSFUL`.

- [ ] **Step 8: Commit.**

```bash
git add core/proto core/crypto core/database core/data feature/conversation feature/chats feature/settings
oc -m "app: REKEY moves a lost contact's chat to the new account, «Ключ безопасности изменился», account code (limit 2)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 55: Android — groups swap a re-keyed member (limit 2)

**Goal:** Groups replace `old` with `new` through a signed state any phone accepts once it knows the REKEY, and our
sender key rotates.

**Findings closed:** design limit 2 (app, groups)

**Files:**
- Modify: `otter-android/core/crypto/.../GroupRules.kt:27-91` (rekey map, swap rule)
- Modify: `core/data/.../group/GroupApplier.kt:51-134` (pass the map, events), `GroupEvents.kt:10-37` (skip swapped pairs), `GroupRepository.kt` (`swapMember`, `distribute(skip)`), `directory/RekeyApplier.kt` (`onApplied` wiring in `DataModule` / `TestGraph`)
- Test: `core/crypto/src/test/.../GroupRulesTest.kt` (cases), `core/data/src/test/.../GroupFlowTest.kt` (rekey case)

**Acceptance Criteria:**
- [ ] `GroupRules.evaluate(..., rekeys)` accepts version+1 signed by a current **member** that equals the base state with every `old` replaced by `new` for known pairs (members and admins), nothing else changed.
- [ ] **Hostile:** the same swap without a known REKEY (e.g. a member trying to swap in its own second account) → `Park("unknown rekey")`, never Accept; a swap that also changes the name or another member → `Reject` for non-admins.
- [ ] On a newly applied REKEY: an admin of each group containing `old` signs the swap and distributes it to the new member set (not to `old`); if `old` was the only admin, the lowest remaining user id does.
- [ ] After the swap: `group_members` lists `new` (with old's admin flag), our sender key rotated (`my_distribution` deleted, `sender_key_shared` cleared), one `SYSTEM_KEY_CHANGED` line with `senderId = new` in the group chat instead of REMOVED/ADDED events.

**Verify:** `cd otter-android && ./gradlew :core:crypto:test --tests '*GroupRules*' :core:data:testDebugUnitTest --tests '*GroupFlow*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing rule tests** in `GroupRulesTest.kt` (read its state builder helper first; called `state(...)` here):

```kotlin
    @Test fun memberMaySwapAKnownRekey() {
        val base = state(version = 3, members = listOf(a, b, old), admins = listOf(a))
        val swapped = state(version = 4, members = listOf(a, b, new), admins = listOf(a))
        val known = mapOf(bs(old) to bs(new))
        assertEquals(Verdict.Accept, GroupRules.evaluate(Applied(base, a), null, swapped, b, rekeys = known))
        assertEquals(Verdict.Park("unknown rekey"), GroupRules.evaluate(Applied(base, a), null, swapped, b))
        val renamedToo = swapped.toBuilder().setName("Другое").build()
        assertEquals(Verdict.Reject("signer is not an admin"), GroupRules.evaluate(Applied(base, a), null, renamedToo, b, rekeys = known))
    }

    @Test fun soleAdminSwapKeepsAdminFlag() {
        val base = state(version = 1, members = listOf(old, b), admins = listOf(old))
        val swapped = state(version = 2, members = listOf(new, b), admins = listOf(new))
        assertEquals(Verdict.Accept, GroupRules.evaluate(Applied(base, old), null, swapped, b, rekeys = mapOf(bs(old) to bs(new))))
    }
```

  Run → FAIL (no `rekeys` parameter).

- [ ] **Step 2: Implement** in `GroupRules.kt`: add `rekeys: Map<ByteString, ByteString> = emptyMap()` as the last
  parameter of `evaluate`, `againstBase` and `concurrent` (pass it through). In `againstBase`, in the
  `candidate.version == base.version + 1` branch, before `!signerIsMember`:

```kotlin
                signerIsMember && isRekeySwap(base, candidate, rekeys) -> Verdict.Accept
                signerIsMember && looksLikeSwap(base, candidate) -> Verdict.Park("unknown rekey")
```

```kotlin
    /** D112: candidate = base with each known old replaced by its new id; nothing else changed. */
    private fun isRekeySwap(base: GroupState, candidate: GroupState, rekeys: Map<ByteString, ByteString>): Boolean {
        if (candidate.name != base.name) return false
        fun map(l: List<ByteString>) = l.map { rekeys[it] ?: it }.map { Key(it.toByteArray()) }.toSet()
        val changed = base.membersList.any { it in rekeys.keys }
        return changed && candidate.membersList.map { Key(it.toByteArray()) }.toSet() == map(base.membersList) &&
            candidate.adminsList.map { Key(it.toByteArray()) }.toSet() == map(base.adminsList)
    }

    /** Same name, exactly one member out and one in, the admin flag carried over: a swap whose REKEY we may not know yet. */
    private fun looksLikeSwap(base: GroupState, candidate: GroupState): Boolean {
        if (candidate.name != base.name) return false
        val out = base.membersList - candidate.membersList.toSet()
        val inn = candidate.membersList - base.membersList.toSet()
        if (out.size != 1 || inn.size != 1) return false
        val wasAdmin = out[0] in base.adminsList
        return (inn[0] in candidate.adminsList) == wasAdmin &&
            (candidate.adminsList - inn.toSet()).toSet() == (base.adminsList - out.toSet()).toSet()
    }
```

  `GroupState.membersList` is `List<ByteString>` (proto equality); keep the stdlib `minus` here (this file has no
  local override). Run → PASS.

- [ ] **Step 3: Applier.** `GroupApplier`: load `val rekeys = db.rekeyDao().all().associate { bs(it.oldUserId) to bs(it.newUserId) }`
  in `change` and `evaluateAndStore` and pass it to `GroupRules.evaluate`. In `evaluateAndStore`, compute
  `val swapped = old?.membersList.orEmpty().filter { rekeys[it] != null && rekeys[it] in state.membersList }`;
  pass `rekeys` to `GroupEvents.between(old, state, signer, me, rekeys)` which drops swapped pairs from ADDED/REMOVED
  (and ADMIN_GRANTED/REVOKED for them); for each swapped old insert a `SYSTEM_KEY_CHANGED` message with
  `senderId = rekeys[old]`. The existing `removedSomeone` rotation then fires (old is no longer a member).
  `RekeyApplier.apply` must run `retryParked` for groups parked with "unknown rekey": after `moveChat`, call
  `applier.retryAllParked()` — a new public method that runs `retryParked(gid)` for every group with pending updates.

- [ ] **Step 4: Swap initiator** in `GroupRepository`:

```kotlin
    /** D112: replace a re-keyed member; returns false when it is not our job (another admin does it). */
    suspend fun swapMember(groupId: ByteArray, old: ByteArray, new: ByteArray): Boolean {
        val me = bs(accounts.require().userId)
        val cur = groups.get(groupId)?.let { SignedGroupState.parseFrom(it.stateSigned) }?.let { GroupState.parseFrom(it.state) } ?: return false
        val o = bs(old); val n = bs(new)
        if (o !in cur.membersList || me !in cur.membersList) return false
        val otherAdmins = cur.adminsList - o
        val mine = if (otherAdmins.isNotEmpty()) me in otherAdmins
            else (cur.membersList - o).minWithOrNull { x, y -> GroupRules.compareUnsigned(x.toByteArray(), y.toByteArray()) } == me
        if (!mine) return false
        fun swap(l: List<ByteString>) = l.map { if (it == o) n else it }
        change(groupId, skip = setOf(o)) { s -> s.toBuilder().clearMembers().addAllMembers(swap(s.membersList)).clearAdmins().addAllAdmins(swap(s.adminsList)) }
        return true
    }
```

  `change`/`distribute` get `skip: Set<ByteString> = emptySet()` and `distribute` does not enqueue to members in
  `skip` (the old key belongs to whoever holds the lost phone). Wire `rekeys.onApplied = { old, new -> groups.groupsWithMember(old).forEach { runCatching { groupRepository.swapMember(it, old, new) } } }`
  once at startup in `DataModule` (a `@Provides` that sets it on the `RekeyApplier` singleton) and in `TestGraph`.

- [ ] **Step 5: Flow test** in `GroupFlowTest.kt` (read its two-/three-graph setup): admin A, members B and OLD;
  REKEY OLD → NEW delivered to A and B (`g.directory.apply(listOf(newEntry, rekey))`); after `outbox` delivery
  B's group state lists NEW, B's chat has one `SYSTEM_KEY_CHANGED` line, A's `myDistribution(gid)` was reset, and no
  GroupUpdate was queued to OLD. Hostile case: B receives the swap before it knows the REKEY → parked; after the
  REKEY arrives the parked update is accepted.

- [ ] **Step 6: Run** `./gradlew testDebugUnitTest` → `BUILD SUCCESSFUL`.

- [ ] **Step 7: Commit.**

```bash
git add core/crypto core/data
oc -m "app: groups swap a re-keyed member and rotate sender keys (limit 2)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 56: Server — dial-out nodes hand backups abroad and keep none (limit 1, storage half)

**Goal:** A dial-out-only node never serves restores from its disk, never receives backups from peers, and deletes
what phones uploaded to it once enough foreign nodes confirm they hold it (D113).

**Findings closed:** design limit 1 (storage rule). Can ship before Task 57 (and before ru-1 joins, spec "Order").

**Files:**
- Modify: `otter-server/proto/otter/v1/peer.proto` (`PeerHoldsQuery`, `PeerHolds`, oneof 10–11), regenerate
- Modify: `otter-server/internal/store/apply.go:41-44` (`LogEntry`), `:258-277` (`Since`); new `internal/store/handoff.go`
- Modify: `otter-server/internal/service/backup.go:56-98` (`BackupAuth`, `BackupFetch`), `internal/service/replicated.go:16-41` (`ApplyReplicated`), new `internal/service/handoff.go`
- Modify: `otter-server/internal/replication/session.go:24-49,55-114,138-185`, `replicator.go:228-236` (helpers), `:182-188` (`SetTestTimings`); new `internal/replication/handoff.go`
- Modify: `otter-server/cmd/otter-node/main.go:316` (start the loop), `internal/meshsim/harness_test.go:249-253` (start the loop)
- Test: `internal/store/handoff_test.go` (new), `internal/meshsim/dialout_backup_test.go` (new)

**Acceptance Criteria:**
- [ ] On a node whose manifest entry has `dial_out_only`, `backup.auth` and `backup.fetch` answer `STATUS_UNAVAILABLE` without touching the store.
- [ ] Replication never sends BACKUP_META or persistent BLOB_META records to a dial-out peer (cursor still advances), a dial-out node drops such records arriving from older peers (`ApplyReplicated` returns `false, nil`), and a peer answers a dial-out node's `PeerBlobGet` for a persistent blob with `missing`.
- [ ] `Store.Holds(key)`: true iff the record exists and, for BLOB_META, every chunk row exists.
- [ ] The dial-out node deletes its BACKUP_META and persistent blob (record, rows, chunk files via the sweep; blob tombstoned) after `min(2, non-dial-out nodes)` distinct non-dial-out peers answer `held`; it never deletes on fewer answers; a blob is a handoff candidate only when a BACKUP_META references it or it is ≥ 1 h old.
- [ ] **Hostile (meshsim):** with one of two foreign nodes down, the dial-out node keeps its copy (one confirmation is not enough); after the second comes back it hands off; a backup published abroad never appears on the dial-out node.

**Verify:** `cd otter-server && go test ./internal/store/ ./internal/meshsim/ -run 'Holds|Handoff|DialOutNode' -count=1 -race` → `ok` ×2

**Steps:**

- [ ] **Step 1: Proto** (`peer.proto`), in `PeerFrame.oneof kind`: `PeerHoldsQuery holds_query = 10; PeerHolds holds = 11;` and

```proto
// A dial-out node asks whether the peer holds a record it wants to hand off (D113). For a BLOB_META "held" means
// every chunk is stored as well.
message PeerHoldsQuery {
  uint64 req = 1;
  bytes record_key = 2;
}

message PeerHolds {
  uint64 req = 1;
  bool held = 2;
}
```

  `make gen`.

- [ ] **Step 2: Failing store test** `internal/store/handoff_test.go`:

```go
package store

import (
	"context"
	"testing"

	pb "ottermsg/server/internal/proto/otterv1"
)

func TestHoldsAndDropBackupCopy(t *testing.T) {
	s, _ := open(t)
	ctx := context.Background()
	owner := r16()
	blob := blobItem(t, owner, nil, 2, 1000, 0) // persistent: no readers, no expiry
	blob.Body.Payload = mustPersistent(t, blob.Body.Payload)
	if err := apply(t, s, blob); err != nil {
		t.Fatal(err)
	}
	key := keyOf(blob)
	if held, _ := s.Holds(ctx, key); held {
		t.Fatal("held without chunks")
	}
	s.MarkChunk(ctx, key, 0)
	s.MarkChunk(ctx, key, 1)
	if held, _ := s.Holds(ctx, key); !held {
		t.Fatal("complete blob not held")
	}
	items, err := s.LocalBackupItems(ctx, 2000) // created 1000 < 2000: old enough
	if err != nil || len(items) != 1 {
		t.Fatalf("items %d %v", len(items), err)
	}
	if err := s.DropBackupCopy(ctx, key); err != nil {
		t.Fatal(err)
	}
	if held, _ := s.Holds(ctx, key); held {
		t.Fatal("still held after drop")
	}
	if gone, _ := s.BlobGone(ctx, key); !gone {
		t.Fatal("no tombstone: a lagging peer could resurrect it")
	}
	if held, _ := s.Holds(ctx, r16()); held {
		t.Fatal("unknown key held")
	}
	_ = pb.RecordType_BLOB_META
}
```

  (`blobItem` is `blobs_test.go:11`; write `mustPersistent` there to set `BlobMeta.Persistent = true` and clear
  readers; `apply`'s record must carry `ExpiresMs = 0`.) Run → FAIL.

- [ ] **Step 3: Implement** `internal/store/handoff.go`:

```go
package store

import (
	"context"
	"database/sql"
	"errors"

	pb "ottermsg/server/internal/proto/otterv1"
)

// Holds: the record is stored here and, for a BLOB_META, every chunk too (PeerHolds, D113).
func (s *Store) Holds(ctx context.Context, key []byte) (bool, error) {
	var typ int32
	var chunks sql.NullInt64
	var have int64
	err := s.r.QueryRowContext(ctx, `SELECT r.type, b.chunks, (SELECT COUNT(*) FROM blob_chunks c WHERE c.blob_key=r.record_key)
		FROM records r LEFT JOIN blobs b ON b.blob_key=r.record_key WHERE r.record_key=?`, key).Scan(&typ, &chunks, &have)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if pb.RecordType(typ) == pb.RecordType_BLOB_META {
		return chunks.Valid && have == chunks.Int64, nil
	}
	return true, nil
}

// LocalBackupItems: BACKUP_META records and persistent blobs a dial-out node should hand off. A blob qualifies once a
// BACKUP_META references it or it was created before olderThanMs (an abandoned upload).
func (s *Store) LocalBackupItems(ctx context.Context, olderThanMs int64) ([][]byte, error) {
	rows, err := s.r.QueryContext(ctx, `SELECT record_key FROM records WHERE type=?
		UNION ALL SELECT b.blob_key FROM blobs b WHERE b.persistent=1 AND
		  (EXISTS (SELECT 1 FROM backups k WHERE k.blob_key=b.blob_key) OR b.created_ms < ?)`,
		int32(pb.RecordType_BACKUP_META), olderThanMs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out [][]byte
	for rows.Next() {
		var k []byte
		if err := rows.Scan(&k); err != nil {
			return nil, err
		}
		out = append(out, k)
	}
	return out, rows.Err()
}

// DropBackupCopy deletes this node's copy of a handed-off backup record or blob (D113).
func (s *Store) DropBackupCopy(ctx context.Context, key []byte) error {
	return s.write(ctx, func(ctx context.Context, tx *sql.Tx) error {
		var typ int32
		err := tx.QueryRowContext(ctx, `SELECT type FROM records WHERE record_key=?`, key).Scan(&typ)
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		switch pb.RecordType(typ) {
		case pb.RecordType_BLOB_META:
			return gcBlob(ctx, tx, key, true, s.now().UnixMilli())
		case pb.RecordType_BACKUP_META:
			if _, err := tx.ExecContext(ctx, `DELETE FROM backups WHERE record_key=?`, key); err != nil {
				return err
			}
			_, err := tx.ExecContext(ctx, `DELETE FROM records WHERE record_key=?`, key)
			return err
		}
		return nil
	})
}

// BlobPersistent: key is a backup blob stored here.
func (s *Store) BlobPersistent(ctx context.Context, key []byte) (bool, error) {
	var p int
	err := s.r.QueryRowContext(ctx, `SELECT persistent FROM blobs WHERE blob_key=?`, key).Scan(&p)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return p != 0, err
}
```

  `apply.go`: `LogEntry` gets `Type int32` and `Persistent bool`; `Since` becomes

```go
	rows, err := s.r.QueryContext(ctx,
		`SELECT o.seq, r.raw, r.type, COALESCE(b.persistent, 0) FROM oplog o JOIN records r ON r.record_key=o.record_key
		 LEFT JOIN blobs b ON b.blob_key=o.record_key WHERE o.seq>? ORDER BY o.seq LIMIT ?`, cursor, limit)
	// scan: rows.Scan(&e.Seq, &e.Raw, &e.Type, &e.Persistent)
```

  Run `go test ./internal/store/ -count=1 -race` → PASS.

- [ ] **Step 4: Service.** New `internal/service/handoff.go`:

```go
package service

import (
	"bytes"
	"context"

	"google.golang.org/protobuf/proto"
	pb "ottermsg/server/internal/proto/otterv1"
)

// DialOutOnly: this node is marked dial_out_only in the current manifest (D71, D113).
func (s *Service) DialOutOnly() bool {
	for _, n := range s.CurrentManifest().GetNodes() {
		if bytes.Equal(n.NodeId, s.NodeID) {
			return n.DialOutOnly
		}
	}
	return false
}

// IsBackupRecord: BACKUP_META or a persistent BLOB_META.
func IsBackupRecord(b *pb.RecordBody) bool {
	switch b.Type {
	case pb.RecordType_BACKUP_META:
		return true
	case pb.RecordType_BLOB_META:
		var m pb.BlobMeta
		return proto.Unmarshal(b.Payload, &m) == nil && m.Persistent
	}
	return false
}

// Holds answers PeerHoldsQuery; a dial-out node never vouches for anyone.
func (s *Service) Holds(ctx context.Context, key []byte) (bool, error) {
	if s.DialOutOnly() {
		return false, nil
	}
	return s.Store.Holds(ctx, key)
}

// DropBackupCopy deletes a handed-off backup record or blob and sweeps chunk files soon.
func (s *Service) DropBackupCopy(ctx context.Context, key []byte) error {
	if err := s.Store.DropBackupCopy(ctx, key); err != nil {
		return err
	}
	s.kickSweep()
	return nil
}
```

  `BackupAuth` and `BackupFetch` start with:

```go
	if s.DialOutOnly() { // D113: no backups at rest here; phones restore through the tunnel to a node abroad
		return nil, fmt.Errorf("%w: restore through a node abroad", ErrUnavailable)
	}
```

  (`BackupFetch` returns three values: `return nil, nil, fmt.Errorf(...)`.) `ApplyReplicated`, right after the
  validation `switch`:

```go
	if s.DialOutOnly() && IsBackupRecord(body) {
		return false, nil // D113: an older peer still sends backups; they never rest on a dial-out node
	}
```

- [ ] **Step 5: Replication.** In `replicator.go` add:

```go
// peerDialOut reports whether node id is dial_out_only in the current manifest.
func (r *Replicator) peerDialOut(id []byte) bool {
	for _, n := range r.svc.CurrentManifest().GetNodes() {
		if bytes.Equal(n.NodeId, id) {
			return n.DialOutOnly
		}
	}
	return false
}

func backupEntry(e store.LogEntry) bool {
	return e.Type == int32(pb.RecordType_BACKUP_META) || (e.Type == int32(pb.RecordType_BLOB_META) && e.Persistent)
}
```

  `session.serve`, batch building (replace `session.go:162-178`):

```go
		toDialOut := s.r.peerDialOut(s.peer)
		b := &pb.PeerBatch{}
		size := 0
		for _, e := range entries {
			if size+len(e.Raw) > maxBatchBytes && len(b.Records) > 0 {
				break
			}
			b.LastSeq = e.Seq
			if toDialOut && backupEntry(e) {
				continue // D113: the cursor moves past it, the record never goes to a dial-out node
			}
			b.Records = append(b.Records, e.Raw)
			size += len(e.Raw)
		}
		if len(b.Records) > 0 { // an empty batch is not acked by the peer: take no window slot
			select {
			case s.acks <- struct{}{}:
			case <-s.ctx.Done():
				return
			}
		}
		s.send(&pb.PeerFrame{Kind: &pb.PeerFrame_Batch{Batch: b}})
		cursor = b.LastSeq
		idleSent = false
```

  `session.run`, `PeerFrame_BlobGet` goroutine, first lines:

```go
				if s.r.peerDialOut(s.peer) { // D113: no backup chunks to a dial-out node
					if p, err := s.r.st.BlobPersistent(s.ctx, g.BlobKey); err != nil || p {
						s.send(blobChunk(g.Req, nil))
						return
					}
				}
```

  Session fields `hpending map[uint64]chan bool` (init in `newSession`) and two cases in `run`:

```go
		case *pb.PeerFrame_HoldsQuery:
			q := k.HoldsQuery
			go func() {
				held, err := s.r.svc.Holds(s.ctx, q.RecordKey)
				s.send(&pb.PeerFrame{Kind: &pb.PeerFrame_Holds{Holds: &pb.PeerHolds{Req: q.Req, Held: err == nil && held}}})
			}()
		case *pb.PeerFrame_Holds:
			s.pmu.Lock()
			ch := s.hpending[k.Holds.Req]
			delete(s.hpending, k.Holds.Req)
			s.pmu.Unlock()
			if ch != nil {
				ch <- k.Holds.Held // buffered 1
			}
```

  New `internal/replication/handoff.go`:

```go
package replication

import (
	"context"
	"encoding/hex"
	"time"

	pb "ottermsg/server/internal/proto/otterv1"
)

var (
	handoffEvery  = time.Minute
	handoffMinAge = time.Hour
)

// holds asks this peer whether it holds key (D113); an old peer never answers and ctx ends.
func (s *session) holds(ctx context.Context, key []byte) (bool, error) {
	id := s.reqID.Add(1)
	ch := make(chan bool, 1)
	s.pmu.Lock()
	s.hpending[id] = ch
	s.pmu.Unlock()
	defer func() { s.pmu.Lock(); delete(s.hpending, id); s.pmu.Unlock() }()
	s.send(&pb.PeerFrame{Kind: &pb.PeerFrame_HoldsQuery{HoldsQuery: &pb.PeerHoldsQuery{Req: id, RecordKey: key}}})
	select {
	case h := <-ch:
		return h, nil
	case <-ctx.Done():
		return false, ctx.Err()
	case <-s.ctx.Done():
		return false, s.ctx.Err()
	}
}

// confirmationsNeeded: distinct non-dial-out nodes that must hold a backup before a dial-out node drops it (D113).
func confirmationsNeeded(m *pb.Manifest) int {
	n := 0
	for _, x := range m.GetNodes() {
		if !x.DialOutOnly {
			n++
		}
	}
	return min(2, n)
}

// RunBackupHandoff: on a dial-out node, deletes local backups once enough nodes abroad hold them (D113).
func (r *Replicator) RunBackupHandoff(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(handoffEvery):
		}
		m := r.svc.CurrentManifest()
		if m == nil || !r.selfDialOutOnly(m) {
			continue
		}
		need := confirmationsNeeded(m)
		if need == 0 {
			continue
		}
		keys, err := r.st.LocalBackupItems(ctx, time.Now().Add(-handoffMinAge).UnixMilli())
		if err != nil {
			r.log.Warn("backup handoff", "err", err)
			continue
		}
		for _, k := range keys {
			got := 0
			for _, s := range r.reg.all() {
				if r.peerDialOut(s.peer) {
					continue
				}
				qctx, cancel := context.WithTimeout(ctx, peerChunkTimeout)
				held, err := s.holds(qctx, k)
				cancel()
				if err == nil && held {
					got++
				}
			}
			if got < need {
				continue
			}
			if err := r.svc.DropBackupCopy(ctx, k); err != nil {
				r.log.Warn("backup handoff drop", "key", hex.EncodeToString(k), "err", err)
			} else {
				r.log.Info("backup handed off", "key", hex.EncodeToString(k), "confirmations", got)
			}
		}
	}
}
```

  `SetTestTimings`: also `handoffEvery = dial`. Start `go repl.RunBackupHandoff(ctx)` in `cmd/otter-node/main.go`
  after `RunPuller` and in meshsim `start` after `RunPuller`.

- [ ] **Step 6: Failing meshsim test** `internal/meshsim/dialout_backup_test.go`:

```go
package meshsim

import (
	"bytes"
	"crypto/sha256"
	"testing"
	"time"

	pb "ottermsg/server/internal/proto/otterv1"
)

func (s *sim) publishBackup(c *client, a *account, version uint64, data []byte) (blob, meta []byte) {
	blob = s.putPersistentBlob(c, a, data)
	v := sha256.Sum256(bytes.Repeat([]byte{5}, 32))
	rec := s.signAs(a, pb.RecordType_BACKUP_META, &pb.BackupMeta{Version: version, Salt: bytes.Repeat([]byte{1}, 16), KdfMKib: 65536,
		KdfT: 3, KdfP: 1, AuthVerifier: v[:], BlobKey: blob, Size: uint64(len(data))})
	c.mustCall("backup.publish", &pb.RecordRequest{Record: rec}, &pb.Empty{})
	return blob, recordKey(rec)
}

func TestDialOutNodeKeepsNoBackups(t *testing.T) {
	s := newSimWith(t, map[string]nodeOpts{"ru": {dialOutOnly: true}}, "ru", "f1", "f2")
	ru, f1, f2 := s.node("ru"), s.node("f1"), s.node("f2")
	anna := s.register(ru, "anna")
	eventually(t, "abroad knows anna", func() bool { return f1.knows(anna) && f2.knows(anna) })
	s.stop(f2) // only one foreign node can confirm now

	c := s.login(ru, anna)
	data := randomBytes(1 << 20)
	blob, meta := s.publishBackup(c, anna, 1, data)
	c.close()
	if st, _ := s.dial(ru).call("backup.auth", &pb.BackupAuthRequest{Username: "anna"}, &pb.BackupAuthResponse{}); st != pb.Status_STATUS_UNAVAILABLE {
		t.Fatalf("dial-out node answered backup.auth: %v", st)
	}
	eventuallyWithin(t, time.Minute, "f1 holds the backup", func() bool { return f1.hasChunks(blob, 4) && f1.has(meta) })
	time.Sleep(20 * 50 * time.Millisecond) // ~20 handoff rounds
	if !ru.has(meta) || ru.blobGone(blob) {
		t.Fatal("ru dropped its copy on one confirmation (need 2)")
	}
	s.start(f2)
	eventuallyWithin(t, time.Minute, "ru hands off", func() bool { return ru.blobGone(blob) && !ru.has(meta) })
	if !f2.has(meta) {
		t.Fatal("f2 confirmed without holding")
	}

	cf := s.login(f1, anna)
	blob2, meta2 := s.publishBackup(cf, anna, 2, data[:1000])
	eventuallyWithin(t, time.Minute, "f2 has v2", func() bool { return f2.has(meta2) && f2.hasChunks(blob2, 1) })
	time.Sleep(500 * time.Millisecond)
	if ru.has(meta2) || ru.has(blob2) {
		t.Fatal("a backup was replicated to the dial-out node")
	}
}
```

  Run `go test ./internal/meshsim/ -run DialOutNode -count=1 -race` → FAIL before Steps 3–5, PASS after.
  Then `go test ./... -count=1 -race` → all `ok` (`TestBackupRestoreThroughOtherNode` must still pass: none of its
  nodes is dial-out).

- [ ] **Step 7: Commit.**

```bash
git add proto/otter/v1/peer.proto internal/proto/otterv1/ internal/store/ internal/service/ internal/replication/ cmd/otter-node/main.go internal/meshsim/
oc -m "node: dial-out nodes hand backups abroad and never keep or serve them (limit 1)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 57: Server — restore tunnel through a dial-out node (limit 1, restore half)

**Goal:** A phone that can reach only the dial-out node runs pinned TLS + the client protocol to a foreign node through
a byte tunnel carried by the dial-out node's existing peer session (D114).

**Findings closed:** design limit 1 (restore path)

**Size check (answering "is the tunnel too large?"):** Go ≈ 300 lines (one file plus wiring), Android ≈ 200 lines
(Task 58). It reuses the peer session, the gateway, the WSS certificate and OkHttp's own TLS/pinning, so it is the
smallest design that keeps the salt and the password check away from the dial-out node. The smaller alternative
(dial-out node answers UNAVAILABLE, phones in Russia restore only when a node abroad is reachable directly or via a
VPN) has one weakness: **no restore at all from inside Russia without a VPN**. Recommended: build the tunnel, ship
Task 56 first if ru-1 is needed earlier.

**Files:**
- Modify: `otter-server/proto/otter/v1/peer.proto` (`PeerTunnelOpen/Data/Ack/Close`, oneof 12–15), regenerate
- Create: `otter-server/internal/replication/tunnel.go`, `internal/replication/tunnel_test.go`
- Modify: `internal/replication/session.go` (fields, dispatch), `registry.go` (`get`), `replicator.go:21-34` (fields `tln`, `tlim`)
- Modify: `internal/transport/wss/server.go:17-30` (4th handler), `transport/wss/server_test.go`
- Modify: `cmd/otter-node/main.go:330-336,400-401` (mount `/tunnel`, serve the tunnel listener with TLS)
- Modify: `internal/meshsim/harness_test.go` (`nodeOpts.tunnel`, TLS tunnel listener, `wrap` split from `dial`)
- Test: `internal/meshsim/tunnel_test.go` (new)

**Acceptance Criteria:**
- [ ] Only a node that is `dial_out_only` in the current manifest serves `<path>/tunnel?to=<hex id>`; others answer 404. Unknown, self or dial-out targets → 404; target without a live peer session → 503; > 4 tunnels per client IP or > 32 per node → 429.
- [ ] A foreign node accepts `PeerTunnelOpen` only from a dial-out peer and only when its tunnel listener is served (TLS configured); otherwise it answers `PeerTunnelClose` and no connection reaches the gateway.
- [ ] Flow control: ≤ 32 KiB per data frame, ≤ 32 unacked frames per direction; a peer exceeding the window or sending larger frames gets its stream closed; ≤ 16 streams per peer session; 2 min idle and 30 min lifetime.
- [ ] **meshsim:** `backup.auth` + `backup.fetch` + all `blob.get` chunks of a 3 MiB backup succeed through `ru`'s tunnel to `f1` with the phone pinning `f1`'s certificate; pinning `f2`'s certificate instead fails the handshake.
- [ ] **Hostile:** the bytes `ru` relays (tap) never contain the salt or the string `backup.fetch`; `f2` (not dial-out) answers 404 for `/tunnel`; a non-dial-out peer's `PeerTunnelOpen` is refused (unit test).

**Verify:** `cd otter-server && go test ./internal/replication/ ./internal/meshsim/ ./internal/transport/wss/ -run 'Tunnel|Server' -count=1 -race` → `ok` ×3

**Steps:**

- [ ] **Step 1: Proto** (`peer.proto`): oneof `PeerTunnelOpen tunnel_open = 12; PeerTunnelData tunnel_data = 13; PeerTunnelAck tunnel_ack = 14; PeerTunnelClose tunnel_close = 15;` and

```proto
// Restore tunnel (D114): opened by a dial-out node for a phone; the bytes are the phone's TLS stream to this node.
message PeerTunnelOpen {
  uint64 stream = 1;
}

message PeerTunnelData {
  uint64 stream = 1;
  bytes data = 2; // 1..32768 bytes
}

// The receiver consumed `chunks` data frames; the sender may have at most 32 unacknowledged.
message PeerTunnelAck {
  uint64 stream = 1;
  uint32 chunks = 2;
}

message PeerTunnelClose {
  uint64 stream = 1;
  string reason = 2;
}
```

  `make gen`.

- [ ] **Step 2: Failing unit test** `internal/replication/tunnel_test.go` — use `newMesh(t, 2, false)` from
  `replication_test.go:85` (two nodes, neither dial-out), wait for the session, then from node 0's session call
  `openTunnel()` and assert node 1 answers `PeerTunnelClose` (the tunnel's `done` closes within 2 s) and node 1's
  `TunnelListener().Accept()` yields nothing (run it in a goroutine with a 1 s timer):

```go
func TestTunnelRefusedFromNonDialOutPeer(t *testing.T) {
	m := newMesh(t, 2, false)
	m.start()
	ln := m.nodes[1].repl.TunnelListener()
	got := make(chan net.Conn, 1)
	go func() { c, err := ln.Accept(); if err == nil { got <- c } }()
	var s *session
	eventually(t, "session up", func() bool { s = m.nodes[0].repl.reg.get(m.nodes[1].svc.NodeID); return s != nil })
	tn, err := s.openTunnel()
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-tn.done:
	case <-time.After(2 * time.Second):
		t.Fatal("open from a non-dial-out peer not refused")
	}
	select {
	case <-got:
		t.Fatal("a refused tunnel reached the listener")
	case <-time.After(time.Second):
	}
}
```

  (Use the real field names of `mesh`/`tnode` — read `replication_test.go:60-140`.) Run → FAIL (`undefined: openTunnel`).

- [ ] **Step 3: Implement** `internal/replication/tunnel.go`:

```go
package replication

import (
	"bytes"
	"context"
	"encoding/hex"
	"errors"
	"net"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
	pb "ottermsg/server/internal/proto/otterv1"
)

// Restore tunnel (D114).
const (
	tunnelChunk       = 32 << 10 // max bytes per PeerTunnelData
	tunnelWindow      = 32       // unacknowledged data frames per stream and direction
	maxTunnelsPerPeer = 16
	maxTunnelsPerIP   = 4
	maxTunnels        = 32
)

var (
	tunnelIdle     = 2 * time.Minute
	tunnelLifetime = 30 * time.Minute
	tunnelTap      func([]byte) // tests: sees every byte a dial-out node relays
	errTunnelBusy  = errors.New("too many tunnels")
)

// SetTunnelTap lets tests observe relayed bytes. Never set in production.
func SetTunnelTap(f func([]byte)) { tunnelTap = f }

type tunnel struct {
	id     uint64
	in     chan []byte // from the peer; never more than tunnelWindow queued
	credit atomic.Int64
	more   chan struct{}
	done   chan struct{}
	once   sync.Once
}

func newTunnel(id uint64) *tunnel {
	t := &tunnel{id: id, in: make(chan []byte, tunnelWindow), more: make(chan struct{}, 1), done: make(chan struct{})}
	t.credit.Store(tunnelWindow)
	return t
}

func (t *tunnel) stop() { t.once.Do(func() { close(t.done) }) }

func tunnelClose(id uint64, why string) *pb.PeerFrame {
	return &pb.PeerFrame{Kind: &pb.PeerFrame_TunnelClose{TunnelClose: &pb.PeerTunnelClose{Stream: id, Reason: why}}}
}

func (s *session) addTunnel(id uint64) *tunnel {
	s.tmu.Lock()
	defer s.tmu.Unlock()
	if s.tunnels[id] != nil || len(s.tunnels) >= maxTunnelsPerPeer {
		return nil
	}
	t := newTunnel(id)
	s.tunnels[id] = t
	return t
}

func (s *session) tunnelByID(id uint64) *tunnel { s.tmu.Lock(); defer s.tmu.Unlock(); return s.tunnels[id] }
func (s *session) dropTunnel(id uint64)         { s.tmu.Lock(); delete(s.tunnels, id); s.tmu.Unlock() }

// onTunnelFrame runs on the session's read loop and never blocks.
func (s *session) onTunnelFrame(f *pb.PeerFrame) {
	switch k := f.Kind.(type) {
	case *pb.PeerFrame_TunnelOpen:
		s.acceptTunnel(k.TunnelOpen.Stream)
	case *pb.PeerFrame_TunnelData:
		t := s.tunnelByID(k.TunnelData.Stream)
		if t == nil {
			return
		}
		if n := len(k.TunnelData.Data); n == 0 || n > tunnelChunk {
			t.stop()
			return
		}
		select {
		case t.in <- k.TunnelData.Data:
		default:
			t.stop() // the peer ignored the window
		}
	case *pb.PeerFrame_TunnelAck:
		if t := s.tunnelByID(k.TunnelAck.Stream); t != nil && k.TunnelAck.Chunks <= tunnelWindow {
			t.credit.Add(int64(k.TunnelAck.Chunks))
			select {
			case t.more <- struct{}{}:
			default:
			}
		}
	case *pb.PeerFrame_TunnelClose:
		if t := s.tunnelByID(k.TunnelClose.Stream); t != nil {
			t.stop()
		}
	}
}

// openTunnel (dial-out side) starts a stream to the peer's in-process TLS endpoint.
func (s *session) openTunnel() (*tunnel, error) {
	id := s.nextTunnel.Add(1)
	t := s.addTunnel(id)
	if t == nil {
		return nil, errTunnelBusy
	}
	s.send(&pb.PeerFrame{Kind: &pb.PeerFrame_TunnelOpen{TunnelOpen: &pb.PeerTunnelOpen{Stream: id}}})
	return t, nil
}

// acceptTunnel (foreign side): only a dial-out peer may open one, only when this node serves the tunnel listener.
func (s *session) acceptTunnel(id uint64) {
	ln := s.r.tln.Load()
	switch {
	case ln == nil:
		s.send(tunnelClose(id, "no tunnel endpoint"))
		return
	case !s.r.peerDialOut(s.peer):
		s.send(tunnelClose(id, "not a dial-out node"))
		return
	}
	t := s.addTunnel(id)
	if t == nil {
		s.send(tunnelClose(id, "busy"))
		return
	}
	a, b := net.Pipe()
	go func() {
		if !ln.offer(tunnelConn{Conn: a, from: "tunnel:" + s.r.labelOf(s.peer)}) {
			a.Close()
		}
	}()
	go s.runTunnel(t, b)
}

// runTunnel copies c ↔ the peer stream until either side ends, it idles, or its lifetime passes; it closes c.
func (s *session) runTunnel(t *tunnel, c net.Conn) {
	ctx, cancel := context.WithTimeout(s.ctx, tunnelLifetime)
	defer func() {
		cancel()
		t.stop()
		c.Close()
		s.dropTunnel(t.id)
		s.send(tunnelClose(t.id, ""))
	}()
	go func() { // unblock c.Read on peer close, session end or lifetime
		select {
		case <-t.done:
		case <-ctx.Done():
		}
		c.Close()
	}()
	go func() { // peer → c
		defer t.stop()
		for {
			select {
			case b := <-t.in:
				if tunnelTap != nil {
					tunnelTap(b)
				}
				c.SetWriteDeadline(time.Now().Add(tunnelIdle))
				if _, err := c.Write(b); err != nil {
					return
				}
				s.send(&pb.PeerFrame{Kind: &pb.PeerFrame_TunnelAck{TunnelAck: &pb.PeerTunnelAck{Stream: t.id, Chunks: 1}}})
			case <-t.done:
				return
			case <-ctx.Done():
				return
			}
		}
	}()
	buf := make([]byte, tunnelChunk)
	for { // c → peer
		for t.credit.Load() <= 0 {
			select {
			case <-t.more:
			case <-t.done:
				return
			case <-ctx.Done():
				return
			}
		}
		c.SetReadDeadline(time.Now().Add(tunnelIdle))
		n, err := c.Read(buf)
		if n > 0 {
			if tunnelTap != nil {
				tunnelTap(buf[:n])
			}
			t.credit.Add(-1)
			s.send(&pb.PeerFrame{Kind: &pb.PeerFrame_TunnelData{TunnelData: &pb.PeerTunnelData{Stream: t.id, Data: bytes.Clone(buf[:n])}}})
		}
		if err != nil {
			return
		}
	}
}

type tunnelAddr string

func (a tunnelAddr) Network() string { return "tunnel" }
func (a tunnelAddr) String() string  { return string(a) }

type tunnelConn struct {
	net.Conn
	from string
}

func (c tunnelConn) RemoteAddr() net.Addr { return tunnelAddr(c.from) }

type tunnelListener struct {
	conns chan net.Conn
	done  chan struct{}
	once  sync.Once
}

func (l *tunnelListener) Accept() (net.Conn, error) {
	select {
	case c := <-l.conns:
		return c, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}
func (l *tunnelListener) Close() error   { l.once.Do(func() { close(l.done) }); return nil }
func (l *tunnelListener) Addr() net.Addr { return tunnelAddr("tunnel") }
func (l *tunnelListener) offer(c net.Conn) bool {
	select {
	case l.conns <- c:
		return true
	case <-l.done:
		return false
	case <-time.After(5 * time.Second):
		return false
	}
}

// TunnelListener yields restore streams from dial-out peers. Serve it with tls.NewListener and the client handler;
// until it is called, this node refuses tunnels.
func (r *Replicator) TunnelListener() net.Listener {
	l := &tunnelListener{conns: make(chan net.Conn), done: make(chan struct{})}
	if r.tln.CompareAndSwap(nil, l) {
		return l
	}
	return r.tln.Load()
}

type tunnelLimits struct {
	mu    sync.Mutex
	total int
	perIP map[string]int
}

func (l *tunnelLimits) acquire(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.perIP == nil {
		l.perIP = map[string]int{}
	}
	if l.total >= maxTunnels || l.perIP[ip] >= maxTunnelsPerIP {
		return false
	}
	l.total++
	l.perIP[ip]++
	return true
}

func (l *tunnelLimits) release(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.total--
	if l.perIP[ip]--; l.perIP[ip] <= 0 {
		delete(l.perIP, ip)
	}
}

// ServeTunnel serves <path>/tunnel?to=<hex node id> on a dial-out node (D114).
func (r *Replicator) ServeTunnel(w http.ResponseWriter, req *http.Request) {
	m := r.svc.CurrentManifest()
	if m == nil || !r.selfDialOutOnly(m) {
		http.NotFound(w, req)
		return
	}
	to, err := hex.DecodeString(req.URL.Query().Get("to"))
	var target *pb.NodeInfo
	for _, n := range m.Nodes {
		if err == nil && bytes.Equal(n.NodeId, to) {
			target = n
		}
	}
	if target == nil || target.DialOutOnly {
		http.Error(w, "unknown node", http.StatusNotFound)
		return
	}
	s := r.reg.get(to)
	if s == nil {
		http.Error(w, "node not connected", http.StatusServiceUnavailable)
		return
	}
	ip, _, err := net.SplitHostPort(req.RemoteAddr)
	if err != nil {
		ip = req.RemoteAddr
	}
	if !r.tlim.acquire(ip) {
		http.Error(w, "busy", http.StatusTooManyRequests)
		return
	}
	defer r.tlim.release(ip)
	c, err := websocket.Accept(w, req, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return
	}
	c.SetReadLimit(tunnelChunk)
	t, err := s.openTunnel()
	if err != nil {
		c.Close(websocket.StatusTryAgainLater, "busy")
		return
	}
	s.runTunnel(t, websocket.NetConn(s.ctx, c, websocket.MessageBinary))
}
```

  Session: fields `tmu sync.Mutex; tunnels map[uint64]*tunnel; nextTunnel atomic.Uint64` (init `tunnels` in
  `newSession`); in `run`'s `switch` add
  `case *pb.PeerFrame_TunnelOpen, *pb.PeerFrame_TunnelData, *pb.PeerFrame_TunnelAck, *pb.PeerFrame_TunnelClose: s.onTunnelFrame(f)`.
  Registry: `func (g *registry) get(peer []byte) *session { g.mu.Lock(); defer g.mu.Unlock(); return g.byPeer[string(peer)] }`.
  Replicator fields: `tln atomic.Pointer[tunnelListener]`, `tlim tunnelLimits`.
  `SetTestTimings`: `tunnelIdle = 20 * backoff`.

- [ ] **Step 4: Run** `go test ./internal/replication/ -run Tunnel -count=1 -race` → PASS.

- [ ] **Step 5: Mount and serve.** `wss.NewServer(cfg Config, ws, peer, tunnel http.Handler)`: mount
  `cfg.Path+"/tunnel"` when `tunnel != nil`; update `server_test.go` and the four call sites. `cmd/otter-node/main.go`:

```go
	srv := wss.NewServer(wcfg, gw, replication.WithListener(repl, "wss"), http.HandlerFunc(repl.ServeTunnel))
	errc := make(chan error, 3)
	go func() { errc <- wss.Serve(srv, wcfg) }()
	if a.cfg.WSS.TLSCert != "" { // D114: restore streams from dial-out nodes end here, under our WSS certificate
		cert, err := tls.LoadX509KeyPair(a.cfg.WSS.TLSCert, a.cfg.WSS.TLSKey)
		if err != nil {
			return fmt.Errorf("tunnel tls: %w", err)
		}
		tsrv := wss.NewServer(wss.Config{Path: a.cfg.WSS.Path}, gw, nil, nil)
		tsrv.ErrorLog = log.New(io.Discard, "", 0)
		go tsrv.Serve(tls.NewListener(repl.TunnelListener(), &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{cert}}))
		defer tsrv.Close()
	}
```

  In `startReality`, pass `http.HandlerFunc(repl.ServeTunnel)` too (phones do not use REALITY today; harmless).

- [ ] **Step 6: Failing meshsim test** `internal/meshsim/tunnel_test.go`. Harness changes first: split `dial` into
  `dial(n)` = `wrap(websocket.Dial(...))` and `wrap(c *websocket.Conn) *client` (the read goroutine and hello);
  `nodeOpts.tunnel bool` → in `start`, when set, `certPEM, keyPEM, pin, _ := pinning.GenerateCert([]string{n.label + ".test"}, nil, 24*time.Hour)`
  (once per node, kept in `simNode.tunnelPin`/`tunnelCert`), and serve
  `wss.NewServer(wss.Config{Path: path}, gw, nil, nil)` on `tls.NewListener(repl.TunnelListener(), cfg)`;
  pass `http.HandlerFunc(repl.ServeTunnel)` to the main `wss.NewServer`. Then:

```go
package meshsim

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"net"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"ottermsg/server/internal/pinning"
	pb "ottermsg/server/internal/proto/otterv1"
	"ottermsg/server/internal/replication"
)

// dialTunnel is what the phone does (D114): WebSocket to via's /tunnel, pinned TLS to target inside it, then the client protocol.
func (s *sim) dialTunnel(via, target *simNode, pin []byte) (*client, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	outer, _, err := websocket.Dial(ctx, s.url(via)+"/tunnel?to="+hex.EncodeToString(target.id), nil)
	if err != nil {
		return nil, err
	}
	raw := websocket.NetConn(context.Background(), outer, websocket.MessageBinary)
	tc := tls.Client(raw, &tls.Config{ServerName: target.label + ".test", InsecureSkipVerify: true,
		VerifyPeerCertificate: func(certs [][]byte, _ [][]*x509.Certificate) error {
			c, err := x509.ParseCertificate(certs[0])
			if err != nil {
				return err
			}
			if !bytes.Equal(pinning.SPKIPin(c), pin) {
				return errors.New("certificate does not match the pin")
			}
			return nil
		}})
	hc := &http.Client{Transport: &http.Transport{DialTLSContext: func(context.Context, string, string) (net.Conn, error) { return tc, nil }}}
	c, _, err := websocket.Dial(ctx, "wss://"+target.label+".test"+path, &websocket.DialOptions{HTTPClient: hc})
	if err != nil {
		return nil, err
	}
	return s.wrap(c), nil
}

func TestRestoreThroughTunnel(t *testing.T) {
	s := newSimWith(t, map[string]nodeOpts{"ru": {dialOutOnly: true}, "f1": {tunnel: true}, "f2": {tunnel: true}}, "ru", "f1", "f2")
	ru, f1, f2 := s.node("ru"), s.node("f1"), s.node("f2")
	anna := s.register(f1, "anna")
	c := s.login(f1, anna)
	data := randomBytes(3 << 20)
	blob, _ := s.publishBackup(c, anna, 1, data)
	c.close()

	var mu sync.Mutex
	var relayed []byte
	replication.SetTunnelTap(func(b []byte) { mu.Lock(); relayed = append(relayed, b...); mu.Unlock() })
	t.Cleanup(func() { replication.SetTunnelTap(nil) })

	eventually(t, "ru has a session to f1", func() bool {
		for _, p := range ru.repl.Status() {
			if bytes.Equal(p.Node, f1.id) && p.Connected {
				return true
			}
		}
		return false
	})
	tc, err := s.dialTunnel(ru, f1, f1.tunnelPin)
	if err != nil {
		t.Fatal(err)
	}
	var auth pb.BackupAuthResponse
	tc.mustCall("backup.auth", &pb.BackupAuthRequest{Username: "anna"}, &auth)
	var res pb.BackupFetchResponse
	tc.mustCall("backup.fetch", &pb.BackupFetchRequest{Username: "anna", AuthSecret: bytes.Repeat([]byte{5}, 32)}, &res)
	got, st := s.getBlob(tc, blob, 12)
	if st != pb.Status_STATUS_OK || !bytes.Equal(got, data) {
		t.Fatalf("restore through the tunnel: %v", st)
	}
	mu.Lock()
	leak := bytes.Contains(relayed, auth.Salt) || bytes.Contains(relayed, []byte("backup.fetch"))
	n := len(relayed)
	mu.Unlock()
	if n < len(data) || leak {
		t.Fatalf("relayed %d bytes, plaintext visible to ru: %v", n, leak)
	}

	if _, err := s.dialTunnel(ru, f1, f2.tunnelPin); err == nil {
		t.Fatal("wrong pin accepted")
	}
	if _, resp, err := websocket.Dial(context.Background(), s.url(f2)+"/tunnel?to="+hex.EncodeToString(f1.id), nil); err == nil || resp == nil || resp.StatusCode != http.StatusNotFound {
		t.Fatalf("non-dial-out node serves /tunnel: %v", err)
	}
	if _, resp, err := websocket.Dial(context.Background(), s.url(ru)+"/tunnel?to="+hex.EncodeToString(ru.id), nil); err == nil || resp == nil || resp.StatusCode != http.StatusNotFound {
		t.Fatalf("tunnel to a dial-out node: %v", err)
	}
}
```

  (`s.getBlob` is the helper `TestBackupRestoreThroughOtherNode` uses; `publishBackup` is from Task 56.)
  Run `go test ./internal/meshsim/ -run Tunnel -count=1 -race` → PASS after Steps 3–5.

- [ ] **Step 7: Run all** `go vet ./... && go test ./... -count=1 -race` → all `ok`.

- [ ] **Step 8: Commit.**

```bash
git add proto/otter/v1/peer.proto internal/proto/otterv1/ internal/replication/ internal/transport/wss/ cmd/otter-node/main.go internal/meshsim/
oc -m "node: restore tunnel — a dial-out node relays a phone's TLS stream to a node abroad (limit 1)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 58: Android — restore through the dial-out node's tunnel (limit 1)

**Goal:** Password restore and «Добавить историю» reach nodes abroad directly or through each dial-out node's
`/tunnel`, with pinned TLS to the node abroad; dial-out nodes are never asked for a backup directly.

**Findings closed:** design limit 1 (app)

**Files:**
- Sync: proto (`peer.proto`; no app use) via `scripts/sync-proto.sh`
- Create: `otter-android/core/network/src/main/kotlin/app/ottermsg/core/network/TunnelSocket.kt`
- Modify: `core/network/.../Candidate.kt` (`via`), `Endpoints.kt` (`restoreCandidates`), `OkHttpTransport.kt` (tunnel connect)
- Modify: `core/data/.../backup/RestoreManager.kt:101-108,158-165` (`restoreCandidates`), `:91-96` (`map`: UNAVAILABLE → Network)
- Test: `core/network/src/test/.../TunnelConnectionTest.kt` (new), `EndpointsTest.kt` (cases)

**Acceptance Criteria:**
- [ ] `Endpoints.restoreCandidates(manifest, allowPlaintext)` = direct candidates of non-dial-out nodes + for every WSS endpoint of a dial-out node × every pinned, non-CDN WSS endpoint of a non-dial-out node a tunnel candidate (`url`/`pins` of the target, `via.url = "<via url>/tunnel?to=<hex target id>"`, `via.pins` of the dial-out endpoint); no direct candidate for a dial-out node.
- [ ] `OkHttpTransport.connect` of a tunnel candidate: WebSocket to `via` (pinned by `via.pins`), then OkHttp TLS **pinned to the target's pins** over that stream (no DNS lookup of the target, no pooling), then the WebSocket upgrade; closing the connection closes both.
- [ ] **Hostile:** a tunnel candidate whose stream ends at a server with another certificate fails the TLS handshake; a tunnel candidate without target pins is refused before connecting.
- [ ] Restore and «Добавить историю» use `restoreCandidates`; words restore keeps `candidates`.

**Verify:** `cd otter-android && ./gradlew :core:network:test --tests '*Tunnel*' --tests '*Endpoints*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing test** `core/network/src/test/kotlin/app/ottermsg/core/network/TunnelConnectionTest.kt`
  (check the `mockwebserver3` 5.2.1 names with `javap` on the jar — `MockResponse.Builder().webSocketUpgrade(listener)` — before writing):

```kotlin
package app.ottermsg.core.network

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import okio.ByteString
import okio.ByteString.Companion.encodeUtf8
import okio.ByteString.Companion.toByteString
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.net.Socket
import kotlin.concurrent.thread

class TunnelConnectionTest {
    private val heldF = HeldCertificate.Builder().addSubjectAlternativeName("f1.test").build()
    private val heldEvil = HeldCertificate.Builder().addSubjectAlternativeName("f1.test").build()
    private val f1 = MockWebServer()
    private val evil = MockWebServer()
    private val ru = MockWebServer()

    private fun tls(s: MockWebServer, h: HeldCertificate) {
        s.useHttps(HandshakeCertificates.Builder().heldCertificate(h).build().sslSocketFactory())
        s.enqueue(MockResponse.Builder().webSocketUpgrade(object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) { webSocket.send("hello".encodeUtf8()) }
        }).build())
        s.start()
    }

    /** The dial-out node: pipes the phone's WebSocket bytes to [target]'s TCP port (D114). */
    private fun relayTo(target: MockWebServer) {
        ru.enqueue(MockResponse.Builder().webSocketUpgrade(object : WebSocketListener() {
            lateinit var sock: Socket
            override fun onOpen(webSocket: WebSocket, response: Response) {
                sock = Socket(target.hostName, target.port)
                thread {
                    val buf = ByteArray(16384)
                    while (true) { val n = sock.getInputStream().read(buf); if (n < 0) break; webSocket.send(buf.toByteString(0, n)) }
                    webSocket.close(1000, null)
                }
            }
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) { sock.getOutputStream().write(bytes.toByteArray()); sock.getOutputStream().flush() }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { sock.close() }
        }).build())
        ru.start()
    }

    @After fun tearDown() { f1.close(); evil.close(); ru.close() }

    private fun candidate(target: MockWebServer, pins: List<ByteArray>) = Candidate(ByteArray(16) { 1 }, "f1 via ru",
        "wss://f1.test:${target.port}/x", "f1.test", pins, 0,
        via = Candidate(ByteArray(16) { 2 }, "ru", ru.url("/x").toString().replace("http", "ws") + "/tunnel?to=01", ru.hostName, emptyList(), 0))

    @Test fun pinnedTlsInsideTheTunnel() = runBlocking {
        tls(f1, heldF); relayTo(f1)
        val conn = OkHttpTransport().connect(candidate(f1, listOf(spkiPin(heldF.certificate))))
        assertEquals("hello", String(withTimeout(5_000) { conn.incoming.receive() }))
        conn.close()
    }

    @Test fun otherCertificateBehindTheTunnelFails() {
        tls(evil, heldEvil); relayTo(evil) // a hostile dial-out node sends the stream to a server of its own
        assertThrows(Exception::class.java) { runBlocking { OkHttpTransport().connect(candidate(evil, listOf(spkiPin(heldF.certificate)))) } }
    }

    @Test fun unpinnedTargetIsRefused() {
        relayTo(f1)
        assertThrows(IllegalArgumentException::class.java) { runBlocking { OkHttpTransport().connect(candidate(f1, emptyList())) } }
    }
}
```

  Run `./gradlew :core:network:test --tests '*Tunnel*'` → FAIL (no `via`).

- [ ] **Step 2: Implement** `Candidate`: add `val via: Candidate? = null` as the last constructor parameter;
  `key = (if (pinsKey.isEmpty()) url else "$url#$pinsKey") + (via?.let { "@" + it.key } ?: "")`.

  `TunnelSocket.kt`:

```kotlin
package app.ottermsg.core.network

import okhttp3.WebSocket
import okio.ByteString.Companion.toByteString
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.Socket
import java.net.SocketAddress
import java.net.SocketException
import java.net.SocketTimeoutException
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** A Socket whose bytes are binary WebSocket messages through a dial-out node's /tunnel (D114). OkHttp runs TLS over it. */
internal class TunnelSocket(private val ws: WebSocket, private val incoming: LinkedBlockingQueue<ByteArray>) : Socket() {
    companion object {
        val EOF = ByteArray(0)
        private const val CHUNK = 16 * 1024
        private const val MAX_QUEUED = 1L shl 20
    }
    @Volatile private var timeoutMs = 0
    @Volatile private var closed = false
    private var pending: ByteArray? = null
    private var pos = 0

    override fun connect(endpoint: SocketAddress?, timeout: Int) {} // already connected through the tunnel
    override fun connect(endpoint: SocketAddress?) {}
    override fun isConnected() = true
    override fun isClosed() = closed
    override fun isInputShutdown() = closed
    override fun isOutputShutdown() = closed
    override fun setSoTimeout(timeout: Int) { timeoutMs = timeout }
    override fun getSoTimeout() = timeoutMs
    override fun getInetAddress(): InetAddress = InetAddress.getByAddress("tunnel", ByteArray(4))
    override fun getPort() = 443
    override fun shutdownInput() {}
    override fun shutdownOutput() {}
    override fun close() { if (!closed) { closed = true; ws.close(1000, null); incoming.offer(EOF) } }

    private val input = object : InputStream() {
        override fun read(): Int { val b = ByteArray(1); return if (read(b, 0, 1) < 0) -1 else b[0].toInt() and 0xff }
        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (len == 0) return 0
            var cur = pending
            if (cur == null || pos >= cur.size) {
                cur = if (timeoutMs > 0) incoming.poll(timeoutMs.toLong(), TimeUnit.MILLISECONDS) ?: throw SocketTimeoutException("tunnel read timed out")
                      else incoming.take()
                if (cur === EOF) { incoming.offer(EOF); return -1 }
                pending = cur; pos = 0
            }
            val n = minOf(len, cur.size - pos)
            System.arraycopy(cur, pos, b, off, n)
            pos += n
            return n
        }
    }

    private val output = object : OutputStream() {
        override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)
        override fun write(b: ByteArray, off: Int, len: Int) {
            var o = off
            while (o < off + len) {
                if (closed) throw SocketException("tunnel closed")
                while (ws.queueSize() > MAX_QUEUED) Thread.sleep(5) // back-pressure: OkHttp fails a socket past 16 MiB queued
                val n = minOf(CHUNK, off + len - o)
                if (!ws.send(b.toByteString(o, n))) throw SocketException("tunnel closed")
                o += n
            }
        }
    }

    override fun getInputStream(): InputStream = input
    override fun getOutputStream(): OutputStream = output
}
```

  `OkHttpTransport.connect`: move the current body into `private suspend fun openWebSocket(client: OkHttpClient, url: String): Connection`
  and make `connect` = `if (candidate.via != null) connectVia(candidate) else openWebSocket(clientFor(candidate), candidate.url)`:

```kotlin
    /** D114: WebSocket to the dial-out node's /tunnel, then pinned TLS to the target inside it. */
    private suspend fun connectVia(c: Candidate): Connection {
        val via = checkNotNull(c.via)
        require(c.pins.isNotEmpty()) { "a tunnel target must be pinned" }
        val queue = LinkedBlockingQueue<ByteArray>()
        val outer = suspendCancellableCoroutine<WebSocket> { cont ->
            val ws = clientFor(via).newWebSocket(Request.Builder().url(via.url).build(), object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) { if (cont.isActive) cont.resume(webSocket) }
                override fun onMessage(webSocket: WebSocket, bytes: ByteString) { queue.offer(bytes.toByteArray()) }
                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(1000, null); queue.offer(TunnelSocket.EOF) }
                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { queue.offer(TunnelSocket.EOF) }
                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    queue.offer(TunnelSocket.EOF)
                    if (cont.isActive) cont.resumeWithException(t)
                }
            })
            cont.invokeOnCancellation { ws.cancel() }
        }
        val sock = TunnelSocket(outer, queue)
        val tm = PinnedTrustManager(c.pins)
        val inner = base.newBuilder()
            .socketFactory(object : SocketFactory() {
                override fun createSocket(): Socket = sock
                override fun createSocket(host: String?, port: Int): Socket = sock
                override fun createSocket(host: String?, port: Int, localHost: InetAddress?, localPort: Int): Socket = sock
                override fun createSocket(host: InetAddress?, port: Int): Socket = sock
                override fun createSocket(address: InetAddress?, port: Int, localAddress: InetAddress?, localPort: Int): Socket = sock
            })
            .dns { host -> listOf(InetAddress.getByAddress(host, ByteArray(4))) } // never resolve the target (it may be blocked)
            .proxy(Proxy.NO_PROXY)
            .connectionPool(ConnectionPool(0, 1, TimeUnit.SECONDS))
            .sslSocketFactory(tm.sslContext().socketFactory, tm)
            .build()
        return try { openWebSocket(inner, c.url) } catch (e: Throwable) { sock.close(); throw e }
    }
```

  (`require` throws before any network use for an unpinned target, which the test expects. Imports:
  `javax.net.SocketFactory`, `java.net.Socket`, `java.net.InetAddress`, `java.net.Proxy`, `okhttp3.ConnectionPool`,
  `java.util.concurrent.LinkedBlockingQueue`.)

  `Endpoints.restoreCandidates`:

```kotlin
    /**
     * Password restore (D113/D114): nodes abroad directly, plus the same nodes through every dial-out node's tunnel.
     * A dial-out node keeps no backups, so it is never a direct candidate here.
     */
    fun restoreCandidates(manifest: Manifest, allowPlaintext: Boolean): List<Candidate> {
        val all = candidates(manifest, allowPlaintext)
        fun isNode(c: Candidate, dialOut: Boolean) = manifest.nodesList.any { it.dialOutOnly == dialOut && it.nodeId.toByteArray().contentEquals(c.nodeId) }
        val direct = all.filter { isNode(it, dialOut = false) }
        val vias = all.filter { isNode(it, dialOut = true) }
        val targets = manifest.nodesList.filter { !it.dialOutOnly }.flatMap { n ->
            n.endpointsList.filter { it.kind == Endpoint.Kind.WSS && it.tlsSpkiPinsCount > 0 && !it.viaCdn }.map { n to it }
        }
        val tunnels = vias.flatMap { v ->
            targets.map { (n, e) ->
                val host = if (':' in e.host) "[${e.host}]" else e.host
                Candidate(nodeId = n.nodeId.toByteArray(), label = "${n.label} via ${v.label}", url = "wss://$host:${e.port}${e.path}",
                    host = e.host, pins = e.tlsSpkiPinsList.map { it.toByteArray() }, priority = v.priority + 1000,
                    via = Candidate(v.nodeId, v.label, "${v.url}/tunnel?to=${n.nodeId.toByteArray().joinToString("") { "%02x".format(it) }}",
                        v.host, v.pins, v.priority))
            }
        }
        return direct + tunnels
    }
```

  `EndpointsTest`: a manifest with node `ru` (dial_out_only, WSS pinned) and `f1` (WSS pinned) and `f2` (WSS via_cdn,
  no pins) → `restoreCandidates` = [f1 direct, f2 direct, f1 via ru]; none with `nodeId == ru` and `via == null`.

- [ ] **Step 3: Restore.** `RestoreManager.withPassword` and `addHistory`: `Endpoints.restoreCandidates(...)` instead
  of `Endpoints.candidates(...)`; `map()` treats `STATUS_UNAVAILABLE` as `RestoreError.Network` (already the `else`;
  add a comment). Extend `RestoreFlowTest` only if its fake connector inspects candidates (read it first).

- [ ] **Step 4: Run** `./gradlew :core:network:test :core:data:testDebugUnitTest` → `BUILD SUCCESSFUL`.

- [ ] **Step 5: Commit.**

```bash
git add core/proto core/network core/data
oc -m "app: restore through a dial-out node's tunnel with TLS pinned to the node abroad (limit 1)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 59: Release server 0.10.0 + app 0.10.0 and rollout; ru-1 may join after this (each step asked first)

**Goal:** M9.3 runs on every node and phone; the v2 cut-over is published once all phones run 0.10.0; ru-1 may then
join as a dial-out node.

**Findings closed:** none (delivery of C7, limits 1 and 2)

**Files:** `otter-server/cmd/otter-node` version via `make release VERSION=0.10.0`; `otter-android/app/build.gradle.kts:35`
(`versionCode = 13; versionName = "0.10.0"`); `docs/00-decisions.md` (D109–D114 with real numbers), `docs/09-roadmap.md`
(M9.3 done), `otter-server/dist/news/0.10.0.md` (news draft, new file). Server state, `~/.otter-admin` and phones are not in git.

**Acceptance Criteria:**
- [ ] All three repos: tests green, `scripts/secrets-check.sh` ok, owner's OK, merged `--no-ff` from `m9-3-network`.
- [ ] Every node on 0.10.0 (`deploy/status.sh`); each foreign node has its WSS TLS certificate (the tunnel listener is served only then).
- [ ] App 0.10.0 announced; a v1 manifest with `min_app_version = 13` published; every phone on 0.10.0 (owner checks).
- [ ] Cut-over manifest published (`--sig-v1-until` = publish + 48 h); messages, photos and group changes still flow between all phones afterwards.
- [ ] ru-1 may now join with `dial_out_only`: backups uploaded on it disappear from it after handoff; a password restore on a phone in Russia succeeds through its tunnel.

**Verify:** `deploy/status.sh` → every node `0.10.0`; on a phone after the cut-over, «Журнал подключений» shows no
signature errors and a test message both ways arrives.

**Steps (ask before each; passphrases only in the owner's terminal):**

- [ ] **Step 1:** Run `go vet ./... && go test ./... -count=1 -race` (server), `./gradlew testDebugUnitTest
  assembleRelease` (app), `scripts/secrets-check.sh` in all three repos. Write the D-entries and the news draft
  (ru/en: «Ключ безопасности изменился» explained, restore through ru-1, nothing to do for users). Ask for the merge.
- [ ] **Step 2 (ask):** `make release VERSION=0.10.0`, then `deploy/upgrade-all.sh 0.10.0 --no-news` — each node
  health-checked. Nodes still sign v1 (no cut-over yet), so mixed 0.9.x/0.10.0 nodes interoperate during the upgrade.
- [ ] **Step 3 (owner runs):** `deploy/release-apk.sh 0.10.0 <release APK>` → news dialog with `dist/news/0.10.0.md`.
  Then `otter-admin manifest sign` with `min_app_version` 13 (the existing way of setting it) and `manifest publish`
  — still v1-signed, so 0.9.x phones accept it and see the update prompt.
- [ ] **Step 4 (owner):** confirm every family phone shows 0.10.0 (Settings → О приложении). Do not continue before.
- [ ] **Step 5 (ask; owner types the passphrase):** `otter-admin manifest sign --sig-v1-until <now + 48 h, RFC 3339>`
  and `otter-admin manifest publish`. Check on two phones: send a message both ways, a photo, a group message.
- [ ] **Step 6 (optional, ask):** re-key drill on the dev mesh only (`.dev-mesh`, two emulators): `user rekey … --old`,
  register on the second emulator, `--new`; the first emulator shows «Ключ безопасности изменился» and the chat
  continues; a group swaps the member.
- [ ] **Step 7 (ask, later):** ru-1 joins (M7 Task 13 procedure with `node set-dial-out-only --label ru-1`, `manifest
  sign`, `manifest publish`). Acceptance on a phone in Russia: back up on ru-1, wait for «backup handed off» in
  ru-1's journal, then restore on a spare phone through ru-1 (`net_log` shows `<abroad> via ru-1`).

---

**Owner questions**

1. **v2 signing starts at the cut-over, not at install (D109).** 0.9.x phones would drop v2-signed messages and
   directory entries, so 0.10.0 only *accepts* v2 until you publish the cut-over manifest after every phone runs
   0.10.0. *Recommended: yes, as written.*
2. **Cut-over margin.** `sig_v1_until_ms` = publish time + 48 h, so a phone that was offline when the manifest came
   still has its queued v1 messages accepted for two days. *Recommended: 48 h.*
3. **Handoff confirmations (D113).** A dial-out node deletes a backup after `min(2, foreign nodes)` foreign nodes hold
   it; with only eeee abroad that is 1 — if eeee is hostile the backup is at its mercy anyway. *Recommended: 2 when
   available.*
4. **Re-key in two admin steps with the account code read aloud (D111).** One step is impossible (the new account's id
   does not exist yet), and a link-only flow would let whoever intercepts the invite become the account. *Recommended:
   two steps; the person reads «Код аккаунта» to you by phone or in person.*
5. **History of the re-keyed person.** Their own phone history is not recovered (the backup belongs to the revoked
   key); contacts keep the chats. *Recommended: accept for now.*
6. **Tunnel vs. "restore only abroad".** The tunnel is ≈ 500 lines total; without it nobody in Russia can restore
   without a VPN. *Recommended: build the tunnel; Task 56 can ship earlier on its own.*

---

## M9.4 — Operations hardening

Branch `m9-4-ops` in `otter-server`, `otter-android` and `docs`; server **0.10.1**, app **0.10.1 / versionCode 14**.
Runs after M9.3 (and after ru-1 has joined). Nothing in this phase changes the protocol: old apps and nodes keep working.

**Proto additions:** none (no new fields, messages or RPCs). Limits answer with the existing `STATUS_RETRY_LATER`
("too many requests", "node storage low") and `STATUS_QUOTA`.

**Coordinator notes (clash checks):**
- **Store migration** `otter-server/internal/store/migrations/0016_records_author.sql` (one index). The number assumes
  M9.0–M9.3 add at most 0009–0011; rename it to the next free number when merging the sections (migrations run in
  file-name order, so it only has to sort after the others).
- **`SecureWindow`** (FLAG_SECURE) moves from `feature/onboarding` to `core/ui` with a hold counter in Task 68. M9.1 C22
  adds it to the backup-password and restore screens: if M9.1 copied the composable, Task 68 replaces those copies too
  (Step 1 greps for them).
- **Username clash (D31)** is assumed fully covered by M9.2 C12 (`name#abcd` display, `#abcd` tag at restore). This
  section adds **no rename screen** (D122, owner question 1).
- **Revocation** (M9.2 Tasks 30–39) is not touched here; the per-user limits key on the logged-in user id only.
- `deploy/status.sh` gains a `--status--` block; if another section also edits `status.sh`, merge both remote command
  lists (one SSH call per node stays the rule, M7 notes).

**Already done (checked, not planned again):**

| Roadmap item | State | Source |
|---|---|---|
| WebSocket ping 30 s (server → phone) | Done since the M8 fix: `Gateway.PingInterval 30 s`, `PingTimeout 60 s`, `session.keepalive` | `internal/gateway/gateway.go:27-43`, `session.go:81-111`, `keepalive_test.go` |
| Revocation (`otter-admin user revoke/list`, groups drop revoked members) | M9.2 Tasks 30–39 | brief |
| Blob quota per author (2 GiB) + persistent-blob limit | Exists (D44, D50); made atomic by M9.2 C9 | `internal/service/blobs.go:78-97` |
| Per-author budgets for PREKEYS / PUSH_TOKEN / INVITE | M9.2 C8 | spec M9.2 |
| `otter-node stats`, netlog in `status.sh` | Exist; extended here | `cmd/otter-node/main.go:242-253`, `deploy/status.sh` |
| systemd hardening basics | Partly: `NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`, `PrivateDevices`, `RestrictAddressFamilies` (with `AF_NETLINK` for TURN), `CapabilityBoundingSet=CAP_NET_BIND_SERVICE`, `ReadWritePaths=/var/lib/otter`; offline exposure **3.8** | `deploy/templates/otter-node.service` |

**Verified facts:**

| Question | Answer | Source |
|---|---|---|
| Replication session keep-alive | **None.** `session.run` reads frames; `serve` idles on `Changed()` or a 1-min safety timer (`session.go:146-163`) and sends nothing; a silently dead TCP link keeps the session in the registry, so `dialMissing` never redials. REALITY tunnels compensate with a 24 h Xray idle timeout (D72) | `internal/replication/session.go:57-117,146-163`, D72 |
| Concurrent ping on a coder/websocket conn | `Conn.Ping(ctx)` is safe next to `Write`; the pong is processed by the concurrent `Read` (in `run`) — same pattern as the gateway | `gateway/session.go:83-111` |
| What a peer confirms of our oplog | `PeerSubscribe.cursor` (on connect) and `PeerBatchAck.seq` (per batch) = highest seq of ours the peer has stored → backlog = our head − that | `session.go:66,82-86,206-208` |
| netlog API | `netlog.Entry{Peer, Endpoint, Direction, Result, Detail; Class}`, `Logger.Add`, `netlog.Result(class)`, `netlog.Classify(err, n)` (`context.DeadlineExceeded` → `timeout`) | `internal/netlog/netlog.go` |
| Per-IP limits today | **None**: `wss.NewServer` mounts the mux directly; `http.Server{ReadHeaderTimeout: 10s}` only. `RemoteAddr` is the client for WSS; for REALITY it is `127.0.0.1` (internal listener, `startReality`) | `internal/transport/wss/server.go`, `cmd/otter-node/main.go:391-412` |
| Status codes the phone already handles | `msg.send`: QUOTA is retried with backoff (only INVALID/NOT_FOUND/REVOKED drop); `blob.create/put`: QUOTA/INVALID fail the photo, RETRY_LATER backs off; restore: RETRY_LATER + "too many" → «Слишком много попыток» | `Outbox.kt:88`, `MediaTransfers.kt:114,186`, `RestoreManager.kt:92-93` |
| Envelope storage | An ENVELOPE row in `records` lives until the last mailbox row is acked (`typed.go:185`) or 30 days / record expiry (janitor) → `SUM(length(raw))` over the author's ENVELOPE rows = undelivered bytes. No index on `records(author)` | `internal/store/typed.go:185`, `migrations/0001_init.sql:3-5` |
| Free-space checks | **None** anywhere (`grep Statfs` empty). Blob chunks: `Service.StoreChunk` is the single write path for uploads and the puller | `internal/service/blobs.go:129-156`, `replication/blobs.go:116-189` |
| Stats for a separate process | Pattern: running node writes `<data_dir>/turn.stats.json` every 10 s, `otter-node stats` reads it if < 60 s old | `internal/turnsrv/stats.go`, `main.go:242-253` |
| Push outcomes | Only logged (`push sent`, `push failed`, `push token unregistered`); no counters | `internal/push/pusher.go:82-92` |
| Unit rollout | `upgrade.sh` swaps only the binary; the unit file is installed only by `bundle/install.sh` (fresh install) → existing nodes need a separate unit step | `deploy/upgrade.sh`, `deploy/bundle/install.sh:49` |
| `systemd-analyze security --offline=true` | Works on the dev PC (systemd 259) without the server: current unit **3.8**, prototype of Task 66 **1.5**; current backup unit **9.0 UNSAFE**, prototype **0.5**; `--threshold=20` exits 1 above 2.0 | run 2026-11-14 |
| `PrivateUsers=` | Not usable: with `CAP_NET_BIND_SERVICE` for REALITY on :443 (D72) the capability must be held in the host user namespace | D72, systemd.exec(5) |
| Android biometric | `androidx.biometric:biometric` stable **1.1.0** (1.4.0-beta01 is from 2026-11-04, < 2 weeks); `BiometricPrompt` needs a `FragmentActivity` → `MainActivity` (now `ComponentActivity`) changes base class; `androidx.fragment:fragment 1.9.1` (2026-09-23) pinned so 1.1.0 does not pull fragment 1.2.5 | Google Maven metadata, `MainActivity.kt:46` |
| FLAG_SECURE today | `internal fun SecureWindow()` in `PhraseScreen.kt:46-54` adds the flag and **clears it on dispose** → an app-wide setting would be switched off by leaving that screen | `feature/onboarding/.../PhraseScreen.kt` |
| Theme setting | `OtterTheme(mode: ThemeMode = SYSTEM)` exists, nothing stores or passes a mode | `core/ui/.../Theme.kt:36-47`, `MainActivity.kt:53` |
| Settings storage | Key/value table `settings` in the SQLCipher DB; `SettingsDao` has get/put/observe, **no delete** | `core/data/.../settings/Settings.kt`, `SettingsDao.kt` |
| Endpoint history on the phone | `EndpointStatDao.all()`; key = `Candidate.key` (`url` or `url#pinsHash`); `ManifestUpdater.candidates(allowPlaintext)` lists label/host/url | `EndpointStatDao.kt`, `Candidate.kt`, `ManifestUpdater.kt:59-70` |
| Deploy VM test infra | `deploy/test/vm.sh` (Debian 12 qcow2, `OTTER_VM`, ports), `e2e-mesh.sh` (2 VMs) | `deploy/test/` |
| Private names in public repos | Other services on shared hosts must never be named in a repo (history scrub 2026-11-14, `~/.otter-private-words` in `secrets-check.sh`) → this plan names only port numbers in the owner's private notes, never products | memory, `scripts/secrets-check.sh` |

**Decisions to record:**

- **D115 Replication keep-alive.** Each peer session sends a WebSocket ping every **25 s**; no pong within **60 s**
  closes the session (≤ 85 s to notice a dead link; the timeout is long because the read loop may be busy with an
  8 MiB batch on a throttled link). A failure writes one netlog line `endpoint = ping`, direction `out` (we dialed)
  or `in`, class from `Classify` (normally `timeout`), merged by the D74 rule, and counts in
  `otter_peer_ping_failures_total`. Successful pings are not logged. Old peers answer pings automatically (WebSocket
  control frames), so no version gate. D72's "peer sessions have no keep-alive" no longer holds; the 24 h REALITY
  idle timeout stays (harmless).
- **D116 Connection and request limits.** Per source IP (loopback exempt: the REALITY inner listener): **32
  concurrent** HTTP/WebSocket connections and **30 new per minute (burst 20)** → HTTP 429 before the upgrade;
  **50 requests/s (burst 500)** on client sessions; the public methods `register`, `auth.login`, `backup.auth`,
  `backup.fetch`, `manifest.publish`, `news.publish` **20/min (burst 20)**. Per logged-in user, the write methods
  `msg.send`, `prekeys.upload`, `invite.create`, `push.register`, `directory.update`, `backup.publish`,
  `blob.create`: **burst 300, then 1/s** (an outbox flush after a week offline still goes out at once). Over a rate
  limit → `STATUS_RETRY_LATER` "too many requests". Config: `[limits] conns_per_ip`, `requests_per_ip`. Counted in
  `otter_rejected_total{kind}`. Peer sessions are limited only by `conns_per_ip` (an authenticated peer opens one).
- **D117 Undelivered-message quota.** Per author per node: undelivered ENVELOPE bytes ≤ **256 MiB**
  (`[limits] user_pending`); over → `STATUS_QUOTA` (the phone's outbox retries with backoff). Checked and applied
  under a per-author lock on submit only; replicated envelopes are not refused for quota (each node checks its own
  submissions; the disk floor bounds the rest).
- **D118 Disk floor.** `[limits] disk_floor` (default **1 GiB**) of free space under `data_dir`, measured every 10 s
  (`statfs`, available to unprivileged users). Below the floor (**low**): no new blobs, chunk uploads, chunk pulls or
  backups (`STATUS_RETRY_LATER` "node storage low"); messages flow. Below floor/4 (**critical**): also no client
  submissions (`msg.send`, `register`, `directory.update`, …). Below **64 MiB** (**full**): replicated records are
  refused too (the peer session ends without advancing the cursor and redials in 30 s). Small replicated records
  keep flowing until "full", so directory, revocations and manifests stay current. Every change of level is logged
  (warn) and shown by `otter-node status` / `deploy/status.sh`.
- **D119 Monitoring.** The running node writes `<data_dir>/status.json` every **15 s** and serves Prometheus text on
  **`127.0.0.1:9477/metrics`** (`[metrics] listen`, loopback only, `"off"` disables; never opened in a firewall).
  `otter-node status [--line|--json]` reads only `status.json` (no database, safe as root or `otter`). Metrics:
  client sessions, users, records, oplog head, blob bytes, per peer connected / caught up / backlog / lag seconds /
  ping failures, disk free/total/level, push sent/failed/unregistered, TURN allocations and relayed bytes, rejections
  by kind. **Problems** (printed with `! `, make `status.sh` exit 1): status older than 60 s; a peer down for > 10 min
  (or never up 10 min after start); a peer lag > 10 min; disk level not ok; ≥ 3 push failures and none sent since
  start. A hostile peer can lie in its acks; that only affects our numbers.
- **D120 Host hardening.** `otter-node.service` adds `UMask=0077`, `PrivateIPC`, `ProtectKernelLogs`, `ProtectClock`,
  `ProtectHostname`, `ProtectProc=invisible`, `ProcSubset=pid`, `RestrictRealtime`, `RestrictSUIDSGID`, `RemoveIPC`,
  `SystemCallFilter=@system-service`, `SystemCallFilter=~@privileged @resources`, `SystemCallErrorNumber=EPERM`
  (offline exposure **3.8 → 1.5**); `otter-backup.service` gets the same plus `PrivateNetwork`,
  `CapabilityBoundingSet=` (**9.0 → 0.5**). Not used: `PrivateUsers` (breaks `CAP_NET_BIND_SERVICE` on :443),
  `PrivateNetwork`/`IPAddressDeny` for the node. Existing nodes get the units with `deploy/sandbox-setup.sh` (rollback
  on a failed health check; `upgrade-all.sh` runs it for 0.10.1+ unless `--no-sandbox`). `deploy/harden-check.sh`
  is **read-only**: SSH (`sshd -T`), unattended-upgrades, pending reboot, firewall, public listeners not owned by
  `otter-node`/`sshd`, metrics bound to loopback, unit exposure ≤ 2.0, key-file and binary ownership, `otter` user
  without shell or sudo, NTP. It changes nothing; fixes on a server are separate, asked-for steps. On a shared host
  every non-Otter public listener is a decision of the owner, recorded only in `~/Documents/otter-private`.
- **D121 App lock.** Settings → Безопасность → «Блокировка приложения»: PIN of 4–8 digits (Argon2id m 16 MiB, t 2,
  p 1, 16-byte salt, stored in the encrypted DB), optional fingerprint/face (`BIOMETRIC_STRONG`), «Блокировать»
  сразу / через 1 мин (default) / 5 мин / 30 мин after the app leaves the screen. 5 free tries, then 30 s doubling
  up to 15 min (persisted). Forgotten PIN: «Забыли PIN?» → the phone's own screen lock (device credential) turns the
  app lock off. While the lock is on: message notifications show only «Otter / Новое сообщение» and have no «Ответить»
  action; the recents thumbnail is hidden (API 33+ `setRecentsScreenshotEnabled(false)`, older: FLAG_SECURE while
  locked). Incoming calls ring and can be answered without the PIN (the call screen is `CallActivity`); the chats
  are not reachable from it. «Запрет скриншотов» (FLAG_SECURE app-wide, default off) is independent of the lock.
- **D122 Username rename (D31) dropped.** M9.2 C12 already shows the loser as `name#abcd` everywhere and asks for the
  tag at restore. A rename would add a username-change path that M9.2's rank-by-redemption rule does not cover;
  rare (clashes need a partition at registration time); V1.x if ever needed. *(Owner question 1.)*
- **D123 Network status and battery.** Settings → Подключение → «Состояние сети» shows: the current state (node
  label, transport, since when or next retry), the phone's network (Wi-Fi / mobile + operator), every node of the
  manifest with each endpoint's last success, last failure, RTT and «понижен до …» (D73), the notification mode
  (D61) with the last push wake-up, battery optimisation state with «Не ограничивать Otter»
  (`ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, permission `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`; the APK is not
  on Google Play) and «Автозапуск и фон» (app details page) for vendors that kill background apps, and the
  «Журнал подключений» row (moved here). Nothing new leaves the phone.
- **D124 Settings polish.** Order per guide §10: Профиль, Семья, Уведомления, **Оформление** (new: Как на устройстве
  / Светлая / Тёмная, stored, applied at once), Фото и память, **Безопасность** (Блокировка приложения, Запрет
  скриншотов, Резервная копия, **Фраза восстановления** — new: the 24 words after the phone's screen lock, with
  FLAG_SECURE), **Подключение** (status row → «Состояние сети», «Звонки только через сервер», full-screen-call
  row), then the version footer. «Журнал подключений» moves into «Состояние сети». Section «Медиа» is renamed to
  «Фото и память» per the guide (one row today).

---

### Task 60: Server — replication keep-alive ping with netlog

**Goal:** A peer session whose link died silently, or whose peer stops answering, ends within 85 s and leaves a
`ping` line in the connectivity log, so the node redials.
**Findings closed:** M9 roadmap "replication keep-alive ping (25 s) with netlog"; threat-model item 3 (a hostile
peer that stops reading can no longer pin a session open forever).

**Files:**
- Modify: `otter-server/internal/replication/session.go` (new `keepalive`, start it in `run` after `go s.writeLoop()` at line 63)
- Modify: `otter-server/internal/replication/replicator.go` (`peerSeen` map, `notePingFail`, `SetTestTimings` lines 147-151)
- Test: `otter-server/internal/replication/keepalive_test.go` (new)

**Acceptance Criteria:**
- [ ] A session over a connection that stops reading and writing ends on both nodes within `peerPing + peerPingTimeout`.
- [ ] Each node that noticed writes a netlog entry `Endpoint "ping"`, `Class timeout`, direction `out` on the dialer, `in` on the acceptor.
- [ ] A healthy session survives ≥ 10 ping intervals (same `*session`).
- [ ] After the drop, the nodes reconnect (a new session object appears).

**Verify:** `cd otter-server && go test ./internal/replication/ -run 'Keepalive' -count=3 -race` → `ok`

**Steps:**

- [ ] **Step 1: Branches.** In `otter-server`, `otter-android` and `docs`: `git switch main && git pull --ff-only && git switch -c m9-4-ops`.

- [ ] **Step 2: Failing test** `internal/replication/keepalive_test.go`

```go
package replication

import (
	"context"
	"net"
	"net/http"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"ottermsg/server/internal/netlog"
	pb "ottermsg/server/internal/proto/otterv1"
)

type recLog struct {
	mu sync.Mutex
	es []netlog.Entry
}

func (r *recLog) Add(_ context.Context, e netlog.Entry) { r.mu.Lock(); r.es = append(r.es, e); r.mu.Unlock() }
func (r *recLog) find(endpoint string) *netlog.Entry {
	r.mu.Lock()
	defer r.mu.Unlock()
	for i := range r.es {
		if r.es[i].Endpoint == endpoint {
			e := r.es[i]
			return &e
		}
	}
	return nil
}

// freezeConn plays a peer whose host vanished (or that stops answering on purpose): after freeze nothing is read
// or written, no FIN is sent, until Close.
type freezeConn struct {
	net.Conn
	frozen chan struct{}
	closed chan struct{}
	fOnce  sync.Once
	cOnce  sync.Once
}

func (c *freezeConn) freeze() { c.fOnce.Do(func() { close(c.frozen) }) }
func (c *freezeConn) block() error {
	select {
	case <-c.frozen:
		<-c.closed
		return net.ErrClosed
	default:
		return nil
	}
}
func (c *freezeConn) Read(p []byte) (int, error) {
	if err := c.block(); err != nil {
		return 0, err
	}
	n, err := c.Conn.Read(p)
	if err == nil {
		if err := c.block(); err != nil {
			return 0, err
		}
	}
	return n, err
}
func (c *freezeConn) Write(p []byte) (int, error) {
	if err := c.block(); err != nil {
		return 0, err
	}
	return c.Conn.Write(p)
}
func (c *freezeConn) Close() error { c.cOnce.Do(func() { close(c.closed) }); return c.Conn.Close() }

// freezeDialer dials WS_PLAIN endpoints like NetDialer and can freeze every connection it made so far.
type freezeDialer struct {
	mu    sync.Mutex
	conns []*freezeConn
}

func (d *freezeDialer) freezeAll() {
	d.mu.Lock()
	defer d.mu.Unlock()
	for _, c := range d.conns {
		c.freeze()
	}
}

func (d *freezeDialer) Dial(ctx context.Context, n *pb.NodeInfo) (*websocket.Conn, error) {
	ep := n.Endpoints[0]
	url := "ws://" + net.JoinHostPort(ep.Host, strconv.Itoa(int(ep.Port))) + ep.Path + "/peer"
	hc := &http.Client{Transport: &http.Transport{DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
		c, err := (&net.Dialer{}).DialContext(ctx, network, addr)
		if err != nil {
			return nil, err
		}
		fc := &freezeConn{Conn: c, frozen: make(chan struct{}), closed: make(chan struct{})}
		d.mu.Lock()
		d.conns = append(d.conns, fc)
		d.mu.Unlock()
		return fc, nil
	}}}
	dctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	c, _, err := websocket.Dial(dctx, url, &websocket.DialOptions{HTTPClient: hc})
	if err != nil {
		return nil, err
	}
	c.SetReadLimit(maxFrame)
	return c, nil
}

func sessionOf(nd *tnode, peer []byte) *session {
	nd.repl.reg.mu.Lock()
	defer nd.repl.reg.mu.Unlock()
	return nd.repl.reg.byPeer[string(peer)]
}

func TestKeepaliveDropsFrozenPeerAndLogs(t *testing.T) {
	m := newMesh(t, 2, false)
	fd := &freezeDialer{}
	logs := &recLog{}
	for _, nd := range m.nodes {
		nd.gate.inner = fd // whichever side wins the duplicate-session race, its link can be frozen
		nd.repl.nlog = logs
	}
	m.start()
	eventually(t, "session up", func() bool { return sessionOf(m.nodes[0], m.nodes[1].id) != nil })
	old := sessionOf(m.nodes[0], m.nodes[1].id)
	fd.freezeAll()
	eventually(t, "ping failure in the netlog", func() bool { return logs.find("ping") != nil })
	e := logs.find("ping")
	if e.Class != netlog.Timeout || e.Result != "fail" || (e.Direction != "in" && e.Direction != "out") {
		t.Fatalf("netlog entry %+v", e)
	}
	eventually(t, "a new session after the drop", func() bool {
		s := sessionOf(m.nodes[0], m.nodes[1].id)
		return s != nil && s != old
	})
}

func TestKeepaliveKeepsHealthySession(t *testing.T) {
	m := newMesh(t, 2, false)
	m.start()
	eventually(t, "session up", func() bool { return sessionOf(m.nodes[0], m.nodes[1].id) != nil })
	s := sessionOf(m.nodes[0], m.nodes[1].id)
	time.Sleep(10 * peerPing)
	if sessionOf(m.nodes[0], m.nodes[1].id) != s {
		t.Fatal("a healthy session was replaced")
	}
}
```

- [ ] **Step 3: Run — fails.** `go test ./internal/replication/ -run Keepalive -count=1` → compile error `undefined: peerPing`;
  after adding only the variables, `TestKeepaliveDropsFrozenPeerAndLogs` fails with "timed out waiting for ping failure in the netlog".

- [ ] **Step 4: Implement.** In `session.go`:

```go
// Peer keep-alive (D115): a WebSocket ping every peerPing; no pong within peerPingTimeout ends the session. The pong
// is read by run()'s read loop, which may be busy with an 8 MiB batch on a throttled link, hence the long timeout.
var (
	peerPing        = 25 * time.Second
	peerPingTimeout = 60 * time.Second
)

// keepalive ends the session when the peer stops answering pings, and logs it (netlog endpoint "ping").
func (s *session) keepalive() {
	t := time.NewTicker(peerPing)
	defer t.Stop()
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-t.C:
		}
		ctx, cancel := context.WithTimeout(s.ctx, peerPingTimeout)
		err := s.c.Ping(ctx)
		cancel()
		if err == nil {
			continue
		}
		if s.ctx.Err() != nil {
			return // the session ended anyway
		}
		dir := "in"
		if bytes.Equal(s.dialer, s.r.svc.NodeID) {
			dir = "out"
		}
		class := netlog.Classify(err, 0)
		s.r.notePingFail(s.peer)
		s.r.log.Info("peer ping failed", "peer", fmt.Sprintf("%x", s.peer), "err", err)
		s.r.nlog.Add(s.r.baseCtx(), netlog.Entry{Peer: s.r.labelOf(s.peer), Endpoint: "ping", Direction: dir,
			Result: netlog.Result(class), Class: class, Detail: fmt.Sprintf("no pong within %s", peerPingTimeout)})
		s.close()
		return
	}
}
```

  Add imports `bytes` and `ottermsg/server/internal/netlog`. In `run()` after `go s.writeLoop()` add `go s.keepalive()`.
  In `replicator.go` add to `Replicator`:

```go
	seenMu sync.Mutex
	seen   map[string]*peerSeen // per peer node id: monitoring state that outlives sessions (D115, D119)
```

```go
// peerSeen is what monitoring needs to know about a peer across sessions.
type peerSeen struct {
	pingFails int64
}

func (r *Replicator) peer(id []byte) *peerSeen { // callers hold seenMu
	if r.seen == nil {
		r.seen = map[string]*peerSeen{}
	}
	p := r.seen[string(id)]
	if p == nil {
		p = &peerSeen{}
		r.seen[string(id)] = p
	}
	return p
}

func (r *Replicator) notePingFail(id []byte) { r.seenMu.Lock(); r.peer(id).pingFails++; r.seenMu.Unlock() }
```

  In `SetTestTimings` add `peerPing, peerPingTimeout = 2*dial, 5*dial` (200 ms / 500 ms with the package's
  `TestMain`). `meshsim` calls `SetTestTimings` too (`grep -rn SetTestTimings internal/meshsim`): its pings then run
  every 2×dial, which is fine for live sessions.

- [ ] **Step 5: Run** `go test ./internal/replication/ -run Keepalive -count=3 -race` → `ok`; then
  `go test ./internal/replication/ ./internal/meshsim/ -count=1 -race` → `ok`.

- [ ] **Step 6: Commit**

```bash
git add internal/replication/session.go internal/replication/replicator.go internal/replication/keepalive_test.go
oc -m "replication: ping peers every 25 s, drop silent sessions after 60 s and log them (M9.4)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 61: Server — disk floor

**Goal:** A node whose disk fills refuses bulk writes first, then client writes, and keeps replicating small records
until 64 MiB are left, instead of failing SQLite writes or stopping.
**Findings closed:** M9 roadmap "disk free-space floor"; threat-model item 3 (a hostile peer or member pushing large
data cannot break the node's database).

**Files:**
- Create: `otter-server/internal/service/disk.go`
- Modify: `otter-server/internal/service/service.go` (field `Disk *DiskGuard` in `Service`, lines 60-80)
- Modify: `otter-server/internal/service/blobs.go` (`CreateBlob` line 49, `StoreChunk` line 129), `backup.go` (`PublishBackup` line 118),
  `submit.go` (`Submit`), `directory.go` (`UpdateDirectoryEntry`), `register.go` (`Register` line 17), `replicated.go` (`ApplyReplicated` line 16)
- Modify: `otter-server/internal/config/config.go` (`Limits.DiskFloor`, `DiskFloorBytes`), `cmd/otter-node/main.go` (`open`, `serve`)
- Modify: `otter-server/deploy/templates/node.toml` (commented default)
- Test: `otter-server/internal/service/disk_test.go` (new), `otter-server/internal/config/config_test.go` (`TestLimits`)

**Acceptance Criteria:**
- [ ] Levels: free ≥ floor → ok; < floor → low; < floor/4 → critical; < 64 MiB → full (`DiskGuard.Check`).
- [ ] low: `CreateBlob`, `StoreChunk` (uploads and the puller), `PublishBackup` → `ErrRetryLater` "node storage low"; `Submit` still works.
- [ ] critical: `Submit`, `UpdateDirectoryEntry`, `Register` → `ErrRetryLater`; `ApplyReplicated` still applies.
- [ ] full: `ApplyReplicated` → `ErrRetryLater` (the replication session stops without advancing its cursor).
- [ ] Back to ok → everything accepted again; level changes logged at warn.
- [ ] `[limits] disk_floor` parses sizes; default 1 GiB; `"0"` disables the low/critical levels (full stays).

**Verify:** `cd otter-server && go test ./internal/service/ ./internal/config/ -run 'Disk|Limits' -count=1 -race` → `ok`

**Steps:**

- [ ] **Step 1: Failing test** `internal/service/disk_test.go`

```go
package service

import (
	"context"
	"errors"
	"testing"
	"time"

	pb "ottermsg/server/internal/proto/otterv1"
)

// A hostile peer or member filling the disk: bulk writes stop first, small replicated records last.
func TestDiskFloorLevels(t *testing.T) {
	f := newFx(t)
	withBlobs(t, f)
	ctx := context.Background()
	a := f.mustRegister(f.invite(nil, time.Hour), "anna")
	b := f.mustRegister(f.invite(a, time.Hour), "boris")
	keep, err := f.persistentBlob(a) // created while the disk is fine
	if err != nil {
		t.Fatal(err)
	}
	free := int64(10 << 30)
	f.svc.Disk = &DiskGuard{Dir: t.TempDir(), Floor: 1 << 30,
		Free: func(string) (int64, int64, error) { return free, 20 << 30, nil }}
	level := func(want DiskLevel) {
		t.Helper()
		if got := f.svc.Disk.Check(); got != want {
			t.Fatalf("level %v, want %v", got, want)
		}
	}
	env := func() *pb.Record {
		return sign(t, pb.RecordType_ENVELOPE, b.id, &pb.Envelope{SenderUser: b.id, SenderDevice: 1,
			Kind: pb.Envelope_PREKEY_SIGNAL, Recipients: []*pb.Recipient{{User: a.id, Device: 1, Content: []byte("x")}}}, b.priv)
	}

	free = 900 << 20
	level(DiskLow)
	if _, err := f.persistentBlob(a); !errors.Is(err, ErrRetryLater) {
		t.Fatalf("new blob at low disk: %v", err)
	}
	blob, err := f.svc.Store.Blob(ctx, keep)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.svc.StoreChunk(ctx, blob, 0, make([]byte, 1000)); !errors.Is(err, ErrRetryLater) {
		t.Fatalf("chunk at low disk: %v", err)
	}
	if _, err := f.svc.Submit(ctx, b.id, env(), pb.RecordType_ENVELOPE); err != nil {
		t.Fatalf("message at low disk: %v", err)
	}

	free = 200 << 20
	level(DiskCritical)
	if _, err := f.svc.Submit(ctx, b.id, env(), pb.RecordType_ENVELOPE); !errors.Is(err, ErrRetryLater) {
		t.Fatalf("message at critical disk: %v", err)
	}
	if _, err := f.svc.ApplyReplicated(ctx, r16(), env()); err != nil {
		t.Fatalf("replicated record at critical disk: %v", err)
	}

	free = 32 << 20
	level(DiskFull)
	if _, err := f.svc.ApplyReplicated(ctx, r16(), env()); !errors.Is(err, ErrRetryLater) {
		t.Fatalf("replicated record at full disk: %v", err)
	}

	free = 10 << 30
	level(DiskOK)
	if _, err := f.persistentBlob(a); err != nil {
		t.Fatalf("after space was freed: %v", err)
	}
}
```

  and in `config_test.go` `TestLimits` add: `disk_floor = "2GiB"` → `c.DiskFloorBytes == 2<<30`; no key → `1<<30`;
  `disk_floor = "lots"` → error containing `limits.disk_floor`.

- [ ] **Step 2: Run — fails** (`undefined: DiskGuard`).

- [ ] **Step 3: Implement** `internal/service/disk.go`

```go
package service

import (
	"context"
	"fmt"
	"log/slog"
	"sync/atomic"
	"syscall"
	"time"
)

// DiskLevel says which writes the node still accepts (D118).
type DiskLevel int32

const (
	DiskOK       DiskLevel = iota
	DiskLow                // < floor: no blobs, chunks or backups
	DiskCritical           // < floor/4: no client submissions either
	DiskFull               // < DiskReserve: no replicated records either
)

// DiskReserve is kept free for SQLite (WAL, checkpoints) whatever the floor.
const DiskReserve = 64 << 20

func (l DiskLevel) String() string {
	return [...]string{"ok", "low", "critical", "full"}[l]
}

// DiskGuard measures free space under Dir. A nil guard allows everything.
type DiskGuard struct {
	Dir   string
	Floor int64                                       // 0 = only the DiskReserve level
	Free  func(dir string) (free, total int64, err error) // nil = statfs
	level atomic.Int32
	free  atomic.Int64
	total atomic.Int64
}

func statfs(dir string) (int64, int64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(dir, &st); err != nil {
		return 0, 0, err
	}
	return int64(st.Bavail) * int64(st.Bsize), int64(st.Blocks) * int64(st.Bsize), nil
}

// Check measures once and returns the new level (a failed measurement keeps the old level).
func (g *DiskGuard) Check() DiskLevel {
	f := g.Free
	if f == nil {
		f = statfs
	}
	free, total, err := f(g.Dir)
	if err != nil {
		return g.Level()
	}
	g.free.Store(free)
	g.total.Store(total)
	l := DiskOK
	switch {
	case free < DiskReserve:
		l = DiskFull
	case g.Floor > 0 && free < g.Floor/4:
		l = DiskCritical
	case g.Floor > 0 && free < g.Floor:
		l = DiskLow
	}
	g.level.Store(int32(l))
	return l
}

func (g *DiskGuard) Level() DiskLevel {
	if g == nil {
		return DiskOK
	}
	return DiskLevel(g.level.Load())
}

// Usage is the last measurement (bytes).
func (g *DiskGuard) Usage() (free, total int64) {
	if g == nil {
		return 0, 0
	}
	return g.free.Load(), g.total.Load()
}

// Run re-measures every `every` and logs level changes until ctx ends.
func (g *DiskGuard) Run(ctx context.Context, every time.Duration, log *slog.Logger) {
	if g == nil {
		return
	}
	prev := g.Check()
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		if l := g.Check(); l != prev {
			free, _ := g.Usage()
			log.Warn("disk level changed", "from", prev.String(), "to", l.String(), "free_bytes", free, "floor_bytes", g.Floor)
			prev = l
		}
	}
}

// diskRefuses returns ErrRetryLater when free space is at or below level `at` (D118).
func (s *Service) diskRefuses(at DiskLevel) error {
	if s.Disk.Level() >= at {
		return fmt.Errorf("%w: node storage low", ErrRetryLater)
	}
	return nil
}
```

  Add `Disk *DiskGuard // free-space floor (D118); nil = no checks` to `Service`. Insert as the first statement:
  `CreateBlob`, `StoreChunk`, `PublishBackup`: `if err := s.diskRefuses(DiskLow); err != nil { return nil, err }`
  (`StoreChunk` returns only `error`: `return err`); `Submit`, `UpdateDirectoryEntry`, `Register`:
  `diskRefuses(DiskCritical)`; `ApplyReplicated`: `diskRefuses(DiskFull)` (returns `false, err`). The replication
  receiver already treats `ErrRetryLater` as "stop without advancing the cursor" (`session.go:192-197`) and
  `runSession` sets `nextTry = now + retryLaterDelay`.

  Config: `Limits.DiskFloor string \`toml:"disk_floor"\``, `DiskFloorBytes int64 \`toml:"-"\``, in `validate()`:
  `if c.DiskFloorBytes, err = sizeOr(c.Limits.DiskFloor, "1GiB"); err != nil { return fmt.Errorf("config: limits.disk_floor: %w", err) }`.
  `main.go` `open()`: after `svc.Limits = …` add
  `svc.Disk = &service.DiskGuard{Dir: cfg.DataDir, Floor: cfg.DiskFloorBytes}; svc.Disk.Check()`;
  `serve()`: after `go a.svc.RunJanitor(...)` add `go a.svc.Disk.Run(ctx, 10*time.Second, a.log)`.
  `node.toml` template, in the commented `[limits]` block: `# disk_floor = "1GiB"   # below: no photos/backups; below 1/4: no messages (D118)`.

- [ ] **Step 4: Run** `go test ./internal/service/ ./internal/config/ -count=1 -race` → `ok`; `go test ./... -count=1` → all `ok`.

- [ ] **Step 5: Commit**

```bash
git add internal/service/disk.go internal/service/disk_test.go internal/service/*.go internal/config/ cmd/otter-node/main.go deploy/templates/node.toml
oc -m "node: disk floor refuses blobs, then client writes, keeps replicating small records (M9.4)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 62: Server — per-IP connection and request limits

**Goal:** One source address cannot open unbounded connections or send unbounded requests; public (unauthenticated)
methods are throttled hardest.
**Findings closed:** M9 roadmap "per-IP connection/request limits"; threat-model item 3.

**Files:**
- Create: `otter-server/internal/limits/limits.go`, `otter-server/internal/limits/limits_test.go`
- Modify: `otter-server/internal/gateway/gateway.go` (fields, `New`, `ServeHTTP` lines 120-172), `methods.go` (`dispatch` line 63), `session.go` (field `ip`)
- Modify: `otter-server/internal/config/config.go` (`Limits.ConnsPerIP`, `Limits.RequestsPerIP`), `cmd/otter-node/main.go` (`serve`: wrap `srv.Handler`)
- Test: `otter-server/internal/gateway/limits_test.go` (new)

**Acceptance Criteria:**
- [ ] `limits.Keyed.Allow(key)` is a token bucket per key (rate/s, burst); idle buckets are dropped after 10 min; key `""` is always allowed.
- [ ] `limits.Conns.Wrap(h)`: the (PerIP+1)-th concurrent request from one IP and the (burst+1)-th new one within the rate get HTTP 429; a finished request frees its slot; loopback is exempt when `ExemptLoopback`.
- [ ] Gateway: over the per-IP request rate or the public-method rate → `STATUS_RETRY_LATER` "too many requests"; the session stays open.
- [ ] Counters for each rejection kind (`limits.Counters`).
- [ ] Defaults from D116; `[limits] conns_per_ip`, `requests_per_ip` override (0 = default).

**Verify:** `cd otter-server && go test ./internal/limits/ ./internal/gateway/ -count=1 -race` → `ok`

**Steps:**

- [ ] **Step 1: Failing tests.** `internal/limits/limits_test.go`:

```go
package limits

import (
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func TestKeyedBucket(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	k := NewKeyed(1, 3) // 1/s, burst 3
	k.Now = func() time.Time { return now }
	for i := 0; i < 3; i++ {
		if !k.Allow("a") {
			t.Fatalf("burst %d refused", i)
		}
	}
	if k.Allow("a") {
		t.Fatal("4th within the same second allowed")
	}
	if !k.Allow("b") {
		t.Fatal("another key shares the bucket")
	}
	now = now.Add(time.Second)
	if !k.Allow("a") {
		t.Fatal("refill after 1 s")
	}
	if !k.Allow("") {
		t.Fatal("empty key must be exempt")
	}
}

// A hostile client opens more parallel connections than allowed.
func TestConnsPerIP(t *testing.T) {
	release := make(chan struct{})
	var started sync.WaitGroup
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { started.Done(); <-release })
	c := &Conns{PerIP: 2, Rate: NewKeyed(100, 100), Count: &Counters{}}
	wrapped := c.Wrap(h)
	req := func() *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", "/", nil)
		r.RemoteAddr = "203.0.113.7:4000"
		w := httptest.NewRecorder()
		wrapped.ServeHTTP(w, r)
		return w
	}
	started.Add(2)
	done := make(chan struct{}, 2)
	for i := 0; i < 2; i++ {
		go func() { req(); done <- struct{}{} }()
	}
	started.Wait()
	if w := req(); w.Code != http.StatusTooManyRequests {
		t.Fatalf("3rd concurrent: %d", w.Code)
	}
	if c.Count.ConnIP.Load() != 1 {
		t.Fatalf("counter %d", c.Count.ConnIP.Load())
	}
	close(release)
	<-done
	<-done
	started.Add(1) // the next request's handler signals once; release is closed, so it returns at once
	if w := req(); w.Code == http.StatusTooManyRequests {
		t.Fatal("slot not freed")
	}
	// loopback (REALITY's inner listener) is exempt when asked
	c2 := &Conns{PerIP: 0, Rate: NewKeyed(0.0001, 0), Count: &Counters{}, ExemptLoopback: true}
	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "127.0.0.1:5000"
	w := httptest.NewRecorder()
	c2.Wrap(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(204) })).ServeHTTP(w, r)
	if w.Code != 204 {
		t.Fatalf("loopback: %d", w.Code)
	}
}
```

  `internal/gateway/limits_test.go`:

```go
package gateway

import (
	"strings"
	"testing"

	"ottermsg/server/internal/limits"
	pb "ottermsg/server/internal/proto/otterv1"
)

func tightLimits(g *Gateway) {
	g.ExemptLoopback = false // httptest clients come from 127.0.0.1
	g.IPRequests = limits.NewKeyed(0.001, 5)
	g.IPPublic = limits.NewKeyed(0.001, 2)
}

// A hostile client floods requests and public methods from one address.
func TestRequestRateLimits(t *testing.T) {
	n := startNode(t, tightLimits)
	c := dial(t, n)
	for i := 0; i < 2; i++ {
		c.call("backup.auth", &pb.BackupAuthRequest{Username: "nobody"}, nil)
	}
	st, msg := c.call("backup.auth", &pb.BackupAuthRequest{Username: "nobody"}, nil)
	if st != pb.Status_STATUS_RETRY_LATER || !strings.Contains(msg, "too many") {
		t.Fatalf("3rd public call: %v %s", st, msg)
	}
	for i := 0; i < 2; i++ {
		c.call("ping", &pb.Empty{}, nil)
	}
	if st, _ := c.call("ping", &pb.Empty{}, nil); st != pb.Status_STATUS_RETRY_LATER {
		t.Fatalf("6th request: %v", st)
	}
	gw := n.svc.Notify.(*Gateway)
	if gw.Rejected.ReqRate.Load() == 0 || gw.Rejected.PublicRate.Load() == 0 {
		t.Fatalf("counters %+v", gw.Rejected.Map())
	}
}
```


- [ ] **Step 2: Run — fails** (`package ottermsg/server/internal/limits` missing; `g.ExemptLoopback` undefined).

- [ ] **Step 3: Implement** `internal/limits/limits.go`

```go
// Package limits: token buckets per key and per-IP connection limits (D116).
package limits

import (
	"net"
	"net/http"
	"sync"
	"sync/atomic"
	"time"
)

type bucket struct {
	tokens float64
	last   time.Time
}

// Keyed holds one token bucket per key (an IP, a user id). nil or key "" allows everything.
type Keyed struct {
	Rate, Burst float64 // tokens per second, bucket size
	Now         func() time.Time
	mu          sync.Mutex
	m           map[string]*bucket
	swept       time.Time
}

func NewKeyed(perSec, burst float64) *Keyed { return &Keyed{Rate: perSec, Burst: burst, m: map[string]*bucket{}} }

func (k *Keyed) Allow(key string) bool {
	if k == nil || key == "" {
		return true
	}
	now := time.Now()
	if k.Now != nil {
		now = k.Now()
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	if now.Sub(k.swept) > time.Minute { // idle buckets are full again: forget them
		for key, b := range k.m {
			if now.Sub(b.last) > 10*time.Minute {
				delete(k.m, key)
			}
		}
		k.swept = now
	}
	b := k.m[key]
	if b == nil {
		b = &bucket{tokens: k.Burst, last: now}
		k.m[key] = b
	} else {
		b.tokens = min(k.Burst, b.tokens+now.Sub(b.last).Seconds()*k.Rate)
		b.last = now
	}
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

// Counters count refusals per kind (otter_rejected_total{kind}).
type Counters struct {
	ConnIP, ConnRate, ReqRate, PublicRate, UserRate, Pending, Disk atomic.Int64
}

func (c *Counters) Map() map[string]int64 {
	return map[string]int64{"conn_ip": c.ConnIP.Load(), "conn_rate": c.ConnRate.Load(), "req_rate": c.ReqRate.Load(),
		"public_rate": c.PublicRate.Load(), "user_rate": c.UserRate.Load(), "pending": c.Pending.Load(), "disk": c.Disk.Load()}
}

// ClientIP is the request's source address without port ("" if unparsable).
func ClientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return ""
	}
	return ip.String()
}

// IsLoopback reports whether ip (from ClientIP) is a loopback address.
func IsLoopback(ip string) bool { p := net.ParseIP(ip); return p != nil && p.IsLoopback() }

// Conns limits concurrent and new requests (each WebSocket is one long request) per source IP.
type Conns struct {
	PerIP          int
	Rate           *Keyed
	Count          *Counters
	ExemptLoopback bool // REALITY's inner listener forwards from 127.0.0.1
	mu             sync.Mutex
	open           map[string]int
}

func (c *Conns) Wrap(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip := ClientIP(r)
		if ip == "" || (c.ExemptLoopback && IsLoopback(ip)) {
			h.ServeHTTP(w, r)
			return
		}
		if !c.Rate.Allow(ip) {
			c.Count.ConnRate.Add(1)
			http.Error(w, "too many requests", http.StatusTooManyRequests)
			return
		}
		c.mu.Lock()
		if c.open == nil {
			c.open = map[string]int{}
		}
		if c.open[ip] >= c.PerIP {
			c.mu.Unlock()
			c.Count.ConnIP.Add(1)
			http.Error(w, "too many connections", http.StatusTooManyRequests)
			return
		}
		c.open[ip]++
		c.mu.Unlock()
		defer func() {
			c.mu.Lock()
			if c.open[ip]--; c.open[ip] <= 0 {
				delete(c.open, ip)
			}
			c.mu.Unlock()
		}()
		h.ServeHTTP(w, r)
	})
}
```

  Gateway: add fields

```go
	// Limits (D116). IPRequests: all requests of a source IP; IPPublic: unauthenticated methods; UserWrites: write
	// methods per logged-in user (Task 63). Loopback is exempt unless ExemptLoopback is false (tests).
	IPRequests, IPPublic, UserWrites *limits.Keyed
	Rejected                         *limits.Counters
	ExemptLoopback                   bool
```

  `New`: `IPRequests: limits.NewKeyed(50, 500), IPPublic: limits.NewKeyed(20.0/60, 20), UserWrites: limits.NewKeyed(1, 300), Rejected: &limits.Counters{}, ExemptLoopback: true`.
  `session` gets `ip string`; in `ServeHTTP` after building `s`: `if ip := limits.ClientIP(r); !(g.ExemptLoopback && limits.IsLoopback(ip)) { s.ip = ip }`.
  In `methods.go`:

```go
var (
	errTooMany = fmt.Errorf("%w: too many requests", service.ErrRetryLater)
	// throttled hardest: no login needed, so a stranger can call them (D116)
	publicLimited = map[string]bool{"register": true, "auth.login": true, "backup.auth": true, "backup.fetch": true,
		"manifest.publish": true, "news.publish": true}
	// per-user write budget (Task 63)
	userWrites = map[string]bool{"msg.send": true, "prekeys.upload": true, "invite.create": true, "push.register": true,
		"directory.update": true, "backup.publish": true, "blob.create": true}
)

func (s *session) limit(method string) error {
	g := s.g
	if !g.IPRequests.Allow(s.ip) {
		g.Rejected.ReqRate.Add(1)
		return errTooMany
	}
	if publicLimited[method] && !g.IPPublic.Allow(s.ip) {
		g.Rejected.PublicRate.Add(1)
		return errTooMany
	}
	if userWrites[method] {
		if u := s.userID(); u != nil && !g.UserWrites.Allow(string(u)) {
			g.Rejected.UserRate.Add(1)
			return errTooMany
		}
	}
	return nil
}
```

  and as the first line of `dispatch`: `if err := s.limit(req.Method); err != nil { return nil, err }`.
  `RETRY_LATER` is not logged as an internal error (`handle` only logs `STATUS_INTERNAL`).
  Config: `Limits.ConnsPerIP int \`toml:"conns_per_ip"\``, `Limits.RequestsPerIP int \`toml:"requests_per_ip"\``;
  negative → error; 0 → defaults 32 / 50.
  `main.go` `serve()`, after `srv := wss.NewServer(...)` and before `go … wss.Serve`:

```go
	conns := &limits.Conns{PerIP: a.cfg.ConnsPerIP(), Rate: limits.NewKeyed(30.0/60, 20), Count: gw.Rejected, ExemptLoopback: true}
	srv.Handler = conns.Wrap(srv.Handler)
	gw.IPRequests = limits.NewKeyed(float64(a.cfg.RequestsPerIP()), float64(10*a.cfg.RequestsPerIP()))
```

  with `func (c *Config) ConnsPerIP() int` / `RequestsPerIP() int` returning the defaults for 0. The REALITY inner
  server is not wrapped (loopback only).

- [ ] **Step 4: Run** `go test ./internal/limits/ ./internal/gateway/ ./internal/config/ -count=1 -race` → `ok`;
  `go test ./... -count=1` → all `ok` (existing gateway tests stay under the defaults: they come from loopback,
  which is exempt).

- [ ] **Step 5: Commit**

```bash
git add internal/limits/ internal/gateway/ internal/config/ cmd/otter-node/main.go
oc -m "node: per-IP connection, request and public-method limits (M9.4)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 63: Server — per-user write rate and undelivered-message quota

**Goal:** A member account (or a stolen phone) cannot fill a node with messages: writes are rate limited per user and
undelivered envelope bytes per author are capped.
**Findings closed:** M9 roadmap "per-user storage quotas" (the part not covered by D44 blobs and M9.2 C8/C9).

**Files:**
- Create: `otter-server/internal/store/migrations/0016_records_author.sql` (see coordinator note)
- Modify: `otter-server/internal/store/query.go` (new `PendingEnvelopeBytes`)
- Modify: `otter-server/internal/service/blobs.go` (`Limits.UserPending`), `submit.go`, `service.go` (`pendingMu`, `Rejected`)
- Modify: `otter-server/internal/config/config.go` (`Limits.UserPending`, `UserPendingBytes`), `cmd/otter-node/main.go` (`open`)
- Test: `otter-server/internal/service/quota_test.go` (new), `otter-server/internal/gateway/limits_test.go` (user rate)

**Acceptance Criteria:**
- [ ] `msg.send` beyond `UserPending` undelivered bytes of that author → `ErrQuota` / `STATUS_QUOTA`; other authors unaffected.
- [ ] 8 concurrent submissions with room for 2 → exactly 2 accepted (check and apply are one step per author).
- [ ] After the recipient acks, the author can send again.
- [ ] Gateway: more than `UserWrites` burst write calls by one user → `STATUS_RETRY_LATER`.
- [ ] `[limits] user_pending` default `256MiB`; `"0"` = no cap.

**Verify:** `cd otter-server && go test ./internal/service/ ./internal/gateway/ ./internal/store/ -count=1 -race` → `ok`

**Steps:**

- [ ] **Step 1: Failing test** `internal/service/quota_test.go`

```go
package service

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	pb "ottermsg/server/internal/proto/otterv1"
)

// A member's phone (or a thief with it) floods an offline recipient.
func TestUndeliveredQuota(t *testing.T) {
	f := newFx(t)
	ctx := context.Background()
	a := f.mustRegister(f.invite(nil, time.Hour), "anna")
	b := f.mustRegister(f.invite(a, time.Hour), "boris")
	c := f.mustRegister(f.invite(a, time.Hour), "clara")
	env := func(from *user, n int) *pb.Record {
		return sign(t, pb.RecordType_ENVELOPE, from.id, &pb.Envelope{SenderUser: from.id, SenderDevice: 1,
			Kind: pb.Envelope_PREKEY_SIGNAL, Recipients: []*pb.Recipient{{User: a.id, Device: 1, Content: make([]byte, n)}}}, from.priv)
	}
	one := len(env(b, 4000).Body)
	f.svc.Limits.UserPending = int64(2*one + one/2) // room for two

	var ok atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := f.svc.Submit(ctx, b.id, env(b, 4000), pb.RecordType_ENVELOPE); err == nil {
				ok.Add(1)
			} else if !errors.Is(err, ErrQuota) {
				t.Errorf("unexpected: %v", err)
			}
		}()
	}
	wg.Wait()
	if ok.Load() != 2 {
		t.Fatalf("accepted %d, want 2", ok.Load())
	}
	if _, err := f.svc.Submit(ctx, c.id, env(c, 4000), pb.RecordType_ENVELOPE); err != nil {
		t.Fatalf("another author is not limited: %v", err)
	}
	// anna's phone acks everything: boris has room again
	box, _ := f.svc.Mailbox(ctx, a.id, 1, 100)
	var ids [][]byte
	for _, e := range box {
		ids = append(ids, e.Key)
	}
	ack := sign(t, pb.RecordType_ACK, a.id, &pb.Ack{EnvelopeIds: ids, DeviceId: 1}, a.priv)
	if _, err := f.svc.Submit(ctx, a.id, ack, pb.RecordType_ACK); err != nil {
		t.Fatal(err)
	}
	if _, err := f.svc.Submit(ctx, b.id, env(b, 4000), pb.RecordType_ENVELOPE); err != nil {
		t.Fatalf("after delivery: %v", err)
	}
}
```

  In `gateway/limits_test.go` add `TestUserWriteRate`: `startNode(t, func(g *Gateway){ g.UserWrites = limits.NewKeyed(0.001, 3) })`,
  register + login anna and boris (`newTestUser`, `login`), send 3 envelopes (OK), the 4th → `STATUS_RETRY_LATER`
  "too many requests", then a `directory.sync` (not a write) still returns OK.

- [ ] **Step 2: Run — fails** (`f.svc.Limits.UserPending` undefined).

- [ ] **Step 3: Implement.** Migration `0016_records_author.sql`:

```sql
-- M9.4 (D117): undelivered envelope bytes per author.
CREATE INDEX IF NOT EXISTS records_author_type ON records(author, type);
```

  `store/query.go`:

```go
// PendingEnvelopeBytes is the size of the author's ENVELOPE records still stored here (not yet acked by every
// recipient device and not expired) (D117).
func (s *Store) PendingEnvelopeBytes(ctx context.Context, author []byte) (int64, error) {
	var n int64
	err := s.r.QueryRowContext(ctx, `SELECT COALESCE(SUM(length(raw)),0) FROM records WHERE author=? AND type=?`,
		author, int32(pb.RecordType_ENVELOPE)).Scan(&n)
	return n, err
}
```

  `service/blobs.go` `Limits`: add `UserPending int64 // undelivered envelope bytes per author (D117); 0 = no cap`.
  `Service`: add `pendingMu [64]sync.Mutex` and `Rejected *limits.Counters // nil-safe use via s.rejected()`.
  In `Submit`, inside `case pb.RecordType_ENVELOPE:` after the recipients loop:

```go
		if s.Limits.UserPending > 0 {
			mu := &s.pendingMu[user[0]&63] // check and apply as one step per author on this node
			mu.Lock()
			defer mu.Unlock()
			used, err := s.Store.PendingEnvelopeBytes(ctx, user)
			if err != nil {
				return nil, err
			}
			if used+int64(len(rec.Body)) > s.Limits.UserPending {
				if s.Rejected != nil {
					s.Rejected.Pending.Add(1)
				}
				return nil, fmt.Errorf("%w: %d of %d bytes of undelivered messages", ErrQuota, used, s.Limits.UserPending)
			}
		}
```

  (`defer` holds the lock across `ApplyFrom` below, which is the point. A resend of an envelope already stored is
  counted again; it only matters at the limit and the resend is a no-op anyway.) Also in `diskRefuses` (Task 61)
  count `s.Rejected.Disk.Add(1)` when non-nil.
  Config: `Limits.UserPending string \`toml:"user_pending"\``, `UserPendingBytes int64`, `sizeOr(…, "256MiB")`.
  `main.go` `open()`: `svc.Limits = service.Limits{UserQuota: …, MaxBlob: …, UserPending: cfg.UserPendingBytes}`;
  `serve()`: `a.svc.Rejected = gw.Rejected` right after `gw := gateway.New(...)`.

- [ ] **Step 4: Run** `go test ./internal/store/ ./internal/service/ ./internal/gateway/ -count=1 -race` → `ok`.

- [ ] **Step 5: Commit**

```bash
git add internal/store/ internal/service/ internal/gateway/ internal/config/ cmd/otter-node/main.go
oc -m "node: per-user write rate and 256 MiB cap on undelivered messages per author (M9.4)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 64: Server — monitoring: backlog/lag, counters, `status.json`, `/metrics`, `otter-node status`

**Goal:** One command on a node (and one column block in `status.sh`) tells whether replication keeps up, the disk
has room, push works and TURN is used; the same numbers are scrapeable on `127.0.0.1:9477/metrics`.
**Findings closed:** M9 roadmap "monitoring: `otter-node status`, `/metrics` on localhost (replication lag, backlog,
disk, push errors, TURN allocations)"; `docs/08-operations.md` Monitoring.

**Files:**
- Create: `otter-server/internal/metrics/metrics.go`, `otter-server/internal/metrics/metrics_test.go`
- Create: `otter-server/cmd/otter-node/status.go`
- Modify: `otter-server/internal/replication/replicator.go` (`peerSeen`, `PeerStatus`, `Status`, `runSession`), `session.go` (Subscribe / BatchAck cases, lines 75-86)
- Modify: `otter-server/internal/store/query.go` (`OplogReceivedAfter`)
- Modify: `otter-server/internal/push/pusher.go` (counters, lines 24-36, 82-92)
- Modify: `otter-server/internal/gateway/gateway.go` (`Sessions`)
- Modify: `otter-server/internal/config/config.go` (`[metrics]`), `cmd/otter-node/main.go` (`serve`, `run`, `usage`)
- Modify: `otter-server/scripts/dev-mesh.sh` (one metrics port per dev node)
- Test: `metrics_test.go`, `otter-server/internal/replication/replication_test.go` (new `TestPeerBacklogTracked`), `otter-server/cmd/otter-node/main_test.go` (new `TestStatusAndMetrics`), `internal/config/config_test.go` (`TestMetricsListen`)

**Acceptance Criteria:**
- [ ] `Replicator.Status()` reports per peer `Label`, `Acked`/`AckKnown` (from `PeerSubscribe.cursor` and `PeerBatchAck.seq`), `LastUpMs`, `PingFailures`.
- [ ] After two nodes converge, each sees backlog 0 for the other; with a peer that never acks (hostile or stuck), backlog = head − its cursor and lag grows.
- [ ] The running node writes `<data_dir>/status.json` (mode 0600) every 15 s and serves `/metrics` on the configured loopback address only.
- [ ] `[metrics] listen` defaults to `127.0.0.1:9477`, accepts `"off"`, refuses non-loopback addresses.
- [ ] `otter-node status [--line|--json]` reads only `status.json`; prints `! <problem>` lines per D119; fails with a clear message when the file is missing.
- [ ] Push counters `Sent/Failed/Unregistered` count outcomes.

**Verify:** `cd otter-server && go test ./internal/metrics/ ./internal/replication/ ./internal/config/ ./cmd/otter-node/ -count=1 -race` → `ok`; manual: `bin/otter-node status --config .dev-mesh/a.toml` on the dev mesh shows `peers=2/2 lag=0s …`.

**Steps:**

- [ ] **Step 1: Failing tests.** `internal/metrics/metrics_test.go`:

```go
package metrics

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func snap(now time.Time) Snapshot {
	ms := now.UnixMilli()
	return Snapshot{Version: "0.10.1", AtMs: ms, StartedMs: ms - 3_600_000, Sessions: 3, OplogSeq: 120,
		Peers: []Peer{
			{Label: "fi-1", Connected: true, CaughtUp: true, Backlog: 0, LastUpMs: ms},
			{Label: "ru-1", Connected: true, Backlog: 40, LagS: 900, LastUpMs: ms},       // connected but not confirming
			{Label: "de-1", Connected: false, Backlog: -1, LastUpMs: ms - 20*60_000}, // gone for 20 min
		},
		DiskFree: 800 << 20, DiskTotal: 20 << 30, DiskLevel: "low", DiskFloor: 1 << 30,
		PushFailed: 4, TurnOn: true, TurnAllocs: 2, Rejected: map[string]int64{"req_rate": 5}}
}

func TestProblems(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	p := strings.Join(snap(now).Problems(now), "\n")
	for _, want := range []string{"peer ru-1 lag 15m (40 records)", "peer de-1 down for 20m", "disk low: 800MiB free (floor 1GiB)",
		"push failing: 4 failures, none sent since start"} {
		if !strings.Contains(p, want) {
			t.Fatalf("missing %q in:\n%s", want, p)
		}
	}
	if strings.Contains(p, "fi-1") {
		t.Fatalf("healthy peer reported:\n%s", p)
	}
	stale := snap(now).Problems(now.Add(3 * time.Minute))
	if !strings.Contains(strings.Join(stale, "\n"), "status is 3m old") {
		t.Fatalf("stale: %v", stale)
	}
}

func TestLineAndPrometheus(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	s := snap(now)
	if got := s.Line(); got != "peers=2/3 lag=15m backlog=40 disk=low free=800MiB sessions=3 push=0/4 turn=2 rejected=5" {
		t.Fatalf("line: %s", got)
	}
	var b bytes.Buffer
	s.Prometheus(&b)
	for _, want := range []string{`otter_peer_backlog_records{peer="ru-1"} 40`, `otter_peer_lag_seconds{peer="ru-1"} 900`,
		`otter_peer_connected{peer="de-1"} 0`, "otter_disk_free_bytes 838860800", "otter_disk_low 1",
		"otter_push_failed_total 4", "otter_turn_allocations 2", `otter_rejected_total{kind="req_rate"} 5`,
		"# TYPE otter_push_failed_total counter"} {
		if !strings.Contains(b.String(), want) {
			t.Fatalf("missing %q in:\n%s", want, b.String())
		}
	}
}

func TestFileRoundTrip(t *testing.T) {
	p := filepath.Join(t.TempDir(), "status.json")
	s := snap(time.Now())
	if err := s.WriteFile(p); err != nil {
		t.Fatal(err)
	}
	got, err := ReadFile(p)
	if err != nil || got.Line() != s.Line() {
		t.Fatalf("%v %s", err, got.Line())
	}
	if _, err := ReadFile(filepath.Join(t.TempDir(), "none.json")); err == nil {
		t.Fatal("missing file accepted")
	}
}
```

  `replication_test.go` — the hostile part is a peer that subscribes but never acks; the honest part is two
  converged nodes:

```go
func TestPeerBacklogTracked(t *testing.T) {
	m := newMesh(t, 2, false)
	m.start()
	m.register(0, "anna")
	m.register(0, "boris")
	head := func(nd *tnode) int64 { st, _ := nd.st.Stats(context.Background()); return st.OplogSeq }
	eventually(t, "n1 confirmed everything of n0", func() bool {
		for _, p := range m.nodes[0].repl.Status() {
			if p.Label == "n1" && p.AckKnown && p.Acked == head(m.nodes[0]) && p.LastUpMs > 0 {
				return true
			}
		}
		return false
	})
}
```

  plus a unit test in the same file for the never-acking peer, driving `Replicator.noteSubscribed` directly:

```go
func TestPeerThatNeverAcksShowsBacklog(t *testing.T) {
	m := newMesh(t, 2, false) // not started: n1 only "subscribed" with cursor 0 and never acks
	m.register(0, "anna")
	m.nodes[0].repl.noteSubscribed(m.nodes[1].id, 0)
	for _, p := range m.nodes[0].repl.Status() {
		if p.Label == "n1" && (!p.AckKnown || p.Acked != 0) {
			t.Fatalf("%+v", p)
		}
	}
	ms, ok, err := m.nodes[0].st.OplogReceivedAfter(context.Background(), 0)
	if err != nil || !ok || ms == 0 {
		t.Fatalf("oldest unconfirmed: %d %v %v", ms, ok, err)
	}
}
```

  (`m.register(i, name)` exists at `replication_test.go:170`.)
  `config_test.go` `TestMetricsListen`: no section → `c.Metrics.Listen == "127.0.0.1:9477"`; `listen = "off"` ok;
  `listen = "[::1]:9000"` ok; `listen = "0.0.0.0:9477"` and `listen = "203.0.113.5:9477"` → error containing `loopback`.
  `cmd/otter-node/main_test.go` `TestStatusAndMetrics`: copy the start of `TestImportAndRun` (import the manifest,
  start `run` in a goroutine) with the config from `testNode` plus `"[metrics]\nlisten = %q\n"` with
  `mport := freePort(t)` appended to the file; then
  - poll ≤ 5 s for `filepath.Join(dir, "data", "status.json")`; its mode must be `0600`;
  - `http.Get("http://" + mport + "/metrics")` → 200 and body contains `otter_up 1` and `otter_build_info`;
  - `run(ctx, []string{"status", "--config", cfg, "--line"}, &out)` → no error, output starts with `peers=0/0 lag=0s`;
  - on a second config whose `data_dir` has no `status.json`: `status` returns an error containing `no status from the running node`.

- [ ] **Step 2: Run — fails** (`package ottermsg/server/internal/metrics` missing, `noteSubscribed` undefined, unknown command `status`).

- [ ] **Step 3: Implement** `internal/metrics/metrics.go`

```go
// Package metrics: the node's health snapshot (status.json, otter-node status) and its Prometheus text form (D119).
package metrics

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"time"
)

// Thresholds for Problems (D119).
const (
	StaleAfterMs  = 60_000
	PeerDownAfter = 10 * 60_000
	LagLimitS     = 10 * 60
	PushFailAlarm = 3
)

type Peer struct {
	Label        string `json:"label"`
	Connected    bool   `json:"connected"`
	CaughtUp     bool   `json:"caught_up"`
	Backlog      int64  `json:"backlog"`    // our records the peer has not confirmed; -1 = not known yet
	LagS         int64  `json:"lag_s"`      // age of the oldest of them
	LastUpMs     int64  `json:"last_up_ms"` // last time a session was up (= at_ms while connected); 0 = never since start
	PingFailures int64  `json:"ping_failures"`
}

type Snapshot struct {
	Version          string           `json:"version"`
	AtMs             int64            `json:"at_ms"`
	StartedMs        int64            `json:"started_ms"`
	Sessions         int              `json:"client_sessions"`
	Users            int64            `json:"users"`
	Records          int64            `json:"records"`
	OplogSeq         int64            `json:"oplog_seq"`
	BlobBytes        int64            `json:"blob_bytes"`
	Peers            []Peer           `json:"peers"`
	DiskFree         int64            `json:"disk_free"`
	DiskTotal        int64            `json:"disk_total"`
	DiskLevel        string           `json:"disk_level"`
	DiskFloor        int64            `json:"disk_floor"`
	PushSent         int64            `json:"push_sent"`
	PushFailed       int64            `json:"push_failed"`
	PushUnregistered int64            `json:"push_unregistered"`
	TurnOn           bool             `json:"turn_on"`
	TurnAllocs       int64            `json:"turn_allocations"`
	TurnRelayed      int64            `json:"turn_relayed_bytes"`
	Rejected         map[string]int64 `json:"rejected"`
}

// WriteFile replaces path atomically (0600: it names peers and counts users).
func (s Snapshot) WriteFile(path string) error {
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	tmp := path + ".new"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func ReadFile(path string) (Snapshot, error) {
	var s Snapshot
	b, err := os.ReadFile(path)
	if err != nil {
		return s, err
	}
	return s, json.Unmarshal(b, &s)
}

// Dur prints milliseconds as 45s, 14m, 3h, 2d.
func Dur(ms int64) string {
	d := time.Duration(max(ms, 0)) * time.Millisecond
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd", int(d.Hours()/24))
	}
}

// Size prints bytes as 800MiB, 1GiB, 12KiB.
func Size(b int64) string {
	switch {
	case b >= 1<<30 && b%(1<<30) == 0 || b >= 10<<30:
		return fmt.Sprintf("%dGiB", b>>30)
	case b >= 1<<30:
		return fmt.Sprintf("%.1fGiB", float64(b)/(1<<30))
	case b >= 1<<20:
		return fmt.Sprintf("%dMiB", b>>20)
	default:
		return fmt.Sprintf("%dKiB", b>>10)
	}
}

// Problems lists what needs the admin's attention at time now (D119).
func (s Snapshot) Problems(now time.Time) []string {
	var p []string
	if age := now.UnixMilli() - s.AtMs; age > StaleAfterMs {
		p = append(p, fmt.Sprintf("status is %s old: is otter-node running?", Dur(age)))
	}
	for _, x := range s.Peers {
		switch {
		case !x.Connected && x.LastUpMs > 0 && s.AtMs-x.LastUpMs > PeerDownAfter:
			p = append(p, fmt.Sprintf("peer %s down for %s", x.Label, Dur(s.AtMs-x.LastUpMs)))
		case !x.Connected && x.LastUpMs == 0 && s.AtMs-s.StartedMs > PeerDownAfter:
			p = append(p, fmt.Sprintf("peer %s not connected since start (%s ago)", x.Label, Dur(s.AtMs-s.StartedMs)))
		}
		if x.LagS > LagLimitS {
			p = append(p, fmt.Sprintf("peer %s lag %s (%d records)", x.Label, Dur(x.LagS*1000), x.Backlog))
		}
	}
	if s.DiskLevel != "" && s.DiskLevel != "ok" {
		p = append(p, fmt.Sprintf("disk %s: %s free (floor %s)", s.DiskLevel, Size(s.DiskFree), Size(s.DiskFloor)))
	}
	if s.PushFailed >= PushFailAlarm && s.PushSent == 0 {
		p = append(p, fmt.Sprintf("push failing: %d failures, none sent since start", s.PushFailed))
	}
	return p
}

// Line is the one-line summary for deploy/status.sh.
func (s Snapshot) Line() string {
	up, backlog, lag := 0, int64(0), int64(0)
	for _, x := range s.Peers {
		if x.Connected {
			up++
		}
		backlog += max(x.Backlog, 0)
		lag = max(lag, x.LagS)
	}
	var rej int64
	for _, v := range s.Rejected {
		rej += v
	}
	return fmt.Sprintf("peers=%d/%d lag=%s backlog=%d disk=%s free=%s sessions=%d push=%d/%d turn=%d rejected=%d",
		up, len(s.Peers), Dur(lag*1000), backlog, s.DiskLevel, Size(s.DiskFree), s.Sessions, s.PushSent, s.PushFailed,
		s.TurnAllocs, rej)
}

type promWriter struct {
	w    io.Writer
	seen map[string]bool
}

func (p *promWriter) m(name, typ, help string, v int64, labels ...string) {
	if !p.seen[name] {
		fmt.Fprintf(p.w, "# HELP %s %s\n# TYPE %s %s\n", name, help, name, typ)
		p.seen[name] = true
	}
	l := ""
	if len(labels) > 0 {
		var parts []string
		for i := 0; i+1 < len(labels); i += 2 {
			parts = append(parts, fmt.Sprintf("%s=%q", labels[i], labels[i+1]))
		}
		l = "{" + strings.Join(parts, ",") + "}"
	}
	fmt.Fprintf(p.w, "%s%s %d\n", name, l, v)
}

func b2i(b bool) int64 {
	if b {
		return 1
	}
	return 0
}

// Prometheus writes the text exposition format (version 0.0.4).
func (s Snapshot) Prometheus(w io.Writer) {
	p := &promWriter{w: w, seen: map[string]bool{}}
	p.m("otter_up", "gauge", "The node process is running.", 1)
	p.m("otter_build_info", "gauge", "Version of otter-node.", 1, "version", s.Version)
	p.m("otter_start_time_seconds", "gauge", "Process start time.", s.StartedMs/1000)
	p.m("otter_client_sessions", "gauge", "Logged-in client sessions.", int64(s.Sessions))
	p.m("otter_users", "gauge", "Known accounts.", s.Users)
	p.m("otter_records", "gauge", "Stored records.", s.Records)
	p.m("otter_oplog_seq", "gauge", "Highest oplog sequence number.", s.OplogSeq)
	p.m("otter_blob_bytes", "gauge", "Bytes of live blobs.", s.BlobBytes)
	for _, x := range s.Peers {
		p.m("otter_peer_connected", "gauge", "A replication session with the peer is up.", b2i(x.Connected), "peer", x.Label)
		p.m("otter_peer_caught_up", "gauge", "We received the peer's whole oplog.", b2i(x.CaughtUp), "peer", x.Label)
		p.m("otter_peer_backlog_records", "gauge", "Our records the peer has not confirmed (-1 unknown).", x.Backlog, "peer", x.Label)
		p.m("otter_peer_lag_seconds", "gauge", "Age of the oldest record the peer has not confirmed.", x.LagS, "peer", x.Label)
		p.m("otter_peer_ping_failures_total", "counter", "Sessions ended by a missing pong.", x.PingFailures, "peer", x.Label)
	}
	p.m("otter_disk_free_bytes", "gauge", "Free bytes under data_dir.", s.DiskFree)
	p.m("otter_disk_total_bytes", "gauge", "Size of the data_dir file system.", s.DiskTotal)
	p.m("otter_disk_low", "gauge", "Free space is below the floor (writes refused).", b2i(s.DiskLevel != "" && s.DiskLevel != "ok"))
	p.m("otter_push_sent_total", "counter", "Push wake-ups sent.", s.PushSent)
	p.m("otter_push_failed_total", "counter", "Push wake-ups that failed.", s.PushFailed)
	p.m("otter_push_unregistered_total", "counter", "Push tokens dropped as unregistered.", s.PushUnregistered)
	p.m("otter_turn_enabled", "gauge", "The TURN relay runs.", b2i(s.TurnOn))
	p.m("otter_turn_allocations", "gauge", "Live TURN allocations.", s.TurnAllocs)
	p.m("otter_turn_relayed_bytes_total", "counter", "Bytes relayed by TURN.", s.TurnRelayed)
	kinds := make([]string, 0, len(s.Rejected))
	for k := range s.Rejected {
		kinds = append(kinds, k)
	}
	sort.Strings(kinds)
	for _, k := range kinds {
		p.m("otter_rejected_total", "counter", "Requests refused by a limit.", s.Rejected[k], "kind", k)
	}
}
```

  Replicator (`replicator.go`): extend `peerSeen` with `acked int64; ackKnown bool; lastUpMs int64` and add

```go
// noteSubscribed: the peer's subscribe cursor is what it holds of our oplog (it may go back after a restore).
func (r *Replicator) noteSubscribed(id []byte, cursor int64) {
	r.seenMu.Lock()
	p := r.peer(id)
	p.acked, p.ackKnown = cursor, true
	r.seenMu.Unlock()
}

// noteAcked: a BatchAck confirms up to seq.
func (r *Replicator) noteAcked(id []byte, seq int64) {
	r.seenMu.Lock()
	if p := r.peer(id); seq > p.acked || !p.ackKnown {
		p.acked, p.ackKnown = seq, true
	}
	r.seenMu.Unlock()
}

func (r *Replicator) noteUp(id []byte) {
	r.seenMu.Lock()
	r.peer(id).lastUpMs = time.Now().UnixMilli()
	r.seenMu.Unlock()
}
```

  `runSession`: call `r.noteUp(peer)` right after `r.reg.add(s)` succeeds and again after `s.run()` returns.
  `session.run`: in `case *pb.PeerFrame_Subscribe:` add `s.r.noteSubscribed(s.peer, k.Subscribe.Cursor)` before
  `if !started`; in `case *pb.PeerFrame_BatchAck:` add `s.r.noteAcked(s.peer, k.BatchAck.Seq)`.
  `PeerStatus` gains `Label string; Acked int64; AckKnown bool; LastUpMs int64; PingFailures int64`; in `Status()`
  set `ps.Label = n.Label` and, under `seenMu`, copy from `r.seen[string(n.NodeId)]` when present.

  Store (`query.go`):

```go
// OplogReceivedAfter returns received_ms of the first oplog entry after seq; ok = false when there is none.
func (s *Store) OplogReceivedAfter(ctx context.Context, seq int64) (int64, bool, error) {
	var ms int64
	err := s.r.QueryRowContext(ctx, `SELECT received_ms FROM oplog WHERE seq > ? ORDER BY seq LIMIT 1`, seq).Scan(&ms)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, false, nil
	}
	return ms, err == nil, err
}
```

  Pusher: add exported `Sent, Failed, Unregistered atomic.Int64` to `Pusher`; in the `switch` of `wake`:
  `p.Sent.Add(1)` / `p.Unregistered.Add(1)` / `p.Failed.Add(1)` next to the existing log lines.
  Gateway:

```go
// Sessions counts connected sessions and the logged-in ones among them (monitoring).
func (g *Gateway) Sessions() (all, loggedIn int) {
	for _, s := range g.snapshot() {
		all++
		if s.loggedIn() {
			loggedIn++
		}
	}
	return all, loggedIn
}
```

  Config: `type Metrics struct { Listen string \`toml:"listen"\` }`, field `Metrics Metrics \`toml:"metrics"\``, and
  in `validate()` call:

```go
// validateMetrics: /metrics only ever listens on loopback (D119); "off" disables it.
func (c *Config) validateMetrics() error {
	if c.Metrics.Listen == "" {
		c.Metrics.Listen = "127.0.0.1:9477"
	}
	if c.Metrics.Listen == "off" {
		return nil
	}
	host, _, err := net.SplitHostPort(c.Metrics.Listen)
	if err != nil {
		return fmt.Errorf("config: metrics.listen: %w", err)
	}
	if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
		return fmt.Errorf("config: metrics.listen must be a loopback address (127.0.0.1:PORT or [::1]:PORT), got %q", c.Metrics.Listen)
	}
	return nil
}
```

  `cmd/otter-node/status.go`:

```go
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"path/filepath"
	"time"

	"ottermsg/server/internal/config"
	"ottermsg/server/internal/gateway"
	"ottermsg/server/internal/metrics"
	"ottermsg/server/internal/push"
	"ottermsg/server/internal/replication"
	"ottermsg/server/internal/turnsrv"
)

// statusPath sits next to the database (the unit may write only there).
func statusPath(c *config.Config) string { return filepath.Join(c.DataDir, "status.json") }

// live holds what the running node reports on (D119).
type live struct {
	a       *app
	repl    *replication.Replicator
	gw      *gateway.Gateway
	pusher  *push.Pusher    // nil: push off
	turn    *turnsrv.Server // nil: TURN off
	started time.Time
}

func (l *live) collect(ctx context.Context, now time.Time) metrics.Snapshot {
	s := metrics.Snapshot{Version: version, AtMs: now.UnixMilli(), StartedMs: l.started.UnixMilli(), Rejected: l.gw.Rejected.Map()}
	_, s.Sessions = l.gw.Sessions()
	if st, err := l.a.st.Stats(ctx); err == nil {
		s.Users, s.Records, s.OplogSeq, s.BlobBytes = st.Users, st.Records, st.OplogSeq, st.BlobBytes
	}
	for _, p := range l.repl.Status() {
		mp := metrics.Peer{Label: p.Label, Connected: p.Connected, CaughtUp: p.CaughtUp, Backlog: -1,
			LastUpMs: p.LastUpMs, PingFailures: p.PingFailures}
		if p.Connected {
			mp.LastUpMs = s.AtMs
		}
		if p.AckKnown {
			mp.Backlog = max(s.OplogSeq-p.Acked, 0)
			if ms, ok, err := l.a.st.OplogReceivedAfter(ctx, p.Acked); err == nil && ok {
				mp.LagS = max(s.AtMs-ms, 0) / 1000
			}
		}
		s.Peers = append(s.Peers, mp)
	}
	s.DiskFree, s.DiskTotal = l.a.svc.Disk.Usage()
	s.DiskLevel, s.DiskFloor = l.a.svc.Disk.Level().String(), l.a.cfg.DiskFloorBytes
	if l.pusher != nil {
		s.PushSent, s.PushFailed, s.PushUnregistered = l.pusher.Sent.Load(), l.pusher.Failed.Load(), l.pusher.Unregistered.Load()
	}
	if l.turn != nil {
		ts := l.turn.Stats.Snapshot(now)
		s.TurnOn, s.TurnAllocs, s.TurnRelayed = true, ts.Allocations, ts.Relayed
	}
	return s
}

// run writes status.json every 15 s and serves /metrics on the loopback listener until ctx ends.
func (l *live) run(ctx context.Context) {
	write := func() {
		if err := l.collect(ctx, time.Now()).WriteFile(statusPath(l.a.cfg)); err != nil && ctx.Err() == nil {
			l.a.log.Warn("status file", "err", err)
		}
	}
	write()
	if ln := l.a.cfg.Metrics.Listen; ln != "off" {
		mux := http.NewServeMux()
		mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
			l.collect(r.Context(), time.Now()).Prometheus(w)
		})
		srv := &http.Server{Addr: ln, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
		go func() {
			if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
				l.a.log.Warn("metrics listener off", "listen", ln, "err", err)
			}
		}()
		defer srv.Close()
	}
	t := time.NewTicker(15 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			write()
		}
	}
}

// printStatus reads status.json only (no database): safe next to the running node, as root or otter.
func printStatus(cfgPath string, line, asJSON bool, out io.Writer) error {
	cfg, err := config.Load(cfgPath)
	if err != nil {
		return err
	}
	s, err := metrics.ReadFile(statusPath(cfg))
	if err != nil {
		return fmt.Errorf("no status from the running node (%v); is otter-node 0.10.1+ running?", err)
	}
	switch {
	case asJSON:
		enc := json.NewEncoder(out)
		enc.SetIndent("", "  ")
		if err := enc.Encode(s); err != nil {
			return err
		}
	case line:
		fmt.Fprintln(out, s.Line())
	default:
		fmt.Fprintf(out, "otter-node %s, up %s, %d client sessions, %d users, oplog %d\n", s.Version,
			metrics.Dur(s.AtMs-s.StartedMs), s.Sessions, s.Users, s.OplogSeq)
		for _, p := range s.Peers {
			state := "down"
			if p.Connected {
				state = "up"
			}
			fmt.Fprintf(out, "peer %-12s %-4s backlog=%d lag=%s ping_failures=%d\n", p.Label, state, p.Backlog,
				metrics.Dur(p.LagS*1000), p.PingFailures)
		}
		fmt.Fprintf(out, "disk %s: %s free of %s (floor %s)\n", s.DiskLevel, metrics.Size(s.DiskFree),
			metrics.Size(s.DiskTotal), metrics.Size(s.DiskFloor))
		fmt.Fprintf(out, "push sent=%d failed=%d unregistered=%d; turn on=%v allocations=%d\n", s.PushSent,
			s.PushFailed, s.PushUnregistered, s.TurnOn, s.TurnAllocs)
	}
	for _, p := range s.Problems(time.Now()) {
		fmt.Fprintln(out, "! "+p)
	}
	return nil
}
```

  `main.go`: flag `line := fs.Bool("line", false, "one-line summary (status)")`; after the `turn` early return add
  `if cmd == "status" { return printStatus(*cfgPath, *line, *asJSON, out) } // must not touch the database`;
  usage line `  status --config FILE [--line|--json]  health summary from the running node (safe while running)`.
  In `serve()`: keep the pusher in a variable (`var pusher *push.Pusher`; `pusher = push.New(fcm, a.st, a.log); a.svc.Waker = pusher`),
  keep `ts` from `startTurn` in `var turnSrv *turnsrv.Server`, and before starting WSS:
  `go (&live{a: a, repl: repl, gw: gw, pusher: pusher, turn: turnSrv, started: time.Now()}).run(ctx)`.
  `scripts/dev-mesh.sh`: in the `node.toml` heredoc add `[metrics]` / `listen = "127.0.0.1:$((9477 + i))"` with the
  node's index (the dev mesh runs three nodes on one host). Template `node.toml`: commented block
  `# [metrics]` / `# listen = "127.0.0.1:9477"   # Prometheus text on loopback only; "off" disables (D119)`.

- [ ] **Step 4: Run** `go test ./... -count=1 -race` → all `ok`. Dev mesh: `scripts/dev-mesh.sh` (reuse), then
  `bin/otter-node status --config .dev-mesh/a.toml` → three lines plus no `! ` lines;
  `curl -s 127.0.0.1:9477/metrics | grep otter_peer_backlog` → one line per peer, value 0.

- [ ] **Step 5: Commit**

```bash
git add internal/metrics/ cmd/otter-node/ internal/replication/ internal/store/query.go internal/push/pusher.go internal/gateway/gateway.go internal/config/ scripts/dev-mesh.sh deploy/templates/node.toml
oc -m "node: otter-node status, status.json and /metrics on loopback (lag, backlog, disk, push, TURN) (M9.4)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 65: Deploy — `status.sh` health block and read-only `harden-check.sh`

**Goal:** `deploy/status.sh` shows each node's health line and problems and fails on them; `deploy/harden-check.sh`
reports (never changes) SSH, updates, firewall, public listeners, sandbox score and key-file ownership per node.
**Findings closed:** M9 roadmap "monitoring in `status.sh`"; owner notes "SSH hardening and unattended-upgrades
check", "other public ports on a shared host"; threat-model item 4 (root-owned binary and keys checked).

**Files:**
- Modify: `otter-server/deploy/status.sh`
- Create: `otter-server/deploy/harden-check.sh`, `otter-server/deploy/bundle/harden-report.sh`
- Test: `otter-server/deploy/test/scripts_test.sh` (status block; harden-report with stubbed commands)

**Acceptance Criteria:**
- [ ] `status.sh` runs `otter-node status --line` inside the same single SSH call, prints a "health" block (`  LABEL  line`, `  LABEL  ! problem`) and exits 1 when any node has a problem; nodes below 0.10.1 print no health line and are not failed for it.
- [ ] `harden-report.sh` (runs on the node as root, read-only) prints lines `PASS|WARN|FAIL <check>: <detail>` for every check of D120.
- [ ] `harden-check.sh [LABEL...]` pipes it over SSH (`bash -s`), prints a table per node and exits 1 on any FAIL; it never writes on the server (the report script contains no write command: test greps for `>` redirections to files, `rm`, `chmod`, `chown`, `systemctl (start|stop|restart|enable|disable)`, `ufw (allow|deny|enable)`, `apt`).
- [ ] Non-Otter public listeners are WARN lines with port, address and process, never named in the repo.

**Verify:** `cd otter-server && cp -r . "$(mktemp -d)/s" && cd "$_" && deploy/test/scripts_test.sh` → `scripts test: ok` (a scratch copy: the script writes into `dist/`).

**Steps:**

- [ ] **Step 1: Failing tests** in `deploy/test/scripts_test.sh`, before the final `echo`:

```bash
# --- status.sh health block (otter-node status --line, 0.10.1+): problems fail the run
cat > "$work/stub/ssh" <<'STUB'
#!/bin/sh
printf '0.10.1\nactive\nusers=1\n1M\non\non\n--status--\npeers=1/2 lag=15m backlog=40 disk=ok free=9GiB sessions=2 push=3/0 turn=0 rejected=0\n! peer n2 lag 15m (40 records)\n--netlog--\n'
STUB
if out=$(PATH="$work/stub:$PATH" deploy/status.sh 2>&1); then fail "status must fail on a problem: $out"; fi
grep -q '^  n1  peers=1/2 lag=15m' <<< "$out" || fail "status health line: $out"
grep -q '^  n1  ! peer n2 lag 15m (40 records)$' <<< "$out" || fail "status problem line: $out"
grep -qE '^n1 .* on +on$' <<< "$out" || fail "status row with health block: $out"

# --- harden-report.sh: read-only checks with stubbed system commands
mkdir -p "$work/hr"
cat > "$work/hr/sshd" <<'STUB'
#!/bin/sh
printf 'passwordauthentication yes\nkbdinteractiveauthentication no\npermitrootlogin prohibit-password\npubkeyauthentication yes\nx11forwarding no\nmaxauthtries 6\n'
STUB
cat > "$work/hr/ss" <<'STUB'
#!/bin/sh
printf 'tcp LISTEN 0 4096 0.0.0.0:27443 0.0.0.0:* users:(("otter-node",pid=10,fd=7))\ntcp LISTEN 0 4096 127.0.0.1:9477 0.0.0.0:* users:(("otter-node",pid=10,fd=9))\ntcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))\ntcp LISTEN 0 511 0.0.0.0:8080 0.0.0.0:* users:(("someapp",pid=20,fd=5))\n'
STUB
cat > "$work/hr/systemd-analyze" <<'STUB'
#!/bin/sh
echo "→ Overall exposure level for otter-node.service: 1.5 OK"
STUB
printf '#!/bin/sh\necho "install ok installed"\n' > "$work/hr/dpkg-query"
printf '#!/bin/sh\necho '"'"'APT::Periodic::Unattended-Upgrade "1";'"'"'\n' > "$work/hr/apt-config"
printf '#!/bin/sh\ncase "$*" in *is-enabled*) echo enabled;; *) exit 0;; esac\n' > "$work/hr/systemctl"
printf '#!/bin/sh\necho "Status: active"\n' > "$work/hr/ufw"
printf '#!/bin/sh\necho yes\n' > "$work/hr/timedatectl"
printf '#!/bin/sh\necho "otter:x:999:999::/var/lib/otter:/usr/sbin/nologin"\n' > "$work/hr/getent"
printf '#!/bin/sh\necho otter\n' > "$work/hr/id"
chmod +x "$work/hr/"*
out=$(PATH="$work/hr:$PATH" HARDEN_ROOT="$work/fakeroot" bash deploy/bundle/harden-report.sh 2>&1) || true
grep -q '^FAIL ssh-password: PasswordAuthentication yes' <<< "$out" || fail "harden ssh: $out"
grep -q '^PASS ssh-root: prohibit-password' <<< "$out" || fail "harden root: $out"
grep -q '^PASS updates: unattended-upgrades on' <<< "$out" || fail "harden updates: $out"
grep -qF 'WARN listener: 0.0.0.0:8080 (someapp, tcp)' <<< "$out" || fail "harden listener: $out"
if grep -q 'listener: .*:27443\|listener: .*:22 ' <<< "$out"; then fail "otter/sshd listener flagged: $out"; fi
grep -q '^PASS metrics: 127.0.0.1:9477' <<< "$out" || fail "harden metrics: $out"
grep -q '^PASS sandbox: exposure 1.5' <<< "$out" || fail "harden sandbox: $out"
grep -q '^PASS otter-user: no shell, no admin groups' <<< "$out" || fail "harden user: $out"
# read-only: no command in the report changes the host
if grep -nE '(^|[;&|(] *)(rm|chmod|chown|mv|cp|tee|apt|apt-get|dpkg-reconfigure)( |$)|ufw +(allow|deny|enable|disable)|systemctl +(start|stop|restart|enable|disable|mask)|>[[:space:]]*[A-Za-z/$]' \
     deploy/bundle/harden-report.sh | grep -v '/dev/null'; then
  fail "harden-report.sh must not change the host"
fi
```

  (`HARDEN_ROOT` prefixes the file paths the report stats — `/etc/otter`, `/var/lib/otter`, `/usr/local/bin/otter-node`,
  `/var/run/reboot-required`, the unattended-upgrades log — so the test can point them at a scratch tree; on a server
  it is empty.)

- [ ] **Step 2: Run — fails** (no health block; `deploy/bundle/harden-report.sh` missing).

- [ ] **Step 3: Implement.** `status.sh`: in the remote command, before `echo --netlog--;` insert
  `echo --status--; runuser -u otter -- /usr/local/bin/otter-node status --config /etc/otter/node.toml --line 2>/dev/null || true;`.
  After reading the six lines: `[[ "$turn" != --* ]] || turn=""` (replaces the `--netlog--` comparison), and

```bash
      hl=$(sed -n '/^--status--$/,/^--netlog--$/p' <<< "$out" | sed '1d;$d;/^$/d' | sed "s/^/  $label  /")
      [[ -z "$hl" ]] || health+="$hl"$'\n'
      grep -q "^  $label  ! " <<< "$hl" && bad=1
      nl=$(sed -n '/^--netlog--$/,$p' <<< "$out" | sed "1d; /^\$/d; s/^/  $label  /")
```

  with `health=""` initialised next to `netlogs=""` and, after the table:
  `if [[ -n "$health" ]]; then printf '\nhealth (otter-node status; "!" = needs attention):\n%s' "$health"; fi`.
  Header comment: add "then each node's health line and problems (0.10.1+; exit 1 on a problem)".

  `deploy/bundle/harden-report.sh` (installed with the bundle for completeness, but `harden-check.sh` streams the
  repo copy so old nodes get the current checks):

```bash
#!/usr/bin/env bash
# Read-only hardening report for one node; run as root (deploy/harden-check.sh streams it over SSH).
# Prints "PASS|WARN|FAIL check: detail". Changes nothing on the host (D120).
set -uo pipefail
R=${HARDEN_ROOT:-}
out() { printf '%s %s: %s\n' "$1" "$2" "$3"; }

# SSH: effective server configuration
if cfg=$(sshd -T 2>/dev/null); then
  v() { awk -v k="$1" '$1 == k { print $2; exit }' <<< "$cfg"; }
  [[ "$(v passwordauthentication)" == no ]] && out PASS ssh-password off || out FAIL ssh-password "PasswordAuthentication $(v passwordauthentication)"
  [[ "$(v kbdinteractiveauthentication)" == no ]] && out PASS ssh-kbd off || out WARN ssh-kbd "KbdInteractiveAuthentication $(v kbdinteractiveauthentication)"
  case "$(v permitrootlogin)" in
    prohibit-password|without-password|no) out PASS ssh-root "$(v permitrootlogin)" ;;
    *) out FAIL ssh-root "PermitRootLogin $(v permitrootlogin)" ;;
  esac
  [[ "$(v x11forwarding)" == no ]] && out PASS ssh-x11 off || out WARN ssh-x11 "X11Forwarding $(v x11forwarding)"
  (( $(v maxauthtries) <= 6 )) && out PASS ssh-tries "$(v maxauthtries)" || out WARN ssh-tries "MaxAuthTries $(v maxauthtries)"
else
  out WARN ssh "sshd -T failed (not OpenSSH?)"
fi

# Security updates
if dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q 'install ok installed' &&
   apt-config dump APT::Periodic::Unattended-Upgrade 2>/dev/null | grep -q '"1"'; then
  out PASS updates "unattended-upgrades on"
else
  out FAIL updates "unattended-upgrades not installed or not enabled (docs/11 §8 shows how)"
fi
[[ "$(systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null)" == enabled ]] || out WARN updates-timer "apt-daily-upgrade.timer not enabled"
log=$R/var/log/unattended-upgrades/unattended-upgrades.log
if [[ -f "$log" ]] && (( $(date +%s) - $(stat -c %Y "$log") > 3 * 86400 )); then out WARN updates-run "last run more than 3 days ago"; fi
[[ -f $R/var/run/reboot-required ]] && out WARN reboot "a reboot is pending (kernel or libc update)"

# Firewall
if ufw status 2>/dev/null | grep -q '^Status: active'; then out PASS firewall "ufw active"
else out WARN firewall "ufw inactive: the cloud firewall must allow only the ports in docs/11 §8"; fi

# Public listeners that are not Otter's or SSH's: each one is a decision of the owner (D120)
while read -r proto _ _ _ local _ users; do
  addr=${local%:*}; port=${local##*:}
  proc=$(sed -nE 's/.*\(\("([^"]+)".*/\1/p' <<< "$users")
  case "$addr" in 127.*|'[::1]'|'::1') ;; *)
    case "$proc" in otter-node|sshd|systemd-network|dhclient|chronyd) ;; *) out WARN listener "$addr:$port ($proc, $proto): confirm it must be reachable from the internet" ;; esac ;;
  esac
  if [[ "$proc" == otter-node && "$port" == 9477 ]]; then
    case "$addr" in 127.*|'[::1]') out PASS metrics "$addr:$port" ;; *) out FAIL metrics "/metrics listens on $addr:$port" ;; esac
  fi
done < <(ss -H -ltunp 2>/dev/null)

# otter-node sandbox (Task 66)
score=$(systemd-analyze security otter-node --no-pager 2>/dev/null | sed -nE 's/.*exposure level for otter-node.service: ([0-9.]+).*/\1/p')
if [[ -z "$score" ]]; then out WARN sandbox "systemd-analyze security not available"
elif awk -v s="$score" 'BEGIN { exit !(s <= 2.0) }'; then out PASS sandbox "exposure $score"
else out WARN sandbox "exposure $score (> 2.0; deploy/sandbox-setup.sh installs the 0.10.1 units)"; fi

# The service user cannot log in or administer, and cannot replace its own binary or keys
shell=$(getent passwd otter | cut -d: -f7)
groups=$(id -nG otter 2>/dev/null)
if [[ "$shell" =~ (nologin|false)$ ]] && ! grep -qwE 'sudo|wheel|adm|root' <<< "$groups"; then
  out PASS otter-user "no shell, no admin groups"
else
  out FAIL otter-user "shell $shell, groups $groups"
fi
for f in $R/usr/local/bin/otter-node $R/etc/otter $R/etc/otter/node.key $R/etc/otter/tls.key $R/etc/otter/turn.secret \
         $R/etc/otter/reality.key $R/etc/otter/fcm.json; do
  [[ -e "$f" ]] || continue
  read -r mode owner <<< "$(stat -c '%a %U' "$f")"
  if [[ "$owner" != root ]] || (( (8#$mode & 8#022) != 0 )); then out FAIL file "$f is $mode $owner (want root-owned, not group/world-writable)"
  elif [[ -f "$f" && "$f" != */otter-node ]] && (( (8#$mode & 8#007) != 0 )); then out FAIL file "$f is world-readable ($mode)"
  fi
done
[[ "$(stat -c '%U %a' $R/var/lib/otter 2>/dev/null)" == "otter 700" ]] || out WARN data-dir "$R/var/lib/otter is $(stat -c '%U %a' $R/var/lib/otter 2>/dev/null)"

# Clock
[[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == yes ]] && out PASS clock "NTP synchronized" || out WARN clock "NTP not synchronized"
```

  `deploy/harden-check.sh`:

```bash
#!/usr/bin/env bash
# Read-only hardening report for every node (or the labels given): SSH, updates, firewall, public listeners,
# metrics on loopback, otter-node sandbox score, key-file ownership, NTP (D120). Changes nothing on the servers;
# fix findings by hand, each one asked first. Usage: harden-check.sh [LABEL...]
source "$(dirname "$0")/lib.sh"
labels=("$@")
(( ${#labels[@]} )) || mapfile -t labels < <(node_labels)
bad=0
for label in "${labels[@]}"; do
  printf '\n== %s\n' "$label"
  if ! host_lookup "$label"; then echo "  no SSH target: deploy/hosts.sh set $label root@HOST"; bad=1; continue; fi
  if ! out=$(SSH_PORT=$TARGET_PORT remote "$TARGET" 'bash -s' < "$ROOT/deploy/bundle/harden-report.sh" 2>&1); then
    echo "  unreachable: $out"; bad=1; continue
  fi
  sed 's/^/  /' <<< "$out"
  grep -q '^FAIL ' <<< "$out" && bad=1
done
(( bad == 0 )) && printf '\nno FAIL; review the WARN lines\n' || printf '\nFAIL lines need attention (fix by hand, asked first)\n'
exit $bad
```

  `make-bundle.sh` / `bundle/install.sh`: add `harden-report.sh` to the `install … /usr/local/lib/otter/` line so a
  node can run it locally (`/usr/local/lib/otter/harden-report.sh`).

- [ ] **Step 4: Run** the scratch-copy `scripts_test.sh` → `scripts test: ok`; `bash -n deploy/harden-check.sh deploy/bundle/harden-report.sh`; `shellcheck` if installed.

- [ ] **Step 5: Commit**

```bash
git add deploy/status.sh deploy/harden-check.sh deploy/bundle/harden-report.sh deploy/make-bundle.sh deploy/bundle/install.sh deploy/test/scripts_test.sh
oc -m "deploy: health block in status.sh; read-only harden-check.sh (ssh, updates, firewall, listeners, sandbox) (M9.4)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 66: Deploy — systemd sandbox for `otter-node` and backups, `sandbox-setup.sh`

**Goal:** A hijacked `otter-node` process runs in a tighter sandbox (exposure 3.8 → 1.5; backups 9.0 → 0.5), on new
installs and, by an explicit step with rollback, on existing nodes.
**Findings closed:** threat-model item 4 ("node process cannot become root"; "Linux is compromised easily"), owner
request "systemd sandboxing … with a test that `systemd-analyze security` improves".

**Files:**
- Modify: `otter-server/deploy/templates/otter-node.service`, `otter-server/deploy/templates/otter-backup.service`
- Create: `otter-server/deploy/sandbox-setup.sh`
- Modify: `otter-server/deploy/upgrade-all.sh` (`--no-sandbox`, call after TURN), `otter-server/deploy/README.md`
- Test: `otter-server/deploy/test/scripts_test.sh` (offline score), `otter-server/deploy/test/e2e-mesh.sh` (node works under the sandbox; TURN and REALITY listeners up; score ≤ 2.0)

**Acceptance Criteria:**
- [ ] `systemd-analyze security --offline=true --threshold=20` passes for both templates (exposure ≤ 2.0); the old unit fails it (shown in the test comment).
- [ ] `systemd-analyze verify` reports nothing but the missing binary on the dev PC.
- [ ] e2e on two VMs: nodes start, replicate, TURN listens on 3478/5349, REALITY (if configured by the test) on :443, `otter-node backup` via `otter-backup.service` works, `harden-report.sh` shows `PASS sandbox`.
- [ ] `sandbox-setup.sh LABEL [--if-older]`: prints the exposure before, installs both units (keeps `*.service.prev`), `daemon-reload`, restarts, runs `health.sh`; on failure restores the previous units, restarts and exits 2; prints the exposure after. `--if-older` skips when the installed unit already equals the template.
- [ ] `upgrade-all.sh` runs `sandbox-setup.sh --if-older` for VERSION ≥ 0.10.1 unless `--no-sandbox`; a failure is reported (`SANDBOX NOT INSTALLED`) but does not stop the rollout (same rule as TURN).

**Verify:** `systemd-analyze security --offline=true --threshold=20 otter-server/deploy/templates/otter-node.service >/dev/null && echo ok` → `ok`; `deploy/test/e2e-mesh.sh` → `e2e-mesh: ok`.

**Steps:**

- [ ] **Step 1: Failing test** in `scripts_test.sh` (skipped where `systemd-analyze` lacks `--offline`):

```bash
# --- sandbox: both units score <= 2.0 offline (the 0.8.x node unit scored 3.8, the backup unit 9.0)
if systemd-analyze security --help 2>/dev/null | grep -q -- '--offline'; then
  for u in otter-node otter-backup; do
    systemd-analyze security --offline=true --threshold=20 "deploy/templates/$u.service" >/dev/null 2>&1 ||
      fail "$u.service exposure above 2.0: $(systemd-analyze security --offline=true "deploy/templates/$u.service" 2>&1 | tail -1)"
  done
  grep -q '^RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK$' deploy/templates/otter-node.service || fail "AF_NETLINK (TURN) lost"
  grep -q '^AmbientCapabilities=CAP_NET_BIND_SERVICE$' deploy/templates/otter-node.service || fail "REALITY :443 capability lost"
  if grep -q '^PrivateUsers=' deploy/templates/otter-node.service; then fail "PrivateUsers breaks CAP_NET_BIND_SERVICE"; fi
else
  echo "scripts test: systemd-analyze --offline not available, sandbox score not checked"
fi
```

- [ ] **Step 2: Run — fails** (`otter-node.service exposure above 2.0: … 3.8 OK`).

- [ ] **Step 3: Implement.** `deploy/templates/otter-node.service`, `[Service]` section after `LimitNOFILE=65536`:

```ini
UMask=0077

# sandbox (D120). systemd-analyze security otter-node: 1.5 (0.8.x unit: 3.8)
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
PrivateIPC=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
ProcSubset=pid
# AF_NETLINK: listing network interfaces (Go net.Interfaces), needed by the TURN relay (M8)
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
RemoveIPC=true
LockPersonality=true
MemoryDenyWriteExecute=true
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
SystemCallErrorNumber=EPERM
# :443 for REALITY (D72) without root. No PrivateUsers=: it would make this capability useless for the host network.
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ReadWritePaths=/var/lib/otter
```

  (Go raises `RLIMIT_NOFILE` at start with `setrlimit`, which `~@resources` denies with EPERM; Go ignores that
  error and `LimitNOFILE=65536` already sets the limit. `ProcSubset=pid` hides `/proc/sys`; Go's listen backlog
  falls back to its built-in value. Both are covered by the e2e step.)
  `deploy/templates/otter-backup.service`:

```ini
[Unit]
Description=OtterMSG node database backup

[Service]
Type=oneshot
User=otter
Group=otter
ExecStart=/usr/local/lib/otter/backup.sh --run
UMask=0077
# sandbox (D120): exposure 0.5 (was 9.0). SQLite needs /var/lib/otter writable for its -shm/-wal files.
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
PrivateIPC=true
PrivateNetwork=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
ProcSubset=pid
RestrictAddressFamilies=AF_UNIX
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
RemoveIPC=true
LockPersonality=true
MemoryDenyWriteExecute=true
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
SystemCallErrorNumber=EPERM
CapabilityBoundingSet=
ReadWritePaths=/var/lib/otter /var/backups/otter
```

  `deploy/sandbox-setup.sh`:

```bash
#!/usr/bin/env bash
# Installs the sandboxed otter-node/otter-backup units (D120) on a node that already runs otter-node, with rollback.
# Usage: sandbox-setup.sh LABEL [--if-older]   Exit: 0 installed or already current, 2 rolled back, 3 manual action.
source "$(dirname "$0")/lib.sh"
label=${1:?usage: sandbox-setup.sh LABEL [--if-older]}; if_older=0; [[ "${2:-}" == --if-older ]] && if_older=1
host_lookup "$label" || die "node $label has no SSH target: deploy/hosts.sh set $label root@HOST"
tpl=$ROOT/deploy/templates
if (( if_older )); then
  cur=$(SSH_PORT=$TARGET_PORT remote "$TARGET" 'sha256sum < /etc/systemd/system/otter-node.service' | cut -d' ' -f1)
  [[ "$cur" == "$(sha256sum < "$tpl/otter-node.service" | cut -d' ' -f1)" ]] && { say "$label: sandbox unit already current"; exit 0; }
fi
for u in otter-node otter-backup; do SSH_PORT=$TARGET_PORT upload "$TARGET" "$tpl/$u.service" "/etc/systemd/system/$u.service.new"; done
set +e
SSH_PORT=$TARGET_PORT remote "$TARGET" bash -s <<'REMOTE'
set -euo pipefail
say() { printf '==> %s\n' "$*"; }
score() { systemd-analyze security otter-node --no-pager 2>/dev/null | tail -n1; }
say "before: $(score)"
for u in otter-node otter-backup; do
  systemd-analyze verify "/etc/systemd/system/$u.service.new" 2>&1 | grep -v 'is not executable' || true
  cp -p "/etc/systemd/system/$u.service" "/etc/systemd/system/$u.service.prev"
  install -o root -g root -m 0644 "/etc/systemd/system/$u.service.new" "/etc/systemd/system/$u.service"
  rm -f "/etc/systemd/system/$u.service.new"
done
systemctl daemon-reload
systemctl restart otter-node || true
if /usr/local/lib/otter/health.sh; then say "after: $(score)"; exit 0; fi
say "health check failed: restoring the previous units"
for u in otter-node otter-backup; do cp -p "/etc/systemd/system/$u.service.prev" "/etc/systemd/system/$u.service"; done
systemctl daemon-reload
systemctl restart otter-node || true
/usr/local/lib/otter/health.sh && exit 2
echo "ROLLBACK FAILED: see journalctl -u otter-node" >&2
exit 3
REMOTE
rc=$?
set -e
case $rc in 0) say "$label: sandbox installed" ;; 2) die "$label: sandbox rolled back (journalctl -u otter-node shows why)" ;; *) die "$label: check the server now (exit $rc)" ;; esac
```

  `upgrade-all.sh`: option `--no-sandbox` (usage and parser), and after `turn_on "$l"`:

```bash
# sandbox_on LABEL: the 0.10.1 units (D120); a failure is reported, the rollout goes on
sandbox_on() {
  (( no_sandbox == 0 )) && version_ge "$version" 0.10.1 || return 0
  if "$ROOT/deploy/sandbox-setup.sh" "$1" --if-older; then result[$1]+=", sandbox ok"
  else say "WARNING: $1: sandbox not installed (see above). Retry: deploy/sandbox-setup.sh $1"; result[$1]+=", SANDBOX NOT INSTALLED"; fi
}
```

  `e2e-mesh.sh`: switch the test releases from `0.0.1-e2e` / `0.0.2-e2e` to `0.10.1-e2e` / `0.10.2-e2e` (lines
  47, 58, 60, 77-78 and the `upgrade-all.sh` call; `clean_dist` already matches `*-e2e*`), so the bundles carry
  `[turn]` (`make-bundle.sh` adds it for 0.8.0+) and the upgrade runs `turn-setup.sh --if-missing` and
  `sandbox-setup.sh --if-older` on real VMs. Then, after the existing status check on both VMs:

```bash
step "sandbox: score, TURN listeners, backup unit, harden report"
for v in a b; do
  s=$(vm $v ssh "systemd-analyze security otter-node --no-pager | tail -n1")
  awk -v s="$(sed -nE 's/.*: ([0-9.]+) .*/\1/p' <<< "$s")" 'BEGIN { exit !(s <= 2.0) }' || fail "$v sandbox: $s"
  vm $v ssh "ss -H -lun 'sport = :3478' | grep -q ." || fail "$v: TURN not listening under the sandbox"
  vm $v ssh "systemctl start otter-backup.service && ls /var/backups/otter/node-*.db >/dev/null" || fail "$v: backup unit"
  vm $v ssh 'bash -s' < deploy/bundle/harden-report.sh | grep -q '^PASS sandbox' || fail "$v: harden report"
done
```

  `deploy/README.md`: list `sandbox-setup.sh` and `harden-check.sh` with one line each.

- [ ] **Step 4: Run** the scratch-copy `scripts_test.sh` → ok; `systemd-analyze verify deploy/templates/*.service`
  (only "not executable" lines); `deploy/test/e2e-mesh.sh` → ok (VMs on the dev PC; never the real nodes).

- [ ] **Step 5: Commit**

```bash
git add deploy/templates/otter-node.service deploy/templates/otter-backup.service deploy/sandbox-setup.sh deploy/upgrade-all.sh deploy/README.md deploy/test/scripts_test.sh deploy/test/e2e-mesh.sh
oc -m "deploy: tighter systemd sandbox for otter-node (3.8 -> 1.5) and backups (9.0 -> 0.5), sandbox-setup.sh (M9.4)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 67: Android — app lock core (PIN hash, lock state machine, settings)

**Goal:** A tested, UI-free app lock: PIN hashing, lock-after-timeout, wrong-PIN backoff that survives restarts,
enable/disable, plus the stored settings Tasks 68–70 need.
**Findings closed:** M9 roadmap "app lock (PIN/biometric)"; guide §10 «Блокировка приложения».

**Files:**
- Create: `otter-android/core/crypto/src/main/kotlin/app/ottermsg/core/crypto/PinHash.kt`
- Create: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/security/AppLock.kt`
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/settings/Settings.kt` (app-lock, screenshot and theme keys)
- Modify: `otter-android/core/database/src/main/kotlin/app/ottermsg/core/database/dao/SettingsDao.kt` (`delete`; no schema change)
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/di/DataModule.kt` (bind `AppLockStore`, `PinHasher`)
- Test: `otter-android/core/crypto/src/test/kotlin/app/ottermsg/core/crypto/PinHashTest.kt`, `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/security/AppLockTest.kt`

**Acceptance Criteria:**
- [ ] `PinHash.hash` returns salt(16) ‖ 32 bytes; `verify` accepts the PIN, rejects another PIN and malformed input; two hashes of one PIN differ (random salt).
- [ ] `AppLock`: locked at start when enabled; `onBackground` + `onForeground` after ≥ timeout locks, before it does not; timeout 0 locks on every return.
- [ ] Wrong PIN: tries 1–4 → `Wrong(left)`, the 5th → `Wait(now + 30 s)`, then 60 s, 120 s … capped at 15 min; during a wait even the right PIN gets `Wait`; the counters are in the store (a new `AppLock` over the same store keeps the wait).
- [ ] The right PIN resets the counters and unlocks; `disable()` clears the PIN and unlocks.
- [ ] `Settings`: app-lock hash/biometric/timeout/failures/lockedUntil, `screenSecure`, `themeMode` with observe flows.

**Verify:** `cd otter-android && ./gradlew :core:crypto:testDebugUnitTest --tests '*PinHash*' :core:data:testDebugUnitTest --tests '*AppLock*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing tests.** `PinHashTest.kt`:

```kotlin
package app.ottermsg.core.crypto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PinHashTest {
    @Test fun hashVerifies() {
        val h = PinHash.hash("2580".toCharArray())
        assertEquals(PinHash.SALT + PinHash.OUT, h.size)
        assertTrue(PinHash.verify("2580".toCharArray(), h))
        assertFalse(PinHash.verify("2581".toCharArray(), h))
        assertFalse(PinHash.verify("2580".toCharArray(), h.copyOf(10)))
        assertFalse(h.contentEquals(PinHash.hash("2580".toCharArray())))
    }
}
```

  `AppLockTest.kt`:

```kotlin
package app.ottermsg.core.data.security

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FakeLockStore : AppLockStore {
    var hash: ByteArray? = null; var bio = false; var timeout = AppLock.DEFAULT_TIMEOUT_MS; var fails = 0; var until = 0L
    override suspend fun pinHash() = hash
    override suspend fun setPinHash(v: ByteArray?) { hash = v }
    override suspend fun biometric() = bio
    override suspend fun setBiometric(v: Boolean) { bio = v }
    override suspend fun timeoutMs() = timeout
    override suspend fun setTimeoutMs(v: Long) { timeout = v }
    override suspend fun failures() = fails
    override suspend fun setFailures(v: Int) { fails = v }
    override suspend fun lockedUntilMs() = until
    override suspend fun setLockedUntilMs(v: Long) { until = v }
}

/** Plain-text "hash" so the state machine tests run fast; PinHash has its own test. */
object PlainHasher : PinHasher {
    override fun hash(pin: CharArray) = String(pin).encodeToByteArray()
    override fun verify(pin: CharArray, stored: ByteArray) = String(pin).encodeToByteArray().contentEquals(stored)
}

class AppLockTest {
    private var now = 1_000_000L
    private val store = FakeLockStore()
    private fun lock() = AppLock(store, { now }, PlainHasher)

    @Test fun locksAfterTimeoutOnly() = runTest {
        val l = lock()
        l.enable("1234".toCharArray(), biometric = false)
        assertFalse(l.locked.value)
        l.onBackground(); now += 59_000; l.onForeground()
        assertFalse("before the timeout", l.locked.value)
        l.onBackground(); now += 60_000; l.onForeground()
        assertTrue("after the timeout", l.locked.value)
        val fresh = lock(); fresh.init()
        assertTrue("locked at start when enabled", fresh.locked.value)
    }

    @Test fun wrongPinBackoffPersists() = runTest {
        val l = lock()
        l.enable("1234".toCharArray(), biometric = false)
        repeat(4) { assertEquals(PinResult.Wrong(4 - it), l.tryPin("0000".toCharArray())) }
        assertEquals(PinResult.Wait(now + 30_000), l.tryPin("0000".toCharArray()))
        assertEquals("right PIN during the wait", PinResult.Wait(now + 30_000), lock().tryPin("1234".toCharArray()))
        now += 30_000
        assertEquals(PinResult.Wait(now + 60_000), l.tryPin("0000".toCharArray()))
        now += 60_000
        assertEquals(PinResult.Ok, l.tryPin("1234".toCharArray()))
        assertEquals(0, store.fails)
        store.fails = 40; store.until = 0 // a long series of wrong guesses: the wait is capped
        assertEquals(PinResult.Wait(now + AppLock.MAX_WAIT_MS), l.tryPin("0000".toCharArray()))
    }

    @Test fun disableUnlocksAndForgetsPin() = runTest {
        val l = lock()
        l.enable("1234".toCharArray(), biometric = true)
        l.onBackground(); now += 3_600_000; l.onForeground()
        l.disable()
        assertFalse(l.locked.value); assertFalse(l.enabled.value)
        assertEquals(null, store.hash); assertFalse(store.bio)
    }
}
```

- [ ] **Step 2: Run — fails** (unresolved `PinHash`, `AppLock`).

- [ ] **Step 3: Implement.** `PinHash.kt`:

```kotlin
package app.ottermsg.core.crypto

import org.bouncycastle.crypto.generators.Argon2BytesGenerator
import org.bouncycastle.crypto.params.Argon2Parameters
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * App-lock PIN hash (D121): salt(16) ‖ Argon2id(m 16 MiB, t 2, p 1) → 32 bytes. It lives in the SQLCipher database,
 * whose key is in the Keystore; the hash only slows guessing if that database is ever extracted with its key.
 */
object PinHash {
    const val SALT = 16
    const val OUT = 32

    fun hash(pin: CharArray, salt: ByteArray = ByteArray(SALT).also { SecureRandom().nextBytes(it) }): ByteArray =
        salt + derive(pin, salt)

    fun verify(pin: CharArray, stored: ByteArray): Boolean {
        if (stored.size != SALT + OUT) return false
        return MessageDigest.isEqual(derive(pin, stored.copyOfRange(0, SALT)), stored.copyOfRange(SALT, stored.size))
    }

    private fun derive(pin: CharArray, salt: ByteArray): ByteArray {
        val p = Argon2Parameters.Builder(Argon2Parameters.ARGON2_id).withVersion(Argon2Parameters.ARGON2_VERSION_13)
            .withSalt(salt).withMemoryAsKB(16 * 1024).withIterations(2).withParallelism(1).build()
        return ByteArray(OUT).also { Argon2BytesGenerator().apply { init(p) }.generateBytes(pin, it) }
    }
}
```

  `AppLock.kt`:

```kotlin
package app.ottermsg.core.data.security

import app.ottermsg.core.crypto.PinHash
import app.ottermsg.core.data.Clock
import app.ottermsg.core.data.settings.Settings
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import javax.inject.Inject
import javax.inject.Singleton

/** Persistent app-lock state (Settings in the app, a fake in tests). */
interface AppLockStore {
    /** salt ‖ hash of the PIN; null = app lock off. */
    suspend fun pinHash(): ByteArray?
    suspend fun setPinHash(v: ByteArray?)
    suspend fun biometric(): Boolean
    suspend fun setBiometric(v: Boolean)
    suspend fun timeoutMs(): Long
    suspend fun setTimeoutMs(v: Long)
    suspend fun failures(): Int
    suspend fun setFailures(v: Int)
    suspend fun lockedUntilMs(): Long
    suspend fun setLockedUntilMs(v: Long)
}

interface PinHasher {
    fun hash(pin: CharArray): ByteArray
    fun verify(pin: CharArray, stored: ByteArray): Boolean
}

object Argon2PinHasher : PinHasher {
    override fun hash(pin: CharArray) = PinHash.hash(pin)
    override fun verify(pin: CharArray, stored: ByteArray) = PinHash.verify(pin, stored)
}

sealed interface PinResult {
    data object Ok : PinResult
    data class Wrong(val triesLeft: Int) : PinResult
    data class Wait(val untilMs: Long) : PinResult
}

/** App lock (D121): a UI gate over the already encrypted database. All decisions here, the screens only render. */
@Singleton
class AppLock @Inject constructor(private val store: AppLockStore, private val clock: Clock, private val hasher: PinHasher) {
    private val _enabled = MutableStateFlow(false)
    val enabled: StateFlow<Boolean> = _enabled
    private val _locked = MutableStateFlow(false)
    val locked: StateFlow<Boolean> = _locked
    @Volatile private var backgroundAt = 0L

    /** At process start: locked whenever the lock is on. */
    suspend fun init() {
        val on = store.pinHash() != null
        _enabled.value = on
        _locked.value = on
    }

    fun onBackground() { backgroundAt = clock.now() }

    suspend fun onForeground() {
        val since = backgroundAt
        backgroundAt = 0
        if (_enabled.value && since > 0 && clock.now() - since >= store.timeoutMs()) _locked.value = true
    }

    suspend fun tryPin(pin: CharArray): PinResult {
        val now = clock.now()
        val until = store.lockedUntilMs()
        if (until > now) return PinResult.Wait(until)
        val stored = store.pinHash() ?: return PinResult.Ok.also { _locked.value = false }
        if (hasher.verify(pin, stored)) {
            store.setFailures(0); store.setLockedUntilMs(0)
            _locked.value = false
            return PinResult.Ok
        }
        val n = store.failures() + 1
        store.setFailures(n)
        if (n < FREE_TRIES) return PinResult.Wrong(FREE_TRIES - n)
        val wait = minOf(BASE_WAIT_MS shl minOf(n - FREE_TRIES, 10), MAX_WAIT_MS)
        store.setLockedUntilMs(now + wait)
        return PinResult.Wait(now + wait)
    }

    /** Only after a successful BiometricPrompt (biometric or the phone's own screen lock). */
    fun unlockedByDevice() { _locked.value = false }

    suspend fun enable(pin: CharArray, biometric: Boolean) {
        store.setPinHash(hasher.hash(pin)); store.setBiometric(biometric)
        store.setFailures(0); store.setLockedUntilMs(0)
        _enabled.value = true
        _locked.value = false
    }

    suspend fun disable() {
        store.setPinHash(null); store.setBiometric(false); store.setFailures(0); store.setLockedUntilMs(0)
        _enabled.value = false
        _locked.value = false
    }

    suspend fun biometric(): Boolean = store.biometric()
    suspend fun setBiometric(v: Boolean) = store.setBiometric(v)
    suspend fun timeoutMs(): Long = store.timeoutMs()
    suspend fun setTimeoutMs(v: Long) = store.setTimeoutMs(v)

    companion object {
        const val FREE_TRIES = 5
        const val BASE_WAIT_MS = 30_000L
        const val MAX_WAIT_MS = 15 * 60_000L
        const val DEFAULT_TIMEOUT_MS = 60_000L
        val TIMEOUTS_MS = listOf(0L, 60_000L, 5 * 60_000L, 30 * 60_000L)
        val PIN_LENGTH = 4..8
    }
}

/** Settings-backed store. */
class SettingsAppLockStore @Inject constructor(private val s: Settings) : AppLockStore {
    override suspend fun pinHash() = s.appLockHash()
    override suspend fun setPinHash(v: ByteArray?) = s.setAppLockHash(v)
    override suspend fun biometric() = s.appLockBiometric()
    override suspend fun setBiometric(v: Boolean) = s.setAppLockBiometric(v)
    override suspend fun timeoutMs() = s.appLockTimeoutMs()
    override suspend fun setTimeoutMs(v: Long) = s.setAppLockTimeoutMs(v)
    override suspend fun failures() = s.appLockFailures()
    override suspend fun setFailures(v: Int) = s.setAppLockFailures(v)
    override suspend fun lockedUntilMs() = s.appLockUntilMs()
    override suspend fun setLockedUntilMs(v: Long) = s.setAppLockUntilMs(v)
}
```

  `SettingsDao`: `@Query("DELETE FROM settings WHERE \`key\` = :key") suspend fun delete(key: String)`.
  `Settings.kt` (next to the push block):

```kotlin
    // ---- app lock (D121), screenshots, appearance (D124) ----
    suspend fun appLockHash(): ByteArray? = dao.get(APP_LOCK_HASH)
    suspend fun setAppLockHash(v: ByteArray?) = if (v == null) dao.delete(APP_LOCK_HASH) else dao.put(SettingEntity(APP_LOCK_HASH, v))
    fun observeAppLockOn(): Flow<Boolean> = dao.observe(APP_LOCK_HASH).map { it != null }
    suspend fun appLockBiometric(): Boolean = (int(APP_LOCK_BIO) ?: 0) != 0
    suspend fun setAppLockBiometric(v: Boolean) = putInt(APP_LOCK_BIO, if (v) 1 else 0)
    suspend fun appLockTimeoutMs(): Long = long(APP_LOCK_TIMEOUT) ?: AppLockDefaults.TIMEOUT_MS
    suspend fun setAppLockTimeoutMs(v: Long) = putLong(APP_LOCK_TIMEOUT, v)
    suspend fun appLockFailures(): Int = int(APP_LOCK_FAILS) ?: 0
    suspend fun setAppLockFailures(v: Int) = putInt(APP_LOCK_FAILS, v)
    suspend fun appLockUntilMs(): Long = long(APP_LOCK_UNTIL) ?: 0
    suspend fun setAppLockUntilMs(v: Long) = putLong(APP_LOCK_UNTIL, v)
    /** «Запрет скриншотов»: FLAG_SECURE on the whole app (default off). */
    fun observeScreenSecure(): Flow<Boolean> = observeInt(SCREEN_SECURE, 0).map { it != 0 }
    suspend fun setScreenSecure(v: Boolean) = putInt(SCREEN_SECURE, if (v) 1 else 0)
    /** 0 = as the system, 1 = light, 2 = dark (ThemeMode.ordinal). */
    fun observeThemeMode(): Flow<Int> = observeInt(THEME_MODE, 0)
    suspend fun setThemeMode(v: Int) = putInt(THEME_MODE, v)
```

  with keys `APP_LOCK_HASH = "app_lock_hash"`, `APP_LOCK_BIO = "app_lock_biometric"`, `APP_LOCK_TIMEOUT = "app_lock_timeout_ms"`,
  `APP_LOCK_FAILS = "app_lock_failures"`, `APP_LOCK_UNTIL = "app_lock_until_ms"`, `SCREEN_SECURE = "screen_secure"`,
  `THEME_MODE = "theme_mode"`, and `private object AppLockDefaults { const val TIMEOUT_MS = 60_000L }` in the same
  file (Settings must not depend on `security`). `DataModule`: `@Provides fun appLockStore(s: SettingsAppLockStore): AppLockStore = s`
  and `@Provides fun pinHasher(): PinHasher = Argon2PinHasher`.

- [ ] **Step 4: Run** the Verify command → `BUILD SUCCESSFUL`; then `./gradlew :core:data:testDebugUnitTest` (all).

- [ ] **Step 5: Commit**

```bash
git add core/crypto/src core/data/src core/database/src
oc -m "app lock core: Argon2id PIN hash, lock timeout, persistent wrong-PIN backoff (M9.4)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 68: Android — app lock screens, biometric, private notifications, app-wide «Запрет скриншотов»

**Goal:** With the lock on, Otter opens to a PIN pad (or fingerprint), hides message text in notifications and in
recents; any member can turn screenshots off for the whole app.
**Findings closed:** M9 roadmap "app lock (PIN/biometric, optional FLAG_SECURE app-wide)"; guide §10 Безопасность.

**Files:**
- Modify: `otter-android/gradle/libs.versions.toml` (`androidx-biometric 1.1.0`, `androidx-fragment 1.9.1`), `otter-android/app/build.gradle.kts`, `otter-android/feature/settings/build.gradle.kts`
- Create: `otter-android/core/ui/src/main/kotlin/app/ottermsg/core/ui/components/SecureWindow.kt` (moved + hold counter)
- Modify: `otter-android/feature/onboarding/src/main/kotlin/app/ottermsg/feature/onboarding/screens/PhraseScreen.kt` (remove the internal `SecureWindow`, import the core one), `PhraseConfirmScreen.kt`, `RestoreScreens.kt` (imports); any M9.1 copies (`grep -rn "FLAG_SECURE" --include=*.kt`)
- Create: `otter-android/app/src/main/java/app/ottermsg/lock/LockScreen.kt`, `otter-android/feature/settings/src/main/kotlin/app/ottermsg/feature/settings/DeviceAuth.kt` (used by the lock screen in `:app`, which depends on `:feature:settings`, and by Task 70)
- Create: `otter-android/core/ui/src/main/kotlin/app/ottermsg/core/ui/components/PinPad.kt`
- Create: `otter-android/feature/settings/src/main/kotlin/app/ottermsg/feature/settings/AppLockScreen.kt`
- Modify: `otter-android/app/src/main/java/app/ottermsg/MainActivity.kt` (`FragmentActivity`, lock gate, FLAG_SECURE, recents), `OtterApp.kt` (lifecycle hooks), `AppNavHost.kt` (route `settings/lock`), `notify/MessageNotifier.kt` (`post`)
- Modify: `feature/settings/.../SettingsScreen.kt` (rows «Блокировка приложения», «Запрет скриншотов»), `feature/settings/src/main/res/values/strings.xml`, `app/src/main/res/values/strings.xml`
- Test: `otter-android/core/ui/src/test/kotlin/app/ottermsg/core/ui/components/SecureWindowTest.kt`, `otter-android/feature/settings/src/test/kotlin/app/ottermsg/feature/settings/AppLockScreenTest.kt`, `otter-android/app/src/test/kotlin/app/ottermsg/notify/LockedNotificationTest.kt`

**Acceptance Criteria:**
- [ ] Two `SecureWindow()` holders: the flag stays until both are gone (leaving the phrase screen no longer clears the app-wide setting).
- [ ] Settings → Безопасность → «Блокировка приложения»: off → «Включить» → PIN twice (4–8 digits, mismatch → «PIN-коды не совпадают») → on; then rows «Разблокировка отпечатком» (shown only if `BiometricManager.canAuthenticate(BIOMETRIC_STRONG) == BIOMETRIC_SUCCESS`), «Блокировать» (Сразу / Через 1 минуту / Через 5 минут / Через 30 минут), «Сменить PIN», «Выключить» (asks for the PIN).
- [ ] Lock screen: PIN pad with dots, «Неверный PIN. Осталось попыток: N», «Повторите через m:ss» with a countdown; biometric prompt offered automatically when enabled; «Забыли PIN?» → device credential → lock off, toast «Блокировка выключена».
- [ ] While enabled, message notifications are posted as «Otter» / «Новое сообщение» without MessagingStyle text and without «Ответить»; recents shows no content.
- [ ] Incoming calls (`CallActivity`) are not gated.
- [ ] «Запрет скриншотов» switch: FLAG_SECURE on `MainActivity` immediately, persisted.
- [ ] TalkBack: PIN keys have content descriptions (digits, «Стереть»), the dot row announces «Введено n из m».

**Verify:** `cd otter-android && ./gradlew :core:ui:testDebugUnitTest :feature:settings:testDebugUnitTest :app:testDebugUnitTest assembleDebug` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing tests.** `SecureWindowTest.kt` (Robolectric):

```kotlin
package app.ottermsg.core.ui.components

import android.view.WindowManager
import androidx.activity.ComponentActivity
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class SecureWindowTest {
    @Test fun flagStaysUntilLastHolderLeaves() {
        val a = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        fun secure() = a.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0
        SecureFlag.hold(a)   // app-wide setting
        SecureFlag.hold(a)   // recovery phrase screen
        SecureFlag.release(a) // leaving the phrase screen
        assertEquals(true, secure())
        SecureFlag.release(a)
        assertEquals(false, secure())
    }
}
```

  `AppLockScreenTest.kt` (Robolectric, `@Config(qualifiers = "ru")`, pattern of `CallSettingsTest`): render
  `AppLockSetupContent(state = AppLockUi(enabled = false, …), …)`, click «Включить», type `1234` on the pad, then
  `1235` → text «PIN-коды не совпадают» shown and `onEnable` not called; `1234` twice → `onEnable("1234", false)` called once.
  `LockedNotificationTest.kt` (Robolectric, app module): build `MessageNotifier` with an `AppLock` whose fake store
  has a PIN, call `onIncoming` for a conversation with one unread message «секрет», read the posted notification via
  `ShadowNotificationManager`: its `EXTRA_TEXT` is «Новое сообщение», no `EXTRA_MESSAGES`, `actions` has no
  RemoteInput; with the lock off the MessagingStyle text contains «секрет». Seed the DB and conversation with the
  helpers of `app/src/test/kotlin/app/ottermsg/notify/MessageNotifierTest.kt` (the new test sits next to it).

- [ ] **Step 2: Run — fails** (unresolved `SecureFlag`, `AppLockSetupContent`; notification still shows the text).

- [ ] **Step 3: Implement.**
  `libs.versions.toml`: `biometric = "1.1.0"`, `fragment = "1.9.1"`; libraries
  `androidx-biometric = { module = "androidx.biometric:biometric", version.ref = "biometric" }`,
  `androidx-fragment = { module = "androidx.fragment:fragment", version.ref = "fragment" }`; `implementation` of both in
  `:app` and of `androidx-biometric` in `:feature:settings`.
  `core/ui/.../components/SecureWindow.kt`:

```kotlin
package app.ottermsg.core.ui.components

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.view.WindowManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.platform.LocalContext
import java.util.WeakHashMap

/** FLAG_SECURE with holders: the app-wide «Запрет скриншотов» and secret screens (phrase, backup password) overlap. */
object SecureFlag {
    private val holds = WeakHashMap<Activity, Int>()

    fun hold(a: Activity) = synchronized(holds) {
        val n = (holds[a] ?: 0) + 1
        holds[a] = n
        if (n == 1) a.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    fun release(a: Activity) = synchronized(holds) {
        val n = (holds[a] ?: 1) - 1
        if (n <= 0) { holds.remove(a); a.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE) } else holds[a] = n
    }
}

/** No screenshots and no recents preview while this is composed (and [enabled]). */
@Composable
fun SecureWindow(enabled: Boolean = true) {
    val activity = LocalContext.current.findActivity()
    DisposableEffect(activity, enabled) {
        if (enabled && activity != null) SecureFlag.hold(activity)
        onDispose { if (enabled && activity != null) SecureFlag.release(activity) }
    }
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
```

  Delete `SecureWindow`/`findActivity` from `PhraseScreen.kt:46-60`; add `import app.ottermsg.core.ui.components.SecureWindow`
  in the three onboarding files (and in any M9.1 screens found by `grep -rn "FLAG_SECURE\|SecureWindow" --include=*.kt`).

  `feature/settings/.../DeviceAuth.kt`:

```kotlin
package app.ottermsg.feature.settings

import android.os.Build
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_WEAK
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity

/** BiometricPrompt wrappers for the lock screen (D121). */
object DeviceAuth {
    fun biometricAvailable(a: FragmentActivity) =
        BiometricManager.from(a).canAuthenticate(BIOMETRIC_STRONG) == BiometricManager.BIOMETRIC_SUCCESS

    /** Fingerprint/face; «PIN» as the negative button returns to the pad. */
    fun biometric(a: FragmentActivity, title: String, negative: String, onOk: () -> Unit) =
        prompt(a, onOk, BiometricPrompt.PromptInfo.Builder().setTitle(title).setNegativeButtonText(negative)
            .setAllowedAuthenticators(BIOMETRIC_STRONG).build())

    /** «Забыли PIN?»: the phone's own screen lock. BIOMETRIC_STRONG|DEVICE_CREDENTIAL is unsupported on API 28–29. */
    fun deviceCredential(a: FragmentActivity, title: String, onOk: () -> Unit) {
        val auth = if (Build.VERSION.SDK_INT >= 30) BIOMETRIC_STRONG or DEVICE_CREDENTIAL else BIOMETRIC_WEAK or DEVICE_CREDENTIAL
        prompt(a, onOk, BiometricPrompt.PromptInfo.Builder().setTitle(title).setAllowedAuthenticators(auth).build())
    }

    private fun prompt(a: FragmentActivity, onOk: () -> Unit, info: BiometricPrompt.PromptInfo) {
        BiometricPrompt(a, ContextCompat.getMainExecutor(a), object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) = onOk()
        }).authenticate(info)
    }
}
```

  `app/.../lock/LockScreen.kt`: `@Composable fun LockScreen(lock: AppLock, activity: FragmentActivity)` — Otter
  mark, title «Введите PIN», a dot row (`semantics { contentDescription = "Введено $n из $max" }`), a 3×4 pad
  (digits, «Стереть» with `contentDescription`, and the fingerprint key when `lock.biometric()`), a message line
  for `PinResult.Wrong` («Неверный PIN. Осталось попыток: N») / `PinResult.Wait` («Повторите через m:ss», ticking
  with `LaunchedEffect` and `delay(1000)`), and the text button «Забыли PIN?» →
  `DeviceAuth.deviceCredential(activity, "Подтвердите, что это вы") { scope.launch { lock.disable(); toast } }`.
  The PIN length is not stored (it would help a guesser), so the pad submits on its «OK» key, enabled from 4 digits. On first composition with biometric on: `DeviceAuth.biometric(activity, "Разблокировать Otter", "PIN") { lock.unlockedByDevice() }`.

  `MainActivity.kt`:

```kotlin
@AndroidEntryPoint
class MainActivity : FragmentActivity() {
    private val vm: MainViewModel by viewModels()
    @Inject lateinit var appLock: AppLock

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        handle(intent)
        setContent {
            val theme by vm.themeMode.collectAsStateWithLifecycle()
            OtterTheme(ThemeMode.entries[theme]) {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    val hasAccount by vm.hasAccount.collectAsStateWithLifecycle()
                    val superseded by vm.superseded.collectAsStateWithLifecycle()
                    val locked by appLock.locked.collectAsStateWithLifecycle()
                    val lockOn by appLock.enabled.collectAsStateWithLifecycle()
                    val noShots by vm.screenSecure.collectAsStateWithLifecycle()
                    SecureWindow(enabled = noShots || (lockOn && Build.VERSION.SDK_INT < 33))
                    LaunchedEffect(lockOn) { if (Build.VERSION.SDK_INT >= 33) setRecentsScreenshotEnabled(!lockOn) }
                    when {
                        superseded -> SupersededScreen()
                        locked -> LockScreen(appLock, this@MainActivity)
                        else -> hasAccount?.let { AppNavHost(it, vm.accounts.account, vm.openConversation) }
                    }
                }
            }
        }
    }
    // onNewIntent / handle unchanged
}
```

  `MainViewModel` gains `val screenSecure = settings.observeScreenSecure().stateIn(viewModelScope, SharingStarted.Eagerly, false)`
  and `val themeMode = settings.observeThemeMode().stateIn(viewModelScope, SharingStarted.Eagerly, 0)` (theme is used
  in Task 70; reading it now avoids touching this file twice). The notification tap's `openConversation` is applied
  by `AppNavHost` only after unlock (it is composed only when unlocked).
  `OtterApp.onCreate`: `appScope.launch { appLock.init() }` before the lifecycle observer, and

```kotlin
            ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
                override fun onStop(owner: LifecycleOwner) = appLock.onBackground()
                override fun onStart(owner: LifecycleOwner) { appScope.launch { appLock.onForeground() } }
            })
```

  `MessageNotifier`: inject `AppLock`; at the start of `post(cid, c)`:

```kotlin
        if (appLock.enabled.value) { // D121: no names, text or reply while the app lock is on
            val n = NotificationCompat.Builder(context, if (c.group) Channels.GROUPS else Channels.MESSAGES)
                .setSmallIcon(R.drawable.ic_stat_otter).setContentTitle(context.getString(R.string.notif_public_title))
                .setContentText(context.getString(R.string.notif_public_text)).setContentIntent(openIntent(cid))
                .setAutoCancel(true).setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setPriority(NotificationCompat.PRIORITY_HIGH).setGroup(groupKey).build()
            try { nm.notify(cid.toInt(), n) } catch (e: SecurityException) { }
            return
        }
```

  (extract the existing `open` PendingIntent construction into `private fun openIntent(cid: Long)`; news posts keep
  their content — announcements are public within the network.)
  `feature/settings/.../AppLockScreen.kt`: `AppLockRoute(onBack)` + `AppLockViewModel(lock: AppLock)` exposing
  `AppLockUi(enabled, biometric, timeoutMs, biometricAvailable)`; `AppLockSetupContent` renders the off state
  (explanation «Otter будет спрашивать PIN при открытии. Звонки можно принять без PIN.» + «Включить»), the
  two-step PIN entry (reuses a `PinPad` composable placed in `core/ui/components/PinPad.kt` so the lock screen and
  setup share it), and the on state rows listed in the acceptance criteria; «Выключить» and «Сменить PIN» first ask
  for the current PIN via `lock.tryPin`. Strings in `feature/settings/.../strings.xml`: `settings_app_lock`
  «Блокировка приложения», `settings_app_lock_on` «Включена», `settings_app_lock_off` «Выключена»,
  `app_lock_enable` «Включить», `app_lock_new_pin` «Придумайте PIN», `app_lock_repeat_pin` «Повторите PIN»,
  `app_lock_mismatch` «PIN-коды не совпадают», `app_lock_biometric` «Разблокировка отпечатком»,
  `app_lock_timeout` «Блокировать», `app_lock_t0` «Сразу», `app_lock_t1` «Через 1 минуту», `app_lock_t5`
  «Через 5 минут», `app_lock_t30` «Через 30 минут», `app_lock_change` «Сменить PIN», `app_lock_disable` «Выключить»,
  `settings_no_screenshots` «Запрет скриншотов», `settings_no_screenshots_sub` «Экран Otter не попадёт на снимки и в
  список недавних приложений». In `SettingsScreen` under «Безопасность», before «Резервная копия»: the
  «Блокировка приложения» row (subtitle on/off, opens `Routes.APP_LOCK = "settings/lock"`) and the
  «Запрет скриншотов» switch row (same `toggleable` pattern as `CallSettingsRows`).

- [ ] **Step 4: Run** the Verify command → `BUILD SUCCESSFUL`. On the emulator (`Medium_Phone_API_35`): enable the
  lock, background 1 min → PIN pad; 5 wrong PINs → 30 s wait; «Забыли PIN?» with the emulator's screen lock;
  a message while locked → «Новое сообщение» only; recents thumbnail blank; «Запрет скриншотов» → `adb exec-out screencap`
  shows a black frame; a call from the second emulator rings and is answered without the PIN.

- [ ] **Step 5: Commit**

```bash
git add gradle/libs.versions.toml app/ core/ui/ feature/settings/ feature/onboarding/
oc -m "app lock: PIN/biometric gate, private notifications while locked, app-wide screenshot block (M9.4)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 69: Android — «Состояние сети» and battery-optimisation helper

**Goal:** A member (or the owner helping on the phone) sees in one screen why messages are late: connection, the
phone's network, each node's endpoints, the notification mode and whether Android restricts Otter in the background.
**Findings closed:** M9 roadmap "network status screen + battery-optimization helper".

**Files:**
- Create: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/network/NetworkStatus.kt`
- Create: `otter-android/feature/settings/src/main/kotlin/app/ottermsg/feature/settings/NetworkStatusScreen.kt`
- Modify: `otter-android/app/src/main/AndroidManifest.xml` (`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`), `AppNavHost.kt` (route `settings/network`), `SettingsScreen.kt` (status row opens it; netlog row moves), strings
- Test: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/network/NetworkStatusTest.kt`, `otter-android/feature/settings/src/test/kotlin/app/ottermsg/feature/settings/NetworkStatusScreenTest.kt`

**Acceptance Criteria:**
- [ ] `NetworkStatus.nodes()` groups `ManifestUpdater.candidates(allowPlaintext)` by node label with each endpoint's `EndpointStatEntity` (last success, last failure, RTT, failures, demoted until); endpoints never tried show «ещё не подключались».
- [ ] The screen shows: «Сейчас» (Подключено к <label> · <WSS|WS> · с hh:mm / Подключаемся… / Нет подключения, повтор в hh:mm:ss + reason), «Сеть телефона» (Wi-Fi / Мобильная · оператор / Нет сети), «Узлы» (one card per node), «Уведомления» (Быстрые / Экономия батареи + «последнее пробуждение: …»), «Батарея», and the «Журнал подключений» row.
- [ ] «Батарея»: when `PowerManager.isIgnoringBatteryOptimizations(pkg)` is false: «Android может задерживать уведомления Otter» + button «Не ограничивать Otter» (`ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, `package:` URI); otherwise «Ограничений нет». Always a row «Автозапуск и фон» opening `ACTION_APPLICATION_DETAILS_SETTINGS`; re-checked on resume.
- [ ] Nothing new is sent anywhere; no new permission prompts beyond the system battery dialog the member taps.

**Verify:** `cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*NetworkStatus*' :feature:settings:testDebugUnitTest --tests '*NetworkStatus*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing tests.** `NetworkStatusTest.kt` (JVM, fakes): two candidates of node `fi` (WSS and REALITY
  is skipped by the app anyway — use two WSS hosts) and one of `ru`; `EndpointStatDao` fake returns a stat for the
  first `fi` key with `lastSuccessMs = 100, rttMs = 80` and one for `ru` with `demotedUntilMs = 5_000`; assert
  `nodes()` == `[NodeRow("fi", [EndpointRow(host1, 100, 0, 80, 0, 0), EndpointRow(host2, null…)]), NodeRow("ru", [… demotedUntilMs = 5_000])]`
  in manifest order. `NetworkStatusScreenTest.kt` (Robolectric, ru): render `NetworkStatusContent` with
  `batteryRestricted = true` → «Не ограничивать Otter» shown and clicking calls `onBattery`; with `false` →
  «Ограничений нет»; a demoted endpoint shows «понижен до 12:00».

- [ ] **Step 2: Run — fails** (unresolved `NetworkStatus`, `NetworkStatusContent`).

- [ ] **Step 3: Implement** `NetworkStatus.kt`:

```kotlin
package app.ottermsg.core.data.network

import app.ottermsg.core.data.di.AllowPlaintext
import app.ottermsg.core.data.sync.ManifestUpdater
import app.ottermsg.core.database.dao.EndpointStatDao
import javax.inject.Inject

data class EndpointRow(val host: String, val url: String, val lastSuccessMs: Long?, val lastFailureMs: Long?,
                       val rttMs: Long?, val failures: Int, val demotedUntilMs: Long)
data class NodeRow(val label: String, val endpoints: List<EndpointRow>)

/** «Состояние сети» (D123): the manifest's nodes with this phone's own connection history. Read-only. */
class NetworkStatus @Inject constructor(
    private val manifests: ManifestUpdater, private val stats: EndpointStatDao,
    @param:AllowPlaintext private val allowPlaintext: Boolean,
) {
    suspend fun nodes(): List<NodeRow> {
        val byKey = stats.all().associateBy { it.key }
        return manifests.candidates(allowPlaintext).groupBy { it.label }.map { (label, cs) ->
            NodeRow(label, cs.map { c ->
                val s = byKey[c.key]
                EndpointRow(c.host, c.url, s?.lastSuccessMs?.takeIf { it > 0 }, s?.lastFailureMs?.takeIf { it > 0 },
                    s?.rttMs?.takeIf { it > 0 }, s?.failures ?: 0, s?.demotedUntilMs ?: 0)
            })
        }
    }
}
```

  (`AllowPlaintext` is in `core/data/.../di/Qualifiers.kt:9`; `SyncEngine` injects it the same way at line 55.)
  `NetworkStatusScreen.kt`: `NetworkStatusViewModel @Inject constructor(status: NetworkStatus, sync: SyncEngine,
  network: CurrentNetwork, push: PushMonitor, settings: Settings)` exposing a `StateFlow<NetworkStatusUi>` refreshed
  on `sync.connection` changes and every 10 s while visible; `NetworkStatusRoute(onBack, onNetLog)` reads
  `context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName)` in a
  `remember(lifecycleState)` like `SettingsRoute` does for full-screen intents, and passes `onBattery`:

```kotlin
    val onBattery = {
        runCatching {
            context.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + context.packageName))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }.onFailure { // some vendors remove the dialog: fall back to the list
            context.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        Unit
    }
    val onAppDetails = {
        context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + context.packageName))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); Unit
    }
```

  `NetworkStatusContent(ui, batteryRestricted, onBack, onBattery, onAppDetails, onNetLog)` renders the sections of
  the acceptance criteria with `OtterSettingsRow` and `Section`-style headings (make `Section` in `SettingsScreen.kt`
  `internal` to reuse it); times via `DateFormat.getTimeFormat(context)`. Manifest:
  `<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />`.
  `SettingsScreen`: the connection status row gets `onClick = onNetwork` and a chevron; the «Журнал подключений» row
  is removed from Settings (it is inside «Состояние сети»); `SettingsRoute` parameter `onNetLog` is replaced by
  `onNetwork`. `AppNavHost`: `Routes.NETWORK = "settings/network"` → `NetworkStatusRoute(onBack = { nav.popBackStack() }, onNetLog = { nav.navigate(Routes.NETLOG) })`.
  Strings: `network_title` «Состояние сети», `network_now` «Сейчас», `network_phone` «Сеть телефона», `network_nodes`
  «Узлы», `network_never` «ещё не подключались», `network_demoted` «понижен до %1$s», `network_battery` «Батарея»,
  `network_battery_restricted` «Android может задерживать уведомления Otter», `network_battery_fix` «Не ограничивать
  Otter», `network_battery_ok` «Ограничений нет», `network_autostart` «Автозапуск и фон», `network_last_wake`
  «Последнее пробуждение: %1$s».

- [ ] **Step 4: Run** the Verify command, then `./gradlew :feature:settings:testDebugUnitTest :app:assembleDebug`.
  Emulator: the screen against the dev mesh shows three nodes; stopping node `a` shows a failure time on it within
  one reconnect; the battery button opens the system dialog and the state flips after «Разрешить».

- [ ] **Step 5: Commit**

```bash
git add core/data/src feature/settings/src app/src
oc -m "settings: network status screen with per-node history and a battery-optimisation helper (M9.4)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 70: Android — settings polish: appearance, order, recovery phrase

**Goal:** Settings match guide §10: a theme choice that sticks, the sections in the guide's order, and the 24 words
viewable again after the phone's screen lock.
**Findings closed:** M9 roadmap "settings polish" (D124).

**Files:**
- Create: `otter-android/feature/settings/src/main/kotlin/app/ottermsg/feature/settings/AppearanceScreen.kt`, `RecoveryPhraseScreen.kt`
- Modify: `SettingsScreen.kt` (order, new rows), `strings.xml`, `AppNavHost.kt` (routes `settings/appearance`, `settings/phrase`), `MainActivity.kt` (theme already observed in Task 68)
- Test: `otter-android/feature/settings/src/test/kotlin/app/ottermsg/feature/settings/SettingsOrderTest.kt`, `AppearanceTest.kt`, `RecoveryPhraseTest.kt`

**Acceptance Criteria:**
- [ ] Section headings appear in this order: Профиль, Семья, Уведомления, Оформление, Фото и память, Безопасность, Подключение; the version footer last.
- [ ] «Оформление» → three radio rows «Как на устройстве» / «Светлая» / «Тёмная»; choosing one saves `themeMode` and the app recolours without restart.
- [ ] «Фраза восстановления» (Безопасность) → device credential prompt (`DeviceAuth.deviceCredential`, or the app-lock PIN pad when the phone has no screen lock) → the 24 words in two numbered columns under `SecureWindow()`, with the warning «Никому не показывайте эти слова. Кто их знает — тот владеет аккаунтом.»; the words are derived from `LocalAccount.seed` via `Bip39` only while the screen is shown.
- [ ] Without a phone screen lock and without the app lock, the row explains «Сначала включите блокировку экрана телефона или блокировку Otter» and does not show the words.

**Verify:** `cd otter-android && ./gradlew :feature:settings:testDebugUnitTest` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing tests.** `SettingsOrderTest` renders `SettingsRoute` with a fake VM and asserts the heading
  nodes (`onAllNodes(isHeading())`) read in the listed order. `AppearanceTest` clicks «Тёмная» and asserts the save
  lambda got `2`. `RecoveryPhraseTest` renders `RecoveryPhraseContent(words = List(24) { "w$it" }, …)` and asserts
  «1. w0» and «24. w23» are shown; with `canAuthenticate = false` the explanation text is shown and no word is.

- [ ] **Step 2: Run — fails.**

- [ ] **Step 3: Implement.** In `SettingsScreen` reorder: Профиль, Семья, Уведомления, **Оформление** (row → `onAppearance`,
  subtitle = current mode), Фото и память (rename the «Медиа» heading to `settings_photos_section` «Фото и память»),
  **Безопасность** (Блокировка приложения, Запрет скриншотов, Резервная копия, Фраза восстановления), **Подключение**
  (status row → «Состояние сети», `CallSettingsRows`), `VersionFooter`. `AppearanceScreen.kt`: `AppearanceViewModel(settings)`
  with `mode = settings.observeThemeMode()` and `set(v) = settings.setThemeMode(v)`; three `Modifier.selectable(role = Role.RadioButton)` rows.
  `RecoveryPhraseScreen.kt`: `RecoveryPhraseViewModel(accounts: AccountRepository)` with
  `fun words(): List<String> = Bip39.toMnemonic(accounts.require().seed)` (`Bip39.kt:17`), called only after the prompt
  succeeds and kept in composition state (not in the ViewModel) so leaving the screen drops it.
  `RecoveryPhraseRoute` gets the activity via `LocalContext.current as FragmentActivity`, checks
  `BiometricManager.from(a).canAuthenticate(BIOMETRIC_STRONG or DEVICE_CREDENTIAL)` (API 30+, `BIOMETRIC_WEAK or DEVICE_CREDENTIAL`
  below) and calls `DeviceAuth.deviceCredential` (Task 68); `SecureWindow()` while the words are shown.
  Strings: `settings_appearance` «Оформление», `appearance_system` «Как на устройстве», `appearance_light` «Светлая»,
  `appearance_dark` «Тёмная», `settings_phrase` «Фраза восстановления», `phrase_warning` (text above),
  `phrase_need_lock` (text above), `phrase_auth_title` «Подтвердите, что это вы».

- [ ] **Step 4: Run** the Verify command; `./gradlew :app:assembleDebug`; emulator: theme switch recolours at once and
  survives a restart; «Фраза восстановления» asks for the emulator PIN, shows 24 words, screenshot is black.

- [ ] **Step 5: Commit**

```bash
git add feature/settings/ app/src/main/java/app/ottermsg/AppNavHost.kt
oc -m "settings: appearance choice, guide order, recovery phrase behind the screen lock (M9.4)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 71: Docs — three-node guide followed from scratch, security checklist, firewall, decisions

**Goal:** `docs/11-deployment.md` has one copy-paste runbook for a 3-node network that a reader without our context
completes on fresh machines, plus the M9.4 security checklist (SSH, updates, firewall incl. TURN, shared hosts,
sandbox, monitoring); decisions and roadmap are current.
**Findings closed:** M9 roadmap acceptance "3-node deployment guide followed from scratch by someone else"; owner notes
"cloud firewall for TURN ports (doc steps)", "other public ports on a shared host (owner checklist, read-only)".

**Files:**
- Modify: `docs/11-deployment.md` (§5.5 unit, §7 health checks, §8 security checklist, §9 table, new §14 "Three nodes from scratch")
- Modify: `docs/08-operations.md` (Monitoring), `docs/00-decisions.md` (D115–D124 as real D-numbers; D72 keep-alive sentence; D31 "no UI until M9" → D122), `docs/09-roadmap.md` (M9.4 row done, "M9.4 notes"), `docs/07-android-architecture.md` (Settings + Security on device), `docs/10-otter-design-guidelines.md` (§10 rows Оформление, Безопасность, Подключение)
- Modify: `otter-server/deploy/FIRST-DEPLOY.md` (pointer to §14 for more than one node), `otter-server/deploy/README.md`
- Create: `otter-server/docs/m9.4-manual-test.md`, `otter-android/docs/m9.4-manual-test.md`

**Acceptance Criteria:**
- [ ] §14 lists every command from an empty admin machine to two phones chatting through three nodes (one of them dial-out-only), with expected output after each step and what to do when it differs; no step refers to knowledge outside the document and the repo.
- [ ] §8 has the firewall table below, provider-neutral cloud-firewall steps, SSH/updates items with the exact commands that `harden-check.sh` checks, the shared-host rule, the sandbox and how to read `systemd-analyze security` on a server (asked first, read-only).
- [ ] A fresh-context agent, given only `docs/11-deployment.md` §14 and the repo, builds the 3-node network on three local VMs; every place it had to guess is fixed in the doc; a second run has zero guesses.
- [ ] No real IP, host name of a shared service or product name of the owner's other services appears in any repo (`scripts/secrets-check.sh` ok in all three).

**Verify:** the fresh-agent run log (kept outside the repos in the scratchpad) ends with "no guesses"; `scripts/secrets-check.sh` → ok in `otter-server`, `otter-android`, `docs`.

**Steps:**

- [ ] **Step 1: §8 Security checklist** (replace the current bullets):

  ```markdown
  ## 8. Security checklist

  Run `deploy/harden-check.sh` (read-only, all nodes) after every install and every few months; it prints
  PASS/WARN/FAIL for each item below. Fix findings by hand on the server.

  * **SSH:** key-only (`PasswordAuthentication no`, `KbdInteractiveAuthentication no`), `PermitRootLogin
    prohibit-password`, `X11Forwarding no`, `MaxAuthTries 6` or lower; optionally a non-standard port
    (`OTTER_SSH_PORT`). Check the effective values: `sshd -T | grep -Ei 'passwordauth|kbdinteractive|permitroot|x11|maxauthtries'`.
  * **Security updates:** `apt-get install unattended-upgrades` and `dpkg-reconfigure -plow unattended-upgrades`
    (answers "Yes"); check `apt-config dump APT::Periodic::Unattended-Upgrade` shows `"1"` and
    `systemctl is-enabled apt-daily-upgrade.timer` says `enabled`. Reboot when `/var/run/reboot-required` exists.
  * **Firewall** (ufw on the host and/or the provider's cloud firewall; inbound, everything else closed):

    | Port | Protocol | From | What |
    |---|---|---|---|
    | 22 (or your SSH port) | TCP | your own addresses if they are stable, else anywhere | SSH |
    | the node port (e.g. 27443) | TCP | anywhere | phones and other nodes (WSS) |
    | 443 | TCP | anywhere | REALITY, only on nodes with `[reality]` (§13) |
    | 3478 | UDP and TCP | anywhere | TURN (calls) |
    | 5349 | TCP | anywhere | TURN over TLS |
    | 49160–49200 | UDP | anywhere | TURN relay ports |
    | 9477 | — | **never** | `/metrics` listens on 127.0.0.1 only |

    Cloud firewall (any provider): create a firewall, add one inbound rule per row above, attach it to the server,
    then from the admin machine check `deploy/check.sh LABEL` (node port) and, for TURN, `deploy/status.sh` shows
    `TURN on`; a call between two phones on mobile data proves the UDP ports.
  * **Shared hosts:** when a node runs on a machine that also serves other things, every public listener that is not
    `otter-node` or `sshd` shows up as a WARN line in `harden-check.sh`. For each one decide: must it be reachable from
    the internet? If not, bind it to 127.0.0.1 or close it in the cloud firewall. Keep the list of such services and
    the decisions **outside the repositories** (they reveal what else runs on the host).
  * **Service sandbox:** `otter-node` runs as `otter` with the systemd sandbox of §5.5 (exposure 1.5 in
    `systemd-analyze security otter-node`; `deploy/sandbox-setup.sh LABEL` installs it on an older node with rollback).
    The binary, `/etc/otter` and all keys are root-owned; the service can write only `/var/lib/otter`.
  * Keys: `node.key`, `tls.key`, `turn.secret`, `reality.key` readable only by root and the `otter` group; the network
    key is never on a server.
  * (keep the existing "Servers hold no secrets…" and "Blocking note" bullets)
  ```

  §5.5: replace the unit listing with the Task 66 unit. §7: add rows "Health summary | `otter-node status` (on the
  server) / `deploy/status.sh` | no `!` lines" and "Hardening | `deploy/harden-check.sh` | no FAIL". §9 table: the
  M9 row becomes "M9.4 (done): limits and `disk_floor` in `[limits]`, `[metrics]` (loopback), `status.json`,
  `otter-node status`, sandboxed units via `sandbox-setup.sh` (also run by `upgrade-all.sh` 0.10.1+),
  `harden-check.sh`; DB migration 0012".

- [ ] **Step 2: §14 Three nodes from scratch.** Write it as numbered steps, each with the command, the expected
  output and "if not": (1) machines: three Debian 12 / Ubuntu 24.04 servers with root SSH keys, one marked "inside
  the censored network"; admin machine with Go 1.26, git, ssh; (2) `git clone` + `make build`; (3) `otter-admin
  network init` (passphrase typed, never stored); (4) per node `otter-admin node add --label … --wss-host … --ip …`,
  `deploy/hosts.sh set LABEL root@HOST`; (5) firewall rows of §8 on each server; (6) `deploy/add-node.sh` for the
  first node (bootstrap invite printed: keep it), the second, the third (answer «y» to the dial-out-only question
  for the censored one); (7) optional push (`deploy/push-key.sh`, §12) and REALITY on the foreign nodes
  (`deploy/reality-setup.sh`, §13); (8) `deploy/status.sh` → three rows `active`, health lines `peers=2/2 lag=0s`
  (dial-out-only node: `peers=2/2` as well, it dials out), no `!`; (9) `deploy/harden-check.sh` → no FAIL;
  (10) install the app on two phones from the release APK, join with the bootstrap invite and an invite from the
  first member, send a message and a photo, make a call; (11) day-2 pointers (§6, upgrades with `upgrade-all.sh`).

- [ ] **Step 3: Followed from scratch by someone else.** In a scratch copy of `otter-server` (never the real
  `dist/` or `~/.otter-admin`), start three VMs: `OTTER_VM=a OTTER_VM_SSH=2222 OTTER_VM_WSS=27443 deploy/test/vm.sh start`,
  `b` (2223/27444), `c` (2224/27445). Spawn a **fresh agent with no conversation context** whose prompt is only:
  "Follow `docs/11-deployment.md` §14 exactly to build a three-node Otter network on the VMs reachable as
  root@127.0.0.1 ports 2222/2223/2224 (SSH key `.vm/id`, use `OTTER_SSH_OPTS`), in the scratch repo at <path>,
  admin dir <scratch>/admin, passphrase from `OTTER_ADMIN_PASSPHRASE`. Do not read any other document. Log every
  step where the document was unclear, wrong or missing something, and every guess you made." (Phones: the agent
  uses `LiveClient`-style checks instead — `otter-node probe` and `deploy/status.sh` — and the human part of step
  10 is done once on emulators.) Fix every logged item in §14, reset the VMs, run a second fresh agent; repeat until
  a run logs no guesses. Keep the logs in the scratchpad (they contain VM addresses only).

- [ ] **Step 4: Monitoring and decisions.** `docs/08-operations.md` Monitoring: replace the two bullets with
  `otter-node status` / `status.sh` health block / `/metrics` (metric names from Task 64, the D119 thresholds, an
  example `ssh root@HOST curl -s 127.0.0.1:9477/metrics | grep otter_peer_lag`). `docs/00-decisions.md`: add D115–D124
  with the next free numbers (D82+ unless earlier M9 sections took them), amend D72 ("peer sessions have no
  keep-alive" → "peer sessions ping every 25 s (DXn); the 24 h idle timeout stays"), D31 ("No UI until M9" →
  "shown as `name#abcd` (M9.2); no rename (DXn)"). `docs/09-roadmap.md`: mark M9.4 done with an "M9.4 notes" block
  (built, deviations, open). Guide §10 and `07-android-architecture.md` Settings: the new rows.

- [ ] **Step 5: Manual checklists.** `otter-server/docs/m9.4-manual-test.md`: rows for status/health, `/metrics`
  on loopback only (`ss -ltnp | grep 9477` shows 127.0.0.1), a frozen peer link (`iptables -I INPUT -s PEER -j DROP`
  on a **VM**, never a real node) → `ping … timeout` in netlog within 85 s, disk floor on a VM (`fallocate -l` a
  filler file until below the floor) → photos refused, messages flow, `status.sh` shows `disk low`; limits (a loop
  of 40 `curl -k` to the node port from one VM → 429s); sandbox score; `harden-check.sh`. Android
  `docs/m9.4-manual-test.md`: app lock rows (enable, timeout, wrong PIN wait, biometric, forgot PIN, locked
  notification, recents, call while locked), «Запрет скриншотов», «Состояние сети» against a stopped node, battery
  helper on each real phone model, theme, recovery phrase, TalkBack walk of the PIN pad.

- [ ] **Step 6: Commit** (docs repo, then the checklist files in the code repos)

```bash
git add 11-deployment.md 08-operations.md 00-decisions.md 09-roadmap.md 07-android-architecture.md 10-otter-design-guidelines.md
oc -m "docs: three-node guide, security checklist with firewall and shared hosts, M9.4 decisions (M9.4)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

```bash
git add deploy/FIRST-DEPLOY.md deploy/README.md docs/m9.4-manual-test.md   # otter-server
oc -m "docs: M9.4 server checklist, pointer to the three-node guide" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git add docs/m9.4-manual-test.md                                             # otter-android
oc -m "docs: M9.4 app checklist" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 72: Versions, full verification, news draft; merge after the owner's OK

**Goal:** 0.10.1 builds and passes every automated check; the owner approves the merge.
**Findings closed:** —

**Files:**
- Modify: `otter-android/app/build.gradle.kts:35` (`versionCode = 14; versionName = "0.10.1"`)
- Create: `otter-server/dist/news/0.10.1.md` (ru/en sections, D69; written from the commits; never delete anything else in `dist/`)

**Acceptance Criteria:**
- [ ] `make check` (server) green; `./gradlew test assembleDebug assembleRelease lint` green; scratch-copy `deploy/test/scripts_test.sh` ok; `deploy/test/e2e-mesh.sh` ok (VMs).
- [ ] Dev mesh + two emulators: messages, photo, call, app lock, network status all work on 0.10.1 nodes; a 0.10.0 app against 0.10.1 nodes works (no protocol change).
- [ ] `scripts/secrets-check.sh` ok in all three repos; no `Claude-Session` trailer; commit dates UTC.
- [ ] The owner says "merge"; then `git merge --no-ff m9-4-ops` in each repo and push.

**Verify:** the commands above; `git log --format='%ad %s' -5` shows UTC times.

**Steps:**

- [ ] **Step 1:** bump the app version; build `make release VERSION=0.10.1` (writes `dist/otter-node_0.10.1_linux_*`).
- [ ] **Step 2:** run every check of the acceptance criteria; fix and re-run until green.
- [ ] **Step 3:** news draft `dist/news/0.10.1.md`:

```markdown
#### ru
Otter 0.10.1
• Блокировка приложения: PIN или отпечаток (Настройки → Безопасность).
• «Запрет скриншотов» для всего приложения.
• «Состояние сети»: видно, к какому узлу подключён телефон и не мешает ли Android работе в фоне.
• Тёмная/светлая тема и фраза восстановления в настройках.
Обновите приложение кнопкой «Обновить».

#### en
Otter 0.10.1
• App lock: PIN or fingerprint (Settings → Security).
• Block screenshots for the whole app.
• Network status: which node the phone uses and whether Android restricts Otter in the background.
• Dark/light theme and the recovery phrase in Settings.
Update with the «Обновить» button.
```

- [ ] **Step 4:** commit the version bump (`oc -m "app 0.10.1 (versionCode 14)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`),
  report to the owner with the test summary, and wait. Merge with `--no-ff` only after the owner's explicit OK;
  push after `secrets-check.sh`.

---

### Task 73: Release server 0.10.1 + app 0.10.1 and rollout (each step asked first)

**Goal:** Every node runs 0.10.1 in the new sandbox with health and hardening reports reviewed; both phones on 0.10.1.
**Findings closed:** —

**Files:** none in git (state lives on the servers, in `~/.otter-admin`, on the phones; private findings in `~/Documents/otter-private`).

**Acceptance Criteria:**
- [ ] `deploy/status.sh` → every node `active`, health line without `!`; `deploy/harden-check.sh` → no FAIL, every WARN discussed with the owner.
- [ ] `systemd-analyze security otter-node` on each node ≤ 2.0 (before/after values recorded in the private notes).
- [ ] The host's other services on eeee still answer after the upgrade; nothing on the host was changed except by an explicit owner "yes" per item.
- [ ] Both phones on 0.10.1 via «Обновить»; the real-network rows of both `m9.4-manual-test.md` filled.

**Verify:** the owner marks the rows PASS (or records what failed).

**Steps (ask before each; passphrases only in the owner's terminal; never touch the servers otherwise):**

- [ ] **Step 1 (ask):** baseline, read-only: `deploy/status.sh` and `deploy/harden-check.sh`. Show the output to the
  owner. Expected WARN on eeee: public listeners of the host's other services (the ports the owner already noted
  privately) and "exposure 3.8".
- [ ] **Step 2 (owner, read-only checklist for the shared host; commands are run only after the owner says yes):**
  for each WARN listener on eeee: `ss -ltnup 'sport = :PORT'` (which process), `ps -o unit= -p PID` (which unit),
  `curl -sI http://127.0.0.1:PORT/ | head -3` (what answers), and the provider panel's firewall rules for that port.
  The owner decides per port: keep public / bind to 127.0.0.1 / close or restrict in the cloud firewall. Record the
  decisions in `~/Documents/otter-private/ops/shared-host-ports.md` (never in a repo). Any change is its own step:
  state the exact command and how to undo it, ask, then do it.
- [ ] **Step 3 (ask):** `deploy/upgrade-all.sh 0.10.1 --no-news` → each node: binary swap with health check and
  rollback, TURN kept, then `sandbox-setup.sh --if-older` prints exposure before → after (3.8 → 1.5) and rolls back
  on a failed health check. Right after eeee: `ss -ltnp` shows the other services' listeners as before, and the
  owner confirms those services still answer.
- [ ] **Step 4 (ask):** `deploy/status.sh` → health lines; `ssh root@eeee curl -s 127.0.0.1:9477/metrics | grep -E 'otter_peer_(lag|backlog)'`
  (read-only) → ru-1 lag 0; `deploy/harden-check.sh` → `PASS sandbox: exposure 1.5`.
- [ ] **Step 5 (owner decides, item by item):** remaining FAIL/WARN of `harden-check.sh`: SSH options, unattended-
  upgrades, pending reboot (a reboot is announced to the family first), cloud firewall rows for TURN and the node
  port (owner, in the provider panel; compare with docs/11 §8). Each change: exact command, undo command, ask.
- [ ] **Step 6 (owner runs):** `deploy/release-apk.sh 0.10.1 <release APK>` → news dialog with `dist/news/0.10.1.md`;
  phones update via «Обновить».
- [ ] **Step 7 (owner, phones):** app lock (PIN, fingerprint, timeout, notification while locked, call while locked),
  «Запрет скриншотов», «Состояние сети» (eeee and ru-1 rows), battery helper on both phone models («Не ограничивать
  Otter» + the vendor's autostart page), theme, recovery phrase. Fill both checklists.
- [ ] **Step 8 (owner, optional):** hand `docs/11-deployment.md` §14 to a second person for a dry read (or a real run
  on their own test servers) and collect questions; fixes go into a docs commit.

---

### Owner questions (with the recommended answer the tasks assume)

1. **Username rename screen (D31)?** Recommended: **no rename** (D122). M9.2 C12 shows `name#abcd` and asks for the tag
   at restore; a rename path would need its own ranking rule against M9.2's invite-chain rank. Revisit in V1.x.
2. **Battery helper: direct system dialog?** Recommended: **yes**, `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` with
   the `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` permission (Google Play restricts it, but Otter is installed from its
   own APK); fallback to the system list.
3. **App lock details:** «Забыли PIN?» turns the lock off after the phone's own screen lock — recommended **yes**
   (the alternative is reinstall + restore). While the lock is on, notifications hide sender and text and lose
   «Ответить» — recommended **yes** (otherwise the lock protects little). Default timeout **1 minute**.
4. **Limit defaults** (32 connections and 30 new per minute per IP, 50 req/s, public methods 20/min, writes burst
   300 then 1/s, undelivered 256 MiB per author): recommended **as listed**; the family's phones behind one
   home router or one mobile CGNAT address stay far below them.
5. **`disk_floor` default 1 GiB** (critical at 256 MiB, full at 64 MiB): recommended **yes**; raise it per node in
   `node.toml` if a node has a large disk.
6. **Who is "someone else" for the guide?** Recommended: a **fresh-context agent on three local VMs** is the
   acceptance (repeatable, no real servers); the owner's optional second person (Task 73 Step 8) is a bonus.
7. **Recovery phrase in Settings?** Recommended: **yes**, only after the phone's screen lock, with FLAG_SECURE
   (guide §10 already lists it; today the words can only be seen once at registration).
8. **`/metrics` on by default** on 127.0.0.1:9477? Recommended: **yes** (loopback only, never in a firewall rule;
   `listen = "off"` disables).
