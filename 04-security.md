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

## Key verification

* Invite QR carries inviter's keys → inviter/invitee are **verified** automatically.
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
master      = Argon2id(password, salt, m=64 MiB, t=3, p=1) → 64 bytes   (BouncyCastle, pure Java)
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
app: backup.auth{username} → node returns salt, kdf params
app: Argon2id(password) → auth_secret
app: backup.fetch{username, auth_secret} (inside the encrypted link)
node: checks SHA-256(auth_secret) == auth_verifier (constant time), counts failures
node: returns meta + blob meta and lets this connection blob.get that blob
app: decrypt with backup_key → seed, data → login → new prekeys (installed_ms), SessionReset to every contact
```
* **Rate limit**: 5 failed `backup.fetch` per username per hour per node, 20/day per node
  (with 3 nodes an online attacker gets at most 60 guesses/day — negligible against a
  zxcvbn ≥ 3 password).
* **Known limitation**: whoever holds a node's disk can attempt **offline** guessing against
  the stored ciphertext/verifier. Mitigations: Argon2id with 64 MiB memory, enforced password
  strength (zxcvbn score ≥ 3, min 10 chars), user advised to use a passphrase.
* Changing password ⇒ new salt, new keys, new backup version (old one superseded and deleted).
* **Fake salts** (D51): for an unknown username or a member without a backup the node answers `backup.auth` with a stable
  fake salt, so the two cases look alike. Limit: fake salts differ per node, so someone who can reach two nodes can tell
  which usernames have backups. Restoring through a node the backup hasn't reached yet looks like a wrong password and
  counts as a failed attempt.
* **Superseded install** (D52, D56): a restore creates a newer install of the device. The old phone is cut off by the
  nodes (its session is closed, its acks are refused) and shows «Аккаунт на другом телефоне» on its next login.
* Messages that arrived for the old install after the last backup are lost; they trigger a session reset (D53).

## Revocation

Admin can revoke a user (`REVOCATION` signed by network key) — e.g. lost phone without
backup, or member leaves. Nodes refuse the user's logins/records; clients mark them removed
and groups rotate keys.

## Node key compromise

Admin publishes a new manifest without that node (or with new keys). Clients and peers stop
trusting the old key as soon as they see the new manifest.

## Libraries

| Purpose | Android | Go node |
|---------|---------|---------|
| Signal protocol | `org.signal:libsignal-android` (AGPL-3.0) | — (never decrypts) |
| Ed25519 | Tink / BouncyCastle | `crypto/ed25519` |
| Argon2id | `com.lambdapioneer.argon2kt` | — |
| AEAD / streaming | Tink | — |
| TLS | OkHttp / Conscrypt | `crypto/tls` |
| REALITY | libXray (Xray-core via gomobile) | Xray-core (embedded) |
