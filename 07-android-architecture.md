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
| Networking | OkHttp WebSocket; libXray AAR for REALITY |
| Serialization | protobuf-javalite (generated from shared `/proto`) |
| Background | WorkManager 2.11 (expedited `wake`, periodic `saver`), FCM (`firebase-messaging`); no persistent foreground service in V1 (D61) |
| Media | CameraX / system photo picker, Coil (images), Media3 (playback), MediaRecorder (voice, AAC/m4a) |
| QR | ZXing (works without Google Play Services) |
| Min / target SDK | 26 / latest |
| Build | Gradle KTS, version catalog, **one build, no flavors** (D61): `firebase-messaging` is always linked; the `google-services` plugin is applied only when `app/google-services.json` exists (never committed), otherwise the app builds and runs without push. Distributed as signed **APKs** (direct download; FCM works from an APK as long as the phone has Google Play services). Build types debug, release, staging (M3) |
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
    settings/                  settings, profile, edit name (M1.5), backup (M6), notifications (M5); later: node status
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

### Outbox (`core/sync`)
* Every outgoing envelope is first written to the `outbox` table (survives process death).
* Sender loop: encrypt lazily (just before sending, so session state is current), `msg.send`,
  on OK mark **sent ✓**. Retries with backoff; on reconnection to another node resends
  pending items (same record id ⇒ dedup on nodes).
* If no `DELIVERED` receipt within 24 h → re-send the same envelope via a different node
  (covers the "node died before replicating" case).

### MailboxReceiver
* On `envelope` events: dedup by id (`seen_envelopes` table, 30 d) → decrypt via libsignal
  → persist message in one DB transaction with the libsignal state update → `msg.ack`
  → queue `DELIVERED` receipt.
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
  at each login only when it differs from the last accepted one (D60).
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
* in-app switch «Показывать уведомления» (default on), «Настройки Android» opens the system page; POST_NOTIFICATIONS
  asked once (Android 13+) when the chat list is first shown;
* small icon `ic_stat_otter`, generated by `scripts/export-assets.py`.
Not in V1: per-chat channels or mute, per-contact sounds, a lock-screen preview setting.

## Local data model (Room, simplified)

```
account(user_id, username, display_name, seed_enc, created)
contacts(user_id, username, display_name, account_pub, identity_pub, verified, revoked, avatar_path, reset_ms)
conversations(id, type{DIRECT|GROUP}, peer_user_id|group_id, title, last_message_id, unread, muted, pinned)
groups(group_id, name, family, version, state_signed, prev_state, i_am_member, created_by)
group_members(group_id, user_id, admin)
pending_group_updates(id, group_id, signed, from_user, received_ms)      parked updates (D36)
pending_group_envelopes(record_key, group_id?, sender, record, decrypted, received_ms, sent_ms)
sender_key_shared(group_id, distribution_id, member)                    who has our sender key
my_distribution(group_id, distribution_id, since_version)                our sender key; deleted on rotation
message_recipients(message_local_id, user_id, delivered_ms, read_ms)     frozen recipient set (D23)
messages(id, conversation_id, sender_id, sent_ms, received_ms, body, quote_id,
         status{PENDING|SENT|DELIVERED|READ|FAILED}, kind{TEXT|SYSTEM_UNDECRYPTABLE|SYSTEM_GROUP|PHOTO|SYSTEM_RESET})
attachments(id, message_local_id UNIQUE, blob_key, key, digest, size, mime, width, height, thumb, file,
            state{UPLOADING|UPLOADED|UPLOAD_FAILED|REMOTE|QUEUED|DOWNLOADED|FAILED|GONE|NOT_IN_BACKUP}, done_chunks, auto,
            meta_record, ack_pending, attempts, next_attempt_ms)                 M4 (DB v5)
receipts(message_id, user_id, type, at)
outbox(record_id, raw_content, recipients, attempts, next_attempt, state)
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
   with per-recipient group delivery. **No** file picker, voice, calls, reactions, typing in V1.
4. **Family (members directory)**: in the new-chat picker and in Settings → Семья; profile →
   "Message", "Verify safety number"; "Invite" (all members may invite, hidden if `can_invite` revoked).
5. **New group / Group info** (`feature:groups`): "Новая группа" is the first row of the new-chat picker (name,
   "Семейная группа" switch, member checklist with search); group info shows the art or initials, name (admins can
   edit), "N участников", members with "админ", per-member admin actions in the anchored menu (and as accessibility
   actions), add members, leave (the last admin first picks a new admin). Removed members see the group read-only.
6. **Invite someone**: shows QR + share-link, expiry.
7. **Settings** (scrollable, sections per guide §10): profile, family, notifications (M5: current mode explained by
   consequences, «Показывать уведомления», «Настройки Android»), appearance (system/light/dark), photos & storage (auto-download,
   safe cache size), security (app lock, verify contact, block screenshots), backups,
   recovery phrase (after device auth), connection (human status; node details inside), about. The very bottom shows
   «Otter 0.5.0 (abc1234)» (`versionName` + short git hash, D63).

Group receipts aggregation: see D23 in [00](00-decisions.md). Media/local-copy rules: D24.

## Security on device

* SQLCipher DB key: random 32 bytes, wrapped with an AES key in Android Keystore
  (StrongBox when available); optional app lock (biometric/PIN).
* Seed stored encrypted in DB; re-displaying phrase requires device credential.
* Photos on disk are the encrypted originals (`filesDir/media/*.otb`, Tink streaming AEAD, key in the DB) and are
  decoded into memory only; plaintext lands on storage only when the user saves to the gallery (D46).
* `FLAG_SECURE` optional (setting) to block screenshots.
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
`DIRECTORY_ENTRY` version `entryVersion + 1` (same username, keys, `can_invite`, `registered_ms = account.created_ms`;
`DirectoryEntries` builds registration and update entries alike) through `directory.update`; `CONFLICT` reads our
own entry from the directory and continues from its version; network errors retry on the next session or after 30 s.
`DirectorySync` handles our own entry: it raises `entryVersion` and, when nothing is pending, adopts its name
(another install, restore). Other members' apps already update contact names and direct-chat titles from the
`directory` event. UI: `feature:settings` — Settings (profile row), Profile, Edit name (code-point counter, inline
errors); `ProfileStore` is the screens' interface (a fake in tests).

### Photos (M4, D44–D48)
`core/data/media`: `PhotoPrep` (JPEG ≤ 2560 px, EXIF orientation applied, no metadata, 64 px thumbnail),
`MediaFiles` (`filesDir/media` originals vs `cacheDir/{pick,camera}` scratch), `BlobMetaBuilder` (signed `BLOB_META`,
`Attachment`), `MediaTransfers` (per-session worker like `Outbox`: uploads missing chunks 4 at a time then releases
the **held** outbox row; downloads resume from a `.part` file and check size + SHA-256; `BLOB_FETCHED` acks; promotes
auto-downloads by the Wi-Fi/any/manual policy; optional save to the gallery), `IncomingPhotos` (receivers store a valid
image attachment as REMOTE), `PhotoLoader` (decrypt + sampled decode into memory, LruCache), `GallerySaver`
(Pictures/Otter), `MediaRepository` (= `PhotoStore`, the UI seam). UI: composer gallery button + camera icon,
`PickVisualMedia`/`TakePicture` (FileProvider `${applicationId}.photos`), full-screen preview dialog with caption,
photo bubbles with honest states, `PhotoViewerScreen` (zoom), Settings → «Фото и память». No Coil/CameraX: system
picker and camera app, `BitmapFactory`.

