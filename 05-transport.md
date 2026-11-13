# 05 — Transport & Censorship Resistance

## Threat recap

Active DPI: IP and SNI blocking, protocol fingerprinting (VPN/proxy/messenger protocols get
cut), throttling or cutting long connections to foreign hosting ranges, possibly
"whitelist-only" periods where only selected domestic resources are reachable. Plus ordinary
hosting outages.

## Principles

1. **Look like ordinary HTTPS.** Never invent a custom protocol on the wire.
2. **Many entry points.** Each node has several endpoints (transport × address); there are
   several nodes. The app tries them all.
3. **Changeable without app update.** Endpoints live in a **signed manifest** distributed by
   every node; the admin can rotate IPs/domains at any time.
4. **Mesh relays around blocks.** A node placed *inside* the restricted network (domestic
   hosting) can be the only thing clients reach; it relays over its own disguised link to
   nodes abroad (see [03](03-mesh-replication.md)).
5. **Pluggable.** Transports implement one interface on both sides; new ones (e.g. for calls
   in V2, or future obfuscation) are added without touching messaging code.

## Transports (V1)

### T1 — WSS (WebSocket over TLS 1.3)
* Port: one configurable rare port per node, default 27443 (D26). TLS by the node itself with a
  self-signed certificate whose SPKI pin is in the signed manifest (D27, [11](11-deployment.md)).
* The node serves a **real-looking static website** on `https://domain:port/`;
  the messenger WebSocket lives on a secret path (`/<random-32-chars>`), anything else gets the site.
* Can be placed **behind a CDN** (e.g. Cloudflare with WebSockets enabled): the client
  connects to CDN IPs, so blocking the node's IP doesn't matter; SNI is the CDN-hosted domain.
  **Postponed (D75):** with the domestic relay phones never reach a foreign IP, and Cloudflare is reportedly
  throttled in Russia; `via_cdn` stays in the manifest for later.
* Client: OkHttp on Android → TLS fingerprint identical to millions of ordinary Android apps.
* Pinning: the manifest carries the node's TLS SPKI pins (`tls_spki_pins`, several during rotation);
  the app accepts only a leaf certificate matching a pin. Endpoints without pins use normal CA validation. Behind a CDN the CDN terminates TLS, so authentication relies on the inner
  layer (signed records + node challenge) — content is E2E anyway.

### T2 — VLESS + REALITY (embedded Xray-core)
* Strongest DPI resistance currently practical: the TLS handshake is indistinguishable from a
  connection to a real large website (the "camouflage" SNI, e.g. a popular foreign site);
  unauthenticated probes are transparently forwarded to that real site, so active probing
  sees a genuine site.
* **Between nodes only (M7, D70, D72).** Phones don't speak REALITY in V1 (D75); release apps skip `REALITY`
  endpoints.
* Server (`[reality]` in `node.toml`, set up by `deploy/reality-setup.sh`): `otter-node` embeds Xray-core
  (v1.260327.0, only the features used, +5 MB) with a VLESS+REALITY inbound on **:443** whose only outbound is a
  `freedom` redirect to an internal plain-HTTP listener on `127.0.0.1:<random port>`. That listener serves the same
  mux as WSS (secret path, `<path>/peer`, site), so the peer handshake with node keys still runs inside the tunnel.
  Unauthenticated connections are forwarded to the camouflage site `dest`. Idle timeout 24 h (peer sessions can be
  quiet for long).
* Client (on the dialing node): one in-process Xray instance per REALITY endpoint (VLESS outbound, REALITY, uTLS
  `chrome`); the peer WebSocket (`ws://host:443<path>/peer`) runs over a stream from `core.Dial`, no local proxy port.
* Camouflage site: a big foreign site with TLS 1.3, HTTP/2 and handshake records ≤ 8 KB (REALITY mirrors the
  site's handshake and gives up above 8192 bytes; `www.microsoft.com` fails that, `dl.google.com` works).
  `otter-node reality-check HOST...` tests all of it, including a loopback REALITY handshake through the site; run it
  on the foreign node and on the domestic one.
* Manifest carries: address, port, the node's secret path, VLESS UUID and short id (per node, from
  `reality-setup.sh`), REALITY public key, server name, uTLS fingerprint (`chrome`).

### Node ↔ node
A node dials a peer's endpoints at `<path>/peer`: WSS on the node port (verified with the peer's **pinned**
certificate from the manifest) or REALITY on :443, then runs a mutual Ed25519 challenge with node keys
([03](03-mesh-replication.md#peer-sync-protocol)). `WS_PLAIN` peer endpoints are dialed only with
`[mesh] allow_plain = true` (development).

Topology for a censored country (M7, D70, D71):

```
phone ──WSS (node port)──▶ domestic node (dial_out_only) ──REALITY :443──▶ foreign node
                                                         └─ fallback: WSS (node port)
```

* The domestic node is `dial_out_only`: it dials every foreign node, none of them dials it. One session carries
  both directions.
* Endpoints are tried one by one in ranked order (last success within 7 days → admin `priority` → manifest order →
  failed in the last 10 min → demoted), the same rule as on the phone; first success wins and is tried first next
  time. The ranking lives in memory, so a restart starts from manifest order (WSS first).
* Every attempt and every accepted peer session goes into the node's connectivity log (below).

## Network manifest

```proto
message Manifest {
  uint64 version     = 1;  // strictly increasing
  int64  issued_ms   = 2;
  bytes  network_pub = 3;
  repeated NodeInfo nodes = 4;
  uint32 min_app_version  = 5;
  repeated bytes news_keys = 6;      // Ed25519 keys allowed to sign announcements (M6.5, D65)
}
message NodeInfo {
  bytes node_id = 1; bytes node_pub = 2; string label = 3;
  bool  push_capable = 4;            // has an FCM key and can reach Google (otter-admin node set-push, D58)
  repeated Endpoint endpoints = 5;
  bool  dial_out_only = 6;           // inside a censored network: dials peers, is never dialed (M7, D71)
}
message Endpoint {
  enum Kind { WSS = 0; REALITY = 1; WS_PLAIN = 2; }  // WS_PLAIN: development only, refused by release apps
  Kind kind = 1; string host = 2; uint32 port = 3;
  string path = 4;  repeated bytes tls_spki_pins = 5; bool via_cdn = 6;  // WSS: SHA-256 of the leaf's SPKI; 2 during rotation
  string vless_uuid = 7; bytes reality_pub = 8; repeated string short_ids = 9;
  repeated string server_names = 10; string fingerprint = 11;         // REALITY
  uint32 priority = 12;   // admin hint
}
```
Signed by the network admin key, distributed as a `MANIFEST` record. The app:
* gets the first manifest from the invite QR;
* after each login compares `hello.manifest_version` with its own and fetches a newer one
  (`manifest.get`); nodes also push a `manifest` event to every connected client when a new version
  arrives (`otter-admin manifest publish`, or replication);
* accepts only if signature valid **and** version > current;
* for 7 days after an update also tries the previous version's endpoints that are not in the new one,
  at the lowest priority (in case the new endpoints are blocked for this user but old ones still work);
* if the node it is connected to is no longer listed, reconnects to a listed one.

**TLS pinning (D27).** For `WSS` endpoints with pins the app (OkHttp `X509TrustManager`) and the
nodes (Go `tls.Config.VerifyConnection`) accept only a leaf certificate whose SPKI SHA-256 is pinned,
that is currently valid and names the host (SAN DNS or IP); the CA chain is ignored. Endpoints
without pins use normal CA validation.

## Fastest-node selection (client)

```
candidates = all (node, endpoint) pairs from the manifest (+ fallbacks, see above)
order: succeeded in the last 7 days (by RTT) → never tried / older (by admin priority, manifest order)
       → failed in the last 10 minutes
race:  start candidate[0]; every 250 ms start the next one (max 4 in parallel)
first to complete transport handshake + node hello (10 s) wins; the others are cancelled and closed
record per-candidate stats (Room): last success/failure, RTT = connect-to-hello time, failures
```
* **Login on the winner fails** (e.g. `RETRY_LATER`: the node has not received our account yet) →
  that candidate is marked failed and the **remaining candidates are raced immediately**.
* **Network change** (Wi-Fi ↔ mobile): reconnect when online, retry at once when waiting.
* **Re-probe** every 30 min while connected (in practice the foreground; a wake-up session ends within 60 s): probe the other candidates
  (transport + hello, then close) and measure the current node with `ping`.
* **Switch** if the best other candidate's RTT is < 70 % of the current one in 3 consecutive probes.
* **Failure classification** (M7, D73; same classes on the nodes): `timeout`, `refused`, `reset` (before any
  data), `reset_after_kb` (reset/EOF after ≥ 1 KB, or a connection that dies within 2 min after receiving ≥ 1 KB:
  the throttling signature), `tls`, `handshake` (no hello), `ok`. An endpoint with ≥ 3 `reset_after_kb` within 24 h
  is **demoted** for 24 h: it is tried after everything else (Room `endpoint_stats` throttle columns, per endpoint,
  not per network). Cancellations (own reconnect, app closing) don't count.
* **Wake-up path** (push or battery-saver job, M5): if the first candidate succeeded in the last 7 days and not
  failed since, it gets a 2 s head start; the others then start at the usual 250 ms stagger
  (`NodeSelector.race(headStartMs)`, `SyncEngine.startWake`). Saves battery when the usual node answers.
* Exponential backoff when nothing works (1 s → 60 s, ±20 % jitter); immediate retry on
  network change.
* Every attempt is also written to the phone's connectivity log (below).

## Connectivity log (M7, D74)

Short, merged logs of connection outcomes; a repeat of the same result and class for the same (peer/node, endpoint,
direction) updates the newest line (count, last time) instead of adding one; the newest 200 lines are kept.

* **Nodes**: SQLite `netlog` (migration 0008), peer connections only (outbound dials per endpoint, accepted
  sessions per listener `wss`/`reality`, throttled sessions, failed node handshakes); client connections are not
  logged. `otter-node netlog [--limit N] [--json]`, e.g. `2026-11-20 10:02–14:55  ru-1  reality  in  ok  ×143`;
  `deploy/status.sh` shows the last 5 lines per node.
* **Phones**: Room `net_log` (DB v7) with node, endpoint, network (Wi-Fi / mobile / other), operator name, result,
  class and RTT. Settings → «Журнал подключений» lists it (newest first); «Поделиться» sends it as plain text through
  the share sheet. Nothing is uploaded automatically (V1.x may add it).

## Keep-alive & battery

* While foregrounded: WebSocket ping every 60 s.
* Background with FCM: no connection; connect on wake-up, drain mailbox, disconnect after 10 s without an
  `envelopes` event and with nothing due in the outbox (at most 60 s per wake-up).
* Background without FCM: "battery saver" — the same drain every 15 min (WorkManager, network constraint); see
  [07](07-android-architecture.md). The "instant" mode (persistent connection with adaptive keep-alive) is **not in
  V1** (D61).

## V2 hook: calls
`Transport` interface already supports opening additional streams; calls will add a
media relay (TURN-like) path that can also run over REALITY.
