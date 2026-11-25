# M11 location sharing — design

Approved by the owner 2026-11-25 (brainstorm). Built **after M10 video calls**, on branches `m11-location` in each repo
touched. Versions: **app 0.13.0, server 0.13.0** (after M10's 0.12.0). New decisions start at **D140**.

## Owner decisions

1. **Map pieces come through our own nodes** (not a public tile host seen by the phones, not "no map").
2. **Coverage on request**: nothing is downloaded up front. A node fetches a map piece the first time anyone views that
   area and keeps a copy.
3. **Only foreign nodes fetch** from the public source. A node without `tiles_upstream` (ru-1) asks a peer over the
   existing node-to-node link and caches the answer. ru-1 never contacts a foreign host for map pieces.
4. **Live sharing is allowed** with a `location` foreground service and its notification while sharing is on. **No
   connection stays open** (D61 and the owner's "Firebase only, no own keep-alive" rule still hold): each update goes
   out through the normal outbox and the connection closes as usual. Watchers get updates while the chat is open, with
   **no pushes** for updates.
5. Live periods: **15 min, 30 min, 1 h, 8 h, or «Пока не остановлю»** (until stopped).
6. Built **after M10**, as M11.

## What people get

- In any chat (1:1 or group) the 📎 menu gains **«Местоположение»**. It opens a map centred on the current position:
  - **«Отправить моё местоположение»**: a one-time pin; the map can be dragged to pin another place instead.
  - **«Делиться в реальном времени»**: choose 15 min / 30 min / 1 h / 8 h / «Пока не остановлю».
- **Bubble**: a small map picture with the pin, accuracy and time. Live shares add «Обновлено 2 мин назад · ещё 43 мин»
  (open-ended shares: «Обновлено 2 мин назад»).
- **Full-screen map** on tap: everyone in this chat who is sharing live, «Открыть в картах» (`geo:` intent to any maps
  app) and, on one's own share, «Остановить».
- **Strip at the top of the chat** while sharing there: «Вы делитесь местоположением · Остановить».
- **After the end** (timer, Stop, reboot, app killed): the bubble keeps the last position with «Трансляция завершена».
- **Open-ended share with no update for 15 min** (three missed heartbeats): «Нет обновлений с 14:05»; the last
  position stays until a new update or the stop arrives.
- The coordinates are always shown as text too (bubble and full-screen map).

## Protocol (phones only; nodes see nothing new in envelopes)

`content.proto`, identical in `otter-server` and `otter-android`:

```proto
message DataMessage {
  ...
  Location location = 5;
}

message Location {
  sint32 lat_e7 = 1;          // degrees × 1e7
  sint32 lon_e7 = 2;
  uint32 accuracy_m = 3;
  uint32 live_period_s = 4;   // 0 = one-time pin; 900, 1800, 3600, 28800; 0xFFFFFFFF = until stopped
}

message Content {
  oneof body {
    ...
    LocationUpdate location_update = 7;
  }
}

message LocationUpdate {
  bytes message_id = 1;       // the DataMessage that started the share
  GroupContext group = 2;     // set in groups (SENDER_KEY envelope)
  sint32 lat_e7 = 3;
  sint32 lon_e7 = 4;
  uint32 accuracy_m = 5;
  uint32 heading_deg = 6;
  uint32 speed_cms = 7;
  int64 fix_ms = 8;           // time of the GPS fix, sender clock
  bool stopped = 9;
}
```

- **Pin or live start**: an ordinary `DataMessage` (1:1 or `SENDER_KEY` in groups), urgent, with receipts.
  `text` carries a fallback for older apps: `📍 Местоположение: 55.75580, 37.61730` plus `geo:55.75580,37.61730`;
  0.13+ apps hide this text when `location` is set.
- **Live end** = `sent_ms + live_period_s`, judged on the **receiver's** clock. `0xFFFFFFFF` has no end.
- **Updates**: `LocationUpdate`, **never urgent**, no receipts, never shown as a message, envelope expiry
  `created + 300 s`.
  - Call-push trap: D58 treats an urgent envelope with expiry ≤ 150 s as a call. Updates are never urgent, so they
    cannot match. A test enforces it.
- **Stop**: `stopped = true`, expiry = the live end (open-ended: `now + 7 days`), so offline members still learn it.
- **Receiver rules** — accept an update only if all hold, else drop and ack:
  1. the sender (account, and group sender key in groups) authored `message_id`;
  2. the share is not over (live end not passed, not stopped);
  3. `fix_ms` is newer than the stored fix.
- **Cadence**: send when moved ≥ 30 m **and** ≥ 30 s since the last update; heartbeat every 5 min when standing still.
  A fixed short interval would flood the oplog (each update is a record plus one ACK per recipient).

## Map pieces on the nodes

- **RPC `tiles.get {z, x, y}`** on the phone's usual pinned WSS session. Logged-in, non-revoked members only.
  Per-account limit, default 600 pieces/minute. `z ≤ 14`; the app overzooms for street level.
- **Cache**: on-disk, keyed `z/x/y`, size cap `tiles_cache_mb` in `node.toml` (default 2048), least-recently-used
  eviction. Pieces stored as received (gzip MVT), each ≤ 1 MiB; larger or undecodable answers are refused and not
  cached.
- **Miss**:
  - node with `tiles_upstream` (URL template, default OpenFreeMap vector tiles, no key): HTTPS fetch, store, answer.
    One fetch per piece at a time (concurrent requests wait for it); per-node upstream rate limit.
  - node without it: a new peer frame pair (`PeerTileGet` / `PeerTile`) on an existing peer session to a peer that
    advertises upstream access; store, answer. Peers answer only for authenticated peer sessions, with the same size
    and rate limits.
  - nothing reachable: an error the app shows as the coordinates card.
- **Privacy**: the public source sees the fetching node's IP and the area, never who looks. Phones talk only to their
  own node.
- **Hostile node**: may serve a wrong map picture, but cannot move a pin; coordinates come end-to-end encrypted and are
  always shown as text.
- **Ops**: `tiles_upstream` set on foreign nodes by `add-node.sh` / `upgrade.sh` defaults, empty on the domestic node;
  `status.sh` shows cache size and hit rate; firewall unchanged (outbound HTTPS only).

## Android

- **Modules**: `feature/location` (picker, full-screen map, bubble), `core/data/location`.
- **Map**: MapLibre Native (open source, no Google, no API key). Style, fonts and sprites ship in the APK. Map requests
  go to a fixed fake host that an OkHttp interceptor answers from `tiles.get`; an app-side disk cache keeps viewed
  pieces.
- **Position**: `LocationSource` interface; fused provider when Play services exist, `LocationManagerCompat` otherwise
  (D61: works without Google).
- **Live sharing**: `LiveLocationService`, `foregroundServiceType="location"`, ongoing notification
  «Вы делитесь местоположением · Остановить». No persistent connection: updates are enqueued in the outbox and sent
  by the normal send path. Timer end stops the service and sends `stopped`. After reboot or process death the share is
  **not** resumed; the app sends `stopped` on next start.
- **Permissions**: `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION` (approximate allowed: accuracy shown),
  `FOREGROUND_SERVICE_LOCATION`. No background-location permission: sharing always starts from the visible app.
- **Storage**: Room migration: `LOCATION` message type, table `live_locations` (message_id, sender, last fix,
  live_until, stopped, last_update_ms). Backups keep pins, not live state.
- **Bubble picture**: drawn on the phone with MapLibre's snapshotter from cached pieces; offline → a card with the
  coordinates. No blob is uploaded.
- Group outbox path must pass the 300 s expiry through (check `GroupSender`; add it if missing).

## Tests (each attack played by a fake sender or node, and it loses)

- Phones: an update from someone else cannot move or extend a share; an older `fix_ms` is ignored; a timed-out share
  ignores late updates; an open-ended share shows «Нет обновлений» after 15 min; restart → `stopped` sent; a
  `LocationUpdate` is never urgent and never rings; old-app fallback text present and hidden in 0.13.
- Nodes: revoked or unknown users get no pieces; per-account and upstream limits hold; an oversized or broken piece from
  upstream or a peer is refused and not cached; the cache stays under its cap; a node without upstream never dials the
  upstream host (fetches only through a peer); a peer refuses `PeerTileGet` outside an authenticated session.
- Two emulators: one shares live for 15 min on a fake route; the other sees the dot move and the share end.

## Out of scope

Searching places or addresses, routes, offline map download, sharing a location from the background without opening
the app, live location in news.
