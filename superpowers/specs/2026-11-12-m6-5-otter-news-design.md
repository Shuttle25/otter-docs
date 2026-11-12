# Design: M6.5 Otter news

Approved by the owner 2026-11-12. Owner request: "a service account which updates all users about new features".

## Owner decisions
* Not a real service account. A real account would need a headless Signal client with its keys somewhere, one
  encrypted copy per member, could not show history to later members and could not carry a verified update.
  Instead: one **signed** announcement for everyone, stored on the phone as an **ordinary message** from the system
  contact «Otter» in an ordinary (not pinned) chat. Announcements are signed, not end-to-end encrypted: nodes can
  read them. Release notes only, never private content.
* Signed by a dedicated **news key** (not the admin key), kept in the desktop keyring, so sending needs no passphrase.
  Claude never asks for or stores a passphrase; passphrase prompts are typed by the owner in the terminal.
* Delete only (no edit). To fix a mistake: delete and send again.
* Text may contain http/https links (optional); tapping one shows the full address and asks to confirm.
* The optional «Обновить» button installs an APK served **only by the Otter nodes** (no arbitrary URLs); Google Play
  later, as another update kind. The app checks SHA-256 and size before installing.
* Text in Russian and English; the phone shows its language (ru locale → Russian, else English, else whichever
  exists). The chat and contact names are localized: «Новости Otter» / "Otter News", «Otter» / "Otter".
* No «Что нового» screen. Instead, at the end of a server and/or APK release, the release script offers a news
  message whose RU/EN draft was generated during the release session (by Claude, from the commits); the owner
  confirms each language, edits it in `$EDITOR` if needed, or skips.
* In-app updates require one signing key for all APKs: a **release keystore** is created on the owner's PC
  (gitignored, backed up by the owner). Phones now run debug-signed builds, so moving to it costs one uninstall +
  restore from backup (M6) per phone, once.

## Keys and manifest
* `otter-admin news init` creates an Ed25519 news key and stores it in the Secret Service keyring (`secret-tool`,
  attribute `otter-news=<network id>`); it refuses to run without a keyring. It prints the public key.
* `Manifest.news_keys` (repeated bytes, new field 6) lists allowed news public keys. `otter-admin manifest add-news-key`
  / `remove-news-key` edit it; then the usual `manifest sign` (admin passphrase) + `manifest publish`.
* An announcement is valid only while its signer is in the current manifest. Removing a key (revocation) makes
  nodes drop and phones delete every announcement it signed.

## Records
* `ANNOUNCEMENT = 15`, body:
  `{id (16 random bytes), created_ms, signer_pub, text_ru, text_en, optional update{version_name, version_code,
  sha256, size}}`; at least one text; text ≤ 4000 chars each.
* `ANNOUNCEMENT_DELETED = 16`, body `{id, created_ms, signer_pub}`; also news-key signed; tombstone wins.
* Nodes validate (signer in current manifest, signature, sizes), replicate, keep forever. On a new manifest nodes
  drop records whose signer was removed.

## APK on the nodes
* `deploy/release-apk.sh VERSION path/to.apk` (admin PC): checks the APK's signer is the release key and its
  versionCode, copies it over ssh to every node in `~/.otter-admin/hosts`, runs `otter-node apk import FILE`
  (stores under `/var/lib/otter/apk/<sha256>.apk`, keeps the newest 2), then offers the news dialog with the update
  filled in.
* New authenticated RPC `apk.get{sha256, index}` → 1 MiB chunks; unknown hash → NOT_FOUND (the app tries another node).

## Delivery
* `news.list{since_ms}` after login → announcements + deletions; new ones arrive as live `news` events.
* When a node accepts a new ANNOUNCEMENT it pushes to every registered device (M5 sender rule D58, coalescing
  applies). Deletions do not push.
* `otter-admin announce --ru FILE --en FILE [--update VERSION_CODE]` publishes through any node (like
  `manifest publish`); `otter-admin announce --delete ID`; `otter-admin announce --list`.

## App
* Announcements are verified (signature + signer in the pinned manifest) and saved as ordinary messages from the
  system contact «Otter» in the chat «Новости Otter» / "Otter News": normal chat list position (by last message),
  unread badge, notification channel «Новости», otter avatar from the asset pack; no composer, no receipts, no
  replies, no verification UI. The system contact cannot be messaged, renamed or deleted; the chat can be muted.
* Links: http/https in the text are tappable; tap → dialog with the full URL → browser.
* «Обновить» shows when `update.version_code` > the installed versionCode: download from the current node via
  `apk.get` (progress, resumable per chunk, other node on NOT_FOUND), check size + SHA-256, then the system installer
  (`REQUEST_INSTALL_PACKAGES`; Android asks once to allow Otter). A mismatch shows «Файл повреждён» and deletes it.
* Deleted / revoked announcements disappear from the chat and their notifications are cancelled.
* Members who join or restore later receive all past announcements.

## Release dialog
* `deploy/news-dialog.sh VERSION [--update VERSION_CODE]`: reads the draft `dist/news/<version>.md`
  (sections `## ru` and `## en`), shows each language, asks «Отправить / Изменить / Пропустить» (edit opens
  `$EDITOR`), then runs `otter-admin announce`. `upgrade-all.sh` and `release-apk.sh` call it at the end (skippable
  with `--no-news`). Without a draft file it offers to open an empty template.

## Signing
* `keystore.properties` + `*.jks` (already gitignored) on the PC; `release` build uses it when present, else stays
  debug-signed (CI/tests unaffected). `release-apk.sh` refuses a debug-signed APK. The owner backs up the keystore.

## Testing
* Server: validator cases (good, wrong key, revoked key, oversized, bad update), replication + revocation drop
  (meshsim), push on accept, `apk.get` chunks/NOT_FOUND, admin CLI tests with a fake keyring.
* App: verification unit tests, message mapping, locale selection, update-button visibility, hash mismatch,
  link confirmation; manual checklist `otter-android/docs/m6.5-manual-test.md`.

## Done when
`otter-admin announce` on the PC → the news appears as a message from «Otter» on FCM phones within seconds (15 min
in battery-saver mode); a record signed by another or a revoked key is rejected by nodes and apps; «Обновить»
downloads the APK from a node, rejects a wrong hash and installs a correct one.

## Out of scope
Editing announcements, a «Что нового» screen, replies to Otter, Google Play updates, arbitrary download URLs,
per-family targeting.
