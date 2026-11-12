# 01 — System Architecture

## Goals

1. Private E2E-encrypted messaging for ≤100 people (text, groups, media, voice messages).
2. Keep working when a hosting provider dies (1–3 redundant nodes).
3. Keep working under active DPI blocking (traffic blends in with normal HTTPS; mesh relays
   around blocked links; endpoints can be changed without app updates).
4. Battery-friendly on Android.
5. Simple to operate: one static binary per node, any Linux.

## Non-goals (V1)

Calls, multi-device, desktop client, public sign-up, federation between independent
networks, anonymity against a global passive adversary (see [04](04-security.md)).

## Big picture

```
                         ┌───────────────────────── mesh (node↔node, mutually authenticated,
                         │                           any transport, transitive relay)
   ┌──────────┐   race   ▼
   │ Android  │──────► Node A ◄──────────► Node B ◄──────────► Node C
   │   app    │  fastest  ▲  ▲                  ▲                  ▲
   └──────────┘  working  │  └──────────────────┼──────────────────┘
        │        endpoint │        (A↔C may be blocked; records still flow via B)
        │                 │
        └── FCM wake-up ◄─┘  (data-less push via Google, when available)
```

Each node:

```
┌────────────────────────── otter-node (single Go binary) ──────────────────────────┐
│ Transports in:  WSS (TLS 1.3)  │  VLESS+REALITY (embedded Xray-core)              │
│ Gateway:        client sessions, auth, request routing                            │
│ Peer link:      node↔node sessions, replication stream                            │
│ Record store:   SQLite (signed records + oplog + mailboxes + prekeys + directory) │
│ Blob store:     encrypted media/backup chunks on disk                             │
│ Replicator:     anti-entropy pull + live push between peers                       │
│ Pusher:         FCM HTTP v1 wake-ups                                              │
│ Janitor:        expiry, ACK-based deletion, log compaction                        │
└───────────────────────────────────────────────────────────────────────────────────┘
```

## Components

| Component | Language | Responsibility |
|-----------|----------|----------------|
| `otter-node` | Go | Relay, temporary storage, replication, push. All nodes identical |
| `otter-admin` | Go | Create network & admin key, sign manifest, add/remove nodes, bootstrap first invite, revoke users |
| Android app | Kotlin | All key material, all encryption, UI, node selection, outbox, backup |
| Network manifest | signed document | List of nodes + endpoints + pinned keys; distributed in invites and via any node |

## Trust model

* **Devices are trusted** (by their owner). All plaintext and private keys live only there.
* **Nodes are untrusted relays.** They see metadata (who messages whom, when, sizes) but
  never content. Every record they store or relay is signed by its author:
  * messages, ACKs, prekeys, directory entries → signed by the user's account key;
  * group membership state → signed by a group admin (and only visible inside E2E messages);
  * manifest, revocations → signed by the network admin key;
  * invites → signed by the inviting user.
* Nodes **verify signatures before accepting or relaying**. A compromised node can drop or
  delay records but cannot forge, alter, or read them; other nodes and clients reject forgeries.
* **Node ↔ node** links are mutually authenticated with node keys pinned in the manifest.

## Data lifecycle on nodes

| Data | Lifetime on nodes |
|------|-------------------|
| Message envelope | Until recipient ACK (then deleted on all nodes), max 30 days |
| ACK tombstone | 30 days (prevents resurrection by a lagging peer) |
| Media blob | Until all recipients downloaded, max 30 days |
| Directory entry, prekeys, invites | While account active |
| Encrypted backup | Latest version per user (long-lived) |
| Manifest | Latest version |

Nodes are therefore cheap to lose: a fresh node rebuilds its state by syncing from peers.

## Key flows (details in [02](02-protocol.md))

1. **Join**: scan invite QR → generate keys/phrase → register on any reachable node → record
   replicates → inviter & invitee are mutually verified contacts.
2. **Send**: encrypt locally → signed envelope to fastest node → node ACKs to sender
   (✓ "sent") → replicates to peers → whichever node the recipient connects to delivers →
   recipient sends encrypted delivery receipt (✓✓) and an ACK record → envelope deleted everywhere.
3. **Wake-up** (M5): the node that accepted the envelope sends a constant, content-free FCM push if it is
   push-capable, otherwise the first push-capable node in manifest order (D58); the app connects, drains its mailbox
   and shows a local notification. Without Google services the app checks every 15 min instead.
4. **Restore** (M6): new phone → network link → username + password → fetch the encrypted backup from any node that
   has it → decrypt → new prekeys → `SessionReset` to every contact. The old phone is cut off (D52, D56).
