# OtterMSG — Documentation

OtterMSG is a private, end-to-end encrypted messenger for a closed circle of friends and
family (10–100 users). It runs on a mesh of 1–3 identical, self-hosted nodes that replicate
to each other, survive hosting outages, and are designed to keep working under active
DPI-based internet blocking.

Status: **in development** — milestones M0–M6 (incl. M1.5, M1.6) built as of 2026-11-12, M5 push with owner checks
open; next M6.5 (Otter news), then M7 (DPI transports) and M8. Details per milestone in [09](09-roadmap.md).

Code: [otter-server](https://github.com/Shuttle25/otter-server) (Go node + admin tools) and
[otter-android](https://github.com/Shuttle25/otter-android) (Android app). Implementation plans for each milestone are in
[`superpowers/plans/`](superpowers/plans), design specs in [`superpowers/specs/`](superpowers/specs).

## Documents

| # | Document | What it covers |
|---|----------|----------------|
| 00 | [Decisions log](00-decisions.md) | Every requirement and decision from the design discussion, with rationale |
| 01 | [System architecture](01-architecture.md) | Big picture: components, trust model, data lifecycle |
| 02 | [Protocol](02-protocol.md) | Identities, records, envelopes, client↔node API, message flows |
| 03 | [Mesh replication](03-mesh-replication.md) | How nodes sync, partitions, dedup, garbage collection |
| 04 | [Security & cryptography](04-security.md) | Threat model, E2E encryption, recovery phrase, password backup |
| 05 | [Transport & censorship resistance](05-transport.md) | WSS, VLESS+REALITY, CDN, network manifest, fastest-node selection |
| 06 | [Node (server) architecture](06-node-architecture.md) | Go packages, storage schema, config, push, blobs |
| 07 | [Android app architecture](07-android-architecture.md) | Modules, stack, local storage, sync engine, screens |
| 08 | [Operations](08-operations.md) | Deploying 1/2/3 nodes, admin CLI, upgrades, monitoring |
| 09 | [Roadmap](09-roadmap.md) | V1 milestones, V2 (calls, multi-device), open questions |
| 10 | [Design guidelines](10-otter-design-guidelines.md) | Android UI: tokens, typography, screens, states, copy (RU) — normative for UI |
| 11 | [Server deployment](11-deployment.md) | Build, bundle, install, TLS, systemd, upgrades, backups, scripts |

## One-paragraph summary

Every user owns their keys on their phone; servers only relay and temporarily store
signed ciphertext. Messages are encrypted with the Signal protocol (libsignal): Double
Ratchet for 1:1, Sender Keys for groups. Any node can serve any user; nodes replicate every
record to each other (transitively, so A↔B↔C works even if A↔C is blocked). The app races
all known nodes/transports and uses the fastest working one. Transports are WebSocket over
TLS (optionally behind a CDN) and VLESS+REALITY (via embedded Xray-core) for heavy DPI.
Registration is invite-only, no phone number. Recovery is by 24-word phrase (identity) and
password (encrypted history backup replicated across nodes). Push is battery-friendly
FCM wake-ups with a constant, content-free payload and an automatic 15-minute fallback when Google services are
unavailable (M5).
