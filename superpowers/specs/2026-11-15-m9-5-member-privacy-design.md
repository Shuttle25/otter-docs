# M9.5 Member privacy and the network code — design

Status: **approved by the owner** (2026-11-15). Agreed in chat: network code yes, catalog listing off by default,
lookup by exact username, inviter and invitee always see each other (one level only), a `@username` sent in a chat
opens that person, filtering by the node (option 3 of open / app-only / node filter / private discovery), no
transition period for old apps.
Built after M9.4 (it needs the M9.2 invite chain) and before M10: server 0.11.0, app 0.11.0 (15).

**As built (2026-11-19), corrections to this spec** (details in `00-decisions.md` D135–D139):
- The clash tag has **8 hex digits** (`name#1a2b3c4d`, D103), not 4.
- Directory answers also carry the **invite ancestry** of every entry (inviter, inviter's inviter, … and rival
  redemptions), which phones need to verify invite chains (D135). Phones store these entries but never show them.
- The `directory` event **stays a broadcast** (D138); a targeted event would stop chat partners from learning a new name.
- The node version travels in **`LoginResponse.server_version`** (members only), not in `hello` (D139).
- `directory.list` has no `since`; there is no `Manifest.directory_full_until_ms`.
- «Сеть изменилась» is a dismissable warning shown once per app run, not a stop screen (D139); the switch sits in the
  plain settings list after «Запрет скриншотов», not in a «Приватность» section.
- Old apps are those up to 0.10.1.

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
    (information only, after login; a node can lie about it; as built it comes in `LoginResponse.server_version`);
  - `otter-admin network code` for the admin.
- **The network key never changes for an installed app.** The app already refuses a manifest with another
  `network_pub` (`ManifestVerifier`, "foreign network"). Add a test that pins this, and show a clear stop screen
  instead of a silent retry: «Сеть изменилась. Не вводите пароли и обратитесь к администратору». (As built: a
  warning with «Понятно», once per app run, D139.)
- **No per-node fingerprints for users.** Node keys are pinned through the signed manifest already and rotate
  legitimately; a visible "fingerprint changed" warning would fire on normal maintenance. A compromised node keeps its
  real key, so a node fingerprint would not reveal it anyway.
- Node version is shown only to logged-in members. Strangers still see only the decoy website.

## Part 2: Who sees whom

### Rules

A member **sees** (in «Написать», «Семья», search) only:
1. the person who invited them, and everyone they invited directly (always, both ways; from the M9.2 invite chain).
   **One level only:** if A invites B and B invites C, then A sees B, B sees A and C, C sees B; A and C do not see
   each other until rule 2 or 3 applies or one of them looks the other up by `@username`;
2. people they already share a chat or group with;
3. members who switched on «Показывать меня в каталоге сети» (**off by default**, also for existing members
   after the upgrade).

Anyone can still be **reached** by:
- exact `@username` (typed in «Написать», or tapped in a message);
- an invite link (as today).

### A `@username` in a message

- `@name` and `@name#1a2b3c4d` (D103 clash tag, 8 hex digits) in message text become links, like web links.
- Tap → exact lookup → a card with avatar, display name, `@username` and «Написать» (or «Открыть чат» if a chat exists).
  Not found → «Пользователь не найден».
- Profile gets «Поделиться именем пользователя», which copies or shares `@username`.

### What it does and does not hide

- The main gain: one lost, seized or infected phone exposes only that member's own contacts and the listed members,
  not the whole network. Exact lookup is rate limited, so the name space cannot be walked.

- It hides members from **other members' phones**. Nodes, and the admin, still hold every account: they need the
  keys to deliver messages. This is stated plainly in the settings text.
- The listing flag lives in the user's **own signed directory entry**, so a hostile node cannot list someone who
  chose not to be listed. A node can still hide a listed member (refusal of service, accepted by the M9 threat model).

### Protocol

- `DirectoryEntry.listed = 12` (bool, signed by the account; fields 10 and 11 are M9.2's invite chain).
- The phone keeps one WebSocket; methods are named per request, so the new calls are **new method names**, not a new
  URL, and the node tells old and new apps apart by the method alone (no app version check).
- New `directory.list` (new apps) returns only: the caller's own entry, entries of `listed` members, the
  caller's direct inviter and invitees (from the invite chain), the invite ancestry and rival redemptions of all of
  these (D135), and every `REVOCATION`, `INVITE_RIGHTS` and `REKEY`. Group members and chat partners are fetched by id.
- ~~The `directory` change event goes only to phones whose `directory.list` set contains the changed entry (or whose
  own entry changed).~~ As built: the event stays a broadcast to every logged-in phone (D138).
- New `directory.get{user_ids}` → entries for known random 16-byte ids (learned from a chat, a group or an invite).
  Ids cannot be guessed, so no rate limit beyond the per-connection limits of M9.4.
- New `directory.lookup{username}` → one entry or `NOT_FOUND`, exact match only (case-insensitive, `#1a2b3c4d` honoured).
  Limited per account: 30 per hour and 200 per day, failed lookups included, so nobody walks the name space.
- Every rule is checked by the node that answers; replication is unchanged (all nodes keep all entries).

### Compatibility (no transition period, owner)

| | Old app (≤ 0.10.1) | New app (M9.5, 0.11.0) |
|---|---|---|
| Directory list | `directory.sync`, which now returns the **same filtered set** as `directory.list` from the day the node is upgraded | `directory.list` |
| By id / exact name | — | `directory.get`, `directory.lookup` |
| `directory` event | gets it, calls `directory.sync` | gets it, calls `directory.list` |
| `listed` field 12 | unknown field, skipped by protobuf; the signature still checks (it covers the record body bytes) | read and shown |
| Own profile edit | entry without `listed` = off (the safe default) | entry with the switch value |

- Old apps never get an error. They keep chatting with everyone they already have; their «Написать»/«Семья» list
  shrinks to the filtered set until the member updates (the APK comes from Otter's own nodes). There is no cut-over
  date and no manifest field: new members are never visible to strangers, not even for a day.
  As built, two limits until the member updates: old apps also show the ancestry entries (they have no catalog
  filter), and they cannot read a message from a sender outside their visible set (they only call `directory.sync`),
  so such messages wait on the node until the app is updated.
- **Old node, new app** (only while the owner upgrades nodes): an old node answers "unknown method" to
  `directory.list`; the app falls back to `directory.sync` and applies the same rules itself before showing anything.
  `directory.get`/`lookup` fail on an old node with «Сервер устарел, попробуйте позже».
- Rollout order as always: every node first, then the APK.
- Old nodes copy and store the `listed` field without reading it.

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

## Owner decisions (2026-11-15)

| # | Question | Decision |
|---|---|---|
| 1 | Lookup limits | 30/hour, 200/day per account |
| 2 | Versions shown in «Сеть» | Each node the phone used recently |
| 3 | Build order | After M9.4, before M10 |
| 4 | Architecture | Node-side filter (option 3); open directory, app-only hiding and private discovery rejected |
| 5 | Old apps | No transition: `directory.sync` is filtered from the first upgraded node |
| 6 | Invite visibility | One level only (direct inviter and invitees) |
