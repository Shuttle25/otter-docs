# M11 Location sharing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Members can send a location pin or share their live location (15 min / 30 min / 1 h / 8 h / until stopped)
in any chat, shown on a map whose pieces come only from their own node.

**Architecture:** Location travels end-to-end encrypted inside the existing `Content` (two new protobuf fields; nodes
see ordinary envelopes). Live updates are non-urgent envelopes that expire after 300 s and never push. Map vector
tiles are served by a new phone RPC `tiles.get`: each node keeps an LRU disk cache, a node with `[tiles] upstream`
(foreign nodes) fetches misses over HTTPS from OpenFreeMap, a node without it (ru-1) asks peers over the existing peer
session with two new frames. The app draws the map with MapLibre Native; its tile requests go to a fake host that an
OkHttp interceptor answers from `tiles.get`. Live sharing runs in a `location` foreground service and sends each update
through the outbox plus an expedited wake, so no connection stays open.

**Tech Stack:** Go 1.26 (otter-server), protobuf/buf, SQLite; Kotlin, Jetpack Compose, Room (AutoMigration), Hilt,
MapLibre Native Android, play-services-location (optional at runtime), Robolectric (otter-android).

**Spec:** `docs/superpowers/specs/2026-11-25-m11-location-sharing-design.md` (approved 2026-11-25).
**Versions:** server **0.13.0**, app **0.13.0** (versionCode **17**; M10 is 0.12.0 / 16).
**Precondition:** M10 video calls is **merged into main** in all repos (`git -C otter-android log origin/main --oneline | grep -m1 "Merge M10"`).
If not, stop and tell the owner.

---

## Facts from the code (main after M9.5, 2026-11-26: server 8ba388d, app cbd0fb5; re-check after M10's merge)

| Question | Answer | Source |
|---|---|---|
| Free proto fields | `DataMessage` ends at `attachments = 4` → `location = 5`; `Content.body` ends at `call = 6` → `location_update = 7` (M10 only adds `CallMessage.media = 6`); `PeerFrame.kind` ends at `tunnel_close = 15` → 16, 17 | `proto/otter/v1/content.proto`, `peer.proto` |
| Proto copies | the app copies server protos with `otter-android/scripts/sync-proto.sh`; nothing checks they match | — |
| Phone RPC | `Request{id, method, body}`; string switch in `internal/gateway/methods.go` `dispatch` (l.113); login required unless in `public` map; revoked → `REVOKED`; sentinels in `internal/service/errors.go` (`ErrQuota` → `STATUS_QUOTA`, `ErrUnavailable` → `STATUS_UNAVAILABLE`, `ErrNotFound`) | `methods.go:47-124` |
| Per-account limiter | `windowCounter.allow(now, window, key, limit)` zero-value struct in `Service` | `internal/service/ratelimit.go`, `service.go:89-93` |
| Peer request/response | `id := s.reqID.Add(1)`, chan in a map under `s.pmu`, `s.send(frame)`, select with timeout; serve side in `session.run()` type switch, `serveSem` (cap 4), recover goroutine; fan-out over peers like `Replicator.FetchChunk` | `internal/replication/handoff.go:21-37`, `session.go:98-195`, `blobs.go:47` |
| Frame limits | peer 8 MiB, phone gateway read 1 MiB | `session.go:24`, `gateway.go:23` |
| Config | `internal/config/config.go`; `Load` **rejects unknown keys** → a `[tiles]` section must only be written for ≥ 0.13.0 binaries (as `[turn]` in `deploy/make-bundle.sh:32-37`) | `config.go:120-122` |
| Data dir | `/var/lib/otter` (`cfg.DataDir`); systemd `ReadWritePaths=/var/lib/otter` | `cmd/otter-node/main.go:97-123` |
| HTTPS client pattern | FCM: 15 s client timeout, `io.LimitReader` | `internal/push/fcm.go:37-56` |
| Metrics | `metrics.Snapshot` JSON fields, `Line()`, `Prometheus()`; collected in `cmd/otter-node/status.go` `collect` | `internal/metrics/metrics.go` |
| Gateway tests | `startNode(t, opts...)`, `dial(t, n)`, `c.call(method, req, resp)`, `members(t, n, "anna", "boris")` | `internal/gateway/testclient_test.go`, `privacy_test.go` |
| Hostile peer tests | `newMesh(t, 2, false)`, `dialHandshake`, `writeFrame`/`readFrame` | `internal/replication/hostile_test.go` |
| Live node.toml edit | pattern `deploy/turn-kbps.sh` (from M10): version check, awk rewrite to `.new`, `otter-node check`, backup, restart, health, journal check, rollback | `deploy/turn-kbps.sh` |
| App composer | **no 📎 menu**: gallery `IconButton` (leading), text field with camera, send | `feature/conversation/.../MessageComposer.kt:35` |
| 1:1 send | `MessageRepository.sendText` (`messaging/MessageRepository.kt:121`), `dataContent(...)` l.297; outbox rows with `messageLocalId == null` are deleted after send | `Outbox.kt` |
| **Group expiry gap** | `Outbox.processGroup()` (l.108) has no expiry check and `GroupSender.buildRecord` (l.59) signs without `expiresMs` → fixed in Task 7 | `Outbox.kt`, `GroupSender.kt` |
| 1:1 receive | `MailboxReceiver.handle`, non-displayed cases at l.105-119 (`CALL` → `calls.onCallMessage`, then `markSeen`, ack, `continue`); anything after l.120 creates a conversation | `messaging/MailboxReceiver.kt` |
| Group receive | `GroupReceiver.place` drops non-`DATA` (l.169); author = verified envelope `sender`; `groups.isMember(gid, sender)` | `messaging/GroupReceiver.kt` |
| Room | version **10** (M10 may bump it: use the next number), AutoMigrations only, schemas in `core/database/schemas/`, `MigrationTest.kt` | `core/database/.../OtterDatabase.kt` |
| Message kinds | `MessageKind` TEXT=0 … SYSTEM_KEY_CHANGED=8 → `LOCATION = 9` (if M10 added a kind, take the next); also edit `MessageDao.unreadReceiptsPending`, `ChatListViewModel.kt:72-84`, `NotificationContent.kt:28` `SHOWN`, `MessageRepository.retry`, `SnapshotCodec.export/import` | `core/database/.../model/MessageStatus.kt` |
| Node API | `interface NodeApi` (defaults throw `OldNodeException`), `RemoteNodeApi` → `rpc.call("method", body)`, `RpcException(status)`, `isUnknownMethod()` | `core/network/.../NodeApi.kt`, `RpcClient.kt` |
| Online API | `fun interface OnlineApi { fun current(): NodeApi? }` from `SyncEngine` | `invite/InviteRepository.kt:26` |
| Wake send | `WakeScheduler.wakeNow()` (app) → `WakeWorker` → `BackgroundSync.drain` (≤ 60 s, idle 10 s, then releases) | `app/.../push/WakeScheduler.kt:25` |
| FGS model | `app/.../calls/CallService.kt` (`ServiceCompat.startForeground`, `START_NOT_STICKY`), channels in `app/.../notify/Channels.kt` | — |
| Play services check | `app/.../push/PushAvailability.kt` (in `:app`, not visible to features) | — |
| Fakes | `core/data/src/test/.../FakeNode.kt` (`Session : NodeApi`, answer hooks), `TestGraph.kt` (`TestClock`, `register`, `online()`), two `TestGraph`s on one `FakeNode` for two devices | — |
| Strings | `values/strings.xml` (ru, default) + `values-en/strings.xml` per module, prefixed keys | — |
| Backups | `backup/SnapshotCodec.kt` `export` l.54 filters kinds, `import` l.100 | — |
| Last decision | **D139**; M10 reserved D125–D129 → this plan uses **D140–D144** | `docs/00-decisions.md` |

## Decisions this plan adds (owner sees them in Task 14)

- **D140 Location content.** `DataMessage.location` (5) for a pin or a live start (urgent, receipts, fallback text
  `📍 Местоположение: lat, lon` + `geo:` URI for apps < 0.13). `Content.location_update` (7) for live updates:
  never urgent, no receipts, envelope expiry `created + 300 s`; the stop expires at the live end (open-ended:
  `now + 7 days`). Receiver accepts an update only if (1) its author is the share's author, (2) the share is live by
  the receiver's clock — `min(sent_ms, received_ms) + live_period_s`, so a sender cannot extend it by back-dating,
  and not stopped — and (3) `fix_ms` is newer than the stored fix. Updates without a known share are dropped (the
  next one comes within 5 min). Cadence: moved ≥ 30 m and ≥ 30 s since the last send, or 5 min heartbeat.
  Groups now honour outbox expiry (fixes a gap: group envelopes never expired).
- **D141 Map pieces on nodes.** Phone RPC `tiles.get{z,x,y}` (members only, `z ≤ 14`, 600/min per account →
  `QUOTA`). Disk cache `<data_dir>/tiles/z/x/y.pbf`, LRU by last use, cap `[tiles] cache_mb` (default 2048). Each
  piece ≤ 1 MiB; a gzip piece must decompress (≤ 8 MiB) or it is refused and not cached. `[tiles] upstream` (TileJSON
  URL or a `{z}/{x}/{y}` template, default empty) makes a node fetch misses over HTTPS (15 s timeout, one fetch per
  piece at a time, 20 fetches/s per node). A node without upstream asks its peers with `PeerTileGet`/`PeerTile`
  (peer frames 16/17); a peer answers from its cache or its own upstream, **never asks further peers** (no loops), and
  refuses frames outside an authenticated peer session like every peer frame. Nothing found → `NOT_FOUND`; app shows
  the coordinates card.
- **D142 Live sharing without a persistent connection** (bounded exception to D61's "no persistent foreground
  service"): `LiveLocationService` (`foregroundServiceType="location"`) runs only while a share is on, with the
  notification «Вы делитесь местоположением · Остановить». It takes no `SyncEngine` lease: each update goes to the
  outbox and `WakeScheduler.wakeNow()` sends it; the wake releases the connection after 10 s idle. After reboot or
  process death the share is not resumed: on next start the app sends `stopped`. No background-location permission.
- **D143 Attach menu.** The composer's leading gallery button becomes an attach button (📎) with «Фото»,
  «Местоположение»; the camera button in the text field stays.
- **D144 Map rendering.** MapLibre Native, style/glyphs/sprites bundled in the APK (`asset://map/...`), only vector
  tiles travel; «© OpenStreetMap» attribution on every map; coordinates always shown as text.

## Branches, worktrees, commits

```bash
cd ~/Documents/Projects/OttterMSG
for r in otter-server otter-android docs; do
  git -C $r fetch origin && git -C $r worktree add ../$r-m11 -b m11-location origin/main
done
```
Work only in `otter-server-m11`, `otter-android-m11`, `docs-m11`. Commit with the `oc` function (copy it from
`docs/superpowers/plans/2026-11-15-m9-0b-frozen-links.md:72-85`; UTC 12:00:SS dates, D57). Every message ends with
`-m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`; never a `Claude-Session:` line.
Env: `export PATH=/usr/lib/go-1.26/bin:$HOME/go/bin:$PATH`, `export JAVA_HOME=~/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2`.
`otter-android-m11` needs `local.properties` (copy `sdk.dir` line from `otter-android/local.properties`).
**Laptop limits:** `go test -p 4`, heavy runs under `nice -n 15 ionice -c3`, Gradle `--max-workers=4`, never Go race
tests, Gradle and an emulator at the same time; one heavy job at a time.
Never create, print or commit `google-services.json`, `fcm*.json`, `release.jks`, `keystore.properties`. Never connect
to the owner's servers; give commands. Real IPs never in repos.

## File map

Server (`otter-server-m11/`):
- `proto/otter/v1/content.proto`, `api.proto`, `peer.proto` — location messages, `TileRequest`/`TileResponse`, `PeerTileGet`/`PeerTile`
- `internal/config/config.go` (+ `tiles_test.go`) — `[tiles]`
- `internal/tiles/cache.go`, `validate.go`, `upstream.go` (+ tests) — disk cache, piece checks, HTTPS fetcher
- `internal/replication/tiles.go` (+ `tiles_test.go`), `session.go` — peer frames, `Replicator.FetchTile`
- `internal/service/tiles.go` (+ test) — `TilesGet`, limit, source order
- `internal/gateway/methods.go`, `internal/gateway/tiles_test.go` — `tiles.get`
- `internal/metrics/metrics.go`, `cmd/otter-node/status.go`, `cmd/otter-node/main.go` — counters, wiring
- `deploy/templates/node.toml.tiles`, `deploy/make-bundle.sh`, `deploy/tiles-upstream.sh`, `deploy/README.md`

App (`otter-android-m11/`):
- `core/proto/...` (synced), `core/network/.../NodeApi.kt` (`tile`), `core/data/src/test/.../FakeNode.kt`
- `core/data/.../messaging/Outbox.kt`, `GroupSender.kt` — group expiry
- `core/database/.../model/MessageStatus.kt`, `entity/LiveLocationEntity.kt`, `dao/LiveLocationDao.kt`, `OtterDatabase.kt`
- `core/data/.../location/LocationCodec.kt`, `LocationSender.kt`, `LiveLocationApplier.kt`, `UpdatePolicy.kt`, `LiveShares.kt`
- `core/data/.../messaging/MailboxReceiver.kt`, `GroupReceiver.kt`, `MessageRepository.kt`, `backup/SnapshotCodec.kt`
- `app/.../location/LiveLocationService.kt`, `PositionSources.kt`, `TileInterceptor.kt`, `MapInit.kt`; `AndroidManifest.xml`; `notify/Channels.kt`
- `feature/location/` (new module): `LocationPickerScreen.kt`, `LiveMapScreen.kt`, `LocationBubble.kt`, `MapView.kt`, assets `map/`
- `feature/conversation/.../MessageComposer.kt`, `ConversationScreen.kt`, `ConversationViewModel.kt`, `MessageGrouping.kt`
- `feature/chats/.../ChatListViewModel.kt`, `app/.../notify/NotificationContent.kt`

---

### Task 1: Protos (server and app)

**Goal:** The new location, tile and peer messages exist in both repos and compile.

**Files:**
- Modify: `otter-server-m11/proto/otter/v1/content.proto`, `api.proto`, `peer.proto`
- Regenerate: `otter-server-m11/internal/proto/...`
- Sync: `otter-android-m11/core/proto/src/main/proto/otter/v1/*.proto`

**Acceptance Criteria:**
- [ ] `make gen` runs `buf lint` clean and regenerates Go code; `go build ./...` ok.
- [ ] `scripts/sync-proto.sh` copies the protos; `diff -r` between server and app proto dirs is empty.
- [ ] App `:core:proto` compiles.

**Verify:** `cd otter-server-m11 && make gen && go build ./... && cd ../otter-android-m11 && OTTER_SERVER_DIR=../otter-server-m11 scripts/sync-proto.sh && diff -r ../otter-server-m11/proto/otter/v1 core/proto/src/main/proto/otter/v1 && nice -n 15 ./gradlew --max-workers=4 :core:proto:build` → no diff, `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: content.proto** — add to `DataMessage` and `Content`, and the two messages:

```proto
message DataMessage {
  bytes message_id = 1;
  string text = 2;
  GroupContext group = 3;
  repeated Attachment attachments = 4;
  Location location = 5; // M11 (D140): a pin, or the start of a live share; text carries a fallback
}

// M11 (D140). Degrees × 1e7. live_period_s: 0 = one-time pin; 900, 1800, 3600, 28800; 4294967295 = until stopped.
message Location {
  sint32 lat_e7 = 1;
  sint32 lon_e7 = 2;
  uint32 accuracy_m = 3;
  uint32 live_period_s = 4;
}

// M11 (D140): a position update of a live share. Never urgent, no receipts, never shown as a message.
message LocationUpdate {
  bytes message_id = 1;   // the DataMessage that started the share
  GroupContext group = 2; // set in groups (SENDER_KEY envelope)
  sint32 lat_e7 = 3;
  sint32 lon_e7 = 4;
  uint32 accuracy_m = 5;
  uint32 heading_deg = 6;
  uint32 speed_cms = 7;
  int64 fix_ms = 8;       // time of the fix, sender clock
  bool stopped = 9;
}
```
and in `Content.body`: `LocationUpdate location_update = 7;`

- [ ] **Step 2: api.proto** — next to `DirectoryLookupRequest`:

```proto
// M11 (D141): one vector map piece. z <= 14, x and y < 2^z. Answer: TileResponse, NOT_FOUND, QUOTA.
message TileRequest {
  uint32 z = 1;
  uint32 x = 2;
  uint32 y = 3;
}

message TileResponse {
  bytes data = 1; // as served upstream (Mapbox Vector Tile, usually gzip), <= 1 MiB
}
```

- [ ] **Step 3: peer.proto** — in `PeerFrame.kind` add `PeerTileGet tile_get = 16; PeerTile tile = 17;` and:

```proto
// M11 (D141): a node without upstream asks a peer for a map piece. The peer answers from its cache or its own
// upstream, never from further peers.
message PeerTileGet {
  uint64 req = 1;
  uint32 z = 2;
  uint32 x = 3;
  uint32 y = 4;
}

message PeerTile {
  uint64 req = 1;
  bytes data = 2;
  bool missing = 3;
}
```

- [ ] **Step 4:** `make gen && go build ./... && go vet ./...` → clean.
- [ ] **Step 5:** sync into the app and build `:core:proto` (Verify command).
- [ ] **Step 6: Commit** both repos:
  server `git add proto internal/proto && oc -m "proto: location content, tile request, peer tile frames (M11, D140, D141)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`;
  app `git add core/proto && oc -m "proto: sync M11 location and tile messages" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`.

---

### Task 2: Server `[tiles]` config and the disk cache

**Goal:** A node reads `[tiles]` and keeps map pieces in a size-capped LRU disk cache that refuses bad pieces.

**Files:**
- Modify: `otter-server-m11/internal/config/config.go`
- Create: `otter-server-m11/internal/config/tiles_test.go`
- Create: `otter-server-m11/internal/tiles/validate.go`, `cache.go`, `cache_test.go`

**Acceptance Criteria:**
- [ ] No `[tiles]` section → `CacheMB = 2048`, `Upstream = ""`.
- [ ] `upstream` must be `https://` (or `http://127.0.0.1…` only in tests via the `allowPlain` test hook); `cache_mb` 64…1048576.
- [ ] `Valid(z,x,y)` rejects `z > 14` and `x, y ≥ 2^z`; `Check(data)` rejects empty, > 1 MiB, broken gzip, gzip > 8 MiB.
- [ ] Cache: `Put` then `Get` returns the bytes; total bytes stay ≤ cap after many `Put`s (least recently used removed first); a restart rebuilds the index from disk; files written atomically (tmp + rename).

**Verify:** `cd otter-server-m11 && nice -n 15 go test -p 4 -count=1 ./internal/config/ ./internal/tiles/` → `ok`

**Steps:**

- [ ] **Step 1: Failing config test** (`internal/config/tiles_test.go`, reuse `valid` and `write` from `config_test.go`):

```go
func TestTilesDefaults(t *testing.T) {
	c, err := Load(write(t, valid))
	if err != nil { t.Fatal(err) }
	if c.Tiles.CacheMB != 2048 || c.Tiles.Upstream != "" { t.Fatalf("defaults: %+v", c.Tiles) }
}

func TestTilesSection(t *testing.T) {
	c, err := Load(write(t, valid+"\n[tiles]\nupstream = \"https://tiles.openfreemap.org/planet\"\ncache_mb = 512\n"))
	if err != nil { t.Fatal(err) }
	if c.Tiles.CacheMB != 512 || c.Tiles.Upstream != "https://tiles.openfreemap.org/planet" { t.Fatalf("%+v", c.Tiles) }
	for _, bad := range []string{"upstream = \"http://x.example/planet\"", "cache_mb = 10", "upstream = \"ftp://x\""} {
		if _, err := Load(write(t, valid+"\n[tiles]\n"+bad+"\n")); err == nil { t.Errorf("accepted %q", bad) }
	}
}
```

- [ ] **Step 2:** `go test ./internal/config/ -run Tiles` → FAIL (`c.Tiles undefined`).
- [ ] **Step 3: Config** — in `Config` add `Tiles Tiles \`toml:"tiles"\``, and:

```go
// Tiles is the [tiles] section (M11, D141): map pieces for phones.
type Tiles struct {
	Upstream string `toml:"upstream"` // TileJSON URL or https template with {z}/{x}/{y}; empty = ask peers only
	CacheMB  int    `toml:"cache_mb"` // disk cache cap, default 2048
}

func (c *Config) validateTiles() error {
	if c.Tiles.CacheMB == 0 { c.Tiles.CacheMB = 2048 }
	if c.Tiles.CacheMB < 64 || c.Tiles.CacheMB > 1<<20 {
		return fmt.Errorf("tiles.cache_mb must be 64..1048576, got %d", c.Tiles.CacheMB)
	}
	if u := c.Tiles.Upstream; u != "" && !strings.HasPrefix(u, "https://") {
		return fmt.Errorf("tiles.upstream must start with https://")
	}
	return nil
}
```
Call `validateTiles()` from `validate()` next to `validateTurn()`.

- [ ] **Step 4: Piece checks** (`internal/tiles/validate.go`):

```go
// Package tiles serves vector map pieces to phones (M11, D141).
package tiles

const (
	MaxZoom     = 14
	MaxPiece    = 1 << 20 // bytes as stored and sent
	MaxUnzipped = 8 << 20
)

var ErrBadPiece = errors.New("bad map piece")

// Valid reports whether z/x/y names a piece of the web-mercator pyramid we serve.
func Valid(z, x, y uint32) bool { return z <= MaxZoom && x < 1<<z && y < 1<<z }

// Check refuses empty, oversized or broken pieces before they are cached or sent.
func Check(data []byte) error {
	if len(data) == 0 || len(data) > MaxPiece { return fmt.Errorf("%w: %d bytes", ErrBadPiece, len(data)) }
	if len(data) >= 2 && data[0] == 0x1f && data[1] == 0x8b {
		zr, err := gzip.NewReader(bytes.NewReader(data))
		if err != nil { return fmt.Errorf("%w: %v", ErrBadPiece, err) }
		n, err := io.Copy(io.Discard, io.LimitReader(zr, MaxUnzipped+1))
		if err != nil || n > MaxUnzipped { return fmt.Errorf("%w: gzip", ErrBadPiece) }
	}
	return nil
}
```

- [ ] **Step 5: Failing cache tests** (`internal/tiles/cache_test.go`):

```go
func piece(n int) []byte { b := make([]byte, n); b[0] = 0x1a; return b } // plain (not gzip) MVT-like bytes

func TestCachePutGet(t *testing.T) {
	c, err := OpenCache(t.TempDir(), 1<<20)
	if err != nil { t.Fatal(err) }
	if err := c.Put(3, 1, 2, piece(100)); err != nil { t.Fatal(err) }
	got, ok := c.Get(3, 1, 2)
	if !ok || len(got) != 100 { t.Fatalf("got %d %v", len(got), ok) }
	if _, ok := c.Get(3, 2, 2); ok { t.Fatal("phantom piece") }
}

func TestCacheEvictsLeastRecentlyUsed(t *testing.T) {
	c, _ := OpenCache(t.TempDir(), 1000)
	_ = c.Put(1, 0, 0, piece(400))
	_ = c.Put(1, 0, 1, piece(400))
	c.Get(1, 0, 0) // touch: 0/0 is now newer than 0/1
	_ = c.Put(1, 1, 0, piece(400))
	if _, ok := c.Get(1, 0, 1); ok { t.Fatal("least recently used piece kept") }
	if _, ok := c.Get(1, 0, 0); !ok { t.Fatal("recently used piece evicted") }
	if c.Bytes() > 1000 { t.Fatalf("cache %d > cap", c.Bytes()) }
}

func TestCacheReopenKeepsPieces(t *testing.T) {
	dir := t.TempDir()
	c, _ := OpenCache(dir, 1<<20)
	_ = c.Put(14, 9000, 5000, piece(10))
	c2, err := OpenCache(dir, 1<<20)
	if err != nil { t.Fatal(err) }
	if _, ok := c2.Get(14, 9000, 5000); !ok || c2.Bytes() != 10 { t.Fatal("index not rebuilt") }
}

func TestCacheRefusesBadPieces(t *testing.T) {
	c, _ := OpenCache(t.TempDir(), 1<<20)
	for _, bad := range [][]byte{nil, make([]byte, MaxPiece+1), {0x1f, 0x8b, 0, 0}} {
		if err := c.Put(1, 0, 0, bad); !errors.Is(err, ErrBadPiece) { t.Errorf("accepted %d bytes: %v", len(bad), err) }
	}
	if c.Bytes() != 0 { t.Fatal("bad piece stored") }
}
```

- [ ] **Step 6: Cache** (`internal/tiles/cache.go`): files under `dir/z/x/y.pbf`; in-memory index `map[key]*list.Element` with a `container/list` ordered by last use; `OpenCache` walks `dir` and inserts files ordered by mtime (oldest first); `Put` runs `Check`, writes `y.pbf.tmp` then `os.Rename`, then evicts from the back until `bytes ≤ cap`; `Get` reads the file, moves the entry to front (no mtime write per hit; `Close`-less). All under one `sync.Mutex`; file reads outside the lock are fine (a racing eviction yields a miss).

```go
type key struct{ z, x, y uint32 }
type entry struct { k key; size int64 }

type Cache struct {
	dir   string
	cap   int64
	mu    sync.Mutex
	bytes int64
	lru   *list.List
	idx   map[key]*list.Element
}

func OpenCache(dir string, capBytes int64) (*Cache, error)
func (c *Cache) Get(z, x, y uint32) ([]byte, bool)
func (c *Cache) Put(z, x, y uint32, data []byte) error
func (c *Cache) Bytes() int64
func (c *Cache) path(k key) string { return filepath.Join(c.dir, fmt.Sprint(k.z), fmt.Sprint(k.x), fmt.Sprint(k.y)+".pbf") }
```

- [ ] **Step 7:** Verify command → `ok`.
- [ ] **Step 8: Commit** `oc -m "tiles: [tiles] config, piece checks, LRU disk cache (M11, D141)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 3: Server HTTPS upstream fetcher

**Goal:** A node with `upstream` fetches missing pieces once each, bounded in size, time and rate.

**Files:**
- Create: `otter-server-m11/internal/tiles/upstream.go`, `upstream_test.go`

**Acceptance Criteria:**
- [ ] A TileJSON URL is resolved to `tiles[0]` (re-resolved after 24 h or after a 404 burst); a URL containing `{z}` is used as a template directly.
- [ ] 200 → bytes (after `Check`); 404/204 → `ErrMissing`; other status, timeout, > 1 MiB → error.
- [ ] 10 concurrent `Fetch` of the same piece → 1 upstream request (singleflight).
- [ ] More than 20 fetches/s per node → `ErrBusy` without contacting upstream.

**Verify:** `nice -n 15 go test -p 4 -count=1 ./internal/tiles/ -run Upstream` → `ok`

**Steps:**

- [ ] **Step 1: Failing tests** (`upstream_test.go`, `httptest.NewTLSServer`, client from `srv.Client()`):

```go
func TestUpstreamTileJSONAndOneFetchPerPiece(t *testing.T) {
	var hits atomic.Int32
	var srv *httptest.Server
	srv = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/planet":
			fmt.Fprintf(w, `{"tiles":["%s/v1/{z}/{x}/{y}.pbf"]}`, srv.URL)
		case r.URL.Path == "/v1/5/3/4.pbf":
			hits.Add(1); time.Sleep(50 * time.Millisecond); w.Write([]byte{0x1a, 1, 2})
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	u := NewUpstream(srv.URL+"/planet", srv.Client())
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); if b, err := u.Fetch(context.Background(), 5, 3, 4); err != nil || len(b) != 3 { t.Error(b, err) } }()
	}
	wg.Wait()
	if hits.Load() != 1 { t.Fatalf("upstream hit %d times", hits.Load()) }
	if _, err := u.Fetch(context.Background(), 5, 0, 0); !errors.Is(err, ErrMissing) { t.Fatalf("missing: %v", err) }
}

func TestUpstreamRefusesHugePiece(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(make([]byte, MaxPiece+10))
	}))
	defer srv.Close()
	u := NewUpstream(srv.URL+"/{z}/{x}/{y}", srv.Client())
	if _, err := u.Fetch(context.Background(), 1, 0, 0); !errors.Is(err, ErrBadPiece) { t.Fatalf("got %v", err) }
}

func TestUpstreamRateLimit(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte{0x1a}) }))
	defer srv.Close()
	u := NewUpstream(srv.URL+"/{z}/{x}/{y}", srv.Client())
	busy := 0
	for i := uint32(0); i < 40; i++ {
		if _, err := u.Fetch(context.Background(), 14, i, 0); errors.Is(err, ErrBusy) { busy++ }
	}
	if busy == 0 { t.Fatal("no rate limit") }
}
```

- [ ] **Step 2:** run → FAIL (`NewUpstream undefined`).
- [ ] **Step 3: Implement** (`upstream.go`): `golang.org/x/sync/singleflight` (already in go.mod? if not, implement a tiny map of `chan struct{}` under a mutex — do not add a dependency), `golang.org/x/time/rate`-free token bucket (20/s, burst 20; plain mutex + timestamps), template substitution with `strings.NewReplacer("{z}", …)`, body read through `io.LimitReader(resp.Body, MaxPiece+1)`, then `Check`.

```go
var (
	ErrMissing = errors.New("map piece does not exist upstream")
	ErrBusy    = errors.New("map upstream busy")
)

type Upstream struct {
	src    string       // TileJSON URL or template
	hc     *http.Client // 15 s timeout in production (NewHTTPClient)
	mu     sync.Mutex
	tmpl   string
	tmplAt time.Time
	flight map[string]*call
	bucket tokenBucket
}

func NewHTTPClient() *http.Client { return &http.Client{Timeout: 15 * time.Second} }
func NewUpstream(src string, hc *http.Client) *Upstream
func (u *Upstream) Fetch(ctx context.Context, z, x, y uint32) ([]byte, error)
```
TileJSON body read with a 64 KiB limit; `tiles[0]` must start with `https://` (in tests the server URL is https too).

- [ ] **Step 4:** Verify → `ok`.
- [ ] **Step 5: Commit** `oc -m "tiles: HTTPS upstream with TileJSON, one fetch per piece, 20/s (M11, D141)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 4: Peer tile frames

**Goal:** A node asks its peers for a piece; a peer answers from its cache or own upstream only, and a hostile peer cannot hurt the asker.

**Files:**
- Create: `otter-server-m11/internal/replication/tiles.go`, `tiles_test.go`
- Modify: `otter-server-m11/internal/replication/session.go` (pending map, dispatch cases), `replicator.go` (field `Tiles TileSource`)

**Acceptance Criteria:**
- [ ] `Replicator.FetchTile(ctx, z, x, y)` tries peers in order (last good peer first), 10 s per peer, returns the first piece that passes `tiles.Check`; all missing → `tiles.ErrMissing`.
- [ ] Serving side uses `TileSource.Local(ctx, z,x,y)` (cache, then own upstream) — never `FetchTile` (no loops); invalid z/x/y → `missing`; busy (`serveSem` full) → `missing` at once.
- [ ] A hostile peer answering with > 1 MiB, broken gzip, or an unknown `req` does not crash the session, nothing is cached, and the next peer is tried.

**Verify:** `nice -n 15 go test -p 4 -count=1 ./internal/replication/ -run Tile` → `ok`

**Steps:**

- [ ] **Step 1: Interface** (`tiles.go`):

```go
// TileSource is what a node can answer a peer's PeerTileGet with: its cache, then its own upstream (M11, D141).
// Implementations must never ask other peers.
type TileSource interface {
	Local(ctx context.Context, z, x, y uint32) ([]byte, error)
}

const peerTileTimeout = 10 * time.Second

func (s *session) tile(ctx context.Context, z, x, y uint32) ([]byte, error) // like session.holds
func (r *Replicator) FetchTile(ctx context.Context, z, x, y uint32) ([]byte, error) // like FetchChunk
```
In `session` add `tpending map[uint64]chan *pb.PeerTile` (init in `newSession`). Dispatch:
`case *pb.PeerFrame_TileGet:` → `serveSem` try-acquire, else answer `missing`; in a recovering goroutine: `!tiles.Valid` or `r.Tiles == nil` → missing; else `Local` with a 12 s context; error → missing; send `PeerTile{req, data}`.
`case *pb.PeerFrame_Tile:` → look up and delete in `tpending`, deliver (buffered 1); unknown `req` ignored.

- [ ] **Step 2: Failing tests** (`tiles_test.go`) with `newMesh(t, 2, false)`; set `m.nodes[1].repl.Tiles = fakeSource{...}`:

```go
type fakeSource struct{ data []byte; err error; calls *atomic.Int32 }
func (f fakeSource) Local(ctx context.Context, z, x, y uint32) ([]byte, error) { f.calls.Add(1); return f.data, f.err }

func TestPeerTileFetched(t *testing.T) {
	m := newMesh(t, 2, false)
	var calls atomic.Int32
	m.nodes[1].repl.Tiles = fakeSource{data: []byte{0x1a, 7}, calls: &calls}
	eventually(t, "peers connected", func() bool { return m.nodes[0].repl.reg.count() == 1 })
	b, err := m.nodes[0].repl.FetchTile(context.Background(), 4, 2, 3)
	if err != nil || !bytes.Equal(b, []byte{0x1a, 7}) { t.Fatalf("%v %v", b, err) }
}

func TestPeerTileMissingAndInvalid(t *testing.T) {
	m := newMesh(t, 2, false)
	var calls atomic.Int32
	m.nodes[1].repl.Tiles = fakeSource{err: tiles.ErrMissing, calls: &calls}
	eventually(t, "peers connected", func() bool { return m.nodes[0].repl.reg.count() == 1 })
	if _, err := m.nodes[0].repl.FetchTile(context.Background(), 4, 2, 3); !errors.Is(err, tiles.ErrMissing) { t.Fatal(err) }
	if _, err := m.nodes[0].repl.FetchTile(context.Background(), 15, 0, 0); !errors.Is(err, tiles.ErrMissing) { t.Fatal(err) }
	if calls.Load() != 1 { t.Fatalf("invalid z reached the source: %d calls", calls.Load()) }
}
```
Plus `TestHostilePeerTile` in `hostile_test.go` style: dial node A as a fake peer (`dialHandshake`), read A's `PeerTileGet` after calling `FetchTile` in a goroutine, answer with `PeerTile{Req: q.Req, Data: make([]byte, tiles.MaxPiece+1)}` → `FetchTile` returns an error, session still answers a following `PeerHoldsQuery`. Use the helper names that `hostile_test.go` already uses (`reg.count()` may be named differently: check `registry` methods and adapt).

- [ ] **Step 3:** run → FAIL; implement; Verify → `ok`.
- [ ] **Step 4: Commit** `oc -m "replication: PeerTileGet/PeerTile, FetchTile over peers, no forwarding (M11, D141)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 5: `tiles.get` for phones, metrics, wiring

**Goal:** Logged-in members get map pieces from cache → upstream → peers, limited to 600 per minute.

**Files:**
- Create: `otter-server-m11/internal/service/tiles.go`, `tiles_test.go`; `internal/gateway/tiles_test.go`
- Modify: `internal/service/service.go` (fields), `internal/gateway/methods.go`, `internal/metrics/metrics.go`, `cmd/otter-node/status.go`, `cmd/otter-node/main.go`

**Acceptance Criteria:**
- [ ] Order: cache hit → `upstream.Fetch` (if configured) → `Fetcher.FetchTile` (peers) — but **only if no upstream is configured** — → `ErrNotFound`. Successful fetches are cached.
- [ ] `TileSource.Local` (for peers) = cache → upstream, never peers.
- [ ] Not logged in → `UNAUTHORIZED`; revoked → `REVOKED`; z > 14 → `INVALID`; 601st in a minute → `QUOTA`; no source configured and no peers → `NOT_FOUND`.
- [ ] A node without upstream never contacts the upstream test server (hit counter stays 0).
- [ ] `Snapshot` gains `tiles_served`, `tiles_cache_hits`, `tiles_upstream`, `tiles_peer`, `tiles_cache_bytes`; `Line()` adds `tiles=<served>/<hits>`; Prometheus `otter_tiles_*`.

**Verify:** `nice -n 15 go test -p 4 -count=1 ./internal/service/ ./internal/gateway/ ./internal/metrics/ ./cmd/otter-node/ -run 'Tile|Metrics|Status'` → `ok`

**Steps:**

- [ ] **Step 1: Service** (`internal/service/tiles.go`):

```go
const TilesPerMinute = 600

// TileFetcher asks peers (replication.Replicator).
type TileFetcher interface{ FetchTile(ctx context.Context, z, x, y uint32) ([]byte, error) }

type Tiles struct {
	Cache    *tiles.Cache
	Upstream *tiles.Upstream // nil without [tiles] upstream
	Peers    TileFetcher     // used only when Upstream is nil
	Served, Hits, FromUpstream, FromPeers atomic.Int64
}

func (s *Service) TilesGet(ctx context.Context, user []byte, z, x, y uint32) ([]byte, error) {
	if s.Tiles == nil || s.Tiles.Cache == nil { return nil, fmt.Errorf("%w: map pieces", ErrUnavailable) }
	if !tiles.Valid(z, x, y) { return nil, fmt.Errorf("%w: tile %d/%d/%d", ErrInvalid, z, x, y) }
	if !s.tilesMinute.allow(s.Now(), time.Minute, hex.EncodeToString(user), TilesPerMinute) {
		return nil, fmt.Errorf("%w: at most %d map pieces a minute", ErrQuota, TilesPerMinute)
	}
	t := s.Tiles
	if b, ok := t.Cache.Get(z, x, y); ok { t.Hits.Add(1); t.Served.Add(1); return b, nil }
	var b []byte
	var err error
	if t.Upstream != nil {
		b, err = t.Upstream.Fetch(ctx, z, x, y)
		if err == nil { t.FromUpstream.Add(1) }
	} else if t.Peers != nil {
		b, err = t.Peers.FetchTile(ctx, z, x, y)
		if err == nil { t.FromPeers.Add(1) }
	} else {
		err = tiles.ErrMissing
	}
	if err != nil {
		if errors.Is(err, tiles.ErrBusy) { return nil, fmt.Errorf("%w: map busy", ErrRetryLater) }
		return nil, fmt.Errorf("%w: tile %d/%d/%d", ErrNotFound, z, x, y)
	}
	if perr := t.Cache.Put(z, x, y, b); perr != nil { return nil, fmt.Errorf("%w: tile", ErrNotFound) }
	t.Served.Add(1)
	return b, nil
}

// Local answers peers: cache, then own upstream. Never other peers (D141).
func (t *Tiles) Local(ctx context.Context, z, x, y uint32) ([]byte, error) {
	if b, ok := t.Cache.Get(z, x, y); ok { return b, nil }
	if t.Upstream == nil { return nil, tiles.ErrMissing }
	b, err := t.Upstream.Fetch(ctx, z, x, y)
	if err != nil { return nil, err }
	if err := t.Cache.Put(z, x, y, b); err != nil { return nil, err }
	return b, nil
}
```
Add `Tiles *Tiles` and `tilesMinute windowCounter` to `Service`.

- [ ] **Step 2: Gateway** (`methods.go` dispatch):

```go
case "tiles.get": // M11 (D141)
	var r pb.TileRequest
	if err := decode(req.Body, &r); err != nil { return nil, err }
	b, err := svc.TilesGet(ctx, s.user, r.Z, r.X, r.Y)
	if err != nil { return nil, err }
	return &pb.TileResponse{Data: b}, nil
```
Do **not** add `tiles.get` to `userWrites` (the per-minute limit in the service covers it).

- [ ] **Step 3: Failing gateway test** (`internal/gateway/tiles_test.go`), node with a cache and an upstream `httptest.NewTLSServer`; second node variant without upstream and with a counting upstream that must stay at 0:

```go
func TestTilesGet(t *testing.T) {
	var hits atomic.Int32
	up := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hits.Add(1); w.Write([]byte{0x1a, 9}) }))
	defer up.Close()
	n := startNode(t, func(g *Gateway) {
		c, _ := tiles.OpenCache(t.TempDir(), 64<<20)
		g.Svc.Tiles = &service.Tiles{Cache: c, Upstream: tiles.NewUpstream(up.URL+"/{z}/{x}/{y}", up.Client())}
	})
	ca, _ := members(t, n, "anna", "boris")
	var resp pb.TileResponse
	if st, msg := ca.call("tiles.get", &pb.TileRequest{Z: 3, X: 1, Y: 1}, &resp); st != pb.Status_STATUS_OK || len(resp.Data) != 2 { t.Fatal(st, msg) }
	ca.call("tiles.get", &pb.TileRequest{Z: 3, X: 1, Y: 1}, &resp)
	if hits.Load() != 1 { t.Fatalf("cache missed: %d upstream hits", hits.Load()) }
	if st, _ := ca.call("tiles.get", &pb.TileRequest{Z: 15}, &resp); st != pb.Status_STATUS_INVALID { t.Fatal(st) }
	anon := dial(t, n)
	if st, _ := anon.call("tiles.get", &pb.TileRequest{Z: 1}, &resp); st != pb.Status_STATUS_UNAUTHORIZED { t.Fatal(st) }
}

func TestTilesQuota(t *testing.T) { /* 600 OK cache hits on one piece, the 601st → STATUS_QUOTA; advance s.Now to reset */ }

func TestTilesNoUpstreamNeverDialsIt(t *testing.T) {
	var hits atomic.Int32
	up := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hits.Add(1) }))
	defer up.Close()
	n := startNode(t, func(g *Gateway) { c, _ := tiles.OpenCache(t.TempDir(), 64<<20); g.Svc.Tiles = &service.Tiles{Cache: c} })
	ca, _ := members(t, n, "anna", "boris")
	var resp pb.TileResponse
	if st, _ := ca.call("tiles.get", &pb.TileRequest{Z: 2, X: 1, Y: 1}, &resp); st != pb.Status_STATUS_NOT_FOUND { t.Fatal(st) }
	if hits.Load() != 0 { t.Fatal("node without upstream contacted it") }
}
```
Write `TestTilesQuota` fully (loop `service.TilesPerMinute` calls on a cached piece, then one more → `STATUS_QUOTA`). A revoked-member case: reuse the revocation helper used in `privacy_test.go` / M9.2 tests (search `Revoked` in `internal/gateway/*_test.go`) → `STATUS_REVOKED`. Adapt how the gateway reaches the service in `startNode` options (field name may be `g.svc`; check `testclient_test.go`).

- [ ] **Step 4: Wiring** (`cmd/otter-node/main.go`, after the replicator is built): `cache, err := tiles.OpenCache(filepath.Join(cfg.DataDir, "tiles"), int64(cfg.Tiles.CacheMB)<<20)`; `t := &service.Tiles{Cache: cache}`; `if cfg.Tiles.Upstream != "" { t.Upstream = tiles.NewUpstream(cfg.Tiles.Upstream, tiles.NewHTTPClient()) } else { t.Peers = repl }`; `svc.Tiles = t`; `repl.Tiles = t`. Log `"msg":"tiles on","upstream":<bool>,"cache_mb":N`.
- [ ] **Step 5: Metrics** — fields + `collect` + `Line()` + `Prometheus()`; extend the existing metrics test with the new names.
- [ ] **Step 6:** Verify → `ok`; then the full server suite once: `nice -n 15 ionice -c3 go test -p 4 -count=1 ./...` → all `ok`.
- [ ] **Step 7: Commit** `oc -m "service, gateway: tiles.get with cache, upstream or peers, 600/min; tiles metrics (M11, D141)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 6: Deploy — `[tiles]` in new bundles, `tiles-upstream.sh`, status

**Goal:** New nodes get a commented `[tiles]` section, and the owner can turn the upstream on for one node with a single script.

**Files:**
- Create: `otter-server-m11/deploy/templates/node.toml.tiles`, `deploy/tiles-upstream.sh`
- Modify: `deploy/make-bundle.sh` (append only for ≥ 0.13.0), `deploy/README.md`, `deploy/test/scripts_test.sh` (cases)

**Acceptance Criteria:**
- [ ] `make-bundle.sh` appends `node.toml.tiles` only when `version_ge "$version" 0.13.0`.
- [ ] `tiles-upstream.sh LABEL on|off`: refuses nodes below 0.13.0; `on` writes `upstream = "https://tiles.openfreemap.org/planet"` into `[tiles]` (creating the section), `off` removes the line; `otter-node check` before swap; backup `node.toml.pre-tiles`; restart; health; journal must show `"msg":"tiles on"` with the expected `"upstream":true|false`; otherwise rollback.
- [ ] Scripts test passes **in a scratch copy** (never in the real checkout).

**Verify:** `rm -rf /tmp/claude-1000/m11-deploy && cp -a otter-server-m11 /tmp/claude-1000/m11-deploy && (cd /tmp/claude-1000/m11-deploy && deploy/test/scripts_test.sh)` → all pass; then `rm -rf /tmp/claude-1000/m11-deploy`

**Steps:**

- [ ] **Step 1:** `deploy/templates/node.toml.tiles`:

```toml

[tiles]
# Map pieces for phones (M11, D141). With upstream set, this node fetches missing pieces from the public source
# (it sees this node's IP and the area, never who looks). Leave it empty on a node in a censored country: it then
# asks its peers. Turn on or off later with deploy/tiles-upstream.sh LABEL on|off.
# upstream = "https://tiles.openfreemap.org/planet"
# cache_mb = 2048
```

- [ ] **Step 2:** `deploy/tiles-upstream.sh` — copy the structure of `deploy/turn-kbps.sh` exactly (version probe, remote heredoc, awk rewrite into `node.toml.new`, `otter-node check`, `node.toml.pre-tiles`, restart, `health.sh`, journal grep, rollback). The awk: drop `upstream` lines inside `[tiles]`; for `on` print `upstream = "https://tiles.openfreemap.org/planet"` under the header; append `[tiles]` at the end if the header is missing. Journal check: `grep '"msg":"tiles on"' | grep -q "\"upstream\":$want"`.
- [ ] **Step 3:** `make-bundle.sh` — next to the `[turn]` append: `if version_ge "$version" 0.13.0; then cat "$ROOT/deploy/templates/node.toml.tiles" >> "$out/node.toml"; fi` (match the variable names used there).
- [ ] **Step 4:** `deploy/README.md`: a "Map pieces (M11)" paragraph: foreign nodes `deploy/tiles-upstream.sh <label> on`; the node in Russia stays off; `status.sh` shows `tiles=served/hits`.
- [ ] **Step 5:** add scripts_test cases (usage errors; refuses `ver=0.12.0` in the fake remote) following the existing `turn-kbps.sh` cases; run the Verify command in the scratch copy.
- [ ] **Step 6: Commit** `oc -m "deploy: [tiles] template for 0.13.0 bundles, tiles-upstream.sh (M11, D141)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 7: App — `NodeApi.tile`, group envelopes honour expiry

**Goal:** The app can ask its node for a map piece, and group outbox items expire like 1:1 items.

**Files:**
- Modify: `otter-android-m11/core/network/.../NodeApi.kt`, `core/network/src/test/.../NodeApiCallsTest.kt`
- Modify: `core/data/src/test/.../FakeNode.kt` (`tileAnswer` hook)
- Modify: `core/data/.../messaging/Outbox.kt` (`processGroup` expiry check), `GroupSender.kt` (`expiresMs` into the record)
- Test: `core/data/src/test/.../GroupExpiryTest.kt`

**Acceptance Criteria:**
- [ ] `tile(z,x,y): ByteArray?` returns bytes; `NOT_FOUND`/`UNAVAILABLE` → `null`; `QUOTA`/`RETRY_LATER` → `TileBusyException`; unknown method → `OldNodeException`.
- [ ] A group outbox item with `expiresMs` in the past is deleted without sending; a sent group record carries `expiresMs` (checked on the FakeNode's stored record).
- [ ] Existing group tests still pass.

**Verify:** `cd otter-android-m11 && nice -n 15 ./gradlew --max-workers=4 :core:network:testDebugUnitTest :core:data:testDebugUnitTest --tests '*NodeApiCalls*' --tests '*Group*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: NodeApi**

```kotlin
class TileBusyException : Exception("map pieces: try later")

// interface NodeApi
suspend fun tile(z: Int, x: Int, y: Int): ByteArray? = throw OldNodeException()

// RemoteNodeApi
override suspend fun tile(z: Int, x: Int, y: Int): ByteArray? = try {
    val req = TileRequest.newBuilder().setZ(z).setX(x).setY(y).build()
    TileResponse.parseFrom(rpc.call("tiles.get", req.toByteString())).data.toByteArray()
} catch (e: RpcException) {
    when {
        e.status == Status.STATUS_NOT_FOUND || e.status == Status.STATUS_UNAVAILABLE -> null
        e.status == Status.STATUS_QUOTA || e.status == Status.STATUS_RETRY_LATER -> throw TileBusyException()
        e.isUnknownMethod() -> throw OldNodeException()
        else -> throw e
    }
}
```
(Match how `directoryLookup` builds the body: `rpc.call` may take a message or `ByteString`.)
Add a test in `NodeApiCallsTest` for each status mapping using `FakeTransport` like the lookup tests.

- [ ] **Step 2: FakeNode** — `@Volatile var tileAnswer: ((Int, Int, Int) -> ByteArray?)? = null` and in `Session`: `override suspend fun tile(z: Int, x: Int, y: Int) = (tileAnswer ?: { _, _, _ -> null })(z, x, y)`.
- [ ] **Step 3: Failing group-expiry test** (`GroupExpiryTest.kt`): two `TestGraph`s in one group (copy the setup from `GroupFlowTest`); insert a group `OutboxEntity` with `expiresMs = clock.now() + 300_000` and one with `expiresMs = clock.now() - 1`; `outbox.drainOnce(api)`; assert the FakeNode stored exactly one group envelope and its `expiresMs` equals the first value (read the stored `Record` body with `RecordCodec`).
- [ ] **Step 4: Fix** — in `processGroup()` add at the top, as in `process()`: `if (item.expiresMs in 1..clock.now()) { outbox.delete(item.id); return }`; in `GroupSender.buildRecord` pass `expiresMs = item.expiresMs` to `RecordCodec.body(...)`.
- [ ] **Step 5:** Verify → `BUILD SUCCESSFUL`.
- [ ] **Step 6: Commit** `oc -m "app: NodeApi.tile; group outbox items honour expiry (M11, D140, D141)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 8: App — storage (kind LOCATION, `live_locations`, migration, backup)

**Goal:** Location messages and live-share state are stored; backups keep pins only.

**Files:**
- Modify: `core/database/.../model/MessageStatus.kt` (`MessageKind.LOCATION = 9`, or next free after M10)
- Create: `core/database/.../entity/LiveLocationEntity.kt`, `dao/LiveLocationDao.kt`
- Modify: `core/database/.../OtterDatabase.kt` (entity, dao, `version + 1`, `AutoMigration(from = N, to = N+1)`), exported schema
- Modify: `core/database/src/test/.../MigrationTest.kt`
- Modify: `core/data/.../backup/SnapshotCodec.kt`, `MessageDao` kind lists, `MessageRepository.retry`

**Acceptance Criteria:**
- [ ] Migration test N → N+1 passes and the table exists with the columns below.
- [ ] `LiveLocationDao`: `upsert`, `get(messageId)`, `observeActive(conversationId, now)`, `ownActive()`, `markStopped(messageId)`.
- [ ] Backup export keeps LOCATION messages (body + `systemData` = the `Location` bytes) with `live_period_s` reset to 0; `live_locations` is not exported.
- [ ] LOCATION counts in unread receipts and `retry` (re-sends the original content).

**Verify:** `nice -n 15 ./gradlew --max-workers=4 :core:database:testDebugUnitTest :core:data:testDebugUnitTest --tests '*Migration*' --tests '*Snapshot*' --tests '*Backup*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Entity and DAO**

```kotlin
@Entity(tableName = "live_locations", indices = [Index("conversation_id")])
data class LiveLocationEntity(
    @PrimaryKey @ColumnInfo(name = "message_id") val messageId: ByteArray, // share id = starting DataMessage id
    @ColumnInfo(name = "conversation_id") val conversationId: Long,
    @ColumnInfo(name = "sender_id") val senderId: ByteArray,
    @ColumnInfo(name = "outgoing") val outgoing: Boolean,
    @ColumnInfo(name = "lat_e7") val latE7: Int,
    @ColumnInfo(name = "lon_e7") val lonE7: Int,
    @ColumnInfo(name = "accuracy_m") val accuracyM: Int,
    @ColumnInfo(name = "heading_deg") val headingDeg: Int = 0,
    @ColumnInfo(name = "speed_cms") val speedCms: Int = 0,
    @ColumnInfo(name = "fix_ms") val fixMs: Long,
    @ColumnInfo(name = "live_until_ms") val liveUntilMs: Long, // Long.MAX_VALUE = until stopped
    @ColumnInfo(name = "stopped") val stopped: Boolean = false,
    @ColumnInfo(name = "updated_ms") val updatedMs: Long,      // receiver clock of the last accepted update
)

@Dao
interface LiveLocationDao {
    @Upsert suspend fun upsert(e: LiveLocationEntity)
    @Query("SELECT * FROM live_locations WHERE message_id = :id") suspend fun get(id: ByteArray): LiveLocationEntity?
    @Query("SELECT * FROM live_locations WHERE conversation_id = :cid AND stopped = 0 AND live_until_ms > :now")
    fun observeActive(cid: Long, now: Long): Flow<List<LiveLocationEntity>>
    @Query("SELECT * FROM live_locations WHERE outgoing = 1 AND stopped = 0") suspend fun ownActive(): List<LiveLocationEntity>
    @Query("UPDATE live_locations SET stopped = 1 WHERE message_id = :id") suspend fun markStopped(id: ByteArray)
    @Query("SELECT * FROM live_locations WHERE message_id = :id") fun observe(id: ByteArray): Flow<LiveLocationEntity?>
}
```
(`equals/hashCode` for `ByteArray` fields: follow how other entities with `ByteArray` keys are written.)

- [ ] **Step 2:** register in `OtterDatabase`, bump version, add `AutoMigration`, build once to export the schema (`:core:database:kspDebugKotlin`), commit the new JSON.
- [ ] **Step 3: Migration test** — copy the latest test in `MigrationTest.kt`: `createDatabase("m11.db", N)` → `runMigrationsAndValidate("m11.db", N+1, true)` → `query("SELECT message_id, live_until_ms, stopped FROM live_locations")` works (empty).
- [ ] **Step 4: Backup** — in `SnapshotCodec.export` keep LOCATION rows; if `systemData` parses as `Location` with `livePeriodS != 0`, write it back with `livePeriodS = 0` (a restored phone shows a plain pin). `import` accepts LOCATION. Test: export a LOCATION row with period 900 → imported row has period 0; `live_locations` empty after import.
- [ ] **Step 5:** add `MessageKind.LOCATION` to `MessageDao.unreadReceiptsPending` and `MessageRepository.retry` kinds.
- [ ] **Step 6:** Verify → `BUILD SUCCESSFUL`.
- [ ] **Step 7: Commit** `oc -m "app: LOCATION messages, live_locations table, backups keep pins only (M11, D140)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 9: App — sending pins, live starts, updates and stops

**Goal:** One `LocationSender` builds and queues every location content correctly for 1:1 and groups.

**Files:**
- Create: `core/data/.../location/LocationCodec.kt`, `UpdatePolicy.kt`, `LocationSender.kt`
- Modify: `core/data/.../messaging/MessageRepository.kt` (shared helper for a DataMessage with `location`), DI module
- Test: `core/data/src/test/.../location/LocationSenderTest.kt`, `UpdatePolicyTest.kt`

**Acceptance Criteria:**
- [ ] `sendPin(cid, fix)` / `startLive(cid, fix, periodS)`: one PENDING LOCATION message (urgent, receipts as text), `DataMessage.text` = `📍 Местоположение: 55.75580, 37.61730\ngeo:55.75580,37.61730`; `startLive` also inserts an outgoing `live_locations` row.
- [ ] `sendUpdate(shareId, fix)`: outbox item with `urgent = false`, `messageLocalId = null`, `expiresMs = now + 300_000`; 1:1 to the peer, groups via the group path; **never** creates a message row.
- [ ] `stop(shareId)`: update with `stopped = true`, `expiresMs = liveUntil` (open-ended: `now + 7 days`), marks the row stopped.
- [ ] `UpdatePolicy.shouldSend(last, fix, now)`: true if no last; false if < 30 s since last; true if moved ≥ 30 m; true if ≥ 5 min since last; else false.
- [ ] Every enqueue is followed by a send trigger (`SendTrigger.now()`, implemented in `:app` by `WakeScheduler.wakeNow()`).

**Verify:** `nice -n 15 ./gradlew --max-workers=4 :core:data:testDebugUnitTest --tests '*location*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Codec and fix type**

```kotlin
data class Fix(val latE7: Int, val lonE7: Int, val accuracyM: Int, val headingDeg: Int = 0, val speedCms: Int = 0, val fixMs: Long)

object LocationCodec {
    const val UNTIL_STOPPED: Int = -1 // uint32 4294967295 on the wire (protobuf-java uses Int)
    val PERIODS_S = listOf(900, 1800, 3600, 28800, UNTIL_STOPPED)
    fun toE7(deg: Double): Int = Math.round(deg * 1e7).toInt()
    fun deg(e7: Int): Double = e7 / 1e7
    fun fallbackText(latE7: Int, lonE7: Int): String {
        val lat = "%.5f".format(Locale.ROOT, deg(latE7)); val lon = "%.5f".format(Locale.ROOT, deg(lonE7))
        return "📍 Местоположение: $lat, $lon\ngeo:$lat,$lon"
    }
    fun liveUntil(startMs: Long, periodS: Int): Long =
        if (periodS == UNTIL_STOPPED) Long.MAX_VALUE else startMs + periodS * 1000L
    fun distanceM(a: Fix, b: Fix): Double { // haversine
        val r = 6_371_000.0
        val p1 = Math.toRadians(deg(a.latE7)); val p2 = Math.toRadians(deg(b.latE7))
        val dp = p2 - p1; val dl = Math.toRadians(deg(b.lonE7) - deg(a.lonE7))
        val h = sin(dp / 2).pow(2) + cos(p1) * cos(p2) * sin(dl / 2).pow(2)
        return 2 * r * asin(sqrt(h))
    }
}
```

- [ ] **Step 2: Policy and its test**

```kotlin
object UpdatePolicy {
    const val MIN_INTERVAL_MS = 30_000L
    const val MIN_MOVE_M = 30.0
    const val HEARTBEAT_MS = 300_000L
    const val UPDATE_TTL_MS = 300_000L
    const val STALE_MS = 900_000L // open-ended share without updates → «Нет обновлений»
    fun shouldSend(last: Fix?, lastSentMs: Long, fix: Fix, now: Long): Boolean = when {
        last == null -> true
        now - lastSentMs < MIN_INTERVAL_MS -> false
        LocationCodec.distanceM(last, fix) >= MIN_MOVE_M -> true
        else -> now - lastSentMs >= HEARTBEAT_MS
    }
}
```
```kotlin
class UpdatePolicyTest {
    private val a = Fix(557_558_000, 376_173_000, 10, fixMs = 0)
    private val far = a.copy(latE7 = a.latE7 + 5_000) // ~55 m north
    @Test fun firstFixAlwaysSends() = assertTrue(UpdatePolicy.shouldSend(null, 0, a, 0))
    @Test fun notBefore30s() = assertFalse(UpdatePolicy.shouldSend(a, 0, far, 29_999))
    @Test fun movedAfter30s() = assertTrue(UpdatePolicy.shouldSend(a, 0, far, 30_000))
    @Test fun standingStillHeartbeat() {
        assertFalse(UpdatePolicy.shouldSend(a, 0, a, 299_999)); assertTrue(UpdatePolicy.shouldSend(a, 0, a, 300_000))
    }
}
```

- [ ] **Step 3: Failing sender tests** (`LocationSenderTest.kt`, `TestGraph` 1:1 and a group, mirroring `MessagingFlowTest`/`GroupFlowTest`):

```kotlin
@Test fun liveUpdateIsNeverUrgentAndExpiresIn300s() = runBlocking {
    val (a, b) = twoContacts()                     // helper copied from MessagingFlowTest
    val cid = a.conversationWith(b)
    val share = a.location.startLive(cid, fix, 900)!!
    a.location.sendUpdate(share, fix.copy(fixMs = fix.fixMs + 40_000))
    val item = a.db.outboxDao().all().last()
    assertFalse(item.urgent)
    assertNull(item.messageLocalId)
    assertEquals(a.clock.now() + 300_000, item.expiresMs, 5)
    assertEquals(1, a.db.messageDao().all().count { it.kind == MessageKind.LOCATION })
}

@Test fun stopExpiresAtLiveEndAndMarksRow() = runBlocking { /* startLive 900 → stop → outbox item expiresMs == startMs + 900_000; liveLocationDao().get(share)!!.stopped */ }
@Test fun openEndedStopKeptSevenDays() = runBlocking { /* UNTIL_STOPPED → stop → expiresMs == now + 7d */ }
@Test fun pinCarriesFallbackText() = runBlocking { /* sendPin → decoded outbox Content.data.text startsWith "📍 Местоположение: 55.75580, 37.61730" and hasLocation */ }
@Test fun groupUpdateGoesThroughGroupPathWithExpiry() = runBlocking { /* group cid → outbox item groupId != empty, expiresMs set, urgent false */ }
@Test fun everyEnqueueTriggersSend() = runBlocking { /* FakeSendTrigger counts calls == number of enqueues */ }
```
Write each body out fully in the test file following the first test's shape.

- [ ] **Step 4: Implement** `LocationSender` (`@Singleton`, injected `OtterDatabase`, `Outbox`, `Clock`, `MessageRepository` helpers, `SendTrigger`):

```kotlin
fun interface SendTrigger { fun now() }

class LocationSender @Inject constructor(
    private val db: OtterDatabase, private val outbox: Outbox, private val messages: MessageRepository,
    private val clock: Clock, private val trigger: SendTrigger,
) {
    suspend fun sendPin(cid: Long, fix: Fix): Long? = start(cid, fix, 0)?.first
    suspend fun startLive(cid: Long, fix: Fix, periodS: Int): ByteArray? = start(cid, fix, periodS)?.second
    suspend fun sendUpdate(shareId: ByteArray, fix: Fix) = update(shareId, fix, stopped = false)
    suspend fun stop(shareId: ByteArray) = update(shareId, null, stopped = true)
    // start(): builds Location, calls messages.queueData(cid, text = LocationCodec.fallbackText(...), location = loc,
    //   kind = MessageKind.LOCATION, systemData = loc.toByteArray()) — a new internal function in MessageRepository
    //   extracted from sendText so text, photo and location share one transaction path; for periodS != 0 also
    //   upserts LiveLocationEntity(outgoing = true, liveUntilMs = LocationCodec.liveUntil(now, periodS)).
    // update(): reads the share row (outgoing only), builds Content{location_update, sent_ms = now}, inserts an
    //   OutboxEntity(urgent = false, messageLocalId = null, expiresMs = now + UPDATE_TTL_MS or the stop expiry,
    //   recipientUserId = peer | groupId = gid), outbox.kick(), trigger.now(); stop also markStopped.
}
```
Bind `SendTrigger` in `:app` (`WakeScheduler.wakeNow()`), and a no-op/counting fake in `TestGraph`.

- [ ] **Step 5:** Verify → `BUILD SUCCESSFUL`.
- [ ] **Step 6: Commit** `oc -m "app: LocationSender for pins, live starts, updates and stops; update policy (M11, D140, D142)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 10: App — receiving locations, hostile updates lose

**Goal:** Incoming pins become LOCATION messages and live updates move only the right share.

**Files:**
- Create: `core/data/.../location/LiveLocationApplier.kt`
- Modify: `core/data/.../messaging/MailboxReceiver.kt` (branch before l.120), `GroupReceiver.kt` (`place`), `MailboxReceiver.handleContent` (kind LOCATION)
- Test: `core/data/src/test/.../location/LiveLocationReceiveTest.kt`

**Acceptance Criteria:**
- [ ] A received DataMessage with `location` → `kind = LOCATION`, `systemData = location bytes`, `body` = fallback text; live (`period != 0`) → incoming `live_locations` row with `liveUntilMs = LocationCodec.liveUntil(min(sentMs, receivedMs), period)`.
- [ ] A `LocationUpdate` is applied only if the share exists, `sender == share.senderId`, (groups) the envelope's group matches and sender is a member, share not stopped, `now < liveUntilMs`, `fixMs > share.fixMs`. Otherwise dropped; always marked seen and acked; never creates a conversation or message.
- [ ] `stopped = true` from the author marks the share stopped (even after the live end).
- [ ] Hostile tests: a third contact's update for A's share does not move it; an older `fixMs` is ignored; an update after the live end is ignored; a sender with `sent_ms` far in the future does not extend the share; a 1:1 update for an unknown share creates no chat.

**Verify:** `nice -n 15 ./gradlew --max-workers=4 :core:data:testDebugUnitTest --tests '*location*' --tests '*Mailbox*' --tests '*GroupReceiver*' --tests '*GroupFlow*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Applier**

```kotlin
class LiveLocationApplier @Inject constructor(private val db: OtterDatabase, private val clock: Clock) {
    /** Returns true if the update changed the share. Callers ack the record either way. */
    suspend fun apply(sender: ByteArray, groupId: ByteArray?, u: LocationUpdate): Boolean {
        val dao = db.liveLocationDao()
        val share = dao.get(u.messageId.toByteArray()) ?: return false
        if (share.outgoing || !share.senderId.contentEquals(sender)) return false
        if (groupId != null && !groupMatches(share.conversationId, groupId)) return false
        val now = clock.now()
        if (u.stopped) { dao.markStopped(share.messageId); return true }
        if (share.stopped || now >= share.liveUntilMs || u.fixMs <= share.fixMs) return false
        dao.upsert(share.copy(latE7 = u.latE7, lonE7 = u.lonE7, accuracyM = u.accuracyM, headingDeg = u.headingDeg,
            speedCms = u.speedCms, fixMs = u.fixMs, updatedMs = now))
        return true
    }
    private suspend fun groupMatches(cid: Long, gid: ByteArray): Boolean =
        db.conversationDao().get(cid)?.groupId?.contentEquals(gid) == true // use the real accessor names
    suspend fun onStart(cid: Long, sender: ByteArray, messageId: ByteArray, loc: Location, sentMs: Long, receivedMs: Long) {
        if (loc.livePeriodS == 0) return
        val start = minOf(sentMs, receivedMs)
        db.liveLocationDao().upsert(LiveLocationEntity(messageId, cid, sender, outgoing = false, loc.latE7, loc.lonE7,
            loc.accuracyM, fixMs = start, liveUntilMs = LocationCodec.liveUntil(start, loc.livePeriodS), updatedMs = receivedMs))
    }
}
```

- [ ] **Step 2: Wire** — `MailboxReceiver` `when` (with `CALL`): `Content.BodyCase.LOCATION_UPDATE -> { if (!content.locationUpdate.hasGroup()) live.apply(sender.userId, null, content.locationUpdate); markSeen(key); acks += key; continue }`. `handleContent` DATA: `kind = when { photo != null -> PHOTO; content.data.hasLocation() -> LOCATION; else -> TEXT }`, `systemData = location bytes`, then `live.onStart(...)`. `GroupReceiver.place`: before the DATA guard, `if (content.bodyCase == LOCATION_UPDATE && content.locationUpdate.hasGroup()) { if (groups.isMember(gid, sender)) live.apply(sender, gid, content.locationUpdate); return }`; DATA with location → same kind/systemData/onStart as 1:1. Add `live: LiveLocationApplier` as a constructor parameter with the same pattern as `calls: CallInbox` (`TestGraph` wiring too).
- [ ] **Step 3: Tests** — two and three `TestGraph`s on one `FakeNode`. Example of the hostile one:

```kotlin
@Test fun strangerCannotMoveSomeoneElsesShare() = runBlocking {
    val (a, b, c) = threeContacts() // a, b, c all contacts of each other
    val share = a.location.startLive(a.conversationWith(b), fix, 900)!!
    a.sync(); b.sync()
    val forged = LocationUpdate.newBuilder().setMessageId(ByteString.copyFrom(share))
        .setLatE7(0).setLonE7(0).setFixMs(fix.fixMs + 60_000).build()
    c.sendRawContent(to = b, Content.newBuilder().setLocationUpdate(forged).setSentMs(c.clock.now()).build(), urgent = false)
    b.sync()
    val row = b.db.liveLocationDao().get(share)!!
    assertEquals(fix.latE7, row.latE7)
    assertEquals(0, b.db.conversationDao().all().count { it.peerUserId?.contentEquals(c.userId) == true })
}
```
`sendRawContent` = a small test helper around `Outbox.enqueue(recipient, content, null, urgent, expiresMs)`. Write the other four hostile cases and the group-path case (update in a group from a member who is not the author → ignored) the same way.
- [ ] **Step 4:** Verify → `BUILD SUCCESSFUL`.
- [ ] **Step 5: Commit** `oc -m "app: receive pins and live updates; only the author's newer fixes within the live window apply (M11, D140)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 11: App — position source and `LiveLocationService`

**Goal:** Sharing runs in a `location` foreground service that sends updates through the outbox and stops cleanly, with no persistent connection.

**Files:**
- Create: `core/data/.../location/PositionSource.kt` (interface), `LiveShares.kt` (orchestrator, testable)
- Create: `app/.../location/PositionSources.kt` (fused / platform), `LiveLocationService.kt`, `StopShareReceiver.kt`
- Modify: `app/src/main/AndroidManifest.xml`, `app/.../notify/Channels.kt` (`LOCATION`), `app/.../OtterApp.kt` (orphan stop), `gradle/libs.versions.toml`, `app/build.gradle.kts`
- Test: `core/data/src/test/.../location/LiveSharesTest.kt`

**Acceptance Criteria:**
- [ ] Manifest: `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `FOREGROUND_SERVICE_LOCATION`; `<service android:name=".location.LiveLocationService" android:exported="false" android:foregroundServiceType="location"/>`. No `ACCESS_BACKGROUND_LOCATION`.
- [ ] `play-services-location` is used only if `GoogleApiAvailability` says SUCCESS; otherwise `LocationManagerCompat` with GPS + network providers.
- [ ] `LiveShares`: on each fix applies `UpdatePolicy` per active own share; at each share's `liveUntilMs` sends `stop` automatically; when no own share remains, signals the service to stop.
- [ ] `stopOrphans()` on app start: every own active share is stopped (`LocationSender.stop`), because a running service can't exist in a fresh process (D142).
- [ ] The service holds **no** `SyncEngine` lease (grep test: `LiveLocationService.kt` does not contain `acquire(`).
- [ ] Notification «Вы делитесь местоположением» with action «Остановить» (stops all own shares).

**Verify:** `nice -n 15 ./gradlew --max-workers=4 :core:data:testDebugUnitTest --tests '*LiveShares*' :app:testDebugUnitTest :app:lintDebug` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Interface and orchestrator** (`core/data`):

```kotlin
interface PositionSource {
    /** Emits fixes until the flow is cancelled. Throws SecurityException without permission. */
    fun fixes(intervalMs: Long = 10_000): Flow<Fix>
    suspend fun current(): Fix?
}

@Singleton
class LiveShares @Inject constructor(
    private val db: OtterDatabase, private val sender: LocationSender, private val clock: Clock,
) {
    private val lastSent = mutableMapOf<String, Pair<Fix, Long>>() // share hex → (fix, sentMs)
    /** Called by the service for every fix. Returns false when no own share is active (service stops). */
    suspend fun onFix(fix: Fix): Boolean {
        val now = clock.now()
        val active = db.liveLocationDao().ownActive()
        for (s in active) {
            val k = s.messageId.toHex()
            if (now >= s.liveUntilMs) { sender.stop(s.messageId); lastSent.remove(k); continue }
            val last = lastSent[k]
            if (UpdatePolicy.shouldSend(last?.first, last?.second ?: 0, fix, now)) {
                sender.sendUpdate(s.messageId, fix); lastSent[k] = fix to now
            }
        }
        return db.liveLocationDao().ownActive().isNotEmpty()
    }
    suspend fun stopAll() { db.liveLocationDao().ownActive().forEach { sender.stop(it.messageId) }; lastSent.clear() }
    suspend fun stopOrphans() = stopAll()
}
```
Tests: fixes every 10 s while moving 5 m/s → updates only every ≥ 30 s; share with `liveUntil` passes → stop enqueued and `onFix` returns false; `stopOrphans` stops two shares. (Use the toHex helper that already exists in core/data, or add one.)

- [ ] **Step 2: Dependencies** — `libs.versions.toml`: `playServicesLocation = "21.3.0"` → `play-services-location = { module = "com.google.android.gms:play-services-location", version.ref = "playServicesLocation" }`; `app/build.gradle.kts`: `implementation(libs.play.services.location)`. (Pick the newest release at least two weeks old if 21.3.0 is outdated.)
- [ ] **Step 3: Position sources** (`app/.../location/PositionSources.kt`): `FusedPositionSource` (`LocationServices.getFusedLocationProviderClient`, `LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, intervalMs).setMinUpdateIntervalMillis(5_000).build()`, `callbackFlow`), `PlatformPositionSource` (`LocationManagerCompat.requestLocationUpdates(lm, provider, LocationRequestCompat.Builder(intervalMs).setQuality(LocationRequestCompat.QUALITY_HIGH_ACCURACY).build(), executor, listener)` for `GPS_PROVIDER` and `NETWORK_PROVIDER` when enabled); Hilt `@Provides fun positionSource(ctx): PositionSource = if (GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(ctx) == ConnectionResult.SUCCESS) Fused(ctx) else Platform(ctx)`. `Location` → `Fix(toE7(lat), toE7(lon), accuracy.toInt(), bearing.toInt(), (speed*100).toInt(), time)`.
- [ ] **Step 4: Service** — model on `CallService` (`@AndroidEntryPoint`, `ServiceCompat.startForeground(this, ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)`, `START_NOT_STICKY`). `onStartCommand`: start foreground, then a coroutine `positions.fixes().collect { if (!liveShares.onFix(it)) stopSelf() }`; a ticker every 60 s calls `onFix(lastFix)` so timed shares end on time even when standing still. Action `ACTION_STOP` → `liveShares.stopAll()` then `stopSelf()`. `SecurityException` → `stopAll()` and stop. Notification on `Channels.LOCATION` (importance LOW, name «Местоположение»), ongoing, content intent opens the app, action «Остановить» → `StopShareReceiver` → service `ACTION_STOP`.
- [ ] **Step 5: Orphans** — in `OtterApp.onCreate` after DI: `appScope.launch { liveShares.stopOrphans() }` (account must be loaded first: follow how other start-up jobs wait for the account).
- [ ] **Step 6:** Verify → `BUILD SUCCESSFUL`.
- [ ] **Step 7: Commit** `oc -m "app: LiveLocationService (foreground location, no lease), fused or platform positions, orphan stop (M11, D142)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 12: App — map stack and the `feature/location` module

**Goal:** A MapLibre map drawn only from `tiles.get`, with the location picker and the full-screen live map.

**Files:**
- Modify: `settings.gradle.kts` (`:feature:location`), `gradle/libs.versions.toml` (`maplibre`)
- Create: `feature/location/build.gradle.kts`, `src/main/AndroidManifest.xml`, `res/values/strings.xml`, `res/values-en/strings.xml`
- Create: `feature/location/src/main/assets/map/style.json`, `map/glyphs/...`, `map/sprites/...`, `map/LICENSES.md`
- Create: `feature/location/.../MapView.kt` (Compose wrapper), `TileBridge.kt` (fake-host interceptor), `LocationPickerScreen.kt`, `LiveMapScreen.kt`, `LocationViewModel.kt`
- Modify: `app/...` navigation (routes `location/pick/{cid}`, `location/map/{cid}`), `app/.../OtterApp.kt` (MapLibre init)
- Test: `feature/location/src/test/.../TileBridgeTest.kt`, `LocationPickerTest.kt`

**Acceptance Criteria:**
- [ ] `TileBridge` answers `https://tiles.otter.invalid/{z}/{x}/{y}.pbf` from `NodeApi.tile` (200 with bytes; 404 when `null`; 503 on `TileBusyException`/offline); any other host is refused with 403 (no request leaves the phone except through Otter).
- [ ] The style references only `asset://` glyphs and sprites and the fake tile host; `grep -R "http" feature/location/src/main/assets/map/style.json` shows only `https://tiles.otter.invalid`.
- [ ] Every map shows «© OpenStreetMap» and the coordinates as text.
- [ ] Picker: shows current position (permission asked: precise or approximate), «Отправить моё местоположение», a draggable pin («Отправить эту точку»), and «Делиться в реальном времени» with 15 мин / 30 мин / 1 ч / 8 ч / «Пока не остановлю». Starting live starts `LiveLocationService`.
- [ ] Live map: markers for every active share in the conversation (`observeActive`), own share with «Остановить», «Открыть в картах» (`geo:` intent), «Нет обновлений с HH:mm» for open-ended shares stale > 15 min.

**Verify:** `nice -n 15 ./gradlew --max-workers=4 :feature:location:testDebugUnitTest :feature:location:lintDebug :app:assembleDebug` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Dependency** — `maplibre = "11.8.0"` (use the newest 11.x release at least two weeks old), `maplibre-android = { module = "org.maplibre.gl:android-sdk", version.ref = "maplibre" }`; `feature/location` depends on it, `:core:ui`, `:core:data`.
- [ ] **Step 2: Assets** — style: start from OpenFreeMap's "liberty" style (MIT/BSD; record its licence in `map/LICENSES.md`), set `"sources": {"openmaptiles": {"type": "vector", "tiles": ["https://tiles.otter.invalid/{z}/{x}/{y}.pbf"], "maxzoom": 14, "attribution": "© OpenStreetMap"}}`, `"glyphs": "asset://map/glyphs/{fontstack}/{range}.pbf"`, `"sprite": "asset://map/sprites/liberty"`. Glyphs: only the fonts the style uses, ranges `0-255`, `256-511`, `1024-1279` (Latin, Latin Extended, Cyrillic); download once with a one-off command from the style's glyph URL and commit (Noto Sans: OFL, add to `LICENSES.md`). If the laptop has no internet, stop and tell the owner which files are needed. Keep the assets under 3 MB total.
- [ ] **Step 3: TileBridge** (OkHttp interceptor; registered once with `HttpRequestUtil.setOkHttpClient(client)` in `MapInit`):

```kotlin
class TileBridge(private val api: () -> NodeApi?) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val req = chain.request()
        if (req.url.host != HOST) return reply(req, 403, null)
        val p = req.url.pathSegments // [z, x, "y.pbf"]
        val z = p.getOrNull(0)?.toIntOrNull(); val x = p.getOrNull(1)?.toIntOrNull()
        val y = p.getOrNull(2)?.removeSuffix(".pbf")?.toIntOrNull()
        if (z == null || x == null || y == null) return reply(req, 400, null)
        val node = api() ?: return reply(req, 503, null)
        return try {
            val bytes = runBlocking { node.tile(z, x, y) }
            if (bytes == null) reply(req, 404, null) else reply(req, 200, bytes)
        } catch (e: TileBusyException) { reply(req, 503, null) } catch (e: IOException) { reply(req, 503, null) }
    }
    private fun reply(req: Request, code: Int, body: ByteArray?) = Response.Builder().request(req)
        .protocol(Protocol.HTTP_1_1).code(code).message("otter")
        .body((body ?: ByteArray(0)).toResponseBody("application/x-protobuf".toMediaType())).build()
    companion object { const val HOST = "tiles.otter.invalid" }
}
```
`api` = `OnlineApi.current()`. The OkHttp client for MapLibre gets a 50 MB `Cache` in `cacheDir/map` and the interceptor as an **application** interceptor (so the cache stores our answers). Tests: 200/404/503/403/400 with a `FakeNode.Session` via `MockWebServer`-free direct `Interceptor.Chain` fake (a tiny `RealInterceptorChain` substitute: implement `Interceptor.Chain` with `request()` only).
- [ ] **Step 4: `MapView.kt`** — `@Composable fun OtterMap(camera: LatLng, zoom: Double, markers: List<MapMarker>, onMapLongPress: ((LatLng) -> Unit)? = null, modifier)` wrapping `org.maplibre.android.maps.MapView` in `AndroidView`, forwarding lifecycle (`onStart/onResume/onPause/onStop/onDestroy` via `LocalLifecycleOwner`), `map.setStyle(Style.Builder().fromUri("asset://map/style.json"))`, attribution enabled, logo off, markers as a `SymbolLayer`/`CircleLayer` on a `GeoJsonSource` (no Google APIs). Coordinates line under the map (`55.75580, 37.61730 · ±12 м`).
- [ ] **Step 5: Screens** — `LocationPickerScreen(state, onSendCurrent, onSendPoint, onStartLive(periodS))`, `LiveMapScreen(shares, ownShareId, onStop, onOpenInMaps)`; `LocationViewModel` uses `PositionSource.current()`, `LocationSender`, `LiveLocationDao.observeActive`. Starting live: `sender.startLive(...)` then `ContextCompat.startForegroundService(ctx, Intent(ctx, LiveLocationService::class.java))` through an `app`-provided callback (feature modules cannot see `:app`; follow how calls are started from features, e.g. a `CallLauncher`-style interface bound in `:app`).
- [ ] **Step 6: Strings** (ru default / en):

| key | ru | en |
|---|---|---|
| `loc_title` | Местоположение | Location |
| `loc_send_current` | Отправить моё местоположение | Send my current location |
| `loc_send_point` | Отправить эту точку | Send this place |
| `loc_live` | Делиться в реальном времени | Share live location |
| `loc_live_15m` / `30m` / `1h` / `8h` | 15 минут / 30 минут / 1 час / 8 часов | 15 minutes / 30 minutes / 1 hour / 8 hours |
| `loc_live_until_stop` | Пока не остановлю | Until I stop |
| `loc_stop` | Остановить | Stop |
| `loc_open_maps` | Открыть в картах | Open in maps |
| `loc_no_updates` | Нет обновлений с %1$s | No updates since %1$s |
| `loc_permission` | Разрешите доступ к местоположению, чтобы отправить его | Allow location access to send it |
| `loc_accuracy` | ±%1$d м | ±%1$d m |

- [ ] **Step 7: Tests** — Robolectric: picker shows the five period choices; «Пока не остановлю» passes `LocationCodec.UNTIL_STOPPED`; live map shows «Нет обновлений с 14:05» for a share with `updatedMs` 16 min old and `liveUntilMs = Long.MAX_VALUE`. (MapLibre's native view does not render under Robolectric: put the map behind a `LocalMapRenderer` composition local with a plain `Box` in tests.)
- [ ] **Step 8:** Verify → `BUILD SUCCESSFUL`.
- [ ] **Step 9: Commit** `oc -m "app: feature/location — MapLibre map from tiles.get only, picker, live map (M11, D141, D144)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 13: App — chat integration (attach menu, bubble, strip, previews)

**Goal:** Locations appear and are sent from the chat like any other message.

**Files:**
- Modify: `feature/conversation/.../MessageComposer.kt` (attach menu), `ConversationScreen.kt` (strip, bubble dispatch, navigation callbacks), `ConversationViewModel.kt` + `MessageGrouping.kt` (`MessageUi.location`), strings ru/en
- Create: `feature/location/.../LocationBubble.kt` (snapshot picture)
- Modify: `feature/chats/.../ChatListViewModel.kt` (preview «📍 Местоположение» / «📍 Трансляция местоположения»), `app/.../notify/NotificationContent.kt` (`SHOWN` += LOCATION, text «📍 Местоположение»)
- Test: `feature/conversation/src/test/.../AttachMenuTest.kt`, `LocationBubbleTest.kt`; extend `ChatListViewModelTest`, `NotificationContentTest`

**Acceptance Criteria:**
- [ ] Composer leading button = attach (📎, `Icons.Outlined.AttachFile`), menu «Фото» (old gallery action) and «Местоположение» (opens the picker); camera in the text field unchanged.
- [ ] A LOCATION message shows `LocationBubble`: map picture (MapLibre `MapSnapshotter`, 240×140 dp, cached per message in memory), pin, `MessageMeta` (time + ticks), live line «Обновлено N мин назад · ещё M мин» / «Трансляция завершена» / «Нет обновлений с HH:mm»; offline or no tiles → card with coordinates. The fallback text is never shown for LOCATION.
- [ ] Tap → live map (`location/map/{cid}`) focused on that share.
- [ ] Own active share in this chat → strip under the top bar «Вы делитесь местоположением · Остановить».
- [ ] Chat list and notifications show «📍 Местоположение» (pin) / «📍 Трансляция местоположения» (live), never coordinates on the lock screen.

**Verify:** `nice -n 15 ./gradlew --max-workers=4 :feature:conversation:testDebugUnitTest :feature:chats:testDebugUnitTest :app:testDebugUnitTest :feature:location:testDebugUnitTest` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing UI tests**:

```kotlin
@Test fun attachMenuHasPhotoAndLocation() {
    var picked = ""
    compose.setContent { OtterTheme { MessageComposer(text = "", sending = false, onText = {}, onSend = {},
        onPickPhoto = { picked = "photo" }, onTakePhoto = {}, onPickLocation = { picked = "location" }) } }
    compose.onNodeWithContentDescription("Прикрепить").performClick()
    compose.onNodeWithText("Местоположение").performClick()
    assertEquals("location", picked)
}

@Test fun locationBubbleHidesFallbackTextAndShowsLiveLine() {
    val m = sampleMessage(kind = LOCATION, body = "📍 Местоположение: 55.75580, 37.61730\ngeo:55.75580,37.61730",
        location = LocationUi(latE7 = 557_558_000, lonE7 = 376_173_000, accuracyM = 12, live = LiveUi(updatedAgoMin = 2, leftMin = 43)))
    compose.setContent { OtterTheme { CompositionLocalProvider(LocalMapRenderer provides FakeMapRenderer) { MessageBubble(m, ...) } } }
    compose.onNodeWithText("geo:", substring = true).assertDoesNotExist()
    compose.onNodeWithText("Обновлено 2 мин назад · ещё 43 мин").assertExists()
}
```
(Use the existing test factories in `feature/conversation/src/test` for `MessageUi`; add `location: LocationUi?` to `MessageUi`.)
- [ ] **Step 2: Implement** — `MessageComposer(..., onPickLocation: () -> Unit = {})` with a `DropdownMenu`; `MessageUi.location` mapped in `ConversationViewModel` from `systemData` (`Location.parseFrom`) joined with `liveLocationDao().observe(messageId)` for live lines (recompute every 30 s with a ticker); `ConversationScreen` dispatch `m.location != null -> LocationBubble(...)` before `MessageBubble`; strip via `liveLocationDao().ownActive` filtered by conversation; preview/notification strings.
- [ ] **Step 3: Snapshot** — `LocationBubble` asks `LocalMapRenderer.current.snapshot(lat, lon, widthPx, heightPx)`; production renderer uses `MapSnapshotter(context, MapSnapshotter.Options(w, h).withStyleBuilder(Style.Builder().fromUri("asset://map/style.json")).withCameraPosition(CameraPosition.Builder().target(LatLng(lat, lon)).zoom(15.0).build()))` and draws the pin on the returned bitmap; failure → coordinates card.
- [ ] **Step 4:** Verify → `BUILD SUCCESSFUL`. Also `ContrastTest`-style check: live line text on bubble colours ≥ 4.5:1 (reuse `ratio()`).
- [ ] **Step 5: Robolectric screenshots** (owner rule): capture the bubble (pin, live, ended) and the strip in light and dark if a screenshot setup exists; if Roborazzi is not yet a dependency, **ask the owner before adding it**, otherwise skip.
- [ ] **Step 6: Commit** `oc -m "app: attach menu, location bubble, sharing strip, previews (M11, D143)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 14: Emulator acceptance, docs, versions, checks, owner test, merge, rollout

**Goal:** Two emulators share live location end to end through a dev mesh, the docs match the code, the owner tests on phones and decides the merge.

**Files:**
- Modify: `docs-m11/00-decisions.md` (D140–D144 as in "Decisions this plan adds"), `02-protocol.md` (`Location`, `LocationUpdate`, `tiles.get`, `TileRequest/Response`), `03-replication`-equivalent peer frame list (`PeerTileGet`/`PeerTile`; find the file listing `PeerTunnel*`), `07-android-architecture.md` (`feature/location`, `LiveLocationService`, MapLibre, D142), `09-roadmap.md` (M11 row: server/app 0.13.0), `10-otter-design-guidelines.md` (attach menu, location bubble, strip), `11-deployment.md` (`[tiles]`, `tiles-upstream.sh`)
- Modify: `docs-m11/superpowers/specs/2026-11-25-m11-location-sharing-design.md` (deviations: attach menu is new, D143; group expiry fix; live end uses `min(sent, received)`; tiles config is a node.toml section written only for ≥ 0.13.0; upstream on via `tiles-upstream.sh`)
- Modify: `otter-android-m11/app/build.gradle.kts` (`versionCode = 17; versionName = "0.13.0"`)
- Create: `otter-android-m11/docs/m11-manual-test.md`

**Acceptance Criteria:**
- [ ] Emulators (`m8_api34` + `m8_api30`, dev mesh of two nodes: one with an upstream stub, one without): A shares live 15 min while `adb emu geo fix` walks a route (a point every 20 s); B sees the dot move; B's node had no upstream and got pieces through the peer; A stops → B shows «Трансляция завершена»; reboot of A's emulator during a share → B sees the share stopped after A's app starts.
- [ ] Server: `nice -n 15 ionice -c3 go test -p 4 -count=1 ./...` all `ok`; `go vet ./...` clean; `scripts/secrets-check.sh` ok.
- [ ] App (after the server run): `nice -n 15 ./gradlew --max-workers=4 test lintDebug assembleDebug` → `BUILD SUCCESSFUL`; `scripts/secrets-check.sh` ok.
- [ ] Docs: `scripts/secrets-check.sh` ok.
- [ ] Owner test passed and the owner said "merge".

**Verify:** the three check commands above.

**Steps:**

- [ ] **Step 1: Emulator run** — dev mesh in a scratch dir (never `otter-server/.dev-mesh`; never the owner's account): the upstream stub is a local `httptest`-style server binary or `python3 -m http.server` over a directory of a few real-looking `.pbf` files served by HTTPS with a self-signed cert added to the dev node's trust (or run the node with a test-only env that allows `http://127.0.0.1` upstream — if you add such a switch, it must be impossible in release config and covered by a test). Record what you ran in `docs/m11-manual-test.md` with the rows for the owner's phone test (below). No builds while emulators run.
- [ ] **Step 2:** Docs edits as listed; commit in `docs-m11`: `oc -m "docs: M11 location sharing (D140–D144), versions 0.13.0" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`.
- [ ] **Step 3:** App version bump; commit `oc -m "app 0.13.0 (versionCode 17)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`.
- [ ] **Step 4:** Run the checks one after another (server first, then app, never together).
- [ ] **Step 5: Ask the owner → build** (as for 0.11.0):
```bash
cd ~/Documents/Projects/OttterMSG/otter-server-m11 && make release VERSION=0.13.0 && make build
# release APK (the build reads the owner's keystore; its storeFile is relative to the checkout):
cd ~/Documents/Projects/OttterMSG/otter-android-m11 && ln -s ../otter-android/release.jks release.jks && \
  JAVA_HOME=~/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2 nice -n 15 ./gradlew --max-workers=4 \
  -PotterKeystore=../otter-android/keystore.properties assembleRelease; rm release.jks
```
  Write the news draft `otter-server-m11/dist/news/0.13.0.md` (`## ru` / `## en`): «Местоположение» in the 📎 menu, live sharing periods, the map comes from our own servers, «Остановить» in the notification.
- [ ] **Step 6: Owner rollout order** (owner runs; never ssh yourself):
```bash
cd ~/Documents/Projects/OttterMSG/otter-server-m11
deploy/upgrade-all.sh 0.13.0 --no-news
deploy/tiles-upstream.sh eeee on        # foreign node fetches map pieces; ru-1 stays off and asks eeee
deploy/harden-check.sh && deploy/status.sh
deploy/release-apk.sh 0.13.0 ../otter-android-m11/app/build/outputs/apk/release/app-release.apk
```
- [ ] **Step 7: Ask the owner → test on two phones** (both 0.13.0):
  1. 📎 → «Местоположение» → «Отправить моё местоположение»: the other phone gets a bubble with a map and the right place.
  2. Drag the pin, «Отправить эту точку» → arrives at the dragged place.
  3. «Делиться в реальном времени» → 15 минут: notification «Вы делитесь местоположением» appears; walk ~100 m: the other phone's dot moves within about a minute while its chat is open.
  4. «Остановить» from the notification: the other phone shows «Трансляция завершена».
  5. «Пока не остановлю», then restart the sharing phone: after it starts, the other phone shows the share ended.
  6. A phone on ru-1 opens the map in a new area: pieces load (through eeee); `deploy/status.sh` shows `tiles=` counts on both nodes.
  7. Lock screen notification for a pin shows «📍 Местоположение», no coordinates.
- [ ] **Step 8: Ask the owner → merge** (through temporary worktrees, as in M9.5):
```bash
cd ~/Documents/Projects/OttterMSG
for r in otter-server otter-android docs; do
  git -C $r fetch origin && git -C $r worktree add ../$r-merge origin/main --detach
  (cd $r-merge && git merge --no-ff --no-commit m11-location && oc -m "Merge M11: location sharing (pins, live sharing, map pieces cached on nodes) (server 0.13.0, app 0.13.0)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && scripts/secrets-check.sh && git push origin HEAD:main)
  git -C $r worktree remove ../$r-merge
done
for r in otter-server otter-android docs; do git -C $r worktree remove ../$r-m11; done
```
