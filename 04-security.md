# 04 — Security & Cryptography

## Threat model

| Adversary | Can | Cannot (by design) |
|-----------|-----|--------------------|
| Network observer / ISP / DPI | See that you connect to some IPs over TLS-looking traffic; block IPs; throttle | Read content; easily classify traffic as a messenger (see [05](05-transport.md)) |
| Hosting provider / seized node | Read node DB: metadata (who↔whom, when, sizes, usernames, display names), encrypted blobs, encrypted backups; drop messages | Read messages, media or history; forge messages; impersonate users |
| Google (FCM, only on push-capable nodes and phones with a Firebase build) | Which Firebase project wakes which phone (token), when, and the push-capable node's IP | Read content, sender, chat or message ids: the push is a constant `{"w":"1"}` (M5, D59) |
| Malicious node operator (one of 3) | Same as above, plus withhold records, hide directory entries, try offline password guessing on backups, refuse restores on its own node | Break E2E; inject forged records into honest nodes; create members, undo a revocation or restore invite rights (M9.2: every node and phone checks membership itself); lock a name's restore on other nodes (D105: a stranger can only slow one name down per node); flood other nodes past the record budgets (D107); replay a member's record from another network that knows the same key, once the cut-over manifest is out (D109); keep backups at rest or see a restore's password check when marked `no_backups` (D113, D114) |
| Another network member | What any contact can see; invite new members (unless the admin withdrew the right, D101) | Read others' 1:1 chats or groups they're not in; reuse an invite (D102); take an existing username (D103); flood nodes or phones with records or call pushes beyond the budgets (D107, D108) |
| Lost/stolen phone | If unlocked: everything on it. If locked: encrypted DB protected by Android Keystore | Keep the account after the admin re-keys it: the old key is revoked everywhere and its signatures, group states included, stop counting (M9.3, D111, D134) |

Out of scope for V1: hiding metadata from nodes (sealed sender), global passive adversary
traffic correlation, compromised phone OS.

**Since M9 the working assumption is "any one node may be hostile"**: phones verify everything a node says (M9.1,
below), and membership is decided by signed records that every node and every phone checks itself (M9.2).

## Layers

1. **E2E (content)** — libsignal: PQXDH session setup, Double Ratchet for 1:1, Sender Keys
   for groups. Forward secrecy and post-compromise security for 1:1; forward secrecy for groups
   with key rotation on membership change.
2. **Record authenticity** — every record Ed25519-signed by its author (account, node, network key); since the M9.3
   cut-over the signature also covers the network id (signature v2, D109).
3. **Link** — client↔node and node↔node: TLS 1.3 (WSS) or VLESS+REALITY (X25519 auth), with
   server keys **pinned in the signed manifest**. Inside the link, node↔node additionally run a
   signed challenge with node keys (mutual authentication independent of the transport).
4. **At rest on phone** — Room DB encrypted with SQLCipher; DB key wrapped by Android Keystore
   (hardware-backed where available). Attachments stored encrypted on disk.
5. **At rest on node** — nothing readable is stored; backups encrypted with password-derived key (a persistent blob on every node, D50,
   except nodes marked `no_backups`, which keep none at rest, D113).

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
  phone checks every 15 min. Since server 0.9.3 (D107) nodes keep only the newest `PUSH_TOKEN` record per author, so
  an old record with the token string disappears from the record log once a newer one arrives (and cannot come back).
  The phone never keeps a connection of its own in the background.

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
  signed by the account key; replicated to **all nodes** like any blob (D50) — except nodes marked `no_backups`
  (M9.3, D113): they never receive backups and hand what phones upload to them to the other nodes.
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
node: reserves the attempt as a failure (limits checked in the same write, D105), then
      checks SHA-256(auth_secret) == auth_verifier (constant time); right secret → the row is removed
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
* **Restore throttle (C4, C10, D105; server 0.9.3)**: every `backup.fetch` is first written to `auth_failures`
  (username, source, time) in the same write transaction that checks the limits, so parallel wrong attempts cannot
  overshoot; a correct secret (or a node error) removes the row. Per node: **5 failures per (username, source) per
  hour** → `RETRY_LATER` for that source only; per username across sources **10 failures per 24 h free**, then each
  attempt waits **30 s × 2^(n−10) after the last failure, at most 15 min**; per source across usernames **30 per 24 h
  free**, then the same slow-down. A correct password during an active slow-down is refused too (no guessing
  oracle). The answer says «too many attempts, retry in Ns». Source = the phone's TCP address at the node's WSS
  listener (IPv4 address, IPv6 /64; loopback = `local`); no forwarding header is trusted. Result: a stranger can slow
  one name down to one attempt per 15 min on one node, never lock it (the old node-wide 20/day lock is gone), and
  each node counts separately; an online guesser gets at most about 110 attempts per name per node per day — negligible against
  a zxcvbn ≥ 3 password. Restores relayed through a restore tunnel (D114) arrive as `tunnel:<relay node id>` and
  all share that one source (accepted until a PROXY-header follow-up).
* **Clashed names (C12, D103)**: for a name that ever clashed, `backup.auth` returns the `name#<8 hex>` candidates and
  no salt, and `backup.fetch` with the plain name is `CONFLICT`; the phone tries at most 4 candidates, only of the form
  `<typed name>#<8 hex>`, with the typed password.
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
* **Design limit 2** (closed in M9.3 by the admin re-key, below): whoever holds the recovery words (the seed) can
  sign `INSTALL` and take the account (the real owner can take it back with «Этот телефон снова главный», and the two
  phones can keep doing so). When the words or the phone are lost to someone else, the admin re-keys the account
  (D111): the old key is revoked everywhere and the person continues under a new key.
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

## Membership (M9.2, D99–D104; server 0.9.3, app 0.9.1)

Threat model: any one node may be hostile, so no node's word decides who is a member.

* **Invite chain (limit 3, C6, D100)**: a new account's directory entry carries the inviter's signed `INVITE` and a
  proof by the invite's one-time redeem key (derived from the link secret, which never leaves the two phones).
  **Every node and every phone** verifies the chain of every account it does not know yet — on registration and on
  replication: signed by the network key or a known member, proof valid, invite lifetime ≤ 30 days, registration
  inside the invite's lifetime, inviter neither revoked nor without the right as of the invite's signed
  `created_ms`. The accounts that predate M9.2 are listed as `founding_members` in the signed manifest. A hostile
  node therefore cannot create a member that other nodes or phones accept.
* **Invite rights (D101)**: every member may invite by default; a network-signed `INVITE_RIGHTS` withdraws or restores
  one member's right. The entry's own `can_invite` is ignored.
* **Single use (C5, D102)**: one invite redeemed several times (a partition or a hostile node) leaves one account (the
  lowest proof hash); the others **and every account invited through them, at any depth** are disabled on every node
  and every phone.
* **Usernames (C12, D103)**: the clash rank is the inviter-signed invite time, fixed at admission.
* **Phones (D104)**: a directory entry becomes a contact only if it is a founding member or its chain verifies;
  revocations and rights are checked with the network key. A node can hide entries; it cannot invent members.
* **Accepted limit (owner, 2026-11-15)**: rights and revocation are judged at the invite's `created_ms`, which the
  inviter signs; an inviter can backdate an invite by up to its 30-day lifetime (e.g. to just before a revocation or a
  withdrawn right). The admin revokes such accounts by hand (`otter-admin user list` shows them).

## Bound to the network, lost phones, backups (M9.3, D109–D114, D134; server 0.10.0, app 0.10.0)

* **Signature v2 (C7, D109, D110)**: record signatures cover `"otter-v2\x00" ‖ network_id ‖ body`, so a record signed
  for this network is worthless in another one that knows the same key. Every node, phone (0.10.0) and the admin CLI
  verifies v2 and v1, and signs v2 once the manifest carries `sig_v1_until_ms`; after that time v1 is refused for new
  records. The cut-over is published only after every node and phone runs 0.10.0 (0.9.x phones would drop v2
  records), with a 48 h margin for queued v1 messages.
* **Lost-phone re-key (limit 2, D111)**: step 1 `otter-admin user rekey NAME --old CODE` revokes the lost account
  (`REVOCATION`, reason `rekey`) and prints a 7-day network invite for a fresh install, which registers under the same
  name (shown as `name#tag` meanwhile). Step 2: the person reads «Код аккаунта» (Settings → Профиль) to the admin by
  phone or in person, and `--new CODE` signs `REKEY{old, new}`. The invite alone gives nothing: whoever redeems it gets
  a new account, and it becomes the person only when the admin enters the code read aloud. Nodes and phones give
  `new` the name, the clash rank and `old`'s direct chats; contacts see «ключ безопасности изменился» and the new
  key is unverified until checked in person.
* **Groups (D112, D134)**: one deterministic phone per group signs the swap old → new; while a `rekey` revocation waits
  for its REKEY (≤ 14 days) the member stays listed but our sender key is rotated at once, so the lost phone reads no
  new group messages. Group states signed by a revoked or re-keyed account are refused on every phone that knows the
  revocation, and a state accepted from it earlier no longer outranks the honest members' next state.
* **No backups at rest on exposed nodes (limit 1, D113)**: a node marked `no_backups` (the node in Russia) answers no
  restore, receives no backups from peers, and deletes what phones upload to it once `min(2, other nodes)` other nodes
  confirm they hold it. Seizing it gives no backups to guess offline.
* **Restore tunnel (limit 1, D114)**: phones restore through the `no_backups` node to a node that keeps backups; the
  phone's TLS runs end to end to that node and pins its certificate, so the relay sees only TLS record sizes and timing,
  never the salt, the password check or the backup.
* **Remaining limits**:
  * Until the cut-over manifest is published, v1 signatures are still accepted for everything; afterwards a v1 record
    created before the cut-over can still be replayed into another network that holds the same key (only with a seed
    reused across networks).
  * The re-keyed person's own history on the lost phone is not recovered (their backup belongs to the revoked key;
    owner, Q5); contacts keep the chats.
  * The admin must recognise the person who reads the account code; anyone who can talk the admin into a wrong code
    takes over the name.
  * Until the revocation reaches a node or phone, the lost phone's key still works there (as for any revocation).
  * With only one node without `no_backups` the handoff needs one confirmation: if that node lies (`held` without
    holding), the `no_backups` node deletes its copy early and the backup depends on that node alone (owner, Q3).
  * A backup uploaded to a `no_backups` node rests there until it is handed off (≥ the time to the `BACKUP_META`, or
    1 h, plus the confirmations); a 0.9.x peer never confirms.
  * Every restore through one tunnel shares the relay's restore-limit source, so a stranger guessing through the same
    relay slows the others down there (D105).

## Revocation (C2, D99)

The admin revokes a member with `otter-admin user revoke` (a `REVOCATION` signed by the network key) — e.g. a lost
phone without backup, or a member who leaves. It is **permanent**. Every node applies it in the transaction that
stores it, also when it arrives by replication: the account is closed (open sessions dropped), its mailbox, prekeys
and push tokens are deleted, it cannot log in, submit, invite, fetch blobs or get TURN credentials, and TURN refuses
its already-issued credentials (D108). Its records that arrive later by replication are skipped. Phones verify the
record themselves: the 1:1 chat shows «Участник удалён» without composer or call button, outbox items to it fail,
envelopes from it (calls included) are dropped, every group containing it rotates our sender key and stops
encrypting to it, and the group's lowest-id non-revoked admin removes it from the signed group state.
`otter-admin user list` asks a node with a network-key-signed request and verifies every record on the admin
machine; comparing two nodes' lists shows a node that hides someone.

## Budgets (C8, C9, D106, D107; server 0.9.3)

A member's records are signed, so a hostile node cannot forge them — but it can relay a member's flood or replay old
records. The budgets therefore hold where records are applied, for local submits **and** replicated records:
* one-time prekeys ≤ 200 unconsumed per (user, device, owner node); old `PREKEYS` records compacted, consumed ids never
  come back (`prekey_floor`);
* `PUSH_TOKEN`: only the newest record per author;
* `INVITE`: lifetime ≤ 30 days, ≤ 50 unexpired per author (the same 50 on every node), expired ones deleted;
* compacted record keys are remembered for 30 days, so re-sending them changes nothing;
* local submits only: `created_ms` ≤ 5 min ahead, `PREKEYS` ≤ 20 and `PUSH_TOKEN` ≤ 30 per author per hour;
* blob quota and the 3-backup-blob limit are counted in the write transaction that inserts the blob (no race);
* phone: a node's `prekeys_low` is obeyed only for owner nodes in the verified manifest (or the connected node), at
  most once per owner per 5 min and 6 times per owner per day.

## Calls under a hostile node or member (M8 review, D108)

* **TURN**: a revoked account gets no new credentials and its earlier ones are refused on every authenticated TURN
  request, so its relay stops within one permission refresh (≤ 5 min).
* **Call pushes**: at most 8 high-priority call wake-ups per (sender, recipient device) per minute per node; beyond
  that the wake-up is an ordinary coalesced one. No push at all for an envelope dated more than 5 min ahead. Only
  the call offer is urgent (answer, candidates and hangup are fetched by the phone the offer woke).
* **Phone**: a TURN answer is used only with 1–4 `turn:`/`turns:` URLs on one IPv4 host, udp/tcp transport, an
  expiry in the future and ≤ 24 h away, username/password ≤ 256 chars — otherwise «Звонки недоступны» on that node.
  Call content from a revoked contact never rings; an offer dated more than 5 min in the future is a missed call.
* Unchanged: SDP and DTLS fingerprints travel only inside Signal-encrypted envelopes (D78), so neither a node nor a
  third member can inject into or join a call.

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
