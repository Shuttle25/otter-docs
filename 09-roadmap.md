# 09 — Roadmap

## Repository layout (monorepo)

```
proto/        shared .proto files (single source of truth)
server/       Go: otter-node, otter-admin
android/      Kotlin app
docs/         this documentation
deploy/       systemd units, Caddy examples, docker-compose for local 3-node mesh
```

## V1 milestones

Each milestone ends with something runnable and tested.

| # | Milestone | Server | Android | Done when |
|---|-----------|--------|---------|-----------|
| M0 | Foundations | proto schemas, `records` validation, `store` + migrations, `otter-admin network init / manifest sign` | project skeleton, modules, DI, Room+SQLCipher, seed/BIP-39, Ed25519 | unit tests green; manifest signed by CLI verifies in Kotlin test — **done 2026-11-10** |
| M1 | Single node, 1:1 text | gateway over plain WSS, auth, register via invite, directory, prekeys, mailbox, ACK | onboarding (invite scan, phrase, username), libsignal 1:1, outbox, chat list, conversation | two phones chat via one node; ✓/✓✓/read — **done 2026-11-11** (see M1 notes) |
| M1.5 | Deployment + profile | `dns records`/`dns check`, `node set-ip`/`rotate-tls`/`drop-old-pins`/`env`, `probe`/`check`/`backup`, `make release`, deploy scripts + VM test ([11](11-deployment.md) §10), `directory.update`, `registered_ms`. Pinning moved to M2 | profile editing (display name, offline-first), `feature:settings` | node installed on a VPS from a bundle; app connects over pinned TLS; upgrade with rollback tested — **code done 2026-11-11, VM run passed; VPS run open** (see M1.5 notes) |
| M1.6 | Server scripts | hosts registry, add-node.sh, status.sh, upgrade-all.sh, otter-node stats, two-VM e2e | — | add a node / upgrade all / status with one command each, proven on two VMs — **done 2026-11-12** (see M1.6 notes) |
| M2 | Mesh | replication (peer sessions, cursors, no snapshots), pinned TLS, prekey ownership, janitor, `manifest publish`, meshsim tests | pinned TLS, NodeSelector race + stats, manifest updates, 24 h resend | kill any node of 3 → chat continues; partition A↔C → messages flow via B — **done 2026-11-11** (see M2 notes) |
| M3 | Groups | fan-out envelopes | sender keys, group state, group UI | group of 5 with add/remove + key rotation — **done 2026-11-11** (see M3 notes; two-phone checks open) |
| M4 | Photos | blobs (generic), chunk upload/download, peer pull/proxy, quotas | photo send (gallery/camera), preview+caption, image viewer, save to gallery, cache rules (D24) | 20 MB photo through mesh while a node is down — **done 2026-11-11** (see M4 notes; two-phone checks open) |
| M5 | Push | `PUSH_TOKEN`, FCM HTTP v1 sender, coalescing, `push_capable` rule (D58), `push-key.sh`, `node set-push` | one build (Firebase optional), FCM wake + battery-saver fallback (no Instant mode in V1), notifications with reply/read, app version | message wakes a sleeping phone in < 5 s on FCM — **done 2026-11-12** (see M5 notes; owner rows 12–17 incl. the < 5 s measurement open) |
| M6 | Backup & restore | backup meta, auth, rate limits, eager replication | password backup, restore flow, session reset | wipe phone → restore with username + password → history back, contacts can keep chatting — **done 2026-11-12** (see M6 notes; two-phone checks open) |
| M6.5 | Otter news | `ANNOUNCEMENT` record signed by a news key listed in the manifest, validation + replication, `otter-admin announce`, push to all, APK served by the nodes | read-only «Новости Выдры» chat, optional «Обновить» button (APK from the nodes, SHA-256 checked), notification | admin sends one announcement from the PC → every member's app shows it (and a notification on FCM phones) within seconds; a forged announcement is rejected — **done 2026-11-13** (see M6.5 notes; two-phone and production rows open) |
| M7 | DPI transports | embedded Xray REALITY inbound/outbound between nodes, `dial_out_only` domestic node, per-endpoint ranked dialing + demotion, connectivity log, `reality-setup.sh` (CDN-WSS postponed, D75) | failure classes + demotion on throttling, «Журнал подключений» (no REALITY in the app, D75) | with direct WSS domestic → foreign blocked, messages flow phone ↔ domestic node ↔ REALITY ↔ foreign node ↔ phone; probes see the camouflage site — **done 2026-11-13** (see M7 notes; real-network rows open) |
| M8 | 1:1 audio calls | TURN relay embedded in `otter-node` (Pion; UDP 3478 + TCP/TLS fallback), `turn.credentials` (short-lived HMAC, logged-in non-revoked members only), allocation/bandwidth limits, call results in `netlog`, firewall step in `add-node.sh`/`upgrade.sh` | WebRTC (Opus), signaling as Signal-encrypted 1:1 contents (`call_offer`/`call_answer`/`ice_candidate`/`call_hangup`, offer is urgent → FCM), DTLS fingerprints inside the encrypted offer, ICE with every path (direct, both relays, TCP), «Звонки только через сервер» (default on, hides IPs), CallStyle full-screen ringing + `phoneCall` FGS + Telecom `ConnectionService`, call screen, missed-call entries; SAVER phones can't ring (caller is told) | phone on RU mobile (domestic node) ↔ phone on foreign Wi-Fi (eeee) hold a 5-min relay-only call; the relay can't decrypt; UDP blocked → call still works over TCP/TLS; a revoked user gets no TURN credentials |
| M8.5 | 1:1 video calls | TURN bandwidth caps raised for video, per-call bitrate logging | camera on/off, front/back switch, picture-in-picture, adaptive bitrate (audio-only fallback on throttled links) | same two phones hold a 5-min video call over the relays; throttled link degrades to audio instead of dropping |
| M9 | Security & ops hardening (**discuss with the owner before planning**) | user revocation (`otter-admin user revoke/list`, `can_invite` revoke), per-user quotas + per-IP limits + disk floor, replication keep-alive ping (25 s) with `netlog`, monitoring in `status.sh` + `otter-node status` + `/metrics` (lag, backlog, disk, push errors), deployment guide | groups drop revoked members and rotate sender keys, app lock (PIN/biometric, optional `FLAG_SECURE`), network status screen + battery-optimization helper, WebSocket ping 30 s, settings polish, username-conflict rename screen (D31); optional invite-unlocked APK download (changes the M6.5 rule) | lost phone cut off by one admin command; 3-node deployment guide followed from scratch by someone else |

Recommended build order is M0→M9 (M6.5 before M7; calls M8/M8.5 before hardening M9, owner request 2026-11-13); M7 can move earlier if blocking is immediate
(the transport interface exists from M1, so only the REALITY implementation is deferred).

## V1.x (after M9)

* **Instant mode**: optional persistent connection (foreground service, adaptive keep-alive) for phones where FCM is
  late or missing; also lets SAVER phones ring for calls (P8, D61).

* Files and voice messages in the UI (protocol/node already support generic blobs; D18).
* Other services on the owner's servers (not Otter): keep them off the public internet (owner, any time).
* REALITY in the app (libXray via gomobile, SOCKS5 on `127.0.0.1` with random per-session credentials), if a
  domestic node is not enough (D75).
* CDN-fronted WSS (`via_cdn`), if phones ever need to reach a foreign node directly (D75).
* Optional upload of the phone's connectivity log to a node (today: view + share only, D74).

## V2 (later)

* Group calls; media relay between nodes over the mesh / REALITY (1:1 calls are M8/M8.5).
* Multi-device (phone + tablet/desktop): per-device keys, already addressable.
* Desktop client.
* Sealed sender (hide sender from nodes).
* Disappearing messages, typing indicators, reactions, message edit/delete-for-everyone.
* Avatars and encrypted profiles (the display name is editable since M1.5, D39).

## Resolved questions

See D13–D17 in [00](00-decisions.md): name **OtterMSG**; display names visible to nodes;
**APK** distribution; admin = owner + one shared copy of the admin key; **all messages kept**
on the phone.

## Open questions

None currently.

## M7 notes (2026-11-13)

Built: server — `NodeInfo.dial_out_only` (6) + `otter-admin node set-dial-out-only` / `node add-reality` (`node list`
shows the flags); `internal/netlog` (failure classes, `Classify`) and the merged 200-line `netlog` table (migration
0008); per-endpoint ranked dialing with demotion (`replication.MultiDialer`, `Ranker`), inbound/outbound/throttle
logging, `dial_out_only` skipping; `internal/reality` (embedded Xray-core REALITY server and client, keygen,
camouflage check); `[reality]` config, `otter-node reality keygen` / `reality-check` / `netlog`, `otter-node check`
verifies the key file; meshsim REALITY / fallback / probe / dial-out-only tests; deploy — `reality-setup.sh`,
`add-node.sh` dial-out-only question, `upgrade.sh` config rollback, netlog in `status.sh`, `CAP_NET_BIND_SERVICE` in
the unit. App — `FailureClass` + throttling demotion in `NodeSelector` / `ConnectionManager`, `NetLog` hooks, Room v7
(`net_log`, throttle columns in `endpoint_stats`, migration 6 → 7), Settings → «Журнал подключений» with
«Поделиться», 0.7.0 / versionCode 7. Decisions D70–D75 (D26 revised for REALITY). Plan:
`docs/superpowers/plans/2026-11-13-m7-dpi-transports.md`; spec:
`docs/superpowers/specs/2026-11-13-m7-dpi-transports-design.md`. Checklists: `otter-server/docs/m7-manual-test.md`,
`otter-android/docs/m7-manual-test.md`.
Commits: server `7587991`, `dada893`, `b90ec17`, `e49f19b`, `f44b3f3`, `a3ef6d1`, `4e68ec8`, `44b7a40`, `ecd3858`
(fixes from the local run), `0f1322b` (checklists), `6fb5022` (race fix from the final check); android `a957374`, `caca10a`, `7b14110`, `61d4a76` (checklist).

Versions: `github.com/xtls/xray-core v1.260327.0` (Xray 26.3.27); it requires `golang.org/x/oauth2` 0.30 → **0.34.0**
and `cloud.google.com/go/compute/metadata` 0.3 → 0.9. `otter-node` (`-s -w`): amd64 14.3 → **19.6 MB** (19 558 562
bytes), arm64 **18.2 MB** (18 219 170 bytes, +4.8 MB); the plan expected +20–30 MB. 564 app tests green.

Local run (2026-11-13, development PC, throwaway two-node network `fi` + `ru`): `ru` (dial-out-only) could not reach
`fi` over ws (manifest port closed), replicated over REALITY; a curl probe of the REALITY port saw the camouflage
certificate (`CN=*.google.com`); stats equal on both nodes. Emulator: 0.6.0 → 0.7.0 by `adb install -r` kept account
and chats; «Журнал подключений» and «Поделиться» work; switching to `fi` logged the refused `ru` attempt.

Deviations / findings:
- **Xray without its JSON loader:** `core.Config` is built as protobuf with only dispatcher, proxyman, policy, VLESS
  in/out, freedom, TCP and REALITY (no `infra/conf`, no `distro/all`) → +5 MB instead of +20–30 MB. Xray logs go to
  slog at warn/error only. `serverConfig` validates every field.
- **Idle timeout 24 h** instead of Xray's 300 s: peer sessions have no keep-alive and would be cut.
- **REALITY client:** `core.Dial` with `context.WithoutCancel` (core.Dial ties the tunnel to the context; the dial
  timeout's cancel would kill established links); no SOCKS5 inbound as the spec described. One Xray instance per
  endpoint config for the process lifetime. The first REALITY connection after start may wait ≤ 5 s (the reality
  library probes `dest` once). Two concurrent REALITY dials at `ru` start, dedup kept one (cosmetic).
- **Camouflage limit:** `www.microsoft.com` passed the TLS 1.3 / h2 / certificate checks but REALITY cannot mirror it
  (8273-byte Certificate record > xtls/reality's 8192 limit → "handshake did not complete"). `reality-check` now runs
  a loopback REALITY handshake through the site (`ecd3858`); examples in scripts and docs use `dl.google.com`.
- Xray's `core.New` writes `transport/internet` package globals; the node creates its REALITY server and client
  instances concurrently → data race (final `make check`). Instance creation is serialized by a package mutex (`6fb5022`).
- `nodecheck`: a REALITY endpoint shares the WSS secret path, so the endpoint check matched it and failed on pins;
  REALITY endpoints are now skipped there, and the check verifies the key file against the manifest's public key.
- `add-reality` refused `--plain` dev nodes (path only from WSS); now also from `WS_PLAIN` (`44b7a40`).
- Ranking/logging: netlog trimmed by `last_ms DESC, id DESC` (merging lines survive); a cancelled context
  (shutdown) is neither logged nor ranked; inbound handshake failures are logged by host without port (so they
  merge); a node-handshake failure after a successful dial is logged, not ranked down; an outbound session dropped
  < 2 min after ≥ 1 KB counts as `reset_after_kb`. Server ranking is in memory (restart = fresh).
- Fixed on the way: the flaky `TestRetryLaterDoesNotLoseRecords` (race in the test harness gates) and a real data race
  between the session cursor and `Status()` (`setCursor`).
- meshsim: the censor acts only after the first ru → fi session (else a race); the fallback test first teaches the
  ranking REALITY, then flips (WSS is first in the endpoint list).
- Deploy: `otter-admin node env` prints `OTTER_IP`; `reality-setup.sh` validates `--dest`/`--port`, cleans up with a
  trap, sends `health.sh` output to stderr, uses `grep >/dev/null` instead of `-q` (SIGPIPE under pipefail), runs
  `ufw allow` when ufw is active and reminds about the cloud firewall. `status.sh` uses one SSH call per node.
  Re-running `push.sh` / `add-node.sh` writes `node.toml` without `[reality]` → `reality-setup.sh --force` (key kept).
- App: `core:network` stays plain Kotlin; `ConnectionManager` ignores `CancellationException` closes (its own
  reconnect is not throttling), throttle window 2 min; the throttle window restarts when the count is 0; network type
  from `core.data.network.CurrentNetwork`; Room columns snake_case, schema `7.json` + `migrate6To7` test; demotion is
  per endpoint, not per network; icon `AutoMirrored.ListAlt`.

Open:
- Real-network rows (server checklist and phone rows 10–14): eeee with REALITY on :443 (other services untouched), the
  domestic node installed as dial-out-only, REALITY carrying replication with direct WSS blocked, a day on MTS /
  Beeline mobile, both phones on 0.7.0 via the news update. The VM e2e was not run for M7.
- News across the 0.6.0 → 0.7.0 update not checked on the emulator (no news key on the local network); check on the
  phones.
- Two concurrent REALITY dials at start (cosmetic, see above).
- The old `TestGraph` coroutine leak in the Android tests makes `runTest` flaky (`RoomNetLogTest` uses
  `runBlocking`); not fixed.
- No admin command to remove a REALITY endpoint (`add-reality` can only replace it).

## M6.5 notes (2026-11-13)

Built: server — records `ANNOUNCEMENT` (15) / `ANNOUNCEMENT_DELETED` (16) with validation against `Manifest.news_keys`
(6), store with `news_deleted` and revocation (`DropNewsExcept`), `news.publish` / `news.list` / event `news`, news push
under the D58 duty rule, APK store + `apk.get` + `otter-node apk import`; admin — `news init|show|revoke` (keyring,
go-keyring v0.2.6), `announce` (to every node, `--list`, `--delete`), manifest news keys; deploy —
`release-apk.sh`, `news-dialog.sh`, `upgrade-all.sh --no-news`; meshsim news tests. App — `AnnouncementVerifier`,
`NewsRepository` (news as `NEWS` messages, DB stays v6), news chat UI with link confirmation, channel «Новости»,
`ApkUpdater`/`ApkInstaller`, release signing via `keystore.properties`, 0.6.0 / versionCode 6. Decisions D64–D69.
Plan: `docs/superpowers/plans/2026-11-12-m6-5-otter-news.md`; spec:
`docs/superpowers/specs/2026-11-12-m6-5-otter-news-design.md`. Checklist: `otter-android/docs/m6.5-manual-test.md`.
Commits: server `508bb2e`, `af622a6`, `166dae0`, `07d704b`, `493ab6e`, `6eff863`, `c7e3218`, `f8751d1`; android
`ba8748a`, `4399a4c`, `f1b88fe`, `9326ce1` (build fix), `2329855`, `bcf10ea`, `2cccbff`, `6160bfb`, `6918f8c` (fixes
from the emulator run), `9fac69b` (checklist).

Emulator run (2026-11-13, `Medium_Phone_API_35`, dev mesh): rows 1, 2, 4–10 pass; 3 (FCM timing) and 11 (TalkBack walk)
need real phones. Update flow: corrupt APK on the nodes → «Файл повреждён» and the file deleted; correct APK → installer
→ 0.6.1 (7) with account and news kept. Battery-saver build got the notification after 12 min 25 s.

Deviations / findings:
- An announcement is named by the hex of its 16-byte record id (the plan's author‖id prefix is the same for every
  announcement of one key). Records no node accepted are not kept in the admin dir; deletions are saved as
  `news/<target>.del` and listed as [deleted]. `announce` validates locally before signing.
- `Store.Apply` returns true for an announcement already deleted (removed at once), so the push decision checks that
  the announcement is still visible. Fixed a data race in `Store.DropNewsExcept` (count captured after ctx cancel →
  atomic); the janitor and `TakePrekeys` use the same capture pattern and are worth a look.
- `otter-node apk import` does not open the DB (as root next to a running node it would leave root-owned -wal/-shm).
- `news-dialog.sh`: Latin `p` also skips, EOF cancels, edits are saved back to the draft, `--apk` requires
  `--version-code`; a failed or cancelled dialog does not fail the release. `release-apk.sh` checks every SSH target
  first and prints the dialog command when run without a terminal.
- Build: the owner's `google-services.json` has no `app.ottermsg.staging` client; variants whose applicationId is not
  in it now build without google-services and with `FIREBASE = false` (`9326ce1`).
- App: the APK FileProvider is a subclass `ApkFileProvider` (the manifest merger would clash with the photos provider),
  authority `${applicationId}.files`, cache path `apk/`. News notifications use their own query (newest unread NEWS
  within 3 days). Strings are duplicated per module. Release builds without `keystore.properties` are debug-signed.
- Emulator fixes: the news chat is dated by its newest announcement, not by arrival (a later member saw it on top);
  it is hidden while empty; its notification is cleared on delete/revoke.
- Dev mesh: `manifest publish` and `announce` need `--allow-plain` (plain `ws://`).
- Open: the downloaded APK stays in the app cache until the next update replaces it or Android clears the cache.
- Exported WebP assets total ~580 KB (over the 400 KB note already before the news avatar).

Production (Task 14, 2026-11-13, done by the owner): release keystore (`CN=Otter`), eeee 0.5.0 → 0.6.0 (all checks
PASS, push on), real news key + manifest v3, both phones moved to release signing via backup/restore, first
announcement `c9c08920d257` with the 0.6.0 APK on eeee. A message sent to a phone while its app was uninstalled is
lost («Could not read the message…», D53) — expected. Open: FCM timing of a news push, TalkBack walk (rows 3, 11).

## M1 notes (2026-11-11)

Verified: server `make check` green; Android `assembleDebug assembleRelease test` green (136 test runs);
`LiveNodeTest` green against `scripts/dev-node.sh`; manual checklist (`otter-android/docs/m1-manual-test.md`)
passed on two real phones (phone A, phone B) through one dev node: steps 1–13 pass, 14 (TalkBack) not tested.
APK: release (R8, unsigned) 46 MB, debug 66 MB.

Deviations from the M1 plan:
- Client subscribes to node events before `auth.login` (the node pushes queued envelopes right after login).
- `ConnectionManager.onConnected` runs with a per-connection session scope; `NodeApi` exposes the hello node id.
- Receipts only advance messages in the receipt sender's conversation.
- libsignal 0.106.2: `SessionBuilder(store, remote, local)` but `SessionCipher(store, local, remote)`; core library desugaring required.
- `invite.proto` / `prekeys.proto` set `java_outer_classname` (Java codegen name clashes).
- Build: Gradle must run on JDK 21 (system default JDK 25 is unsupported by Gradle 8.14); Ubuntu's OpenJDK 21.0.13 C2 JIT
  crashed during R8 — `gradle.properties` excludes the method and disables core dumps; Temurin 21 is the proven daemon JVM.

Open issues for M2 (all resolved in M2):
- ~~Replicated records must apply leniently~~ → merge rules in [03](03-mesh-replication.md#merge-rules-for-replicated-records).
- ~~`dev-node.sh` without `--keep` replaces the network~~ → reuse is the default; `--reset` asks for confirmation.
- ~~`RpcClient` event buffer can back-pressure the reader~~ → unlimited event channel, single collector.
- Debug APK above the 60 MB target (unminified dex, material-icons-extended).
- TalkBack pass of the M1 screens still to do.

## M2 notes (2026-11-11)

Verified: server `make check` green (16 packages, incl. `meshsim` scenarios 1–8 and replication tests, repeated runs
under `-race`); Android `./gradlew test assembleDebug` green; `LiveMeshTest` green twice against `scripts/dev-mesh.sh`
(the node the client uses is stopped; the client fails over within 15 s; the conversation reaches READ).
Manual checklist (`otter-android/docs/m2-manual-test.md`) on two real phones (phone A, phone B) against a
3-node `dev-mesh.sh`: steps 1–6 and 9 pass (failover of one phone, of both phones at once, the phones on different nodes,
full outage with messages kept PENDING and sent once afterwards) and step 8 (Wi-Fi switch). Steps 7 (manifest removing a
node) and 10 (force-stop) not tested manually; 7 is covered by `meshsim`/`SyncEngineManifestTest` only.
Found on the device and fixed: missing `ACCESS_NETWORK_STATE` permission crashed the app at start (Robolectric does not
enforce permissions).

Deviations from the M2 plan:
- Replication receiver skips only invalid records; any other apply error (retry-later or transient) ends the session
  without advancing the cursor (the plan skipped all non-retry errors, which could lose records).
- The created_ms retention guard applies to replicated records only.
- `NodeSelector.race`: a hello timeout counts as a failure (the plan's version hung the race); losers that connected just
  before cancellation are closed.
- Manifest fallback endpoints are kept for 7 days counted from when the **new** manifest arrived.
- A failed 24 h resend is not retried again (one attempt), so the outbox worker cannot spin.
- Data race fixed in `Store.Expire` (stats read after a cancelled write); `Replicator.ctx` is mutex-guarded.
- Gateway registers every connection at connect time so manifest events reach clients that have not logged in.

Open issues for M3+:
- Endpoint failure classification/demotion and the FCM wake-up path (docs/05) — M5/M7.
- Username conflicts (`name#xxxx`) have no UI yet — M9.
- ~~`PREKEY_CONSUMED` from a node not in the receiver's manifest version stalls that peer session~~ → skipped (M3).
- Debug APK above 60 MB (unchanged from M1).
- ~~Returning to the app during a reconnect backoff waits out the rest of the pause~~ → `ForegroundSync` retries at once (M3).
- ~~Instrumented smoke test on a device/emulator~~ → `SmokeTest` (M3).

## M3 notes (2026-11-11)

Verified: server `make check` green (16 packages under `-race`, incl. the SENDER_KEY validator cases, the skipped
unknown-node `PREKEY_CONSUMED`, gateway fan-out to 4 recipients and `meshsim` scenario 9). Android `./gradlew test
assembleDebug assembleRelease` green (221 tests; skipped: the live tests); `GroupFlowTest` (5 clients, real libsignal,
the plan's 8 scenarios) repeated 3× without failure; `LiveGroupTest` green against `dev-mesh.sh` (one client per node:
messages from each, READ aggregates, removal → the removed member cannot decrypt, the others keep chatting);
`SmokeTest` green on the AVD; `scripts/export-assets.py --check` green.
On the emulator (`Medium_Phone_API_35`) with two scripted members: welcome/no-chats art (light/dark, 200 % text), family
group creation, author names per series, aggregate statuses, menu above own/incoming bubbles, message info "2 of 2",
promote/remove/leave (last-admin hand-over), read-only state, coloured initials; the same group flow on the `staging`
(R8) build. Results per step in `otter-android/docs/m3-manual-test.md`; the steps needing two real phones are open.
APK: release (R8, unsigned) 48.96 MB, debug 69.5 MB; the design assets account for ≈ 0.63 MB.

How to run the instrumented smoke test: start the emulator (`~/Android/Sdk/emulator/emulator -avd Medium_Phone_API_35`),
uninstall any previous build (`adb uninstall app.ottermsg`), then
`JAVA_HOME=~/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2 ./gradlew :app:connectedDebugAndroidTest`.
A fresh bootstrap invite for an existing dev mesh (for `LiveGroupTest`/`LiveMeshTest`) without `--reset`:
`OTTER_ADMIN_PASSPHRASE=dev-only-passphrase bin/otter-admin --dir .dev-mesh/admin invite bootstrap`, then
`bin/otter-node import --config .dev-mesh/a.toml <the printed Record file>`; the `otter://join/…` line is the invite.

Deviations from the M3 plan:
- `GroupRules`: with no local state, a version > 1 signed by an admin **of that state** is accepted (trust on first use)
  — members added later never receive version 1, so parking would lock them out. Version 1 not signed by its creator is
  rejected (it can never become valid). Recorded in D36.
- Group messages whose sender is not (yet) a member in our state are parked and retried after the next accepted state
  instead of dropped (dropped only when we are no longer a member); they are kept decrypted, because a sender key
  decrypts each message once (`pending_group_envelopes.decrypted`, `sent_ms`). Unplaceable entries after 7 days become an
  "undecryptable" event in the group's chat (by group id; else the only group containing the sender; else the direct chat).
- Sender-key distributions are outbox rows sent right before the group message in the same pass; a failing one keeps its
  own backoff and that member parks the message until the key arrives (the group is not blocked). A permanently failing
  one forgets the share so the next message queues it again.
- Receipts never create a direct chat (group members send receipts 1:1). READ receipts go one per author.
- Tasks 7 and 8 landed as one commit (they share `MailboxReceiver`/`Outbox`). `NewGroup` lives in `feature:groups`
  (shares the member picker; no feature→feature dependency). `GroupStore` also exposes contacts and the own id/name
  so the group ViewModels test against one fake. `core:ui` depends on `core:proto` to render `GroupEvent`s.
- Event texts use the "(а)" verb form and undeclined names (the actor's gender is unknown).
- The chat list's empty state waits for the first directory sync, or shows when the app cannot sync (offline/waiting),
  so it never stays blank. The "Написать" FAB is hidden while the empty state shows its own button.
- The four WebP drawables total 559 KB (plan expected < 400 KB); lossless 880 px kept (APK growth stays < 1 MB).
- Found in Task 13: the release build crashed when onboarding started — `Bip39` loaded its word list by a path relative
  to the class, which R8 repackages (latent since M1: the release APK had never been run). Fixed with an absolute path.
  New build type **`staging`** (release + R8, debug-signed, `app.ottermsg.staging`, plaintext allowed) to run R8 builds
  against dev meshes; the group flow was run on it.
- `dev-mesh.sh` on a LAN IP cannot be reached from the emulator (host firewall drops the emulator's TCP to the LAN IP);
  emulator runs used a mesh advertised as `127.0.0.1` plus `adb reverse tcp:<port> tcp:<port>`.

Open issues for M4+:
- Two-phone run 2026-11-11: rename, statuses/Сведения, add, remove, offline catch-up passed. Found: when the network
  came back while a connect attempt was in flight, the app ignored the change and waited out its backoff (≤ 72 s) —
  fixed (`ConnectionManager.networkChanged`: always re-race, backoff reset); retest Wi-Fi off/on with the app open.
- Still unchecked on phones (`m3-manual-test.md` rows 8, 19–21): menu at the top edge, splash, empty conversation art,
  TalkBack; themed launcher icon on a launcher with themed icons on.
- ~~The "Написать" FAB uses Material's default `primaryContainer` (lavender)~~ — fixed in M1.5 (outgoing-bubble pair).
- Group state is not part of any backup yet (M6); a restored phone will need the groups re-sent by an admin.
- Debug APK still above 60 MB.

## M1.5 notes (2026-11-11)

Built: `make release` (static, version-stamped, `SHA256SUMS`); `otter-node probe|check|backup`; `otter-admin dns
records|check`, `node set-ip|rotate-tls|drop-old-pins|env`, `version`; `deploy/` (`make-bundle.sh`, `push.sh`,
`upgrade.sh`, `check.sh`, bundle `install.sh`/`uninstall.sh`/`backup.sh`/`health.sh`, templates, `README.md`);
`directory.update` + `DirectoryEntry.registered_ms` (D39–D43); Android profile editing (`ProfileRepository`,
`feature:settings` with Settings/Profile/Edit name); the FAB colour fix.

Verified: server `make check` green; `deploy/test/bundle_test.sh` ok; **`deploy/test/e2e.sh` passed against a Debian 12
VM** (install, idempotent reinstall, upgrade 0.0.1→0.0.2, broken binary → exit 2 and still 0.0.2, checks all PASS,
daily backup, uninstall keeps data, reinstall over kept data, purge). Android `LiveNodeTest` and `LiveProfileTest`
passed against the VM over pinned TLS (IP-literal host). Android `./gradlew test` green (102 debug unit tests incl.
`ProfileTest` ×5, settings VM/Compose tests); `assembleRelease assembleStaging` under R8 without new keep rules;
SmokeTest green. Emulator (staging build, scratch mesh): rename online reached a scripted member; rename with all
nodes down showed the pending note, published ~12 s after they came back; 200 % font / 320 dp / dark fit.

Deviations / findings:
- `otter-node check` prints 5 lines: config, node key, manifest, **endpoint**, TLS pin (the plan's code had 4).
- `make-bundle.sh` checks the manifest by the bundle certificate's pin only (unique per node, so it also proves the
  node is listed); there is no separate node-id grep.
- `install.sh` imports invites through a copy in `/var/lib/otter` (the `otter` user can't read the root-only bundle
  directory) — found by the VM run.
- VM seed: cloud-init 22.4 fell back to `DataSourceNone` with the SMBIOS/HTTP NoCloud seed (sshd without host keys);
  `vm.sh` uses a vfat `CIDATA` disk instead (no seed HTTP server, no port 8099).
- A member who lost a replicated username clash (`name#hex`) can still publish profile updates: the store ranks such
  a local update like a replicated one instead of `ErrUsernameTaken`; `store.User.UsernameConflict` added.
- `DirectorySync` adopts the own entry's name only if its version is ≥ the local `entryVersion` (never an older one).
- Edit name: the cursor starts at the end (found on the emulator).
- SmokeTest fails with "No compose hierarchies" when the emulator screen is off: `adb shell svc power stayon true`.

Open issues:
- **VPS run** (Task 11): the owner deploys it from `otter-server/deploy/FIRST-DEPLOY.md` (new network, own
  domain, chosen later); results go into `m1.5-manual-test.md` rows 15–18. Until then the VM run stands in.
- Two-phone checks of `m1.5-manual-test.md` rows 10–13 (rename seen in groups, airplane mode, TalkBack, FAB with chats).
- ~~The M2 dev mesh still runs the M3 build~~ — restarted on the M4 build (which includes M1.5) on 2026-11-11.

## M1.6 notes (2026-11-12)

Built: `~/.otter-admin/hosts` (`label target [port]`, 0600) managed by `deploy/hosts.sh set|get|list|rm`;
`deploy/add-node.sh`, `deploy/status.sh`, `deploy/upgrade-all.sh`; `otter-node stats --config F`; tests
`deploy/test/scripts_test.sh` (offline), `deploy/test/e2e-mesh.sh` (two VMs), `make deploy-test`; `vm.sh` named
instances. Decision D49. Plan: `docs/superpowers/plans/2026-11-12-m1-6-server-scripts.md`; spec:
`docs/superpowers/specs/2026-11-12-ops-scripts-and-backup-design.md`. Procedure: [11](11-deployment.md) §11.

Deviations from the plan:
- `add-node.sh` gained `--version V` (tests must not bundle the owner's real release in `dist/`) and signs whenever
  the signed manifest lacks the node's pin, so a re-run after a failed sign works.
- A failure prints a one-line "re-run the same command" hint.
- `upgrade-all.sh` refuses unknown `--only` labels.
- The e2e-mesh bridge runs `apt-get update` before installing nftables.
- The replication check in e2e-mesh compares record counts: b starts with only the manifest from its bundle, so
  reaching a's 3 records means it pulled from a. A stronger check that writes user data on a is left for later.

## M4 notes (2026-11-11)

Built: server — `BLOB_META`/`BLOB_FETCHED` records with validation (D44), blob tables + chunk files + fetch-based
deletion with tombstones (D45), `blob.create|put|get|ack` with chunk verification and quotas (`[limits]`,
`[replication]`), peer chunk frames, background puller and on-demand proxy. App — `BlobCipher` (Tink streaming,
D46), DB v5 (`attachments`, held outbox rows, photo settings), `PhotoPrep` (D47), `MediaTransfers`, receive/download/ack,
composer gallery + camera, preview with caption, photo bubbles with honest states, viewer with zoom, save to gallery,
Settings → «Фото и память», chat-list «Фото» previews.

Verified: server `make check` green incl. meshsim: **20 MiB through the mesh with the upload node down** (acceptance),
proxy, not-yet-replicated → `RETRY_LATER`, partition A↔C via B, garbage chunks from a peer rejected. Android
`./gradlew test` green (incl. `PhotoFlowTest` ×9: send/download/decrypt/ack, offline upload before envelope, quota +
retry, manual policy and GONE, Wi-Fi-only, group of 3 with one blob, restart mid-upload, delete, unreadable source);
release/staging under R8 without new keep rules; SmokeTest green. Real processes: dev mesh restarted on the M4 build;
`LiveNodeTest`, `LiveGroupTest`, `LiveBlobTest` (20 MiB, clients on nodes a and c, 8.6 s) green; with node b killed
`LiveBlobTest` passed (8.4 s) and b, restarted, holds no rows or files for the blob. Emulator (staging): gallery and
camera photos to a scripted member, viewer zoom, save (Pictures/Otter, 1920×2560, no EXIF/GPS), camera denied dialog,
manual policy, clear cache keeps photos, offline send → delivered after reconnect (`m4-manual-test.md`).

Deviations / findings:
- Puller retry for a blob no peer has yet: 1 s doubling to 30 s (plan: a flat 30 s) — the meta replicates before the
  upload finishes, so a flat 30 s delayed every first pull.
- A node that was down while a blob lived and died gets only the `BLOB_FETCHED` (the meta record is deleted
  everywhere): no rows, no files, no tombstone; its fetch rows delete a late meta on arrival.
- `PhotoLoader` returns `android.graphics.Bitmap` (plan: `ImageBitmap`) so `core:data` has no Compose; the UI converts.
- `InputStream.readNBytes` needs API 33; `BlobCipher` reads chunks with its own loop (minSdk 26).
- Text messages: «Удалить у меня» still leaves their outbox row (as before); a photo still uploading also drops its held
  envelope. Receivers accept thumbnails up to 16 KiB (senders produce ≤ 4 KiB).
- `MessageRepository.queuePhoto`/`sendEncryptedFile` split out of `sendPhoto` (`LiveBlobTest` queues a raw 20 MiB file).
- `PhotoStore` also imports picked images and hands out camera files, so the ViewModel needs no Context.
- SmokeTest checks the merged camera FileProvider and the CAMERA permission (a fresh install shows onboarding, so the
  composer can't be reached).
- Found on the emulator and fixed: the preview showed the raw orientation; the preview overlay let touches and TalkBack
  reach the chat behind it (now a full-screen dialog); caption time left-aligned; tonal buttons in Material lavender;
  a duplicate «Фото и память» label in Settings (section now «Медиа»).
- Gradle treats a test task whose only change is environment variables as up to date: live re-runs need `--rerun`.
- A full `make check` once failed in meshsim while the emulator was also running (details lost; not reproduced in 9
  later runs); the multi-MiB blob scenarios now wait up to 1 minute instead of 10 s.
- APK: debug 70.1 MB (M1.5: 69.5), release 49.09 MB (48.98); no new heavy libraries (exifinterface only).

Open issues:
- Two-phone rows of `m4-manual-test.md` (11–17): photos both ways, group of 3, Wi-Fi-only on mobile data, a real
  portrait camera photo, TalkBack, 200 % font, Android 8–9 storage permission.
- No «Ответить» (quotes) for any message yet; several photos per send, video, files, voice — after V1 (D18).
- M6 backup blobs will need eager replication and a backup rule for `/var/lib/otter/blobs`.
- The VPS run of M1.5 is still open (`otter-server/deploy/FIRST-DEPLOY.md`).

## M6 notes (2026-11-12)

Built: server — persistent blobs (`BlobMeta.persistent`, ≤ 3 live per user), `BACKUP_META` validation and
latest-wins storage with superseded-blob deletion (D50), public `backup.auth` / `backup.fetch` with fake salts, rate
limits and a per-connection blob grant (D51), `backup.publish`, `PreKeys.installed_ms` and the install rule,
`LoginResponse` (D52), janitor rules (orphan persistent blobs after 7 days, `auth_failures` after 24 h), cut-off of
replaced installs (D56); migration 0005. App — `BackupKeys`, `PasswordPolicy`, `SnapshotCodec`, `BackupManager`,
`RestoreManager`, `InstallGuard`, `SessionResets` (D53), DB v6, Settings → «Резервная копия», restore onboarding
steps, `SupersededScreen`, «восстановил(а) аккаунт» chip, «Нет в резервной копии» photos (D54, D55). Decisions
D50–D56. Plan: `docs/superpowers/plans/2026-11-12-m6-backup-restore.md`; spec:
`docs/superpowers/specs/2026-11-12-ops-scripts-and-backup-design.md` Part 2. Checklist: `otter-android/docs/m6-manual-test.md`.

Verified: server `make check` green, incl. meshsim backup scenarios. Android unit suite green. Real processes:
`LiveRestoreTest` via nodes a→c, again with node b killed, and again after the gateway fix; `LiveNodeTest` and
`LiveGroupTest` green on the M6 mesh. Emulator (staging): rows 1–10 and 13 of `m6-manual-test.md` pass. Instrumented
`SmokeTest` 3/3. APKs: debug 70.69 MB (M4: 70.1), release 48.49 MB (49.09).

Deviations / findings:
- zxcvbn Maven coordinate is `com.nulab-inc:zxcvbn:1.9.0` (plan: `com.nulabinc`); it loads its dictionaries by absolute
  path, which is R8-safe.
- `FakeNode`: republishing a backup meta whose blob is gone answers INVALID, as the Go node does; the test was adjusted.
- `BackupManager` takes `Provider<OnlineApi>` (cycle SyncEngine → BackupManager → OnlineApi) and has a test-only
  `derive` hook for cheap Argon2 parameters; `RestoreManager` has the same hook and refuses when an account is
  already installed.
- `InstallGuard` syncs the directory before sending resets (a words-only restore has no contacts yet).
- `SnapshotCodec.import` merges (existing conversation reused, newer group state kept, entry version = max), so
  `addHistory` after a words restore works.
- All restore screens live in `screens/RestoreScreens.kt`; restoring shows a single «Ищем копию…» (no separate
  «Расшифровываем…» phase: `Restorer` has no progress API). `InviteScreen` takes a title and text for the link step.
- Found on the emulator and fixed (server commit 46a8759, D56): an online old install kept its session after a restore
  elsewhere and could take and ack the new install's mail. The gateway now closes replaced installs and refuses their acks.
- Restoring through a node the backup hasn't reached yet answers like a wrong password and counts a failed attempt
  (the node can't tell; D51). `LiveRestoreTest` waits for the real salt first.
- Bot incident: a scripted test member sent one message «привет от бота» to the owner's dev-mesh account (first contact
  in the directory) before the bot was limited to the emulator account.

Open issues:
- Two-phone rows 14–17 of `m6-manual-test.md`. Rows 11–12 are covered by unit tests only.
- Known limits: fake salts differ per node (someone reaching two nodes can tell which usernames have backups);
  messages that arrived for the old install after the last backup are lost (they trigger a reset); no media in
  backups; backups only while the app is in the foreground (no WorkManager).
- The VPS run of M1.5 is still open.
- Next: M5 (push), then M7.

## M5 notes (2026-11-12)

Built: repos — `.gitignore` for every private file, `.gitleaks.toml`, `scripts/secrets-check.sh` in both repos, history
rewrite of the author identity (D57). Server — `PushToken` payload + validation, migration 0006 and newest-wins storage
(D60), FCM HTTP v1 client and coalescing `Pusher` (D59), `[push] fcm_credentials`, `otter-node check` push line,
`pushDuty`/`maybePush` with the sending-peer rule (D58), `Gateway.Online`, `push.register`, `otter-admin node set-push`,
`deploy/push-key.sh`, PUSH column in `deploy/status.sh`. App — version footer (D63), `PushRegistrar`, `PushMonitor`
(FAST/SAVER), `SyncEngine` leases, 2 s head start in `NodeSelector.race`, `BackgroundSync`, `OtterMessagingService`,
`WakeWorker`/`SaverWorker`/`WakeScheduler`, `MessageNotifier` + `NotificationActionReceiver` + channels, notification
permission once, tap → chat, Settings → «Уведомления», `ic_stat_otter` (D61, D62). Decisions D57–D63. Plan:
`docs/superpowers/plans/2026-11-12-m5-push.md`; spec: `docs/superpowers/specs/2026-11-12-m5-push-design.md`.
Checklist: `otter-android/docs/m5-manual-test.md`. Commits: server `6385ab8`, `d44e7fa`, `70898dd`, `0a8bcbe`; android
`32d37d1`, `ff282d3`, `ad50623`, `c73c9c7`, `6946656`, `683988e`, `bbcdcc4` (fix), `4b88e16` (tests).

Versions actually used: server `golang.org/x/oauth2 v0.30.0` (+ indirect `cloud.google.com/go/compute/metadata
v0.3.0`). App `firebase-bom 34.0.0` (→ `firebase-messaging 25.0.0`), Gradle plugin `com.google.gms.google-services
4.4.3`, `androidx.work:work-runtime-ktx` + `work-testing` **2.11.2** (plan: 2.10.1, see the bug below),
`androidx.hilt:hilt-work` + `hilt-compiler 1.3.0`, plus `play-services-base 18.1.0` (`GoogleApiAvailability`, the
version firebase-messaging already pulls in) and `room-runtime` in `:app` (the notifier reads the DB). Tools: gitleaks
v8.24.0 (`go install`; the binary prints "version is set by build process"), git-filter-repo 2.47.0 (scratch venv,
`pip --user` is blocked by PEP 668).

Publish safety (Task 1):
- gitleaks found only the cross-language test vectors (server `testdata/vectors/v1.json`; android
  `core/{crypto,network,signal}/src/test/resources/vectors/v1.json`) → allowlisted by path. `.dev-mesh/`, `.vm/`,
  `dist/`, `local.properties` were never committed; no VPS or LAN address in the history.
- Owner's decision (2026-11-12): «Переписать историю на анонимный адрес». git-filter-repo with a mailmap to
  `al <al@users.noreply.invalid>` and replace-text `~/` → `~/` (an old line in android `gradle.properties`).
  Every hash changed; content otherwise unchanged. New `main` heads: server `24c3713`, android `ae3049f`. Old → new
  hashes: `.git/filter-repo/commit-map` in each repo. Repo-local `user.name=al`, `user.email=al@users.noreply.invalid`.
- **The pre-rewrite bundle backups were NOT created** (wrong bundle path; the loop did not stop on the error). The
  commit maps are the only link to the old hashes.

Deviations / findings:
- Server: `nodecheck.Run` split into `checkTLS`/`checkPush` (same "ok …" output); `service.Capable(m, id)` exported
  (nil-safe) for the start-up warning "manifest says push_capable but no FCM key is installed"; `maybePush` uses the
  already decoded envelope; `Pusher.Wake` copies the user id (the send runs after the caller returns).
- D58: the origin node is approximated by the **sending peer** (`ApplyReplicated(from)`); locally imported records
  count as local.
- `push-key.sh LABEL KEY` takes the SSH target from the hosts registry, streams the key over ssh stdin with
  `umask 077` (no scp temp file), adds `[push]` to an old `node.toml`, runs `otter-node check`, restarts and looks for
  `"push on"` only in the log lines after the restart. `status.sh` PUSH = the last `push on`/`push off` line of the
  current boot (`off` when there is none), `-` if unreachable. **Neither has run against a real server yet.**
- `/usr/bin/gofmt` is older than the Go toolchain: not used for reformatting.
- App: `PushToken` proto first added by hand; `sync-proto.sh` from server `0a8bcbe` later gave no diff. The head-start
  test clock starts at 1000 (`lastSuccessMs = 0` means never). New test `FakeNodeTransport` serves `FakeNode` over the
  real frame protocol (`TestGraph` uses it); `BackgroundSyncTest` uses a real-time ticker for the `TestClock`;
  `ForegroundSync`'s internal constructor parameter order changed; `PushRegistrar` skips an empty token.
- `MailboxReceiver` raises the alert after the transaction commits. Background processes (push, workers, notification
  actions) call `accounts.load()` first; `OtterApp` applies the FAST/SAVER mode only once an account exists.
- `ic_stat_otter`: icon bounds are parsed per SVG path command (the plan's even/odd number split broke on arcs).
  `onRead` matches `notification.group`. Robolectric app tests use `application = Application` (`OtterApp` opens
  SQLCipher). WorkManager names: unique `wake` (one-time, expedited, KEEP) and `saver` (periodic 15 min, CONNECTED, KEEP).
- `WakeFlowTest` needs `core:data`'s `FakeNode`/`TestGraph`: `:app` unit tests get `core:data`'s compiled unit-test
  classes as a per-variant jar (internal names are mangled per variant: debug ↔ debug, release/staging ↔ release).
- Firebase-on build checked in a scratch worktree with a dummy `google-services.json`: `FIREBASE = true`, the
  google-services values are generated, the file is ignored by `.gitignore`; the worktree was removed.
- **Bug found on the emulator and fixed (`bbcdcc4`):** Android 15 blocks the network of a cached app process
  (`dumpsys netpolicy`: `blocked=APP_BACKGROUND`). WorkManager 2.10.1's in-process `GreedyScheduler` ran `SaverWorker`
  in such a process; the drain could not connect, timed out after 60 s and posted nothing. WorkManager ≥ 2.11.1 treats
  a blocked network as an unmet constraint («Constraints not met»), so the run happens as a JobScheduler job, which may
  use the network. Push and notification actions use the expedited `wake` job, which gets network anyway.
- Known limit: with no push-capable node in the network a Firebase build stays in FAST until 3 missed wake-ups within
  24 h are seen, and returns to FAST when they age out.

Emulator run (2026-11-12, `Medium_Phone_API_35`, Android 15, debug build **without** Firebase → SAVER, Russian via
`adb shell cmd locale set-app-locales app.ottermsg --locales ru-RU`), against the 3-node dev mesh restarted on
`dev-0a8bcbe` (data kept) with a scripted JVM contact «Бот M5»: rows 1–9 and 11 of `m5-manual-test.md` pass, row 10
(photo) only by unit test.
- Battery saver, send → notification **11 min 47 s** (the job started 3.4 s before the notification). The periodic
  job cannot be forced: `adb shell cmd jobscheduler run -f -n androidx.work.systemjobscheduler app.ottermsg <id>`
  (id from `adb shell dumpsys jobscheduler | grep 'JobStatus{.*app.ottermsg'`) is refused by WorkManager («executed
  before schedule») and re-queued, so the real period was waited out (`TIME=+…` in the dumpsys line is the time left).
- «Ответить» and «Прочитано» from the notification: the contact saw the reply / ✓✓ read after ~1 s.
- Notifications read with `adb shell dumpsys notification --noredact`. The owner tapped the emulator once during
  run 3 (launcher start + «Прочитано»).
- APKs: debug 79.40 MB (M6: 70.69), release 51.42 MB (48.49) — Firebase, Play services base and WorkManager.

Flaky tests seen once, both pre-existing, not reproduced: server
`internal/replication TestRetryLaterDoesNotLoseRecords` (data race in `Replicator.dialMissing`, `replicator.go:143`;
0 of 8 re-runs); android `ProfileTest.offlineEditIsPublishedWhenOnlineAndOthersSeeIt` (`ProfileRepository` writes
`profilePending` before it updates the pending flow).

Extra dev-mesh accounts created by the tests: three `m5bot_*` («Бот M5», the scripted contacts) and the emulator
account `m5emu2549`.

Open issues:
- Owner rows 12–17 of `m5-manual-test.md` (Task 14 of the plan): Firebase project and `google-services.json`, the
  key on `eeee` via `push-key.sh` + `node set-push` + manifest sign/publish, PUSH = on in `status.sh`, «Быстрые
  уведомления» on phone A, the < 5 s measurement (screen off and Doze), phone B, TalkBack. The acceptance
  "< 5 s on FCM" is **not** proven yet; the dev mesh has no FCM key and never pushes.
- Two-phone rows of M3/M4/M6 and the M1.5 VPS rows (phones join `eeee`, upgrade/rollback test) remain open.
- `eeee` runs 0.3.0 (M6): upgrade it to a release with M5 (`deploy/upgrade-all.sh`) **before** `deploy/push-key.sh`.
  A pre-M5 `otter-node` refuses unknown config keys; `push-key.sh` runs `otter-node check` on a copy of `node.toml`
  with `[push]` added and only then replaces the live file, so on an old binary it stops with `node.toml` unchanged
  (the key file is installed but ignored).
- Next: M7 (DPI transports).
