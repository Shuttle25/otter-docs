# Design: M7 DPI transports (server-to-server REALITY, connectivity log)

Approved by the owner 2026-11-13 (brainstorm). Replaces the roadmap M7 row.

## Owner decisions
* **Topology for Russia.** Phones in Russia connect only to a **domestic node** (owner's existing domestic server in Russia) over the existing WSS (pinned, port 27443). Mobile whitelists in city centres may also block a domestic
  VPS; no transport fixes that, the log will show how often it happens.
* **REALITY is server-to-server only.** The domestic node reaches foreign nodes (eeee, Hetzner) over VLESS+REALITY
  on :443, with direct WSS (:27443) as a fallback when REALITY fails. Phones get **no** REALITY/libXray in M7.
* **CDN-WSS dropped** (not needed: phones never connect to a foreign IP directly; Cloudflare is reportedly throttled
  in Russia).
* **The domestic node always dials out**; foreign nodes never dial into Russia.
* **Connectivity log** on nodes and phones, short: a repeat of the same result and type updates the existing line
  (count, last time) instead of adding one. Phone log stays on the phone (view + share); automatic reporting later
  if needed.
* **Decoy site**: already built (M1, `site_dir`), no work.

## eeee port check (read-only, 2026-11-13)
80/443 free; no other service on the host uses them, so otter-node can own :443 directly — no SNI router.

## Topology
```
phone ──WSS :27443──▶ ru node (ru-1, dial_out_only) ──REALITY :443──▶ eeee
                                                      └─ fallback: WSS :27443
```

## Manifest
* `NodeInfo.dial_out_only` (bool, new field 6): other nodes never dial this node; it dials them. One replication
  session carries both directions (already true today), so nothing else changes.
  `otter-admin node set-dial-out-only --label L [--off]`. **Default off** (existing nodes, `node add`).
* `deploy/add-node.sh` asks while installing a new node: «Is LABEL inside a censored network (e.g. Russia)? It will
  dial out to the other nodes and is never dialed by them. [y/N]» (default No); `--dial-out-only` /
  `--no-dial-out-only` answer it without a prompt (non-interactive runs default to No). A yes runs
  `set-dial-out-only` before the manifest is signed, so it goes out in the same signature. Re-runs keep the stored
  value and do not ask again.
* REALITY endpoints use the existing `Endpoint` fields (kind `REALITY`, host, port, `vless_uuid`, `reality_pub`,
  `short_ids`, `server_names`, `fingerprint = "chrome"`, `priority`). Added with
  `otter-admin node add-reality --label L --host H --port 443 --pub B64 --server-name S [--short-id X]`
  (generates the VLESS UUID and a short id when not given). Removed with the existing endpoint removal.
* Release apps ignore `REALITY` endpoints (no client support), as today.

## Server: REALITY inbound (foreign node)
* `otter-node` embeds **Xray-core** as a Go library (pinned version), started in-process from a generated config;
  no separate service.
* Config:
  ```toml
  [reality]
  listen = ":443"
  private_key_file = "/etc/otter/reality.key"   # 0640 root:otter, never leaves the node
  dest = "www.microsoft.com:443"                # camouflage: real site that probes are forwarded to
  server_names = ["www.microsoft.com"]
  short_ids = ["…"]
  vless_uuid = "…"
  ```
  The section is optional; without it no REALITY listener starts.
* Authenticated VLESS streams go to an internal plain-HTTP listener on `127.0.0.1` (random port) that serves the
  same mux as WSS (secret path, `/peer`, site). REALITY already encrypts; the peer handshake (mutual Ed25519 with
  node keys) still runs inside, so a leaked VLESS UUID gives no node access.
* Unauthenticated connections are forwarded by REALITY to `dest` (probes see the real site).
* systemd unit: `AmbientCapabilities=CAP_NET_BIND_SERVICE` (to bind :443 as user `otter`).
* `otter-node reality keygen` (on the node) writes `private_key_file` and prints the public key for
  `otter-admin node add-reality`. The private key never leaves the node.
* `otter-node reality-check HOST` checks a camouflage candidate from the machine it runs on: TCP + TLS 1.3 + HTTP/2
  (ALPN h2) + certificate valid for HOST + latency. Run on eeee (REALITY forwards probes there) **and** on the
  domestic node (the censor sees this SNI); pick a host that passes on both.

## Server: dialing peers (domestic node)
* The replication dialer tries a peer's endpoints in order: last success (7 days) → admin `priority` → manifest
  order; endpoints that failed in the last 10 min go last. First success wins; the next dial starts with it again.
* `REALITY` endpoint: an in-process Xray client (VLESS + REALITY outbound, uTLS `chrome`) with a SOCKS5 inbound on
  `127.0.0.1:<random port>` and random per-process credentials; the WebSocket to `http://<internal>/<path>/peer`
  goes through it. `WSS` endpoints: as today (pinned).
* Nodes skip dialing peers with `dial_out_only`.
* **Failure classes** (shared with the phone): `timeout`, `refused`, `reset` (before any data), `reset_after_kb`
  (reset/EOF after ≥ 1 KB, typical throttling), `tls` (alert / pin mismatch), `handshake` (node handshake failed),
  `ok`. An endpoint with ≥ 3 `reset_after_kb` in 24 h is **demoted** to last place for 24 h.

## Connectivity log (nodes)
* SQLite table `netlog(id, peer_label, endpoint, direction, result, class, detail, count, first_ms, last_ms)`.
  `direction` = `out` (our dial) or `in` (accepted peer session). Client connections are **not** logged.
* Merge rule: if the newest line for the same `(peer, endpoint, direction)` has the same `result` and `class`,
  increment `count` and update `last_ms`; otherwise add a line. Keep the newest 200 lines.
* `otter-node netlog [--json]` prints it (newest first, local time, e.g.
  `eeee reality:443 out ok ×143 10:02–14:55`). `deploy/status.sh` shows the last 5 lines per node.

## Phone: connectivity log and demotion
* `NodeSelector` records every candidate attempt in Room `net_log(node_label, endpoint, network, operator, result,
  class, rtt_ms, count, first_ms, last_ms)`; `network` = wifi / mobile / other, `operator` =
  `TelephonyManager.networkOperatorName` (no permission). Same merge rule and 200-line cap.
* Failure classification with the same classes; endpoints with ≥ 3 `reset_after_kb` in 24 h are demoted for 24 h
  (fills the "not yet implemented (M7)" gap in docs/05).
* Settings → Подключение → «Журнал подключений»: list (newest first) + «Поделиться» (plain text via the share sheet).
  Nothing is sent automatically.

## Backward compatibility
* **Phones 0.6.0 ↔ nodes 0.7.0:** no client protocol change. The 0.6.0 app already skips `REALITY` endpoints
  (`core/network/Endpoints.kt`) and ignores unknown manifest fields.
* **Manifest:** records are signed over the raw body bytes, so old nodes and apps verify a manifest with the new
  `dial_out_only` field and ignore it (same as `news_keys` in M6.5). Old nodes' dialers skip `REALITY` endpoints.
* **Mixed node versions:** the `/peer` protocol is unchanged; a 0.7.0 node reaches a 0.6.0 peer over WSS. A 0.6.0 node
  ignores `dial_out_only` and would still try to dial the domestic node (harmless, but it breaks the "never dial into
  Russia" rule) → set the flag only after every node runs 0.7.0.
* **Server DB:** one additive migration (`netlog`); the 0.6.0 binary still opens the DB (it ignores unknown
  migrations/tables), so `upgrade.sh`'s binary rollback keeps working.
* **Config:** `otter-node` rejects unknown config keys, so a 0.6.0 binary will **not start** with a `[reality]`
  section. `[reality]` is added in a separate step after 0.7.0 is healthy; `upgrade.sh` gets a config backup and
  restores `node.toml` together with the binary on rollback; a manual downgrade removes `[reality]` first.
* **App DB:** Room migration 0.6 → 0.7 adds `net_log` (additive, tested with a migration test; no destructive
  fallback), so updating via the news button keeps accounts, chats and news.

## Versions and release
Server 0.7.0, app 0.7.0 (versionCode 7, release-signed). Server via `upgrade-all.sh`; app via `release-apk.sh` +
news (RU/EN draft in `dist/news/0.7.0.md`).

## Owner steps (each asked first; passphrases only in the owner's terminal)
1. Upgrade eeee to 0.7.0; `otter-node reality keygen`; `reality-check` candidates; add `[reality]`; restart; health
   check (other services untouched).
2. Install the domestic node (ru-1) with `add-node.sh` (answer **yes** to the dial-out-only question); it joins
   the manifest.
3. Manifest: `add-reality` for eeee, `manifest sign` + `publish`.
4. Verify replication via REALITY (`otter-node netlog` on both), then the fallback by temporarily blocking eeee:443
   on the domestic node's firewall (and restoring it).
5. Install app 0.7.0 on the phones through the news update.

## Testing
* Unit: netlog merge/cap (node and app), endpoint ordering + demotion, failure classification, manifest flag,
  admin commands, `reality-check` against a local TLS server.
* meshsim: two nodes with REALITY between them (camouflage `dest` = a local TLS 1.3 server) — replication works;
  a "censor" dialer hook that refuses WSS proves REALITY carries it; refusing REALITY proves the WSS fallback; a
  probe without the VLESS key gets the camouflage server's response; `dial_out_only` node is never dialed.
* Manual checklist `otter-server/docs/m7-manual-test.md` + phone rows in `otter-android/docs/m7-manual-test.md`.

## Done when
With direct WSS from the domestic node to eeee blocked, a message from a phone connected to the domestic node reaches
a phone connected to eeee and back; `otter-node netlog` on both nodes and the phone's «Журнал подключений» show what
was tried; a non-Otter probe of eeee:443 sees the camouflage site.

## Out of scope
REALITY/libXray in the app, CDN-WSS, automatic upload of phone logs, per-node decoy site variety, SNI router
(not needed on eeee), anything for whitelist-only periods.
