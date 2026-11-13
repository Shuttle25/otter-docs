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
* Client: OkHttp on Android → TLS fingerprint identical to millions of ordinary Android apps.
* Pinning: the manifest carries the node's TLS SPKI pins (`tls_spki_pins`, several during rotation);
  the app accepts only a leaf certificate matching a pin. Endpoints without pins use normal CA validation. Behind a CDN the CDN terminates TLS, so authentication relies on the inner
  layer (signed records + node challenge) — content is E2E anyway.

### T2 — VLESS + REALITY (embedded Xray-core)
* Strongest DPI resistance currently practical: the TLS handshake is indistinguishable from a
  connection to a real large website (the "camouflage" SNI, e.g. a popular foreign site);
  unauthenticated probes are transparently forwarded to that real site, so active probing
  sees a genuine site.
* Server: `otter-node` embeds Xray-core as a Go library with a REALITY inbound on :443 that
  forwards authenticated streams to the node's internal WebSocket handler.
* Client: **libXray** (Xray-core compiled with gomobile into an AAR) runs in-process with a
  SOCKS5 inbound on `127.0.0.1:<random port>` with a **random per-session username/password**
  (prevents other apps from using or probing it); OkHttp's WebSocket goes through that proxy.
  No `VpnService` is used.
* Manifest carries: address, port, VLESS UUID (per network), REALITY public key, short IDs,
  server name(s), uTLS fingerprint (`chrome`).

### Node ↔ node
Same port and transports as clients: a node dials a peer's endpoint at `<path>/peer` (WSS, verified
with the peer's **pinned** certificate from the manifest), then runs a mutual Ed25519 challenge with
node keys ([03](03-mesh-replication.md#peer-sync-protocol)). `WS_PLAIN` peer endpoints are dialed only
with `[mesh] allow_plain = true` (development). From M7 a domestic node can be configured to reach
foreign nodes over REALITY.

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
* **Failure classification**: connect timeout / reset after N KB / TLS alert → endpoints with
  repeated "reset after N KB" (typical throttling signature) are demoted for that network.
* **Wake-up path** (push or battery-saver job, M5): if the first candidate succeeded in the last 7 days and not
  failed since, it gets a 2 s head start; the others then start at the usual 250 ms stagger
  (`NodeSelector.race(headStartMs)`, `SyncEngine.startWake`). Saves battery when the usual node answers.
* Exponential backoff when nothing works (1 s → 60 s, ±20 % jitter); immediate retry on
  network change.
* *Not yet implemented* (M7): failure classification and demotion. The wake-up path is built (M5).

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
