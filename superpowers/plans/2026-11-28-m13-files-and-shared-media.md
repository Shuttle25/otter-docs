# M13 Files and shared media — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Members can send any file up to 1 GB (and photos in original quality without location data) in any chat, and
browse every chat's photos, files, links and places from a new contact profile or the group info screen.

**Architecture:** End-to-end content only: a new `DataMessage.file` (`FileShare`) points at 1–11 ordinary photo-style
blobs (each ≤ 100 MiB ciphertext, own key, 7-day expiry), so nodes need no change. The phone keeps each part's
ciphertext in `filesDir/media`, opens files for other apps through a `StorageManager` proxy file descriptor that
decrypts on demand (no plaintext on disk), and runs a `dataSync` foreground service that holds a sync lease only while
parts move. A new `feature/media` module adds the contact profile and the shared media tabs, fed by Room queries.

**Tech Stack:** Kotlin, Jetpack Compose, Room (AutoMigration), Hilt, Tink streaming AEAD (`AesGcmHkdfStreaming`,
seekable decrypting channel), `androidx.exifinterface`, MediaStore, Robolectric + Roborazzi; protobuf/buf generation
only on the server.

**Spec:** `docs/superpowers/specs/2026-11-28-m13-files-and-shared-media-design.md` (approved 2026-11-28; mockups
https://claude.ai/artifact/PyVHMATZ4j86vvyRj7Xjnq).
**Versions:** app **0.15.0** (versionCode **19**); server stays 0.13.0 (proto copy + generated code only).
**Decisions:** **D147–D149** (last used: D146). **Room:** 12 → **13**.
**Precondition:** M12 merged into main (`git -C otter-android log origin/main --oneline | grep -m1 "Merge M12"`).

---

## Facts from the code (main after M12, 2026-11-28: app e79f610, docs 9c02e53)

| Question | Answer | Source |
|---|---|---|
| Blob encryption | `BlobCipher` (core/crypto): `AesGcmHkdfStreaming(key, "HmacSha256", 32, SEGMENT=1 MiB, 0)`, `encrypt(input, outFile, key, aad) → Sealed(size, sha256)`, `decrypt(file, key, aad)`, `chunkHashes`, `CHUNK = 256 KiB`; aad = blob key | `core/crypto/.../BlobCipher.kt` |
| BLOB_META | `BlobMetaBuilder.build(id, me, file, readers, now)` with `TTL_MS = 30 days`; `resign`; `attachment(a)`; `blobKey(author, id)` | `core/data/.../media/BlobMetaBuilder.kt` |
| Photo send | `MessageRepository.sendPhoto` → prep, encrypt into `files.file(name)`, `queuePhoto` (message PENDING + attachment UPLOADING + **held** outbox row in one transaction) → `media.kick()` | `messaging/MessageRepository.kt:176-230` |
| Upload | `MediaTransfers.upload(api, a)`: `blobCreate(meta)` → missing chunks → `blobPut` ×4 parallel → state UPLOADED and **`outboxDao().release(messageLocalId)` per attachment** (must wait for all parts); QUOTA/INVALID → UPLOAD_FAILED + message FAILED + outbox deleted | `media/MediaTransfers.kt:88-127` |
| Download | `MediaTransfers.download(api, a)`: resumes `files.part(name)` by whole chunks, exact chunk size check (C17), digest check (3 failures → FAILED), rename, DOWNLOADED + `ackPending`; NOT_FOUND → GONE | `MediaTransfers.kt:135-177` |
| Attachment table | `attachments` (one row per message: **unique index on `message_local_id`**), states in `AttachmentState` (UPLOADING … NOT_IN_BACKUP=8); `AttachmentDao.forMessage(m)` returns one row | `core/database/.../entity/AttachmentEntity.kt`, `dao/AttachmentDao.kt`, `model/MessageStatus.kt` |
| Message kinds | TEXT=0 … LOCATION=9 → **FILE = 10** | `model/MessageStatus.kt` |
| Receive | 1:1 `MailboxReceiver.handleContent` (l.158-180), groups `GroupReceiver` (l.205-222): `IncomingAttachments.photoOrNull(d)` → kind PHOTO, `photos.store(id, photo)`; location → kind LOCATION with `systemData` | `messaging/*.kt` |
| Kind lists to extend | `MessageDao.unreadReceiptsPending` (l.31), `NotificationContent.SHOWN` + label (l.27-35), `ChatListViewModel` previews (l.85-106), `RETRYABLE` (MessageRepository l.338), `SnapshotCodec.export/import` | — |
| Delete | `MessageRepository.deleteLocal` deletes one attachment file (`a?.file`) | `MessageRepository.kt:~290` |
| Sync lease | `SyncEngine.acquire(tag)` / `release(tag)`; core code uses the `CallLink` pattern (`interface` in core, `engine.get().acquire`) | `sync/SyncEngine.kt:78`, `calls/CallLink.kt` |
| FGS pattern | `LiveLocationService` (location FGS, `START_NOT_STICKY`, `onTimeout`, `stopEverything`, companion `start(c)`) | `app/.../location/LiveLocationService.kt` |
| FileProvider | `ApkFileProvider` subclass (`${applicationId}.files`); photos have their own in `:feature:conversation` | `app/.../update/ApkInstaller.kt` |
| Composer | 📎 `DropdownMenu` with «Фото», «Местоположение» (D143); `MessageComposer(..., onPickPhoto, onTakePhoto, onPickLocation)` | `feature/conversation/.../MessageComposer.kt:40-62` |
| Photo preview | `PhotoPreview(path, draft, sending, onCancel, onSend)`; VM `pendingPhoto`, `onPicked(uri)`, `sendPhoto(caption)` | `PhotoPreview.kt:52`, `ConversationViewModel.kt:207-305` |
| Message menu | `MenuAction(...)` list in `ConversationScreen.kt:385-391` | — |
| Username regex | `usernameRegex` in `feature/conversation/.../UsernameLinks.kt:39` | — |
| Navigation | `Routes` + `composable(...)` in `app/.../AppNavHost.kt`; conversation route l.124; group info `Routes.groupInfo(hex)` | — |
| Module template | `feature/location/build.gradle.kts` (Compose, Hilt, Roborazzi), `settings.gradle.kts` `include(...)` | — |
| Group info | `GroupInfoScreen(ui, error, onBack, onAddMembers, actions)` LazyColumn | `feature/groups/.../GroupInfoScreen.kt:76` |
| Storage permission | `WRITE_EXTERNAL_STORAGE maxSdkVersion=28` already declared; `GallerySaver` pattern for MediaStore | `app/src/main/AndroidManifest.xml:5`, `media/GallerySaver.kt` |
| Proto copies | edit `otter-server/proto/otter/v1/content.proto`, `make gen`, app `scripts/sync-proto.sh` (`OTTER_SERVER_DIR`) | — |

## Constants (D147)

```kotlin
object FileLimits {
    const val MAX_FILE = 1L shl 30                 // 1 073 741 824 plaintext bytes
    const val SLICE = 99L shl 20                   // plaintext per part; ciphertext stays ≤ 100 MiB
    const val MAX_PARTS = 11                       // ceil(MAX_FILE / SLICE)
    const val MAX_PART_CIPHERTEXT = 100L shl 20    // node limit (D44)
    const val PART_TTL_MS = 7L * 24 * 3600 * 1000
    const val MAX_NAME = 120
    const val FREE_SPACE_MARGIN = 50L shl 20
}
```

## Branches, worktrees, commits

```bash
cd ~/Documents/Projects/OttterMSG
for r in otter-server otter-android docs; do
  git -C $r fetch origin && git -C $r worktree add ../$r-m13 -b m13-files origin/main
done
cp otter-android/local.properties otter-android-m13/local.properties
```
Work only in `otter-server-m13`, `otter-android-m13`, `docs-m13`. Commit with `oc` (copy from
`docs/superpowers/plans/2026-11-15-m9-0b-frozen-links.md:72-82`; UTC 12:00:SS dates, D57). Every message ends with
`-m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`; never a `Claude-Session:` line; no hooks.
Env: `export PATH=/usr/lib/go-1.26/bin:$HOME/go/bin:$PATH`, `export JAVA_HOME=~/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2`.
`G="nice -n 15 ionice -c3 ./gradlew --max-workers=4"` (from `otter-android-m13`). **Laptop limits:** one heavy job at a
time; never Gradle and an emulator together; `go test -p 4`. **Tests never write real 1 GB files**: every size-dependent
class takes its slice size as a constructor parameter so tests use KiB slices. Never create, print or commit
`google-services.json`, `fcm*.json`, `release.jks`, `keystore.properties`. Never connect to the owner's servers.

## File map

- Server: `proto/otter/v1/content.proto`, `internal/proto/otterv1/content.pb.go`
- `core/database`: `AttachmentEntity` (`part_index`), `AttachmentDao` (part queries, shared media queries), `MessageStatus.kt` (`FILE`), `OtterDatabase` (v13), schema `13.json`, `MigrationTest`, new `SharedMediaDaoTest`
- `core/crypto`: `BlobCipher` (+ `ciphertextSize`, `seekable`)
- `core/data/media/`: new `FileLimits.kt`, `FileNames.kt`, `FileShareCheck.kt`, `FileSealer.kt` (split + encrypt), `MultiPartReader.kt` (seekable plaintext over parts), `ExifStripper.kt`, `FileStore.kt` (interface for UI: send, download, cancel, open, save, share), `TransferLink.kt`, `SharedMedia.kt` (repository); edits in `BlobMetaBuilder`, `MediaTransfers`, `IncomingAttachments`
- `core/data/messaging/`: `MessageRepository` (`sendFile`, retry/delete for parts, fallback text), `MailboxReceiver`, `GroupReceiver`
- `core/data/backup/SnapshotCodec.kt`
- `app/`: `files/FileContentProvider.kt`, `files/FileTransferService.kt`, `files/TransferWatcher.kt`, manifest, `notify/NotificationContent.kt`, `AppNavHost.kt`
- `feature/conversation/`: composer «Файл», `FilePreviewSheet.kt`, `FileBubble.kt`, `RiskyFileDialog.kt`, `PhotoPreview` switch, menu actions, strings, tests
- `feature/chats/`: file preview line
- new `feature/media/`: `ContactProfileScreen.kt`, `SharedMediaScreen.kt` (+ VMs), strings, tests
- `feature/groups/`: media card in `GroupInfoScreen`
- docs: `00-decisions.md`, `02-protocol.md`, `07-android-architecture.md`, `09-roadmap.md`, `10-otter-design-guidelines.md`; `otter-android-m13/docs/m13-manual-test.md`

---

### Task 1: `FileShare` proto (server copy, generated code, app copy)

**Goal:** `DataMessage.file = 6` and `message FileShare` exist identically in both repos.

**Files:**
- Modify: `otter-server-m13/proto/otter/v1/content.proto`; regenerate `otter-server-m13/internal/proto/otterv1/content.pb.go`
- Modify (sync): `otter-android-m13/core/proto/src/main/proto/otter/v1/content.proto`

**Acceptance Criteria:**
- [ ] Both `content.proto` files are byte-identical and contain `FileShare` as in the spec.
- [ ] `go build ./... && go vet ./...` clean; `$G :core:proto:build` succeeds.

**Verify:** `diff otter-server-m13/proto/otter/v1/content.proto otter-android-m13/core/proto/src/main/proto/otter/v1/content.proto && echo SAME`

**Steps:**

- [ ] **Step 1:** In `DataMessage` add after `location = 5`:

```proto
  FileShare file = 6;    // M13 (D147): a file of 1-11 blob parts; text carries a fallback for older apps
```
  and after `message Location {...}`:

```proto
// M13 (D147). The receiver re-checks everything: parts == ceil(size / 99 MiB), exact part ciphertext sizes,
// sanitized name; mime is a hint only (icons and warnings come from the sanitized extension).
message FileShare {
  string name = 1;
  string mime = 2;
  uint64 size = 3;                 // plaintext bytes, 1 .. 1073741824
  repeated Attachment parts = 4;   // in order; part i holds plaintext [i*99 MiB, min(size, (i+1)*99 MiB))
  bytes thumbnail = 5;             // images only: JPEG, long edge 64 px, <= 4 KiB
  uint32 width = 6;
  uint32 height = 7;
  string caption = 8;
  bool original_photo = 9;         // sent with «Без сжатия»
}
```
- [ ] **Step 2:** `cd otter-server-m13 && make gen && go build ./... && go vet ./...` (needs the Go module cache for buf; if it fails for lack of network, stop and tell the owner). `git status` → only `content.proto`, `content.pb.go`.
- [ ] **Step 3:** `oc -am "proto: FileShare for files up to 1 GiB in parts (D147)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`
- [ ] **Step 4:** `cd ../otter-android-m13 && OTTER_SERVER_DIR=../otter-server-m13 scripts/sync-proto.sh && git status --short` → only `content.proto` (revert anything else).
- [ ] **Step 5:** `$G :core:proto:build`; `oc -am "proto: sync content.proto (FileShare, D147)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 2: Room v13 — parts and the FILE kind

**Goal:** A message can own several attachment rows (parts) and a FILE kind exists.

**Files:**
- Modify: `core/database/src/main/kotlin/app/ottermsg/core/database/entity/AttachmentEntity.kt`
- Modify: `core/database/src/main/kotlin/app/ottermsg/core/database/dao/AttachmentDao.kt`
- Modify: `core/database/src/main/kotlin/app/ottermsg/core/database/model/MessageStatus.kt`
- Modify: `core/database/src/main/kotlin/app/ottermsg/core/database/OtterDatabase.kt`
- Create (generated): `core/database/schemas/app.ottermsg.core.database.OtterDatabase/13.json`
- Test: `core/database/src/test/kotlin/app/ottermsg/core/database/MigrationTest.kt`, `DaoTest.kt`

**Acceptance Criteria:**
- [ ] Migration 12 → 13 keeps every attachment with `part_index = 0`; two rows with the same message and different `part_index` are accepted, the same pair is refused.
- [ ] `forMessage(m)` returns part 0; `parts(m)` returns all parts ordered; `observeParts(m)` emits them.

**Verify:** `$G :core:database:testDebugUnitTest` → BUILD SUCCESSFUL

**Steps:**

- [ ] **Step 1: Failing tests.** `MigrationTest`:

```kotlin
    @Test fun migrate12To13AddsPartIndex() {
        helper.createDatabase("m13.db", 12).use {
            it.execSQL("INSERT INTO conversations(id, peer_user_id, title, last_activity_ms, unread, draft, type, muted) VALUES (1, x'02', 'A', 1, 0, '', 0, 0)")
            it.execSQL("""INSERT INTO messages(local_id, message_id, conversation_id, sender_id, outgoing, sent_ms, received_ms, body, status, kind, read_receipt_sent, call_outcome, call_duration_s)
                          VALUES (1, x'01', 1, x'02', 0, 5, 6, '', 2, 3, 0, 0, 0)""")
            it.execSQL("""INSERT INTO attachments(id, message_local_id, blob_key, key, digest, size, mime, width, height, state, done_chunks, auto, ack_pending, attempts, next_attempt_ms)
                          VALUES (1, 1, x'03', x'04', x'05', 10, 'image/jpeg', 1, 1, 3, 0, 0, 0, 0, 0)""")
        }
        helper.runMigrationsAndValidate("m13.db", 13, true).use { db ->
            db.query("SELECT part_index FROM attachments WHERE id = 1").use { c -> c.moveToFirst(); assertEquals(0, c.getInt(0)) }
            db.execSQL("""INSERT INTO attachments(message_local_id, part_index, blob_key, key, digest, size, mime, width, height, state, done_chunks, auto, ack_pending, attempts, next_attempt_ms)
                          VALUES (1, 1, x'06', x'04', x'05', 10, 'application/octet-stream', 0, 0, 3, 0, 0, 0, 0, 0)""")
            assertThrows(android.database.sqlite.SQLiteConstraintException::class.java) {
                db.execSQL("""INSERT INTO attachments(message_local_id, part_index, blob_key, key, digest, size, mime, width, height, state, done_chunks, auto, ack_pending, attempts, next_attempt_ms)
                              VALUES (1, 1, x'07', x'04', x'05', 10, 'x', 0, 0, 3, 0, 0, 0, 0, 0)""")
            }
        }
    }
```
  (Check the exact `attachments` column list against `schemas/.../12.json` and adjust the INSERTs; keep the asserts.)
  `DaoTest`: insert a message, three `AttachmentEntity` rows with `partIndex` 2, 0, 1 → `parts(m).map { it.partIndex } == [0, 1, 2]`, `forMessage(m)!!.partIndex == 0`.

- [ ] **Step 2: Entity.** `AttachmentEntity`: change the indices to
  `indices = [Index(value = ["message_local_id", "part_index"], unique = true), Index("state")]` and add after `messageLocalId`:

```kotlin
    /** D147: part of a file (0-based); photos and single-part files have 0. */
    @ColumnInfo(name = "part_index", defaultValue = "0") val partIndex: Int = 0,
```
  Update the KDoc: «A photo or one part of a file (D46/D147)».
- [ ] **Step 3: DAO.**

```kotlin
    @Query("SELECT * FROM attachments WHERE message_local_id = :m ORDER BY part_index LIMIT 1") suspend fun forMessage(m: Long): AttachmentEntity?
    @Query("SELECT * FROM attachments WHERE message_local_id = :m ORDER BY part_index LIMIT 1") fun observeMessage(m: Long): Flow<AttachmentEntity?>
    @Query("SELECT * FROM attachments WHERE message_local_id = :m ORDER BY part_index") suspend fun parts(m: Long): List<AttachmentEntity>
    @Query("SELECT * FROM attachments WHERE message_local_id = :m ORDER BY part_index") fun observeParts(m: Long): Flow<List<AttachmentEntity>>
    @Query("SELECT COUNT(*) FROM attachments WHERE message_local_id = :m AND state != ${AttachmentState.UPLOADED}") suspend fun notUploaded(m: Long): Int
```
  (replace the existing `forMessage` / `observeMessage` definitions with the ordered ones).
- [ ] **Step 4:** `MessageKind`: add `/** D147: a file in 1-11 parts; system_data = FileShare without part keys. */ const val FILE = 10` (keep the object's one-line style).
- [ ] **Step 5:** `OtterDatabase`: `version = 13`, `AutoMigration(from = 12, to = 13)`.
- [ ] **Step 6:** Verify → PASS, `13.json` generated. `git add core/database && oc -m "database v13: attachment parts, MessageKind.FILE (D147)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 3: File names, kinds and the receiver's checks

**Goal:** Pure functions that sanitize names, classify files by extension, and refuse hostile `FileShare`s.

**Files:**
- Create: `core/data/src/main/kotlin/app/ottermsg/core/data/media/FileLimits.kt` (the constants above)
- Create: `core/data/src/main/kotlin/app/ottermsg/core/data/media/FileNames.kt`
- Create: `core/data/src/main/kotlin/app/ottermsg/core/data/media/FileShareCheck.kt`
- Modify: `core/crypto/src/main/kotlin/app/ottermsg/core/crypto/BlobCipher.kt` (`ciphertextSize`)
- Test: `core/data/src/test/kotlin/app/ottermsg/core/data/FileNamesTest.kt`, `FileShareCheckTest.kt`

**Acceptance Criteria:**
- [ ] `FileNames.sanitize` removes `/ \ : NUL`, C0/C1 controls, U+202A–U+202E, U+2066–U+2069, U+200B–U+200F, U+FEFF, leading dots; keeps the extension when cutting to 120 chars; empty → «файл».
- [ ] `FileNames.kind(name)` returns DOCUMENT/PDF/TABLE/ARCHIVE/AUDIO/VIDEO/APP/IMAGE/OTHER from the extension only; `risky(name)` true for the spec's list.
- [ ] `FileShareCheck.check(share)` returns `Valid(sanitized)` or `Invalid(reason)`; every hostile case in the spec is Invalid; a well-formed 1-part and 11-part share are Valid.

**Verify:** `$G :core:data:testDebugUnitTest --tests '*FileNamesTest' --tests '*FileShareCheckTest'` → PASS

**Steps:**

- [ ] **Step 1: Failing tests** (examples; write each as its own `@Test`):

```kotlin
assertEquals("x", FileNames.sanitize("../../x"))
assertEquals("счётfdp.exe", FileNames.sanitize("счёт‮fdp.exe"))   // bidi override gone: the real extension shows
assertEquals("файл", FileNames.sanitize("\u0000\u0001"))
assertEquals("a.pdf", FileNames.sanitize("...a.pdf"))
FileNames.sanitize("я".repeat(500) + ".docx").let { assertEquals(120, it.length); assertTrue(it.endsWith(".docx")) }
assertEquals(FileKind.APP, FileNames.kind("Setup.APK")); assertTrue(FileNames.risky("x.apk"))
assertFalse(FileNames.risky("отчёт.pdf")); assertEquals(FileKind.PDF, FileNames.kind("отчёт.pdf"))
assertEquals("application/pdf", FileNames.mimeFor("a.pdf")); assertEquals("application/octet-stream", FileNames.mimeFor("a.unknownext"))
```
  `FileShareCheckTest` builds shares with a helper `share(size, partSizes, name = "a.pdf", thumb = ByteArray(0))` whose
  parts have 32-byte blob key/key/digest; part ciphertext sizes come from `BlobCipher.ciphertextSize(plainOfPart)`:
  valid 1 byte (1 part), valid `11 * SLICE` boundary (`size = MAX_FILE`, 11 parts); invalid: 0 parts, 12 parts,
  `size = 0`, `size = MAX_FILE + 1`, parts count ≠ `ceil(size / SLICE)`, a part ciphertext size off by one, a part
  > `MAX_PART_CIPHERTEXT`, a 31-byte key, thumbnail of 5000 bytes → Valid but thumbnail dropped. Use
  `FileShareCheck(slice = 1024)` in tests with small sizes, and one test with the real constants for the `MAX_FILE`
  boundary (pure arithmetic, no data).

- [ ] **Step 2: `BlobCipher.ciphertextSize`** (core/crypto):

```kotlin
    /** Exact ciphertext bytes Tink produces for [plaintext] bytes with this blob setup (D147 receiver checks). */
    fun ciphertextSize(plaintext: Long): Long = aead(ByteArray(32)).expectedCiphertextSize(plaintext)
```
  Add a test in core/crypto's `BlobCipherTest`: encrypt 0, 1, `SEGMENT - 1`, `SEGMENT`, `3 * SEGMENT + 5` bytes and
  compare file length with `ciphertextSize`.

- [ ] **Step 3: `FileNames.kt`**

```kotlin
package app.ottermsg.core.data.media

enum class FileKind { DOCUMENT, PDF, TABLE, ARCHIVE, AUDIO, VIDEO, APP, IMAGE, OTHER }

/** D147: everything the UI shows or decides about a received file comes from its sanitized name, never its mime. */
object FileNames {
    private val REMOVE = Regex("[\\u0000-\\u001F\\u007F-\\u009F/\\\\:\\u200B-\\u200F\\u202A-\\u202E\\u2066-\\u2069\\uFEFF]")
    private val RISKY = setOf("apk", "apks", "xapk", "exe", "msi", "bat", "cmd", "sh", "js", "jar", "vbs", "scr", "com", "ps1", "reg")
    private val KINDS = mapOf(
        FileKind.PDF to setOf("pdf"),
        FileKind.DOCUMENT to setOf("doc", "docx", "odt", "rtf", "txt", "md", "pages", "epub", "fb2"),
        FileKind.TABLE to setOf("xls", "xlsx", "ods", "csv", "numbers"),
        FileKind.ARCHIVE to setOf("zip", "rar", "7z", "tar", "gz", "xz", "bz2"),
        FileKind.AUDIO to setOf("mp3", "m4a", "aac", "ogg", "opus", "wav", "flac", "amr"),
        FileKind.VIDEO to setOf("mp4", "m4v", "mov", "mkv", "webm", "3gp", "avi"),
        FileKind.APP to setOf("apk", "apks", "xapk", "exe", "msi"),
        FileKind.IMAGE to setOf("jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "dng", "bmp"),
    )

    fun sanitize(raw: String): String {
        var s = REMOVE.replace(raw, "").trim().trimStart('.')
        if (s.length > FileLimits.MAX_NAME) {
            val ext = extension(s).let { if (it.isEmpty() || it.length > 10) "" else ".$it" }
            s = s.take(FileLimits.MAX_NAME - ext.length) + ext
        }
        return s.ifBlank { "файл" }
    }

    fun extension(name: String): String = name.substringAfterLast('.', "").lowercase()
    fun kind(name: String): FileKind = extension(name).let { e -> KINDS.entries.firstOrNull { e in it.value }?.key ?: FileKind.OTHER }
    fun risky(name: String): Boolean = extension(name) in RISKY
    /** For «Открыть в…»: from the extension; unknown → octet-stream. */
    fun mimeFor(name: String): String =
        android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension(name)) ?: "application/octet-stream"
}
```
  (`MimeTypeMap` works under Robolectric; if a JVM-only test needs it, keep the test in Robolectric.)

- [ ] **Step 4: `FileShareCheck.kt`**

```kotlin
package app.ottermsg.core.data.media

import app.ottermsg.core.crypto.BlobCipher
import app.ottermsg.proto.v1.FileShare

/** D147 receiver rules: anything else becomes «Не удалось прочитать файл» and nothing is downloaded. */
class FileShareCheck(private val slice: Long = FileLimits.SLICE, private val maxFile: Long = FileLimits.MAX_FILE) {
    sealed interface Result { data class Valid(val share: FileShare) : Result; data class Invalid(val reason: String) : Result }

    fun check(f: FileShare): Result {
        if (f.size !in 1..maxFile) return Result.Invalid("size ${f.size}")
        val expectedParts = ((f.size + slice - 1) / slice).toInt()
        if (f.partsCount != expectedParts || f.partsCount > FileLimits.MAX_PARTS) return Result.Invalid("parts ${f.partsCount}")
        f.partsList.forEachIndexed { i, p ->
            val plain = minOf(slice, f.size - i * slice)
            if (p.blobKey.size() != 32 || p.key.size() != 32 || p.digest.size() != 32) return Result.Invalid("part $i keys")
            if (p.size != BlobCipher.ciphertextSize(plain) || p.size > FileLimits.MAX_PART_CIPHERTEXT) return Result.Invalid("part $i size")
        }
        val b = f.toBuilder().setName(FileNames.sanitize(f.name)).setCaption(f.caption.take(4096))
        if (f.thumbnail.size() > 4096) b.clearThumbnail()
        return Result.Valid(b.build())
    }
}
```
- [ ] **Step 5:** Verify → PASS. `oc -am "files: name sanitizing, kinds, receiver checks (D147)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"` (add new files first).

---

### Task 4: Split-and-seal and the seekable multi-part reader

**Goal:** Turn an input stream into encrypted parts and read any plaintext range back across parts without writing plaintext.

**Files:**
- Create: `core/data/src/main/kotlin/app/ottermsg/core/data/media/FileSealer.kt`
- Create: `core/data/src/main/kotlin/app/ottermsg/core/data/media/MultiPartReader.kt`
- Modify: `core/crypto/.../BlobCipher.kt` (`seekable(file, key, aad)`)
- Test: `core/data/src/test/kotlin/app/ottermsg/core/data/FileSealerTest.kt`

**Acceptance Criteria:**
- [ ] `FileSealer(slice = 1024).seal(input, ...)` makes `ceil(n/1024)` parts, each part's ciphertext equals `ciphertextSize(plain)`, digests match `BlobCipher.sha256`.
- [ ] Input longer than `maxFile` → `TooLarge` and every written part file deleted; empty input → `Empty`.
- [ ] `MultiPartReader.read(offset, buf)` returns the right bytes for ranges inside one part, across a boundary, at the end; wrong key → `IOException`.

**Verify:** `$G :core:data:testDebugUnitTest --tests '*FileSealerTest'` → PASS

**Steps:**

- [ ] **Step 1: Failing tests** with random data of 0, 1, 1023, 1024, 1025, 5000 bytes and `slice = 1024`
  (`maxFile = 4096` for the TooLarge case): seal into a temp dir, then `MultiPartReader(parts, size = n, slice = 1024)` reads
  `[0, n)`, `[1000, 1100)` (crosses 1024), `[n-3, n)`; compare with the source. A part file with one flipped byte →
  read throws `IOException`.
- [ ] **Step 2: `BlobCipher.seekable`**

```kotlin
    /** Random-access plaintext of a blob file (D147 «Открыть в…»); tampering fails the read with an IOException. */
    fun seekable(file: File, key: ByteArray, aad: ByteArray): java.nio.channels.SeekableByteChannel =
        aead(key).newSeekableDecryptingChannel(java.io.RandomAccessFile(file, "r").channel, aad)
```
- [ ] **Step 3: `FileSealer.kt`**

```kotlin
package app.ottermsg.core.data.media

import app.ottermsg.core.crypto.BlobCipher
import java.io.File
import java.io.InputStream

/** D147: cuts a plaintext stream into slices and encrypts each into its own blob file with a fresh key. */
class FileSealer(private val slice: Long = FileLimits.SLICE, private val maxFile: Long = FileLimits.MAX_FILE) {
    class Part(val file: File, val key: ByteArray, val blobId: ByteArray, val blobKey: ByteArray, val sealed: BlobCipher.Sealed, val plain: Long)
    sealed interface Result { data class Ok(val parts: List<Part>, val size: Long) : Result; data object Empty : Result; data object TooLarge : Result }

    /** [newFile] gives a fresh file in filesDir/media; [blobKeyOf] maps a fresh 16-byte id to the blob key (author‖id). */
    fun seal(input: InputStream, newFile: () -> File, newId: () -> ByteArray, blobKeyOf: (ByteArray) -> ByteArray): Result {
        val parts = ArrayList<Part>()
        var total = 0L
        try {
            while (true) {
                val limited = LimitedStream(input, slice)
                val id = newId(); val blobKey = blobKeyOf(id); val key = BlobCipher.newKey(); val out = newFile()
                val sealed = BlobCipher.encrypt(limited, out, key, blobKey)
                if (limited.count == 0L) { out.delete(); break }
                total += limited.count
                parts += Part(out, key, id, blobKey, sealed, limited.count)
                if (total > maxFile) { parts.forEach { it.file.delete() }; return Result.TooLarge }
                if (limited.count < slice) break
            }
        } catch (e: Exception) { parts.forEach { it.file.delete() }; throw e }
        return if (parts.isEmpty()) Result.Empty else Result.Ok(parts, total)
    }

    private class LimitedStream(private val src: InputStream, private val limit: Long) : InputStream() {
        var count = 0L; private set
        override fun read(): Int = if (count >= limit) -1 else src.read().also { if (it >= 0) count++ }
        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (count >= limit) return -1
            val n = src.read(b, off, minOf(len.toLong(), limit - count).toInt())
            if (n > 0) count += n
            return n
        }
        override fun close() {} // the caller owns src
    }
}
```
  Note: a file whose size is an exact multiple of `slice` produces an extra empty attempt that is deleted (covered by
  the 1024-byte test). `maxFile + 1` bytes → the check after the part that crosses it returns TooLarge.
- [ ] **Step 4: `MultiPartReader.kt`** (package `app.ottermsg.core.data.media`, imports `BlobCipher`, `Closeable`, `File`, `ByteBuffer`, `SeekableByteChannel`):

```kotlin
class MultiPartReader(private val parts: List<Src>, val size: Long, private val slice: Long = FileLimits.SLICE) : Closeable {
    class Src(val file: File, val key: ByteArray, val blobKey: ByteArray)
    private val open = HashMap<Int, SeekableByteChannel>()

    /** Fills [dst] from plaintext [offset]; returns bytes read, -1 at the end. */
    @Synchronized fun read(offset: Long, dst: ByteArray, len: Int = dst.size): Int {
        if (offset >= size) return -1
        var done = 0
        while (done < len && offset + done < size) {
            val pos = offset + done
            val idx = (pos / slice).toInt()
            val ch = open.getOrPut(idx) { parts[idx].let { BlobCipher.seekable(it.file, it.key, it.blobKey) } }
            ch.position(pos - idx * slice)
            val want = minOf((len - done).toLong(), slice - (pos - idx * slice), size - pos).toInt()
            val n = ch.read(ByteBuffer.wrap(dst, done, want))
            if (n <= 0) throw java.io.IOException("short read in part $idx")
            done += n
        }
        return done
    }

    @Synchronized override fun close() { open.values.forEach { runCatching { it.close() } }; open.clear() }
}
```
- [ ] **Step 5:** Verify → PASS. `oc -am "files: split-and-seal into parts, seekable reader across parts (D147)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 5: Sending a file (queue, multi-part upload, expiry, retry, delete)

**Goal:** `sendFile` stores a FILE message with all parts sealed, uploads every part before releasing the envelope, and handles quota, retry and delete for parts.

**Files:**
- Modify: `core/data/src/main/kotlin/app/ottermsg/core/data/media/BlobMetaBuilder.kt` (`ttlMs` parameter)
- Modify: `core/data/src/main/kotlin/app/ottermsg/core/data/media/MediaTransfers.kt` (release only when all parts are up; fail all parts)
- Modify: `core/data/src/main/kotlin/app/ottermsg/core/data/messaging/MessageRepository.kt` (`sendFile`, `queueFile`, `dataContent` with file, `RETRYABLE`, `retry`, `deleteLocal`)
- Create: `core/data/src/main/kotlin/app/ottermsg/core/data/media/FileStore.kt` (interface + implementation pieces for sending)
- Test: `core/data/src/test/kotlin/app/ottermsg/core/data/FileFlowTest.kt` (FakeNode / TestGraph, like `PhotoFlowTest`)

**Acceptance Criteria:**
- [ ] A 3-part file (test slice 1 KiB): message PENDING with 3 UPLOADING parts and one **held** outbox row; the envelope is not submitted until the third part is on the node; then it carries `DataMessage.file` with 3 parts and the fallback text «📎 Файл: a.pdf (2,9 КБ) — обновите Otter, чтобы открыть».
- [ ] Each part's `BLOB_META` expires `created + 7 days`; photos keep 30 days.
- [ ] QUOTA on part 2 → every part UPLOAD_FAILED, message FAILED, outbox row gone; «Повторить» re-signs all failed parts with the same ids and the upload completes.
- [ ] Deleting the message deletes every part file.
- [ ] Not enough free space → `SendResult.NoSpace`; > 1 GiB → `TooLarge`; empty → `Empty`; unreadable URI → `Unreadable`.

**Verify:** `$G :core:data:testDebugUnitTest --tests '*FileFlowTest' --tests '*PhotoFlowTest'` → PASS

**Steps:**

- [ ] **Step 1: Failing tests** in `FileFlowTest` (copy the graph setup of `PhotoFlowTest`; inject `FileSealer(slice = 1024)` through the repository's constructor parameter added below): send 3000 bytes → assert parts/outbox held/`FakeNode` received no envelope; run `MediaTransfers.drainOnce` → envelope present, parse its `Content` → `data.file.partsCount == 3`, `data.text` starts with «📎 Файл: a.pdf»; meta records' `expiresMs - createdMs == FileLimits.PART_TTL_MS`. Quota case: `FakeNode` answers `blobCreate` for the second blob with QUOTA (use its existing answer hook) → states as in the criteria; clear the hook, `retry(localId)` → completes. Delete case. Free-space case through a `FreeSpace` fake returning 0.

- [ ] **Step 2: BlobMetaBuilder.** `build(id, me, file, readers, now, ttlMs: Long = TTL_MS)` and `resign(old, me, now, ttlMs: Long = TTL_MS)`; use `now + ttlMs`.

- [ ] **Step 3: FileStore interface** (used by the UI; implemented by `MessageRepository` for sending and by `MediaRepository` for the rest in Task 7):

```kotlin
package app.ottermsg.core.data.media

import android.net.Uri

enum class SendFileResult { Ok, Empty, TooLarge, NoSpace, Unreadable, NotAllowed }

/** D147: what the conversation and media screens need for files (a fake in UI tests). */
interface FileSender {
    /** Seals [uri] (or the photo at [file], original quality) into parts and queues the message; returns the local id on Ok. */
    suspend fun sendFile(conversationId: Long, uri: Uri, caption: String): Pair<SendFileResult, Long?>
    suspend fun sendOriginalPhoto(conversationId: Long, file: java.io.File, caption: String): Pair<SendFileResult, Long?>
}

/** Free bytes on the data partition (fake in tests). */
fun interface FreeSpace { fun bytes(): Long }
```
  Provide `FreeSpace { android.os.StatFs(context.filesDir.path).availableBytes }` in the Hilt module that provides
  `MediaFiles`.

- [ ] **Step 4: MessageRepository.sendFile.** Add constructor params `private val sealer: FileSealer = FileSealer()`,
  `private val freeSpace: FreeSpace = FreeSpace { Long.MAX_VALUE }`; implement `FileSender`:

```kotlin
    override suspend fun sendFile(conversationId: Long, uri: Uri, caption: String): Pair<SendFileResult, Long?> {
        val (name, declared) = withContext(Dispatchers.IO) { queryNameAndSize(uri) }      // OpenableColumns; size may be -1
        if (declared > FileLimits.MAX_FILE) return SendFileResult.TooLarge to null
        if (declared > 0 && freeSpace.bytes() < declared + FileLimits.FREE_SPACE_MARGIN) return SendFileResult.NoSpace to null
        val input = withContext(Dispatchers.IO) { runCatching { files.resolver.openInputStream(uri) }.getOrNull() }
            ?: return SendFileResult.Unreadable to null
        return input.use { sendStream(conversationId, it, FileNames.sanitize(name), caption, thumb = null, w = 0, h = 0, original = false) }
    }
```
  `sendOriginalPhoto` does the same from a `File` after `ExifStripper` (Task 9) with `original = true`, thumbnail and
  dimensions from `PhotoPrep`'s thumbnail helper. `sendStream`:
  1. resolves readers exactly like `sendPhoto` (group membership check → `NotAllowed`);
  2. `withContext(IO) { sealer.seal(input, { files.file(files.newName()) }, { ByteArray(16).also(rng::nextBytes) }, { BlobMetaBuilder.blobKey(me.userId, it) }) }`;
     `Empty`/`TooLarge` → return that; IO error → `Unreadable`;
  3. builds one `AttachmentEntity` per part: `partIndex = i`, `mime = FileNames.mimeFor(name)`, `size = sealed.size`,
     `digest = sealed.sha256`, `file = part.file.name`, `state = UPLOADING`,
     `metaRecord = BlobMetaBuilder.build(part.blobId, me, part.file, readers, now, FileLimits.PART_TTL_MS).toByteArray()`;
  4. `queueFile(...)`: like `queuePhoto` but kind `MessageKind.FILE`, `body = caption.trim()`,
     `systemData = FileShare` **without** `parts` (name, mime, size, thumbnail, width, height, caption, original_photo),
     inserts all parts, and the outbox content from
     `dataContent(messageId, fallbackText(name, size, caption), now, gid, file = fileShareWithParts)`.

```kotlin
    internal fun fallbackText(name: String, size: Long, caption: String): String =
        "📎 Файл: $name (${humanSize(size)}) — обновите Otter, чтобы открыть" + if (caption.isBlank()) "" else "\n${caption.trim()}"
```
  (`humanSize`: Russian units «Б/КБ/МБ/ГБ», one decimal under 10, comma as separator — put it in `FileNames` with a
  test: 2 400 000 → «2,3 МБ», 1 073 741 824 → «1 ГБ».)
  `dataContent` gains `file: FileShare? = null` → `.apply { if (file != null) setFile(file) }`.

- [ ] **Step 5: MediaTransfers.upload** — replace the success transaction with:

```kotlin
            db.withTransaction {
                dao.update(a.copy(state = AttachmentState.UPLOADED, doneChunks = st.chunks, attempts = 0))
                // D147: a file's envelope waits for every part (photos have one part)
                if (dao.notUploaded(a.messageLocalId) == 0) db.outboxDao().release(a.messageLocalId, clock.now())
            }
```
  and the failure branch with: every part of the message `UPLOADING` → `UPLOAD_FAILED` (`dao.parts(m)`), then
  `markFailed` and `deleteForMessage` as today.
- [ ] **Step 6: retry / delete.** In `retry(localId)`: for FILE (add `MessageKind.FILE` to `RETRYABLE`) iterate
  `dao.parts(localId)`; each `UPLOAD_FAILED` part → `resign(old, me, now, FileLimits.PART_TTL_MS)`, state UPLOADING,
  attempts 0; recreate the held outbox row from the original content (follow exactly what the photo retry does today
  and apply it to all parts). `deleteLocal`: delete `files.file(name)` and `files.part(name)` for **every** part.
- [ ] **Step 7:** Verify → PASS. `oc -am "files: send in parts, envelope after the last part, 7-day expiry, retry and delete (D147)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 6: Receiving a file

**Goal:** 1:1 and group receivers store FILE messages with REMOTE parts after `FileShareCheck`; hostile shares become a «Не удалось прочитать файл» bubble; previews, notifications and receipts know FILE.

**Files:**
- Modify: `core/data/src/main/kotlin/app/ottermsg/core/data/media/IncomingAttachments.kt` (`fileOrNull`, `insertParts`)
- Modify: `core/data/src/main/kotlin/app/ottermsg/core/data/messaging/MailboxReceiver.kt:158-180`, `GroupReceiver.kt:205-222`
- Modify: `core/database/.../dao/MessageDao.kt:31` (add FILE), `app/src/main/java/app/ottermsg/notify/NotificationContent.kt:27-35`, `app/src/main/res/values*/strings.xml` (`notif_file`)
- Modify: `feature/chats/src/main/kotlin/app/ottermsg/feature/chats/ChatListViewModel.kt` (+ strings): «📎 Файл» / «📎 {caption}» / group author prefix
- Test: `core/data/src/test/kotlin/app/ottermsg/core/data/FileReceiveTest.kt`, `app/src/test/.../notify/NotificationContentTest.kt`, `feature/chats/src/test/.../ChatRowFileTest.kt`

**Acceptance Criteria:**
- [ ] A valid share from a contact (1:1) and from a group member: message kind FILE, `body` = caption, `systemData` = sanitized share without part keys, parts stored REMOTE with `auto = false` (files never auto-download), unread +1, DELIVERED receipt queued.
- [ ] Every hostile share from Task 3's list: message kind FILE with **no** attachment rows (UI: «Не удалось прочитать файл»), nothing downloaded, receipt still sent.
- [ ] A message with both `file` and `attachments` (photo) is handled as a file; the photo attachment is ignored.
- [ ] Notification line «📎 отчёт.pdf» (caption appended «📎 отчёт.pdf: подпись»); chat list preview «📎 Файл» / «📎 подпись».

**Verify:** `$G :core:data:testDebugUnitTest --tests '*FileReceiveTest'` and `$G :app:testDebugUnitTest --tests '*NotificationContentTest'` and `$G :feature:chats:testDebugUnitTest` → PASS

**Steps:**

- [ ] **Step 1: Failing tests.** `FileReceiveTest` (two `TestGraph`s on one `FakeNode`, like `MessagingFlowTest`/
  `GroupFlowTest`): Anna sends a real 3-part file (slice 1 KiB) → Boris has FILE + 3 REMOTE parts; Boris taps download
  (`MediaRepository.downloadFile(localId)`, Task 7 — for now set parts QUEUED directly) → after `drainOnce` all
  DOWNLOADED, reader returns the original bytes. Hostile: a fake sender (the existing forged-envelope helpers of
  `ForgedEnvelopeTest`) sends `FileShare`s with 12 parts / wrong part size / `size = 2 GiB` / name `../../x` →
  kinds and rows as in the criteria, sanitized name stored for the `../../x` case (valid otherwise).
- [ ] **Step 2: IncomingAttachments.**

```kotlin
    /** D147: the checked file of [d], or null when [d] has none. Invalid shares come back as Invalid (shown, never fetched). */
    fun fileOrNull(d: DataMessage, check: FileShareCheck = FileShareCheck()): FileShareCheck.Result? =
        if (d.hasFile()) check.check(d.file) else null

    suspend fun insertParts(db: OtterDatabase, files: MediaFiles, localId: Long, f: FileShare) {
        f.partsList.forEachIndexed { i, p ->
            db.attachmentDao().insert(AttachmentEntity(messageLocalId = localId, partIndex = i, blobKey = p.blobKey.toByteArray(),
                key = p.key.toByteArray(), digest = p.digest.toByteArray(), size = p.size, mime = FileNames.mimeFor(f.name),
                width = f.width, height = f.height, thumb = if (i == 0) f.thumbnail.toByteArray().takeIf { it.isNotEmpty() } else null,
                file = files.newName(), state = AttachmentState.REMOTE, auto = false))
        }
    }

    /** What the message row keeps: the share without part keys. */
    fun stored(f: FileShare): ByteArray = f.toBuilder().clearParts().build().toByteArray()
```
  `IncomingPhotos` gets `suspend fun storeFile(localId: Long, f: FileShare) = IncomingAttachments.insertParts(db, files, localId, f)`.
- [ ] **Step 3: Receivers** (both, same shape). Before `photo`:

```kotlin
                val file = IncomingAttachments.fileOrNull(d)
                val photo = if (file == null) IncomingAttachments.photoOrNull(d) else null
                val loc = if (photo == null && file == null) LiveLocationApplier.locationOf(d) else null
```
  kind: `file != null -> MessageKind.FILE`; body: for a file `(file as? Valid)?.share?.caption ?: ""`; systemData:
  `Valid → IncomingAttachments.stored(share)`, `Invalid → null`. After insert: `if (file is FileShareCheck.Result.Valid) photos.storeFile(id, file.share)`.
- [ ] **Step 4:** `MessageDao.unreadReceiptsPending`: add `${MessageKind.FILE}` to the kind list. `NotificationContent`:
  `MessageKind.FILE -> fileLine(m)` = «📎 {name}» (+ «: caption»), name parsed from `systemData` (`FileShare.parseFrom`,
  fallback «Файл»); add FILE to `SHOWN`; new constructor label `fileLabel` passed from `MessageNotifier` like
  `locationLabel`. Lock-screen behaviour is unchanged (D121 shows nothing).
- [ ] **Step 5:** Chat list: `ChatRow.file: Boolean`; preview «📎 Файл» or «📎 {caption}»; author prefix in groups as
  for PHOTO (add FILE to the author condition at l.99). Strings ru/en `chats_preview_file` «📎 Файл» / "📎 File",
  `chats_preview_file_caption` «📎 %1$s».
- [ ] **Step 6:** Verify → PASS. `oc -am "files: receive with checks, hostile shares never fetched, previews and notifications (D147)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 7: Download, open, save, share (no plaintext on disk)

**Goal:** Users download a file on tap, open it in another app through a decrypting proxy descriptor, save it to Downloads or share it.

**Files:**
- Modify: `core/data/src/main/kotlin/app/ottermsg/core/data/media/MediaRepository.kt` (implements `FileStore`)
- Modify: `core/data/src/main/kotlin/app/ottermsg/core/data/media/FileStore.kt` (add `FileStore`)
- Create: `core/data/src/main/kotlin/app/ottermsg/core/data/media/DownloadsSaver.kt`
- Create: `app/src/main/java/app/ottermsg/files/FileContentProvider.kt`; modify `app/src/main/AndroidManifest.xml`
- Test: `core/data/src/test/.../FileStoreTest.kt`, `app/src/test/kotlin/app/ottermsg/files/FileContentProviderTest.kt`

**Acceptance Criteria:**
- [ ] `downloadFile(m)` sets every REMOTE/FAILED part QUEUED; `cancel(m)`: incoming → QUEUED parts back to REMOTE and `.part` files deleted; outgoing PENDING → message and parts deleted (same as delete).
- [ ] `observeFile(m)` emits `FileUi(name, size, kind, risky, state, progress 0..1)` combining all parts (any FAILED → FAILED, any GONE → GONE, all DOWNLOADED/UPLOADED → READY, else MOVING with Σ done chunks / Σ chunks).
- [ ] `FileContentProvider` serves `content://app.ottermsg.filecontent/<localId>/<sanitized-name>`: `openFile("r")` returns a proxy FD whose reads equal the original bytes (Robolectric test via `MultiPartReader`-backed callback logic tested directly); `query` returns `DISPLAY_NAME` and `SIZE`; `getType` = `FileNames.mimeFor`; any other mode → `FileNotFoundException`; not exported.
- [ ] `saveToDownloads(m)` writes the plaintext through MediaStore Downloads (API 29+) or `Environment.DIRECTORY_DOWNLOADS` (26–28, permission asked by the UI); name collision → «name (2).ext».

**Verify:** `$G :core:data:testDebugUnitTest --tests '*FileStoreTest'` and `$G :app:testDebugUnitTest --tests '*FileContentProviderTest'` → PASS

**Steps:**

- [ ] **Step 1: Failing tests** for the criteria (Robolectric for MediaStore; the proxy-FD callback is a separate class
  `PlainCallback(reader: MultiPartReader) : ProxyFileDescriptorCallback` tested by calling `onRead` directly, because
  Robolectric does not implement `openProxyFileDescriptor`).
- [ ] **Step 2: Interface** (append to `FileStore.kt`):

```kotlin
enum class FileState { REMOTE, MOVING, READY, FAILED, GONE, NOT_IN_BACKUP, INVALID }
data class FileUi(val name: String, val size: Long, val kind: FileKind, val risky: Boolean, val state: FileState,
                  val progress: Float, val outgoing: Boolean, val original: Boolean, val thumb: ByteArray?)

interface FileStore {
    fun observeFile(localId: Long): kotlinx.coroutines.flow.Flow<FileUi?>
    suspend fun downloadFile(localId: Long)
    suspend fun cancel(localId: Long)
    /** content:// URI for ACTION_VIEW / ACTION_SEND (read grant added by the caller), or null when not READY. */
    suspend fun contentUri(localId: Long): android.net.Uri?
    fun downloadsNeedPermission(): Boolean
    suspend fun saveToDownloads(localId: Long): Boolean
}
```
  `FileUi` is built from the message's `systemData` (`FileShare`), `dao.observeParts(m)` and `outgoing`; no rows and
  not restored → INVALID; a single NOT_IN_BACKUP row → NOT_IN_BACKUP.
- [ ] **Step 3: Provider** (`app/.../files/FileContentProvider.kt`):

```kotlin
/** D147: plaintext of a stored file for another app, decrypted on demand; nothing is written to disk. */
class FileContentProvider : ContentProvider() {
    @dagger.hilt.EntryPoint @dagger.hilt.InstallIn(dagger.hilt.components.SingletonComponent::class)
    interface Deps { fun db(): OtterDatabase; fun files(): MediaFiles }
    private val thread by lazy { android.os.HandlerThread("otter-files").apply { start() } }

    override fun onCreate() = true
    override fun getType(uri: Uri) = FileNames.mimeFor(uri.lastPathSegment ?: "")
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw FileNotFoundException("read only")
        val localId = uri.pathSegments.firstOrNull()?.toLongOrNull() ?: throw FileNotFoundException()
        val deps = dagger.hilt.android.EntryPointAccessors.fromApplication(context!!, Deps::class.java)
        val reader = runBlocking { FileReaders.open(deps.db(), deps.files(), localId) } ?: throw FileNotFoundException()
        val sm = context!!.getSystemService(StorageManager::class.java)
        return sm.openProxyFileDescriptor(ParcelFileDescriptor.MODE_READ_ONLY, PlainCallback(reader), android.os.Handler(thread.looper))
    }
    override fun query(uri: Uri, projection: Array<out String>?, s: String?, a: Array<out String>?, o: String?): Cursor {
        val localId = uri.pathSegments.firstOrNull()?.toLongOrNull() ?: return MatrixCursor(emptyArray())
        val deps = dagger.hilt.android.EntryPointAccessors.fromApplication(context!!, Deps::class.java)
        val share = runBlocking { deps.db().messageDao().get(localId) }?.takeIf { it.kind == MessageKind.FILE }
            ?.systemData?.let { runCatching { FileShare.parseFrom(it) }.getOrNull() } ?: return MatrixCursor(emptyArray())
        return MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)).apply { addRow(arrayOf(share.name, share.size)) }
    }
    override fun insert(uri: Uri, values: ContentValues?) = null
    override fun update(uri: Uri, v: ContentValues?, s: String?, a: Array<out String>?) = 0
    override fun delete(uri: Uri, s: String?, a: Array<out String>?) = 0
}

class PlainCallback(private val reader: MultiPartReader) : ProxyFileDescriptorCallback() {
    override fun onGetSize() = reader.size
    override fun onRead(offset: Long, size: Int, data: ByteArray): Int =
        try { reader.read(offset, data, size).coerceAtLeast(0) } catch (e: IOException) { throw ErrnoException("read", OsConstants.EIO) }
    override fun onRelease() = reader.close()
}
```
  `FileReaders.open(db, files, localId)` (core/data) returns a `MultiPartReader` only when the message is FILE and every
  part is DOWNLOADED (incoming) or UPLOADING/UPLOADED (outgoing originals are on disk from the start). Manifest:

```xml
        <provider android:name=".files.FileContentProvider" android:authorities="${applicationId}.filecontent"
            android:exported="false" android:grantUriPermissions="true" />
```
  `contentUri(m)` = `content://${packageName}.filecontent/$m/${Uri.encode(name)}`. Callers add
  `FLAG_GRANT_READ_URI_PERMISSION`; the conversation screen revokes grants (`context.revokeUriPermission`) when the
  app lock engages (hook into the existing `hideAll()` path of D121).
- [ ] **Step 4: DownloadsSaver** — follow `GallerySaver`'s structure: API 29+ `MediaStore.Downloads.EXTERNAL_CONTENT_URI`
  with `IS_PENDING` 1 → copy plaintext from `MultiPartReader` in 1 MiB steps → `IS_PENDING` 0; API 26–28 write to
  `Environment.getExternalStoragePublicDirectory(DIRECTORY_DOWNLOADS)` with a unique name.
- [ ] **Step 5:** Verify → PASS. `oc -am "files: download on tap, open through a decrypting proxy descriptor, save to Downloads (D147)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 8: Transfer service (lease only while parts move)

**Goal:** A `dataSync` foreground service with progress and «Отменить» keeps the connection only while file parts upload or download.

**Files:**
- Create: `core/data/src/main/kotlin/app/ottermsg/core/data/media/TransferLink.kt` (lease seam like `CallLink`)
- Modify: `core/database/.../dao/AttachmentDao.kt` (`observeActiveFileTransfers()`)
- Create: `app/src/main/java/app/ottermsg/files/FileTransferService.kt`, `app/src/main/java/app/ottermsg/files/TransferWatcher.kt`
- Modify: `app/src/main/AndroidManifest.xml` (service, `FOREGROUND_SERVICE_DATA_SYNC`), `app/.../notify/Channels.kt` (channel `transfers`, LOW), `app/src/main/res/values*/strings.xml`, `OtterApp` (start the watcher)
- Test: `app/src/test/kotlin/app/ottermsg/files/FileTransferServiceTest.kt`, `TransferWatcherTest.kt`

**Acceptance Criteria:**
- [ ] With an active FILE part (UPLOADING or QUEUED), the watcher starts the service; the service acquires lease `transfer` and shows «Отправка файла · 35 %» / «Загрузка файла · 35 %» with the file name and «Отменить».
- [ ] When the last active part ends (any state), the service releases the lease and stops within 1 s; `SyncEngine.holds("transfer")` is false afterwards (no keep-alive).
- [ ] «Отменить» calls `FileStore.cancel` for the file shown; a refused FGS start (background start not allowed) leaves transfers to the existing leases, no crash; `onTimeout` (Android 15) stops cleanly.
- [ ] Photos alone never start the service.

**Verify:** `$G :app:testDebugUnitTest --tests '*FileTransferServiceTest' --tests '*TransferWatcherTest'` → PASS

**Steps:**

- [ ] **Step 1: Failing tests** (Robolectric `ServiceController`, a fake `TransferLink` recording acquire/release, an
  in-memory DB with one FILE part UPLOADING → service foreground + acquired; set it UPLOADED → released + stopped).
- [ ] **Step 2: DAO**

```kotlin
    /** D148: file parts that still move (photos excluded): drives the transfer notification. */
    @Query("""SELECT a.* FROM attachments a JOIN messages m ON m.local_id = a.message_local_id
              WHERE m.kind = ${MessageKind.FILE} AND a.state IN (${AttachmentState.UPLOADING}, ${AttachmentState.QUEUED})""")
    fun observeActiveFileTransfers(): Flow<List<AttachmentEntity>>
```
- [ ] **Step 3: TransferLink** (`core/data`):

```kotlin
/** D148: the transfer service's hold on the node connection (only while file parts move). */
interface TransferLink { fun acquire(); fun release() }
class EngineTransferLink @Inject constructor(private val engine: dagger.Lazy<SyncEngine>) : TransferLink {
    override fun acquire() = engine.get().acquire(TAG)
    override fun release() = engine.get().release(TAG)
    companion object { const val TAG = "transfer" }
}
```
  Bind it in the data Hilt module next to `CallLink`.
- [ ] **Step 4: Service** — model on `LiveLocationService` (same `enterForeground` with `ServiceCompat.startForeground(..., FOREGROUND_SERVICE_TYPE_DATA_SYNC)`,
  `START_NOT_STICKY`, `onTimeout` → stop). In `onCreate` collect `observeActiveFileTransfers()` combined with
  message rows: empty → `link.release(); stopSelf()`; else update the notification (first active message: direction,
  name, percent of Σ done chunks over Σ chunks). Action `ACTION_CANCEL` with `EXTRA_LOCAL_ID` → `fileStore.cancel(id)`.
  `link.acquire()` once after `startForeground` succeeds; `onDestroy` → `link.release()` (idempotent).
- [ ] **Step 5: TransferWatcher** (`@Singleton`, started from `OtterApp.onCreate`): collects
  `observeActiveFileTransfers().map { it.isNotEmpty() }.distinctUntilChanged()`; on `true` → `ContextCompat.startForegroundService`
  inside `try/catch (ForegroundServiceStartNotAllowedException | IllegalStateException)` (log and continue).
- [ ] **Step 6:** Manifest: `<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />`,
  `<service android:name=".files.FileTransferService" android:foregroundServiceType="dataSync" android:exported="false" />`.
  Strings ru/en: `transfer_upload` «Отправка файла · %1$d %%», `transfer_download` «Загрузка файла · %1$d %%»,
  `transfer_cancel` «Отменить», `notif_channel_transfers` «Передача файлов».
- [ ] **Step 7:** Verify → PASS. `oc -am "files: transfer notification holds the connection only while parts move (D148)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 9: Original-quality photos without location (ExifStripper)

**Goal:** «Без сжатия» sends the original photo as a file with GPS and camera details removed, or asks when the format can't be cleaned.

**Files:**
- Create: `core/data/src/main/kotlin/app/ottermsg/core/data/media/ExifStripper.kt`
- Modify: `core/data/build.gradle.kts` (`androidx.exifinterface` from the version catalog; add it to `libs.versions.toml` if missing, latest stable 1.4.x)
- Modify: `core/data/.../messaging/MessageRepository.kt` (`sendOriginalPhoto`)
- Test: `core/data/src/test/kotlin/app/ottermsg/core/data/ExifStripperTest.kt` (+ a small JPEG fixture with GPS in `src/test/resources/exif/gps.jpg`, generated in the test with `ExifInterface` from a 16×16 JPEG — never a real photo)

**Acceptance Criteria:**
- [ ] JPEG/PNG/WebP: after `strip(file)` no `GPS*`, `Make`, `Model`, `BodySerialNumber`, `CameraOwnerName`, `Artist`, `MakerNote`, `UserComment`, XMP and no embedded thumbnail; `Orientation` unchanged; pixel data unchanged (decode both, compare).
- [ ] HEIC/DNG/other → `Stripper.Result.Unsupported` (the UI asks).
- [ ] `sendOriginalPhoto` sends `FileShare.original_photo = true` with the 64-px thumbnail and dimensions.

**Verify:** `$G :core:data:testDebugUnitTest --tests '*ExifStripperTest'` → PASS

**Steps:**

- [ ] **Step 1: Failing test**: create a 16×16 JPEG with `Bitmap.compress`, write GPS lat/lon, Make, Model, Orientation=6,
  BodySerialNumber with `ExifInterface.saveAttributes()`; `strip` → assert as in the criteria.
- [ ] **Step 2: Implementation**

```kotlin
/** D147: removes location and camera identity from an original photo in place; pixels untouched. */
object ExifStripper {
    enum class Result { Stripped, Unsupported }
    private val TAGS = listOf(
        ExifInterface.TAG_GPS_LATITUDE, ExifInterface.TAG_GPS_LATITUDE_REF, ExifInterface.TAG_GPS_LONGITUDE, ExifInterface.TAG_GPS_LONGITUDE_REF,
        ExifInterface.TAG_GPS_ALTITUDE, ExifInterface.TAG_GPS_ALTITUDE_REF, ExifInterface.TAG_GPS_TIMESTAMP, ExifInterface.TAG_GPS_DATESTAMP,
        ExifInterface.TAG_GPS_PROCESSING_METHOD, ExifInterface.TAG_GPS_AREA_INFORMATION, ExifInterface.TAG_GPS_IMG_DIRECTION,
        ExifInterface.TAG_GPS_IMG_DIRECTION_REF, ExifInterface.TAG_GPS_SPEED, ExifInterface.TAG_GPS_SPEED_REF, ExifInterface.TAG_GPS_TRACK,
        ExifInterface.TAG_GPS_TRACK_REF, ExifInterface.TAG_GPS_DEST_LATITUDE, ExifInterface.TAG_GPS_DEST_LONGITUDE, ExifInterface.TAG_GPS_VERSION_ID,
        ExifInterface.TAG_MAKE, ExifInterface.TAG_MODEL, ExifInterface.TAG_BODY_SERIAL_NUMBER, ExifInterface.TAG_CAMERA_OWNER_NAME,
        ExifInterface.TAG_LENS_MAKE, ExifInterface.TAG_LENS_MODEL, ExifInterface.TAG_LENS_SERIAL_NUMBER, ExifInterface.TAG_ARTIST,
        ExifInterface.TAG_MAKER_NOTE, ExifInterface.TAG_USER_COMMENT, ExifInterface.TAG_IMAGE_UNIQUE_ID, ExifInterface.TAG_XMP,
        ExifInterface.TAG_SOFTWARE, ExifInterface.TAG_COPYRIGHT,
    )

    fun strip(file: File, mime: String): Result {
        if (mime !in setOf("image/jpeg", "image/png", "image/webp")) return Result.Unsupported
        val exif = ExifInterface(file)
        TAGS.forEach { exif.setAttribute(it, null) }
        exif.saveAttributes()
        return Result.Stripped
    }
}
```
  The embedded EXIF thumbnail: `ExifInterface` drops it when its tags are cleared (`TAG_JPEG_INTERCHANGE_FORMAT*`);
  assert `exif.hasThumbnail() == false` in the test and clear those two tags too if it isn't. If any assertion fails
  for PNG/WebP with the library version used, return `Unsupported` for that type and note it in the test.
  Detect the real type from the file header (`BitmapFactory.Options.inJustDecodeBounds` → `outMimeType`), never from
  the picker's name.
- [ ] **Step 3:** `sendOriginalPhoto(cid, file, caption, asIs: Boolean = false)`: detect mime → unless `asIs`, `strip`;
  `Unsupported` → return the new `SendFileResult.NeedsChoice` (add it to the enum) so the UI asks; «Отправить как есть»
  calls again with `asIs = true`; «Сжать» uses today's `sendPhoto`.
  Thumbnail and dimensions: reuse `PhotoPrep`'s thumbnail function (make it `internal`/public if private).
- [ ] **Step 4:** Verify → PASS. `oc -am "files: original-quality photos without location or camera details (D147)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 10: Conversation UI — «Файл», preview, bubble, warning, menu, «Без сжатия»

**Goal:** Everything in mockups 1, 2 and 8 B inside the chat screen.

**Files:**
- Modify: `feature/conversation/.../MessageComposer.kt` (third item «Файл», `onPickFile`)
- Create: `feature/conversation/.../FilePreviewSheet.kt`, `FileBubble.kt`, `RiskyFileDialog.kt`
- Modify: `feature/conversation/.../PhotoPreview.kt` (switch), `ConversationViewModel.kt`, `ConversationScreen.kt` (bubble, menu, open/save/share, dialogs), strings ru/en
- Modify: `AppNavHost.kt` / `ConversationRoute` wiring only if a new callback is needed
- Test: `feature/conversation/src/test/.../FileBubbleTest.kt`, `FileSendTest.kt`, `AttachMenuTest.kt` (extend)

**Acceptance Criteria:**
- [ ] 📎 menu has «Фото», «Файл», «Местоположение» in that order; «Файл» launches `OpenDocument(arrayOf("*/*"))`.
- [ ] Picked file → sheet with type icon, name, size, caption field, «Отправить»/«Отмена»; results map to snackbars: TooLarge «Файл больше 1 ГБ — отправить нельзя», NoSpace «Недостаточно места на телефоне», Unreadable/Empty «Не удалось прочитать файл», NotAllowed «Вы не участник этой группы».
- [ ] Photo preview shows «Без сжатия» (default off, hint text); on → `sendOriginalPhoto`; `NeedsChoice` → dialog «Местоположение из этого формата убрать нельзя» with «Сжать» / «Отправить как есть» / «Отмена».
- [ ] File bubble renders every `FileState` (REMOTE download button «2,4 МБ · PDF», MOVING progress + «Отправка · 84 из 240 МБ» / «Загрузка · …» + cancel, READY tap-to-open, FAILED «Повторить», GONE «Файл больше недоступен — попросите отправить снова», NOT_IN_BACKUP «Файл не входит в резервную копию», INVALID «Не удалось прочитать файл»); original photo shows its thumbnail and «без сжатия»; TalkBack description includes name, size and state.
- [ ] Tap on READY: risky → `RiskyFileDialog` first (names the sender); else `ACTION_VIEW` with the content URI + read grant, chooser «Открыть в…»; no app → snackbar «Нет приложения, чтобы открыть этот файл».
- [ ] Long press on READY adds «Сохранить в Загрузки» (asks storage permission on 8–9) and «Поделиться» (`ACTION_SEND`, chooser).
- [ ] Roborazzi light/dark: bubble states (`file_bubble_*`), preview sheet, «Без сжатия» preview, risky dialog.

**Verify:** `$G :feature:conversation:testDebugUnitTest` → PASS; PNGs in `feature/conversation/build/outputs/roborazzi/`

**Steps:**

- [ ] **Step 1: Strings** (ru; en equivalents in `values-en`): `conv_attach_file` «Файл», `file_send` «Отправить»,
  `file_caption` «Подпись», `file_too_large` «Файл больше 1 ГБ — отправить нельзя», `file_no_space` «Недостаточно места
  на телефоне», `file_unreadable` «Не удалось прочитать файл», `file_not_member` «Вы не участник этой группы»,
  `file_download_size` «%1$s · %2$s», `file_uploading` «Отправка · %1$s из %2$s», `file_downloading` «Загрузка · %1$s из %2$s»,
  `file_gone` «Файл больше недоступен — попросите отправить снова», `file_not_in_backup` «Файл не входит в резервную копию»,
  `file_invalid` «Не удалось прочитать файл», `file_original` «без сжатия», `file_retry` «Повторить», `file_cancel` «Отменить»,
  `file_open_with` «Открыть в…», `file_no_app` «Нет приложения, чтобы открыть этот файл», `file_save_downloads`
  «Сохранить в Загрузки», `file_saved` «Сохранено в «Загрузки»», `file_share` «Поделиться», `photo_original` «Без сжатия»,
  `photo_original_hint` «Оригинал как файл. Геометка и данные камеры будут удалены», `photo_strip_unsupported_title`
  «Местоположение из этого формата убрать нельзя», `photo_strip_compress` «Сжать», `photo_strip_send_as_is`
  «Отправить как есть», `risky_title` «Открыть файл приложения?», `risky_text` «Этот файл может установить приложение или
  изменить телефон. Открывайте, только если доверяете отправителю — %1$s. Обновления Otter приходят только через
  «Новости Выдры».», `risky_open` «Всё равно открыть», `risky_cancel` «Отмена».
- [ ] **Step 2: Failing tests**: `FileBubbleTest` renders `FileBubble(FileUi(...))` for each state and asserts the
  texts above + screenshots; `FileSendTest` drives the VM with a fake `FileSender`/`FileStore` (results → snackbar
  events; NeedsChoice → dialog state); `AttachMenuTest` asserts the three items and order.
- [ ] **Step 3: Composer**: add `onPickFile: () -> Unit = {}` and a `DropdownMenuItem` with
  `Icons.Outlined.Description` between photo and location.
- [ ] **Step 4: VM** (`ConversationViewModel`): new constructor params `files: FileSender = FileSender.NONE`,
  `fileStore: FileStore = FileStore.NONE` (add `NONE` objects to the interfaces); state `pendingFile: Uri?` (savedState,
  as `pendingPhoto`) with name/size read via `ContentResolver` in the route; `sendFile(caption)`,
  `sendPhoto(caption, original: Boolean)`, `stripChoice: StateFlow<String?>` for the dialog, `fileEvents` for snackbars,
  `observeFile(localId)` passthrough, `downloadFile`, `cancelFile`, `openFile` (returns URI), `saveFile`.
  **Important**: the picked `Uri` must be sealed before the grant is lost: call `sendFile` straight from the sheet's
  «Отправить»; if the process died while the sheet was open, the saved `Uri` may be unreadable → `Unreadable` snackbar.
- [ ] **Step 5: FileBubble** (`FileBubble.kt`): layout from mockup 1 (44 dp round action / type tile, name one line
  with middle ellipsis via `TextOverflow.MiddleEllipsis` when available, else end ellipsis; meta line; caption below;
  time/ticks via the existing `MessageMeta`). Type icon by `FileKind` (Material outlined: `PictureAsPdf`, `Description`,
  `TableChart`, `FolderZip`, `AudioFile`, `VideoFile`, `Android`, `Image`, `InsertDriveFile`). Colours from the
  guideline tokens only (risky tile uses `warningContainer`/`warning`).
- [ ] **Step 6: Screen wiring**: `MessageUi` gains `file: Long?` (local id for FILE kind) and the list renders
  `FileBubble` by collecting `fileStore.observeFile(id)` in a `produceState`. Menu: for READY files add
  `MenuAction(saveDownloadsLabel)` and `MenuAction(shareLabel)`. Open: `Intent(ACTION_VIEW).setDataAndType(uri, FileNames.mimeFor(name)).addFlags(FLAG_GRANT_READ_URI_PERMISSION)`
  wrapped in `Intent.createChooser(..., «Открыть в…»)`; `ActivityNotFoundException` → snackbar.
- [ ] **Step 7: PhotoPreview** switch row (label + hint + `Switch`), state hoisted to the VM so rotation keeps it.
- [ ] **Step 8:** Verify → PASS; Read the PNGs (layout at 360 dp, dark contrast). `git add -A feature/conversation && oc -m "conversation: send, show, open, save and share files; photos without compression (D147)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 11: Shared media data (queries and repository)

**Goal:** One repository answers "photos / files / links / places of chat X" with month sections and counts.

**Files:**
- Modify: `core/database/.../dao/MessageDao.kt` (shared media queries)
- Create: `core/data/src/main/kotlin/app/ottermsg/core/data/media/SharedMedia.kt`
- Move: `usernameRegex` from `feature/conversation/.../UsernameLinks.kt` to `core/data/.../media/TextLinks.kt` (keep the feature using it from there)
- Test: `core/database/src/test/.../SharedMediaDaoTest.kt`, `core/data/src/test/.../SharedMediaTest.kt`

**Acceptance Criteria:**
- [ ] `photos(cid)` = PHOTO messages + FILE messages whose `FileShare.original_photo` is true, newest first; `files(cid)` = FILE messages that are not original photos; `places(cid)` = LOCATION messages; `links(cid)` = every `http(s)://` URL and `@username` in TEXT bodies and PHOTO/FILE captions (no `javascript:`/`file:`/`content:` schemes), one item per occurrence, newest first.
- [ ] Deleted messages never appear; other chats' items never appear.
- [ ] `counts(cid)` returns the four numbers; `recent(cid, 4)` the newest 4 previews (photos first, else file tiles).
- [ ] Month grouping helper `byMonth(items, zone, locale)` → «Ноябрь 2026» sections (capitalised standalone month name).

**Verify:** `$G :core:database:testDebugUnitTest --tests '*SharedMediaDaoTest'` and `$G :core:data:testDebugUnitTest --tests '*SharedMediaTest'` → PASS

**Steps:**

- [ ] **Step 1: Failing tests** with two conversations, every kind, a deleted message, and bodies such as
  «см. https://example.org/a?b=1 и @boris_m», «javascript:alert(1)», «http://x.y/z).» (trailing `).` trimmed).
- [ ] **Step 2: DAO**

```kotlin
    @Query("SELECT * FROM messages WHERE conversation_id = :cid AND kind IN (${MessageKind.PHOTO}, ${MessageKind.FILE}) ORDER BY sent_ms DESC, local_id DESC")
    fun observeMediaAndFiles(cid: Long): Flow<List<MessageEntity>>
    @Query("SELECT * FROM messages WHERE conversation_id = :cid AND kind = ${MessageKind.LOCATION} ORDER BY sent_ms DESC, local_id DESC")
    fun observePlaces(cid: Long): Flow<List<MessageEntity>>
    @Query("""SELECT * FROM messages WHERE conversation_id = :cid AND kind IN (${MessageKind.TEXT}, ${MessageKind.PHOTO}, ${MessageKind.FILE})
              AND (body LIKE '%http://%' OR body LIKE '%https://%' OR body LIKE '%@%') ORDER BY sent_ms DESC, local_id DESC""")
    fun observeLinkCandidates(cid: Long): Flow<List<MessageEntity>>
```
  (photo/file split and `original_photo` are decided in Kotlin from `systemData`.)
- [ ] **Step 3: SharedMedia.kt** — data classes `MediaItem(localId, sentMs, senderId, outgoing, kind: PHOTO|ORIGINAL)`,
  `FileItem(localId, sentMs, senderId, outgoing)` (UI collects `FileStore.observeFile`), `LinkItem(localId, sentMs, senderId, text, url | username, snippet)`,
  `PlaceItem(localId, sentMs, senderId, latE7, lonE7, live: Boolean)`; `class SharedMedia @Inject constructor(db)` with
  `observePhotos/Files/Links/Places(cid)`, `observeCounts(cid)`, `observeRecent(cid, n)`; link extraction:

```kotlin
object TextLinks {
    val url = Regex("""\bhttps?://[^\s<>"«»]+""", RegexOption.IGNORE_CASE)
    // usernameRegex moved here unchanged from UsernameLinks.kt
    fun find(text: String): List<String> = (url.findAll(text).map { it.value.trimEnd('.', ',', ')', '!', '?', ';', ':') } +
        usernameRegex.findAll(text).map { it.value }).toList()
}
```
- [ ] **Step 4:** Verify → PASS. `oc -am "shared media: photos, files, links and places of a chat (D149)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 12: New module `feature/media` — contact profile

**Goal:** Tapping a 1:1 chat header opens «Профиль» (mockup 3).

**Files:**
- Create: `feature/media/build.gradle.kts` (copy of `feature/location`'s without MapLibre/OkHttp; namespace `app.ottermsg.feature.media`), `feature/media/src/main/AndroidManifest.xml` (empty manifest as in other features)
- Modify: `settings.gradle.kts` (`":feature:media"`), `app/build.gradle.kts` (dependency)
- Create: `feature/media/src/main/kotlin/app/ottermsg/feature/media/ContactProfileScreen.kt`, `ContactProfileViewModel.kt`, `res/values/strings.xml`, `res/values-en/strings.xml`
- Modify: `feature/conversation/.../ConversationScreen.kt` (`onTitleClick` for 1:1 → `onOpenProfile`), `AppNavHost.kt` (route `profile/{cid}`)
- Test: `feature/media/src/test/kotlin/app/ottermsg/feature/media/ContactProfileTest.kt`

**Acceptance Criteria:**
- [ ] 1:1 header tap navigates to `profile/{cid}`; group taps still open group info; the news chat has no tap target.
- [ ] Profile shows avatar 88 dp, name, @username, «Позвонить» only when `canCall`, «Без звука»/«Включить уведомления» toggling `ConversationStore.setMuted` (M12), the «Медиа, файлы и ссылки · N» card with 4 previews, and rows «Фото/Файлы/Ссылки/Места» with counts, zero rows hidden, all zero → «Пока нет вложений».
- [ ] Row taps navigate to `media/{cid}?tab=photos|files|links|places`.
- [ ] Roborazzi light/dark of a profile with items and an empty one.

**Verify:** `$G :feature:media:testDebugUnitTest` → PASS

**Steps:**

- [ ] **Step 1:** Module scaffolding; `$G :feature:media:assembleDebug` builds an empty module first, commit
  `oc -am "feature/media module (D149)" ...` (with the trailer).
- [ ] **Step 2: Failing tests** for the criteria (fake `SharedMedia` counts via an interface `SharedMediaSource`
  extracted in Task 11 — add the interface there if not done).
- [ ] **Step 3: ViewModel**: inputs `ConversationStore.observeConversation`, `observeContacts` (username), `SharedMediaSource.observeCounts/observeRecent`,
  `CallStarter` (reuse the conversation module's interface if accessible; else pass `canCall` from the conversation's
  rules: direct chat, contact not revoked) and mute toggle via `ConversationStore.setMuted`.
- [ ] **Step 4: Screen** per mockup 3 (tokens from `docs/10-otter-design-guidelines.md`; cards radius 20 dp, rows ≥ 56 dp,
  avatar via `OtterAvatar`). Strings: `profile_title` «Профиль», `profile_call` «Позвонить», `profile_mute` «Без звука»,
  `profile_unmute` «Включить уведомления», `profile_media_all` «Медиа, файлы и ссылки», `media_tab_photos` «Фото»,
  `media_tab_files` «Файлы», `media_tab_links` «Ссылки», `media_tab_places` «Места», `profile_no_media` «Пока нет вложений».
- [ ] **Step 5: Navigation**: `Routes.PROFILE_CHAT = "profile/{cid}"`, `Routes.MEDIA = "media/{cid}?tab={tab}"`;
  `ConversationRoute(onOpenProfile = { nav.navigate(Routes.profile(cid)) })`; `ConversationScreen` `onTitleClick =
  when { ui.isGroup -> onOpenGroupInfo; ui.isNews -> null; else -> onOpenProfile }`.
- [ ] **Step 6:** Verify → PASS. `oc -am "contact profile from the 1:1 header with attachments summary (D149)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 13: Shared media screen (tabs) and group info card

**Goal:** «Вложения» with tabs Фото · Файлы · Ссылки · Места (mockups 4–6) and the group info card (mockup 7).

**Files:**
- Create: `feature/media/src/main/kotlin/app/ottermsg/feature/media/SharedMediaScreen.kt`, `SharedMediaViewModel.kt`
- Modify: `feature/groups/.../GroupInfoScreen.kt`, `GroupInfoViewModel.kt`, `feature/groups/build.gradle.kts` (depend on `:feature:media` for the shared card composable, or put `MediaSummaryCard` in `core/ui`)
- Modify: `feature/conversation/.../PhotoViewerScreen.kt` («Показать в чате»), `AppNavHost.kt` (route, conversation `focus` arg)
- Modify: `feature/conversation/.../ConversationViewModel.kt` / `ConversationScreen.kt` (scroll to `focus` local id once)
- Test: `feature/media/src/test/.../SharedMediaScreenTest.kt`, `feature/groups/src/test/.../GroupInfoMediaCardTest.kt`

**Acceptance Criteria:**
- [ ] Tabs switch content and keep their own scroll; the start tab comes from the route.
- [ ] Фото: 3-column grid with month headers, «ОРИГ» badge, download mark on REMOTE, «Нет в копии» tile; tap → photo viewer (compressed photos) or `FileStore` open (originals).
- [ ] Файлы: search field filters by name (case-insensitive, local); rows with kind tile, name, «size · date · sender», trailing state; risky rows show «Может установить приложение» in `warning`; tap = bubble tap behaviour (download / open with warning).
- [ ] Ссылки: domain, link, snippet «…» and «sender · date»; tap opens the URL via `ACTION_VIEW` / `@username` via the M9.5 person card; no network requests are made by the screen.
- [ ] Места: map-less row with coordinates «55.75580, 37.61730», sender, date, live/ended label; tap → `Routes.locationMap(cid, focus)`.
- [ ] Group info shows `MediaSummaryCard` (count + 4 previews) opening the same screen; group items show the sender's name.
- [ ] Photo viewer opened from the media screen shows «Показать в чате», which opens the conversation scrolled to that message.
- [ ] Roborazzi light/dark for every tab and the group card.

**Verify:** `$G :feature:media:testDebugUnitTest :feature:groups:testDebugUnitTest :feature:conversation:testDebugUnitTest` → PASS

**Steps:**

- [ ] **Step 1: Failing tests** for each criterion with fake sources.
- [ ] **Step 2: VM**: `SharedMediaViewModel(savedState: cid, tab)`, flows from `SharedMedia`, names from contacts,
  `query` state for the Files tab, `byMonth` grouping.
- [ ] **Step 3: Screen**: `TabRow` with four `Tab`s (labels from Task 12 strings), `HorizontalPager` not required —
  plain tab switch is enough; `LazyVerticalGrid(GridCells.Fixed(3))` with full-span month headers for Фото;
  `LazyColumn` for the rest. Thumbnails via `PhotoSource.thumb` (compressed) or `FileUi.thumb` (originals).
- [ ] **Step 4: Group card**: `MediaSummaryCard(count, previews, onClick)` in `core/ui` (no data dependencies) used by
  the profile (replace its inline card) and `GroupInfoScreen` as the first item after the header.
- [ ] **Step 5: «Показать в чате»**: route `conversation/{id}?focus={localId}` (default −1); `ConversationViewModel`
  reads it once and the screen scrolls to the item index (`listState.scrollToItem`), highlighting it briefly is
  optional (not required).
- [ ] **Step 6:** Verify → PASS. `oc -am "shared media tabs and group info card (D149)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 14: Backups for file messages

**Goal:** Backups keep file messages (name, size, caption, thumbnail of originals) but never the files; restored files show «Файл не входит в резервную копию».

**Files:**
- Modify: `core/data/src/main/kotlin/app/ottermsg/core/data/backup/SnapshotCodec.kt`
- Test: `core/data/src/test/kotlin/app/ottermsg/core/data/SnapshotCodecTest.kt`

**Acceptance Criteria:**
- [ ] Export of a FILE message carries `kind`, `body`, `system_data` (already without keys) and **no** `BackupAttachment`; part keys never appear in the snapshot bytes (test searches the serialized snapshot for each part key).
- [ ] Import creates one attachment row `part_index 0`, state `NOT_IN_BACKUP`, thumbnail from `FileShare.thumbnail`, empty key/digest → `FileUi.state == NOT_IN_BACKUP`.
- [ ] Older snapshots (no FILE messages) import unchanged.

**Verify:** `$G :core:data:testDebugUnitTest --tests '*SnapshotCodecTest'` → PASS

**Steps:**

- [ ] **Step 1: Failing tests** per criteria.
- [ ] **Step 2:** In `export`, skip attachments for `kind == FILE`; in `import`, after inserting a FILE message insert
  `AttachmentEntity(messageLocalId = id, partIndex = 0, blobKey = ByteArray(32), key = ByteArray(32), digest = ByteArray(32), size = 0,
  mime = FileNames.mimeFor(name), width = share.width, height = share.height, thumb = share.thumbnail..., file = null, state = AttachmentState.NOT_IN_BACKUP)`.
  Make sure `MediaTransfers.due` never picks NOT_IN_BACKUP (it doesn't: states UPLOADING/QUEUED only) and
  `downloadFile` ignores it.
- [ ] **Step 3:** Verify → PASS. `oc -am "backup: file messages without their files (D147, D55)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 15: Emulator acceptance, docs, version, checks, owner build/test/merge

**Goal:** Two emulators confirm files and shared media end to end; docs record D147–D149; app 0.15.0; checks green; the release APK and news are built and handed over without stopping; the owner rolls out, tests and decides the merge.

**Files:**
- Modify: `docs-m13/00-decisions.md` (D147–D149 from the spec's "Decisions to record"), `02-protocol.md` (`FileShare`, parts rule, fallback text), `07-android-architecture.md` (FileSealer/MultiPartReader, FileContentProvider, FileTransferService, `feature/media`, Room v13), `09-roadmap.md` (M13 row), `10-otter-design-guidelines.md` (file bubble, profile, tabs, risky dialog)
- Modify: `otter-android-m13/app/build.gradle.kts` (`versionCode = 19; versionName = "0.15.0"`)
- Create: `otter-android-m13/docs/m13-manual-test.md`

**Acceptance Criteria:**
- [ ] Emulators (`m8_api34` + `m8_api30`, dev mesh in a scratch dir — never `otter-server/.dev-mesh`, never the owner's account; generate test files with `adb shell dd if=/dev/urandom of=/sdcard/Download/t300.bin bs=1M count=300` and a 1.2 GB sparse file `truncate -s 1200M`): A sends 300 MB → B downloads with the app in the background (transfer notification visible, disappears at the end; `adb shell dumpsys activity services app.ottermsg` shows no FileTransferService afterwards); B opens a PDF via «Открыть в…» and saves it to Downloads; A tries 1.2 GB → «Файл больше 1 ГБ»; A sends an original-quality JPEG with GPS → B's saved copy has no GPS (`exiftool` on the pulled file); an `.apk` shows the warning; profile and all tabs show the items; group info card works; a 0.14 app on the second emulator shows the fallback text (install the 0.14.0 debug build from main before the M13 build, if feasible; otherwise leave it to the owner's phone row 8).
- [ ] App: `$G test lintDebug assembleDebug` → BUILD SUCCESSFUL; server: `nice -n 15 go test -p 4 -count=1 ./...` all ok; `scripts/secrets-check.sh` ok in all three repos.
- [ ] The owner tested on phones and said "merge".

**Verify:** the check commands above.

**Steps:**

- [ ] **Step 1:** Emulator run; record commands and results in `otter-android-m13/docs/m13-manual-test.md` with the owner's phone rows (Step 6). No Gradle while emulators run.
- [ ] **Step 2:** Docs edits; `oc -am "docs: M13 files and shared media (D147–D149), app 0.15.0" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`.
- [ ] **Step 3:** Version bump; `oc -am "app 0.15.0 (versionCode 19)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`.
- [ ] **Step 4:** Checks one after another; mark tasks completed in `docs-m13/superpowers/plans/2026-11-28-m13-files-and-shared-media.md.tasks.json`; commit.
- [ ] **Step 5: Build the release — do NOT stop to ask** (owner 2026-11-28: finish all builds and hand over links):

```bash
cd ~/Documents/Projects/OttterMSG/otter-android-m13 && ln -s ../otter-android/release.jks release.jks && \
  JAVA_HOME=~/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2 nice -n 15 ./gradlew --max-workers=4 \
  -PotterKeystore=../otter-android/keystore.properties assembleRelease; rm release.jks
cp app/build/outputs/apk/release/app-release.apk ../otter-server/dist/otter-app_0.15.0.apk
sha256sum ../otter-server/dist/otter-app_0.15.0.apk
apksigner verify --print-certs ../otter-server/dist/otter-app_0.15.0.apk | grep -m1 SHA-256   # must match the 0.14.0 release cert
```
  If the keystore asks for a passphrase that is not in `keystore.properties`, stop and give the owner the exact command
  (passphrases are typed only in the owner's terminal). Server binaries are **not** rebuilt: M13 has no server change,
  nodes stay on 0.13.0.
  Write the news `otter-server/dist/news/0.15.0.md` (`## ru` / `## en`): «Файлы до 1 ГБ через 📎 → «Файл»; фото без
  сжатия (геометка удаляется); в профиле собеседника и в информации о группе — все фото, файлы, ссылки и места чата.
  Файлы, которые никто не скачал за 7 дней, удаляются с серверов.» Never delete anything in `otter-server/dist/`.
  Save a release log in `~/Documents/otter-private/releases/2026-MM-DD-0.15.0.md` (sha256, cert, commits, test results).
  **Hand over** to the owner, without waiting: the full paths of the APK and the news file, the sha256, and the
  commands of Step 6.
- [ ] **Step 6: Owner pre-check, rollout, phone test** (handed over in Step 5; owner runs; never ssh yourself):

```bash
cd ~/Documents/Projects/OttterMSG/otter-server
deploy/status.sh                       # DISK column: keep >= 10 GB free on every node
deploy/release-apk.sh 0.15.0 dist/otter-app_0.15.0.apk
```
  Phone rows: (1) send a PDF; the other phone downloads and opens it. (2) Send a ~500 MB video on Wi-Fi, switch to
  another app: «Отправка файла · N %» shows, finishes, disappears. (3) A 1.5 GB file is refused. (4) Original-quality
  photo: the receiver saves it; its details show no location. (5) An `.apk` shows the warning. (6) Profile from the
  chat header: counts right; each tab opens; «Показать в чате» jumps to the message. (7) Group info card. (8) A phone
  still on 0.14 sees «📎 Файл: … — обновите Otter».
- [ ] **Step 7: Merge only after the owner says "merge"** (standing rule; temporary worktrees):

```bash
cd ~/Documents/Projects/OttterMSG
for r in otter-server otter-android docs; do
  git -C $r fetch origin && git -C $r worktree add ../$r-merge origin/main --detach
  (cd $r-merge && git merge --no-ff --no-commit m13-files && oc -m "Merge M13: files up to 1 GB and shared media (app 0.15.0)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && scripts/secrets-check.sh && git push origin HEAD:main)
  git -C $r worktree remove ../$r-merge
done
for r in otter-server otter-android docs; do git -C $r worktree remove ../$r-m13 && git -C $r branch -d m13-files; done
for r in otter-server otter-android docs; do git -C $r pull --ff-only; done
```
