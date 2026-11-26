# M12 per-chat mute — design

Approved by the owner 2026-11-26 (brainstorm). App-only change: **app 0.14.0 (versionCode 18)**; server stays 0.13.0
(only its copy of `backup.proto` changes, the binary does not). New decision **D146**. Branch `m12-mute`.

## Owner decisions

1. Every chat can be muted on its own: 1:1 chats, groups and **«Новости Выдры»**.
2. **On/off only**: muted until turned back on, no timer.
3. **Muted = silent, calls still ring**: no notification for new messages; the unread count still grows (grey in the
   chat list); calls from that person ring as before, missed calls still show.

## What people get

- **Bell button in every chat's top bar** (also in «Новости Выдры», whose top bar is empty today): 🔔 (`Notifications`
  outlined) when notifications are on, 🔕 (`NotificationsOff` outlined) when the chat is muted. One tap switches it; a
  snackbar says «Уведомления выключены» / «Уведомления включены». Content description «Выключить уведомления» /
  «Включить уведомления».
- **Long-press a chat in the chat list** → a small menu with one item «Без звука» or «Включить уведомления».
- **Chat list**: a muted chat shows a small 🔕 icon after its title; its unread badge is grey
  (`surfaceVariant` background, `onSurfaceVariant` text) instead of teal. TalkBack reads «без звука» in the row's
  description.
- Muting a chat that has a notification in the shade removes that notification (and the summary if it was the last).
- The global switch «Показывать уведомления» (Settings → Уведомления, D94) still turns everything off; per-chat mute
  only adds silence, never sound.

## What muted means

- `MessageNotifier.onIncoming` posts nothing for a muted conversation (1:1, group, news). Unread counting, receipts and
  sync are unchanged.
- Calls (`CallNotifier`, channel `calls`) and missed-call notifications (`missed_calls`) are not touched: a muted 1:1
  chat still rings. Live-location's own sharing notification is not a chat notification and is unaffected.
- The phone still wakes by Firebase and syncs as before. **Nodes are not told**: no push filtering on the node, no new
  RPC, nothing in the manifest; a node cannot learn which chats someone muted.

## Storage

- Room v12: column `conversations.muted INTEGER NOT NULL DEFAULT 0` (AutoMigration 11 → 12); existing chats stay
  unmuted.
- `ConversationDao.setMuted(id, muted)`; `ConversationSummary.muted` for the chat list.
- **Backup** (`backup.proto`, same file in both repos): `BackupConversation.muted = 9`; `BackupSnapshot.news_muted =
  14` (the news chat itself is not backed up, D67). Restore sets both; a backup from an older app restores as unmuted.
  The server copy of `backup.proto` and its generated Go code are updated so the protos stay identical; server
  behaviour does not change.

## Code shape

- `ConversationStore.setMuted(conversationId, muted)` (default no-op); `MessageRepository` implements it:
  `conversations.setMuted(...)`, and when muting, `alerts.onRead(conversationId)` to clear a shown notification.
  The chat list calls the same `MessageRepository.setMuted`.
- `ConversationUi.muted`; `ChatRow.muted`.
- `MessageNotifier.onIncoming`: `if (conv.muted) return` right after loading the conversation (before the news branch).

## Tests (each "attack" is a muted chat that tries to make noise and fails)

- Robolectric `MessageNotifierTest`: muted 1:1, muted group and muted news post nothing; unmute → the next message
  posts; muting clears a shown notification and the summary.
- A muted 1:1 chat still rings: `CallNotifier` never reads the conversation (no database dependency, kept so); its
  existing tests stay green, and a new test posts `missed()` for a conversation stored as muted.
- `MigrationTest` 11 → 12: existing rows have `muted = 0`.
- `SnapshotCodec` round-trip keeps `muted` on conversations and `news_muted`; an old snapshot without the fields
  restores unmuted.
- `conversationUi` / `chatRows` mapping carry `muted`; the bell button toggles via the view model.
- Robolectric screenshots (Roborazzi, light and dark): chat list rows muted / unmuted with unread; conversation top bar
  with 🔔 and 🔕, news chat included.
- Emulator: mute a 1:1 chat and the news chat, send from the second emulator → shade stays empty, unread grows; unmute
  → next message notifies; a call to the muted chat still rings.

## Out of scope

Timed mutes, mute by keyword or @mention, per-chat sounds, syncing mute between phones, muting on the node.
