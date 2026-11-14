# M9 Security hardening: "assume any node can be hostile"

Status: **draft for the owner** (2026-11-14). Replaces the M8.1 row and the security part of M9 in `09-roadmap.md` once approved.
Source: the combined security audit (kept outside the repos), findings C1–C28 and four design limits.
C27 and the publish-safety part of C28 are **done** (history rewrite and `secrets-check.sh`, D57, 2026-11-14).

## Threat model (owner, 2026-11-14)

Linux servers are compromised easily, so **any one node may be run by an attacker**: it lies in every answer, injects records
through replication, reads its own disk and sees everything that terminates on it. The design must still guarantee:

1. A hostile node cannot read messages, calls or backups, and cannot cheaply guess backup passwords.
2. It cannot impersonate a member, admit members on its own, or restore a revoked member.
3. It cannot permanently break a phone or another node (no "poison" answers, no unbounded input).
4. A hostile node *process* cannot become root on its own host.
5. What it can still do (accepted): refuse service (the phone uses another node), see metadata it carries (who talks
   to whom, when, sizes), relay call media it cannot decrypt.

## Phases

Each phase is one plan (`docs/superpowers/plans/…`), one branch per repo, merged `--no-ff` after the owner's OK.

### M9.0: Server hotfix (server 0.8.3), first because it is small and closes host takeover

| # | Fix |
|---|---|
| C3 | `otter-node apk import` runs as `otter`, never chowns; `release-apk.sh` uploads into a root-owned 0700 temp dir and passes the file by descriptor. Test: a symlink planted by `otter` is refused. |
| C11 | Peer boundary and `blobs.Dir` refuse blob keys that are not 32 bytes (status INVALID, session continues). Test: empty key from a peer no longer stops the node. |
| C26 | DB backups written 0600 `otter:otter`; `upgrade.sh` keeps the newest 3 pre-upgrade copies. |
| C25 | Rejected-peer source IPs kept 7 days, then purged by the janitor. |

### M9.1: The phone trusts no node (app 0.9.0 + small server parts)

| # | Fix |
|---|---|
| C1 | Client-owned KDF profiles: profile 1 = Argon2id m 64 MiB, t 3, p 1, 16-byte salt. The node's numbers are only an ID check; anything else fails the restore before the password is used. Room for a stronger profile 2 later (for example 128 MiB) chosen by the phone, never by the node. |
| C13 | Restore verifies the `BACKUP_META` and `BLOB_META` signatures with the account key from the decrypted seed, and that the salt in the signed meta equals the salt the node returned; else "Corrupt", nothing installed. |
| C18 | Words-only restore uses the same directory-entry verification as normal sync (signature by the account key, newest valid version). |
| C14 | "A newer install exists" is believed only with an account-signed install record (`INSTALL{registration_id, installed_ms}`). An unsigned or invalid claim is ignored and logged. Recovery path: Settings → «Этот телефон снова главный» re-signs the install. |
| C15 | An envelope is marked seen only in the same transaction that stores the decrypted message; a forged copy is dropped without blocking the real one. |
| C16 | After a manifest update, only endpoints and pins in the newest valid manifest are used; the 7-day fallback applies only to endpoints that manifest still lists. |
| C17 | Size limits at receipt: RPC frame 1 MiB, blob chunk 256 KiB + overhead, APK chunk 1 MiB, APK total 100 MiB; over-limit closes the connection and tries another node. |
| C20 | Every node answers `backup.auth` for every username, with or without a backup: profile 1 and a fake salt = HMAC(network key, username), the same on every node. Backup existence is no longer visible. |
| C21 | Thumbnails decoded with `inSampleSize` to at most 4096×4096 pixels; bigger images show «Фото повреждено». |
| C22 | `FLAG_SECURE` on the backup-password, recovery-words and restore screens. |
| C23 | The inviter contact from a link is stored **unverified** until its directory entry verifies; the chat shows the normal safety-number state. |
| C24 | The shareable connection log replaces hosts with node labels and rounds times to the minute; the full log stays on the phone. |
| C19 | Release build fails without the release keystore (no debug-key fallback). |
| Push | Notification switches (see the owner's decision in the chat). |

### M9.2: Nodes cannot change who is a member (server 0.9.0 + app 0.9.x)

| # | Fix |
|---|---|
| C2 | `REVOCATION` and `INVITE_RIGHTS` are applied when accepted or replicated, in the same transaction: revoked users cannot log in, submit, invite or get TURN credentials; their open sessions are closed. App: groups drop revoked members and rotate sender keys; 1:1 chats show «Участник удалён». `otter-admin user revoke/list`. |
| Limit 3 + C6 | **Invite proof travels with the account.** Registration replicates the signed `INVITE` (by an inviter with invite rights, back to the admin key) and the new member's signed redemption. Every node checks the whole chain itself before accepting the account; a replicated account without a valid chain is refused. `can_invite` comes only from the invite or a signed `INVITE_RIGHTS`, never from the applicant's own entry. |
| C5 | Each invite is single use network-wide by a deterministic rule: if two redemptions of one invite meet, the one with the lower record hash stays; the other account is disabled on every node and the inviter is told. |
| C12 | Username clash: the rank comes from the redemption record (invite chain), not from a time the applicant claims. A clashing name is shown as `name#abcd` (D31) and restore by username asks for the `#abcd` tag when the name is ambiguous. |
| C4 | Failed recovery attempts throttled per (account, source IP) instead of per account, so a stranger cannot lock someone's recovery. |
| C10, C9 | Recovery attempts and blob quotas reserved inside the write transaction. |
| C8 | Per-author budgets: ≤ 200 live `PREKEYS`, 4 `PUSH_TOKEN` per device, 50 `INVITE` per month; the janitor compacts superseded ones on every node. |
| M8 review | A fresh read of the M8 call code with this threat model (TURN credentials, call pushes, signaling expiry). Media is already safe: SDP and DTLS fingerprints travel inside end-to-end envelopes. |

### M9.3: Bound to the network, lost phones, backups away from exposed nodes

| # | Fix |
|---|---|
| C7 | Signature format v2: every user-signed record signs `"otter-v2" ‖ network_id ‖ body`. Nodes accept v1 for records created before the cut-over date in the manifest and refuse new v1 records after it; apps sign v2 from 0.9.x. |
| Limit 2 | **Lost-phone re-key.** Whoever holds the 12 words *is* the account, so a stolen phone cannot be locked out by flags. Fix: the admin signs `REKEY{old_user, new_user}`: the old key is revoked (M9.2), the new account keeps the username and contacts, and the contacts see «ключ безопасности изменился». |
| Limit 1 | **No backups on dial-out-only nodes** (owner). A node with `dial_out_only` in the manifest keeps backup records and blobs only until a non-dial-out node confirms them, then deletes them; it never serves `backup.auth/fetch` from its own disk. Phones restore through a TCP pass-through on that node to a foreign node (TLS ends on the foreign node, pinned as usual), so the dial-out node sees neither the salt nor the password check. |

### M9.4: Ops (existing M9 scope, unchanged)

Per-user quotas, per-IP limits, disk floor, replication keep-alive ping (25 s), monitoring (`status.sh`, `otter-node status`,
`/metrics`), app lock, network status screen, 3-node deployment guide.

## Order and rollout

M9.0 → M9.1 → M9.2 → M9.3 → ru-1 joins → M9.4. If ru-1 is needed sooner, it can join after M9.1 with backups switched off on it (the storage half of the dial-out rule, a small change).

Every phase ends with: all tests green, a "hostile node" test that plays the attacker for each fix (fake-node tests on
Android, `meshsim` scenarios on the server), `secrets-check.sh` ok, and the owner's OK before merge and before any server touch.
