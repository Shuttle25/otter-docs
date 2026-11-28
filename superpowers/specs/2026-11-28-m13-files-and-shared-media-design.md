# M13 files and shared media — design

Approved by the owner 2026-11-28 (brainstorm + mockups «Otter files & shared media», canvas
https://claude.ai/artifact/PyVHMATZ4j86vvyRj7Xjnq). Built **after M12 per-chat mute**, on branches `m13-files`.
**App 0.15.0 (versionCode 19)**; **no server change** (nodes see ordinary blobs and envelopes). New decisions
**D147–D149**. Room version **13** (M12 takes 12).

## Owner decisions

1. **Any file** can be sent, up to **1 GB** (1 073 741 824 bytes of file).
2. 1 GB is reached by **splitting** a file into up to **11 encrypted parts** of ≤ 100 MiB each; nodes keep their
   100 MiB per-blob limit and need no upgrade.
3. Node limits stay: **2 GiB** of undelivered blobs per sender; **file parts expire after 7 days** (photos keep 30).
4. **Videos are files** for now (no inline player).
5. **Photos «без сжатия»**: original quality, GPS and camera details removed.
6. **Transfer notification approved**: a foreground service holds the node connection **only while a file
   transfer runs** (bounded exception to "Firebase only, no keep-alive", like D142).
7. **Shared media screen** reached from the chat header, Telegram/WhatsApp pattern drawn in Otter's style:
   1:1 → new contact profile; group → group info. Tabs **Фото · Файлы · Ссылки · Места**.
8. Decided by default after the mockups (owner may still change before the plan runs): **«Поиск» button and
   in-chat search are not in M13** (own milestone later); **multi-select in the tabs is not in M13**; the **Места
   tab is in** (M11 already stores pins).

## What people get

### Sending (mockup 2)

- 📎 menu: «Фото», **«Файл»**, «Местоположение». «Файл» opens the system picker (`ACTION_OPEN_DOCUMENT`, `*/*`).
  A preview sheet shows name, size, type icon and an optional caption; «Отправить».
- Over 1 GB → «Файл больше 1 ГБ — отправить нельзя». Empty or unreadable file → «Не удалось прочитать файл».
- Photo preview gains a switch **«Без сжатия»** (default off) with the hint «Оригинал как файл. Геометка и данные
  камеры будут удалены». On → the photo is sent as a file (`FileShare` with `image/*`, thumbnail and size).
  - JPEG, PNG, WebP: GPS tags, make/model/serial, owner/artist, maker notes, XMP and the embedded thumbnail are
    removed with `ExifInterface`, orientation kept; pixels untouched.
  - Any other image type (HEIC, DNG…): dialog «Местоположение из этого формата убрать нельзя» → «Сжать» (today's
    photo path) / «Отправить как есть» / «Отмена».

### File bubble (mockup 1)

- Type icon (by extension: document, PDF, table, archive, audio, video, APK/app, image, other), name (one line,
  middle ellipsis), size and type, caption, time and ticks.
- States:
  - incoming, not downloaded → round download button, «2,4 МБ · PDF»;
  - moving → progress ring/bar, «Отправка · 84 из 240 МБ» / «Загрузка · …», tap cancels;
  - downloaded / own → tap opens («Открыть в…»);
  - failed → «Повторить»; node no longer has it → «Файл больше недоступен — попросите отправить снова».
- Original-quality photo bubble shows its thumbnail with «без сжатия».
- Long press adds **«Сохранить в Загрузки»** and **«Поделиться»** to the existing message menu (copy/info/delete).
- Files **never auto-download**.
- Opening a risky type (`.apk .apks .xapk .exe .msi .bat .cmd .sh .js .jar .vbs .scr .com .ps1 .reg`) first asks
  (mockup 8 B): «Открыть файл приложения?» / «Этот файл может установить приложение или изменить телефон.
  Открывайте, только если доверяете отправителю — {имя}. Обновления Otter приходят только через «Новости Выдры».»
  → «Отмена» / «Всё равно открыть». In the Files tab such files carry the amber line «Может установить приложение».

### Transfers (mockup 8 A)

- While any file part is uploading or downloading and the app leaves the screen, `FileTransferService`
  (`foregroundServiceType="dataSync"`) shows «Отправка файла · 35 %» / «Загрузка файла · 35 %», file name and
  peer, a progress bar and «Отменить». It holds a `SyncEngine` lease only while transfers remain; when the last
  one finishes, fails or is cancelled it releases the lease and stops. Nothing runs between transfers.
- Uploads and downloads resume from the last finished 256 KiB chunk after a cut connection, app restart or reboot
  (the service is not restarted after reboot; the transfer continues at the next app start or wake).
- Cancel (bubble or notification): outgoing → message removed, parts deleted locally; incoming → back to «Скачать».
- Android 15 limits `dataSync` to 6 h per day: on timeout the service stops and the transfer continues next time
  the app is open.

### Contact profile (mockup 3)

- Tap the 1:1 chat header (avatar + name) → «Профиль»: avatar 88 dp, name, @username; buttons «Позвонить» (when
  a call is possible, D80) and «Без звука» / «Включить уведомления» (M12, D146).
- Card «Медиа, файлы и ссылки · N» with the 4 newest previews → opens the shared media screen on «Фото».
- Card with rows «Фото N», «Файлы N», «Ссылки N», «Места N» → opens that tab. Rows with 0 are hidden; all 0 →
  the card says «Пока нет вложений».
- The news chat has no profile; group header taps keep opening group info.

### Group info (mockup 7)

- New card «Медиа, файлы и ссылки · N» with 4 previews above «Уведомления» / members, opening the same screen;
  every item shows its sender's name.

### Shared media screen (mockups 4–6)

- Title «Вложения», subtitle = chat name; tabs **Фото · Файлы · Ссылки · Места**, sections by month («Ноябрь 2026»),
  newest first; only items still in the chat (deleted messages disappear).
- **Фото**: 3-column grid of photos (compressed and original-quality); «ОРИГ» badge on originals; not downloaded →
  thumbnail with a download mark; restored without the file → «Нет в копии». Tap → photo viewer with
  «Показать в чате» (scrolls the chat to the message).
- **Файлы**: search field «Поиск по названию» (filters by name, local only), rows: type icon, name, «size · date ·
  sender», trailing state (download button / % / ✓ / «Недоступен»). Tap → same as the bubble.
- **Ссылки**: every `http(s)://` link and `@username` found in text and captions, with domain, the link and the
  start of its message; no previews are fetched (the phone never contacts a site until a link is opened).
  Tap → opens the link as in the chat (M9.5 rules for `@username`).
- **Места**: pins and live shares (M11) with the coordinates, sender and date; tap opens the M11 map.

## Protocol (end-to-end content only; nodes see nothing new)

`content.proto` (same file in both repos):

```proto
message DataMessage {
  ...
  FileShare file = 6;          // M13 (D147); text carries a fallback for older apps
}

message FileShare {
  string name = 1;             // display name, sanitized by the receiver
  string mime = 2;             // sender's guess; never trusted for opening or warnings
  uint64 size = 3;             // plaintext bytes, 1 … 1073741824
  repeated Attachment parts = 4;  // 1 … 11, in order; each is today's blob attachment (key, digest, ciphertext size)
  bytes thumbnail = 5;         // images only: JPEG, long edge 64 px, ≤ 4 KiB
  uint32 width = 6;            // images only
  uint32 height = 7;
  string caption = 8;
  bool original_photo = 9;     // sent with «Без сжатия»
}
```

- **Splitting**: the plaintext is cut into slices of 100 MiB − 1 MiB (99 MiB) so each part's ciphertext (Tink
  streaming AEAD, 1 MiB segments, own random key) stays ≤ 100 MiB; each part is one `BLOB_META` + chunks exactly
  as photos (D44–D48), `expires_ms = created + 7 days`, readers = recipients. Upload before envelope (D48): the
  envelope is released only after **every** part is on the node.
- **Fallback for apps < 0.15**: `text` = «📎 Файл: {name} ({size}) — обновите Otter, чтобы открыть» (+ caption on
  the next line). 0.15+ shows `FileShare.caption` and hides `text` when `file` is set. Older apps never see
  `attachments`, so they never download parts (those expire after 7 days).
- **Receiver checks** (each one has a hostile-sender test that loses):
  1. 1 ≤ parts ≤ 11; every part's ciphertext size ≤ 100 MiB and ≥ the Tink minimum; Σ plaintext implied by part
     sizes is consistent with `size` within Tink overhead; `size` ≤ 1 GiB — else the message shows as
     «Не удалось прочитать файл» and nothing is downloaded;
  2. name: path separators, NUL and control characters, bidi overrides/isolates (U+202A–U+202E, U+2066–U+2069),
     zero-width characters and leading dots are removed; length cut to 120 characters keeping the extension;
     empty → «файл»;
  3. the type icon, the «Открыть в…» MIME and the risk warning come from the **sanitized extension**, never from
     `mime`;
  4. each part's digest is checked after download (as photos); a mismatch fails the part, never opens a file;
  5. thumbnail > 4 KiB or not decodable → no thumbnail.
- Blob lifetime per D45: a reader sends `BLOB_FETCHED` per part after verifying it; nodes delete a part when
  every reader fetched it or it expires.

## On the phone

- **Storage**: each part's ciphertext stays as received in `filesDir/media/` (D46); nothing readable at rest.
  Database v13:
  - `attachments` gets `part_index INTEGER NOT NULL DEFAULT 0`; the unique index becomes
    `(message_local_id, part_index)`;
  - `MessageKind.FILE = 10`; the message's `system_data` keeps `FileShare` **without** part keys (keys live in
    `attachments` as today); `body` = caption.
- **Opening** without writing plaintext: a `FileContentProvider` (`app.ottermsg.files`, not exported, read grant
  per intent) returns `StorageManager.openProxyFileDescriptor` whose callback decrypts the needed range with
  Tink's seekable decrypting channel across the parts. Apps get a seekable file (PDF readers, video players work).
  Grants are revoked when the chat or the app lock closes the app (D121).
- **«Сохранить в Загрузки»**: MediaStore `Downloads` (Android 10+), legacy `Download/` with
  `WRITE_EXTERNAL_STORAGE` on 8–9 (permission already declared ≤ 28); name collisions get « (2)».
- **Backups** (D55): files are not in backups; restored file messages show «Файл не входит в резервную копию»
  (`NOT_IN_BACKUP`), thumbnails kept for original-quality photos.
- **Quota**: a node `QUOTA` on upload → message FAILED with «Слишком много неполученных файлов — попробуйте позже»;
  «Повторить» re-uploads (same record ids, D48).
- **Notifications** for an incoming file: «📎 {name}» (lock screen: «Новое сообщение», D62/D121). Chat list preview:
  «📎 Файл» / «📎 {caption}».
- **Disk**: before sending or downloading, the app checks free space (file size + 50 MB) and says «Недостаточно места
  на телефоне» instead of starting.

## Nodes and operations

- No code or config change. Effects to know: a 1 GB file occupies ~1 GB on **every** node until all recipients
  fetch it or 7 days pass; replication pulls parts at `[replication] blob_bandwidth` (default 2 MB/s → about 9 min
  per GB per node). Before rollout the owner checks free disk: `deploy/status.sh` (disk column) — keep ≥ 10 GB free
  per node; the ru-1 ↔ eeee link may slow big transfers (D130/D131), messages still arrive (blobs and envelopes are
  separate).

## Decisions to record

- **D147 Files**: `DataMessage.file` (`FileShare`), up to 11 parts ≤ 100 MiB, 1 GiB per file, 7-day part expiry,
  fallback text, receiver checks, risky-extension warning, files never auto-download, original-quality photos
  with metadata removal.
- **D148 Transfer service**: `FileTransferService` (`dataSync`) holds a sync lease only while transfers run;
  resumable chunks; no restart after reboot (bounded exception to D61 like D142).
- **D149 Contact profile and shared media**: 1:1 header → profile; group info card; tabs Фото / Файлы / Ссылки /
  Места; no link previews; local search by name only.

## Tests (each attack is played by a hostile sender and loses)

- Hostile `FileShare`: 12 parts; a 101 MiB part; sizes that don't add up; `size` > 1 GiB; name `../../x`,
  `счёт‮fdp.exe`, control characters, 500-character name; `mime = application/pdf` on `x.apk` → warning
  still shown; bad thumbnail; a part whose digest doesn't match → never opens.
- Split and join: 0-byte refused, 1 byte, exactly 99 MiB, 99 MiB + 1, 1 GiB boundary (with a sparse/virtual
  source in tests, not real 1 GB files); seekable read across a part boundary returns the right bytes.
- Upload before envelope with 3 parts (envelope held until the third finishes); resume after a cut mid-part;
  quota on part 2 → FAILED, retry works; cancel cleans files.
- Old-app fallback text present; 0.15 hides it.
- Metadata stripping: a JPEG with GPS, make/model and XMP → none left, orientation kept; HEIC → asks.
- Transfer service: starts only with an active transfer while backgrounded, stops when the last ends, holds no
  lease afterwards (no keep-alive).
- Shared media: tabs list only this chat's items, month sections, deleted messages disappear, link extraction
  (http/https, `@username`, no `javascript:`), counts on the profile; Robolectric screenshots (Roborazzi) of the
  profile, group card, each tab, file bubble states, transfer notification, light and dark.
- Two emulators: send a 300 MB file (generated) and a 1.2 GB attempt (refused); receiver downloads with the app in
  the background (notification visible), opens it via «Открыть в…», saves to Downloads; the original-quality
  photo arrives without GPS (`exiftool` on the saved copy).

## Out of scope

In-chat search and the profile «Поиск» button, multi-select in the tabs, inline video/audio players, link
previews, folders, sending several files at once (one file per message, as photos), files in news, files larger
than 1 GB, desktop access (idea only).
