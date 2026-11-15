# 04 — Security & Cryptography

## Threat model

| Adversary | Can | Cannot (by design) |
|-----------|-----|--------------------|
| Network observer / ISP / DPI | See that you connect to some IPs over TLS-looking traffic; block IPs; throttle | Read content; easily classify traffic as a messenger (see [05](05-transport.md)) |
| Hosting provider / seized node | Read node DB: metadata (who↔whom, when, sizes, usernames, display names), encrypted blobs, encrypted backups; drop messages | Read messages, media or history; forge messages; impersonate users |
| Google (FCM, only on push-capable nodes and phones with a Firebase build) | Which Firebase project wakes which phone (token), when, and the push-capable node's IP | Read content, sender, chat or message ids: the push is a constant `{"w":"1"}` (M5, D59) |
| Malicious node operator (one of 3) | Same as above, plus withhold records, try offline password guessing on backups | Break E2E; inject forged records into honest nodes |
| Another network member | What any contact can see | Read others' 1:1 chats or groups they're not in |
| Lost/stolen phone | If unlocked: everything on it. If locked: encrypted DB protected by Android Keystore | — |

Out of scope for V1: hiding metadata from nodes (sealed sender), global passive adversary
traffic correlation, compromised phone OS.

## Layers

1. **E2E (content)** — libsignal: PQXDH session setup, Double Ratchet for 1:1, Sender Keys
   for groups. Forward secrecy and post-compromise security for 1:1; forward secrecy for groups
   with key rotation on membership change.
2. **Record authenticity** — every record Ed25519-signed by its author (account, node, network key).
3. **Link** — client↔node and node↔node: TLS 1.3 (WSS) or VLESS+REALITY (X25519 auth), with
   server keys **pinned in the signed manifest**. Inside the link, node↔node additionally run a
   signed challenge with node keys (mutual authentication independent of the transport).
4. **At rest on phone** — Room DB encrypted with SQLCipher; DB key wrapped by Android Keystore
   (hardware-backed where available). Attachments stored encrypted on disk.
5. **At rest on node** — nothing readable is stored; backups encrypted with password-derived key (a persistent blob on every node, D50).

## Push notifications (M5, D58–D62)

* What Google receives per push: the device's FCM token, `priority HIGH`, collapse key `otter`, TTL 600 s and the
  constant data `{"w":"1"}`. No user, chat, message or record id, no sender, no content, no counter. One push per
  (user, device) per 10 s per node at most, so timing still shows roughly when a member gets messages.
* The phone decrypts locally and builds the notification itself; on the lock screen only «Otter / Новое сообщение»
  (`VISIBILITY_PRIVATE`).
* The FCM token is a signed `PUSH_TOKEN` record replicated to every node (members' nodes see it, like other metadata).
* The Firebase service-account key (`/etc/otter/fcm.json`, 0640 root:otter) lets anyone holding it send pushes to the
  project's apps — wake-ups, nothing readable. It never enters bundles, the admin dir or git; `deploy/push-key.sh`
  streams it over SSH. It can be revoked in the Firebase console. `app/google-services.json` (the app's Firebase
  config) is also kept out of git (D57).
* A build without `google-services.json` has no Firebase app and never contacts Firebase; it checks every 15 min.
  Only `firebase-messaging` is linked (no Analytics or Crashlytics).
* **Push switches (design limit 4, D94; app and server 0.9.0)**: with «Показывать уведомления» off the phone sends
  `PUSH_TOKEN{messages_off}` and nodes push it for calls only. With «Пробуждение через Google» off the phone deletes its
  FCM token and sends `PUSH_TOKEN{withdrawn}`: nodes erase the token (the row stays, so an older token record cannot
  bring it back), Google is no longer told when the phone is woken, calls cannot ring while Otter is closed, and the
  phone checks every 15 min. Old `PUSH_TOKEN` records with the token string stay in the record log until M9.2's
  per-author compaction (C8). The phone never keeps a connection of its own in the background.

## Key verification

* Invite QR carries inviter's keys, but these link fields are unsigned: the invitee stores the inviter **unconfirmed**
  (`entryVersion = 0`, only if `inviter_user_id = ID16(inviter_account_pub)`) and neither encrypts to it nor accepts
  envelopes or group states signed with its link key until the inviter's directory entry verifies (C23, D95).
* Other contacts are trusted on first use via the directory; users can verify in person by
  scanning each other's safety-number QR (libsignal fingerprint).
* Identity key change of a contact ⇒ prominent warning; verified status cleared.
  (Restore with recovery phrase **does not** change keys → no warning.)

## Recovery phrase (identity)

* 256-bit seed ↔ 24 BIP-39 words, shown once at registration, user must confirm 3 random words.
* Seed deterministically derives the account key and libsignal identity key ([02](02-protocol.md) §1).
* Restoring from phrase alone: same user_id, same keys, contacts & group membership lost
  unless a backup is also restored; new prekeys uploaded; peers see a session reset, not a key change.
  Built in M6 (D54): «Восстановить аккаунт» → words → empty chats; the history can be added afterwards with the password.

## Password backup (history)

Goal: new phone + username + password ⇒ identity **and** history back, even if the old phone
is gone and one hosting died.

### Key derivation
```
salt        = random 16 bytes (stored in BACKUP_META, public)
master      = Argon2id(password, salt, profile 1: m=64 MiB, t=3, p=1) → 64 bytes   (BouncyCastle, pure Java)
backup_key  = HKDF(master, "otter/backup/enc/v1")    32 bytes
auth_secret = HKDF(master, "otter/backup/auth/v1")   32 bytes
auth_verifier = SHA-256(auth_secret)   (stored on nodes in BACKUP_META)
```

### Contents (encrypted with backup_key, Tink `AesGcmHkdfStreaming`, aad = blob key; gzip inside)
* the **seed** (so identity is restored too),
* contacts, verification states, groups (state + membership), settings,
* message history (DB export, compressed),
* attachment metadata and thumbnails. **No media files** in V1 (D55): restored photo messages show the thumbnail and «Нет в резервной копии».

Not included: Signal session/ratchet state and sender keys (restoring old ratchet state is
unsafe and breaks decryption). After restore the client uploads new prekeys and sends
`SessionReset` to contacts; group sender keys are redistributed.

### Storage
* Backup is a persistent blob (chunked) + `BACKUP_META{version, salt, kdf params, auth_verifier, blob_key, size}`
  signed by the account key; replicated to **all nodes** like any blob (D50).
* `backup_key` and `auth_secret` are derived once, when the password is set, and kept wrapped by the Android Keystore
  (`SeedVault`), so automatic backups need no password. Password policy: ≥ 10 chars, zxcvbn score ≥ 3 (D55).
* Schedule (V1): a full snapshot while the app is in the foreground when the last success is older than 24 h, and on
  «Создать сейчас». No WorkManager, no incremental backups, no media.

### Restore
```
app: network link (any member invite or bootstrap link; only its manifest is used, the invite is not consumed, D54)
app: backup.auth{username} → node returns salt, kdf params (must be a client profile, else stop)
app: Argon2id(password) → auth_secret
app: backup.fetch{username, auth_secret} (inside the encrypted link)
node: checks SHA-256(auth_secret) == auth_verifier (constant time), counts failures
node: returns meta + blob meta and lets this connection blob.get that blob
app: decrypt with backup_key → seed, data → verify metas against the seed's account key
app: login → INSTALL, new prekeys (installed_ms), SessionReset to every contact
```
* **KDF profiles (C1, D86)**: the phone knows a fixed table of Argon2id profiles; **profile 1 = m 65536 KiB, t 3,
  p 1, salt exactly 16 bytes**. The numbers a node returns in `backup.auth` are **only an ID**: they must equal a known
  profile exactly, otherwise the restore ends with «Копия повреждена» **before the password is used** (no Argon2 run,
  no `auth_secret` sent). The profile used for a backup is stored on the phone (`backup_profile`); a stronger profile
  is added to the table and chosen by the phone when a password is set, never by a node. A node can at most make a
  later-profile backup look like profile 1 (the phone then derives wrong keys and fails); it can never go below
  profile 1.
* **Restore checks (C13, C18, D87, D88)**: after decrypting, the phone checks with the account key from the decrypted
  seed (1) the `BACKUP_META` signature and (2) the `BLOB_META` signature, both authored by that account, (3)
  `BLOB_META` key == `BackupMeta.blob_key`, (4) signed `salt` == the salt from `backup.auth`, (5) signed KDF numbers ==
  the profile used. Any failure → «Копия повреждена», nothing is written. A restored phone continues backup versions
  from `max(restored version, now ms)`, so a node serving an older genuine backup cannot make the phone's later backups
  lose to a newer one (D50). A words-only restore runs the directory sync verification on every `DIRECTORY_ENTRY`,
  counts only entries of the derived account key and takes the highest `version`; no valid entry → «Аккаунт не найден».
* **Rate limit**: 5 failed `backup.fetch` per username per hour per node, 20/day per node
  (with 3 nodes an online attacker gets at most 60 guesses/day — negligible against a
  zxcvbn ≥ 3 password).
* **Known limitation**: whoever holds a node's disk can attempt **offline** guessing against
  the stored ciphertext/verifier. Mitigations: Argon2id with 64 MiB memory, enforced password
  strength (zxcvbn score ≥ 3, min 10 chars), user advised to use a passphrase.
* Changing password ⇒ new salt, new keys, new backup version (old one superseded and deleted).
* **Decoys (C20, D90; replaces the fake-salt limit of D51)**: an account without a backup publishes once a decoy
  `BACKUP_META` (`version 0`, random 16-byte salt, profile-1 numbers, random verifier, `size 0`, `blob_key = author ‖
  16 zero bytes`, no blob). It replicates like any backup, so every node answers `backup.auth` for that member with the
  same salt and numbers as for a member with a real backup; `backup.fetch` against a decoy always fails like a wrong
  password (and counts). A real backup replaces the decoy; a decoy never replaces a real backup. Decoys are signed, so a
  node cannot fake or remove one without it showing. Unknown usernames keep the node-local fake salt (D51): it differs
  between nodes, which tells someone with two nodes' addresses only that a name is **not a member**. Leaks that remain:
  a salt change over time (a password set or changed), and members whose phone is still on 0.8.x (no decoy yet; a
  0.9.0 phone retries the decoy each session while a 0.8.x node refuses it). Restoring through a node the backup hasn't
  reached yet looks like a wrong password and counts as a failed attempt.
* **Install record (C14, D89)**: "another phone replaced me" is decided only from an account-signed `INSTALL{
  registration_id, installed_ms}` (record type 17) that verifies with the phone's own account key and is newer than its
  own (installed_ms, then registration_id). The unsigned `LoginResponse.installed_ms`/`registration_id` are ignored by
  0.9.0 phones, so a node cannot fake a takeover. A phone publishes `INSTALL` after registration, at the end of every
  restore (before the new `PREKEYS`), on first start of 0.9.0, and after «Этот телефон снова главный». Nodes raise the
  device's install from `INSTALL` or `PREKEYS` (both account-signed) and cut off the older install (D56).
* **Superseded install** (D52, D56, D89): a restore creates a newer install of the device. The old phone is cut off by the
  nodes (its session is closed, its acks are refused) and shows «Аккаунт на другом телефоне» on its next login. That
  screen offers «Этот телефон снова главный» (with a confirmation dialog): a new `installed_ms` on this phone, then the
  restore finish (signed `INSTALL`, fresh prekeys, a reset to every contact).
* **Design limit 2**: whoever holds the recovery words (the seed) can still sign `INSTALL` and take the account (the real owner can take
  it back with «Этот телефон снова главный», and the two phones can keep doing so). The fix is the admin-signed `REKEY`
  in M9.3.
* Messages that arrived for the old install after the last backup are lost; they trigger a session reset (D53).

## What the phone does not take from a node (M9.1, app 0.9.0)

Threat model: any one node may be hostile. Besides restore (above) and install (D89):
* **Envelopes (C15, D91)**: an envelope is marked seen and acknowledged only after its signature verifies with the
  sender's directory key; a forged copy is ignored (not acked: an ACK would delete the real envelope on every node).
* **Sizes (C17, D93)**: frame ≤ 4 MiB, unhandled events ≤ 16 MiB, blob and APK chunks exactly the expected size,
  APK ≤ 100 MiB; over a limit the connection is dropped and other nodes are tried; WebSocket compression is never
  negotiated. **Accepted residual:** OkHttp buffers one whole WebSocket message before the app can check it, so a
  hostile node can still make the phone hold one huge uncompressed frame, but only by really sending those bytes.
* **Manifest fallback (C16, D92)**: a previous manifest's endpoint is used only for a node, and with pins, that the
  newest manifest still authorizes.
* **Pictures (C21, D98)**: photo and thumbnail headers are checked before decoding (≤ 100 megapixels, ≤ 4096 px
  decoded).
* **Secrets on screen (C22, D98)**: `FLAG_SECURE` on every screen with the recovery words or a backup password.
* **Shared connection log (C24, D96)**: node labels, no operator, no IP addresses.
* **Release signing (C19, D97)**: a release build without the owner's keystore fails instead of being debug-signed.

## Revocation

Admin can revoke a user (`REVOCATION` signed by network key) — e.g. lost phone without
backup, or member leaves. Nodes refuse the user's logins/records; clients mark them removed
and groups rotate keys.

## Node key compromise

Admin publishes a new manifest without that node (or with new keys). Clients and peers stop
trusting the old key as soon as they see the new manifest (from app 0.9.0 also during the 7-day fallback, D92).

## Libraries

| Purpose | Android | Go node |
|---------|---------|---------|
| Signal protocol | `org.signal:libsignal-android` (AGPL-3.0) | — (never decrypts) |
| Ed25519 | Tink / BouncyCastle | `crypto/ed25519` |
| Argon2id | `com.lambdapioneer.argon2kt` | — |
| AEAD / streaming | Tink | — |
| TLS | OkHttp / Conscrypt | `crypto/tls` |
| REALITY | libXray (Xray-core via gomobile), V1.x (D75) | Xray-core (embedded, M7) |
