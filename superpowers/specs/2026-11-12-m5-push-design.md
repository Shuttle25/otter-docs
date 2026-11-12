# Design: M5 push (FCM only), version label, publish-safe repos

Approved by the owner 2026-11-12.

## Owner decisions
* FCM only. No «Мгновенно» foreground-service mode and no foss flavor. Without Google services, or when FCM is
  detected as not working, the app falls back to «Экономия батареи» (WorkManager, every 15 min, network
  constraint).
* Notifications: sender + text when unlocked («Мама: Купи хлеб», photo → «Фото»), one per chat, grouped,
  actions «Ответить» (inline reply) and «Прочитано»; lock screen shows only «Otter: новое сообщение»
  (VISIBILITY_PRIVATE + public version).
* Settings shows the app version at the very bottom, below «Подключение» (versionName + short build info).
* Both repos must be safe to publish on the internet.

## Server
* Config `[push] fcm_credentials = "/etc/otter/fcm.json"` (optional). Without it the node never pushes.
* `otter-admin node set-push --label L [--off]` toggles `push_capable` in the manifest; deploy helper
  `deploy/push-key.sh LABEL /path/fcm.json` copies the key (0640 root:otter) and adds the config line, then
  restarts with health check. Never stored in git or in the admin dir.
* `PUSH_TOKEN` record (user, device_id, kind=FCM, token) via `push.register{token}`; replicates; newest per
  device wins; removed when FCM answers UNREGISTERED/NOT_FOUND (drop locally + tombstone record).
* Trigger: urgent ENVELOPE stored for a recipient without a live session on this node. Sender: the origin node
  if push-capable, else the first push-capable node in manifest order (decided on apply of the replicated
  envelope). Coalescing: ≤ 1 push per recipient per 10 s per node. Payload: FCM HTTP v1, data-only, empty data,
  `android.priority = high`, collapse key per recipient. OAuth via `golang.org/x/oauth2/google`.
* Tests use a fake FCM HTTP server (endpoint and token URL overridable for tests only).

## App
* `firebase-messaging` + `google-services` plugin; the build must still succeed without
  `app/google-services.json` (plugin applied only when the file exists; push disabled then).
* `OtterMessagingService.onNewToken` → `push.register` (also at every login if changed);
  `onMessageReceived` → expedited WorkManager job: connect (last-good endpoint alone for 2 s, then race),
  drain mailbox, decrypt/store, notify, disconnect after 10 s idle.
* Notifications: channels «Сообщения» (and «Группы»), MessagingStyle per conversation, group summary, inline
  reply sends through the outbox, «Прочитано» marks read + sends receipts; tapping opens the chat; no
  notification for the chat currently open; cleared when the chat is read. POST_NOTIFICATIONS asked once after
  join/restore (Android 13+). Notification icon: monochrome otter head reframed for 24 dp via
  `scripts/export-assets.py` (masters untouched).
* Mode detection: FCM token present and wake-ups observed → «Быстрые уведомления»; no GMS / no token / mail
  found waiting on connect with no wake-up 3 times in 24 h → «Экономия батареи» (periodic WorkManager sync).
  Settings → «Уведомления»: current mode, on/off, link to system channel settings.

## Publish-safe repos
* `.gitignore` (both): `google-services.json`, `fcm*.json`, `*.jks`, `*.keystore`, `keystore.properties`,
  `.env*`, `*.pem`, `*.key` (except test fixtures if any), local tool dirs; server already ignores
  `.dev-mesh/ .dev/ .vm/ dist/ bin/ *.db`.
* Scan full history of both repos with gitleaks (pinned version) + a grep for LAN/VPS IPs, `/home/`, emails;
  fix tracked files; document in each repo's README how to supply private files.
* Commit author email in all existing commits is the owner's personal Gmail. Rewriting history to a
  noreply address is optional and destructive: the plan asks the owner first and only then runs
  `git filter-repo --mailmap` on both repos (after a bundle backup).

## Done when
A message wakes phone A (screen off, idle) and shows a notification in < 5 s on FCM; automated tests use
the fake FCM server; battery-saver fallback shows a notification within 15 min on an emulator without GMS.

## Out of scope
«Мгновенно» mode, foss flavor, call notifications, notification-content encryption beyond E2E (none is sent).
