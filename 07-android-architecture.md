# 07 — Android App Architecture

## Stack

| Concern | Choice |
|---------|--------|
| Language | Kotlin 2.x, coroutines + Flow |
| UI | Jetpack Compose, Material 3, Navigation-Compose |
| Architecture | MVVM with unidirectional state (ViewModel → `StateFlow<UiState>`), repositories, use-cases where logic is non-trivial |
| DI | Hilt |
| Local DB | Room + SQLCipher (key wrapped by Android Keystore) |
| E2E | `org.signal:libsignal-android` (stores implemented on top of Room) |
| Other crypto | Tink (Ed25519, streaming AEAD), Argon2kt (Argon2id) |
| Networking | OkHttp WebSocket; libXray AAR for REALITY later (V1.x, D75: REALITY is node-to-node only in V1) |
| Serialization | protobuf-javalite (generated from shared `/proto`) |
| Background | WorkManager 2.11 (expedited `wake`, periodic `saver`), FCM (`firebase-messaging`); no persistent foreground service in V1 (D61; bounded exception: `LiveLocationService` only while a live location share is on, M11, D142) |
| Media | CameraX / system photo picker, Coil (images), Media3 (playback), MediaRecorder (voice, AAC/m4a) |
| Calls (M8) | WebRTC M150 `io.github.webrtc-sdk:android:150.7871.04` (only in `:feature:calls`), `androidx.core:core-telecom:1.0.1`, CallStyle from `androidx.core` 1.17.0 (D76, D80) |
| Maps and location (M11) | MapLibre Native Android `org.maplibre.gl:android-sdk:11.13.5` (only in `:feature:location`; bundled style, sprites and glyphs; tiles only through `TileBridge`, D144); `com.google.android.gms:play-services-location:21.4.0` (fused positions when Google Play services exist; platform `LocationManager` otherwise, D142) |
| QR | ZXing (works without Google Play Services) |
| Min / target SDK | 26 / latest |
| Build | Release ABI **arm64-v8a** only since 0.13.0 (D145; 32-bit armeabi-v7a dropped; x86_64 only in debug/staging, for the emulator; M8). Gradle KTS, version catalog, **one build, no flavors** (D61): `firebase-messaging` is always linked; the `google-services` plugin is applied only when `app/google-services.json` exists (never committed), otherwise the app builds and runs without push. Distributed as signed **APKs** (direct download; FCM works from an APK as long as the phone has Google Play services). Build types debug, release, staging (M3) |
| App id | `app.ottermsg` (name: **OtterMSG**) |
| History | All messages kept on the phone indefinitely (no auto-delete) |

## Module layout

```
android/
  app/                         Application, navigation graph, DI root
  core/
    proto/                     generated protobuf
    crypto/                    seed/BIP-39, key derivation, account key signing,
                               libsignal stores, attachment & backup encryption
    database/                  Room + SQLCipher, DAOs, entities, migrations
    network/                   Transport interface, WssTransport, RealityTransport,
                               NodeSelector (racing, stats), ProtocolClient (requests/events)
    manifest/                  manifest verification, endpoint store
    sync/                      Outbox, MailboxReceiver, Acker, ReceiptSender,
                               PrekeyMaintainer, DirectorySync
    push/                      FCM token, FAST/SAVER monitor, background drain (as built: core/data/push;
                               Android parts in app/…/push and app/…/notify, M5)
    backup/                    backup builder/uploader, restore
    media/                     attachment upload/download, voice recorder, thumbnails
    ui/                        design system: theme, common composables
  feature/
    onboarding/                invite scan, username, phrase, password, restore
    chats/                     chat list
    conversation/              message list, composer, attachments, voice, receipts
    contacts/                  member directory, contact profile, safety-number verify
    groups/                    new group, group info (members, admins, rename, leave), add members (M3)
    settings/                  settings, profile, edit name (M1.5), backup (M6), notifications (M5), app lock, network status, appearance, recovery phrase (M9.4)
    calls/                     WebRtcEngine (MediaEngine impl), call screen + view model, audio routing (M8)
    location/                  MapLibre map (OtterMap), TileBridge, MapInit, picker, live map, location bubble,
                               sharing strip (M11)
```

Dependency rule: `feature/*` → `core/*`; core modules never depend on features; `core/network`
knows nothing about Signal; `core/crypto` knows nothing about the network.

## Key components

### Transport & NodeSelector (`core/network`)
```kotlin
interface Transport { suspend fun connect(endpoint: Endpoint): Connection }
interface Connection { val incoming: Flow<Frame>; suspend fun send(f: Frame); fun close() }
```
`NodeSelector` implements the race described in [05](05-transport.md) and exposes
`StateFlow<ConnectionState>` (Connecting / Connected(node, endpoint, rtt) / Offline(retryAt)).
`ProtocolClient` sits on top: request/response correlation, timeouts, auth, event stream.

**Receive limits** (app 0.9.0, C17, D93; `ReceiveLimits`): frame ≤ 4 MiB (`RpcClient`); events received but not yet
collected ≤ 16 MiB (counted in bytes, the channel itself is unbounded); `blob.get` chunk ≤ 256 KiB and exactly
`min(256 KiB, size − offset)` (`NodeApi`, `MediaTransfers`); `apk.get` chunk ≤ 1 MiB and exactly `min(1 MiB, size −
offset)`, signed `AppUpdate.size` 1 byte to 100 MiB (`ApkUpdater`, else «Файл повреждён»). A frame, the event queue or
a chunk over its maximum raises `OversizeFrame`: the connection is dropped, `ConnectionManager` records an endpoint
failure and a «Журнал подключений» line `limit: …`, and races the other candidates at once (an ordinary session end
waits and races all). A chunk under the maximum but of the wrong size is refused before it reaches the disk (photo:
retried later). `OkHttpTransport.NoCompression` (an application interceptor: OkHttp runs no network interceptors for
web sockets) removes OkHttp's `permessage-deflate` offer and refuses an answer that enables compression. Accepted
residual: OkHttp buffers a whole message before the app sees it, so one huge uncompressed frame is still buffered
(D93).

### Outbox (`core/sync`)
* Every outgoing envelope is first written to the `outbox` table (survives process death).
* Sender loop: encrypt lazily (just before sending, so session state is current), `msg.send`,
  on OK mark **sent ✓**. Retries with backoff; on reconnection to another node resends
  pending items (same record id ⇒ dedup on nodes).
* If no `DELIVERED` receipt within 24 h → re-send the same envelope via a different node
  (covers the "node died before replicating" case).

### MailboxReceiver
* On `envelopes` events: skip (and ack) ids already in `seen_envelopes` (30 d) → look up the sender (only contacts
  with a directory entry, `entryVersion > 0`, D95) → verify the record signature → decrypt via libsignal → persist the
  message **and** its `seen_envelopes` row in one DB transaction → `msg.ack` → queue `DELIVERED` receipt (D91, C15).
* A copy that fails the signature check is logged and neither marked seen nor acked (an ACK would tombstone the real
  envelope on every node). Content handled outside a transaction (calls, group update, sender key, session reset) is
  marked seen right after it is handled; libsignal writes its own state outside Room, so `DuplicateMessageException`
  on a 1:1 envelope ("decrypted before a crash cut the commit") is marked seen and acked, nothing shown, no reset.
* Decryption failure ⇒ request session reset (`PLAINTEXT_RETRY`), show "message couldn't be
  decrypted" placeholder.

### Groups (M3, `core/data/group`, `messaging/Group*`)
* `GroupApplier` applies every signed state — local changes and incoming `GroupUpdate`s — through `GroupRules`
  (`core:crypto`, pure): stores state, members, conversation title and system events in one transaction, parks what
  can't be applied yet and retries parked updates after each accept. A removal triggers sender-key rotation
  (drops `my_distribution` and `sender_key_shared`).
* `GroupRepository` (`GroupStore` for ViewModels) builds the next state, signs it with the account key, applies it
  locally and queues it 1:1 to old and new members via the outbox (works offline).
* Sending: one outbox row per group message (`group_id`, empty recipient). `GroupSender` makes sure every current member
  has our sender key (queues SKDM rows and sends them right before the message), then encrypts once into a
  `SENDER_KEY` record for the frozen recipient set (minus removed members). Same "encrypt once, resend the identical
  record" rule as 1:1.
* Receiving: `MailboxReceiver` hands `SENDER_KEY` envelopes, `SenderKeyDistribution` and `GroupUpdate` contents to
  `GroupReceiver` outside any DB transaction (libsignal writes its own state). Messages that can't be decrypted or placed
  yet wait in `pending_group_envelopes`; after 7 days they become an "undecryptable" system event.
* Receipts for group messages update `message_recipients` only for members of the frozen set; the aggregate drives the
  message status (DELIVERED/READ when all recipients did). Receipts never create direct chats.

### Design assets (M3)
* Masters live unchanged in `design/source-assets/` (with both manifests and READMEs); `scripts/export-assets.py`
  verifies their SHA-256s and writes the runtime resources deterministically (`--check` verifies that outputs are up to
  date): illustrations and the family avatar as lossless WebP in `core/ui/src/main/res/drawable-nodpi/`, the adaptive
  launcher foreground per density, and the monochrome launcher layer as a VectorDrawable from the SVG.
* `OtterIllustration` (decorative `Image`, `Fit`, never tinted; hidden when the available height is below its size + 120 dp),
  `OtterAvatar(name, seed, size, family)` (family art for family groups, otherwise coloured initials from
  `AvatarPalette`, colour by the stable id), `AnchoredMenu` (D38).
* Theme `Theme.Otter` sets the window background (#FAF7F2 / #151B19) and the Android 12+ splash (adaptive icon).

### Notifications / background — "most battery friendly" (M5, D60–D62)
| Mode | When | How |
|------|------|-----|
| **FAST** «Быстрые уведомления» (default) | Firebase configured in this build (`BuildConfig.FIREBASE`), Google Play services available, FCM token obtained, < 3 missed wake-ups in 24 h | Constant data-only push → `OtterMessagingService` → unique expedited work `wake` (`WakeWorker`) → `BackgroundSync.drain` |
| **SAVER** «Экономия батареи» | Otherwise (no Firebase / no Play services / no token / FCM not delivering) | Unique periodic work `saver` (`SaverWorker`) every 15 min (Android's minimum), network constraint, policy KEEP; cancelled in FAST |

* **No «Мгновенно» / persistent-connection mode and no `foss` flavor in V1** (owner's decision for M5). The mode is
  chosen automatically by `PushMonitor` and shown (not chosen) in Settings → «Уведомления»; no banner.
* **Leases** (`SyncEngine.acquire/release`): the engine runs while at least one lease is held — `foreground`
  (`ForegroundSync`, app visible) or `wake`. Releasing the last lease stops it and records `last_offline_ms`.
* **Drain** (`BackgroundSync`): take the `wake` lease → connect with a 2 s head start for the last-good endpoint
  ([05](05-transport.md)) → wait until online, no `envelopes` event for 10 s and nothing due in the outbox → release
  (cap 60 s). Received messages, receipts and the outbox are handled by the normal session code.
* `WakeWorker` is expedited (`RUN_AS_NON_EXPEDITED_WORK_REQUEST` when out of quota); on API 26–30 it runs as a
  `dataSync` foreground service with a silent «Проверяем сообщения…» notification (channel «Синхронизация»).
  Notification actions also enqueue `wake`, so a reply or read receipt leaves without opening the app.
* **WorkManager ≥ 2.11.1 is required** (2.11.2 used): Android 15 blocks the network of a cached app process; 2.10.1
  ran the saver in such a process and the drain timed out. 2.11.x treats the blocked network as an unmet constraint.
* Background entry points (push, workers, notification actions) call `AccountRepository.load()` first: the process
  may have started with no screen. `OtterApp` applies FAST/SAVER only once an account exists.
* **Token** (`PushRegistrar`): stored by `OtterApp`/`onNewToken`, sent as a signed `PUSH_TOKEN` via `push.register`
  at each login only when the push state (token, `messages_off`, `withdrawn`) differs from the last accepted one (D60,
  D94).
* **Push switches** (app 0.9.0, D94; `PushSwitches`, Settings → «Уведомления»): «Показывать уведомления» off also sends
  `PUSH_TOKEN{messages_off}`: nodes then wake the phone for calls only (no message or announcement pushes).
  «Пробуждение через Google» (default on, always shown, also without Google services) off deletes the FCM token
  (`FirebasePushTokens`: `deleteToken`, auto-init off; `OtterApp` and `onNewToken` then keep no token) and sends
  `PUSH_TOKEN{withdrawn, token = ""}`: nodes erase the token, `push.status` is false, the phone runs in SAVER and the
  screen says «Без пробуждения через Google звонки не будут приходить». On again → a fresh token is fetched and sent.
  Either switch is sent at once when online, otherwise at the next login. There is **no keep-alive or persistent
  connection** on the phone: background delivery is Firebase or the 15-min saver.
* **Missed wake-up** (`PushMonitor.onDelivered`): a session receives an envelope created after the engine last went
  offline and after the last FCM wake, ≥ 60 s before the session started; at most one per session, kept 24 h. Any FCM
  wake clears them.

### Notifications content (D62)
Local only: decrypted on the device; nothing readable goes through Google. `MessageNotifier` (implements
`core:data`'s `MessageAlerts`, called by `MailboxReceiver`/`GroupReceiver` after the transaction commits):
* channels «Сообщения» (direct), «Группы» (both IMPORTANCE_HIGH), «Синхронизация» (IMPORTANCE_MIN);
* one MessagingStyle notification per conversation (id = conversation id) with the last 6 unread incoming messages
  (photo → «Фото» / «Фото: подпись»; groups: title = group name, sender per line), grouped under one summary;
* actions «Ответить» (RemoteInput → outbox) and «Прочитано» (`NotificationActionReceiver`); tap opens the chat
  (`MainActivity` → `AppNavHost`);
* `VISIBILITY_PRIVATE` with the public version «Otter» / «Новое сообщение»;
* nothing for the chat open on screen (`ActiveConversation` + `AppVisibility`); cleared when the chat is read;
* in-app switch «Показывать уведомления» (default on; off also stops message pushes, D94), «Пробуждение через Google»
  (D94), «Настройки Android» opens the system page; POST_NOTIFICATIONS
  asked once (Android 13+) when the chat list is first shown;
* small icon `ic_stat_otter`, generated by `scripts/export-assets.py`.
* per-chat mute (M12, D146): `onIncoming` returns for a muted chat (news too) and re-checks the flag right before
  posting; `MessageRepository.setMuted` stores `conversations.muted` (Room v12) and on mute calls `alerts.onRead`
  (clears the shown notification; never marks read, sends no receipt); `CallNotifier` never reads it, so calls and
  missed calls still ring/show; backups: `BackupConversation.muted = 9`, `BackupSnapshot.news_muted = 14`; a re-key
  merge keeps a mute from either chat; nodes are never told.
Not in V1: per-chat channels, mute timers, per-contact sounds, a lock-screen preview setting.

### Calls (M8, D76–D81)
Layers, from pure to Android:
* `core/data/.../calls`: **`CallStateMachine`** (pure Kotlin, no WebRTC, no Android: events in, effects out; states
  Idle → Outgoing (Соединение… / Звонит… after DELIVERED) / Incoming → Connecting → Active → Ended; timers from
  `CallTimers` (D81), glare, busy, stale offer, ICE restart); **`CallManager`** runs it on one event loop against
  `CallTransport` (`CallSignaling`: outbox, 2-min expiry; since 0.9.1 only the offer is urgent, D108), `TurnCache`
  (credentials asked per call, last answer only as fallback, D79; an answer outside the D108 bounds — 1–4
  `turn:`/`turns:` URLs on one IPv4 host, udp/tcp, expiry in the future and ≤ 24 h away, fields ≤ 256 chars — is
  refused and the call shows «Звонки недоступны»), a `MediaEngine`, `CallLines` (local call rows) and `CallAlerts`; it implements
  `CallInbox` (fed by `MailboxReceiver`) and `CallStarter` (what screens use: `state`, `notices`, `dial`,
  `peerHasPush`). The node connection is reached through **`CallLink`** (`SyncCallLink` with a `Provider<SyncEngine>`:
  SyncEngine → MailboxReceiver → CallInbox → CallLink would otherwise be a Dagger cycle); a call holds a `call` lease
  so the connection stays up. The last `CallNotice` (e.g. «Звонки недоступны») is replayed to a call screen that
  subscribes late and cleared when a new call starts (`c05ab41`).
* `MediaEngine` (interface) / `WebRtcEngine` (`:feature:calls`): one `PeerConnection` per call, unified plan,
  max-bundle, ICE policy **RELAY** when «Звонки только через сервер» is on (`Settings.callsRelayOnly`, default on),
  TURN TLS without certificate check, Opus mono + DTX (`OpusSdp`), ≤ 2 s gathering, continual gathering, one ICE
  restart by the caller; reports the selected path for the connection log (sampled 2 s after ICE connected and kept
  when the peer hangs up first, `fbee406`).
* `:app` `calls/`: `CallNotifier` (implements `CallAlerts`: full-screen CallStyle on channel `calls`, ongoing on
  `calls_ongoing`, missed on `missed_calls` with «Перезвонить»), `CallService` (foreground service
  `phoneCall|microphone`; registers the call with Telecom via core-telecom, routes audio with
  `requestEndpointChange`; without Telecom a plain `AudioManager` fallback; stops when the manager is Idle),
  `CallActivity` (show-when-locked, turn-screen-on, proximity), `CallActionReceiver` (Decline / hang up),
  `CallModule` (Hilt bindings). If Android refuses to start the service from the background while ringing, the
  notification alone rings and the service starts on Accept.
* UI: call button in the 1:1 top bar (asks `RECORD_AUDIO` the first time; warns when `push.status` says the peer has
  no push), call lines in the chat and in the chat-list preview, call screen (initials avatar, state, timer, mute,
  speaker, hang up), Settings → Подключение «Звонки только через сервер», and on Android 14+ without the
  full-screen permission «Разрешить звонки на заблокированном экране».
* Connection log: one `net_log` line per call (`call:relay-udp` / `relay-tcp` / `relay-tls` / `direct` / `none`,
  direction, duration, RTT).

### Video calls (M10, D125–D129)
* `core/data/.../calls`: `CallStateMachine` keeps a **`VideoState`** (`peerVideo`: null until known, then true/false;
  `cameraOn`, `front`, `saver`, `netPaused` (watchdog), `hidden` (screen off, background without PiP, locked),
  `cameraDenied`, the peer's last `CallMedia`, `remoteFrames`) and the add-video negotiation: after the first answer
  with `video = true` the caller emits `SendOffer(addVideo = true)` (the engine's `addVideo()` + offer); 10 s without its answer (caller) or 20 s without such an offer (callee) → `peerVideo = false`;
  one negotiation at a time with ICE restarts (D125). Only `UserCamera(on = true)` produces `StartCamera` (property
  test `VideoPrivacyTest`, source scan `CameraEntryPointsTest`, D127). **`VideoWatchdog`** (pure, fed once a second
  from `MediaEngine.stats()`): pause < 150 kbit/s for 10 s, test bursts at 15 s / 30 s / 60 s / every 2 min, resume
  after 15 s ≥ 400 kbit/s (D126). `CallManager` sends `CallMedia{camera_on, paused}` on every change (not urgent),
  applies the «Экономить трафик в видеозвонках» default (`Settings`, a row of the key-value table, no Room change)
  and samples the stats.
* `MediaEngine` video calls: `addVideo()` (track-less `sendrecv` transceiver for the re-offer), `peerVideo()`
  (`currentDirection == SEND_RECV`), `setCamera(on)` (opens/closes the camera and attaches the track with
  `RtpSender.setTrack`), `setPaused(paused)` (`setTrack(null)` / the camera track; the capturer stays open),
  `switchCamera()`, `setSaver(saver)` (encoding `maxBitrateBps` / `maxFramerate` + capture format: 1280×720@30
  ≤ 1.5 Mbit/s or 640×360@20 ≤ 500 kbit/s), `stats()` (`candidate-pair.availableOutgoingBitrate`, video bytes).
  `WebRtcEngine` builds its factory with `DefaultVideoEncoderFactory(egl, true, false)` / `DefaultVideoDecoderFactory`
  on the shared `EglBase` of `VideoSinks`. `FakeEngine` records every call for the JVM tests; `VideoLoopbackTest` (instrumented) runs
  two engines in one process, including old-peer (audio-only) calls both ways.
* **`VideoSinks`** (`:feature:calls`, singleton): the one shared `EglBase` and the sinks that connect the engine's
  remote and local frames to the `SurfaceViewRenderer`s of the call screen (remote full screen, local 96×160 dp draggable tile, mirrored for the
  front camera), so renderers come and go with the UI while the engine lives in the service.
* Call screen: camera, «Сменить камеру» and saver buttons (disabled while `peerVideo` is null; «У собеседника старая
  версия» when false), notices «Видео приостановлено: слабая связь», «Разблокируйте телефон, чтобы видеть видео»,
  «Нет доступа к камере» + «Настройки». `CAMERA` is asked on the first tap. First video moves an earpiece route to
  the speaker (`CallAudio.preferSpeakerForVideo`); no proximity screen-off with video.
* `CallService` adds the FGS type **`camera`** (`FOREGROUND_SERVICE_CAMERA`) only while the camera is on and granted,
  right after the tap, and drops it when off. `CallActivity` reports hidden / locked to the manager (sending stops,
  peer told `camera_on = false`); the unlock comes from an **exported** `ACTION_USER_PRESENT` receiver (D127).
  **Picture-in-picture**: 9:16 with an end-call action while remote video is shown (auto-enter on API 31+,
  `onUserLeaveHint` below); PiP counts as visible. Notifications never carry a picture.
* Tests: Robolectric + **Roborazzi** 1.59.0 screenshots (test-only; PNGs under `build/`, never committed).

## Local data model (Room, simplified)

```
account(user_id, username, display_name, seed_enc, created)
contacts(user_id, username, display_name, account_pub, identity_pub, verified, revoked, avatar_path, reset_ms,
         listed, related)                                                       listed/related: M9.5 (DB v10, D136)
rekeys(old_user_id, new_user_id, created_ms, record_id, revoked_ms, applied_ms)     verified REKEYs (M9.3, DB v9)
conversations(id, type{DIRECT|GROUP}, peer_user_id|group_id, title, last_message_id, unread, muted, pinned)
groups(group_id, name, family, version, state_signed, prev_state, i_am_member, created_by)
group_members(group_id, user_id, admin)
pending_group_updates(id, group_id, signed, from_user, received_ms)      parked updates (D36)
pending_group_envelopes(record_key, group_id?, sender, record, decrypted, received_ms, sent_ms)
sender_key_shared(group_id, distribution_id, member)                    who has our sender key
my_distribution(group_id, distribution_id, since_version)                our sender key; deleted on rotation
message_recipients(message_local_id, user_id, delivered_ms, read_ms)     frozen recipient set (D23)
messages(id, conversation_id, sender_id, sent_ms, received_ms, body, quote_id,
         status{PENDING|SENT|DELIVERED|READ|FAILED}, kind{TEXT|SYSTEM_UNDECRYPTABLE|SYSTEM_GROUP|PHOTO|SYSTEM_RESET|…|CALL|…|LOCATION=9},
         call_outcome, call_duration_s)                                        call columns: M8 (DB v8)
attachments(id, message_local_id UNIQUE, blob_key, key, digest, size, mime, width, height, thumb, file,
            state{UPLOADING|UPLOADED|UPLOAD_FAILED|REMOTE|QUEUED|DOWNLOADED|FAILED|GONE|NOT_IN_BACKUP}, done_chunks, auto,
            meta_record, ack_pending, attempts, next_attempt_ms)                 M4 (DB v5)
receipts(message_id, user_id, type, at)
outbox(record_id, raw_content, recipients, attempts, next_attempt, state, expires_ms)    expires_ms: M8 (DB v8, D78);
                                                         honoured for group items too since M11 (D140)
live_locations(message_id, conversation_id, sender_id, outgoing, lat_e7, lon_e7, accuracy_m, heading_deg, speed_cms,
               fix_ms, live_until_ms, stopped, updated_ms)                live shares, ours and members' (M11, DB v11, D140);
                                                                           never backed up
seen_envelopes(id, until)
signal_*                       (identity, prekeys, signed prekeys, kyber prekeys, sessions, sender keys)
endpoint_stats(node_id, endpoint_hash, network_id, success, fail, last_rtt, last_ok)
manifest(version, raw)
```

## Screens (V1)

Visual design, tokens, copy and behaviour: **[10 — design guidelines](10-otter-design-guidelines.md)**
(normative for UI). Display name **Otter**; strings in Russian (primary) and English.

1. **Onboarding**: Welcome → Scan invite / Restore from backup → Username & display name →
   Recovery phrase (show, confirm 3 words) → Done. The notification permission is asked once when the chat list is
   first shown (M5, D62). The backup password is optional and
   is set later in Settings → Безопасность → Резервная копия (M6, D55). «Восстановить аккаунт»: network link →
   password or 24 words → «Ищем копию…» → «Вернуть переписку?» (see Backup and restore below).
2. **Chats list** (main screen, no bottom tabs): top bar "Otter", search, avatar → Settings;
   primary "Написать" button → member picker. Connection problems shown as a calm banner, not in the top bar.
3. **Conversation**: bubbles, PENDING/SENT/DELIVERED/READ/FAILED, reply-quote, **photo** from
   gallery or camera (one per send, preview with caption), image viewer, long-press menu
   (reply, copy, delete-for-me; photo: reply, save to gallery, delete-for-me), "Message info"
   with per-recipient group delivery. **No** file picker, voice, reactions, typing in V1. Since M8 a 1:1 chat has a
   call button in the top bar and call lines in the message list (D80); there is no «Звонки» tab.
4. **Family (members directory)**: in the new-chat picker and in Settings → Семья; since M9.5 only the catalog
   (D136, see "Member privacy" below), with a search field and «Найти @name»; profile →
   "Message", "Verify safety number"; "Invite" (every member may invite; when the admin withdrew the right with
   `INVITE_RIGHTS`, the invite screen says so, D101).
5. **New group / Group info** (`feature:groups`): "Новая группа" is the first row of the new-chat picker (name,
   "Семейная группа" switch, member checklist with search); group info shows the art or initials, name (admins can
   edit), "N участников", members with "админ", per-member admin actions in the anchored menu (and as accessibility
   actions), add members, leave (the last admin first picks a new admin). Removed members see the group read-only.
6. **Invite someone**: shows QR + share-link, expiry.
7. **Settings** (scrollable, sections in the order of guide §10, D124): Профиль; Семья («Пригласить в семью»);
   Уведомления (M5: current mode explained by consequences, «Показывать уведомления», «Пробуждение через Google»,
   «Настройки Android»); Оформление (Как на устройстве / Светлая / Тёмная); Фото и память (auto-download, safe cache
   size); Безопасность («Блокировка приложения», «Запрет скриншотов», «Резервная копия», «Фраза восстановления»);
   Подключение (status row → «Состояние сети» with the nodes and «Журнал подключений» inside, «Звонки только через
   сервер», full-screen-call row when Android 14+ blocks it). The very bottom shows «Otter 0.5.0 (abc1234)»
   (`versionName` + short git hash, D63). Verifying a contact stays in the contact's profile.

Group receipts aggregation: see D23 in [00](00-decisions.md). Media/local-copy rules: D24.

## Security on device

* SQLCipher DB key: random 32 bytes, wrapped with an AES key in Android Keystore
  (StrongBox when available); optional app lock (PIN/biometric, D121, see below).
* Seed stored encrypted in DB; re-displaying the phrase («Фраза восстановления», D124) requires the phone's screen lock
  or the app-lock PIN.
* Photos on disk are the encrypted originals (`filesDir/media/*.otb`, Tink streaming AEAD, key in the DB) and are
  decoded into memory only; plaintext lands on storage only when the user saves to the gallery (D46).
* `FLAG_SECURE` optional («Запрет скриншотов», D121) to block screenshots app-wide. Always on (D98, C22) while a screen shows or takes the recovery
  words or a backup password (phrase, phrase check, restore by words / password / history, backup password form):
  `SecureWindow()` in `core/ui`, reference-counted per window so the next secure screen keeps the flag when the
  previous one is disposed after it.
* Pictures are decoded bounded (D98, C21): `PhotoLoader` reads the bounds first and refuses a source over
  100 megapixels or with no size («Фото повреждено»); the decoded long edge is ≤ 4096 px, thumbnails ≤ 256 px.
* The inviter from an invite link is stored unconfirmed (`verified = false`, `entryVersion = 0`, only if
  `inviter_user_id = ID16(inviter_account_pub)`): no encryption to it, no envelopes or group states accepted from it
  until its directory entry verifies (D95, C23).
* «Журнал подключений» → «Поделиться» sends redacted lines: node label instead of host, no operator, IPs → `<ip>`
  (D96, C24). The manifest fallback keeps a previous endpoint only for a node and pins the newest manifest still
  authorizes (D92, C16).
* Release builds fail without `keystore.properties` (D97, C19).
* No analytics, no crash reporters that send data externally (local crash log, user can share).

## Testing

* Unit: crypto (seed derivation vectors, Ed25519, backup encrypt/decrypt), outbox state machine,
  NodeSelector race logic with fake transports, receipt/dedup logic.
* Integration (JVM): two in-memory clients through a fake node exchanging libsignal sessions,
  groups with sender keys, session reset after restore.
* Instrumented: Room migrations, Keystore wrapping, end-to-end against a local `otter-node`
  started in CI (docker) with 3-node mesh.
* Compose UI tests for onboarding and conversation.
* Instrumented smoke test (`app/src/androidTest`, M3): fresh install starts on the Welcome screen with its illustration
  and the network permissions are granted — run on the AVD with `./gradlew :app:connectedDebugAndroidTest`.
* Push (M5): `PushMonitorTest`, `PushRegistrarTest`, `BackgroundSyncTest`, `AlertsHookTest` (`core:data`, through
  `FakeNodeTransport` = `FakeNode` over the real frame protocol); Robolectric `MessageNotifierTest`, `WakeSchedulerTest`,
  `WakeFlowTest` in `:app` (it reuses `core:data`'s compiled test classes as a per-variant jar). No real FCM in tests.
* Calls (M8): `CallStateMachineTest` (answer, decline, busy, timeout, glare, stale offer, ICE failure and restart,
  missed calls) and `CallManagerTest` with a fake `MediaEngine` and clock, `TurnCacheTest`, `CallSignalingTest`,
  `CallLinesTest`, `NodeApiCallsTest`, Room `MigrationTest` 7 → 8, Robolectric `CallNotifierTest`, UI tests for the
  call button, call lines and settings. WebRTC itself is exercised only on the emulators and phones.
* Build type `staging` (M3): release code with R8, debug-signed, plaintext dev nodes allowed — for running R8 builds
  against `dev-mesh.sh`. Never distributed.

### Backup and restore (M6, D50–D56)
`core/crypto` `BackupKeys` (Argon2id via BouncyCastle, HKDF → `backup_key`, `auth_secret`, `auth_verifier`).
`core/data/backup`:
* `PasswordPolicy` (≥ 10 chars, zxcvbn score ≥ 3), `SnapshotCodec` (`BackupSnapshot` ↔ DB: seed, profile, contacts,
  conversations, messages, attachment metadata + thumbnails, groups, photo settings; gzip; import merges, so history
  can be added after a words-only restore).
* `BackupManager` (`setPassword`, `runNow`, `runIfDue`, `state`; launched per sync session by `SyncEngine`; keys are
  kept wrapped by the Keystore via `SeedVault`): snapshot → encrypt (Tink streaming, aad = blob key) → persistent blob
  → `backup.publish`. Auto run when the last success is > 24 h old and the app is in the foreground.
* `RestoreManager` implements `Restorer`: `withPassword` (auth → fetch → blob.get → decrypt → install), `withWords`
  (identity only), `addHistory` (password after a words restore). Refuses when an account is already installed.
* `InstallGuard` runs after every login: finishes a pending restore (`restore_pending`: directory sync, fresh
  prekeys with `installed_ms`, `SessionReset` to every contact) or detects that this install was superseded
  (`superseded` → `MainActivity` shows `SupersededScreen`).
`messaging/SessionResets`: `send`, `onUndecryptable` (drops the session, at most 1 per contact per hour via
`contacts.reset_ms`), `sendToAll`, `onReceived` (→ `SYSTEM_RESET` message, `deleteSharedWithMember`).
Room v6: `contacts.reset_ms`, `MessageKind.SYSTEM_RESET = 4`, `AttachmentState.NOT_IN_BACKUP = 8`. Settings keys:
`installed_ms`, `restore_pending`, `superseded`, `backup_*`.
UI: onboarding steps `RESTORE_LINK`, `RESTORE_METHOD`, `RESTORE_PASSWORD`, `RESTORE_WORDS`, `RESTORING`,
`RESTORE_HISTORY` (`screens/RestoreScreens.kt`); route `settings/backup` (`BackupScreen`).

### Profile (M1.5, D39/D40)
`ProfileRepository` (`core/data/profile`) saves a new display name in `account` together with a `profile_pending`
setting (one transaction), so the edit works offline and the chat list, invites and Profile show it at once. While a
session is up (`SyncEngine` launches `profile.run(api)` per session) a pending name is published as
`DIRECTORY_ENTRY` version `entryVersion + 1` (same username, keys, `can_invite`, `registered_ms = account.created_ms`,
and since 0.9.1 our `invite_record` / `invite_proof` from `Settings.ownInvite()`, D100;
`DirectoryEntries` builds registration and update entries alike) through `directory.update`; `CONFLICT` reads our
own entry from the directory and continues from its version; network errors retry on the next session or after 30 s.
`DirectorySync` handles our own entry: it raises `entryVersion` and, when nothing is pending, adopts its name
(another install, restore). Other members' apps already update contact names and direct-chat titles from the
`directory` event. UI: `feature:settings` — Settings (profile row), Profile, Edit name (code-point counter, inline
errors); `ProfileStore` is the screens' interface (a fake in tests).

### Membership (M9.2, D99–D104; app 0.9.1)
A node can hide directory entries; it cannot invent members. Pure rules in `core/data/directory/Membership.kt`
(invite chain like Go `admitChain`, invite lifetime ≤ 30 days, revocation and rights as of the invite's
`created_ms`, duplicate rank), used by:
* `DirectorySync`: an entry becomes a **new** contact only if it is a founding member (verified manifest) or its
  chain verifies against the network key or an already accepted member; `REVOCATION` / `INVITE_RIGHTS` from
  `directory.sync` are verified with the network key and mark contacts `revoked` (sticky). Of several redemptions of
  one invite the lowest `SHA-256(invite_proof)` stays; losers and every contact invited through them (any depth) are
  marked revoked and never accepted as inviters. A removal writes a `SYSTEM_MEMBER` line (`MessageKind = 7`,
  `system_data` `revoked` | `duplicate_invite`) in the 1:1 chat.
* Revoked contacts: the conversation shows «Участник удалён» instead of the composer and no call button; the
  `Outbox` fails items to them; `MailboxReceiver` acks and drops their envelopes (calls included);
  `GroupRevocations` rotates our sender key in every group containing them, stops encrypting to them, and the
  group's lowest-id non-revoked admin removes them from the signed state.
* `InviteRepository` puts `redeem_pub` and the signed `INVITE` into the link; `UNAUTHORIZED` from the node →
  `NoInviteRightsException` («Администратор запретил вам приглашать…»). `Registration` derives the redeem key from
  the link secret and sends `invite_record` / `invite_proof`, never the secret; a link without the signed invite (made
  before 0.9.1) → `RegistrationError.InviteOutdated`.
* `RestoreManager`: when `backup.auth` answers `candidates` (a clashed name), it tries at most 4 of them, only
  `<typed name>#<8 hex>`, with the typed password (D103).
* `PrekeyRefill`: a node's `prekeys_low` is obeyed only for owner nodes in the verified manifest (or the connected
  node), at most once per owner per 5 min and 6 times per owner per 24 h (persisted in settings, D107).
No Room schema change (still v8): `contacts.revoked` existed already.

### Network-bound signatures, re-key, restore tunnel (M9.3, D109–D114, D134; app 0.10.0 (13))
* **Signatures (D109)**: `SigContext(networkId, v1UntilMs)` (`core/crypto`): `networkId = ID16(network_pub)`,
  `v1UntilMs` = the newest verified manifest's `sig_v1_until_ms`. `RecordCodec.sign(body, key, ctx)` signs v1 while it
  is 0 and v2 once set; `RecordCodec.verify(…, ctx)` accepts v2, or v1 for records created before `v1UntilMs`. Every
  signer goes through `LocalAccount.sign(body)` / `AccountRepository.sigContext()`, which take the context from
  `SigContexts` (`ManifestUpdater`, the newest stored manifest); every verifier (`ManifestVerifier`,
  `AnnouncementVerifier`, `DirectorySync`, `MailboxReceiver`, restore) uses the same context. `Registration` signs under
  the node's manifest when it is newer than the link's (a link may predate the cut-over). An envelope whose signature
  fails is dropped and **not** acked.
* **Re-key (D111)**: `RekeyVerifier` (`core/crypto`) checks a `REKEY` like the node (network-signed, permanent, two
  distinct 16-byte ids). `RekeyApplier`, run inside `DirectorySync`, stores verified REKEYs (Room v9 table `rekeys`):
  the old account is revoked from the earliest REKEY of it (also for invite-chain checks); the winning REKEY's new
  account is admitted without a chain and exempt from the duplicate-invite rule; once the new account is a contact
  the direct chat moves to it (messages merged into the old conversation, peer changed), the new contact is marked
  identity-changed (unverified), unsent outbox items to the old account are removed and their messages marked FAILED
  (a retry goes to the new account), and a `SYSTEM_KEY_CHANGED` line (`MessageKind = 8`, «%1$s: ключ безопасности
  изменился») is written; the chat list shows the same text. Our own re-key moves nothing.
* **«Код аккаунта»** (Settings → Профиль): our user id as 32 hex digits in 8 groups of 4, with «Копировать код» and
  the hint «Нужен администратору, если телефон потерян»; the admin types it into `otter-admin user rekey NAME --new`.
* **Groups (D112)**: `GroupRules.evaluate(…, rekeys)` accepts a member-signed state that only swaps re-keyed members
  for their new ids (a swap-shaped state without a known REKEY is parked "unknown rekey"). `GroupRevocations` (after
  every directory sync) picks one phone per group to sign the swap (`GroupRepository.swapMember`): the lowest-id
  non-revoked admin other than the old account, else the lowest-id non-revoked member. A `REVOCATION` with reason
  `rekey` rotates our sender key at once but removes the member only after `REKEY_WAIT_MS` = 14 days without a REKEY
  (`Settings.rekeyRevocations` remembers when each was seen). The swap shows the key-changed line in the group.
* **Revoked signers (D134)**: `GroupApplier.signerKey` → known / unknown (park) / revoked (refuse; a parked state
  whose signer is revoked meanwhile is deleted); `GroupRules.evaluate(…, currentSignerRevoked)` lets an honest state
  valid against the previous one replace a state we hold from a signer revoked since.
* **Restore tunnel (D113, D114)**: `Endpoints.restoreCandidates(manifest)` = the nodes without `no_backups` directly,
  then each of their pinned, non-CDN WSS endpoints through each `no_backups` node (`Candidate.via` =
  `<relay url>/tunnel?to=<hex node id>`, label `"<target> via <relay>"`, after the direct ones). `OkHttpTransport`
  opens the WebSocket to the relay (pinned to the relay) and runs a second OkHttp client over a `TunnelSocket` (each
  write ≤ 16 KiB per binary message, back-pressure at 1 MiB queued), whose TLS is pinned to the target (the target's name is never resolved, the connection never pooled). `RestoreManager`
  uses these candidates for password restore and «Добавить историю» only; a direct attempt that fails with an
  `IOException` (a freeze from inside Russia, D132) or `UNAVAILABLE` is retried once over the tunnels only; wrong
  passwords and bad backups end at once. A `no_backups` node's `UNAVAILABLE` shows as a network error.

### App lock, network status, settings (M9.4, D121, D123, D124; app 0.10.1 (14))
* **`AppLock`** (`core/data/security`, singleton): `initialized`, `enabled`, `locked` as StateFlows; `init()` loads the
  state once (idempotent), `onBackground()` / `onForeground()` apply the timeout («Сразу», 1 min default, 5, 30 min),
  `lockNow()`; `tryPin` / `checkPin` / `changePin` → `PinResult.Ok | Wrong(triesLeft) | Wait(untilMs)` (5 free tries,
  then 30 s doubling up to 15 min, persisted); `unlockedByDevice()` after a `BIOMETRIC_STRONG` prompt; `enable(pin,
  biometric)` / `disable()`. The PIN (4–8 digits) is stored as salt ‖ Argon2id(m 16 MiB, t 2, p 1) in the encrypted
  settings table (`PinHash`, `core/crypto`); every Argon2 call runs off the main thread.
* **Gate:** `MainActivity` is a `FragmentActivity` (BiometricPrompt) and shows nothing until `initialized`, then the
  lock screen (`lock/LockScreen.kt`, `PinPad`/`PinDots`/`PinEntry` in `core/ui`) while `locked`, before every other
  screen; the chat screens keep their state under it. «Забыли PIN?» → the phone's screen lock (device credential)
  turns the app lock off. Calls: `CallActivity` rings and answers without the PIN and reaches no chat.
* **While the lock is on:** `MessageNotifier` waits for `init()` (a cold start by Firebase) and posts only «Otter /
  Новое сообщение» without «Ответить» (news are unchanged; call notifications keep the caller's name); notifications
  already shown are removed when the lock is turned on (`hideAll`). Recents: API 33+ `setRecentsScreenshotEnabled(false)`;
  Android 12 and older use `FLAG_SECURE` while the lock is on (screenshots blocked there too). «Запрет скриншотов»
  holds the counted `SecureWindow(enabled = true)` for the whole window, independent of the lock.
* **Settings rows:** «Блокировка приложения» (`settings/lock`: enable with a PIN twice, biometric switch, timeout,
  change PIN, turn off; turning it on without a phone screen lock warns and offers «Всё равно включить»),
  «Запрет скриншотов» switch, «Оформление» (`settings/appearance`, `Settings.observeThemeMode()` / `setThemeMode`: 0 system / 1 light / 2 dark,
  applied at once; `applySystemBars` keeps the status-bar icons readable), «Фраза восстановления» (`settings/phrase`:
  device credential or the app-lock PIN, `FLAG_SECURE`, the words only in the screen's memory, cleared on `ON_STOP`).
* **«Состояние сети»** (`settings/network`, `NetworkStatus` in `core/data/network`): current state, the phone's network
  and operator, every manifest node with each endpoint as `scheme:port` («· CDN» for `Candidate.viaCdn`; IPs masked,
  `maskIps`) and its last success / failure, RTT, failures in a row and demotion (D73), the notification mode with the
  last push wake-up, battery optimisation with «Не ограничивать Otter»
  (`ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`) and «Автозапуск и фон» (app details page), and «Журнал подключений».
  It only reads what the phone has; no keep-alive or foreground service (phones are woken by Firebase only).

### Member privacy and network code (M9.5, D135–D139; app 0.11.0 (15))
* **Directory sync (D135, D137):** `DirectorySync.sync` calls `NodeApi.directoryList()` (on a node before 0.11.0
  "unknown method" → `directory.sync` from then on), then `directoryGet` for every 1:1 chat partner and group member
  plus the newer accounts of re-keyed ones (sent in parts of 256). `DirectorySync.fetch(api, ids)` gets unknown ids
  with their ancestry: `MailboxReceiver` fetches all unknown senders of a batch in one request, `GroupApplier` fetches
  an unknown signer and unknown members, `Outbox` fetches an unknown 1:1 recipient once before failing it with
  "unknown contact". Every answer goes through the normal admission (D104).
* **Catalog (D136):** each contact stores the signed `listed` of its entry and `related` (my direct inviter, from
  `Settings.ownInvite()`, or my invitees, from the verified invite edges, across re-keys both ways; sticky).
  `ContactDao.observeCatalog()` = not revoked and (`listed` or `related` or a 1:1 conversation or a group membership);
  `ContactRepository.observeContacts()` («Написать») and the group pickers use it. Ancestry entries stay in the store
  (names, safety numbers) but out of the lists. Room v10 adds the two columns (default 0).
* **«Показывать меня в каталоге сети»:** `Settings.catalogListed` (off by default); `ProfileRepository.setListed`
  publishes a new own entry with `listed` like a name edit (pending, offline-safe); `DirectorySync.applyOwn` takes the
  value back from an own entry at least as new as ours when nothing is pending (restore, another install).
* **`UsernameLookup`** (`core/data/directory`): normalises `@Name` → `name`, accepts `name` or `name#<8 hex>`. Answers
  from the store only when exactly one live account (or the phone's own) holds a plain name, or when a tagged name
  matches a stored account; otherwise asks the node (`directory.lookup`). The answer is applied through
  `DirectorySync.apply` and must then hold a live entry with that username (for a plain name: the only one in the
  answer, or the one the phone did not have before), else `NotFound`. Results: `Found`, `Self` («Это вы»), `NotFound`
  («Пользователь не найден»), `Limited` («Слишком много поисков, попробуйте позже»), `OldNode` («Сервер устарел,
  попробуйте позже»), `Offline` («Нет подключения»). A found account is stored but joins the catalog only once a chat
  exists. Known limit: a phone that stores only the losing account of a clash answers the plain name with it.
* **`PersonFinder`** (interface; `RealPersonFinder` = `UsernameLookup` + `MessageRepository`): `find(typed)` →
  `FoundPerson(contact, hasChat)` plus the result, `chatWith(userId)`; a fake in ViewModel tests. «Написать»
  (`NewChatViewModel`) and the conversation (`ConversationViewModel`, `@username` links from `UsernameLinks`) use it
  and show `PersonCard` (`core/ui`: avatar, name, `@username`, «Написать» or «Открыть чат») in a bottom sheet.
* **Network code and versions (D139):** `NetworkCode.of(network_pub)` (`core/crypto`, shared vector) on the onboarding
  profile step and as the first row of «Состояние сети». `SyncEngine` stores `LoginResponse.server_version` per manifest
  label (`Settings.setNodeVersion`, looked up with `ManifestUpdater.nodeLabel`); «Состояние сети» shows «Версия …»
  under each node. `ManifestUpdater` returns `FOREIGN` for a manifest validly signed by another network's key
  (`ManifestVerifier.foreignNetwork`), from `checkAfterLogin` or a `manifest` event; `SyncEngine.networkChanged`
  (memory only) shows «Сеть изменилась» over the app until «Понятно» (`dismissNetworkChanged`) for this app run.

### Location sharing (M11, D140–D144; app 0.13.0 (17))
* **Content** (`core/data/.../location`): `LocationCodec` (`Fix`, degrees × 1e7, `PERIODS_S` 900/1800/3600/28800 and
  `UNTIL_STOPPED` = -1 (uint32 max on the wire), fallback text, haversine), `UpdatePolicy` (≥ 30 m and ≥ 30 s, or a
  5-min heartbeat; update TTL 300 s; open-ended stop TTL 7 days; «Нет обновлений» after 15 min). `LocationSender`:
  `sendPin`, `startLive` (a `LOCATION` message with the `Location` proto in `systemData`, plus our `live_locations`
  row), `sendUpdate` and `stop` (outbox items only: `messageLocalId = null`, not urgent; the update's `message_id` is
  the share id; group items carry `LocationUpdate.group`); every enqueue calls `SendTrigger` = `WakeScheduler.wakeNow()`.
  Location sends keep the composer draft (`queueData(clearDraft = false)`).
* **Receive**: `MailboxReceiver` / `GroupReceiver` store `LOCATION` messages (`LiveLocationApplier.locationOf`: an
  unknown period → pin, coordinates out of range → plain text) and add the incoming share row on a newly inserted
  start (`onStart`, end counted from `min(sent_ms, received_ms)`). `LiveLocationApplier.apply` takes an update only
  from the share's author, through the share's own chat or group, while live and not stopped, with a newer `fix_ms`;
  updates never create chats, messages, notifications or receipts. In groups an update needs a current member, a stop
  counts also from a member who left or was removed. Group outbox items honour `expires_ms` (`Outbox` drops expired
  ones, `GroupSender` signs the expiry); parked group envelopes whose record expired are deleted quietly.
* **Live sharing** (`app/.../location`, D142): `LiveLocationService` (`foregroundServiceType="location|shortService"`,
  not sticky, channel `location`, notification «Вы делитесь местоположением» + «Остановить» via `StopShareReceiver`).
  `LiveLocationService.start(ctx, liveShares)` is called after `startLive` while the app is visible; without the
  permission, or when Android refuses the start, every own share is stopped and the caller tells the user. If the
  `location` type is refused inside the service (Android 14+), the permission-free `shortService` type satisfies the
  start and the service stops at once; the loop runs only under `location`. `LiveShareLoop` (`core/data`) merges
  positions, a 60 s ticker (ends timed shares while standing still) and nudges (a share started or stopped), and
  hands each to `LiveShares` (`onFix`, `expire`, `stopAll`); a failing position source stops every share. The
  service takes no `SyncEngine` lease; each update is sent by an expedited wake that releases after 10 s idle.
  `OtterApp` calls `LiveShares.stopOrphans()` once the account is loaded: a fresh process never resumes a share.
* **Positions** (`PositionSources.kt`): `FusedPositionSource` with Google Play services, `PlatformPositionSource`
  (`LocationManager`) otherwise; a fix without an accuracy is dropped (unknown is not 0 m), and `CoarseFixFilter` drops
  a fix more than 4× worse than the best of the last 30 s. `PositionSource.current()` gives the picker's pin.
* **Map** (`:feature:location`, D144): MapLibre 11.13.5 with the bundled style (`assets/map/style.json`, OpenFreeMap «liberty»
  reduced to one vector source; `asset://` sprites; glyphs for Noto Sans Regular/Bold/Italic in the assets but
  requested through the bridge; `LICENSES.md`). `MapInit.ensure` silences MapLibre's logging (Java and
  native: its messages carry tile coordinates) and installs an OkHttp client whose only interceptor is **`TileBridge`
  — the only map network path**: `https://tiles.otter.invalid/z/x/y.pbf` → `NodeApi.tile` (`tiles.get`; null or an old
  node → 404, `TileBusyException` / offline → 503; a gzip piece is unzipped before MapLibre, ≤ 8 MiB, broken → 404;
  > 1 MiB raw → 404); `/glyphs/{font}/{range}.pbf` → the bundled range, an unbundled range → empty 200 with
  `no-store` (MapLibre 11 blanks a whole tile on a failed range); other hosts → 403; the client's DNS refuses every
  name. 200 answers carry `max-age` 30 days for MapLibre's own cache. `OtterMap(camera, zoom, markers)` draws the map
  with «© OpenMapTiles © OpenStreetMap» (logo and (i) off); the picker and live map start at zoom 1 and zoom in
  (15 / 14) when the first position arrives. Bubble pictures come from MapLibre's snapshotter through the same client
  (memory cache only); offline or without pieces the bubble shows the coordinates card.
* **Screens**: `Routes.locationPick(cid)` (picker: «Отправить моё местоположение» / «Отправить эту точку», «Делиться
  в реальном времени» with the five periods, permission dead ends → «Открыть настройки»), `Routes.locationMap(cid)`
  (`?focus=<hex message id>`; every live share of the chat, own with «Остановить», each with «Открыть в картах»
  via `geo:`; an ended share or a pin focused as «Точка на карте»). Composer 📎 menu (D143), `LocationBubble`,
  `SharingStrip`; chat list, notifications and message info show «📍 Местоположение» / «📍 Трансляция
  местоположения», never coordinates. Backups keep pins (period forced to 0), never `live_locations`.
* **Size**: MapLibre's `.so` is ~13 MB for arm64-v8a; dropping 32-bit armeabi-v7a (D145) removes ~27 MB of native code, so the 0.13.0 APK is smaller than 0.12.0. MapLibre 13.x exists; moving
  to it is an owner decision. Tests: Robolectric with `LocalMapRenderer` / `LocalMapSnapshots` fakes (MapLibre's
  native view does not run on the JVM), Roborazzi screenshots (light and dark) of the 📎 menu, picker, live map, bubbles, strip and chat-list row.
* **Emulators**: on headless emulators the default SwiftShader renderer draws no MapLibre text; start them with
  `-gpu host` for map checks. If the PC's application firewall (OpenSnitch) drops new binaries' connections to the LAN
  address, run the dev nodes on 127.0.0.1 and reach them with `adb reverse` (`otter-android/docs/m11-manual-test.md`).

### Photos (M4, D44–D48)
`core/data/media`: `PhotoPrep` (JPEG ≤ 2560 px, EXIF orientation applied, no metadata, 64 px thumbnail),
`MediaFiles` (`filesDir/media` originals vs `cacheDir/{pick,camera}` scratch), `BlobMetaBuilder` (signed `BLOB_META`,
`Attachment`), `MediaTransfers` (per-session worker like `Outbox`: uploads missing chunks 4 at a time then releases
the **held** outbox row; downloads resume from a `.part` file and check size + SHA-256; `BLOB_FETCHED` acks; promotes
auto-downloads by the Wi-Fi/any/manual policy; optional save to the gallery), `IncomingPhotos` (receivers store a valid
image attachment as REMOTE), `PhotoLoader` (decrypt + bounded sampled decode into memory, LruCache, D98), `GallerySaver`
(Pictures/Otter), `MediaRepository` (= `PhotoStore`, the UI seam). UI: composer gallery button + camera icon,
`PickVisualMedia`/`TakePicture` (FileProvider `${applicationId}.photos`), full-screen preview dialog with caption,
photo bubbles with honest states, `PhotoViewerScreen` (zoom), Settings → «Фото и память». No Coil/CameraX: system
picker and camera app, `BitmapFactory`.

