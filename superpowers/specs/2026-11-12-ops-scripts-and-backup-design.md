# Design: server scripts (M1.6) and backup & restore (M6)

Approved by the owner 2026-11-12. Two plans, executed in order: M1.6 first, then M6.

## Part 1 — M1.6 Server scripts (admin PC)

* `~/.otter-admin/hosts` — one line per node: `<label> <ssh target>` (e.g. `eeee root@eeee`).
  `deploy/hosts.sh set|get|list|rm`. All new scripts look the target up here.
* `deploy/add-node.sh LABEL root@HOST --ip IP [--ip IPv6] [--domain D]` — `node add` (wss host = domain, else
  the first IP), `manifest sign` (one passphrase prompt), records the host, `push.sh`, then `manifest publish`
  through the already-running nodes so they learn the new peer; prints DNS records when a domain is used;
  stops at the first error and says how to resume.
* `deploy/upgrade-all.sh VERSION [--only LABEL]...` — `make release VERSION`, then for each node in manifest
  order: detect arch (`uname -m`), `upgrade.sh`; stop at the first rollback/failure (exit 2/3), print a summary.
* `deploy/status.sh` — table per node: label, target, version, pinned hello, service/health, disk use of
  `/var/lib/otter`.
* Tests: offline script tests; `deploy/test/e2e.sh` grows a two-VM scenario: install A, add-node B, message
  replicates A→B, upgrade-all, status.
* The existing node `eeee` is registered with `hosts.sh set eeee root@eeee` (documented in FIRST-DEPLOY/README).

## Part 2 — M6 Backup & restore

### Member experience
* Backup is opt-in: Settings → «Резервная копия» → password (≥ 10 chars, zxcvbn score ≥ 3, strength meter)
  → first backup. Afterwards an automatic backup runs while the app is in the foreground when the last one
  is > 24 h old; «Создать сейчас» runs one on demand; changing the password re-encrypts (new version).
  No onboarding step, no reminder card. No WorkManager.
* Welcome screen: «Присоединиться» and «Восстановить». Restore offers:
  1. username + backup password → identity, contacts, conversations, messages, groups;
  2. 24 words → identity only, empty chats; if a backup exists the app then offers to enter its password.
* The superseded install: on login the node reports the device's current registration id; a mismatch shows
  «Аккаунт восстановлен на другом телефоне» and sync stops.
* Photos are not in the backup: restored photo messages keep the thumbnail and show «нет в копии».

### Backup contents and crypto (docs/04-security.md)
* Snapshot (protobuf, gzip): seed, own profile, contacts + verification, conversations, messages,
  attachment metadata + thumbnails (no media files), groups (signed state + members), photo settings.
  Not included: Signal sessions/prekeys, sender keys, outbox, seen envelopes, endpoint stats.
* `master = Argon2id(password, salt16, m=64 MiB, t=3, p=1)`; `backup_key = HKDF(master, "otter/backup/enc/v1")`,
  `auth_secret = HKDF(master, "otter/backup/auth/v1")`, `auth_verifier = SHA-256(auth_secret)`.
  Ciphertext: Tink AesGcmHkdfStreaming (as D46), aad = blob key.

### Nodes
* Backup blob = BLOB_META with `persistent = true`: zero readers allowed, no expiry, not GC'd on reads,
  removed from `expiring()`. Deleted when superseded by a newer BACKUP_META or unreferenced 7 days after
  creation. Per-user cap: one live backup + one in-flight; size counts toward the 2 GiB quota.
* `BACKUP_META = 10` payload `{version, salt, kdf params, auth_verifier, blob_key, size}`, signed by the
  account key, latest version wins, replicates to all nodes.
* Public methods: `backup.auth{username}` → salt + kdf params (unknown username → stable fake salt
  `HMAC(node secret, username)`); `backup.fetch{username, auth_secret}` → meta; the session may then
  `blob.get` that blob only. Rate limit via `auth_failures`: 5 failures/username/hour, 20/day per node.
* `auth.login` response carries the device's current `registration_id`.
* PREKEYS with a different registration_id than stored replaces all one-time/signed/kyber keys of the device.

### Recovering sessions
* New content `SessionReset{}`. After restore the phone uploads fresh prekeys and sends SessionReset to every
  contact (new PreKey session). A receiver switches to the new session, inserts «Имя восстановил(а) аккаунт»,
  and forgets sender-key shares with that user in every common group (so group keys get re-sent).
* On an undecryptable 1:1 or sender-key-distribution message the receiver sends SessionReset to the sender,
  at most once per contact per hour.

### Done when
Wipe phone → restore with username + password → history back; contacts write to it in a direct chat and a
group with no action on their side. Automated (live mesh test) plus a two-phone checklist.

### Out of scope
Media in backups, background backups while closed, phrase rotation, multi-device.
