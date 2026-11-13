# M7 DPI Transports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A domestic node (Russia) reaches foreign nodes over VLESS+REALITY on :443 with a WSS fallback, never being
dialed itself; nodes and phones keep a short connectivity log and demote throttled endpoints.

**Architecture:** `otter-node` embeds Xray-core (Go library). A foreign node runs a REALITY inbound on :443 whose
only outbound is a `freedom` redirect to an internal plain-HTTP listener on 127.0.0.1 serving the existing mux; the
domestic node dials through an in-process Xray client (`core.Dial`) and runs the unchanged peer handshake inside.
The replication dialer becomes per-endpoint (ranking, demotion, netlog). Phones only gain failure classification,
demotion and a local «Журнал подключений».

**Tech Stack:** Go 1.26, `github.com/xtls/xray-core v1.260327.0`, `github.com/coder/websocket`, SQLite migrations,
bash deploy scripts; Android Kotlin, Room (AutoMigration 6→7), Hilt, Compose.

**Spec:** `docs/superpowers/specs/2026-11-13-m7-dpi-transports-design.md` (owner approved 2026-11-13).

**Ground rules (owner):**
* Branch `m7-dpi` in `otter-server` and `otter-android` (and `otter-docs` for docs); merge with `--no-ff` **only
  after the owner says so**.
* Ask before touching any real server (`root@eeee`, the ru-1 node), DNS, `~/.otter-admin`, or the phones. Never ask
  for passphrases in chat — the owner types them in their own terminal. Never delete anything in
  `otter-server/dist/`.
* Gradle: `export JAVA_HOME=~/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2`. Run `scripts/secrets-check.sh` in
  both repos before every push. Every APK for the phones is release-signed (`keystore.properties` + `release.jks`).
* Commits end with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01S4HpRE25HCYGuf99akymrv
  ```
* Versions: server 0.7.0, app 0.7.0 (versionCode 7).

**Decisions to record (Task 12):** D70 domestic relay + REALITY server-to-server only; D71 `dial_out_only`; D72
embedded Xray REALITY inbound on :443 (revises D26 for REALITY) → freedom redirect to an internal listener; D73
failure classes + demotion; D74 connectivity log (nodes + phones, merged, 200 lines, phone log local only); D75
CDN-WSS and app REALITY postponed.

## File map

**otter-server**
| File | Responsibility |
|---|---|
| `proto/otter/v1/manifest.proto` | `NodeInfo.dial_out_only = 6` |
| `internal/admin/nodeops.go`, `cmd/otter-admin/main.go` | `node set-dial-out-only`, `node add-reality`, `node list` shows flags |
| `internal/netlog/netlog.go` (new) | failure classes, `Classify`, `Entry`, `Logger` interface |
| `internal/store/migrations/0008_netlog.sql`, `internal/store/netlog.go` (new) | merged 200-line log |
| `internal/replication/endpoints.go` (new) | `EndpointDialer`, `Ranker`, `MultiDialer` |
| `internal/replication/dialer.go` | `NetDialer.DialEndpoint` (WSS / WS_PLAIN / REALITY) |
| `internal/replication/replicator.go`, `session.go` | skip `dial_out_only`, inbound/outbound netlog, `reset_after_kb` |
| `internal/reality/` (new: `keys.go`, `server.go`, `client.go`, `check.go`) | Xray instances, keygen, camouflage check |
| `internal/config/config.go` | optional `[reality]` section |
| `internal/nodecheck/check.go` | checks the REALITY key file |
| `cmd/otter-node/main.go` | wiring, `reality keygen`, `reality-check`, `netlog` |
| `internal/meshsim/reality_test.go` (new), `partition_test.go` | censor scenarios |
| `deploy/templates/otter-node.service`, `deploy/reality-setup.sh` (new), `deploy/add-node.sh`, `deploy/upgrade.sh`, `deploy/status.sh`, `deploy/test/scripts_test.sh` | ops |

**otter-android**
| File | Responsibility |
|---|---|
| `core/proto/src/main/proto/otter/v1/manifest.proto` | synced (`scripts/sync-proto.sh`) |
| `core/network/.../FailureClass.kt` (new) | classes + classification |
| `core/network/.../NetLog.kt` (new) | `NetLog` interface + `NetLogEntry` |
| `core/network/.../Transport.kt`, `OkHttpTransport.kt` | `Connection.bytesIn` |
| `core/network/.../EndpointStats.kt`, `NodeSelector.kt`, `ConnectionManager.kt` | demotion, logging |
| `core/database/.../entity/NetLogEntity.kt`, `dao/NetLogDao.kt` (new), `entity/EndpointStatEntity.kt`, `OtterDatabase.kt` | Room v7 |
| `core/data/.../network/RoomNetLog.kt`, `NetworkInfo.kt` (new), `RoomEndpointStats.kt`, `di/DataModule.kt` | persistence |
| `feature/settings/.../NetLogScreen.kt` (new), `SettingsScreen.kt`, strings | UI |
| `app/.../AppNavHost.kt`, `app/build.gradle.kts` | route, version 0.7.0 / 7 |

---

### Task 1: Branches, proto flag and admin commands

**Goal:** `NodeInfo.dial_out_only` exists; `otter-admin` can set it and add a REALITY endpoint.

**Files:**
- Modify: `otter-server/proto/otter/v1/manifest.proto:17-23`
- Modify: `otter-server/internal/admin/nodeops.go` (append), `otter-server/cmd/otter-admin/main.go` (usage + cases)
- Test: `otter-server/internal/admin/nodeops_test.go`, `otter-server/cmd/otter-admin/main_test.go`

**Acceptance Criteria:**
- [ ] `make gen` regenerates Go code; `NodeInfo.DialOutOnly` exists; default false for existing nodes.
- [ ] `node set-dial-out-only --label L [--off]` toggles it; unknown label → `ErrNotFound`.
- [ ] `node add-reality --label L --host H --port 443 --pub B64URL --server-name S [--short-id HEX]` appends a
  `REALITY` endpoint (WSS stays at index 0), copies the WSS `path`, generates a UUID and an 8-hex-char short id when
  absent; a second call replaces the existing REALITY endpoint.
- [ ] `node list` prints `dial_out_only=true` and REALITY endpoints with their server name.

**Verify:** `cd otter-server && make gen && go test ./internal/admin/ ./cmd/otter-admin/` → `ok`

**Steps:**

- [ ] **Step 1: Branches**

```bash
cd ~/Documents/Projects/OttterMSG
for r in otter-server otter-android docs; do git -C $r checkout main && git -C $r pull --ff-only && git -C $r checkout -b m7-dpi; done
```

- [ ] **Step 2: Proto field** — in `manifest.proto` `message NodeInfo` add after `endpoints = 5`:

```proto
  bool dial_out_only = 6;            // M7 (D71): inside a censored network; dials peers, is never dialed by them
```

Run `make gen`. Expected: `internal/proto/otterv1/manifest.pb.go` has `DialOutOnly`.

- [ ] **Step 3: Failing tests** — append to `internal/admin/nodeops_test.go`:

```go
func TestSetDialOutOnly(t *testing.T) {
	dir := newNet(t)
	get := func() bool {
		st, err := LoadState(dir)
		if err != nil {
			t.Fatal(err)
		}
		return st.Nodes[0].DialOutOnly
	}
	if get() {
		t.Fatal("dial_out_only must default to false")
	}
	if err := SetDialOutOnly(dir, "fi-1", true); err != nil || !get() {
		t.Fatalf("set: %v %v", err, get())
	}
	if err := SetDialOutOnly(dir, "fi-1", false); err != nil || get() {
		t.Fatalf("off: %v %v", err, get())
	}
	if err := SetDialOutOnly(dir, "nope", true); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown label: %v", err)
	}
}

func TestAddReality(t *testing.T) {
	dir := newNet(t)
	pub := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))
	ep, err := AddReality(dir, RealitySpec{Label: "fi-1", Host: "203.0.113.10", Port: 443, Pub: pub, ServerName: "www.example.com"})
	if err != nil {
		t.Fatal(err)
	}
	if ep.Kind != pb.Endpoint_REALITY || len(ep.RealityPub) != 32 || len(ep.ShortIds) != 1 || len(ep.ShortIds[0]) != 8 ||
		ep.VlessUuid == "" || ep.Fingerprint != "chrome" || ep.ServerNames[0] != "www.example.com" {
		t.Fatalf("endpoint: %+v", ep)
	}
	st, _ := LoadState(dir)
	n := st.Nodes[0]
	if len(n.Endpoints) != 2 || n.Endpoints[0].Kind != pb.Endpoint_WSS || n.Endpoints[1].Path != n.Endpoints[0].Path {
		t.Fatalf("endpoints: %+v", n.Endpoints)
	}
	if _, err := AddReality(dir, RealitySpec{Label: "fi-1", Host: "203.0.113.10", Port: 443, Pub: pub, ServerName: "b.example", ShortID: "abcd0123"}); err != nil {
		t.Fatal(err)
	}
	st, _ = LoadState(dir)
	if len(st.Nodes[0].Endpoints) != 2 || st.Nodes[0].Endpoints[1].ShortIds[0] != "abcd0123" {
		t.Fatalf("second add-reality must replace: %+v", st.Nodes[0].Endpoints)
	}
	if _, err := AddReality(dir, RealitySpec{Label: "fi-1", Host: "h", Port: 443, Pub: "short", ServerName: "s"}); err == nil {
		t.Fatal("bad public key accepted")
	}
}
```

Add imports `bytes`, `encoding/base64` if missing. Run `go test ./internal/admin/ -run 'DialOut|AddReality'` →
FAIL (undefined).

- [ ] **Step 4: Implement** — append to `internal/admin/nodeops.go`:

```go
// SetDialOutOnly marks a node inside a censored network: it dials its peers and is never dialed (D71).
func SetDialOutOnly(dir, label string, on bool) error {
	st, err := LoadState(dir)
	if err != nil {
		return err
	}
	n, err := findNode(st, label)
	if err != nil {
		return err
	}
	n.DialOutOnly = on
	return saveNodes(dir, st.Nodes)
}

type RealitySpec struct {
	Label, Host, Pub, ServerName, ShortID string
	UUID                                  string // the node's [reality].vless_uuid; generated when empty
	Port                                  uint32
}

// AddReality adds (or replaces) the node's VLESS+REALITY endpoint (D72). Pub is the node's X25519 public key in
// base64 RawURL encoding, printed by `otter-node reality keygen`. The WSS endpoint stays first.
func AddReality(dir string, s RealitySpec) (*pb.Endpoint, error) {
	st, err := LoadState(dir)
	if err != nil {
		return nil, err
	}
	n, err := findNode(st, s.Label)
	if err != nil {
		return nil, err
	}
	pub, err := base64.RawURLEncoding.DecodeString(s.Pub)
	if err != nil || len(pub) != 32 {
		return nil, errors.New("--pub must be the 32-byte X25519 public key in base64 RawURL encoding (otter-node reality keygen)")
	}
	if s.Host == "" || s.ServerName == "" || s.Port == 0 || s.Port > 65535 {
		return nil, errors.New("--host, --port and --server-name are required")
	}
	sid := s.ShortID
	if sid == "" {
		b := make([]byte, 4)
		if _, err := rand.Read(b); err != nil {
			return nil, err
		}
		sid = hex.EncodeToString(b)
	}
	if _, err := hex.DecodeString(sid); err != nil || len(sid) > 16 || len(sid)%2 != 0 {
		return nil, errors.New("--short-id must be 2-16 hex characters, even length")
	}
	path := ""
	keep := n.Endpoints[:0]
	uuid := newUUID()
	for _, e := range n.Endpoints {
		if e.Kind == pb.Endpoint_WSS && path == "" {
			path = e.Path
		}
		if e.Kind == pb.Endpoint_REALITY {
			uuid = e.VlessUuid // keep the UUID across replacements: nodes' configs already use it
			continue
		}
		keep = append(keep, e)
	}
	if path == "" {
		return nil, fmt.Errorf("node %s has no WSS endpoint to take the secret path from", s.Label)
	}
	ep := &pb.Endpoint{Kind: pb.Endpoint_REALITY, Host: s.Host, Port: s.Port, Path: path, VlessUuid: uuid,
		RealityPub: pub, ShortIds: []string{sid}, ServerNames: []string{s.ServerName}, Fingerprint: "chrome"}
	if s.UUID != "" {
		ep.VlessUuid = s.UUID // reality-setup.sh passes the UUID it wrote into the node's config
	}
	n.Endpoints = append(keep, ep)
	return ep, saveNodes(dir, st.Nodes)
}
```

Add `crypto/rand` to imports. `newUUID()` already exists in `state.go`.

- [ ] **Step 5: CLI** — in `cmd/otter-admin/main.go` usage after `node set-push` add:

```
  node set-dial-out-only --label L [--off]
  node add-reality --label L --host H --port 443 --pub B64URL --server-name S [--short-id HEX] [--uuid UUID]
```

(also add a `TestAddReality` sub-case: `UUID: "d6a3f0b2-1c2d-4e5f-8a9b-0c1d2e3f4a5b"` → `ep.VlessUuid` equals it), and cases after `case "node set-push":`:

```go
	case "node set-dial-out-only":
		fs := flag.NewFlagSet("node set-dial-out-only", flag.ContinueOnError)
		label := fs.String("label", "", "node label")
		off := fs.Bool("off", false, "the node may be dialed again")
		if err := fs.Parse(a[2:]); err != nil {
			return err
		}
		if err := admin.SetDialOutOnly(*dir, *label, !*off); err != nil {
			return err
		}
		fmt.Fprintf(out, "node %s: dial_out_only=%v. Run 'manifest sign' and 'manifest publish'.\n", *label, !*off)
	case "node add-reality":
		fs := flag.NewFlagSet("node add-reality", flag.ContinueOnError)
		var s admin.RealitySpec
		var port uint
		fs.StringVar(&s.Label, "label", "", "node label")
		fs.StringVar(&s.Host, "host", "", "public IP or name of the node")
		fs.UintVar(&port, "port", 443, "REALITY port")
		fs.StringVar(&s.Pub, "pub", "", "X25519 public key (otter-node reality keygen)")
		fs.StringVar(&s.ServerName, "server-name", "", "camouflage site name, e.g. www.microsoft.com")
		fs.StringVar(&s.ShortID, "short-id", "", "REALITY short id (hex; random if empty)")
		fs.StringVar(&s.UUID, "uuid", "", "VLESS UUID used in the node's [reality] (random if empty)")
		if err := fs.Parse(a[2:]); err != nil {
			return err
		}
		s.Port = uint32(port)
		ep, err := admin.AddReality(*dir, s)
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "node %s: REALITY %s:%d server_name=%s\n[reality] for its node.toml:\n  vless_uuid = %q\n  short_ids = [%q]\n  server_names = [%q]\nRun 'manifest sign' and 'manifest publish'.\n",
			s.Label, ep.Host, ep.Port, s.ServerName, ep.VlessUuid, ep.ShortIds[0], s.ServerName)
```

In `case "node list":` print the flag and REALITY fields — replace the `Fprintf` line with:

```go
				extra := ""
				if e.Kind == pb.Endpoint_REALITY && len(e.ServerNames) > 0 {
					extra = " sni=" + e.ServerNames[0]
				}
				fmt.Fprintf(out, "%-12s %x  %s %s:%d%s cdn=%v pin=%s dial_out_only=%v%s\n", n.Label, n.NodeId, e.Kind, e.Host, e.Port, e.Path, e.ViaCdn, pin, n.DialOutOnly, extra)
```

Add a CLI test to `cmd/otter-admin/main_test.go` following the existing `set-push` test pattern (run
`network init` with the test passphrase helper used there, `node add`, then `node set-dial-out-only --label fi-1` and
check the output contains `dial_out_only=true`; then `node list` contains `dial_out_only=true`).

- [ ] **Step 6: Run tests** — `go test ./internal/admin/ ./cmd/otter-admin/` → `ok`; `make check` → passes.

- [ ] **Step 7: Commit**

```bash
git add proto internal/proto internal/admin cmd/otter-admin
git commit -m "feat(admin): dial_out_only node flag and REALITY endpoints (D71, D72)"
```

---

### Task 2: Failure classes and the node connectivity log

**Goal:** A `netlog` package classifies connection failures; the store keeps a merged log of at most 200 lines.

**Files:**
- Create: `otter-server/internal/netlog/netlog.go`, `otter-server/internal/netlog/netlog_test.go`
- Create: `otter-server/internal/store/migrations/0008_netlog.sql`, `otter-server/internal/store/netlog.go`,
  `otter-server/internal/store/netlog_test.go`

**Acceptance Criteria:**
- [ ] `Classify(err, bytesIn)` returns `ok`, `timeout`, `refused`, `reset`, `reset_after_kb` (≥ 1024 bytes in),
  `tls`, `handshake`.
- [ ] `Store.NetlogAdd` merges into the newest line for the same `(peer, endpoint, direction)` when `result` and
  `class` match (count+1, last_ms updated), otherwise inserts; never more than 200 lines.
- [ ] `Store.Netlog(limit)` returns newest first.

**Verify:** `go test ./internal/netlog/ ./internal/store/ -run 'Classify|Netlog'` → `ok`

**Steps:**

- [ ] **Step 1: Failing tests** — `internal/netlog/netlog_test.go`:

```go
package netlog

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"syscall"
	"testing"
)

type timeoutErr struct{}

func (timeoutErr) Error() string   { return "i/o timeout" }
func (timeoutErr) Timeout() bool   { return true }
func (timeoutErr) Temporary() bool { return true }

func TestClassify(t *testing.T) {
	cases := []struct {
		err   error
		bytes int64
		want  Class
	}{
		{nil, 0, OK},
		{context.DeadlineExceeded, 0, Timeout},
		{&net.OpError{Op: "dial", Err: timeoutErr{}}, 0, Timeout},
		{&net.OpError{Op: "dial", Err: syscall.ECONNREFUSED}, 0, Refused},
		{&net.OpError{Op: "read", Err: syscall.ECONNRESET}, 0, Reset},
		{&net.OpError{Op: "read", Err: syscall.ECONNRESET}, 4096, ResetAfterKB},
		{io.ErrUnexpectedEOF, 2048, ResetAfterKB},
		{io.EOF, 10, Reset},
		{tls.AlertError(40), 0, TLS},
		{fmt.Errorf("x: %w", &tls.CertificateVerificationError{Err: errors.New("pin")}), 0, TLS},
		{fmt.Errorf("x: %w", ErrHandshake), 0, Handshake},
		{errors.New("something else"), 0, Reset},
	}
	for i, c := range cases {
		if got := Classify(c.err, c.bytes); got != c.want {
			t.Errorf("%d: Classify(%v, %d) = %s, want %s", i, c.err, c.bytes, got, c.want)
		}
	}
}
```

`internal/store/netlog_test.go` (use the package's existing test helper that opens a temp store — in
`store_test.go` it is the function returning `*Store` for `t.TempDir()`; call it `openTest(t)` below and rename to
match):

```go
func TestNetlogMergeAndCap(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	e := NetlogEntry{Peer: "eeee", Endpoint: "reality:443", Direction: "out", Result: "ok", Class: "ok"}
	for i := 0; i < 3; i++ {
		if err := s.NetlogAdd(ctx, e); err != nil {
			t.Fatal(err)
		}
	}
	fail := e
	fail.Result, fail.Class, fail.Detail = "fail", "timeout", "dial tcp: i/o timeout"
	if err := s.NetlogAdd(ctx, fail); err != nil {
		t.Fatal(err)
	}
	if err := s.NetlogAdd(ctx, e); err != nil {
		t.Fatal(err)
	}
	got, err := s.Netlog(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 || got[0].Count != 1 || got[0].Class != "ok" || got[1].Class != "timeout" || got[2].Count != 3 {
		t.Fatalf("lines: %+v", got)
	}
	other := e
	for i := 0; i < 250; i++ {
		other.Endpoint = fmt.Sprintf("wss:%d", i) // distinct keys: no merging
		if err := s.NetlogAdd(ctx, other); err != nil {
			t.Fatal(err)
		}
	}
	all, _ := s.Netlog(ctx, 1000)
	if len(all) != NetlogMax {
		t.Fatalf("cap: %d lines", len(all))
	}
	if all[0].Endpoint != "wss:249" {
		t.Fatalf("newest first: %s", all[0].Endpoint)
	}
}
```

Run → FAIL (undefined).

- [ ] **Step 2: `internal/netlog/netlog.go`**

```go
// Package netlog classifies connection outcomes for the connectivity log and endpoint demotion (D73, D74).
package netlog

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"syscall"
)

type Class string

const (
	OK           Class = "ok"
	Timeout      Class = "timeout"
	Refused      Class = "refused"
	Reset        Class = "reset"          // dropped before any useful data
	ResetAfterKB Class = "reset_after_kb" // dropped after ≥ 1 KB: typical throttling
	TLS          Class = "tls"            // alert, bad certificate, pin mismatch
	Handshake    Class = "handshake"      // transport worked, the node handshake failed
)

// ThrottleBytes is the minimum received before a reset counts as throttling.
const ThrottleBytes = 1024

// ErrHandshake wraps node-handshake failures so they classify as Handshake.
var ErrHandshake = errors.New("node handshake failed")

func Classify(err error, bytesIn int64) Class {
	if err == nil {
		return OK
	}
	if errors.Is(err, ErrHandshake) {
		return Handshake
	}
	var alert tls.AlertError
	var verr *tls.CertificateVerificationError
	var rec tls.RecordHeaderError
	if errors.As(err, &alert) || errors.As(err, &verr) || errors.As(err, &rec) {
		return TLS
	}
	if errors.Is(err, syscall.ECONNREFUSED) {
		return Refused
	}
	var ne net.Error
	if errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &ne) && ne.Timeout()) {
		return Timeout
	}
	if bytesIn >= ThrottleBytes {
		return ResetAfterKB
	}
	_ = io.EOF // EOF, ECONNRESET and anything unknown before data: a plain reset
	return Reset
}

// Entry is one log observation; the store merges repeats.
type Entry struct {
	Peer, Endpoint, Direction, Result, Detail string
	Class                                     Class
}

// Logger records observations; implementations must not block for long.
type Logger interface {
	Add(ctx context.Context, e Entry)
}

// Nop discards everything (tests, commands without a store).
type Nop struct{}

func (Nop) Add(context.Context, Entry) {}

// Result is "ok" or "fail" for a class.
func Result(c Class) string {
	if c == OK {
		return "ok"
	}
	return "fail"
}
```

Remove the `_ = io.EOF` line and the `io` import if `go vet` complains — it is only documentation.

- [ ] **Step 3: Migration** `internal/store/migrations/0008_netlog.sql`:

```sql
-- M7 (D74): connectivity log; repeats of the same outcome update one line. Capped at 200 lines by the store.
CREATE TABLE netlog(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  peer TEXT NOT NULL, endpoint TEXT NOT NULL, direction TEXT NOT NULL,
  result TEXT NOT NULL, class TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '',
  count INTEGER NOT NULL, first_ms INTEGER NOT NULL, last_ms INTEGER NOT NULL
);
CREATE INDEX netlog_key ON netlog(peer, endpoint, direction, id);
```

- [ ] **Step 4: `internal/store/netlog.go`**

```go
package store

import (
	"context"
	"database/sql"
	"errors"
)

const NetlogMax = 200

type NetlogEntry struct {
	ID                                               int64
	Peer, Endpoint, Direction, Result, Class, Detail string
	Count                                            int64
	FirstMs, LastMs                                  int64
}

// NetlogAdd merges e into the newest line for the same peer/endpoint/direction if result and class match,
// otherwise adds a line; keeps the newest NetlogMax lines (D74).
func (s *Store) NetlogAdd(ctx context.Context, e NetlogEntry) error {
	now := s.now().UnixMilli()
	return s.write(ctx, func(ctx context.Context, tx *sql.Tx) error {
		var id int64
		var result, class string
		err := tx.QueryRowContext(ctx, `SELECT id, result, class FROM netlog WHERE peer=? AND endpoint=? AND direction=?
			ORDER BY id DESC LIMIT 1`, e.Peer, e.Endpoint, e.Direction).Scan(&id, &result, &class)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		if err == nil && result == e.Result && class == e.Class {
			_, err = tx.ExecContext(ctx, `UPDATE netlog SET count=count+1, last_ms=?, detail=? WHERE id=?`, now, e.Detail, id)
			return err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO netlog(peer,endpoint,direction,result,class,detail,count,first_ms,last_ms)
			VALUES(?,?,?,?,?,?,1,?,?)`, e.Peer, e.Endpoint, e.Direction, e.Result, e.Class, e.Detail, now, now); err != nil {
			return err
		}
		_, err = tx.ExecContext(ctx, `DELETE FROM netlog WHERE id NOT IN (SELECT id FROM netlog ORDER BY id DESC LIMIT ?)`, NetlogMax)
		return err
	})
}

// Netlog returns up to limit lines, the most recently updated first.
func (s *Store) Netlog(ctx context.Context, limit int) ([]NetlogEntry, error) {
	rows, err := s.r.QueryContext(ctx, `SELECT id,peer,endpoint,direction,result,class,detail,count,first_ms,last_ms
		FROM netlog ORDER BY last_ms DESC, id DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []NetlogEntry
	for rows.Next() {
		var e NetlogEntry
		if err := rows.Scan(&e.ID, &e.Peer, &e.Endpoint, &e.Direction, &e.Result, &e.Class, &e.Detail, &e.Count, &e.FirstMs, &e.LastMs); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}
```

The test's "newest first" ordering relies on `last_ms DESC, id DESC`; inserts in the same millisecond fall back to
`id`, so `got[0]` is the merged-ok line only if it was updated last — it was (step order in the test). If the test
runs within one millisecond, `got[0]` (id 3, last insert) still wins by id.

- [ ] **Step 5: Store adapter for the logger** — a new file `internal/netlog/store.go` (netlog imports store, never
the other way round):

```go
package netlog

import (
	"context"

	"ottermsg/server/internal/store"
)

// StoreLogger writes observations to the node database (best effort).
type StoreLogger struct{ S *store.Store }

func (l StoreLogger) Add(ctx context.Context, e Entry) {
	_ = l.S.NetlogAdd(context.WithoutCancel(ctx), store.NetlogEntry{Peer: e.Peer, Endpoint: e.Endpoint,
		Direction: e.Direction, Result: e.Result, Class: string(e.Class), Detail: truncate(e.Detail, 200)})
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}
```

- [ ] **Step 6: Run** `go test ./internal/netlog/ ./internal/store/` → `ok`.

- [ ] **Step 7: Commit** — `git add internal/netlog internal/store && git commit -m "feat(netlog): failure classes and merged connectivity log (D73, D74)"`

---

### Task 3: Per-endpoint dialing, ranking, demotion, `dial_out_only`

**Goal:** The replicator dials peers endpoint by endpoint in ranked order, logs every attempt and session end,
skips `dial_out_only` peers, and demotes throttled endpoints.

**Files:**
- Create: `otter-server/internal/replication/endpoints.go`, `otter-server/internal/replication/endpoints_test.go`
- Modify: `otter-server/internal/replication/dialer.go` (whole file), `replicator.go` (`New`, `ServeHTTP`,
  `runSession`, `dialMissing`), `session.go` (`bytesIn` counter), `handshake.go` (wrap errors)
- Modify: `otter-server/internal/meshsim/partition_test.go` (gated dialer becomes an `EndpointDialer`),
  `harness_test.go` (`replication.New` call)

**Acceptance Criteria:**
- [ ] `Ranker.Order` puts the last success (7 days) first, then admin `priority`, then manifest order; endpoints
  failed in the last 10 min go last; endpoints with ≥ 3 `reset_after_kb` in 24 h go after everything for 24 h.
- [ ] `MultiDialer.Dial` tries endpoints in that order and logs each attempt (`out`, class, detail).
- [ ] Nodes never dial a peer with `dial_out_only`; a `dial_out_only` node dials everyone.
- [ ] Inbound peer sessions are logged (`in`, endpoint = the listener name: `wss` or `reality`).
- [ ] An outbound session that ends with an error after ≥ 1 KB received and < 2 min logs `reset_after_kb` and counts
  toward demotion.
- [ ] All existing replication and meshsim tests pass.

**Verify:** `go test ./internal/replication/ ./internal/meshsim/` → `ok`

**Steps:**

- [ ] **Step 1: Failing tests** — `internal/replication/endpoints_test.go`:

```go
package replication

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"ottermsg/server/internal/netlog"
	pb "ottermsg/server/internal/proto/otterv1"
)

func eps(names ...string) []*pb.Endpoint {
	var out []*pb.Endpoint
	for _, n := range names {
		out = append(out, &pb.Endpoint{Kind: pb.Endpoint_WSS, Host: n, Port: 1})
	}
	return out
}

func hosts(es []*pb.Endpoint) string {
	s := ""
	for _, e := range es {
		s += e.Host
	}
	return s
}

func TestRankerOrder(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	r := NewRanker(func() time.Time { return now })
	e := eps("a", "b", "c", "d")
	e[2].Priority = 0
	e[0].Priority, e[1].Priority, e[3].Priority = 5, 5, 5
	if got := hosts(r.Order(e)); got != "cabd" {
		t.Fatalf("priority then manifest order: %s", got)
	}
	r.Done(e[3], netlog.OK)
	r.Done(e[2], netlog.Timeout)
	if got := hosts(r.Order(e)); got != "dabc" {
		t.Fatalf("success first, recent failure last: %s", got)
	}
	for i := 0; i < 3; i++ {
		r.Done(e[3], netlog.ResetAfterKB)
	}
	if got := hosts(r.Order(e)); got != "abcd" {
		t.Fatalf("throttled endpoint demoted below failures: %s", got)
	}
	now = now.Add(25 * time.Hour)
	r.Done(e[3], netlog.OK)
	if got := hosts(r.Order(e)); got[0] != 'd' {
		t.Fatalf("demotion expires after 24h: %s", got)
	}
}

type fakeEP struct {
	mu    sync.Mutex
	fail  map[string]error
	tried []string
}

func (f *fakeEP) DialEndpoint(ctx context.Context, n *pb.NodeInfo, ep *pb.Endpoint) (*websocket.Conn, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.tried = append(f.tried, ep.Host)
	if err := f.fail[ep.Host]; err != nil {
		return nil, err
	}
	return nil, errSkip // never reached in this test
}

var errSkip = errors.New("unused")

type memLog struct {
	mu sync.Mutex
	es []netlog.Entry
}

func (m *memLog) Add(_ context.Context, e netlog.Entry) { m.mu.Lock(); m.es = append(m.es, e); m.mu.Unlock() }

func TestMultiDialerTriesAllAndLogs(t *testing.T) {
	f := &fakeEP{fail: map[string]error{"a": context.DeadlineExceeded, "b": context.DeadlineExceeded}}
	log := &memLog{}
	d := &MultiDialer{EP: f, Rank: NewRanker(time.Now), Log: log}
	n := &pb.NodeInfo{Label: "eeee", Endpoints: eps("a", "b")}
	if _, err := d.Dial(context.Background(), n); err == nil {
		t.Fatal("expected failure")
	}
	if len(f.tried) != 2 || len(log.es) != 2 || log.es[0].Class != netlog.Timeout || log.es[0].Peer != "eeee" ||
		log.es[0].Direction != "out" || log.es[0].Endpoint != "wss:a:1" {
		t.Fatalf("tried %v log %+v", f.tried, log.es)
	}
}
```

Run `go test ./internal/replication/ -run 'Ranker|MultiDialer'` → FAIL.

- [ ] **Step 2: `internal/replication/endpoints.go`**

```go
package replication

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"ottermsg/server/internal/netlog"
	pb "ottermsg/server/internal/proto/otterv1"
)

// EndpointDialer opens a peer WebSocket over one endpoint.
type EndpointDialer interface {
	DialEndpoint(ctx context.Context, n *pb.NodeInfo, ep *pb.Endpoint) (*websocket.Conn, error)
}

// EndpointName is the log/rank key: "reality:host:443", "wss:host:27443".
func EndpointName(ep *pb.Endpoint) string {
	return fmt.Sprintf("%s:%s:%d", strings.ToLower(ep.Kind.String()), ep.Host, ep.Port)
}

const (
	recentSuccess  = 7 * 24 * time.Hour
	recentFailure  = 10 * time.Minute
	throttleWindow = 24 * time.Hour
	throttleLimit  = 3
)

type epState struct {
	lastOK, lastFail time.Time
	throttles        []time.Time
	demotedUntil     time.Time
}

// Ranker orders a peer's endpoints from what worked recently (D73). In memory: a restart starts fresh.
type Ranker struct {
	now func() time.Time
	mu  sync.Mutex
	st  map[string]*epState
}

func NewRanker(now func() time.Time) *Ranker { return &Ranker{now: now, st: map[string]*epState{}} }

func (r *Ranker) state(ep *pb.Endpoint) *epState {
	k := EndpointName(ep)
	s := r.st[k]
	if s == nil {
		s = &epState{}
		r.st[k] = s
	}
	return s
}

// Done records an outcome for ep.
func (r *Ranker) Done(ep *pb.Endpoint, c netlog.Class) {
	r.mu.Lock()
	defer r.mu.Unlock()
	s, now := r.state(ep), r.now()
	switch c {
	case netlog.OK:
		s.lastOK = now
	case netlog.ResetAfterKB:
		s.lastFail = now
		keep := s.throttles[:0]
		for _, t := range s.throttles {
			if now.Sub(t) < throttleWindow {
				keep = append(keep, t)
			}
		}
		s.throttles = append(keep, now)
		if len(s.throttles) >= throttleLimit {
			s.demotedUntil = now.Add(throttleWindow)
		}
	default:
		s.lastFail = now
	}
}

// Order returns eps best first: recent success → priority/manifest order → recent failure → demoted.
func (r *Ranker) Order(eps []*pb.Endpoint) []*pb.Endpoint {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := r.now()
	type row struct {
		ep    *pb.Endpoint
		i     int
		group int
		ok    time.Time
	}
	rows := make([]row, len(eps))
	for i, ep := range eps {
		s := r.state(ep)
		g := 1
		switch {
		case now.Before(s.demotedUntil):
			g = 3
		case !s.lastFail.IsZero() && now.Sub(s.lastFail) < recentFailure && s.lastFail.After(s.lastOK):
			g = 2
		case !s.lastOK.IsZero() && now.Sub(s.lastOK) < recentSuccess:
			g = 0
		}
		rows[i] = row{ep, i, g, s.lastOK}
	}
	sort.SliceStable(rows, func(a, b int) bool {
		x, y := rows[a], rows[b]
		if x.group != y.group {
			return x.group < y.group
		}
		if x.group == 0 && !x.ok.Equal(y.ok) {
			return x.ok.After(y.ok)
		}
		if x.ep.Priority != y.ep.Priority {
			return x.ep.Priority < y.ep.Priority
		}
		return x.i < y.i
	})
	out := make([]*pb.Endpoint, len(rows))
	for i, x := range rows {
		out[i] = x.ep
	}
	return out
}

// MultiDialer implements Dialer over an EndpointDialer: ranked order, every attempt logged.
type MultiDialer struct {
	EP   EndpointDialer
	Rank *Ranker
	Log  netlog.Logger
}

func (d *MultiDialer) Dial(ctx context.Context, n *pb.NodeInfo) (*websocket.Conn, error) {
	var lastErr error = errors.New("no usable endpoint")
	for _, ep := range d.Rank.Order(n.Endpoints) {
		c, err := d.EP.DialEndpoint(ctx, n, ep)
		if errors.Is(err, ErrUnsupported) {
			continue
		}
		cl := netlog.Classify(err, 0)
		d.Rank.Done(ep, cl)
		d.Log.Add(ctx, netlog.Entry{Peer: n.Label, Endpoint: EndpointName(ep), Direction: "out", Result: netlog.Result(cl), Class: cl, Detail: errText(err)})
		if err == nil {
			return c, nil
		}
		lastErr = err
	}
	return nil, lastErr
}

// ErrUnsupported: this dialer cannot use the endpoint kind (skipped silently, not logged).
var ErrUnsupported = errors.New("endpoint kind not supported here")

func errText(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
```

Note on the test: `TestRankerOrder` expects after three `ResetAfterKB` on `d` the order `abcd` — `c` failed with a
timeout (group 2), `d` demoted (group 3), `a`,`b` untried (group 1). Adjust nothing else.

- [ ] **Step 3: `dialer.go`** — replace the whole file:

```go
package replication

import (
	"context"
	"net"
	"net/http"
	"strconv"
	"time"

	"github.com/coder/websocket"
	"ottermsg/server/internal/pinning"
	pb "ottermsg/server/internal/proto/otterv1"
)

type Dialer interface {
	Dial(ctx context.Context, n *pb.NodeInfo) (*websocket.Conn, error)
}

// RealityDialer opens a TCP stream to a REALITY endpoint (internal/reality.Client); nil = REALITY unsupported.
type RealityDialer interface {
	DialContext(ctx context.Context, ep *pb.Endpoint) (net.Conn, error)
}

// NetDialer dials one endpoint: WSS (pinned), WS_PLAIN (development), REALITY (through Reality).
type NetDialer struct {
	AllowPlain bool
	Reality    RealityDialer
}

const dialTimeout = 15 * time.Second

func (d NetDialer) DialEndpoint(ctx context.Context, n *pb.NodeInfo, ep *pb.Endpoint) (*websocket.Conn, error) {
	hostport := net.JoinHostPort(ep.Host, strconv.Itoa(int(ep.Port)))
	var url string
	var hc *http.Client
	switch {
	case ep.Kind == pb.Endpoint_WSS:
		url = "wss://" + hostport + ep.Path + "/peer"
		hc = &http.Client{Transport: &http.Transport{TLSClientConfig: pinning.ClientConfig(ep.Host, ep.TlsSpkiPins)}}
	case ep.Kind == pb.Endpoint_WS_PLAIN && d.AllowPlain:
		url = "ws://" + hostport + ep.Path + "/peer"
	case ep.Kind == pb.Endpoint_REALITY && d.Reality != nil:
		// plain HTTP inside the REALITY tunnel; the far side redirects every stream to its internal listener
		url = "ws://" + hostport + ep.Path + "/peer"
		hc = &http.Client{Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return d.Reality.DialContext(ctx, ep)
		}}}
	default:
		return nil, ErrUnsupported
	}
	dctx, cancel := context.WithTimeout(ctx, dialTimeout)
	defer cancel()
	c, _, err := websocket.Dial(dctx, url, &websocket.DialOptions{HTTPClient: hc})
	if err != nil {
		return nil, err
	}
	c.SetReadLimit(maxFrame)
	return c, nil
}
```

- [ ] **Step 4: Replicator changes** (`replicator.go`):

1. Struct: add fields `rank *Ranker`, `nlog netlog.Logger`.
2. `New` signature becomes `func New(svc *service.Service, dialer Dialer, log *slog.Logger, opts ...Option) *Replicator`
   with

```go
type Option func(*Replicator)

// WithNetlog sets the connectivity log and the ranker shared with a MultiDialer (D74).
func WithNetlog(l netlog.Logger, rank *Ranker) Option {
	return func(r *Replicator) { r.nlog, r.rank = l, rank }
}
```

   default `r.nlog = netlog.Nop{}`, `r.rank = NewRanker(time.Now)`; apply opts after building `r`.
3. `ServeHTTP` gets the listener name from the request context:

```go
type listenerKey struct{}

// WithListener tags requests served by one listener ("wss", "reality") for the inbound log.
func WithListener(h http.Handler, name string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), listenerKey{}, name)))
	})
}
```

   In `ServeHTTP`, after a successful `acceptHandshake`: look up the peer label
   (`r.labelOf(peer)`, a helper scanning `r.svc.CurrentManifest().Nodes`, falling back to `%x` of the id) and
   `r.nlog.Add(req.Context(), netlog.Entry{Peer: label, Endpoint: listenerName(req), Direction: "in", Result: "ok", Class: netlog.OK})`;
   on handshake failure log `Direction: "in", Peer: req.RemoteAddr, Class: netlog.Handshake`. `listenerName`
   returns the context value or `"wss"`.
4. `dialMissing`: skip peers the local node must not dial —

```go
		if n.DialOutOnly && !r.selfDialOutOnly(m) {
			continue // D71: a node inside a censored network dials us, never the other way round
		}
```

   with

```go
func (r *Replicator) selfDialOutOnly(m *pb.Manifest) bool {
	for _, n := range m.Nodes {
		if bytes.Equal(n.NodeId, r.svc.NodeID) {
			return n.DialOutOnly
		}
	}
	return false
}
```

   (two `dial_out_only` nodes may still dial each other). In the dial goroutine, wrap a handshake failure as
   `fmt.Errorf("%w: %v", netlog.ErrHandshake, err)` and log it with the endpoint `"handshake"` (the endpoint that
   connected is unknown at this level — acceptable; the transport attempt itself was already logged as ok).
5. `runSession(c, peer, dialer)` gets an extra `ep *pb.Endpoint` parameter (nil for inbound). Outbound callers must
   know which endpoint won: change `MultiDialer.Dial` to remember it — add to `MultiDialer`
   `func (d *MultiDialer) DialWith(ctx, n) (*websocket.Conn, *pb.Endpoint, error)` used by the replicator when its
   dialer is a `*MultiDialer` (type assertion), `Dial` calls `DialWith` and drops the endpoint. After `s.run()` ends:

```go
	if ep != nil && err != nil && r.baseCtx().Err() == nil {
		bytes := s.bytesIn.Load()
		if time.Since(s.start) < 2*time.Minute && bytes >= netlog.ThrottleBytes {
			r.rank.Done(ep, netlog.ResetAfterKB)
			r.nlog.Add(r.baseCtx(), netlog.Entry{Peer: r.labelOf(peer), Endpoint: EndpointName(ep), Direction: "out",
				Result: "fail", Class: netlog.ResetAfterKB, Detail: fmt.Sprintf("%d bytes in %s: %v", bytes, time.Since(s.start).Round(time.Second), err)})
		}
	}
```

6. `session.go`: add `bytesIn atomic.Int64` to `session`; in `run()`'s read loop the frame is read by
   `readFrame`; change `readFrame` to return the payload length too (`func readFrame(ctx, c) (*pb.PeerFrame, int, error)`),
   update its 3–4 callers, and in `run()` do `s.bytesIn.Add(int64(n))`.

- [ ] **Step 5: meshsim** — `partition_test.go`: `gatedDialer` implements `EndpointDialer` instead:

```go
func (d gatedDialer) DialEndpoint(ctx context.Context, n *pb.NodeInfo, ep *pb.Endpoint) (*websocket.Conn, error) {
	d.p.mu.Lock()
	blocked := d.p.blocked[key(d.self, n.NodeId)] || d.p.censored[censorKey(d.self, n.NodeId, ep.Kind)]
	d.p.mu.Unlock()
	if blocked {
		return nil, errors.New("partitioned")
	}
	c, err := d.p.net(d.self).DialEndpoint(ctx, n, ep)
	if err != nil {
		return nil, err
	}
	d.p.mu.Lock()
	blocked = d.p.blocked[key(d.self, n.NodeId)] || d.p.censored[censorKey(d.self, n.NodeId, ep.Kind)]
	d.p.mu.Unlock()
	if blocked {
		c.CloseNow()
		return nil, errors.New("partitioned")
	}
	return c, nil
}
```

with `censored map[string]bool` (init in `newPartition`), `censorKey(from, to []byte, k pb.Endpoint_Kind) string { return string(from) + "→" + string(to) + k.String() }`,
`func (p *partition) Censor(from, to *simNode, k pb.Endpoint_Kind)` (sets the key and calls
`p.repls[string(from.id)].DropPeer(to.id)`), and `func (p *partition) Uncensor(from, to *simNode, k pb.Endpoint_Kind)`.
`p.net(self)` returns `replication.NetDialer{AllowPlain: true, Reality: p.reality[string(self)]}` (map filled by
Task 6; nil = no REALITY). `partition.dialer(self)` now returns
`&replication.MultiDialer{EP: gatedDialer{p, self}, Rank: rank, Log: logger}` where the harness passes a per-node
`rank` and `logger` (`netlog.StoreLogger{S: st}`) — change the signature to `dialer(self []byte, rank *replication.Ranker, l netlog.Logger)`.
In `harness_test.go` `start`: `rank := replication.NewRanker(time.Now)`, `l := netlog.StoreLogger{S: st}`,
`repl := replication.New(svc, s.part.dialer(n.id, rank, l), quiet, replication.WithNetlog(l, rank))`.

- [ ] **Step 6: dial_out_only scenario test** — append to `internal/meshsim/scenarios_test.go`:

```go
func TestDialOutOnlyIsNeverDialed(t *testing.T) {
	s := newSim(t, "ru", "fi")
	ru, fi := s.node("ru"), s.node("fi")
	infos := s.nodeInfos()
	infos[0].DialOutOnly = true // ru
	s.publishManifest(2, infos)
	eventually(t, "session up", func() bool { return fi.repl.Status()[0].Connected })
	s.stop(ru)
	time.Sleep(500 * time.Millisecond) // ~10 dial rounds in test timings
	es, _ := fi.st.Netlog(context.Background(), 100)
	for _, e := range es {
		if e.Direction == "out" && e.Peer == "ru" && e.LastMs > time.Now().Add(-400*time.Millisecond).UnixMilli() {
			t.Fatalf("fi dialed the dial_out_only node: %+v", e)
		}
	}
	s.start(ru)
	eventually(t, "ru dials fi again", func() bool { return fi.repl.Status()[0].Connected })
}
```

Add harness helpers if missing: `nodeInfos()` returns a copy of the current manifest's `[]*pb.NodeInfo` (keep the
`infos` slice built in `newSim` on `sim`), and `publishManifest(v, infos)` signs and imports it on every running node
(`n.svc.ImportRecord`). Wait for the manifest on both before asserting.

- [ ] **Step 7: Run** `go test ./internal/replication/ ./internal/meshsim/ -count=1` → `ok`; `make check` → passes.

- [ ] **Step 8: Commit** — `git commit -am "feat(replication): ranked per-endpoint dialing, demotion, netlog, dial_out_only (D71, D73, D74)"`
  (also `git add internal/replication/endpoints*.go`).

---

### Task 4: REALITY package (Xray-core embedded)

**Goal:** `internal/reality` starts a REALITY server that forwards authenticated streams to a local address, dials
REALITY endpoints in-process, generates keys and checks camouflage candidates.

**Files:**
- Create: `otter-server/internal/reality/keys.go`, `server.go`, `client.go`, `check.go`, `reality_test.go`
- Modify: `otter-server/go.mod`, `go.sum`

**Acceptance Criteria:**
- [ ] `GenerateKey()` returns a 32-byte private key and its X25519 public key, both base64 RawURL.
- [ ] A loopback test: server (dest = local TLS 1.3 test server) + client → an HTTP request through the tunnel reaches
  the internal handler.
- [ ] A plain TLS client connecting to the REALITY port (no VLESS key) gets the camouflage server's certificate.
- [ ] The server's only outbound is a `freedom` redirect: an authenticated client cannot reach any other address.
- [ ] `Check(ctx, host)` reports TLS 1.3, ALPN h2, certificate validity and latency; fails clearly otherwise.

**Verify:** `go test ./internal/reality/ -count=1 -v` → `ok`

**Steps:**

- [ ] **Step 1: Dependency** — `go get github.com/xtls/xray-core@v1.260327.0 && go mod tidy`. Record the binary size
  before/after (`go build -o /tmp/on ./cmd/otter-node && ls -l /tmp/on`) for the docs (expect +20–30 MB).

- [ ] **Step 2: `keys.go`**

```go
// Package reality embeds Xray-core's VLESS+REALITY for node-to-node links (D72).
package reality

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"os"
	"strings"
)

var b64 = base64.RawURLEncoding

// GenerateKey returns a new X25519 key pair as base64 RawURL strings (the encoding Xray uses).
func GenerateKey() (priv, pub string, err error) {
	k, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return "", "", err
	}
	return b64.EncodeToString(k.Bytes()), b64.EncodeToString(k.PublicKey().Bytes()), nil
}

// PublicFromPrivate derives the public key (for `reality keygen` re-prints and checks).
func PublicFromPrivate(priv string) (string, error) {
	raw, err := b64.DecodeString(strings.TrimSpace(priv))
	if err != nil || len(raw) != 32 {
		return "", errors.New("reality: private key must be 32 bytes, base64 RawURL")
	}
	k, err := ecdh.X25519().NewPrivateKey(raw)
	if err != nil {
		return "", err
	}
	return b64.EncodeToString(k.PublicKey().Bytes()), nil
}

// ReadKeyFile reads a private key written by WriteKeyFile.
func ReadKeyFile(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	priv := strings.TrimSpace(string(b))
	_, err = PublicFromPrivate(priv)
	return priv, err
}

// WriteKeyFile creates path (0640, must not exist) with the private key.
func WriteKeyFile(path, priv string) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o640)
	if err != nil {
		return err
	}
	if _, err := f.WriteString(priv + "\n"); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}
```

- [ ] **Step 3: `server.go`**

```go
package reality

import (
	"encoding/json"
	"fmt"
	"net"
	"strconv"

	"github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/main/distro/all" // registers protocols + the JSON loader
)

type ServerConfig struct {
	Listen      string   // ":443"
	PrivateKey  string   // base64 RawURL
	Dest        string   // camouflage "host:443": unauthenticated connections are forwarded there
	ServerNames []string // SNI values accepted, e.g. ["www.microsoft.com"]
	ShortIDs    []string
	VlessUUID   string
	Forward     string // internal plain-HTTP listener, "127.0.0.1:PORT"
}

// Server is a running REALITY inbound.
type Server struct{ inst *core.Instance }

func serverJSON(c ServerConfig) ([]byte, error) {
	host, port, err := net.SplitHostPort(c.Listen)
	if err != nil {
		return nil, fmt.Errorf("reality listen %q: %w", c.Listen, err)
	}
	p, err := strconv.Atoi(port)
	if err != nil {
		return nil, err
	}
	if host == "" {
		host = "0.0.0.0"
	}
	cfg := map[string]any{
		"log": map[string]any{"loglevel": "warning"},
		"inbounds": []any{map[string]any{
			"listen": host, "port": p, "protocol": "vless",
			"settings": map[string]any{"clients": []any{map[string]any{"id": c.VlessUUID}}, "decryption": "none"},
			"streamSettings": map[string]any{"network": "tcp", "security": "reality", "realitySettings": map[string]any{
				"target": c.Dest, "serverNames": c.ServerNames, "privateKey": c.PrivateKey, "shortIds": c.ShortIDs}},
		}},
		// the only outbound: every authenticated stream goes to our own listener, never anywhere else
		"outbounds": []any{map[string]any{"protocol": "freedom", "settings": map[string]any{"redirect": c.Forward}}},
	}
	return json.Marshal(cfg)
}

func StartServer(c ServerConfig) (*Server, error) {
	js, err := serverJSON(c)
	if err != nil {
		return nil, err
	}
	inst, err := core.StartInstance("json", js)
	if err != nil {
		return nil, fmt.Errorf("reality server: %w", err)
	}
	return &Server{inst}, nil
}

func (s *Server) Close() error { return s.inst.Close() }
```

- [ ] **Step 4: `client.go`**

```go
package reality

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"sync"

	"github.com/xtls/xray-core/core"
	xnet "github.com/xtls/xray-core/common/net"
	pb "ottermsg/server/internal/proto/otterv1"
)

// Client dials REALITY endpoints; one Xray instance per distinct endpoint config, kept for the process lifetime.
type Client struct {
	mu   sync.Mutex
	inst map[string]*core.Instance
}

func NewClient() *Client { return &Client{inst: map[string]*core.Instance{}} }

func clientJSON(ep *pb.Endpoint) ([]byte, error) {
	if len(ep.RealityPub) != 32 || ep.VlessUuid == "" || len(ep.ServerNames) == 0 {
		return nil, fmt.Errorf("reality endpoint %s:%d is incomplete", ep.Host, ep.Port)
	}
	sid := ""
	if len(ep.ShortIds) > 0 {
		sid = ep.ShortIds[0]
	}
	fp := ep.Fingerprint
	if fp == "" {
		fp = "chrome"
	}
	cfg := map[string]any{
		"log": map[string]any{"loglevel": "warning"},
		"outbounds": []any{map[string]any{
			"protocol": "vless",
			"settings": map[string]any{"address": ep.Host, "port": ep.Port, "id": ep.VlessUuid, "encryption": "none"},
			"streamSettings": map[string]any{"network": "tcp", "security": "reality", "realitySettings": map[string]any{
				"serverName": ep.ServerNames[0], "fingerprint": fp, "publicKey": b64.EncodeToString(ep.RealityPub), "shortId": sid}},
		}},
	}
	return json.Marshal(cfg)
}

func (c *Client) instance(ep *pb.Endpoint) (*core.Instance, error) {
	js, err := clientJSON(ep)
	if err != nil {
		return nil, err
	}
	k := string(js)
	c.mu.Lock()
	defer c.mu.Unlock()
	if in := c.inst[k]; in != nil {
		return in, nil
	}
	in, err := core.StartInstance("json", js)
	if err != nil {
		return nil, fmt.Errorf("reality client: %w", err)
	}
	c.inst[k] = in
	return in, nil
}

// DialContext opens a stream through the endpoint. The far side redirects it to its internal listener, so the
// destination given here is only a placeholder. Errors of the tunnel itself surface on the first read/write.
func (c *Client) DialContext(ctx context.Context, ep *pb.Endpoint) (net.Conn, error) {
	in, err := c.instance(ep)
	if err != nil {
		return nil, err
	}
	return core.Dial(ctx, in, xnet.TCPDestination(xnet.ParseAddress("127.0.0.1"), xnet.Port(80)))
}

// Close stops all instances.
func (c *Client) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	for k, in := range c.inst {
		_ = in.Close()
		delete(c.inst, k)
	}
}
```

- [ ] **Step 5: `check.go`**

```go
package reality

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"time"
)

type CheckResult struct {
	TLS13, H2, CertOK bool
	Latency           time.Duration
}

func (r CheckResult) OK() bool { return r.TLS13 && r.H2 && r.CertOK }

// Check tests a camouflage candidate from this machine: TLS 1.3, ALPN h2, a certificate valid for host (D72).
func Check(ctx context.Context, host string) (CheckResult, error) {
	var r CheckResult
	t0 := time.Now()
	d := tls.Dialer{NetDialer: &net.Dialer{Timeout: 10 * time.Second},
		Config: &tls.Config{ServerName: host, NextProtos: []string{"h2", "http/1.1"}, MinVersion: tls.VersionTLS12}}
	c, err := d.DialContext(ctx, "tcp", net.JoinHostPort(host, "443"))
	if err != nil {
		return r, fmt.Errorf("%s: %w", host, err) // includes certificate errors: CertOK stays false
	}
	defer c.Close()
	st := c.(*tls.Conn).ConnectionState()
	r.Latency = time.Since(t0)
	r.TLS13 = st.Version == tls.VersionTLS13
	r.H2 = st.NegotiatedProtocol == "h2"
	r.CertOK = true
	return r, nil
}
```

- [ ] **Step 6: Loopback test** — `reality_test.go`:

```go
package reality

import (
	"context"
	"crypto/tls"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	pb "ottermsg/server/internal/proto/otterv1"
)

func freePort(t *testing.T) int {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port
}

func TestKeys(t *testing.T) {
	priv, pub, err := GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	if p2, err := PublicFromPrivate(priv); err != nil || p2 != pub {
		t.Fatalf("derive: %v %s %s", err, p2, pub)
	}
}

// startPair runs a camouflage TLS 1.3 site, an internal handler and a REALITY server in front of them.
func startPair(t *testing.T) (ep *pb.Endpoint, realityAddr string, camo *httptest.Server) {
	camo = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "camouflage") }))
	camo.TLS = &tls.Config{MinVersion: tls.VersionTLS13}
	camo.StartTLS()
	t.Cleanup(camo.Close)
	internal := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "otter:"+r.URL.Path) }))
	t.Cleanup(internal.Close)
	priv, pub, _ := GenerateKey()
	port := freePort(t)
	uuid := "d6a3f0b2-1c2d-4e5f-8a9b-0c1d2e3f4a5b"
	srv, err := StartServer(ServerConfig{Listen: "127.0.0.1:" + strconv.Itoa(port), PrivateKey: priv,
		Dest: camo.Listener.Addr().String(), ServerNames: []string{"camo.test"}, ShortIDs: []string{"a1b2c3d4"},
		VlessUUID: uuid, Forward: internal.Listener.Addr().String()})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { srv.Close() })
	raw, _ := b64.DecodeString(pub)
	ep = &pb.Endpoint{Kind: pb.Endpoint_REALITY, Host: "127.0.0.1", Port: uint32(port), VlessUuid: uuid, RealityPub: raw,
		ShortIds: []string{"a1b2c3d4"}, ServerNames: []string{"camo.test"}, Fingerprint: "chrome", Path: "/x"}
	return ep, "127.0.0.1:" + strconv.Itoa(port), camo
}

func TestTunnelReachesInternalHandler(t *testing.T) {
	ep, _, _ := startPair(t)
	cl := NewClient()
	t.Cleanup(cl.Close)
	hc := &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return cl.DialContext(ctx, ep)
	}}}
	resp, err := hc.Get("http://anything.invalid/x/peer")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if string(b) != "otter:/x/peer" {
		t.Fatalf("body %q", b)
	}
}

func TestProbeWithoutKeySeesCamouflage(t *testing.T) {
	_, addr, camo := startPair(t)
	c, err := tls.Dial("tcp", addr, &tls.Config{ServerName: "camo.test", InsecureSkipVerify: true})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	got := c.ConnectionState().PeerCertificates[0].Raw
	want := camo.Certificate().Raw
	if string(got) != string(want) {
		t.Fatal("a probe without the key must get the camouflage site's certificate")
	}
}

func TestWrongKeyFails(t *testing.T) {
	ep, _, _ := startPair(t)
	_, other, _ := GenerateKey()
	ep.RealityPub, _ = b64.DecodeString(other)
	cl := NewClient()
	t.Cleanup(cl.Close)
	hc := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return cl.DialContext(ctx, ep)
	}}}
	if resp, err := hc.Get("http://x/x/peer"); err == nil {
		resp.Body.Close()
		t.Fatal("tunnel with a wrong public key must fail")
	}
}

func TestCheckLocal(t *testing.T) {
	if _, err := Check(context.Background(), "nonexistent.invalid"); err == nil {
		t.Fatal("Check must fail for an unresolvable host")
	}
}
```

If REALITY rejects `127.0.0.1` as `target` because the camouflage certificate's SAN does not match `camo.test`:
REALITY does not verify the target's certificate, so this works; if a future Xray version does, set
`ServerNames` to `"example.com"` (the httptest certificate's SAN) in both places.

- [ ] **Step 7: Run** `go test ./internal/reality/ -count=1 -v` → all PASS. `make check` → passes (`go vet`,
  existing lint).

- [ ] **Step 8: Commit** — `git add go.mod go.sum internal/reality && git commit -m "feat(reality): embedded Xray-core REALITY server, client, keygen, camouflage check (D72)"`

---

### Task 5: Node config, wiring and commands

**Goal:** `otter-node run` starts the REALITY listener when `[reality]` is configured and dials REALITY endpoints;
new commands `reality keygen`, `reality-check`, `netlog`.

**Files:**
- Modify: `otter-server/internal/config/config.go` (struct + validation), `internal/nodecheck/check.go`,
  `cmd/otter-node/main.go`
- Test: `internal/config/config_test.go`, `internal/nodecheck/check_test.go`, `cmd/otter-node/main_test.go`

**Acceptance Criteria:**
- [ ] `[reality]` optional; when present all of `listen`, `private_key_file`, `dest`, `server_names`, `short_ids`,
  `vless_uuid` are required; `dest` must be `host:port`.
- [ ] `otter-node check` reports the REALITY key file (readable, valid) when configured.
- [ ] `run`: an internal listener on `127.0.0.1:0` serves the same mux tagged `reality`; the WSS mux is tagged `wss`;
  the replicator uses `MultiDialer{NetDialer{Reality: reality.NewClient()}}` and the store netlog.
- [ ] `otter-node reality keygen --config F` writes `[reality].private_key_file` (refuses to overwrite) and prints
  `public key: <b64>`.
- [ ] `otter-node reality-check HOST...` prints one line per host and exits non-zero if none passes.
- [ ] `otter-node netlog --config F [--limit N] [--json]` prints newest first, e.g.
  `2026-11-20 10:02–14:55  eeee  reality:<eeee-ip>:443  out  ok  ×143`.

**Verify:** `go test ./internal/config/ ./internal/nodecheck/ ./cmd/otter-node/ -count=1` → `ok`

**Steps:**

- [ ] **Step 1: Config tests** — append to `internal/config/config_test.go` (use the file's existing helper that
  writes a minimal valid config to a temp file; below called `writeCfg(t, extra string) string`):

```go
func TestRealitySection(t *testing.T) {
	ok := `
[reality]
listen = ":443"
private_key_file = "/etc/otter/reality.key"
dest = "www.example.com:443"
server_names = ["www.example.com"]
short_ids = ["a1b2c3d4"]
vless_uuid = "d6a3f0b2-1c2d-4e5f-8a9b-0c1d2e3f4a5b"
`
	c, err := Load(writeCfg(t, ok))
	if err != nil || !c.RealityEnabled() {
		t.Fatalf("valid [reality]: %v", err)
	}
	if _, err := Load(writeCfg(t, strings.Replace(ok, `dest = "www.example.com:443"`, `dest = "www.example.com"`, 1))); err == nil {
		t.Fatal("dest without port accepted")
	}
	if _, err := Load(writeCfg(t, strings.Replace(ok, `vless_uuid = "d6a3f0b2-1c2d-4e5f-8a9b-0c1d2e3f4a5b"`, ``, 1))); err == nil {
		t.Fatal("missing vless_uuid accepted")
	}
	c, err = Load(writeCfg(t, ""))
	if err != nil || c.RealityEnabled() {
		t.Fatalf("no [reality]: %v", err)
	}
}
```

- [ ] **Step 2: Config code** — in `config.go`:

```go
// Reality (D72): VLESS+REALITY listener for peers; optional.
type Reality struct {
	Listen         string   `toml:"listen"`
	PrivateKeyFile string   `toml:"private_key_file"`
	Dest           string   `toml:"dest"`
	ServerNames    []string `toml:"server_names"`
	ShortIDs       []string `toml:"short_ids"`
	VlessUUID      string   `toml:"vless_uuid"`
}
```

add `Reality Reality \`toml:"reality"\`` to `Config`, and

```go
// RealityEnabled reports whether a [reality] section is configured.
func (c *Config) RealityEnabled() bool { return c.Reality.Listen != "" || c.Reality.PrivateKeyFile != "" }
```

In `validate()` before `switch c.LogLevel`:

```go
	if c.RealityEnabled() {
		r := c.Reality
		if r.Listen == "" || r.PrivateKeyFile == "" || r.Dest == "" || r.VlessUUID == "" || len(r.ServerNames) == 0 || len(r.ShortIDs) == 0 {
			return fmt.Errorf("config: [reality] needs listen, private_key_file, dest, server_names, short_ids, vless_uuid")
		}
		if _, _, err := net.SplitHostPort(r.Dest); err != nil {
			return fmt.Errorf("config: reality.dest must be host:port: %w", err)
		}
	}
```

(import `net`). `RealityEnabled` true with a partial section makes validation fail — intended.

- [ ] **Step 3: nodecheck** — in `internal/nodecheck/check.go`, where other files are checked, add:

```go
	if cfg.RealityEnabled() {
		if _, err := reality.ReadKeyFile(cfg.Reality.PrivateKeyFile); err != nil {
			lines = append(lines, "FAIL reality key: "+err.Error())
			failed = true
		} else {
			lines = append(lines, "ok   reality key "+cfg.Reality.PrivateKeyFile)
		}
	}
```

Match the file's existing line format and failure accumulation (read it first; names above are illustrative of the
pattern used there). Add a test case in `check_test.go`: config with `[reality]` pointing to a missing key file →
`check` fails with a line containing `reality key`.

- [ ] **Step 4: `cmd/otter-node/main.go`**

Usage lines:

```
  reality keygen --config FILE write the REALITY private key file (once) and print the public key
  reality-check HOST...        test camouflage candidates from this machine (TLS 1.3, h2, valid certificate)
  netlog --config FILE [--limit 50] [--json]   connectivity log (safe while running)
```

Dispatch in `run()` before `rest := args[1:]` handling of `apk`:

```go
	if cmd == "reality-check" {
		return runRealityCheck(ctx, args[1:], out)
	}
	if cmd == "reality" {
		if len(args) < 2 || args[1] != "keygen" {
			return errors.New("usage: otter-node reality keygen --config FILE")
		}
		rest = args[2:]
	}
```

(`rest` must be declared before; move `rest := args[1:]` above.) Add flags `limit := fs.Int("limit", 50, "")`,
`asJSON := fs.Bool("json", false, "")`. Then:

```go
	if cmd == "reality" {
		cfg, err := config.Load(*cfgPath)
		if err != nil {
			return err
		}
		if !cfg.RealityEnabled() {
			return errors.New("reality keygen: add a [reality] section with private_key_file first (deploy/reality-setup.sh does this)")
		}
		priv, pub, err := reality.GenerateKey()
		if err != nil {
			return err
		}
		if err := reality.WriteKeyFile(cfg.Reality.PrivateKeyFile, priv); err != nil {
			if errors.Is(err, os.ErrExist) {
				priv, err := reality.ReadKeyFile(cfg.Reality.PrivateKeyFile)
				if err != nil {
					return err
				}
				pub, _ = reality.PublicFromPrivate(priv)
				fmt.Fprintf(out, "key file exists; public key: %s\n", pub)
				return nil
			}
			return err
		}
		fmt.Fprintf(out, "public key: %s\n", pub)
		return nil
	}
```

`keygen` with an existing file re-prints the public key (idempotent for scripts). But keygen needs the
`[reality]` section to know the path, while `run` would fail without a key — `reality-setup.sh` (Task 7) writes the
section into a candidate config `node.toml.new` and calls `keygen --config node.toml.new`, so the live config is
never broken.

`netlog` is handled with `run/import/backup/stats` (it opens the store; add `"netlog"` to the allowed list):

```go
	case "netlog":
		es, err := a.st.Netlog(ctx, *limit)
		if err != nil {
			return err
		}
		if *asJSON {
			return json.NewEncoder(out).Encode(es)
		}
		for _, e := range es {
			first, last := time.UnixMilli(e.FirstMs).Local(), time.UnixMilli(e.LastMs).Local()
			span := last.Format("2006-01-02 15:04")
			if e.Count > 1 {
				span = first.Format("2006-01-02 15:04") + "–" + last.Format("15:04")
			}
			line := fmt.Sprintf("%s  %s  %s  %s  %s", span, e.Peer, e.Endpoint, e.Direction, e.Result)
			if e.Class != "ok" {
				line += " " + e.Class
			}
			line += fmt.Sprintf("  ×%d", e.Count)
			if e.Detail != "" && e.Class != "ok" {
				line += "  (" + e.Detail + ")"
			}
			fmt.Fprintln(out, line)
		}
		return nil
```

`runRealityCheck`:

```go
func runRealityCheck(ctx context.Context, hosts []string, out io.Writer) error {
	if len(hosts) == 0 {
		return errors.New("usage: otter-node reality-check HOST...")
	}
	good := 0
	for _, h := range hosts {
		r, err := reality.Check(ctx, h)
		switch {
		case err != nil:
			fmt.Fprintf(out, "FAIL %s: %v\n", h, err)
		case !r.OK():
			fmt.Fprintf(out, "FAIL %s: tls1.3=%v h2=%v cert=%v\n", h, r.TLS13, r.H2, r.CertOK)
		default:
			good++
			fmt.Fprintf(out, "ok   %s: tls1.3 h2 cert %dms\n", h, r.Latency.Milliseconds())
		}
	}
	if good == 0 {
		return errors.New("no candidate passed")
	}
	return nil
}
```

In `serve()` replace the replication/server block:

```go
	nl := netlog.StoreLogger{S: a.st}
	rank := replication.NewRanker(time.Now)
	rc := reality.NewClient()
	defer rc.Close()
	dialer := &replication.MultiDialer{EP: replication.NetDialer{AllowPlain: a.cfg.Mesh.AllowPlain, Reality: rc}, Rank: rank, Log: nl}
	repl := replication.New(a.svc, dialer, a.log, replication.WithNetlog(nl, rank))
	go repl.Run(ctx)
	a.svc.Fetcher = repl
	go repl.RunPuller(ctx, a.cfg.BlobBytesPerSec)
	go a.svc.RunJanitor(ctx, 10*time.Minute)
	wcfg := wss.Config{Listen: a.cfg.WSS.Listen, Path: a.cfg.WSS.Path, TLSCert: a.cfg.WSS.TLSCert, TLSKey: a.cfg.WSS.TLSKey, SiteDir: a.cfg.WSS.SiteDir}
	srv := wss.NewServer(wcfg, gw, replication.WithListener(repl, "wss"))
	errc := make(chan error, 2)
	go func() { errc <- wss.Serve(srv, wcfg) }()
	if a.cfg.RealityEnabled() {
		stopReality, err := startReality(a, gw, repl, errc)
		if err != nil {
			return err
		}
		defer stopReality()
	}
```

with

```go
// startReality serves the client/peer mux on an internal listener and puts the REALITY inbound in front (D72).
func startReality(a *app, gw http.Handler, repl *replication.Replicator, errc chan<- error) (func(), error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	icfg := wss.Config{Path: a.cfg.WSS.Path, SiteDir: a.cfg.WSS.SiteDir}
	isrv := wss.NewServer(icfg, gw, replication.WithListener(repl, "reality"))
	go func() { errc <- isrv.Serve(ln) }()
	priv, err := reality.ReadKeyFile(a.cfg.Reality.PrivateKeyFile)
	if err != nil {
		ln.Close()
		return nil, fmt.Errorf("reality key: %w", err)
	}
	r := a.cfg.Reality
	rs, err := reality.StartServer(reality.ServerConfig{Listen: r.Listen, PrivateKey: priv, Dest: r.Dest,
		ServerNames: r.ServerNames, ShortIDs: r.ShortIDs, VlessUUID: r.VlessUUID, Forward: ln.Addr().String()})
	if err != nil {
		ln.Close()
		return nil, err
	}
	a.log.Info("reality on", "listen", r.Listen, "dest", r.Dest)
	return func() { rs.Close(); isrv.Close() }, nil
}
```

Imports: `net`, `encoding/json`, `ottermsg/server/internal/netlog`, `ottermsg/server/internal/reality`.

- [ ] **Step 5: main tests** — append to `cmd/otter-node/main_test.go` (reuse its helper that writes a config into a
  temp dir; below `testConfig(t, extra string) string`):

```go
func TestRealityKeygen(t *testing.T) {
	dir := t.TempDir()
	keyPath := filepath.Join(dir, "reality.key")
	cfg := testConfig(t, fmt.Sprintf(`
[reality]
listen = "127.0.0.1:0"
private_key_file = %q
dest = "127.0.0.1:1"
server_names = ["x.test"]
short_ids = ["a1b2"]
vless_uuid = "d6a3f0b2-1c2d-4e5f-8a9b-0c1d2e3f4a5b"
`, keyPath))
	var out bytes.Buffer
	if err := run(context.Background(), []string{"reality", "keygen", "--config", cfg}, &out); err != nil {
		t.Fatal(err)
	}
	first := out.String()
	if !strings.HasPrefix(first, "public key: ") {
		t.Fatalf("output %q", first)
	}
	out.Reset()
	if err := run(context.Background(), []string{"reality", "keygen", "--config", cfg}, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), strings.TrimPrefix(strings.TrimSpace(first), "public key: ")) {
		t.Fatalf("second keygen must re-print the same key: %q", out.String())
	}
}

func TestNetlogCommandEmpty(t *testing.T) {
	cfg := testConfig(t, "")
	var out bytes.Buffer
	if err := run(context.Background(), []string{"netlog", "--config", cfg}, &out); err != nil {
		t.Fatal(err)
	}
}
```

- [ ] **Step 6: Run** `go test ./internal/config/ ./internal/nodecheck/ ./cmd/otter-node/ -count=1` → `ok`;
  `make check` → passes.

- [ ] **Step 7: Commit** — `git commit -am "feat(node): [reality] listener, REALITY dialing, reality keygen/check, netlog command (D72, D74)"`

---

### Task 6: meshsim censor scenarios over REALITY

**Goal:** Prove end to end that replication runs over REALITY, falls back to WSS, and that probes see the
camouflage site.

**Files:**
- Create: `otter-server/internal/meshsim/reality_test.go`
- Modify: `otter-server/internal/meshsim/harness_test.go` (optional REALITY per node), `partition_test.go`
  (`reality` map)

**Acceptance Criteria:**
- [ ] `ru` (dial_out_only) ↔ `fi` (REALITY + WS_PLAIN): with WS_PLAIN censored ru→fi, a user on `ru` and a user on
  `fi` exchange a message; `ru`'s netlog has `out ok` for `reality:` and `fail` for `ws_plain:`.
- [ ] Censoring REALITY instead (WS_PLAIN open): the message still arrives; netlog shows the fallback.
- [ ] A TLS probe to fi's REALITY port gets the camouflage certificate.
- [ ] `fi` has no outbound log lines for `ru`.

**Verify:** `go test ./internal/meshsim/ -run Reality -count=1 -v` → `ok`

**Steps:**

- [ ] **Step 1: Harness** — add to `simNode` a field `reality *realityInfo` with
  `type realityInfo struct { ep *pb.Endpoint; srv *reality.Server; camo *httptest.Server }`. Add
  `func newSimWith(t *testing.T, opts map[string]nodeOpts, labels ...string) *sim` where
  `type nodeOpts struct { reality, dialOutOnly bool }` and make `newSim` call it with nil. For a REALITY node, before
  building its `NodeInfo`: start a camouflage `httptest` TLS 1.3 server (as in `internal/reality/reality_test.go`),
  generate a key, pick a free port, and append a `REALITY` endpoint (Host `127.0.0.1`, Port, `VlessUuid`,
  `RealityPub`, `ShortIds`, `ServerNames: ["camo.test"]`, `Path: path`) after the WS_PLAIN endpoint. In `start(n)`,
  when `n.reality != nil`: listen on `127.0.0.1:0` for the internal server
  (`wss.NewServer(wss.Config{Path: path}, gw, replication.WithListener(repl, "reality"))`) and
  `reality.StartServer(...)` with `Forward` = that listener; stop both in `stop(n)`. Every node's dialer gets
  `Reality: reality.NewClient()` (set `p.reality[string(n.id)]` in `start`).

- [ ] **Step 2: Tests** — `internal/meshsim/reality_test.go`:

```go
package meshsim

import (
	"context"
	"crypto/tls"
	"strings"
	"testing"

	pb "ottermsg/server/internal/proto/otterv1"
)

func netlogHas(n *simNode, dir, endpointPrefix, result string) bool {
	es, _ := n.st.Netlog(context.Background(), 200)
	for _, e := range es {
		if e.Direction == dir && strings.HasPrefix(e.Endpoint, endpointPrefix) && e.Result == result {
			return true
		}
	}
	return false
}

func TestRealityCarriesReplicationWhenWSSCensored(t *testing.T) {
	s := newSimWith(t, map[string]nodeOpts{"ru": {dialOutOnly: true}, "fi": {reality: true}}, "ru", "fi")
	ru, fi := s.node("ru"), s.node("fi")
	s.part.Censor(ru, fi, pb.Endpoint_WS_PLAIN)
	alice := s.register(ru, "alice") // existing harness helpers for accounts and messages (see scenarios_test.go)
	bob := s.register(fi, "bob")
	s.sendText(alice, bob, "привет")
	eventually(t, "bob gets the message via REALITY", func() bool { return fi.mailbox(bob) > 0 })
	if !netlogHas(ru, "out", "reality:", "ok") || !netlogHas(fi, "in", "reality", "ok") {
		t.Fatal("netlog must show the REALITY session on both sides")
	}
	es, _ := fi.st.Netlog(context.Background(), 200)
	for _, e := range es {
		if e.Direction == "out" && e.Peer == "ru" {
			t.Fatalf("fi dialed ru: %+v", e)
		}
	}
}

func TestWSSFallbackWhenRealityCensored(t *testing.T) {
	s := newSimWith(t, map[string]nodeOpts{"ru": {dialOutOnly: true}, "fi": {reality: true}}, "ru", "fi")
	ru, fi := s.node("ru"), s.node("fi")
	s.part.Censor(ru, fi, pb.Endpoint_REALITY)
	alice := s.register(ru, "alice")
	bob := s.register(fi, "bob")
	s.sendText(alice, bob, "fallback")
	eventually(t, "message via WSS fallback", func() bool { return fi.mailbox(bob) > 0 })
	if !netlogHas(ru, "out", "ws_plain:", "ok") {
		t.Fatal("netlog must show the WS fallback")
	}
}

func TestRealityProbeSeesCamouflage(t *testing.T) {
	s := newSimWith(t, map[string]nodeOpts{"fi": {reality: true}}, "fi")
	fi := s.node("fi")
	addr := fi.reality.ep.Host + ":" + itoa(fi.reality.ep.Port)
	c, err := tls.Dial("tcp", addr, &tls.Config{ServerName: "camo.test", InsecureSkipVerify: true})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if string(c.ConnectionState().PeerCertificates[0].Raw) != string(fi.reality.camo.Certificate().Raw) {
		t.Fatal("probe must see the camouflage certificate")
	}
}
```

Use the account/message helpers that already exist in `scenarios_test.go`/`client_test.go` (read them first; the
names `register`, `sendText`, `mailbox` above must be mapped to the real ones — e.g. the existing tests create users
through `invite` + a test client and check `n.mailbox(u)`). `itoa` = `strconv.Itoa(int(x))`.

- [ ] **Step 3: Run** `go test ./internal/meshsim/ -count=1` (all, not only REALITY) → `ok`; repeat 3× with
  `-count=3 -run Reality` to catch flakiness.

- [ ] **Step 4: Commit** — `git commit -am "test(meshsim): REALITY replication, WSS fallback, camouflage probe"` (add the new file).

---

### Task 7: Deploy scripts

**Goal:** The ops scripts set up REALITY safely, ask about `dial_out_only` on install, restore the config on
rollback and show the netlog.

**Files:**
- Modify: `otter-server/deploy/templates/otter-node.service`
- Create: `otter-server/deploy/reality-setup.sh`
- Modify: `otter-server/deploy/add-node.sh`, `deploy/upgrade.sh`, `deploy/status.sh`, `deploy/README.md`
- Test: `otter-server/deploy/test/scripts_test.sh`

**Acceptance Criteria:**
- [ ] New installs: unit has `AmbientCapabilities=CAP_NET_BIND_SERVICE` and
  `CapabilityBoundingSet=CAP_NET_BIND_SERVICE`.
- [ ] `reality-setup.sh LABEL --dest HOST [--port 443]`: on the node, writes `[reality]` into `node.toml.new`, runs
  `reality keygen --config node.toml.new`, installs a systemd drop-in with the capability (existing nodes), validates
  with `otter-node check --config node.toml.new`, swaps, restarts, health-checks, greps `"reality on"`; on any
  failure the live `node.toml` is unchanged. Then (on the PC) runs `otter-admin node add-reality` with the printed
  key and the node's IP and tells the owner to `manifest sign` + `publish`. Refuses if the node already has
  `[reality]` unless `--force`.
- [ ] `add-node.sh` asks the dial-out-only question (default No), or takes `--dial-out-only` / `--no-dial-out-only`;
  non-interactive (no TTY) → No; the flag is set before `manifest sign`; a re-run of an existing node does not ask.
- [ ] `upgrade.sh` copies `node.toml` → `node.toml.prev` before the swap and restores it on rollback.
- [ ] `status.sh` shows the last 5 netlog lines per node.
- [ ] `deploy/test/scripts_test.sh` covers the prompt flags and the rollback config restore with its existing stubs.

**Verify:** `bash deploy/test/scripts_test.sh` → `all tests passed` (or the file's existing success line)

**Steps:**

- [ ] **Step 1: Unit template** — in `deploy/templates/otter-node.service` replace `CapabilityBoundingSet=` with:

```
# :443 for REALITY (D72) without root
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
```

- [ ] **Step 2: `deploy/reality-setup.sh`**

```bash
#!/usr/bin/env bash
# Turns on the REALITY listener on one node (D72) and adds its endpoint to the admin state.
# Usage: reality-setup.sh LABEL --dest HOST [--port 443] [--force]
# The private key is generated on the node and never leaves it. The live node.toml is changed only after the new
# config passed `otter-node check`; on failure the node keeps running as before.
source "$(dirname "$0")/lib.sh"
usage="usage: reality-setup.sh LABEL --dest HOST [--port 443] [--force]"
label=${1:-}; [[ -n "$label" && "$label" != --* ]] || die "$usage"; shift
dest=""; port=443; force=0
while (( $# )); do
  case "$1" in
    --dest) dest=${2:?$usage}; shift 2 ;;
    --port) port=${2:?$usage}; shift 2 ;;
    --force) force=1; shift ;;
    *) die "$usage" ;;
  esac
done
[[ -n "$dest" ]] || die "$usage"
host_lookup "$label" || die "node $label has no SSH target: deploy/hosts.sh set $label root@HOST"
export SSH_PORT=$TARGET_PORT
ip=$(admin_node_ip "$label")
[[ -n "$ip" ]] || die "no IP recorded for $label (otter-admin node set-ip)"
say "checking the camouflage site $dest from $label"
remote "$TARGET" "/usr/local/bin/otter-node reality-check $dest" || die "$dest failed the check on $label; pick another (e.g. www.microsoft.com, dl.google.com)"
sid=$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')
vless=$(cat /proc/sys/kernel/random/uuid)
say "configuring REALITY on $label (:$port, camouflage $dest)"
pub=$(remote "$TARGET" bash -s -- "$dest" "$port" "$sid" "$vless" "$force" <<'REMOTE'
set -euo pipefail
dest=$1 port=$2 sid=$3 vless=$4 force=$5
if grep -q '^\[reality\]' /etc/otter/node.toml && [[ $force != 1 ]]; then
  echo "node.toml already has [reality]; re-run with --force to replace it" >&2; exit 1
fi
cp -p /etc/otter/node.toml /etc/otter/node.toml.new
# drop an old [reality] section (to the next section or EOF)
awk 'BEGIN{s=0} /^\[reality\]/{s=1;next} /^\[/{s=0} !s' /etc/otter/node.toml.new > /etc/otter/node.toml.tmp && mv /etc/otter/node.toml.tmp /etc/otter/node.toml.new
cat >> /etc/otter/node.toml.new <<EOF

[reality]
listen = ":$port"
private_key_file = "/etc/otter/reality.key"
dest = "$dest:443"
server_names = ["$dest"]
short_ids = ["$sid"]
vless_uuid = "$vless"
EOF
chown root:otter /etc/otter/node.toml.new
out=$(/usr/local/bin/otter-node reality keygen --config /etc/otter/node.toml.new)
chown root:otter /etc/otter/reality.key; chmod 0640 /etc/otter/reality.key
if ! runuser -u otter -- /usr/local/bin/otter-node check --config /etc/otter/node.toml.new >&2; then
  rm -f /etc/otter/node.toml.new
  echo "otter-node $(/usr/local/bin/otter-node version) rejects the REALITY config; upgrade to 0.7.0+ first" >&2; exit 1
fi
mkdir -p /etc/systemd/system/otter-node.service.d
printf '[Service]\nAmbientCapabilities=CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE\n' \
  > /etc/systemd/system/otter-node.service.d/reality.conf
systemctl daemon-reload
cp -p /etc/otter/node.toml /etc/otter/node.toml.pre-reality
mv /etc/otter/node.toml.new /etc/otter/node.toml
since=$(date '+%Y-%m-%d %H:%M:%S')
systemctl restart otter-node
if ! /usr/local/lib/otter/health.sh || ! journalctl -u otter-node --since "$since" --no-pager -o cat | grep -q '"reality on"'; then
  echo "REALITY did not start; restoring the previous config" >&2
  mv /etc/otter/node.toml.pre-reality /etc/otter/node.toml
  systemctl restart otter-node; /usr/local/lib/otter/health.sh || true
  exit 1
fi
echo "${out##*: }"
REMOTE
) || die "REALITY setup failed on $label (node left on its previous config)"
say "adding the REALITY endpoint to the admin state"
admin node add-reality --label "$label" --host "$ip" --port "$port" --pub "$pub" --server-name "$dest" --short-id "$sid" --uuid "$vless"
say "REALITY is on for $label. Next (your terminal): otter-admin manifest sign && otter-admin manifest publish"
```

The node's `vless_uuid` reaches the manifest through `--uuid` (Task 1). `admin_node_ip` is a new `lib.sh` helper: `admin_node_ip() { admin node env --label "$1" | sed -n "s/^OTTER_IP=//p" | tr -d "'" | head -1; }`
— check `admin node env` output for the real variable name first (it prints the node's env; pick the public IP
variable) and adjust.

- [ ] **Step 3: `add-node.sh`** — parse `--dial-out-only` / `--no-dial-out-only` into `dial_out=1|0|""`; in the
  "register a new node" branch, after `admin node add "${args[@]}"`:

```bash
  if [[ -z "$dial_out" ]]; then
    dial_out=0
    if [[ -t 0 ]]; then
      read -r -p "Is $label inside a censored network (e.g. Russia)? It will dial out to the other nodes and is never dialed by them. [y/N] " ans
      [[ "$ans" =~ ^[yYдД] ]] && dial_out=1
    fi
  fi
  if (( dial_out )); then
    say "marking $label dial_out_only"
    admin node set-dial-out-only --label "$label"
  fi
```

Update the usage line to include `[--dial-out-only|--no-dial-out-only]`. An existing node (re-run) skips this
branch entirely, so it never asks again.

- [ ] **Step 4: `upgrade.sh`** — in the remote block, after `cp -p /usr/local/bin/otter-node /usr/local/bin/otter-node.prev`
  add `cp -p /etc/otter/node.toml /etc/otter/node.toml.prev`; in the rollback path, after restoring the binary add
  `cp -p /etc/otter/node.toml.prev /etc/otter/node.toml`. (Normal upgrades never edit `node.toml`; this protects a
  rollback after `[reality]` was added.)

- [ ] **Step 5: `status.sh`** — after the per-node table, for each node print
  `remote "$target" 'runuser -u otter -- /usr/local/bin/otter-node netlog --config /etc/otter/node.toml --limit 5 2>/dev/null' | sed "s/^/  $label  /"`
  (silently skip nodes older than 0.7.0 — `netlog` fails there and prints nothing).

- [ ] **Step 6: Script tests** — in `deploy/test/scripts_test.sh`, following the existing stub style (`admin`,
  `remote`, `upload` replaced by functions that record calls):
  1. `add-node.sh x root@h --ip 192.0.2.1 --dial-out-only` with stdin not a TTY → recorded calls contain
     `node set-dial-out-only --label x` before `manifest sign`.
  2. same with `--no-dial-out-only` → no `set-dial-out-only`.
  3. no flag, no TTY → no `set-dial-out-only`.
  4. `upgrade.sh` remote script text contains `node.toml.prev` in both the backup and the rollback branch
     (grep the heredoc).
  Run `bash deploy/test/scripts_test.sh` → pass. Also `shellcheck deploy/*.sh` if the repo's `make check` runs it.

- [ ] **Step 7: README** — `deploy/README.md`: a "REALITY (M7)" section: when to use, `reality-setup.sh`, choosing a
  camouflage site with `otter-node reality-check`, the `--dial-out-only` question in `add-node.sh`, reading
  `otter-node netlog`, and rollback notes (remove `[reality]` before downgrading below 0.7.0).

- [ ] **Step 8: Commit** — `git add deploy && git commit -m "feat(deploy): reality-setup.sh, dial-out-only prompt, config rollback, netlog in status"`

---

### Task 8: Android — failure classes, bytes counter, demotion

**Goal:** The app classifies connection failures, counts bytes per connection, and demotes throttled endpoints.

**Files:**
- Create: `otter-android/core/network/src/main/kotlin/app/ottermsg/core/network/FailureClass.kt`,
  `.../NetLog.kt`
- Modify: `.../Transport.kt`, `.../OkHttpTransport.kt`, `.../EndpointStats.kt`, `.../NodeSelector.kt`,
  `.../ConnectionManager.kt`
- Run: `otter-android/scripts/sync-proto.sh` (manifest field 6)
- Test: `core/network/src/test/kotlin/app/ottermsg/core/network/FailureClassTest.kt`, `NodeSelectorTest.kt`,
  `ConnectionManagerTest.kt` (existing files: add cases)

**Acceptance Criteria:**
- [ ] `classify(t, bytesIn)` maps `SocketTimeoutException` → TIMEOUT, `ConnectException` → REFUSED,
  `SSLException`/`SSLHandshakeException`/`CertificateException` → TLS, other `IOException`/EOF → RESET or
  RESET_AFTER_KB (≥ 1024 bytes), `null` → OK; a hello timeout → TIMEOUT.
- [ ] `Connection.bytesIn` counts received bytes (OkHttp transport).
- [ ] `EndpointStats.throttled(key, now)` records a throttle; 3 within 24 h → demoted for 24 h; `NodeSelector.order`
  puts demoted candidates after recently failed ones.
- [ ] `NodeSelector` and `ConnectionManager` call `NetLog.add(...)` for every attempt and for a session that ends with
  an error after ≥ 1 KB within 2 min (`RESET_AFTER_KB`, plus `stats.throttled`).
- [ ] Existing network tests pass.

**Verify:** `cd otter-android && ./gradlew :core:network:testDebugUnitTest` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Proto sync** — `scripts/sync-proto.sh` (copies from `../otter-server/proto`); `git diff` shows only
  `dial_out_only = 6` in `manifest.proto`.

- [ ] **Step 2: Failing test** — `FailureClassTest.kt`:

```kotlin
package app.ottermsg.core.network

import java.io.EOFException
import java.io.IOException
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.security.cert.CertificateException
import javax.net.ssl.SSLHandshakeException
import kotlinx.coroutines.TimeoutCancellationException
import org.junit.Assert.assertEquals
import org.junit.Test

class FailureClassTest {
    @Test fun classifies() {
        assertEquals(FailureClass.OK, classify(null, 0))
        assertEquals(FailureClass.TIMEOUT, classify(SocketTimeoutException("t"), 0))
        assertEquals(FailureClass.REFUSED, classify(ConnectException("refused"), 0))
        assertEquals(FailureClass.TLS, classify(SSLHandshakeException("pin"), 0))
        assertEquals(FailureClass.TLS, classify(IOException("wrap", CertificateException("x")), 0))
        assertEquals(FailureClass.RESET, classify(EOFException(), 10))
        assertEquals(FailureClass.RESET_AFTER_KB, classify(IOException("reset"), 4096))
        assertEquals(FailureClass.HANDSHAKE, classify(HandshakeFailed("no hello"), 0))
    }
}
```

- [ ] **Step 3: `FailureClass.kt`**

```kotlin
package app.ottermsg.core.network

import java.net.ConnectException
import java.net.SocketTimeoutException
import java.security.cert.CertificateException
import javax.net.ssl.SSLException

/** Connection outcome classes shared with the nodes (D73). */
enum class FailureClass(val wire: String) {
    OK("ok"), TIMEOUT("timeout"), REFUSED("refused"), RESET("reset"), RESET_AFTER_KB("reset_after_kb"),
    TLS("tls"), HANDSHAKE("handshake"),
}

/** The transport connected but the node's hello never came / was invalid. */
class HandshakeFailed(message: String) : Exception(message)

const val THROTTLE_BYTES = 1024L

fun classify(t: Throwable?, bytesIn: Long): FailureClass {
    if (t == null) return FailureClass.OK
    var e: Throwable? = t
    while (e != null) {
        when (e) {
            is HandshakeFailed -> return FailureClass.HANDSHAKE
            is SocketTimeoutException -> return FailureClass.TIMEOUT
            is ConnectException -> return FailureClass.REFUSED
            is SSLException, is CertificateException -> return FailureClass.TLS
        }
        e = e.cause
    }
    return if (bytesIn >= THROTTLE_BYTES) FailureClass.RESET_AFTER_KB else FailureClass.RESET
}
```

- [ ] **Step 4: `NetLog.kt`**

```kotlin
package app.ottermsg.core.network

/** One connectivity observation (D74); the store merges repeats. */
data class NetLogEntry(val nodeLabel: String, val endpoint: String, val result: FailureClass, val detail: String = "", val rttMs: Long = 0)

interface NetLog {
    suspend fun add(e: NetLogEntry)
    object None : NetLog { override suspend fun add(e: NetLogEntry) {} }
}

/** "wss://host:27443" without the secret path, for the log. */
fun Candidate.logName(): String = url.substringBefore("://") + "://" + url.substringAfter("://").substringBefore('/')
```

- [ ] **Step 5: Bytes counter** — `Transport.kt` `Connection` gains `val bytesIn: Long get() = 0`. In
  `OkHttpTransport`, `OkConnection` takes an `AtomicLong` counter; `onMessage` does
  `counter.addAndGet(bytes.size.toLong())` before `trySend`; `override val bytesIn get() = counter.get()`.
  `RpcClient` exposes `val bytesIn: Long get() = conn.bytesIn`.

- [ ] **Step 6: Demotion in stats** — `EndpointStats.kt`:

```kotlin
data class EndpointStat(val lastSuccessMs: Long = 0, val lastFailureMs: Long = 0, val rttMs: Long = 0, val failures: Int = 0,
    val throttleCount: Int = 0, val throttleWindowStartMs: Long = 0, val demotedUntilMs: Long = 0)

interface EndpointStats {
    suspend fun get(key: String): EndpointStat?
    suspend fun success(key: String, rttMs: Long, nowMs: Long)
    suspend fun failure(key: String, nowMs: Long)
    /** A "reset after N KB" (D73): 3 within 24 h demote the endpoint for 24 h. */
    suspend fun throttled(key: String, nowMs: Long)
}

/** Shared rule for both implementations. */
fun EndpointStat.withThrottle(nowMs: Long): EndpointStat {
    val fresh = nowMs - throttleWindowStartMs >= DAY_MS
    val count = if (fresh) 1 else throttleCount + 1
    val start = if (fresh) nowMs else throttleWindowStartMs
    return copy(lastFailureMs = nowMs, failures = failures + 1, throttleCount = count, throttleWindowStartMs = start,
        demotedUntilMs = if (count >= 3) nowMs + DAY_MS else demotedUntilMs)
}

const val DAY_MS = 86_400_000L
```

`InMemoryEndpointStats.throttled` = `map[key] = (map[key] ?: EndpointStat()).withThrottle(nowMs)` inside
`synchronized`.

- [ ] **Step 7: `NodeSelector`** — constructor gains `private val netLog: NetLog = NetLog.None`. In `order`, group 3
  for demoted: change `group` to

```kotlin
        fun group(s: EndpointStat?) = when {
            s != null && now < s.demotedUntilMs -> 3
            s != null && now - s.lastFailureMs < RECENT_FAILURE_MS && s.lastFailureMs > s.lastSuccessMs -> 2
            s != null && s.lastSuccessMs > 0 && now - s.lastSuccessMs < RECENT_SUCCESS_MS -> 0
            else -> 1
        }
```

In `race`, keep the exception: change the result type to `Triple<Candidate, Winner?, Throwable?>`; on timeout use
`HandshakeFailed("no hello in ${helloTimeoutMs} ms")` if the transport connected, else the exception. When reading
results: failure → `stats.failure(...)` and `netLog.add(NetLogEntry(c.label, c.logName(), classify(err, 0), err?.message ?: ""))`;
winner → `netLog.add(NetLogEntry(c.label, c.logName(), FailureClass.OK, rttMs = w.rttMs))`. Same in `probe`.
Cancelled losers are not logged.

- [ ] **Step 8: `ConnectionManager`** — constructor gains `private val netLog: NetLog = NetLog.None`. After
  `w.rpc.closed.await()` returns `cause`:

```kotlin
                    val cause = w.rpc.closed.await()
                    val lived = clock() - connectedAt
                    if (cause != null && lived < 120_000 && w.rpc.bytesIn >= THROTTLE_BYTES) {
                        stats.throttled(w.candidate.key, clock())
                        netLog.add(NetLogEntry(w.candidate.label, w.candidate.logName(), FailureClass.RESET_AFTER_KB,
                            "${w.rpc.bytesIn} bytes in ${lived / 1000} s: ${cause.message}"))
                    }
```

(`val connectedAt = clock()` right after `rpc = w.rpc`). A cancellation (`stop()`, network change → `rpc.close()`)
completes `closed` with `null` → not counted.

- [ ] **Step 9: Tests** — `NodeSelectorTest.kt` add:

```kotlin
    @Test fun demotedGoesLast() = runTest {
        val stats = InMemoryEndpointStats()
        val now = 10 * DAY_MS
        val sel = NodeSelector(FakeTransport(), stats, clock = { now })
        val a = cand("a"); val b = cand("b"); val c = cand("c")
        stats.failure(b.key, now - 1_000)                  // recently failed → group 2
        repeat(3) { stats.throttled(a.key, now - 5_000) }   // demoted → group 3
        assertEquals(listOf("c", "b", "a"), sel.order(listOf(a, b, c)).map { it.label })
    }
```

Use the file's existing `FakeTransport`/`cand` helpers (rename to match). In `ConnectionManagerTest.kt` add a case
with a fake connection whose `bytesIn` is 4096 and which closes with an `IOException` 1 s after hello: assert
`stats.get(key)!!.throttleCount == 1` and the fake `NetLog` received `RESET_AFTER_KB`.

- [ ] **Step 10: Run** `./gradlew :core:network:testDebugUnitTest` → `BUILD SUCCESSFUL`.

- [ ] **Step 11: Commit** — `git add -A core/network core/proto && git commit -m "feat(network): failure classes, throttling demotion, netlog hooks (D73)"`

---

### Task 9: Android — Room `net_log`, stats migration, network info

**Goal:** Persist the phone log (merged, 200 lines) and the throttle fields; DB version 7 via AutoMigration.

**Files:**
- Create: `core/database/src/main/kotlin/app/ottermsg/core/database/entity/NetLogEntity.kt`,
  `.../dao/NetLogDao.kt`
- Modify: `.../entity/EndpointStatEntity.kt`, `.../OtterDatabase.kt` (version 7, entity, dao, AutoMigration 6→7)
- Create: `core/data/src/main/kotlin/app/ottermsg/core/data/network/RoomNetLog.kt`, `.../NetworkInfo.kt`
- Modify: `.../RoomEndpointStats.kt`, `core/data/.../di/DataModule.kt` (provide `NetLog`, pass to selector/manager)
- Test: `core/database/src/androidTest/...` or Robolectric test used by the project for DAOs (follow the existing
  DAO test location), `core/data/src/test/.../RoomNetLogTest.kt`, migration test 6→7

**Acceptance Criteria:**
- [ ] `net_log` merge: the newest row with the same `(node_label, endpoint, network)` and same `result` gets
  `count+1`, `last_ms`, latest `detail`/`rtt_ms`/`operator`; otherwise insert; keep the newest 200 rows.
- [ ] `endpoint_stats` gets three columns with defaults 0; AutoMigration 6→7 succeeds on a v6 database with data
  (schema `7.json` exported).
- [ ] `network` is `wifi`/`mobile`/`other`/`none` from `ConnectivityManager`; `operator` from
  `TelephonyManager.networkOperatorName` only for mobile, else empty.

**Verify:** `./gradlew :core:database:testDebugUnitTest :core:data:testDebugUnitTest` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Entities**

```kotlin
package app.ottermsg.core.database.entity

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

/** Connectivity log (D74): one row per run of identical outcomes. */
@Entity(tableName = "net_log", indices = [Index(value = ["node_label", "endpoint", "network"])])
data class NetLogEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    @androidx.room.ColumnInfo(name = "node_label") val nodeLabel: String,
    val endpoint: String,
    val network: String,
    val operator: String,
    val result: String,
    val detail: String,
    @androidx.room.ColumnInfo(name = "rtt_ms") val rttMs: Long,
    val count: Int,
    @androidx.room.ColumnInfo(name = "first_ms") val firstMs: Long,
    @androidx.room.ColumnInfo(name = "last_ms") val lastMs: Long,
)
```

In `EndpointStatEntity` add (match its column naming style; read the file first):

```kotlin
    @ColumnInfo(defaultValue = "0") val throttleCount: Int = 0,
    @ColumnInfo(defaultValue = "0") val throttleWindowStartMs: Long = 0,
    @ColumnInfo(defaultValue = "0") val demotedUntilMs: Long = 0,
```

- [ ] **Step 2: DAO**

```kotlin
package app.ottermsg.core.database.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import androidx.room.Transaction
import app.ottermsg.core.database.entity.NetLogEntity
import kotlinx.coroutines.flow.Flow

@Dao
abstract class NetLogDao {
    @Query("SELECT * FROM net_log WHERE node_label = :label AND endpoint = :endpoint AND network = :network ORDER BY id DESC LIMIT 1")
    abstract suspend fun latest(label: String, endpoint: String, network: String): NetLogEntity?

    @Insert abstract suspend fun insert(e: NetLogEntity): Long

    @Query("UPDATE net_log SET count = count + 1, last_ms = :now, detail = :detail, rtt_ms = :rtt, operator = :operator WHERE id = :id")
    abstract suspend fun bump(id: Long, now: Long, detail: String, rtt: Long, operator: String)

    @Query("DELETE FROM net_log WHERE id NOT IN (SELECT id FROM net_log ORDER BY id DESC LIMIT :max)")
    abstract suspend fun trim(max: Int)

    @Query("SELECT * FROM net_log ORDER BY last_ms DESC, id DESC")
    abstract fun observe(): Flow<List<NetLogEntity>>

    @Query("SELECT * FROM net_log ORDER BY last_ms DESC, id DESC")
    abstract suspend fun all(): List<NetLogEntity>

    @Transaction
    open suspend fun add(e: NetLogEntity, max: Int = MAX) {
        val last = latest(e.nodeLabel, e.endpoint, e.network)
        if (last != null && last.result == e.result) bump(last.id, e.lastMs, e.detail, e.rttMs, e.operator)
        else { insert(e); trim(max) }
    }

    companion object { const val MAX = 200 }
}
```

- [ ] **Step 3: Database** — `OtterDatabase.kt`: add `NetLogEntity::class` to `entities`, `version = 7`,
  `AutoMigration(from = 6, to = 7)`, `abstract fun netLogDao(): NetLogDao`. Build once to export
  `core/database/schemas/.../7.json` and commit it. Add a migration test next to existing ones (if the project has
  `MigrationTestHelper` tests, add `migrate6to7` inserting an `endpoint_stats` row at v6 and reading it at v7 with
  throttle columns = 0; if not, add one under `core/database/src/androidTest` and run it on the emulator in Task 12).

- [ ] **Step 4: Network info + Room log** — `NetworkInfo.kt`:

```kotlin
package app.ottermsg.core.data.network

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.telephony.TelephonyManager
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

/** Current network type and mobile operator name for the connectivity log (no permission needed). */
@Singleton
open class NetworkInfo @Inject constructor(@ApplicationContext private val ctx: Context) {
    open fun current(): Pair<String, String> {
        val cm = ctx.getSystemService(ConnectivityManager::class.java) ?: return "none" to ""
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return "none" to ""
        return when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi" to ""
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ->
                "mobile" to (ctx.getSystemService(TelephonyManager::class.java)?.networkOperatorName ?: "")
            else -> "other" to ""
        }
    }
}
```

`RoomNetLog.kt`:

```kotlin
package app.ottermsg.core.data.network

import app.ottermsg.core.data.Clock
import app.ottermsg.core.database.dao.NetLogDao
import app.ottermsg.core.database.entity.NetLogEntity
import app.ottermsg.core.network.NetLog
import app.ottermsg.core.network.NetLogEntry
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class RoomNetLog @Inject constructor(private val dao: NetLogDao, private val net: NetworkInfo, private val clock: Clock) : NetLog {
    override suspend fun add(e: NetLogEntry) {
        val (network, operator) = net.current()
        val now = clock.now()
        dao.add(NetLogEntity(nodeLabel = e.nodeLabel, endpoint = e.endpoint, network = network, operator = operator,
            result = e.result.wire, detail = e.detail.take(200), rttMs = e.rttMs, count = 1, firstMs = now, lastMs = now))
    }
}
```

(Use the real `Clock` API of `core/data/Clock.kt` — read it; replace `clock.now()` accordingly.)
`RoomEndpointStats`: map the three new columns in `get`, add

```kotlin
    override suspend fun throttled(key: String, nowMs: Long) = mutex.withLock {
        val s = dao.get(key) ?: EndpointStatEntity(key)
        val t = EndpointStat(s.lastSuccessMs, s.lastFailureMs, s.rttMs, s.failures, s.throttleCount, s.throttleWindowStartMs, s.demotedUntilMs).withThrottle(nowMs)
        dao.upsert(s.copy(lastFailureMs = t.lastFailureMs, failures = t.failures, throttleCount = t.throttleCount,
            throttleWindowStartMs = t.throttleWindowStartMs, demotedUntilMs = t.demotedUntilMs))
    }
```

`DataModule.kt`: `@Provides @Singleton fun netLog(l: RoomNetLog): NetLog = l`, `@Provides fun netLogDao(db: OtterDatabase) = db.netLogDao()`
(match how other DAOs are provided — maybe in `core/database/di`), pass `netLog` into `NodeSelector(...)` and into the
`ConnectionManager` construction (in `SyncEngine`, which builds it — add a constructor parameter `netLog: NetLog`).

- [ ] **Step 5: Test** — `RoomNetLogTest.kt` (Robolectric in-memory DB like the existing data tests):

```kotlin
    @Test fun mergesAndCaps() = runTest {
        val log = RoomNetLog(db.netLogDao(), object : NetworkInfo(ctx) { override fun current() = "mobile" to "MTS" }, clock)
        repeat(3) { log.add(NetLogEntry("ru-1", "wss://1.2.3.4:27443", FailureClass.OK)) }
        log.add(NetLogEntry("ru-1", "wss://1.2.3.4:27443", FailureClass.TIMEOUT, "t"))
        val rows = db.netLogDao().all()
        assertEquals(2, rows.size)
        assertEquals("timeout", rows[0].result); assertEquals(3, rows[1].count); assertEquals("MTS", rows[1].operator)
        repeat(250) { log.add(NetLogEntry("n$it", "e", FailureClass.OK)) }
        assertEquals(200, db.netLogDao().all().size)
    }
```

- [ ] **Step 6: Run** `./gradlew :core:database:testDebugUnitTest :core:data:testDebugUnitTest` → success.

- [ ] **Step 7: Commit** — `git add -A core && git commit -m "feat(data): net_log table, throttle columns (Room v7), network info (D74)"`

---

### Task 10: Android — «Журнал подключений» screen and version 0.7.0

**Goal:** Settings → Подключение → «Журнал подключений» lists the log and shares it as text; app 0.7.0 (7).

**Files:**
- Create: `feature/settings/src/main/kotlin/app/ottermsg/feature/settings/NetLogScreen.kt`
- Modify: `feature/settings/.../SettingsScreen.kt` (row + callback), `feature/settings/src/main/res/values/strings.xml`,
  `values-en/strings.xml`, `app/src/main/java/app/ottermsg/AppNavHost.kt` (route), `app/build.gradle.kts`
  (versionName/versionCode)
- Test: `feature/settings/src/test/.../NetLogFormatTest.kt`

**Acceptance Criteria:**
- [ ] Row «Журнал подключений» / "Connection log" under the connection status row opens the screen.
- [ ] Each line: time span (local), node, endpoint, network (+operator), result, `×count`, detail for failures;
  newest first; empty state «Пока пусто» / "Nothing yet".
- [ ] «Поделиться» shares the whole log as plain text via `Intent.ACTION_SEND` (chooser), first line
  `Otter <version> · <date>`.
- [ ] App version 0.7.0, versionCode 7; debug and release builds succeed.

**Verify:** `./gradlew :feature:settings:testDebugUnitTest :app:assembleDebug` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Strings** — `values/strings.xml`:

```xml
    <string name="settings_netlog">Журнал подключений</string>
    <string name="netlog_empty">Пока пусто</string>
    <string name="netlog_share">Поделиться</string>
    <string name="netlog_wifi">Wi-Fi</string>
    <string name="netlog_mobile">моб.</string>
```

`values-en/strings.xml`: `Connection log`, `Nothing yet`, `Share`, `Wi-Fi`, `mobile`.

- [ ] **Step 2: Formatting (pure, tested)** — in `NetLogScreen.kt`:

```kotlin
internal fun formatLine(e: NetLogEntity, zone: java.time.ZoneId, mobileLabel: String): String {
    val fmt = java.time.format.DateTimeFormatter.ofPattern("dd.MM HH:mm").withZone(zone)
    val hm = java.time.format.DateTimeFormatter.ofPattern("HH:mm").withZone(zone)
    val first = java.time.Instant.ofEpochMilli(e.firstMs); val last = java.time.Instant.ofEpochMilli(e.lastMs)
    val span = if (e.count > 1) "${fmt.format(first)}–${hm.format(last)}" else fmt.format(last)
    val net = when (e.network) { "wifi" -> "Wi-Fi"; "mobile" -> listOf(mobileLabel, e.operator).filter { it.isNotBlank() }.joinToString(" "); else -> e.network }
    val tail = if (e.result != "ok" && e.detail.isNotBlank()) " (${e.detail})" else ""
    return "$span  ${e.nodeLabel}  ${e.endpoint}  $net  ${e.result}  ×${e.count}$tail"
}
```

Test:

```kotlin
class NetLogFormatTest {
    @Test fun formatsMergedMobileFailure() {
        val e = NetLogEntity(1, "ru-1", "wss://1.2.3.4:27443", "mobile", "MTS", "timeout", "connect timed out", 0, 3,
            1_700_000_000_000, 1_700_000_600_000)
        assertEquals("14.11 22:13–22:23  ru-1  wss://1.2.3.4:27443  моб. MTS  timeout  ×3 (connect timed out)",
            formatLine(e, java.time.ZoneId.of("UTC"), "моб."))
    }
}
```

(Verify the expected date string against the epoch values when running; fix the literal, not the code, if the
date differs.)

- [ ] **Step 3: Screen + ViewModel**

```kotlin
@HiltViewModel
class NetLogViewModel @Inject constructor(dao: NetLogDao) : ViewModel() {
    val rows = dao.observe().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
}

@Composable
fun NetLogRoute(onBack: () -> Unit, versionText: String, vm: NetLogViewModel = hiltViewModel()) {
    val rows by vm.rows.collectAsStateWithLifecycle()
    val ctx = LocalContext.current
    val mobile = stringResource(R.string.netlog_mobile)
    val zone = java.time.ZoneId.systemDefault()
    val shareTitle = stringResource(R.string.netlog_share)
    NetLogScreen(rows.map { formatLine(it, zone, mobile) }, onBack, onShare = {
        val text = (listOf("$versionText · ${java.time.LocalDate.now()}") + rows.map { formatLine(it, zone, mobile) }).joinToString("\n")
        val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
        ctx.startActivity(Intent.createChooser(send, shareTitle))
    })
}

@Composable
fun NetLogScreen(lines: List<String>, onBack: () -> Unit, onShare: () -> Unit) {
    Scaffold(containerColor = MaterialTheme.colorScheme.background,
        topBar = { OtterTopBar(stringResource(R.string.settings_netlog), onBack = onBack, actions = {
            IconButton(onClick = onShare, enabled = lines.isNotEmpty()) { Icon(Icons.Outlined.Share, stringResource(R.string.netlog_share)) }
        }) }) { padding ->
        if (lines.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) { Text(stringResource(R.string.netlog_empty)) }
        } else {
            LazyColumn(Modifier.fillMaxSize().padding(padding)) {
                items(lines) { l ->
                    Text(l, style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                        modifier = Modifier.fillMaxWidth().padding(horizontal = Dimens.screenGutter, vertical = Dimens.s8))
                }
            }
        }
    }
}
```

Check `OtterTopBar`'s real signature (it may not take `actions`; if not, add an optional
`actions: @Composable RowScope.() -> Unit = {}` parameter to it in `core/ui`). `feature/settings` must depend on
`core:database` for `NetLogDao`/`NetLogEntity` — check its `build.gradle.kts`; if it does not, expose a
`NetLogRepository` in `core/data` with `fun observe(): Flow<List<NetLogEntity>>` and inject that instead (feature
modules already depend on `core:data`).

- [ ] **Step 4: Wiring** — `SettingsScreen.kt`: add `onNetLog: () -> Unit` to `SettingsRoute`/`SettingsScreen`, and
  under the connection status row:

```kotlin
            OtterSettingsRow(stringResource(R.string.settings_netlog), icon = Icons.Outlined.ListAlt, onClick = onNetLog)
```

`AppNavHost.kt`: `const val NETLOG = "settings/netlog"`, pass `onNetLog = { nav.navigate(Routes.NETLOG) }`,
`composable(Routes.NETLOG) { NetLogRoute(onBack = { nav.popBackStack() }, versionText = AppVersion.current) }`.

- [ ] **Step 5: Version** — `app/build.gradle.kts`: `versionCode = 7`, `versionName = "0.7.0"`.

- [ ] **Step 6: Run** `./gradlew :feature:settings:testDebugUnitTest testDebugUnitTest :app:assembleDebug :app:assembleRelease`
  → success (release uses `keystore.properties` when present; do not print or log its passwords).

- [ ] **Step 7: Commit** — `git add -A && git commit -m "feat(settings): connection log screen with share; 0.7.0 (D74)"`

---

### Task 11: Acceptance on the dev mesh and emulator

**Goal:** Prove "Done when" locally before any real server is touched.

**Files:**
- Create: `otter-server/docs/m7-manual-test.md`, `otter-android/docs/m7-manual-test.md`
- Modify (if needed): `otter-server/deploy/test/e2e-mesh.sh` (optional REALITY node)

**Acceptance Criteria:**
- [ ] Server: `make check`, `go test ./... -count=1`, `bash deploy/test/scripts_test.sh`, meshsim REALITY tests 3×
  green. `go build` binary size recorded.
- [ ] Local two-node run (dev mesh, `.dev-mesh/`): node `fi` with `[reality]` on a high port (`listen = "127.0.0.1:24443"`,
  camouflage `dest = "www.microsoft.com:443"` if internet is available, otherwise a local TLS 1.3 server), node
  `ru` `dial_out_only`, WSS from `ru` to `fi` blocked with an `iptables`/`nft` rule **on this PC only** (or by
  giving `ru` a manifest whose `fi` WSS endpoint points to a closed port). Emulator A on `ru`, emulator B on `fi`
  exchange messages both ways; `otter-node netlog` on both shows the REALITY session; A's «Журнал подключений» shows
  its attempts; «Поделиться» produces text.
- [ ] `curl -vk --resolve www.microsoft.com:24443:127.0.0.1 https://www.microsoft.com:24443/` against `fi` shows the
  camouflage site's certificate (when using the real camouflage).
- [ ] App 0.6.0 → 0.7.0 update on the emulator through a dev news announcement keeps account, chats and news (Room
  6→7 migration).
- [ ] Manual checklists list every row, mark what passed locally, and leave the real-network rows (eeee, ru-1,
  phones, MTS/Beeline mobile in the city centre) for the owner.

**Verify:** the checklist files exist and every local row is marked PASS with a date.

**Steps:**

- [ ] **Step 1:** Run all automated checks listed above; fix failures (systematic-debugging skill).
- [ ] **Step 2:** Dev mesh run as described; record exact commands in `otter-server/docs/m7-manual-test.md` so the
  owner can repeat them.
- [ ] **Step 3:** Emulator run and migration check; record in `otter-android/docs/m7-manual-test.md`.
- [ ] **Step 4:** Remove any temporary firewall rule; `nft list ruleset`/`iptables -S` shows it is gone.
- [ ] **Step 5: Commit** both checklists — `git commit -m "docs: M7 manual checklists"`.

---

### Task 12: Docs, decisions, news draft, merge (after the owner says so)

**Goal:** Docs describe M7 as built; the owner approves the merge.

**Files:**
- Modify: `docs/00-decisions.md` (D70–D75, D26 note), `docs/05-transport.md` (topology, REALITY server-to-server,
  netlog, demotion implemented, CDN postponed), `docs/03-mesh-replication.md` (`dial_out_only`, per-endpoint
  dialing), `docs/11-deployment.md` (`reality-setup.sh`, `add-node.sh` question, rollback), `docs/09-roadmap.md` (M7
  row → done with notes; V1.x: app REALITY, CDN-WSS, phone log upload), both READMEs (one paragraph each)
- Create: `otter-server/dist/news/0.7.0.md` (RU/EN draft) — `dist/` is gitignored; never delete files there.

**Acceptance Criteria:**
- [ ] Decisions D70–D75 recorded with reasons as in the spec.
- [ ] `docs/05` no longer says "Not yet implemented (M7)" for demotion; describes netlog and REALITY between nodes.
- [ ] News draft `## ru` / `## en`, short, mentions «Журнал подключений» and faster/more reliable delivery in Russia;
  no IPs or server names in it.
- [ ] `scripts/secrets-check.sh` passes in both repos; the owner says "merge" → `git merge --no-ff m7-dpi` in each
  repo, push.

**Verify:** `scripts/secrets-check.sh` (both repos) → no findings; `git log --oneline -1` on `main` shows the merge
commit after the owner's approval.

**Steps:**

- [ ] **Step 1:** Write the docs changes; commit on `m7-dpi` in `docs`.
- [ ] **Step 2:** Write `otter-server/dist/news/0.7.0.md`:

```markdown
## ru
Otter 0.7.0
• Настройки → Подключение → «Журнал подключений»: видно, к какому серверу и по какой сети подключался телефон. Если что-то не работает — нажмите «Поделиться» и пришлите журнал.
• Серверы научились обходить блокировки между собой, поэтому сообщения надёжнее доходят из России и в Россию.

## en
Otter 0.7.0
• Settings → Connection → "Connection log" shows which server the phone connected to and over which network. If something does not work, tap "Share" and send the log.
• Servers can now reach each other around blocking, so messages get to and from Russia more reliably.
```

- [ ] **Step 3:** Run `scripts/secrets-check.sh` in both repos; show the owner the summary of changes and ask for
  the merge. Only after "merge": `git checkout main && git merge --no-ff m7-dpi && git push` in `otter-server`,
  `otter-android`, `docs`.

---

### Task 13: Owner steps on the real network (each asked first)

**Goal:** M7 running on eeee and the ru-1 node; phones on 0.7.0.

**Files:** none in git (state lives in `~/.otter-admin` and on the servers).

**Acceptance Criteria:**
- [ ] eeee on 0.7.0 with REALITY on :443; the host's other services still work.
- [ ] ru-1 node installed, `dial_out_only`, in the published manifest.
- [ ] `otter-node netlog` on ru-1 shows `reality:...:443 out ok`; eeee shows `in reality ok` and no `out` to it.
- [ ] Fallback verified by temporarily dropping ru-1 → eeee:443 in ru-1's firewall, then restored.
- [ ] Both phones on 0.7.0 via the news update; a phone on the ru-1 node and a phone on eeee exchange messages.

**Verify:** the real-network rows of both manual checklists are marked PASS by the owner.

**Steps (ask before each; passphrases only in the owner's terminal):**

- [ ] **Step 1:** Build release artifacts (`make dist VERSION=0.7.0` or the repo's release target) — new files in
  `dist/`, nothing deleted.
- [ ] **Step 2 (ask):** `deploy/upgrade-all.sh 0.7.0 --no-news` → eeee upgraded, health ok. Check the host's other services:
  `ss -ltnp` shows them unchanged.
- [ ] **Step 3 (ask):** On eeee: `otter-node reality-check www.microsoft.com dl.google.com www.apple.com`; on ru-1
  (after it is installed, or via a one-off copy of the binary to `/tmp` there) the same; pick a host passing on both.
- [ ] **Step 4 (ask):** `deploy/reality-setup.sh eeee --dest <host>` → "REALITY is on".
- [ ] **Step 5 (ask):** `deploy/add-node.sh <label> root@<itsoft-ip> --ip <itsoft-ip> --version 0.7.0` → answer
  **y** to the dial-out-only question; the script asks for the admin passphrase for `manifest sign` in the owner's
  terminal (the owner runs this step themselves).
- [ ] **Step 6 (owner's terminal):** `otter-admin manifest sign && otter-admin manifest publish` (for the REALITY
  endpoint from Step 4, if not already included).
- [ ] **Step 7 (ask):** Watch `otter-node netlog` on both nodes; then on ru-1 temporarily
  `nft add rule inet filter output ip daddr <eeee-ip> tcp dport 443 drop` (or the iptables equivalent),
  send a message, confirm the WSS fallback in netlog, delete the rule, confirm REALITY again.
- [ ] **Step 8 (owner runs):** `deploy/release-apk.sh 0.7.0 <release APK>` → news dialog with `dist/news/0.7.0.md`;
  phones update via «Обновить».
- [ ] **Step 9:** Owner fills the real-network checklist rows (including a mobile-data test in the city centre:
  does the phone reach the ru-1 node during whitelist periods? — the phone's «Журнал подключений» answers it).
