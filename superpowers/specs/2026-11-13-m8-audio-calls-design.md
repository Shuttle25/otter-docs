# Design: M8 1:1 audio calls (embedded TURN, WebRTC)

Approved by the owner 2026-11-13 (brainstorm). Refines the roadmap M8 row. Video is M8.5 and out of scope here.

## Owner decisions
* **Call pairs.** Most calls are Russia ↔ Russia or abroad ↔ abroad; Russia ↔ abroad only sometimes. **The border is
  ignored in M8**: a cross-border call uses whatever ICE finds; if the real-network test shows trouble, a fix (e.g.
  media between nodes over REALITY, roadmap V2) is planned then.
* **Audio stack: Google's WebRTC library** (prebuilt Android package): Opus, echo cancellation, noise suppression,
  jitter buffer, ICE, DTLS-SRTP, TURN UDP/TCP/TLS. If it disappoints it can be replaced later; nothing else in the
  design depends on it.
* **Calls live in the chat**: a call button in the 1:1 chat top bar and call lines in the chat («Исходящий звонок ·
  3:12», «Пропущенный звонок» — tap to call back). **No «Звонки» tab.**
* **«Звонки только через сервер»** (Settings, default **on**): relay candidates only, the other side never sees the
  phone's IP. Off: direct paths are tried too.
* Phones without push (battery-saver mode, D61) cannot ring; the caller is warned.

## Topology
```
RU phone ──TURN──▶ ru-1 relay ◀──TURN── RU phone            (Russia ↔ Russia)
phone abroad ──TURN──▶ eeee relay ◀──TURN── phone abroad       (abroad ↔ abroad)
RU phone ─▶ ru-1 relay ◀─ ─ ICE decides ─ ─▶ eeee relay ◀─ phone abroad   (sometimes; best effort)
```
Each phone allocates a relay **on its own current node** (the node its session is on). The two relays are "both
relays" of the roadmap row; ICE tries relay↔relay, relay↔direct and direct pairs (direct only when
«только через сервер» is off). Signaling goes through the existing mailbox/mesh, never through the relay.

Russia ↔ Russia needs the ru-1 node (M7 Task 13, owner rollout, still pending). M8 can be built before it; that
checklist row waits for it.

## Server: embedded TURN (`otter-node`)
* Pion `github.com/pion/turn/v4` (pin the version in the plan) inside `otter-node`, no new binary.
* Listeners: **UDP 3478**, **TCP 3478**, **TLS 5349** (443 is REALITY on eeee since D72). TLS uses the node's
  existing `wss.tls_cert`/`tls_key`; the phone does **not** verify it (libwebrtc `TLS_CERT_POLICY_INSECURE_NO_CHECK`):
  media is end-to-end DTLS-SRTP and a TURN login is only an HMAC token, so the certificate protects nothing extra.
* Relay address: the node's public IP (`OTTER_IP`, already in `node env` since M7). Relay ports: a fixed UDP range,
  default **49160–49200** (41 ports ≈ 40 parallel allocations), configurable.
* Config: new `[turn]` section in `node.toml` (`enabled`, `udp_listen`, `tcp_listen`, `tls_listen`,
  `relay_ip`, `relay_port_min/max`, `secret_file`, limits). `otter-node` rejects unknown keys, so **`[turn]` may only be
  written after the 0.8.0 binary is installed** (same rule as `[reality]` in M7; `upgrade.sh` handles the order and
  rolls node.toml back on failure as in M7). Missing section = TURN off, node still works.
* Secret: 32 random bytes per node, `/etc/otter/turn.secret` (0640 root:otter), created by `add-node.sh`/`upgrade.sh`
  if missing; never in bundles, the admin dir or git. Each node issues credentials **only for itself**; no shared
  secret between nodes.
* Credentials (TURN REST scheme): username `"<expiry_unix>:<hex(sha256(user_id))[0:16]>"`, password
  `base64(HMAC-SHA1(secret, username))`, lifetime **12 h**. Pion's auth handler recomputes the HMAC and rejects
  expired usernames on every authenticated request (allocate, refresh, permission, channel bind).
* Limits (config, defaults): ≤ **4 allocations per user**, ≤ **200 kbit/s** relayed per allocation (enough for Opus
  audio; M8.5 raises it for video), ≤ **40 allocations per node** (= relay port range), allocation lifetime per Pion
  default with refresh. Over a limit → TURN error 486 (Allocation Quota Reached) and a `netlog` line.
* Relay only to public addresses: deny peer addresses in loopback, private, link-local and the node's own listeners
  (no SSRF into the node's LAN).

## Server: new RPCs (session must be logged in)
* `turn.credentials{}` → `{username, password, ttl_s, urls[]}` where `urls` lists
  `turn:IP:3478?transport=udp`, `turn:IP:3478?transport=tcp`, `turns:IP:5349?transport=tcp` for **this** node only.
  Not logged in → `UNAUTHORIZED`; TURN disabled → `UNAVAILABLE` (new error code if none fits; check
  02-protocol). Revoked users: revocation arrives in M9; M9 must make this RPC refuse them.
* `push.status{user_id}` → `{has_push: bool}`: true if the node holds a current `PUSH_TOKEN` record for that user
  (records replicate, so any node can answer). Family-internal information only.
* Both documented in 02-protocol; old nodes answer an unknown RPC with their usual error, which the phone treats as
  "calls not available on this node".

## Server: logging and ops
* `netlog` (D74) gets TURN lines: login failure (bad HMAC / expired), quota reached, listener start failure. Same
  merge rule as M7 (repeat → count/last time), so it does not flood. No per-call lines on nodes (phones log calls).
* `otter-node stats` shows current allocations and relayed bytes.
* `otter-node check` validates `[turn]` and that the secret file is readable.
* Firewall step: `add-node.sh` and `upgrade.sh` print (and, where they already manage nft/ufw, apply after asking)
  «open UDP 3478, TCP 3478, TCP 5349, UDP 49160–49200»; `deploy/status.sh` shows TURN on/off per node.
* `deploy/test/scripts_test.sh` covers the new script paths (run in a scratch copy, it writes into `dist/`).

## Protocol: call signaling content
New `Content.body` case **`CallMessage call = 6`** (both copies of `content.proto`, server and android):
```
message CallMessage {
  bytes call_id = 1;              // 16 random bytes, chosen by the caller
  oneof kind {
    CallOffer offer = 2;          // sdp (with DTLS fingerprint + candidates gathered in ~2 s); restart flag for ICE restart
    CallAnswer answer = 3;        // sdp
    IceCandidates candidates = 4; // late candidates only
    CallHangup hangup = 5;        // reason: NORMAL, BUSY, DECLINED, TIMEOUT, FAILED
  }
}
```
* Sent as ordinary Signal-encrypted 1:1 envelopes. **Offer: urgent** (FCM wake). Answer, candidates, hangup: urgent
  too (the caller's phone is foreground, but a hangup must also reach a ringing phone in the background); receipts
  for them are not sent except DELIVERED for the offer.
* Envelope `expires_ms` = created + **2 min** for all call messages (the plan checks that nodes accept and purge
  short expiries; mailbox envelopes otherwise live 30 days).
* The DTLS fingerprint travels only inside the encrypted offer/answer, so a node or relay cannot man-in-the-middle the
  media and cannot decrypt it.
* An old app receiving `call` (unknown oneof case) must ignore it silently — the plan verifies how 0.7.0 handles an
  unknown `Content.body` and, if it shows an error bubble, accepts that (only old phones see it) and notes it in the
  release news.

## Phone: call flow
States: IDLE → OUTGOING (Соединение… → Звонит… after DELIVERED of the offer) / INCOMING (ringing) → CONNECTING →
ACTIVE → ENDED. One call at a time.

* **Caller:** tap call button → RECORD_AUDIO permission (first time) → `turn.credentials` (cached until 1 h before
  expiry) → PeerConnection (relay-only if the setting is on) → gather ≤ 2 s → offer → «Соединение…». DELIVERED for
  the offer → «Звонит…». No answer in **45 s** → hangup TIMEOUT, «Не отвечает».
* Before calling, `push.status`; `has_push=false` → «Собеседник может не услышать звонок — у него нет
  push-уведомлений», then the call goes ahead anyway.
* **Callee, offer arrives:**
  * offer older than 45 s, or its hangup already received → no ringing; «Пропущенный звонок» line + notification.
  * already in an Otter call, or Telecom reports another call → hangup BUSY (caller sees «Занято»).
  * otherwise ring: full-screen CallStyle notification (Accept/Decline), works locked and with the app closed.
    Accept → answer → CONNECTING → ACTIVE. Decline → hangup DECLINED («Отклонён»).
* **Glare** (both call each other): the call with the **smaller `call_id`** (bytewise) wins on both phones; the
  other is dropped silently and the winner is answered automatically.
* **ICE failure:** not connected **15 s** after the answer → hangup FAILED, «Не удалось соединиться».
* **Network change mid-call:** on ICE `disconnected`/`failed`, one ICE restart (new offer with `restart`, same
  `call_id`); audio not back in **20 s** → hangup FAILED.
* Remote hangup or local hang up → ENDED, call line written, resources released.

## Phone: Android integration
* WebRTC prebuilt package (plan picks and pins one — e.g. `io.getstream:stream-webrtc-android`; check licence,
  that it ships **16 KB-page-aligned** native libs, and the ABIs below).
* Audio: Opus mono ~24–32 kbit/s, DTX on; earpiece by default, speaker toggle, proximity wake lock (screen off at the
  ear); Bluetooth routing via Telecom.
* Jetpack **`androidx.core:core-telecom`** (self-managed `ConnectionService` underneath): audio focus, Bluetooth,
  interaction with ordinary phone calls (GSM call → BUSY / hold rules from the library). Plan checks minSdk 26 support.
* Foreground service type **`phoneCall`** during OUTGOING/ACTIVE; permissions `RECORD_AUDIO`,
  `FOREGROUND_SERVICE_PHONE_CALL`, `MANAGE_OWN_CALLS`, `USE_FULL_SCREEN_INTENT` (Android 14+: if
  `canUseFullScreenIntent()` is false, Settings shows a one-tap fix; without it the call is a heads-up notification).
* Incoming offer handling starts from the existing push/mailbox receive path (`AccountRepository.load()` first, as
  every background entry point).
* Call screen: name + initials avatar (D34 colours), state text, timer, mute, speaker, hang up. Russian and English
  strings like the rest of the app.
* Call lines: local Room rows in the chat (not sent): «Исходящий звонок · m:ss», «Входящий звонок · m:ss»,
  «Пропущенный звонок», «Отклонён», «Не отвечает», «Занято», «Не удалось соединиться». Missed call → notification
  (tap opens the chat; «Перезвонить» action).
* Settings: «Звонки только через сервер» (default on).
* Phone `net_log` (D74): one line per call — node, path (relay UDP / TCP / TLS, or direct), RTT, duration, end
  reason. Same merge rule and «Поделиться».
* Room migration v7 → v8 for call lines (and anything else the plan needs).
* APK: release builds ship **`arm64-v8a` + `armeabi-v7a`** only (drop `x86_64` from release; debug keeps it for the
  emulator). Expected release APK ≈ 70–80 MB (now 51 MB).

## Backward compatibility
* 0.7.0 nodes: no `turn.credentials` → the call button shows «Звонки недоступны: сервер не обновлён». Upgrade all
  nodes before releasing the app.
* 0.7.0 apps: see the unknown-content rule above. A 0.8.0 phone calling a 0.7.0 phone may show «Звонит…» (if the
  old app still sends DELIVERED) but never gets an answer and times out with «Не отвечает».
* Manifest: no change (TURN ports are fixed defaults; `turn.credentials` returns the URLs).

## Versions and release
Server **0.8.0**, app **0.8.0 / versionCode 8**. Owner steps (each asked first; passphrases only in the owner's
terminal): `make build` → `deploy/upgrade-all.sh 0.8.0` (writes `turn.secret`, `[turn]`, firewall step) →
`deploy/status.sh` shows TURN on → `deploy/release-apk.sh 0.8.0 <release APK>` with `dist/news/0.8.0.md` (Claude
writes the draft) → phones update via «Обновить». Release APK is release-signed (`keystore.properties` +
`release.jks`).

## Decisions to record (D76–D81, numbers final in the plan)
* D76 Calls: WebRTC (Google libwebrtc prebuilt), 1:1 audio, Opus; revises D6 (calls no longer V2).
* D77 TURN embedded in otter-node: ports, per-node secret, TURN-REST credentials 12 h, limits, no TLS verification.
* D78 Call signaling: `CallMessage` in `Content` (field 6), urgent, 2-min expiry, fingerprints only in encrypted
  SDP, glare rule.
* D79 Relay choice and privacy: each phone allocates on its own node; «Звонки только через сервер» default on.
* D80 Android calling: core-telecom, `phoneCall` FGS, full-screen CallStyle, call lines in the chat (no tab).
* D81 Timers: 45 s ring, 15 s ICE connect, one ICE restart + 20 s, 2 s gathering.

## Testing
* **Server (`make check`)**: credential HMAC/expiry/wrong-node rejection; not-logged-in → no credentials; quota (5th
  allocation refused), bandwidth cap; peer-address deny list; config validation; meshsim test with two Pion clients
  relaying through the embedded TURN over UDP, TCP and TLS; `push.status`.
* **Android (`gradle test`)**: pure-Kotlin `CallStateMachine` (no WebRTC inside) covering answer, decline, busy,
  timeout, glare, stale offer, ICE failure, ICE restart, missed-call and call-line rules; proto encode/decode;
  Room migration test v7 → v8.
* **Emulator**: two emulators call each other through the dev mesh (TURN on dev nodes), relay-only, audio both ways.
* **Manual checklist** `otter-android/docs/m8-manual-test.md` (two real phones):
  1. RU mobile (ru-1) ↔ foreign Wi-Fi (eeee), 5-min relay-only call (best effort).
  2. RU ↔ RU through ru-1; abroad ↔ abroad through eeee.
  3. UDP to the node blocked (temporary firewall rule, asked first) → call connects over TCP/TLS.
  4. Packet capture on the node shows only DTLS/SRTP.
  5. Not-logged-in phone gets no TURN credentials.
  6. Ringing with screen locked and app closed; missed-call line + notification.
  7. Bluetooth headset, speaker toggle, proximity sensor.
  8. Wi-Fi → mobile switch mid-call recovers.
  Plus a server checklist `otter-server/docs/m8-manual-test.md` (ports, stats, netlog lines).

## Done when
The roadmap M8 acceptance holds: a phone on RU mobile and a phone on foreign Wi-Fi hold a 5-min relay-only call
(best effort per owner decision), RU ↔ RU and abroad ↔ abroad calls work, the relay cannot decrypt, UDP blocked →
call works over TCP/TLS, a phone without a valid session gets no TURN credentials; docs (D76–D81, 02-protocol,
05-transport, 06-node-architecture, 07-android-architecture, 08-operations, 09-roadmap M8 notes, READMEs) updated.

## Out of scope
Video (M8.5); group calls, media over the mesh/REALITY (V2); a «Звонки» tab; ringing on phones without push
(Instant mode, V1.x); user revocation (M9 — only the hook in `turn.credentials`); call recording; multi-device.
