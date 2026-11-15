# M9.5 Member privacy and the network code — design

Status: **draft for the owner** (2026-11-15). Agreed in chat: network code yes, catalog listing off by default,
lookup by exact username, inviter and invitee always see each other, a `@username` sent in a chat opens that person.
Built after M9.4 (it needs the M9.2 invite chain) and before M10. Server and app versions are set by the plan.

## Why

1. **Joining the wrong network.** Everything after joining is signed and checked, but the invite link itself is
   trusted on first use. A fake link to a look-alike network would look normal. A short **network code** that a new
   member compares once with the admin closes that gap.
2. **Several families on one network.** Today every phone downloads the whole directory, and «Написать» and «Семья»
   list every member, so family A can browse family B.

## Part 1: Network code (goes into the M9.4 network status screen)

- **Code:** 15 digits in three groups, `12345 67890 13579`, derived from the network public key:
  the first 8 bytes of `SHA-256("otter-network-code" ‖ network_pub)` as a big-endian integer, mod 10^15, zero-padded.
  Digits work across languages and read well over the phone.
- **Where it shows:**
  - the join screen, before «Присоединиться»: «Код сети: 12345 67890 13579. Сверьте его с тем, кто вас пригласил»;
  - Settings → «Сеть» (the M9.4 status screen), with the version of each node the phone talked to
    (information only, after login; a node can lie about it);
  - `otter-admin network code` for the admin.
- **The network key never changes for an installed app.** The app already refuses a manifest with another
  `network_pub` (`ManifestVerifier`, "foreign network"). Add a test that pins this, and show a clear stop screen
  instead of a silent retry: «Сеть изменилась. Не вводите пароли и обратитесь к администратору».
- **No per-node fingerprints for users.** Node keys are pinned through the signed manifest already and rotate
  legitimately; a visible "fingerprint changed" warning would fire on normal maintenance. A compromised node keeps its
  real key, so a node fingerprint would not reveal it anyway.
- Node version is shown only to logged-in members. Strangers still see only the decoy website.

## Part 2: Who sees whom

### Rules

A member **sees** (in «Написать», «Семья», search) only:
1. the person who invited them, and everyone they invited (always, both ways; from the M9.2 invite chain);
2. people they already share a chat or group with;
3. members who switched on «Показывать меня в каталоге сети» (**off by default**, also for existing members
   after the upgrade).

Anyone can still be **reached** by:
- exact `@username` (typed in «Написать», or tapped in a message);
- an invite link (as today).

### A `@username` in a message

- `@name` and `@name#abcd` (D31 clash tag) in message text become links, like web links.
- Tap → exact lookup → a card with avatar, display name, `@username` and «Написать» (or «Открыть чат» if a chat exists).
  Not found → «Пользователь не найден».
- Profile gets «Поделиться именем пользователя», which copies or shares `@username`.

### What it does and does not hide

- It hides members from **other members' phones**. Nodes, and the admin, still hold every account: they need the
  keys to deliver messages. This is stated plainly in the settings text.
- The listing flag lives in the user's **own signed directory entry**, so a hostile node cannot list someone who
  chose not to be listed. A node can still hide a listed member (refusal of service, accepted by the M9 threat model).

### Protocol

- `DirectoryEntry.listed = 12` (bool, signed by the account; fields 10 and 11 are M9.2's invite chain).
- `directory.sync{since}` returns only: the caller's own entry, entries of `listed` members, the caller's inviter and
  invitees (from the invite chain), and every `REVOCATION`. Group members and chat partners are fetched by id.
- New `directory.get{user_ids}` → entries for known random 16-byte ids (learned from a chat, a group or an invite).
  Ids cannot be guessed, so no rate limit beyond the per-connection limits of M9.4.
- New `directory.lookup{username}` → one entry or `NOT_FOUND`, exact match only (case-insensitive, `#abcd` honoured).
  Limited per account: 30 per hour and 200 per day, failed lookups included, so nobody walks the name space.
- `Manifest.directory_full_until_ms = 8`: until this time nodes still answer `directory.sync` from apps older than
  M9.5 with the full directory, so old apps keep working during the rollout; after it, every app gets the filtered set.
  The admin sets it with `otter-admin manifest set-directory-cutover --at <date>` once every phone runs the new app.
- Every rule is checked by the node that answers; replication is unchanged (all nodes keep all entries).

### App

- Directory store keeps an entry once fetched (a chat or group partner stays visible after they leave the catalog).
- After the upgrade, entries the phone already has stay where a chat or group exists; other entries leave the
  catalog but stay in the local store for safety numbers.
- Settings → «Приватность»: «Показывать меня в каталоге сети» (off), with the explanation from "What it does and does
  not hide".
- «Написать»: a search field that first filters visible people, then offers «Найти @name» for an exact lookup.

## Hostile-node tests (M9 rule)

- A node that lists a non-listed member: the app trusts only the signed `listed` flag and refuses to show them in the
  catalog (they stay reachable by exact username).
- A node that answers `directory.lookup` with another user's entry: the app checks the username in the signed entry and
  the account signature, and drops a mismatch.
- A node that sends a manifest with another `network_pub`: stop screen, nothing else changes.

## Out of scope

- Hiding accounts from nodes or the admin.
- Per-family sub-networks (separate network keys per family).
- Contact requests or approval before someone can write to you.

## Owner questions

| # | Question | Recommendation |
|---|---|---|
| 1 | Lookup limits 30/hour, 200/day per account | Accept |
| 2 | Shown version: each node's version in «Сеть», or only the node in use | Each node the phone used recently |
| 3 | Build order: after M9.4, before M10 | Accept |
