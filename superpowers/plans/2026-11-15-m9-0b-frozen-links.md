# M9.0b Frozen peer links: server hotfix 0.8.4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ru-1 keeps replicating with eeee although Russian DPI freezes every connection to eeee's address: frozen
sessions end within ~85 s, count as throttling, and ru-1 moves to a Cloudflare-fronted WSS endpoint of eeee.

**Architecture:** Three small server changes, same binary on every node: (1) a WebSocket ping on replication sessions
(M9 Task 60, moved here); (2) a session ended by a failed ping, or a node handshake that times out, ranks its endpoint
down (D73 extended); (3) `otter-admin node add-wss` / `node remove-endpoint` add a second, unpinned `via_cdn` WSS
endpoint to an existing node. The owner then puts a Cloudflare-proxied name in front of eeee's WSS port.

**Tech Stack:** Go 1.26, `github.com/coder/websocket`, existing `internal/replication`, `internal/netlog`,
`internal/admin`, `cmd/otter-admin`; Cloudflare (owner's account, set up by the owner).

---

## Why (field report, 2026-11-15)

Measured by the owner on ru-1 (addresses only in the owner's notes, never in repos):

| Test from ru-1 | Result |
|---|---|
| `journalctl` | `peer session up` → `peer session down … read: connection timed out` every ~151 s, then redial |
| `otter-node netlog` | only `wss:<eeee-ip>:27443`, 345 "ok" dials in 15 h; REALITY never tried |
| Hetzner speed file | 0 bytes in 20 s |
| Linode Frankfurt speed file | 0 bytes in 20 s |
| Cloudflare speed file | 20 MB in 2 s |
| `https://<eeee-ip>/` (REALITY port, fallback site) | 301, 219 bytes in 0.3 s |
| `dl.google.com` through eeee's REALITY port (`--resolve`) | 0 bytes in 20 s |

Reading: small exchanges pass, bulk data to eeee's address freezes whatever the traffic looks like (REALITY's camouflage
does not help; the freeze is by destination address range). 151 s = Go's default TCP keepalive (15 s idle + 9 × 15 s
probes). Our code never noticed: the session lasted longer than `throttleSession` (2 min) and had no ping, so the
endpoint stayed "ok" and the other endpoints were never tried.

## Facts verified in the code (main, 2026-11-15)

| Question | Answer | Source |
|---|---|---|
| Peer session keep-alive | none; `run` only reads frames | `otter-server/internal/replication/session.go:57-117` |
| Throttle rule | outbound session dropped < 2 min after ≥ 1 KB in → `rank.Done(ep, ResetAfterKB)` | `internal/replication/replicator.go` `runSession`, `throttleSession` |
| Ranker | group 0 recent ok → 1 by priority/manifest order → 2 failed < 10 min ago → 3 demoted (≥ 3 throttles in 24 h) | `internal/replication/endpoints.go:84-127` |
| Handshake failure after a good dial | logged as `handshake`, endpoint **not** ranked ("which endpoint carried it is not tracked here") | `replicator.go` `dialMissing` |
| `handshakeTimeout` | `const` 10 s | `internal/replication/handshake.go:21` |
| WSS without pins | Go: normal CA validation (`pinning.ClientConfig` with no pins); Android: plain OkHttp client | `internal/pinning/pinning.go:30-34`; `otter-android/core/network/.../OkHttpTransport.kt:24` |
| Code that assumes the node's own WSS endpoint | `Endpoints[0]` only (pins, rotate-tls, set-ip, DNS) | `internal/admin/nodeops.go:105,132,186,200`, `internal/admin/dns.go:32,65` |
| Phones' endpoint order | `priority * 1000 + manifest order` | `otter-android/core/network/.../Endpoints.kt` |
| Version | only `make release VERSION=x.y.z`; no source bump | `Makefile:21-29` |
| M9 Task 60 (ping) | drafted in the M9 plan for M9.4; moved here | `docs/superpowers/plans/2026-11-14-m9-security-hardening.md` Task 60 |

## Decisions

| D | Topic | Decision |
|---|---|---|
| D130 | Frozen links | Replication sessions ping every 25 s; no pong within 60 s ends the session (was M9 Task 60 / D115, moved here). An **outbound** session ended by a failed ping counts as `reset_after_kb` for its endpoint whatever its length or byte count (a freeze can start after a large transfer at any time), and a node handshake that fails after a good dial marks the endpoint failed. Cost accepted: a peer that reboots looks like one throttle; 3 in 24 h only reorder endpoints. |
| D131 | CDN-fronted WSS for node links (revives part of D75) | A node may carry extra WSS endpoints after its own (`Endpoints[0]` stays the pinned, direct one). A `via_cdn` endpoint has **no pins** (the CDN terminates TLS; CA validation) and priority 10, so nodes and phones use it only after the direct endpoints fail. Authentication stays in the node handshake (node key) and in signed records; content is end-to-end encrypted. Accepted: the CDN sees the metadata a node sees, and the CDN→origin hop is not certificate-checked (Cloudflare "Full"), so a party between Cloudflare and eeee could at worst act as a refusing or lying node, which the M9 threat model already covers. |

## Coordination with the M9 session

- The M9 session works in `otter-server` and `docs` on `m9-1-client`. **Do not touch those working trees.** Work in
  separate worktrees from `main` (Task 1 Step 1).
- After this hotfix is merged to `main`, the M9 session merges `main` into `m9-1-client` (small conflicts possible in
  `internal/replication/session.go` and `replicator.go`) and **skips M9 Task 60** (marked "moved" in the M9 plan by
  this plan's commit).
- D-numbers D130–D131 follow M10's D125–D129.

## Commit convention (D57)

Define once per shell (same as the M9 plan header):
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
Every message ends with `-m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`. Never a `Claude-Session:` line.
Never write real IPs, the secret WSS path, provider names of ru-1, or the owner's domain into a repo: use `<eeee-ip>`,
`<secret-path>`, `ru-1`, `<cdn-host>`. `scripts/secrets-check.sh` must print `secrets check: ok` before any push.
Go env: `export PATH=/usr/lib/go-1.26/bin:$HOME/go/bin:$PATH`.

---

### Task 1: Replication keep-alive ping with netlog (M9 Task 60, moved)

**Goal:** A peer session whose link froze or whose peer stops answering ends within `peerPing + peerPingTimeout`
(85 s) and leaves a `ping` line in the connectivity log, so the node redials.

**Files:**
- Modify: `otter-server/internal/replication/session.go` (new `keepalive`, `pingFailed` field; start it in `run` after `go s.writeLoop()`)
- Modify: `otter-server/internal/replication/replicator.go` (`peerSeen`, `notePingFail`, `SetTestTimings`)
- Test: `otter-server/internal/replication/keepalive_test.go` (new)

**Acceptance Criteria:**
- [ ] A session over a connection that stops reading and writing ends on both nodes within `peerPing + peerPingTimeout`.
- [ ] Each node that noticed writes a netlog entry `Endpoint "ping"`, `Class timeout`, direction `out` on the dialer, `in` on the acceptor.
- [ ] A healthy session survives ≥ 10 ping intervals (same `*session`).
- [ ] After the drop the nodes reconnect (a new session object appears).

**Verify:** `cd ~/Documents/Projects/OttterMSG/otter-server-0b && go test ./internal/replication/ -run 'Keepalive' -count=3 -race` → `ok`

**Steps:**

- [ ] **Step 1: Worktrees (the normal trees belong to the M9 session)**

```bash
cd ~/Documents/Projects/OttterMSG
git -C otter-server fetch origin && git -C otter-server worktree add ../otter-server-0b -b m9-0b-frozen origin/main
git -C docs fetch origin && git -C docs worktree add ../docs-0b -b m9-0b-frozen origin/main
```
Expected: two new directories `otter-server-0b`, `docs-0b` on branch `m9-0b-frozen`. All later steps run there.

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

// freezeConn plays a link that DPI froze (or a peer that stops answering on purpose): after freeze nothing is read
// or written, no FIN is sent, until Close.
type freezeConn struct {
	net.Conn
	frozen chan struct{}
	closed chan struct{}
	fOnce  sync.Once
	cOnce  sync.Once
}

func newFreezeConn(c net.Conn) *freezeConn {
	return &freezeConn{Conn: c, frozen: make(chan struct{}), closed: make(chan struct{})}
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
		fc := newFreezeConn(c)
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

Check before relying on them: `recLog` and `sessionOf` must not clash with names in other `_test.go` files of the
package (`grep -n "recLog\|func sessionOf\|freezeConn" internal/replication/*_test.go`); `memLog` in
`endpoints_test.go` is a different type and stays.

- [ ] **Step 3: Run — fails.** `go test ./internal/replication/ -run Keepalive -count=1` → compile error
  `undefined: peerPing`. After adding only the variables, `TestKeepaliveDropsFrozenPeerAndLogs` fails with
  "timed out waiting for ping failure in the netlog".

- [ ] **Step 4: Implement.** In `session.go` add to `session` (next to `bytesIn`):

```go
	pingFailed atomic.Bool // the session ended because the peer stopped answering pings (D130)
```

and:

```go
// Peer keep-alive (D130): a WebSocket ping every peerPing; no pong within peerPingTimeout ends the session. The pong
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
		s.pingFailed.Store(true)
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
  If `netlog.Classify(err, 0)` on a ping deadline returns anything other than `netlog.Timeout`, use
  `class := netlog.Timeout` (a missing pong is a timeout by definition) and keep the test's expectation.
  In `replicator.go` add to `Replicator`:

```go
	seenMu sync.Mutex
	seen   map[string]*peerSeen // per peer node id: monitoring state that outlives sessions (D130; M9.4 monitoring reads it)
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
oc -m "replication: ping peers every 25 s, drop silent sessions after 60 s and log them (D130)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: A frozen link ranks its endpoint down, so the next endpoint is tried

**Goal:** On ru-1's pattern (connect, then freeze), the dialing node stops preferring the frozen endpoint after the
first frozen session and carries replication over the next endpoint.

**Files:**
- Modify: `otter-server/internal/replication/replicator.go` (`runSession` throttle rule; `dialMissing` handshake failure ranks `ep`)
- Modify: `otter-server/internal/replication/handshake.go:21` (`handshakeTimeout` becomes a `var`)
- Modify: `otter-server/internal/replication/replicator.go` `SetTestTimings` (shorten `handshakeTimeout`)
- Test: `otter-server/internal/replication/freeze_test.go` (new; uses `freezeConn`, `sessionOf` from Task 1 and `memLog`, `known` from existing tests)

**Acceptance Criteria:**
- [ ] An outbound session that ends by a failed ping writes a netlog line for its endpoint with `Class reset_after_kb` and a `Detail` starting with `frozen:`, and the ranker records one throttle for it.
- [ ] With a frozen direct endpoint and a working second endpoint (priority 10), the dialer ends up on the second endpoint, a record registered on the far node reaches the dialer, and that session holds for ≥ 10 ping intervals.
- [ ] A dial that succeeds but whose node handshake times out marks that endpoint failed (`lastFail`), so the next dial tries the next endpoint first.
- [ ] Existing `TestSessionLogsInboundAndThrottle` still passes (the < 2 min / ≥ 1 KB rule is unchanged).

**Verify:** `go test ./internal/replication/ -run 'Frozen|Throttle|Keepalive' -count=3 -race` → `ok`

**Steps:**

- [ ] **Step 1: Failing test** `internal/replication/freeze_test.go`

```go
package replication

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"
	"ottermsg/server/internal/keys"
	"ottermsg/server/internal/netlog"
	pb "ottermsg/server/internal/proto/otterv1"
)

// dpiDialer plays the Russian freeze seen on ru-1 (2026-11-15): connections to a frozen endpoint open, then go
// silent after `after` (or right after the WebSocket upgrade when after == 0); other endpoints work normally.
type dpiDialer struct {
	frozen map[string]bool // EndpointName → frozen
	after  time.Duration
}

func (d *dpiDialer) DialEndpoint(ctx context.Context, n *pb.NodeInfo, ep *pb.Endpoint) (*websocket.Conn, error) {
	url := "ws://" + net.JoinHostPort(ep.Host, strconv.Itoa(int(ep.Port))) + ep.Path + "/peer"
	frozen := d.frozen[EndpointName(ep)]
	var fc *freezeConn
	hc := &http.Client{Transport: &http.Transport{DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
		c, err := (&net.Dialer{}).DialContext(ctx, network, addr)
		if err != nil {
			return nil, err
		}
		fc = newFreezeConn(c)
		if frozen && d.after > 0 {
			time.AfterFunc(d.after, fc.freeze)
		}
		return fc, nil
	}}}
	dctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	c, _, err := websocket.Dial(dctx, url, &websocket.DialOptions{HTTPClient: hc})
	if err != nil {
		return nil, err
	}
	if frozen && d.after == 0 {
		fc.freeze() // the upgrade passed; the node handshake will not
	}
	c.SetReadLimit(maxFrame)
	return c, nil
}

// frozenMesh: A (dial-out-only, like ru-1) and B (like eeee) with two endpoints: the direct one and a second
// listener with priority 10 (the CDN route in production).
func frozenMesh(t *testing.T, after time.Duration) (m *mesh, direct, second *pb.Endpoint, aLog *memLog, rank *Ranker) {
	m = newMesh(t, 2, false)
	a, b := m.nodes[0], m.nodes[1]
	mux := http.NewServeMux()
	mux.Handle("/x/peer", b.repl)
	srv2 := httptest.NewServer(mux)
	t.Cleanup(srv2.Close)
	u, _ := url.Parse(srv2.URL)
	port2, _ := strconv.Atoi(u.Port())
	man := proto.Clone(a.svc.CurrentManifest()).(*pb.Manifest)
	man.Version = 2
	man.Nodes[0].DialOutOnly = true // A dials B, never the other way round
	direct = man.Nodes[1].Endpoints[0]
	second = &pb.Endpoint{Kind: pb.Endpoint_WS_PLAIN, Host: "127.0.0.1", Port: uint32(port2), Path: "/x", ViaCdn: true, Priority: 10}
	man.Nodes[1].Endpoints = append(man.Nodes[1].Endpoints, second)
	rec := m.sign(pb.RecordType_MANIFEST, keys.ID16(m.netPub), man, m.netPriv)
	for _, nd := range m.nodes {
		if _, err := nd.svc.ImportRecord(context.Background(), rec); err != nil {
			t.Fatal(err)
		}
	}
	aLog = &memLog{}
	rank = NewRanker(time.Now)
	dd := &dpiDialer{frozen: map[string]bool{EndpointName(direct): true}, after: after}
	a.repl = New(a.svc, &MultiDialer{EP: dd, Rank: rank, Log: aLog}, quiet, WithNetlog(aLog, rank))
	return m, direct, second, aLog, rank
}

func TestFrozenSessionFallsBackToSecondEndpoint(t *testing.T) {
	m, direct, second, aLog, rank := frozenMesh(t, 300*time.Millisecond)
	a, b := m.nodes[0], m.nodes[1]
	m.start()
	eventually(t, "a frozen session counted as throttling", func() bool {
		return aLog.find(func(e netlog.Entry) bool {
			return e.Endpoint == EndpointName(direct) && e.Class == netlog.ResetAfterKB && strings.HasPrefix(e.Detail, "frozen:")
		})
	})
	rank.mu.Lock()
	throttles := len(rank.st[EndpointName(direct)].throttles)
	rank.mu.Unlock()
	if throttles < 1 {
		t.Fatalf("ranker throttles for the direct endpoint: %d", throttles)
	}
	eventually(t, "a dial over the second endpoint", func() bool {
		return aLog.find(func(e netlog.Entry) bool { return e.Endpoint == EndpointName(second) && e.Class == netlog.OK })
	})
	boris := m.register(1, "boris")
	eventually(t, "boris reaches A over the second endpoint", func() bool { return known(a, boris) })
	s := sessionOf(a, b.id)
	time.Sleep(10 * peerPing)
	if s == nil || sessionOf(a, b.id) != s {
		t.Fatal("the session over the second endpoint did not hold")
	}
}

func TestFrozenHandshakeTriesNextEndpoint(t *testing.T) {
	m, direct, second, aLog, rank := frozenMesh(t, 0)
	m.start()
	eventually(t, "a dial over the second endpoint", func() bool {
		return aLog.find(func(e netlog.Entry) bool { return e.Endpoint == EndpointName(second) && e.Class == netlog.OK })
	})
	rank.mu.Lock()
	st := rank.st[EndpointName(direct)]
	failed := st != nil && !st.lastFail.IsZero()
	rank.mu.Unlock()
	if !failed {
		t.Fatal("a handshake that froze did not mark the direct endpoint failed")
	}
}
```

- [ ] **Step 2: Run — fails.** `go test ./internal/replication/ -run Frozen -count=1` →
  `TestFrozenSessionFallsBackToSecondEndpoint` fails with "timed out waiting for a frozen session counted as
  throttling" (sessions end by ping but are not ranked, or last > `throttleSession` in other runs);
  `TestFrozenHandshakeTriesNextEndpoint` fails with "timed out waiting for a dial over the second endpoint"
  (the handshake failure leaves the direct endpoint first).

- [ ] **Step 3: Implement.**

  `handshake.go`: move `handshakeTimeout` out of the `const` block into a `var` with the same value and comment:
```go
var handshakeTimeout = 10 * time.Second // var: tests shorten it (SetTestTimings)
```

  `replicator.go` `SetTestTimings`: add `handshakeTimeout = 5 * dial`.

  `replicator.go` `runSession`: replace the throttle block with

```go
	if ep != nil && err != nil && r.baseCtx().Err() == nil {
		in, dur := s.bytesIn.Load(), time.Since(s.start)
		frozen := s.pingFailed.Load() // D130: a freeze can start at any time, even after a long transfer
		if frozen || (dur < throttleSession && in >= netlog.ThrottleBytes) {
			r.rank.Done(ep, netlog.ResetAfterKB)
			detail := fmt.Sprintf("%d bytes in %s: %v", in, dur.Round(time.Second), err)
			if frozen {
				detail = fmt.Sprintf("frozen: no pong within %s, %d bytes in %s", peerPingTimeout, in, dur.Round(time.Second))
			}
			r.nlog.Add(r.baseCtx(), netlog.Entry{Peer: r.labelOf(peer), Endpoint: EndpointName(ep), Direction: "out",
				Result: "fail", Class: netlog.ResetAfterKB, Detail: detail})
		}
	}
```

  `replicator.go` `dialMissing`, inside `if err := r.dialHandshake(ctx, c, n); err != nil {` after `c.CloseNow()`,
  inside `if ctx.Err() == nil {` and before the `r.nlog.Add`, add:

```go
					if ep != nil {
						r.rank.Done(ep, netlog.Handshake) // D130: the transport opened but froze or failed; try the next endpoint first
					}
```

  and change that block's comment to `// the transport attempt was already logged as ok; the endpoint is now ranked failed (D130)`.
  `rank.Done` with `netlog.Handshake` takes the `default` branch (`lastFail = now`), which puts the endpoint in group 2
  for 10 min; no throttle is counted, so a node with a broken key is not demoted for 24 h.

- [ ] **Step 4: Run** `go test ./internal/replication/ -run 'Frozen|Throttle|Keepalive' -count=3 -race` → `ok`;
  then `go test ./internal/replication/ ./internal/meshsim/ -count=1 -race` → `ok`.

- [ ] **Step 5: Commit**

```bash
git add internal/replication/replicator.go internal/replication/handshake.go internal/replication/freeze_test.go
oc -m "replication: a frozen session or handshake ranks its endpoint down so the next one is tried (D130)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `otter-admin node add-wss` and `node remove-endpoint`

**Goal:** The owner can add a CDN-fronted WSS endpoint to an existing node (and remove it again) without touching the
node's own pinned endpoint.

**Files:**
- Modify: `otter-server/internal/admin/nodeops.go` (new `WSSSpec`, `AddWSS`, `RemoveEndpoint`, after `AddReality`)
- Modify: `otter-server/cmd/otter-admin/main.go` (usage lines; `case "node add-wss"`, `case "node remove-endpoint"` next to `case "node add-reality"`)
- Test: `otter-server/internal/admin/nodeops_test.go` (new tests after `TestAddRealityOnPlainDevNode`)
- Test: `otter-server/cmd/otter-admin/main_test.go` (new `TestAddWSSCLI`)

**Acceptance Criteria:**
- [ ] `AddWSS` appends `{Kind WSS, Host, Port, Path = the node's secret path, ViaCdn, Priority}`; `Endpoints[0]` is unchanged.
- [ ] A `--cdn` endpoint has no pins; a non-CDN extra endpoint copies `Endpoints[0]`'s pins (same node certificate).
- [ ] Adding again with the same host and port replaces that endpoint (no duplicates).
- [ ] Host empty, port 0 or > 65535, a host equal to the node's own WSS host and port, or a node without a WSS endpoint → error.
- [ ] `RemoveEndpoint` removes the WSS endpoint with that host and port and refuses to remove `Endpoints[0]` or a missing one.
- [ ] CLI prints the new endpoint and "Run 'manifest sign' and 'manifest publish'."

**Verify:** `go test ./internal/admin/ ./cmd/otter-admin/ -count=1` → `ok`

**Steps:**

- [ ] **Step 1: Failing tests** in `internal/admin/nodeops_test.go` (it already imports `bytes`, `pb`, uses `newNet`
  which creates node `fi-1` with WSS host `chat.example.org`):

```go
func TestAddWSSCDN(t *testing.T) {
	dir := newNet(t)
	st, _ := LoadState(dir)
	own := proto.Clone(st.Nodes[0].Endpoints[0]).(*pb.Endpoint)
	ep, err := AddWSS(dir, WSSSpec{Label: "fi-1", Host: "n2.example.net", Port: 443, CDN: true, Priority: 10})
	if err != nil {
		t.Fatal(err)
	}
	if ep.Kind != pb.Endpoint_WSS || !ep.ViaCdn || len(ep.TlsSpkiPins) != 0 || ep.Priority != 10 || ep.Path != own.Path || ep.Port != 443 {
		t.Fatalf("endpoint: %+v", ep)
	}
	st, _ = LoadState(dir)
	n := st.Nodes[0]
	if len(n.Endpoints) != 2 || !proto.Equal(n.Endpoints[0], own) {
		t.Fatalf("endpoints: %+v", n.Endpoints)
	}
	if _, err := AddWSS(dir, WSSSpec{Label: "fi-1", Host: "n2.example.net", Port: 443, CDN: true, Priority: 20}); err != nil {
		t.Fatal(err)
	}
	st, _ = LoadState(dir)
	if len(st.Nodes[0].Endpoints) != 2 || st.Nodes[0].Endpoints[1].Priority != 20 {
		t.Fatalf("second add must replace: %+v", st.Nodes[0].Endpoints)
	}
	if _, err := AddWSS(dir, WSSSpec{Label: "fi-1", Host: "n3.example.net", Port: 8443}); err != nil {
		t.Fatal(err)
	}
	st, _ = LoadState(dir)
	if e := st.Nodes[0].Endpoints[2]; e.ViaCdn || len(e.TlsSpkiPins) == 0 || !bytes.Equal(e.TlsSpkiPins[0], own.TlsSpkiPins[0]) {
		t.Fatalf("a direct extra endpoint must carry the node's pins: %+v", e)
	}
	for _, bad := range []WSSSpec{
		{Label: "fi-1", Host: "", Port: 443},
		{Label: "fi-1", Host: "x.example.net", Port: 0},
		{Label: "fi-1", Host: "x.example.net", Port: 70000},
		{Label: "fi-1", Host: own.Host, Port: own.Port},
		{Label: "nope", Host: "x.example.net", Port: 443},
	} {
		if _, err := AddWSS(dir, bad); err == nil {
			t.Fatalf("accepted %+v", bad)
		}
	}
}

func TestRemoveEndpoint(t *testing.T) {
	dir := newNet(t)
	if _, err := AddWSS(dir, WSSSpec{Label: "fi-1", Host: "n2.example.net", Port: 443, CDN: true, Priority: 10}); err != nil {
		t.Fatal(err)
	}
	st, _ := LoadState(dir)
	own := st.Nodes[0].Endpoints[0]
	if err := RemoveEndpoint(dir, "fi-1", own.Host, own.Port); err == nil {
		t.Fatal("removed the node's own endpoint")
	}
	if err := RemoveEndpoint(dir, "fi-1", "missing.example.net", 443); err == nil {
		t.Fatal("removed a missing endpoint")
	}
	if err := RemoveEndpoint(dir, "fi-1", "n2.example.net", 443); err != nil {
		t.Fatal(err)
	}
	st, _ = LoadState(dir)
	if len(st.Nodes[0].Endpoints) != 1 {
		t.Fatalf("endpoints: %+v", st.Nodes[0].Endpoints)
	}
}
```

  Add `"google.golang.org/protobuf/proto"` to the test file's imports (it is not imported yet).
  In `cmd/otter-admin/main_test.go` add (it already imports `bytes`, `strings`, `testing`):

```go
func TestAddWSSCLI(t *testing.T) {
	t.Setenv("OTTER_ADMIN_PASSPHRASE", "a very long passphrase")
	dir := t.TempDir()
	var out bytes.Buffer
	for _, s := range [][]string{
		{"--dir", dir, "network", "init"},
		{"--dir", dir, "node", "add", "--label", "fi-1", "--wss-host", "chat.example.org"},
	} {
		if err := run(s, &out, strings.NewReader("")); err != nil {
			t.Fatalf("%v: %v", s, err)
		}
	}
	out.Reset()
	if err := run([]string{"--dir", dir, "node", "add-wss", "--label", "fi-1", "--host", "n2.example.net", "--cdn"}, &out, nil); err != nil ||
		!strings.Contains(out.String(), "WSS n2.example.net:443 cdn=true priority=10 pins=0") {
		t.Fatalf("add-wss: %v %s", err, out.String())
	}
	out.Reset()
	if err := run([]string{"--dir", dir, "node", "list"}, &out, nil); err != nil || strings.Count(out.String(), "fi-1") != 2 {
		t.Fatalf("node list: %v %s", err, out.String())
	}
	out.Reset()
	if err := run([]string{"--dir", dir, "node", "remove-endpoint", "--label", "fi-1", "--host", "n2.example.net", "--port", "443"}, &out, nil); err != nil {
		t.Fatalf("remove-endpoint: %v %s", err, out.String())
	}
	if err := run([]string{"--dir", dir, "node", "remove-endpoint", "--label", "fi-1", "--host", "chat.example.org", "--port", "27443"}, &out, nil); err == nil {
		t.Fatal("removed the node's own endpoint")
	}
}
```

- [ ] **Step 2: Run — fails.** `go test ./internal/admin/ ./cmd/otter-admin/ -count=1` → `undefined: AddWSS`.

- [ ] **Step 3: Implement** in `internal/admin/nodeops.go` after `AddReality`:

```go
type WSSSpec struct {
	Label, Host string
	Port        uint32
	CDN         bool   // behind a CDN: no pins, the CDN's certificate is checked against the CAs (D131)
	Priority    uint32 // higher = tried later; nodes and phones try the node's own endpoint first
}

// AddWSS adds (or replaces, same host and port) an extra WSS endpoint after the node's own (D131). The secret path is
// the node's; Endpoints[0] (the pinned, direct endpoint that rotate-tls, set-ip and dns use) never changes.
func AddWSS(dir string, s WSSSpec) (*pb.Endpoint, error) {
	st, err := LoadState(dir)
	if err != nil {
		return nil, err
	}
	n, err := findNode(st, s.Label)
	if err != nil {
		return nil, err
	}
	if s.Host == "" || s.Port == 0 || s.Port > 65535 {
		return nil, errors.New("--host and a --port between 1 and 65535 are required")
	}
	if len(n.Endpoints) == 0 || n.Endpoints[0].Kind != pb.Endpoint_WSS {
		return nil, fmt.Errorf("node %s has no WSS endpoint to take the secret path from", s.Label)
	}
	own := n.Endpoints[0]
	if strings.EqualFold(own.Host, s.Host) && own.Port == s.Port {
		return nil, errors.New("that is the node's own endpoint")
	}
	ep := &pb.Endpoint{Kind: pb.Endpoint_WSS, Host: s.Host, Port: s.Port, Path: own.Path, ViaCdn: s.CDN, Priority: s.Priority}
	if !s.CDN {
		for _, p := range own.TlsSpkiPins {
			ep.TlsSpkiPins = append(ep.TlsSpkiPins, bytes.Clone(p))
		}
	}
	keep := n.Endpoints[:1]
	for _, e := range n.Endpoints[1:] {
		if e.Kind == pb.Endpoint_WSS && strings.EqualFold(e.Host, s.Host) && e.Port == s.Port {
			continue
		}
		keep = append(keep, e)
	}
	n.Endpoints = append(keep, ep)
	return ep, saveNodes(dir, st.Nodes)
}

// RemoveEndpoint removes an extra WSS endpoint (host and port); the node's own endpoint cannot be removed.
func RemoveEndpoint(dir, label, host string, port uint32) error {
	st, err := LoadState(dir)
	if err != nil {
		return err
	}
	n, err := findNode(st, label)
	if err != nil {
		return err
	}
	if len(n.Endpoints) > 0 && strings.EqualFold(n.Endpoints[0].Host, host) && n.Endpoints[0].Port == port {
		return errors.New("that is the node's own endpoint; use 'node remove' or 'node set-ip'")
	}
	keep := n.Endpoints[:0]
	found := false
	for _, e := range n.Endpoints {
		if e.Kind == pb.Endpoint_WSS && strings.EqualFold(e.Host, host) && e.Port == port {
			found = true
			continue
		}
		keep = append(keep, e)
	}
	if !found {
		return fmt.Errorf("node %s has no WSS endpoint %s:%d", label, host, port)
	}
	n.Endpoints = keep
	return saveNodes(dir, st.Nodes)
}
```

  Add import `bytes` to `nodeops.go` (`errors`, `fmt`, `strings` are already imported).
  In `cmd/otter-admin/main.go` add two usage lines after the `node add-reality` line:

```
  node add-wss --label L --host H [--port 443] [--cdn] [--priority 10]
  node remove-endpoint --label L --host H --port P
```

  and two cases after `case "node add-reality":`'s block:

```go
	case "node add-wss":
		fs := flag.NewFlagSet("node add-wss", flag.ContinueOnError)
		var s admin.WSSSpec
		var port, prio uint
		fs.StringVar(&s.Label, "label", "", "node label")
		fs.StringVar(&s.Host, "host", "", "name clients dial (the CDN-proxied name with --cdn)")
		fs.UintVar(&port, "port", 443, "port clients dial")
		fs.BoolVar(&s.CDN, "cdn", false, "behind a CDN: no pins, CA-checked certificate (D131)")
		fs.UintVar(&prio, "priority", 10, "higher = tried later; the node's own endpoint has 0")
		if err := fs.Parse(a[2:]); err != nil {
			return err
		}
		if port > 65535 || prio > 1000 {
			return errors.New("--port must be 1-65535 and --priority 0-1000")
		}
		s.Port, s.Priority = uint32(port), uint32(prio)
		ep, err := admin.AddWSS(*dir, s)
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "node %s: WSS %s:%d cdn=%v priority=%d pins=%d\nRun 'manifest sign' and 'manifest publish'.\n",
			s.Label, ep.Host, ep.Port, ep.ViaCdn, ep.Priority, len(ep.TlsSpkiPins))
	case "node remove-endpoint":
		fs := flag.NewFlagSet("node remove-endpoint", flag.ContinueOnError)
		label := fs.String("label", "", "node label")
		host := fs.String("host", "", "endpoint host")
		port := fs.Uint("port", 0, "endpoint port")
		if err := fs.Parse(a[2:]); err != nil {
			return err
		}
		if *port == 0 || *port > 65535 {
			return errors.New("--port must be 1-65535")
		}
		if err := admin.RemoveEndpoint(*dir, *label, *host, uint32(*port)); err != nil {
			return err
		}
		fmt.Fprintf(out, "node %s: endpoint %s:%d removed. Run 'manifest sign' and 'manifest publish'.\n", *label, *host, *port)
```

  (`errors` is already imported in `main.go`.) New two-word commands dispatch the same way as `node add-reality`.

- [ ] **Step 4: Run** `go test ./internal/admin/ ./cmd/otter-admin/ -count=1` → `ok`; `make check` → all `ok`.

- [ ] **Step 5: Commit**

```bash
git add internal/admin/nodeops.go internal/admin/nodeops_test.go cmd/otter-admin/main.go cmd/otter-admin/main_test.go
oc -m "otter-admin: node add-wss / remove-endpoint for CDN-fronted node links (D131)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Docs: decisions, transport, deploy guide, M9 plan note

**Goal:** The docs say what the code now does, and the M9 executor knows Task 60 is done.

**Files:**
- Modify: `docs-0b/00-decisions.md` (D130, D131 rows; D73 and D75 rows get a "see D130/D131" note)
- Modify: `docs-0b/05-transport.md` (the CDN paragraph around line 30-33)
- Modify: `docs-0b/09-roadmap.md` (an "M9.0b" row after M9)
- Modify: `otter-server-0b/deploy/README.md` (new section "CDN-fronted endpoint (Cloudflare)")

**Acceptance Criteria:**
- [ ] D130/D131 rows carry the text of this plan's Decisions table.
- [ ] `05-transport.md` says: CDN-fronted WSS is used for node links that a censor freezes by address (D131), unpinned, priority 10.
- [ ] `deploy/README.md` holds the Cloudflare steps of Task 5 Step 6 with `<cdn-host>` and `<eeee-ip>` placeholders only.
- [ ] `scripts/secrets-check.sh` prints `secrets check: ok` in `docs-0b` and `otter-server-0b`.

**Verify:** `cd ~/Documents/Projects/OttterMSG/docs-0b && scripts/secrets-check.sh` → `secrets check: ok`

**Steps:**

- [ ] **Step 1:** Add to the end of the decisions table in `00-decisions.md` (after the last `| D…` row, check the
  current last number first: M10's D125–D129 may live only in the M10 plan; D130/D131 are reserved for this plan):

```
| D130 | Frozen peer links | Replication sessions ping every 25 s; no pong within 60 s ends the session. An outbound session ended by a failed ping counts as `reset_after_kb` for its endpoint whatever its length, and a node handshake that fails after a good dial marks the endpoint failed, so the next endpoint is tried. Accepted: a peer reboot looks like one throttle | ru-1 (2026-11-15): DPI froze every connection to eeee's address after a few KB; sessions lasted 151 s (TCP keepalive) and were never ranked down |
| D131 | CDN-fronted WSS for node links | Extra WSS endpoints after the node's own (`otter-admin node add-wss`); a `via_cdn` endpoint has no pins (CA check) and priority 10, so it is used only after the direct ones fail. Authentication stays in the node handshake and signed records; the CDN sees node-level metadata; the CDN→origin hop is not certificate-checked (Cloudflare "Full") | The freeze is by destination address range: REALITY on the same address froze too, Cloudflare passed 20 MB in 2 s |
```

  In the D73 row append ` Extended by D130.`; in the D75 row append ` CDN-fronted WSS revived for node links by D131.`

- [ ] **Step 2:** In `05-transport.md` replace the two lines starting `**Postponed (D75):**` with:

```
  **Node links (D131):** a node can carry an extra, unpinned WSS endpoint behind a CDN (priority 10) for peers whose
  path to its address is frozen by DPI; phones only reach it after every direct endpoint failed.
```

- [ ] **Step 3:** In `09-roadmap.md` add after the M9 row:

```
| M9.0b | Frozen peer links (server 0.8.4) | replication ping 25 s / 60 s, frozen session or handshake ranks the endpoint down (D130), `otter-admin node add-wss` / `remove-endpoint`, CDN-fronted WSS for eeee (D131) | — | ru-1 ↔ eeee sessions hold over the CDN endpoint; no `peer session down` for 30 min |
```

- [ ] **Step 4:** In `otter-server-0b/deploy/README.md` add a section "CDN-fronted endpoint (Cloudflare)" with the
  text of Task 5 Steps 6–8 (placeholders only).

- [ ] **Step 5: Commit both repos and run the checks**

```bash
cd ~/Documents/Projects/OttterMSG/docs-0b
git add 00-decisions.md 05-transport.md 09-roadmap.md
oc -m "docs: D130 frozen peer links, D131 CDN-fronted WSS for node links" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
scripts/secrets-check.sh
cd ../otter-server-0b
git add deploy/README.md
oc -m "deploy: CDN-fronted endpoint steps (D131)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
scripts/secrets-check.sh
```
Expected: `secrets check: ok` twice.

---

### Task 5: Release 0.8.4 and rollout (the owner runs every command)

**Goal:** eeee and ru-1 run 0.8.4, eeee carries a Cloudflare-fronted endpoint, and ru-1's session to eeee holds.

The executing agent **does not run anything on servers, DNS, Cloudflare or `~/.otter-admin`**. It runs Steps 1–2
locally, then hands Steps 3–10 to the owner as a list, one step at a time, waiting for the pasted output before the
next. `manifest sign` asks the owner for the admin passphrase in the owner's own terminal; never ask for it in chat.

**Acceptance Criteria:**
- [ ] `make check`, scripts and bundle tests (scratch copy), and `secrets-check.sh` in both repos pass.
- [ ] Merged `--no-ff` to `main` and pushed only after the owner's OK; worktrees removed.
- [ ] eeee and ru-1 report `0.8.4 active` in `deploy/status.sh`.
- [ ] `otter-admin node list` shows eeee's second WSS line `cdn=true pin=-`.
- [ ] On ru-1, `otter-node netlog` shows `wss:<cdn-host>:443 out ok`, and `journalctl` shows no `peer session down` for 30 min.

**Verify:** owner on ru-1: `journalctl -u otter-node --since "-30min" -o cat | grep -c "peer session down"` → `0`

**Steps:**

- [ ] **Step 1: Local checks (agent, no server)**

```bash
cd ~/Documents/Projects/OttterMSG/otter-server-0b
make check
d=$(mktemp -d) && rsync -a --exclude dist --exclude .dev-mesh --exclude .vm ./ $d/srv/ && (cd $d/srv && mkdir -p dist && deploy/test/scripts_test.sh && deploy/test/bundle_test.sh)
scripts/secrets-check.sh && (cd ../docs-0b && scripts/secrets-check.sh)
```
Expected: every package `ok`, `scripts test: ok`, `bundle test: ok`, `secrets check: ok` twice.

- [ ] **Step 2: Ask the owner → merge, push, remove worktrees**

```bash
cd ~/Documents/Projects/OttterMSG
for r in otter-server docs; do
  git -C $r fetch origin
  git -C $r worktree add ../$r-merge origin/main --detach
  (cd $r-merge && git merge --no-ff --no-commit m9-0b-frozen && oc -m "Merge M9.0b: frozen peer links, server 0.8.4 (D130, D131)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && scripts/secrets-check.sh && git push origin HEAD:main)
  git -C $r worktree remove ../$r-merge
done
git -C otter-server worktree remove ../otter-server-0b && git -C docs worktree remove ../docs-0b
```
(The normal `otter-server` and `docs` trees stay on the M9 session's branch; this merges through temporary worktrees.
Tell the M9 session afterwards: "merge origin/main into m9-1-client; M9 Task 60 is done (D130)".)

- [ ] **Step 3: Owner → build the release on the laptop** (from `main`, never from the M9 branch)

The normal `otter-server` tree is on the M9 session's branch, and `upgrade-all.sh` builds from the tree it lives in, so
build and roll out from a release worktree of `main`. Host names come from `~/.otter-admin/hosts`, which every tree shares.

```bash
cd ~/Documents/Projects/OttterMSG/otter-server && git fetch origin && git worktree add ../otter-server-rel origin/main --detach
cd ../otter-server-rel && make release VERSION=0.8.4 && ls dist/
```
Expected: `SHA256SUMS`, `otter-admin_0.8.4_linux_amd64`, `otter-node_0.8.4_linux_{amd64,arm64}`.
Keep this worktree until Step 11. (A copy for the archive afterwards:
`cp -n dist/*0.8.4* ../otter-server/dist/ && (cd ../otter-server/dist && sha256sum otter-*_* > SHA256SUMS)`; nothing
in `otter-server/dist/` is deleted.)

- [ ] **Step 4: Owner → upgrade eeee, then ru-1** (binary only; TURN and news untouched)

```bash
cd ~/Documents/Projects/OttterMSG/otter-server-rel
export OTTER_ADMIN_BIN=$PWD/dist/otter-admin_0.8.4_linux_amd64
deploy/upgrade-all.sh 0.8.4 --only eeee --no-news --no-turn
deploy/upgrade-all.sh 0.8.4 --only ru-1 --no-news --no-turn
deploy/status.sh
```
Expected: `eeee  upgraded 0.8.3 → 0.8.4`, `ru-1  upgraded 0.8.3 → 0.8.4`, both `0.8.4 active`. Exit 2 = rolled back
(stop, paste the output), 3 = act now.
Rollback: from the normal tree, `cd ../otter-server && deploy/upgrade-all.sh 0.8.3 --only <label> --no-news --no-turn`
(the 0.8.3 binaries are in its `dist/`, so nothing is rebuilt).

- [ ] **Step 5: Owner → first effect, before any CDN** (ru-1)

```bash
otter-node netlog --config /etc/otter/node.toml --limit 15
```
Expected within ~10 min: lines `eeee  ping  out  fail timeout` and `wss:<eeee-ip>:27443 out fail reset_after_kb (frozen: …)`,
followed by dials of `reality:<eeee-ip>:443` (which freeze too). This proves the detection works; replication is still
blocked until the CDN endpoint exists.

- [ ] **Step 6: Owner → Cloudflare (dashboard of the domain chosen for `<cdn-host>`)**

  1. DNS → Add record: type `A`, name = the `<cdn-host>` label, IPv4 `<eeee-ip>`, **Proxy status: Proxied** (orange).
  2. Rules → Origin Rules → Create: "Hostname equals `<cdn-host>`" → Destination port: **rewrite to 27443**.
  3. Rules → Configuration Rules → Create: "Hostname equals `<cdn-host>`" → SSL: **Full** (not "Full (strict)":
     eeee's certificate is self-signed and pinned). Leave the zone's default SSL mode as it is.
  4. Network → WebSockets: **On** (default).
  5. Do **not** enable caching rules, "Always use HTTPS" redirects to other ports, Rocket Loader or Bot Fight Mode for
     this name; they can break the WebSocket upgrade.

- [ ] **Step 7: Owner → test the CDN path** (from the laptop, then from ru-1)

```bash
curl -s -o /dev/null --max-time 10 -w 'site: %{http_code}\n' https://<cdn-host>/
curl -s -o /dev/null --max-time 5 --http1.1 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H "Sec-WebSocket-Key: $(head -c 16 /dev/urandom | base64)" \
  -w 'peer: %{http_code}\n' https://<cdn-host>/<secret-path>/peer
```
`<secret-path>` is the part after the port in eeee's `node list` WSS line (without the leading `/`).
Expected: `site: 200` (the node's camouflage site through Cloudflare), `peer: 101`. On ru-1 the same two lines.
`site: 52x` = origin rule or SSL mode wrong; `peer: 400/426` = WebSockets off or the path wrong.

- [ ] **Step 8: Owner → add the endpoint and publish** (laptop; `manifest sign` asks for the passphrase)

```bash
A=~/Documents/Projects/OttterMSG/otter-server-rel/dist/otter-admin_0.8.4_linux_amd64
$A node add-wss --label eeee --host <cdn-host> --port 443 --cdn --priority 10
$A node list
$A manifest sign
$A manifest publish --via eeee --via ru-1
```
Expected: `node eeee: WSS <cdn-host>:443 cdn=true priority=10 pins=0`; `node list` shows a second eeee WSS line with
`cdn=true pin=-`; publish prints `ok` (or `already current`) per node. If publishing via ru-1 times out, eeee's copy
still reaches ru-1 over the next short session.

- [ ] **Step 9: Owner → confirm on ru-1** (after ~15 min)

```bash
otter-node netlog --config /etc/otter/node.toml --limit 10
journalctl -u otter-node --since "-30min" -o cat | grep -E "peer session (up|down)" | tail -5
```
Expected: newest netlog lines `wss:<cdn-host>:443 out ok`; one `peer session up` and no `down` after it in the last
30 min (after the first ~15 min have passed).
Then a real test: send a photo from a phone that uses ru-1 to a phone that uses eeee; it arrives.

- [ ] **Step 10: Rollback of the CDN part** (only if it misbehaves)

```bash
$A node remove-endpoint --label eeee --host <cdn-host> --port 443 && $A manifest sign && $A manifest publish --via eeee --via ru-1
```
then delete the DNS record and both rules in Cloudflare.

- [ ] **Step 11: Roadmap and cleanup** — `git -C ~/Documents/Projects/OttterMSG/otter-server worktree remove ../otter-server-rel` after the archive copy of Step 3; in `docs` (through a worktree on `origin/main`, as in Step 2) mark the M9.0b row done with
  the date and nodes, commit with `oc -m "roadmap: M9.0b frozen peer links rolled out (0.8.4)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`,
  run `scripts/secrets-check.sh`, push after the owner's OK.

No news announcement and no APK: 0.8.4 changes nothing a phone shows.

## Owner questions (recommendation assumed in the tasks)

| # | Question | Recommendation |
|---|---|---|
| 1 | Which domain and name for `<cdn-host>`? | A name on a domain already in Cloudflare, not the one the network's phones use for eeee, so the CDN name can be dropped without touching anything else. The owner fills it in only at Task 5 Steps 6–8; it never goes into a repo. |
| 2 | Should phones also be allowed to use the CDN endpoint? | Yes, as last resort (priority 10). Phones abroad never reach it because eeee's direct endpoint works for them. |
| 3 | If Cloudflare is also frozen from ru-1 later | Add a small VPS at a provider Russia does not freeze, as a normal node (no code). |
