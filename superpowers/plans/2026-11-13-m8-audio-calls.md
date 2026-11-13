# M8 1:1 Audio Calls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two family phones hold an end-to-end encrypted 1:1 audio call through a TURN relay embedded in their own
Otter nodes, ringing via the existing push path, with the call shown as a line in the 1:1 chat.

**Architecture:** `otter-node` embeds Pion TURN (UDP 3478, TCP 3478, TLS 5349, UDP relay ports 49160–49200,
per-node secret, TURN-REST credentials issued by a new `turn.credentials` RPC). Phones signal with a new
Signal-encrypted `Content.call` (`CallMessage`) sent through the existing outbox/mailbox with a 2-minute record
expiry; media is WebRTC (Opus, DTLS-SRTP) whose fingerprints travel only inside the encrypted offer/answer. A pure
Kotlin `CallStateMachine` drives a `CallManager`; WebRTC sits behind a `MediaEngine` interface; Android integration
uses `androidx.core:core-telecom`, a `phoneCall` foreground service and a full-screen CallStyle notification.

**Tech Stack:** Go 1.26, `github.com/pion/turn/v5 v5.1.3`, SQLite; Android Kotlin 2.2.21, AGP 8.13.2,
`io.github.webrtc-sdk:android:150.7871.04` (WebRTC M150), `androidx.core:core-telecom:1.0.1`, `androidx.core:core-ktx
1.17.0` (CallStyle), Room 2.8.3 (AutoMigration 7→8), Hilt, Compose.

**Spec:** `docs/superpowers/specs/2026-11-13-m8-audio-calls-design.md` (owner approved 2026-11-13).

**Ground rules (owner):**
* Branch `m8-calls` in `otter-server`, `otter-android` and `docs`; TDD, small commits; merge with `--no-ff` **only
  after the owner says so**. Run `scripts/secrets-check.sh` in every repo (all three have it) before any push.
* Never touch `root@eeee`, the ru-1 node, DNS, `~/.otter-admin` or the phones without asking. Passphrases are typed
  only in the owner's terminal. Never delete anything in `otter-server/dist/`. Run `deploy/test/scripts_test.sh` only
  in a scratch copy (it writes into `dist/`).
* Never create, print or commit `google-services.json`, `fcm*.json`, `release.jks` or `keystore.properties`. Phone
  APKs are release-signed. Never use the owner's own account in scripts. Never write to the desktop keyring without asking.
* `otter-node` rejects unknown config keys: `[turn]` may be written only after the 0.8.0 binary is installed.
* Environment: `export PATH=/usr/lib/go-1.26/bin:$HOME/go/bin:$PATH`;
  `export JAVA_HOME=~/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2`; dev mesh in `otter-server/.dev-mesh`
  (`scripts/dev-mesh.sh`, admin `bin/otter-admin --dir .dev-mesh/admin`, `OTTER_ADMIN_PASSPHRASE=dev-only-passphrase`).
* Real server IPs never go into any repo (`~/.otter-real-ips` is checked by `secrets-check.sh`); use `<eeee-ip>`,
  `203.0.113.x` or `1.2.3.4` in docs and tests.
* Commits end with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01S4HpRE25HCYGuf99akymrv
  ```
* Versions: server **0.8.0**, app **0.8.0 / versionCode 8**.

## Verified facts (2026-11-13, recorded before writing the tasks)

| Question | Answer | Source |
|---|---|---|
| Pion TURN version | **`github.com/pion/turn/v5 v5.1.3`** (2026-10-24, MIT). v4's last release is v4.1.4 (2025-11-14); v5 is the maintained line, so the plan uses v5 instead of the spec's "v4". Needs `pion/stun/v4 v4.0.1`, `pion/transport/v5 v5.1.1`. No pion module in `go.mod` today. | `go list -m -versions`, module source |
| v5 API used | `ServerConfig{PacketConnConfigs, ListenerConfigs, LoggerFactory, Realm, AuthHandler, QuotaHandler, EventHandler, ChannelBindTimeout, PermissionTimeout, AllocationLifetime, InboundMTU}`; `AuthHandler func(ra *RequestAttributes) (userID string, key []byte, ok bool)`; `LongTermTURNRESTAuthHandler(sharedSecret string, logger) AuthHandler` (username `"<unix expiry>:<user>"`, password `base64(HMAC-SHA1(secret, username))`, returns `userID` = part after `:`); `QuotaHandler func(username, realm string, srcAddr net.Addr) bool` (false → 486); `PermissionHandler func(clientAddr net.Addr, peerIP net.IP) bool` on each Packet/ListenerConfig (false → 403); `EventHandler.OnAuth / OnAllocationCreated / OnAllocationDeleted`; `RelayAddressGeneratorPortRange{RelayAddress, MinPort, MaxPort, Address}` with `AllocatePacketConn / AllocateListener / AllocateConn`; `Server.AllocationCount()`; client `NewClient(&ClientConfig{...})`, `Listen()`, `Allocate()`, `CreatePermission()`, `NewSTUNConn(net.Conn)`. No built-in per-user quota (count with EventHandler, as `examples/turn-server/simple-quota`). v5 also allows RFC 6062 TCP relays → refuse them in our generator. **Confirm each name with `go doc github.com/pion/turn/v5 <Name>` before coding.** | pion/turn v5.1.3 source |
| WebRTC AAR | **`io.github.webrtc-sdk:android:150.7871.04`** (2026-10-23, BSD-3-Clause, WebRTC **M150**, package `org.webrtc`). ABIs arm64-v8a/armeabi-v7a/x86/x86_64; arm64-v8a and x86_64 `.so` LOAD `p_align = 0x4000` (16 KB), 32-bit 0x1000 (exempt). Chosen over `io.getstream:stream-webrtc-android:1.3.10` (Apache-2.0, smaller, but undocumented milestone, quiet repo, open 16 KB issue #312): a current WebRTC milestone matters more for a network-facing media stack than ~10 MB of APK. | Maven Central, `readelf -lW` on the AARs |
| core-telecom | **`androidx.core:core-telecom:1.0.1`** (2025-08-27; minSdk **23** → API 26 fine). 1.1.0 (2026-11-04) is < 2 weeks old. Merges `MANAGE_OWN_CALLS`, `BLUETOOTH_CONNECT`, `MODIFY_AUDIO_SETTINGS` and its `JetpackConnectionService`. `addCall`'s `block` is **not** suspend in 1.0.1 (launch inside). Post the CallStyle notification within 5 s of `addCall`; remote lambdas must finish within 5 s; route audio only via `requestEndpointChange`. | dl.google.com, javap, Android telecom guide |
| CallStyle / FGS | `NotificationCompat.CallStyle.forIncomingCall/forOngoingCall` in core 1.17.0; `NotificationManagerCompat.canUseFullScreenIntent()`; `Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT` (API 34); `FOREGROUND_SERVICE_TYPE_PHONE_CALL` (API 29), permission `FOREGROUND_SERVICE_PHONE_CALL` (API 34) needs `MANAGE_OWN_CALLS`; `microphone` type only after the user answers (while-in-use rule). | api-versions.xml, FGS types page |
| 0.7.0 app + unknown `Content.body` | `MailboxReceiver` acks it, shows nothing, sends no receipt, posts no notification — **but `getOrCreateDirect` creates an empty direct chat** if none exists. Accepted (only old phones, only when no chat exists); mentioned in the 0.8.0 news. | `MailboxReceiver.kt:83-105` |
| Short envelope expiry | Nodes **accept** `expires_ms = created + 2 min` (`validate.go:94-96` only rejects already-expired records; replication drops already-expired records silently, `replicated.go:30`). But nodes **neither filter nor purge** by `expires_ms`: `Store.Mailbox` ignores it (`query.go:110-113`) and the janitor deletes envelopes by 30-day receive age only (`janitor.go`). → **Task 2** adds the filter and the purge. The phone's `Outbox` never sets `expires_ms` (`RecordCodec.body(..., expiresMs = 0)`) and has no expiry column → **Task 10**. | server + app code |
| Error code for "not available" | `api.proto` `Status` has no fitting value (OK, RETRY_LATER, UNAUTHORIZED, INVALID, NOT_FOUND, CONFLICT, REVOKED, QUOTA, INTERNAL). Add **`STATUS_UNAVAILABLE = 9`** (`service.ErrUnavailable`). Old nodes answer an unknown method with `STATUS_INVALID` (`methods.go:248`); the phone treats `UNAVAILABLE` and `INVALID` on these two RPCs as "calls not available on this node". | `api.proto:10-20`, `methods.go` |
| OTTER_IP / node env | `otter-admin node env --label L` (`internal/admin/nodeops.go:191 NodeEnv`), eval'd by `node_env` in `deploy/lib.sh`; `OTTER_IP` = first `NodeIPs` entry. There is no `otter-node env`. | `nodeops.go`, `lib.sh` |
| node.toml rollback | `deploy/upgrade.sh` copies `node.toml` → `node.toml.prev` before the swap and restores it with the binary and DB on a failed health check. `bundle/install.sh` **overwrites** `node.toml` from the template on every (re)install. `reality-setup.sh` is the model for adding a section after the upgrade (`node.toml.new` → `otter-node check` → swap → health + journal marker → rollback to `node.toml.pre-reality`). | deploy scripts |
| netlog API | `netlog.Entry{Peer, Endpoint, Direction, Result, Detail string; Class Class}`, `netlog.Logger.Add(ctx, e)`, `netlog.StoreLogger{S}`, `store.NetlogAdd` merges same (peer, endpoint, direction, result, class); direction is free text. | `internal/netlog/`, `store/netlog.go` |

## File map

**otter-server**
| File | Responsibility |
|---|---|
| `proto/otter/v1/content.proto` | `CallMessage` (+ offer/answer/candidates/hangup) as `Content.call = 6` |
| `proto/otter/v1/api.proto` | `STATUS_UNAVAILABLE = 9`, `TurnCredentials`, `PushStatusRequest`, `PushStatus` |
| `internal/store/query.go`, `internal/store/janitor.go` | expired envelopes not delivered; purged by `expires_ms` |
| `internal/config/config.go` | optional `[turn]` section |
| `internal/turnsrv/` (new: `creds.go`, `peers.go`, `relay.go`, `server.go`, `stats.go`, `keygen.go`) | embedded TURN |
| `internal/nodecheck/check.go` | `[turn]` + secret check |
| `internal/service/calls.go` (new), `service.go`, `errors.go` | `TurnCredentials`, `PushStatus`, `ErrUnavailable` |
| `internal/gateway/methods.go` | `turn.credentials`, `push.status`, status mapping |
| `cmd/otter-node/main.go` | `turn keygen`, start/stop TURN, stats line |
| `internal/meshsim/turn_test.go` (new), `harness_test.go` | relay tests |
| `deploy/templates/node.toml`, `deploy/bundle/install.sh`, `deploy/make-bundle.sh`, `deploy/turn-setup.sh` (new), `deploy/upgrade-all.sh`, `deploy/status.sh`, `deploy/test/scripts_test.sh` | ops |
| `docs/m8-manual-test.md` (new), `README.md`, `deploy/README.md` | docs |

**otter-android**
| File | Responsibility |
|---|---|
| `core/proto/src/main/proto/otter/v1/*.proto` | synced |
| `gradle/libs.versions.toml`, `app/build.gradle.kts`, `settings.gradle.kts` | deps, release ABIs, `:feature:calls`, 0.8.0/8 |
| `core/network/.../NodeApi.kt` | `turnCredentials()`, `pushStatus()` |
| `core/database/.../entity/MessageEntity.kt`, `OutboxEntity.kt`, `model/MessageStatus.kt`, `OtterDatabase.kt` | Room v8 (call columns, outbox expiry) |
| `core/data/.../messaging/Outbox.kt`, `MailboxReceiver.kt` | expiry, call dispatch |
| `core/data/.../calls/` (new: `CallStateMachine.kt`, `CallModels.kt`, `CallSignaling.kt`, `CallLines.kt`, `MediaEngine.kt`, `CallManager.kt`, `TurnCache.kt`, `CallAlerts.kt`) | call logic, pure where possible |
| `core/data/.../settings/Settings.kt` | `callsRelayOnly` |
| `feature/calls/` (new module: `WebRtcEngine.kt`, `CallScreen.kt`, `CallViewModel.kt`, strings) | WebRTC + call UI |
| `app/.../calls/` (new: `CallService.kt`, `CallNotifier.kt`, `CallActivity.kt`, `CallModule.kt`), `AndroidManifest.xml` | telecom, FGS, ringing |
| `feature/conversation/...` | call button, call lines |
| `feature/chats/...ChatListViewModel.kt` | call preview text |
| `feature/settings/...` | relay-only toggle, full-screen-intent fix row |
| `docs/m8-manual-test.md` (new) | checklist |

---
### Task 1: Branches, proto (`CallMessage`, TURN/push RPC messages) and protocol doc

**Goal:** The wire format for call signaling and the two new RPCs exists in both repos and is documented.

**Files:**
- Modify: `otter-server/proto/otter/v1/content.proto`, `otter-server/proto/otter/v1/api.proto`
- Generated: `otter-server/internal/proto/otterv1/*.pb.go` (`make gen`)
- Sync: `otter-android/core/proto/src/main/proto/otter/v1/*.proto` (`scripts/sync-proto.sh`)
- Modify: `docs/02-protocol.md` (RPC table + §Content)
- Test: `otter-server/internal/proto/otterv1/call_roundtrip_test.go` (new)

**Acceptance Criteria:**
- [ ] Branch `m8-calls` exists in `otter-server`, `otter-android`, `docs` (from `main`).
- [ ] `Content.call = 6` (`CallMessage`) round-trips; `STATUS_UNAVAILABLE = 9` exists; `TurnCredentials`,
  `PushStatusRequest`, `PushStatus` exist; `buf lint` passes.
- [ ] Android proto copies are identical (`diff -r`); `./gradlew :core:proto:build` passes.
- [ ] `docs/02-protocol.md` lists `turn.credentials` and `push.status` and the `call` content.

**Verify:** `cd otter-server && make gen && go test ./internal/proto/... -count=1` → `ok`

**Steps:**

- [ ] **Step 1: Branches**

```bash
cd ~/Documents/Projects/OttterMSG
for r in otter-server otter-android docs; do git -C $r checkout main && git -C $r pull --ff-only && git -C $r checkout -b m8-calls; done
```

- [ ] **Step 2: Write the failing round-trip test** `otter-server/internal/proto/otterv1/call_roundtrip_test.go`

```go
package otterv1

import (
	"bytes"
	"testing"

	"google.golang.org/protobuf/proto"
)

func TestCallMessageRoundTrip(t *testing.T) {
	id := bytes.Repeat([]byte{7}, 16)
	in := &Content{SentMs: 5, Body: &Content_Call{Call: &CallMessage{CallId: id,
		Kind: &CallMessage_Offer{Offer: &CallOffer{Sdp: "v=0", Restart: true}}}}}
	raw, err := proto.Marshal(in)
	if err != nil {
		t.Fatal(err)
	}
	var out Content
	if err := proto.Unmarshal(raw, &out); err != nil {
		t.Fatal(err)
	}
	c := out.GetCall()
	if !bytes.Equal(c.GetCallId(), id) || c.GetOffer().GetSdp() != "v=0" || !c.GetOffer().GetRestart() {
		t.Fatalf("round trip lost data: %v", &out)
	}
	h := &CallMessage{Kind: &CallMessage_Hangup{Hangup: &CallHangup{Reason: CallHangup_BUSY}}}
	if h.GetHangup().GetReason() != CallHangup_BUSY {
		t.Fatal("hangup reason")
	}
	if Status_STATUS_UNAVAILABLE != 9 {
		t.Fatal("STATUS_UNAVAILABLE must be 9")
	}
}
```

- [ ] **Step 3: Run it — fails** (`go test ./internal/proto/...` → `undefined: Content_Call`).

- [ ] **Step 4: Edit `content.proto`.** In `message Content`'s `oneof body` add `CallMessage call = 6;` after
  `session_reset = 5`. Append at the end of the file (enum style follows the existing `ReceiptMessage.Type`, which
  has no value prefix; if `buf lint` asks for prefixes, use whatever the existing enums in this file do):

```proto
// 1:1 call signaling (D78). Sent as an ordinary Signal-encrypted 1:1 envelope, urgent, record expiry created + 2 min.
// The DTLS fingerprints inside the SDP travel only here, so nodes and TURN relays cannot intercept the media.
message CallMessage {
  bytes call_id = 1; // 16 random bytes chosen by the caller; glare: the smaller call_id (bytewise) wins
  oneof kind {
    CallOffer offer = 2;
    CallAnswer answer = 3;
    IceCandidates candidates = 4;
    CallHangup hangup = 5;
  }
}

message CallOffer {
  string sdp = 1;     // includes the candidates gathered in the first ~2 s
  bool restart = 2;   // ICE restart within an existing call (same call_id)
}

message CallAnswer {
  string sdp = 1;
}

message IceCandidate {
  string sdp_mid = 1;
  int32 sdp_mline_index = 2;
  string candidate = 3;
}

message IceCandidates {
  repeated IceCandidate candidates = 1; // late (trickled) candidates only
}

message CallHangup {
  enum Reason {
    NORMAL = 0;
    BUSY = 1;
    DECLINED = 2;
    TIMEOUT = 3;
    FAILED = 4;
  }
  Reason reason = 1;
}
```

- [ ] **Step 5: Edit `api.proto`.** In `enum Status` add `STATUS_UNAVAILABLE = 9; // feature not enabled on this node
  (e.g. TURN off)`. Append:

```proto
// turn.credentials (logged in) → TurnCredentials. TURN-REST credentials valid only on this node (D77).
message TurnCredentials {
  string username = 1;      // "<unix expiry>:<hex(sha256(user_id))[0:16]>"
  string password = 2;      // base64(HMAC-SHA1(node secret, username))
  uint32 ttl_s = 3;         // 43200 (12 h)
  repeated string urls = 4; // turn:IP:3478?transport=udp, turn:IP:3478?transport=tcp, turns:IP:5349?transport=tcp
}

// push.status (logged in): may this user's phone be woken by push? Family-internal information only.
message PushStatusRequest {
  bytes user_id = 1;
}

message PushStatus {
  bool has_push = 1;
}
```

- [ ] **Step 6: Generate and test.** `make gen && go test ./internal/proto/... -count=1` → `ok`.

- [ ] **Step 7: Sync to Android and build.**

```bash
cd ~/Documents/Projects/OttterMSG/otter-android && scripts/sync-proto.sh
diff -r ../otter-server/proto/otter/v1 core/proto/src/main/proto/otter/v1 && echo same
JAVA_HOME=~/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2 ./gradlew :core:proto:build -q
```

- [ ] **Step 8: Protocol doc** (`docs/02-protocol.md`): add to the RPC table
  `| turn.credentials{}` → `TurnCredentials` | logged in; TURN off → UNAVAILABLE (9); old nodes → INVALID |`
  and `| push.status{user_id}` → `PushStatus{has_push}` | logged in; true if this node holds a PUSH_TOKEN for (user, 1) |`;
  add `STATUS_UNAVAILABLE = 9` to the status list; under Content add a `call` paragraph: fields as above, urgent,
  `expires_ms = created + 120 000`, only DELIVERED receipts for the offer (message id = `call_id`), 0.7.0 apps
  ignore it (but may create an empty direct chat).

- [ ] **Step 9: Commit** (one commit per repo).

```bash
git -C otter-server add proto internal/proto && git -C otter-server commit -m "proto: CallMessage content, TURN credentials and push status RPC messages, STATUS_UNAVAILABLE"
git -C otter-android add core/proto && git -C otter-android commit -m "proto: sync M8 call signaling and RPC messages"
git -C docs add 02-protocol.md && git -C docs commit -m "docs: M8 call content and RPCs in 02-protocol"
```
(each with the trailer from the ground rules)

---

### Task 2: Node — short-lived envelopes are not delivered after expiry and are purged

**Goal:** An envelope whose record `expires_ms` has passed is never handed to a phone and is deleted by the janitor.

**Files:**
- Modify: `otter-server/internal/store/query.go` (`Mailbox`), `otter-server/internal/store/janitor.go` (`Expire`)
- Test: `otter-server/internal/store/expiry_test.go` (new)

**Acceptance Criteria:**
- [ ] `Mailbox(ctx, user, device, limit)` skips envelopes with `0 < expires_ms <= now`.
- [ ] `Expire(ctx, now)` deletes mailbox rows and ENVELOPE records with `0 < expires_ms < now` (counted in
  `ExpireStats.Envelopes`), leaving never-expiring envelopes alone.
- [ ] Existing store tests still pass.

**Verify:** `cd otter-server && go test ./internal/store/ -run 'Expir|Mailbox' -count=1 -race` → `ok`

**Steps:**

- [ ] **Step 1: Read** `internal/store/query.go:110-125` and `janitor.go:19-60`, and an existing store test that
  applies an ENVELOPE (search `grep -rn "RecordType_ENVELOPE" internal/store/*_test.go`) to reuse its helper for
  building a signed envelope with a given `ExpiresMs`. The test below calls that helper `putEnvelope`; use the real
  helper name.

- [ ] **Step 2: Failing test** `internal/store/expiry_test.go`

```go
package store

import (
	"context"
	"testing"
)

func TestMailboxSkipsAndJanitorPurgesExpiredEnvelopes(t *testing.T) {
	ctx := context.Background()
	s := openTest(t) // existing helper in this package's tests
	now := int64(1_800_000_000_000)
	alice, bob := []byte("alice-0000000000"), []byte("bob-000000000000")
	short := putEnvelope(t, s, alice, bob, now-60_000, now+60_000) // created 1 min ago, expires in 1 min
	gone := putEnvelope(t, s, alice, bob, now-180_000, now-60_000) // expired 1 min ago (arrived before expiry)
	keep := putEnvelope(t, s, alice, bob, now-180_000, 0)          // never expires

	got, err := s.mailboxAt(ctx, bob, 1, 10, now)
	if err != nil {
		t.Fatal(err)
	}
	if !hasKey(got, short) || !hasKey(got, keep) || hasKey(got, gone) {
		t.Fatalf("mailbox = %v; want short+keep, not expired", got)
	}
	st, err := s.Expire(ctx, now)
	if err != nil {
		t.Fatal(err)
	}
	if st.Envelopes < 1 {
		t.Fatalf("expired envelope not purged: %+v", st)
	}
	got, _ = s.mailboxAt(ctx, bob, 1, 10, now)
	if hasKey(got, gone) || !hasKey(got, keep) {
		t.Fatalf("after janitor: %v", got)
	}
}

func hasKey(es []MailboxEntry, k []byte) bool {
	for _, e := range es {
		if string(e.RecordKey) == string(k) {
			return true
		}
	}
	return false
}
```

  `putEnvelope` must insert the record the same way replication does (so it lands in `mailbox`), bypassing the
  "already expired" validator check for `gone` (apply directly through the store, not through `Validate`). If no
  such helper exists, write it next to the test using the store's apply function for ENVELOPE records.

- [ ] **Step 3: Run — fails** (`s.mailboxAt undefined`).

- [ ] **Step 4: Implement.** In `query.go`, make `Mailbox` call a new `mailboxAt(ctx, user, device, limit,
  time.Now().UnixMilli())` whose query adds the expiry filter:

```go
// Mailbox returns pending envelopes for a device, oldest first. Expired envelopes (record expires_ms passed) are skipped.
func (s *Store) Mailbox(ctx context.Context, user []byte, device uint32, limit int) ([]MailboxEntry, error) {
	return s.mailboxAt(ctx, user, device, limit, time.Now().UnixMilli())
}

func (s *Store) mailboxAt(ctx context.Context, user []byte, device uint32, limit int, now int64) ([]MailboxEntry, error) {
	rows, err := s.r.QueryContext(ctx,
		`SELECT m.record_key, r.raw FROM mailbox m JOIN records r ON r.record_key=m.record_key
		 WHERE m.user_id=? AND m.device_id=? AND (r.expires_ms = 0 OR r.expires_ms > ?)
		 ORDER BY m.received_ms, m.record_key LIMIT ?`, user, device, now, limit)
	// ... the rest of the existing body unchanged
```

  In `janitor.go` `Expire`, before the 30-day envelope deletes, add:

```go
		// short-lived envelopes (call signaling, D78): gone as soon as their record expiry passes
		if err := exec(&ignore, `DELETE FROM mailbox WHERE record_key IN
			(SELECT record_key FROM records WHERE type=? AND expires_ms > 0 AND expires_ms < ?)`,
			int32(pb.RecordType_ENVELOPE), now); err != nil {
			return err
		}
		if err := exec(&st.Envelopes, `DELETE FROM records WHERE type=? AND expires_ms > 0 AND expires_ms < ?`,
			int32(pb.RecordType_ENVELOPE), now); err != nil {
			return err
		}
```

  The oplog row stays, exactly as for the 30-day deletion (replication already tolerates a missing record body —
  check `Since` handles it the same way; if it does not, also delete the oplog row as the 30-day path does).
  The janitor runs every 10 min; the `Mailbox` filter makes delivery exact.

- [ ] **Step 5: Run** `go test ./internal/store/ -count=1 -race` → `ok`; `go test ./... -count=1` → all `ok`.

- [ ] **Step 6: Commit** — `git commit -m "store: skip and purge envelopes past their record expiry (call signaling)"`.

---

### Task 3: Node — `[turn]` config, secret keygen and `otter-node check`

**Goal:** `node.toml` accepts an optional `[turn]` section; `otter-node turn keygen` writes the per-node secret;
`otter-node check` validates both.

**Files:**
- Modify: `otter-server/internal/config/config.go`, `otter-server/internal/nodecheck/check.go`,
  `otter-server/cmd/otter-node/main.go` (usage + `turn keygen` dispatch)
- Create: `otter-server/internal/turnsrv/keygen.go`
- Test: `otter-server/internal/config/turn_test.go`, `otter-server/internal/turnsrv/keygen_test.go`,
  `otter-server/internal/nodecheck/check_test.go` (extend)

**Acceptance Criteria:**
- [ ] Without `[turn]` everything behaves as before (`TurnEnabled() == false`).
- [ ] `[turn] enabled = true` fills defaults (`udp_listen ":3478"`, `tcp_listen ":3478"`, `tls_listen ":5349"`,
  `relay_port_min 49160`, `relay_port_max 49200`, `secret_file "/etc/otter/turn.secret"`,
  `max_allocations_per_user 4`, `max_allocations` = port-range size, `relay_kbps 200`, `realm "otter"`); requires
  `relay_ip` (valid IP); rejects `relay_port_min > relay_port_max`, ports outside 1024–65535, a `max_allocations`
  larger than the port range; `tls_listen` must be empty when `[wss]` has no TLS cert.
- [ ] Unknown key inside `[turn]` → load error (existing `md.Undecoded` rule).
- [ ] `turn keygen` writes 32 random bytes with mode 0640 once; a second run without `--force` refuses; prints
  `turn secret written <path>`. The secret is never printed.
- [ ] `otter-node check` prints `ok turn secret <path> (32 bytes)` or fails when TURN is enabled and the file is
  missing/short.

**Verify:** `cd otter-server && go test ./internal/config/ ./internal/turnsrv/ ./internal/nodecheck/ ./cmd/otter-node/ -count=1` → `ok`

**Steps:**

- [ ] **Step 1: Failing config test** `internal/config/turn_test.go` (mirror the existing `[reality]` tests'
  helper for writing a temp node.toml — search `reality` in `internal/config/*_test.go` and reuse its helper; it is
  called `loadTOML` below):

```go
package config

import "testing"

const base = `label = "n1"
network_pub = "AAAA"
[wss]
listen = ":27443"
path = "/x"
tls_cert = "/etc/otter/tls.crt"
tls_key = "/etc/otter/tls.key"
`

func TestTurnDefaultsAndValidation(t *testing.T) {
	c, err := loadTOML(t, base+"[turn]\nenabled = true\nrelay_ip = \"203.0.113.7\"\n")
	if err != nil {
		t.Fatal(err)
	}
	tc := c.Turn
	if !c.TurnEnabled() || tc.UDPListen != ":3478" || tc.TCPListen != ":3478" || tc.TLSListen != ":5349" ||
		tc.RelayPortMin != 49160 || tc.RelayPortMax != 49200 || tc.SecretFile != "/etc/otter/turn.secret" ||
		tc.MaxAllocationsPerUser != 4 || tc.MaxAllocations != 41 || tc.RelayKbps != 200 || tc.Realm != "otter" {
		t.Fatalf("defaults: %+v", tc)
	}
	for name, extra := range map[string]string{
		"no relay_ip":   "[turn]\nenabled = true\n",
		"bad relay_ip":  "[turn]\nenabled = true\nrelay_ip = \"nope\"\n",
		"min > max":     "[turn]\nenabled = true\nrelay_ip = \"203.0.113.7\"\nrelay_port_min = 50000\nrelay_port_max = 49000\n",
		"low port":      "[turn]\nenabled = true\nrelay_ip = \"203.0.113.7\"\nrelay_port_min = 80\n",
		"too many":      "[turn]\nenabled = true\nrelay_ip = \"203.0.113.7\"\nmax_allocations = 500\n",
		"unknown key":   "[turn]\nenabled = true\nrelay_ip = \"203.0.113.7\"\nbogus = 1\n",
	} {
		if _, err := loadTOML(t, base+extra); err == nil {
			t.Errorf("%s: want error", name)
		}
	}
	if c, err := loadTOML(t, base); err != nil || c.TurnEnabled() {
		t.Fatalf("no [turn] must stay off: %v %v", c, err)
	}
}
```

  Use real values for `label`/`network_pub` that the existing config tests use if `validate()` checks them.

- [ ] **Step 2: Run — fails** (`c.Turn undefined`).

- [ ] **Step 3: Implement** in `config.go`:

```go
// Turn is the embedded TURN relay for calls (D77). Missing section or enabled = false: no relay.
type Turn struct {
	Enabled               bool   `toml:"enabled"`
	UDPListen             string `toml:"udp_listen"`
	TCPListen             string `toml:"tcp_listen"`
	TLSListen             string `toml:"tls_listen"` // "" = no TURN over TLS
	RelayIP               string `toml:"relay_ip"`   // public IP written into relay addresses (OTTER_IP)
	RelayPortMin          int    `toml:"relay_port_min"`
	RelayPortMax          int    `toml:"relay_port_max"`
	SecretFile            string `toml:"secret_file"`
	Realm                 string `toml:"realm"`
	MaxAllocationsPerUser int    `toml:"max_allocations_per_user"`
	MaxAllocations        int    `toml:"max_allocations"`
	RelayKbps             int    `toml:"relay_kbps"`          // per allocation, each direction
	AllowPrivatePeers     bool   `toml:"allow_private_peers"` // tests and dev mesh only
}
```

  Add `Turn Turn \`toml:"turn"\`` to `Config`; `func (c *Config) TurnEnabled() bool { return c.Turn.Enabled }`;
  in `validate()` (only when enabled) set defaults and check:

```go
	if t := &c.Turn; t.Enabled {
		def := func(s *string, v string) { if *s == "" { *s = v } }
		defInt := func(p *int, v int) { if *p == 0 { *p = v } }
		def(&t.UDPListen, ":3478"); def(&t.TCPListen, ":3478"); def(&t.SecretFile, "/etc/otter/turn.secret"); def(&t.Realm, "otter")
		if t.TLSListen == "" && c.WSS.TLSCert != "" { t.TLSListen = ":5349" }
		defInt(&t.RelayPortMin, 49160); defInt(&t.RelayPortMax, 49200)
		defInt(&t.MaxAllocationsPerUser, 4); defInt(&t.RelayKbps, 200)
		if net.ParseIP(t.RelayIP) == nil { return fmt.Errorf("turn.relay_ip: %q is not an IP address", t.RelayIP) }
		if t.RelayPortMin < 1024 || t.RelayPortMax > 65535 || t.RelayPortMin > t.RelayPortMax {
			return fmt.Errorf("turn: relay ports %d-%d invalid", t.RelayPortMin, t.RelayPortMax)
		}
		span := t.RelayPortMax - t.RelayPortMin + 1
		defInt(&t.MaxAllocations, span)
		if t.MaxAllocations > span { return fmt.Errorf("turn.max_allocations %d > relay port range %d", t.MaxAllocations, span) }
		if t.TLSListen != "" && c.WSS.TLSCert == "" { return errors.New("turn.tls_listen needs [wss] tls_cert/tls_key") }
	}
```

  Note: an explicitly configured `tls_listen = ""` with TLS present gets the default; that is acceptable (document
  "set `tls_listen = "off"`" is **not** supported — keep it simple; TLS on whenever the node has a cert).

- [ ] **Step 4: Keygen.** `internal/turnsrv/keygen.go`:

```go
package turnsrv

import (
	"crypto/rand"
	"errors"
	"fmt"
	"os"
)

const SecretLen = 32

// WriteSecret creates the per-node TURN secret (0640). It never overwrites unless force is set.
func WriteSecret(path string, force bool) error {
	if _, err := os.Stat(path); err == nil && !force {
		return fmt.Errorf("%s exists (use --force to replace; active credentials stop working)", path)
	}
	b := make([]byte, SecretLen)
	if _, err := rand.Read(b); err != nil {
		return err
	}
	tmp := path + ".new"
	if err := os.WriteFile(tmp, b, 0o640); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// ReadSecret loads the secret and checks its length.
func ReadSecret(path string) ([]byte, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(b) != SecretLen {
		return nil, errors.New("turn secret must be 32 bytes")
	}
	return b, nil
}
```

  Test `keygen_test.go`: write to `t.TempDir()`, mode `0640`, length 32, second call errors, `force` replaces with
  different bytes, `ReadSecret` rejects a 31-byte file.

- [ ] **Step 5: CLI.** In `main.go` usage add
  `turn keygen --config FILE [--force]  write the TURN secret file (once; never printed)`; dispatch like
  `reality keygen` (strip the sub-word, no database): load config, require `cfg.TurnEnabled()` or at least a
  `secret_file` (use `cfg.Turn.SecretFile` with the default `/etc/otter/turn.secret` when empty), call
  `turnsrv.WriteSecret`, print `turn secret written <path>`. Add a `--force` bool to the shared FlagSet. Extend the
  `cmd/otter-node` test that covers `reality keygen` with a `turn keygen` case (temp config with `[turn]`).

- [ ] **Step 6: Check.** In `nodecheck.Run`, `if cfg.TurnEnabled()` call `checkTurn(cfg)` returning
  `fmt.Sprintf("ok turn secret %s (%d bytes), relay %s:%d-%d", path, len, relay_ip, min, max)` or the
  `ReadSecret` error. Add a case to `check_test.go` (enabled + missing file → error; present → `ok turn`).

- [ ] **Step 7: Run** the Verify command → `ok`; `go vet ./...` clean.

- [ ] **Step 8: Commit** — `git commit -m "node: optional [turn] config, turn keygen, check"`.

---

### Task 4: Node — embedded TURN package (`internal/turnsrv`)

**Goal:** A self-contained TURN server: TURN-REST auth with the node secret, per-user and per-node allocation
quota, per-allocation rate cap, UDP relays only, no relaying to private/loopback peers or to the node's own
non-relay ports, stats, netlog lines for auth/quota failures.

**Files:**
- Modify: `otter-server/go.mod`, `go.sum` (`go get github.com/pion/turn/v5@v5.1.3`)
- Modify: `otter-server/internal/netlog/netlog.go` (classes `auth`, `quota`, `listen`)
- Create: `otter-server/internal/turnsrv/creds.go`, `peers.go`, `relay.go`, `server.go`, `stats.go`
- Test: `otter-server/internal/turnsrv/creds_test.go`, `peers_test.go`, `relay_test.go`, `server_test.go`

**Acceptance Criteria:**
- [ ] `Credentials(secret, userID, now, ttl)` → username `"<unix(now+ttl)>:<hex(sha256(userID))[0:16]>"`, password
  `base64(HMAC-SHA1(secret, username))`; pion's `LongTermTURNRESTAuthHandler(string(secret))` accepts it and
  returns the key `GenerateAuthKey(username, realm, password)`; an expired username or another node's secret is
  rejected.
- [ ] `peerAllowed` refuses loopback, RFC 1918, link-local, CGNAT 100.64/10, unspecified, multicast and IPv6 ULA
  unless `AllowPrivatePeers`; public addresses (incl. the node's own relay IP) are allowed.
- [ ] Relay packet conns drop writes to the node's own IP outside the relay port range, drop traffic above
  `RelayKbps` (token bucket, 1 s burst) and count relayed bytes / dropped packets; TCP relays (RFC 6062) are refused.
- [ ] `Start(cfg)` listens on UDP, TCP and (if `TLS != nil`) TLS; two UDP clients relay a packet through two
  allocations; the 2nd allocation of a user with `MaxPerUser = 1` fails; a wrong-secret client fails to allocate;
  each failure adds one netlog line (`peer "turn"`, `direction "in"`, class `auth`/`quota`).
- [ ] `Close()` releases all ports (a second `Start` on the same ports succeeds).

**Verify:** `cd otter-server && go test ./internal/turnsrv/ -count=1 -race` → `ok`

**Steps:**

- [ ] **Step 1: Dependency and API check.**

```bash
export PATH=/usr/lib/go-1.26/bin:$HOME/go/bin:$PATH
cd ~/Documents/Projects/OttterMSG/otter-server && go get github.com/pion/turn/v5@v5.1.3 && go mod tidy
for n in ServerConfig AuthHandler RequestAttributes LongTermTURNRESTAuthHandler GenerateAuthKey QuotaHandler \
  PermissionHandler EventHandler RelayAddressGeneratorPortRange AllocateListenerConfig AllocateConnConfig \
  ClientConfig NewSTUNConn; do go doc github.com/pion/turn/v5 $n | head -20; done
```

  If a name or signature differs from the code below (the table in "Verified facts" was taken from v5.1.3 source),
  adapt the code to the real API — keep behaviour identical — and note the difference in the commit message.

- [ ] **Step 2: netlog classes.** In `internal/netlog/netlog.go` after `Handshake` add:

```go
	// TURN relay (D77): login refused, quota reached, listener could not start.
	Auth   Class = "auth"
	Quota  Class = "quota"
	Listen Class = "listen"
```

- [ ] **Step 3: Credentials — failing test** `creds_test.go`:

```go
package turnsrv

import (
	"bytes"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/pion/logging"
	"github.com/pion/turn/v5"
)

func TestCredentialsAcceptedByPion(t *testing.T) {
	secret := bytes.Repeat([]byte{1}, SecretLen)
	user := bytes.Repeat([]byte{9}, 16)
	now := time.Unix(1_800_000_000, 0)
	u, p := Credentials(secret, user, now, 12*time.Hour)
	if !strings.HasPrefix(u, "1800043200:") || len(strings.SplitN(u, ":", 2)[1]) != 16 {
		t.Fatalf("username %q", u)
	}
	h := turn.LongTermTURNRESTAuthHandler(string(secret), logging.NewDefaultLoggerFactory().NewLogger("t"))
	src := &net.UDPAddr{IP: net.IPv4(203, 0, 113, 1), Port: 5000}
	// pion compares the expiry with the real clock: use a username that expires in the future
	u, p = Credentials(secret, user, time.Now(), time.Hour)
	_, key, ok := h(&turn.RequestAttributes{Username: u, Realm: "otter", SrcAddr: src})
	if !ok || !bytes.Equal(key, turn.GenerateAuthKey(u, "otter", p)) {
		t.Fatal("pion rejected our credentials")
	}
	other := bytes.Repeat([]byte{2}, SecretLen)
	h2 := turn.LongTermTURNRESTAuthHandler(string(other), logging.NewDefaultLoggerFactory().NewLogger("t"))
	if _, key2, ok := h2(&turn.RequestAttributes{Username: u, Realm: "otter", SrcAddr: src}); ok && bytes.Equal(key2, key) {
		t.Fatal("another node's secret must not produce the same key")
	}
	old, _ := Credentials(secret, user, time.Now().Add(-2*time.Hour), time.Hour)
	if _, _, ok := h(&turn.RequestAttributes{Username: old, Realm: "otter", SrcAddr: src}); ok {
		t.Fatal("expired username accepted")
	}
}
```

  (With a different secret pion still returns `ok` with a different key — the client's MESSAGE-INTEGRITY then fails.
  The server test in Step 9 proves the allocation is refused.)

- [ ] **Step 4: Implement `creds.go`:**

```go
package turnsrv

import (
	"crypto/hmac"
	"crypto/sha1" //nolint:gosec // TURN REST credentials are defined with HMAC-SHA1 (RFC draft-uberti-behave-turn-rest)
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"time"

	pb "ottermsg/server/internal/proto/otterv1"
)

// TTL of issued credentials (D77).
const TTL = 12 * time.Hour

// UserTag is the TURN user id: a short hash, so the TURN layer never sees the account id itself.
func UserTag(userID []byte) string {
	h := sha256.Sum256(userID)
	return hex.EncodeToString(h[:])[:16]
}

// Credentials returns TURN-REST credentials valid until now+ttl, only on the node holding secret.
func Credentials(secret, userID []byte, now time.Time, ttl time.Duration) (username, password string) {
	username = fmt.Sprintf("%d:%s", now.Add(ttl).Unix(), UserTag(userID))
	m := hmac.New(sha1.New, secret)
	m.Write([]byte(username))
	return username, base64.StdEncoding.EncodeToString(m.Sum(nil))
}

// Issuer answers turn.credentials for this node.
type Issuer struct {
	Secret  []byte
	RelayIP string // public IP of the node (same as relay_ip)
	TLS     bool   // a TLS listener runs on 5349
	UDPPort, TCPPort, TLSPort int
}

func (i Issuer) Issue(userID []byte, now time.Time) *pb.TurnCredentials {
	u, p := Credentials(i.Secret, userID, now, TTL)
	urls := []string{
		fmt.Sprintf("turn:%s:%d?transport=udp", i.RelayIP, i.UDPPort),
		fmt.Sprintf("turn:%s:%d?transport=tcp", i.RelayIP, i.TCPPort),
	}
	if i.TLS {
		urls = append(urls, fmt.Sprintf("turns:%s:%d?transport=tcp", i.RelayIP, i.TLSPort))
	}
	return &pb.TurnCredentials{Username: u, Password: p, TtlS: uint32(TTL / time.Second), Urls: urls}
}
```

  Add `TestIssuerURLs` (TLS on/off → 3/2 URLs, `ttl_s == 43200`, IPv6 relay IP is out of scope: relays are IPv4).

- [ ] **Step 5: Peers — test then code.** `peers_test.go`:

```go
func TestPeerAllowed(t *testing.T) {
	for ip, want := range map[string]bool{
		"8.8.8.8": true, "203.0.113.9": true, "127.0.0.1": false, // RFC 1918 cases: built from bytes in the real test
		"169.254.1.1": false, "100.64.0.1": false, "0.0.0.0": false, "224.0.0.1": false,
		"fd00::1": false, "::1": false, "2001:4860:4860::8888": true,
	} {
		if got := peerAllowed(net.ParseIP(ip), false); got != want {
			t.Errorf("%s: %v want %v", ip, got, want)
		}
	}
	if !peerAllowed(net.ParseIP("127.0.0.1"), true) {
		t.Error("allow_private_peers must allow loopback (tests, dev mesh)")
	}
}
```

  `peers.go`:

```go
package turnsrv

import "net"

var cgnat = &net.IPNet{IP: net.IPv4(100, 64, 0, 0), Mask: net.CIDRMask(10, 32)}

// peerAllowed: TURN relays only to public addresses, never into the node's own network (no SSRF).
func peerAllowed(ip net.IP, allowPrivate bool) bool {
	if ip == nil {
		return false
	}
	if allowPrivate {
		return true
	}
	return !(ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsUnspecified() || ip.IsMulticast() || ip.IsInterfaceLocalMulticast() || cgnat.Contains(ip))
}
```

- [ ] **Step 6: Relay conns — test then code.** `relay_test.go` uses a fake `net.PacketConn` recording writes and a
  controllable clock:

```go
type fakePC struct{ net.PacketConn; writes [][]byte; reads chan []byte }

func (f *fakePC) WriteTo(p []byte, _ net.Addr) (int, error) { f.writes = append(f.writes, append([]byte(nil), p...)); return len(p), nil }
func (f *fakePC) ReadFrom(p []byte) (int, net.Addr, error) { b := <-f.reads; return copy(p, b), &net.UDPAddr{IP: net.IPv4(8, 8, 8, 8), Port: 9}, nil }

func TestLimitedConn(t *testing.T) {
	now := time.Unix(0, 0)
	st := &Stats{}
	g := &relayGen{own: net.IPv4(203, 0, 113, 7), minPort: 49160, maxPort: 49200, bytesPerSec: 1000, stats: st, now: func() time.Time { return now }}
	f := &fakePC{reads: make(chan []byte, 4)}
	c := g.wrap(f)
	own := &net.UDPAddr{IP: net.IPv4(203, 0, 113, 7), Port: 3478}
	peer := &net.UDPAddr{IP: net.IPv4(8, 8, 8, 8), Port: 9}
	relay := &net.UDPAddr{IP: net.IPv4(203, 0, 113, 7), Port: 49170}
	c.WriteTo(make([]byte, 100), own)   // own listener port: dropped
	c.WriteTo(make([]byte, 100), relay) // own relay port: allowed (two phones on one node)
	c.WriteTo(make([]byte, 900), peer)  // 1000 B budget now used up
	c.WriteTo(make([]byte, 10), peer)   // over the cap: dropped
	if len(f.writes) != 2 || st.Dropped.Load() != 2 || st.Relayed.Load() != 1000 {
		t.Fatalf("writes=%d dropped=%d relayed=%d", len(f.writes), st.Dropped.Load(), st.Relayed.Load())
	}
	now = now.Add(time.Second) // refill
	c.WriteTo(make([]byte, 500), peer)
	if len(f.writes) != 3 {
		t.Fatal("bucket did not refill")
	}
	if _, _, err := g.AllocateListener(turn.AllocateListenerConfig{}); err == nil {
		t.Fatal("TCP relay must be refused")
	}
}
```

  `relay.go`:

```go
package turnsrv

import (
	"errors"
	"math"
	"net"
	"sync"
	"time"

	"github.com/pion/turn/v5"
)

var errNoTCPRelay = errors.New("TCP relays are not offered")

// relayGen hands out UDP relay sockets from the configured port range, each wrapped with the rate cap and the
// own-port filter. TCP relays (RFC 6062) are refused: WebRTC never asks for them.
type relayGen struct {
	base        *turn.RelayAddressGeneratorPortRange
	own         net.IP
	minPort     int
	maxPort     int
	bytesPerSec int
	stats       *Stats
	now         func() time.Time
}

func (g *relayGen) Validate() error { return g.base.Validate() }

func (g *relayGen) AllocatePacketConn(c turn.AllocateListenerConfig) (net.PacketConn, net.Addr, error) {
	pc, addr, err := g.base.AllocatePacketConn(c)
	if err != nil {
		return nil, nil, err
	}
	return g.wrap(pc), addr, nil
}

func (g *relayGen) AllocateListener(turn.AllocateListenerConfig) (net.Listener, net.Addr, error) {
	return nil, nil, errNoTCPRelay
}

func (g *relayGen) AllocateConn(turn.AllocateConnConfig) (net.Conn, error) { return nil, errNoTCPRelay }

func (g *relayGen) wrap(pc net.PacketConn) net.PacketConn {
	return &limitedConn{PacketConn: pc, g: g, in: newBucket(g.bytesPerSec, g.now), out: newBucket(g.bytesPerSec, g.now)}
}

// blocked: the node's own address on a port that is not a relay port (its listeners, SSH, ...).
func (g *relayGen) blocked(a net.Addr) bool {
	u, ok := a.(*net.UDPAddr)
	return ok && u.IP.Equal(g.own) && (u.Port < g.minPort || u.Port > g.maxPort)
}

type limitedConn struct {
	net.PacketConn
	g       *relayGen
	in, out *bucket
}

func (c *limitedConn) WriteTo(p []byte, addr net.Addr) (int, error) {
	if c.g.blocked(addr) || !c.out.take(len(p)) {
		c.g.stats.Dropped.Add(1)
		return len(p), nil // UDP: a dropped packet is not an error
	}
	c.g.stats.Relayed.Add(int64(len(p)))
	return c.PacketConn.WriteTo(p, addr)
}

func (c *limitedConn) ReadFrom(p []byte) (int, net.Addr, error) {
	for {
		n, addr, err := c.PacketConn.ReadFrom(p)
		if err != nil {
			return n, addr, err
		}
		if c.in.take(n) {
			c.g.stats.Relayed.Add(int64(n))
			return n, addr, nil
		}
		c.g.stats.Dropped.Add(1)
	}
}

// bucket is a token bucket with a one-second burst.
type bucket struct {
	mu     sync.Mutex
	rate   float64
	tokens float64
	last   time.Time
	now    func() time.Time
}

func newBucket(bytesPerSec int, now func() time.Time) *bucket {
	if now == nil {
		now = time.Now
	}
	return &bucket{rate: float64(bytesPerSec), tokens: float64(bytesPerSec), last: now(), now: now}
}

func (b *bucket) take(n int) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	t := b.now()
	b.tokens = math.Min(b.rate, b.tokens+t.Sub(b.last).Seconds()*b.rate)
	b.last = t
	if b.tokens < float64(n) {
		return false
	}
	b.tokens -= float64(n)
	return true
}
```

- [ ] **Step 7: Stats.** `stats.go`:

```go
package turnsrv

import (
	"encoding/json"
	"os"
	"sync/atomic"
	"time"
)

// Stats are live counters of this process; WriteFile publishes them for `otter-node stats` (a separate process).
type Stats struct {
	Allocations atomic.Int64
	Relayed     atomic.Int64 // bytes, both directions
	Dropped     atomic.Int64 // packets (rate cap, own ports)
}

type Snapshot struct {
	Allocations int64 `json:"allocations"`
	Relayed     int64 `json:"relayed_bytes"`
	Dropped     int64 `json:"dropped_packets"`
	AtMs        int64 `json:"at_ms"`
}

func (s *Stats) Snapshot(now time.Time) Snapshot {
	return Snapshot{s.Allocations.Load(), s.Relayed.Load(), s.Dropped.Load(), now.UnixMilli()}
}

// WriteFile replaces path atomically with the current snapshot.
func (s *Stats) WriteFile(path string, now time.Time) error {
	b, _ := json.Marshal(s.Snapshot(now))
	tmp := path + ".new"
	if err := os.WriteFile(tmp, b, 0o640); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// ReadSnapshot returns the snapshot if it is younger than maxAge.
func ReadSnapshot(path string, now time.Time, maxAge time.Duration) (Snapshot, bool) {
	var s Snapshot
	b, err := os.ReadFile(path)
	if err != nil || json.Unmarshal(b, &s) != nil || now.Sub(time.UnixMilli(s.AtMs)) > maxAge {
		return Snapshot{}, false
	}
	return s, true
}
```

- [ ] **Step 8: Server.** `server.go`:

```go
package turnsrv

import (
	"context"
	"crypto/tls"
	"errors"
	"log/slog"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/pion/logging"
	"github.com/pion/turn/v5"

	"ottermsg/server/internal/netlog"
)

type Config struct {
	UDPListen, TCPListen, TLSListen string
	TLS                             *tls.Config // nil = no TLS listener
	RelayIP                         net.IP
	PortMin, PortMax                int
	Secret                          []byte
	Realm                           string
	MaxPerUser, MaxTotal            int
	RelayKbps                       int
	AllowPrivatePeers               bool
	Netlog                          netlog.Logger
	StatsFile                       string // "" = do not publish
	Log                             *slog.Logger
}

type Server struct {
	srv     *turn.Server
	closers []func() error
	Stats   *Stats
	stop    context.CancelFunc
	done    chan struct{}
}

// quota counts live allocations per TURN user id and per node (pion has only a yes/no hook).
type quota struct {
	mu             sync.Mutex
	per            map[string]int
	total          int
	maxPer, maxAll int
}

func (q *quota) allow(u string) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.per[u] < q.maxPer && q.total < q.maxAll
}
func (q *quota) add(u string, d int) {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.per[u] += d
	q.total += d
	if q.per[u] <= 0 {
		delete(q.per, u)
	}
}

// userOf strips the "<expiry>:" prefix if a hook receives the full TURN username.
func userOf(name string) string {
	if i := strings.LastIndexByte(name, ':'); i >= 0 {
		return name[i+1:]
	}
	return name
}

func Start(cfg Config) (*Server, error) {
	if cfg.Log == nil {
		cfg.Log = slog.Default()
	}
	if cfg.Netlog == nil {
		cfg.Netlog = netlog.Nop{}
	}
	s := &Server{Stats: &Stats{}, done: make(chan struct{})}
	q := &quota{per: map[string]int{}, maxPer: cfg.MaxPerUser, maxAll: cfg.MaxTotal}
	nl := func(proto string, c netlog.Class, detail string) {
		cfg.Netlog.Add(context.Background(), netlog.Entry{Peer: "turn", Endpoint: "turn:" + strings.ToLower(proto),
			Direction: "in", Result: "fail", Class: c, Detail: detail})
	}
	gen := &relayGen{
		base:  &turn.RelayAddressGeneratorPortRange{RelayAddress: cfg.RelayIP, Address: "0.0.0.0", MinPort: uint16(cfg.PortMin), MaxPort: uint16(cfg.PortMax)},
		own:   cfg.RelayIP, minPort: cfg.PortMin, maxPort: cfg.PortMax,
		bytesPerSec: cfg.RelayKbps * 1000 / 8, stats: s.Stats,
	}
	perm := func(_ net.Addr, ip net.IP) bool { return peerAllowed(ip, cfg.AllowPrivatePeers) }
	fail := func(err error) (*Server, error) {
		for _, c := range s.closers {
			_ = c()
		}
		return nil, err
	}
	udp, err := net.ListenPacket("udp4", cfg.UDPListen)
	if err != nil {
		return fail(err)
	}
	s.closers = append(s.closers, udp.Close)
	lns := []turn.ListenerConfig{}
	tcp, err := net.Listen("tcp4", cfg.TCPListen)
	if err != nil {
		return fail(err)
	}
	s.closers = append(s.closers, tcp.Close)
	lns = append(lns, turn.ListenerConfig{Listener: tcp, RelayAddressGenerator: gen, PermissionHandler: perm})
	if cfg.TLS != nil && cfg.TLSListen != "" {
		tl, err := tls.Listen("tcp4", cfg.TLSListen, cfg.TLS)
		if err != nil {
			return fail(err)
		}
		s.closers = append(s.closers, tl.Close)
		lns = append(lns, turn.ListenerConfig{Listener: tl, RelayAddressGenerator: gen, PermissionHandler: perm})
	}
	lf := logging.NewDefaultLoggerFactory()
	lf.DefaultLogLevel = logging.LogLevelWarn
	srv, err := turn.NewServer(turn.ServerConfig{
		Realm:         cfg.Realm,
		LoggerFactory: lf,
		AuthHandler:   turn.LongTermTURNRESTAuthHandler(string(cfg.Secret), lf.NewLogger("turn-auth")),
		QuotaHandler: func(username, _ string, src net.Addr) bool {
			if q.allow(userOf(username)) {
				return true
			}
			nl(src.Network(), netlog.Quota, "allocation quota reached")
			return false
		},
		EventHandler: turn.EventHandler{
			OnAuth: func(src, _ net.Addr, proto, _, _ string, _ string, ok bool) {
				if !ok {
					nl(proto, netlog.Auth, "bad or expired credentials")
				}
			},
			OnAllocationCreated: func(_, _ net.Addr, _, user, _ string, _ net.Addr, _ int) {
				q.add(userOf(user), 1)
				s.Stats.Allocations.Add(1)
			},
			OnAllocationDeleted: func(_, _ net.Addr, _, user, _ string) {
				q.add(userOf(user), -1)
				s.Stats.Allocations.Add(-1)
			},
		},
		PacketConnConfigs: []turn.PacketConnConfig{{PacketConn: udp, RelayAddressGenerator: gen, PermissionHandler: perm}},
		ListenerConfigs:   lns,
	})
	if err != nil {
		return fail(err)
	}
	s.srv = srv
	ctx, cancel := context.WithCancel(context.Background())
	s.stop = cancel
	go func() {
		defer close(s.done)
		if cfg.StatsFile == "" {
			<-ctx.Done()
			return
		}
		t := time.NewTicker(10 * time.Second)
		defer t.Stop()
		for {
			if err := s.Stats.WriteFile(cfg.StatsFile, time.Now()); err != nil {
				cfg.Log.Warn("turn stats", "err", err)
			}
			select {
			case <-ctx.Done():
				return
			case <-t.C:
			}
		}
	}()
	cfg.Log.Info("turn on", "udp", cfg.UDPListen, "tcp", cfg.TCPListen, "tls", cfg.TLSListen,
		"relay", cfg.RelayIP.String(), "ports", [2]int{cfg.PortMin, cfg.PortMax})
	return s, nil
}

// Close stops the server and releases every port. pion's Close closes the listeners it was given.
func (s *Server) Close() error {
	s.stop()
	<-s.done
	err := s.srv.Close()
	if errors.Is(err, net.ErrClosed) {
		err = nil
	}
	return err
}
```

  `EventHandler` field names and parameter lists must match `go doc github.com/pion/turn/v5 EventHandler`; the
  `OnAuth` parameters above follow v5.1.3 (`srcAddr, dstAddr net.Addr, protocol, username, realm, method string,
  verdict bool`).

- [ ] **Step 9: Server test** `server_test.go` — UDP clients on loopback, `AllowPrivatePeers: true`:

```go
package turnsrv

import (
	"bytes"
	"context"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/pion/logging"
	"github.com/pion/turn/v5"

	"ottermsg/server/internal/netlog"
)

type memLog struct{ mu sync.Mutex; e []netlog.Entry }

func (m *memLog) Add(_ context.Context, e netlog.Entry) { m.mu.Lock(); m.e = append(m.e, e); m.mu.Unlock() }
func (m *memLog) has(c netlog.Class) bool {
	m.mu.Lock(); defer m.mu.Unlock()
	for _, e := range m.e { if e.Class == c && e.Peer == "turn" && e.Direction == "in" { return true } }
	return false
}

func freeUDPPort(t *testing.T) int {
	c, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil { t.Fatal(err) }
	defer c.Close()
	return c.LocalAddr().(*net.UDPAddr).Port
}

func startTest(t *testing.T, secret []byte, maxPer int, nl netlog.Logger) (*Server, string) {
	p := freeUDPPort(t)
	addr := net.JoinHostPort("127.0.0.1", itoa(p))
	s, err := Start(Config{UDPListen: addr, TCPListen: addr, RelayIP: net.IPv4(127, 0, 0, 1),
		PortMin: 52100, PortMax: 52140, Secret: secret, Realm: "otter", MaxPerUser: maxPer, MaxTotal: 41,
		RelayKbps: 2000, AllowPrivatePeers: true, Netlog: nl})
	if err != nil { t.Fatal(err) }
	t.Cleanup(func() { s.Close() })
	return s, addr
}

func client(t *testing.T, server, user, pass string) *turn.Client {
	conn, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil { t.Fatal(err) }
	c, err := turn.NewClient(&turn.ClientConfig{STUNServerAddr: server, TURNServerAddr: server, Conn: conn,
		Username: user, Password: pass, Realm: "otter", LoggerFactory: logging.NewDefaultLoggerFactory()})
	if err != nil { t.Fatal(err) }
	if err := c.Listen(); err != nil { t.Fatal(err) }
	t.Cleanup(c.Close)
	return c
}

func TestRelayBetweenTwoAllocations(t *testing.T) {
	secret := bytes.Repeat([]byte{3}, SecretLen)
	_, addr := startTest(t, secret, 4, netlog.Nop{})
	ua, pa := Credentials(secret, []byte("anna-00000000000"), time.Now(), time.Hour)
	ub, pb := Credentials(secret, []byte("boris-0000000000"), time.Now(), time.Hour)
	ra, err := client(t, addr, ua, pa).Allocate()
	if err != nil { t.Fatal(err) }
	rb, err := client(t, addr, ub, pb).Allocate()
	if err != nil { t.Fatal(err) }
	rb.WriteTo([]byte("hi"), ra.LocalAddr()) // creates b's permission for a
	if _, err := ra.WriteTo([]byte("hello"), rb.LocalAddr()); err != nil { t.Fatal(err) }
	buf := make([]byte, 64)
	rb.SetReadDeadline(time.Now().Add(5 * time.Second))
	n, _, err := rb.ReadFrom(buf)
	if err != nil || string(buf[:n]) != "hello" { t.Fatalf("relayed %q %v", buf[:n], err) }
}

func TestQuotaAndWrongSecret(t *testing.T) {
	secret := bytes.Repeat([]byte{4}, SecretLen)
	nl := &memLog{}
	_, addr := startTest(t, secret, 1, nl)
	u, p := Credentials(secret, []byte("anna-00000000000"), time.Now(), time.Hour)
	if _, err := client(t, addr, u, p).Allocate(); err != nil { t.Fatal(err) }
	if _, err := client(t, addr, u, p).Allocate(); err == nil { t.Fatal("second allocation of the same user must hit the quota") }
	wu, wp := Credentials(bytes.Repeat([]byte{5}, SecretLen), []byte("eve-000000000000"), time.Now(), time.Hour)
	if _, err := client(t, addr, wu, wp).Allocate(); err == nil { t.Fatal("other node's credentials accepted") }
	time.Sleep(100 * time.Millisecond)
	if !nl.has(netlog.Quota) || !nl.has(netlog.Auth) { t.Fatalf("netlog: %+v", nl.e) }
}
```

  Add `func itoa(i int) string { return strconv.Itoa(i) }` (import `strconv`) or use `fmt.Sprint`. Add
  `TestCloseReleasesPorts`: `Start`, `Close`, `Start` again on the same address → no error. If `OnAuth` reports a
  failure for the first (nonce-less) request of every client, make the netlog line only for a request that carried a
  username (check `username != ""` in the hook) and keep the assertion.

- [ ] **Step 10: Run** `go test ./internal/turnsrv/ -count=1 -race` (3×) → `ok`; `go vet ./...` clean.

- [ ] **Step 11: Commit** — `git commit -m "turnsrv: embedded Pion TURN v5 with REST credentials, quotas, rate cap, peer deny list"`.

---

### Task 5: Node — `turn.credentials` and `push.status` RPCs, wiring, stats

**Goal:** Logged-in phones get TURN credentials for this node and can ask whether a contact has push; `otter-node
run` starts TURN when `[turn]` is on; `otter-node stats` shows TURN counters.

**Files:**
- Create: `otter-server/internal/service/calls.go`
- Modify: `otter-server/internal/service/service.go` (field `Turn`), `internal/service/errors.go`
  (`ErrUnavailable`), `internal/gateway/methods.go`, `cmd/otter-node/main.go`
- Test: `otter-server/internal/gateway/calls_test.go` (new), `cmd/otter-node` stats test (extend)

**Acceptance Criteria:**
- [ ] `turn.credentials` not logged in → `STATUS_UNAUTHORIZED`; TURN off → `STATUS_UNAVAILABLE` (9); on →
  `TurnCredentials` whose URLs name `relay_ip` and whose username tag is `UserTag(user)`.
- [ ] `push.status{user_id}` → `has_push` true only after that user's `PUSH_TOKEN` (device 1) is stored;
  empty `user_id` → `STATUS_INVALID`.
- [ ] `otter-node run` with `[turn]` logs `turn on`; a TURN start failure logs an error, adds a netlog line
  (`turn`, class `listen`) and the node **keeps serving** messages with `turn.credentials` → UNAVAILABLE.
- [ ] `otter-node stats` appends ` turn_allocs=N turn_relayed_bytes=M` when `/var/lib/otter/turn.stats.json`
  (path: `<dir of db>/turn.stats.json`) is younger than 60 s; unchanged otherwise.

**Verify:** `cd otter-server && go test ./internal/gateway/ ./internal/service/ ./cmd/otter-node/ -count=1 -race` → `ok`

**Steps:**

- [ ] **Step 1: Failing gateway test** `internal/gateway/calls_test.go` (reuse `startNode`, `dial`, `registerReq`,
  `login`, `sign` from `push_test.go`/`testclient_test.go`; the `newUser` closure in `TestPushRegister` shows the
  registration dance — move it to a shared helper `newTestUser(t, n, name)` in `testclient_test.go` and use it in
  both tests):

```go
func TestTurnCredentialsAndPushStatus(t *testing.T) {
	n := startNode(t)
	anna, ca := newTestUser(t, n, "anna")
	boris, cb := newTestUser(t, n, "boris")
	_ = boris
	// not logged in
	if st, _ := ca.call("turn.credentials", &pb.Empty{}, nil); st != pb.Status_STATUS_UNAUTHORIZED {
		t.Fatalf("not logged in: %v", st)
	}
	login(t, ca, anna)
	// TURN off
	if st, _ := ca.call("turn.credentials", &pb.Empty{}, nil); st != pb.Status_STATUS_UNAVAILABLE {
		t.Fatalf("turn off: %v", st)
	}
	// TURN on
	n.svc.Turn = turnsrv.Issuer{Secret: bytes.Repeat([]byte{1}, 32), RelayIP: "203.0.113.7", TLS: true, UDPPort: 3478, TCPPort: 3478, TLSPort: 5349}
	var cr pb.TurnCredentials
	if st, msg := ca.call("turn.credentials", &pb.Empty{}, &cr); st != pb.Status_STATUS_OK {
		t.Fatalf("turn on: %v %s", st, msg)
	}
	if len(cr.Urls) != 3 || cr.Urls[0] != "turn:203.0.113.7:3478?transport=udp" || !strings.HasSuffix(cr.Username, ":"+turnsrv.UserTag(anna.id)) {
		t.Fatalf("creds %+v", &cr)
	}
	// push.status
	var ps pb.PushStatus
	if st, _ := ca.call("push.status", &pb.PushStatusRequest{UserId: boris.id}, &ps); st != pb.Status_STATUS_OK || ps.HasPush {
		t.Fatalf("no token yet: %v %v", st, ps.HasPush)
	}
	login(t, cb, boris)
	tokReq := &pb.RecordRequest{Record: sign(t, pb.RecordType_PUSH_TOKEN, boris.id, &pb.PushToken{DeviceId: 1, Kind: pb.PushToken_FCM, Token: "tok"}, boris.priv)}
	if st, msg := cb.call("push.register", tokReq, nil); st != pb.Status_STATUS_OK {
		t.Fatalf("register: %v %s", st, msg)
	}
	if st, _ := ca.call("push.status", &pb.PushStatusRequest{UserId: boris.id}, &ps); st != pb.Status_STATUS_OK || !ps.HasPush {
		t.Fatalf("token stored: %v %v", st, ps.HasPush)
	}
	if st, _ := ca.call("push.status", &pb.PushStatusRequest{}, &ps); st != pb.Status_STATUS_INVALID {
		t.Fatalf("empty user: %v", st)
	}
}
```

  (`cb` may need a fresh `dial` if the helper closes it; follow the helper.)

- [ ] **Step 2: Run — fails** (`n.svc.Turn undefined`).

- [ ] **Step 3: Service.** `errors.go`: `ErrUnavailable = errors.New("unavailable")`. `service.go` field:
  `Turn TurnIssuer // TURN credentials (D77); nil = turn.credentials unavailable`. `calls.go`:

```go
package service

import (
	"context"
	"fmt"
	"time"

	pb "ottermsg/server/internal/proto/otterv1"
)

// TurnIssuer issues TURN-REST credentials for this node's relay (turnsrv.Issuer).
type TurnIssuer interface {
	Issue(userID []byte, now time.Time) *pb.TurnCredentials
}

// M9 (user revocation) must make this refuse revoked users (spec "Server: new RPCs").
func (s *Service) TurnCredentials(user []byte) (*pb.TurnCredentials, error) {
	if s.Turn == nil {
		return nil, fmt.Errorf("%w: turn relay is off on this node", ErrUnavailable)
	}
	return s.Turn.Issue(user, s.Now()), nil
}

// PushStatus: does this node hold a push token for the user's phone (device 1)? Records replicate, so any node can answer.
func (s *Service) PushStatus(ctx context.Context, user []byte) (bool, error) {
	if len(user) == 0 {
		return false, fmt.Errorf("%w: user_id", ErrInvalid)
	}
	tok, err := s.Store.PushToken(ctx, user, 1)
	return tok != "", err
}
```

- [ ] **Step 4: Gateway.** In `status()` add `case errors.Is(err, service.ErrUnavailable): return
  pb.Status_STATUS_UNAVAILABLE` (before `default`). In `dispatch` add:

```go
	case "turn.credentials":
		return svc.TurnCredentials(s.userID())
	case "push.status":
		var r pb.PushStatusRequest
		if err := decode(req.Body, &r); err != nil {
			return nil, err
		}
		ok, err := svc.PushStatus(ctx, r.UserId)
		if err != nil {
			return nil, err
		}
		return &pb.PushStatus{HasPush: ok}, nil
```

  Neither goes into `public`.

- [ ] **Step 5: Run** the gateway test → `ok`.

- [ ] **Step 6: Wiring in `cmd/otter-node/main.go`.** After the REALITY block in `serve`:

```go
	if a.cfg.TurnEnabled() {
		if ts, iss, err := startTurn(a); err != nil {
			a.log.Error("turn off: could not start", "err", err)
			netlog.StoreLogger{S: a.st}.Add(ctx, netlog.Entry{Peer: "turn", Endpoint: "turn", Direction: "in",
				Result: "fail", Class: netlog.Listen, Detail: err.Error()})
		} else {
			defer ts.Close()
			a.svc.Turn = iss
		}
	}
```

  and:

```go
// startTurn runs the embedded relay (D77). A failure leaves the node running without calls.
func startTurn(a *app) (*turnsrv.Server, turnsrv.Issuer, error) {
	t := a.cfg.Turn
	secret, err := turnsrv.ReadSecret(t.SecretFile)
	if err != nil {
		return nil, turnsrv.Issuer{}, err
	}
	var tc *tls.Config
	if t.TLSListen != "" {
		cert, err := tls.LoadX509KeyPair(a.cfg.WSS.TLSCert, a.cfg.WSS.TLSKey)
		if err != nil {
			return nil, turnsrv.Issuer{}, err
		}
		tc = &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{cert}}
	}
	ip := net.ParseIP(t.RelayIP).To4()
	srv, err := turnsrv.Start(turnsrv.Config{UDPListen: t.UDPListen, TCPListen: t.TCPListen, TLSListen: t.TLSListen,
		TLS: tc, RelayIP: ip, PortMin: t.RelayPortMin, PortMax: t.RelayPortMax, Secret: secret, Realm: t.Realm,
		MaxPerUser: t.MaxAllocationsPerUser, MaxTotal: t.MaxAllocations, RelayKbps: t.RelayKbps,
		AllowPrivatePeers: t.AllowPrivatePeers, Netlog: netlog.StoreLogger{S: a.st},
		StatsFile: turnStatsPath(a.cfg), Log: a.log})
	if err != nil {
		return nil, turnsrv.Issuer{}, err
	}
	return srv, turnsrv.Issuer{Secret: secret, RelayIP: t.RelayIP, TLS: tc != nil,
		UDPPort: portOf(t.UDPListen), TCPPort: portOf(t.TCPListen), TLSPort: portOf(t.TLSListen)}, nil
}

func portOf(listen string) int {
	_, p, _ := net.SplitHostPort(listen)
	n, _ := strconv.Atoi(p)
	return n
}

// turnStatsPath sits next to the database (the unit may write only there).
func turnStatsPath(c *config.Config) string { return filepath.Join(filepath.Dir(c.DB), "turn.stats.json") }
```

  Use the real config field for the database path (`grep -n 'toml:"db' internal/config/config.go`). A relay IP that
  is IPv6 is rejected in `config.validate()` (add `To4() == nil` → error "turn.relay_ip must be IPv4") — add that
  case to the Task 3 config test.

- [ ] **Step 7: Stats.** In the `stats` case append, when `turnsrv.ReadSnapshot(turnStatsPath(a.cfg), time.Now(),
  time.Minute)` is ok, ` turn_allocs=%d turn_relayed_bytes=%d` before the newline. Extend the existing stats test:
  write a fresh snapshot file next to the test DB → the suffix appears; a 2-minute-old one → no suffix.

- [ ] **Step 8: Run** the Verify command and `make check` → all `ok`.

- [ ] **Step 9: Commit** — `git commit -m "node: turn.credentials and push.status RPCs, TURN wiring, stats"`.

---

### Task 6: meshsim — calls relay through two nodes over UDP, TCP and TLS

**Goal:** In the in-process mesh, two accounts on two different nodes fetch credentials over RPC and relay media
through the two embedded relays using UDP, TCP and TLS client transports; credentials are node-specific.

**Files:**
- Modify: `otter-server/internal/meshsim/harness_test.go` (`nodeOpts.turn`, start/stop TURN, TLS cert)
- Create: `otter-server/internal/meshsim/turn_test.go`

**Acceptance Criteria:**
- [ ] `TestCallRelayAcrossNodes`: anna logged in on `a`, boris on `b`; each `turn.credentials` from its own node;
  anna allocates on `a` over **UDP**, boris on `b` over **TCP** → payload relayed both ways; repeated with
  **TLS** (boris) → relayed.
- [ ] `TestTurnCredentialsAreNodeLocal`: anna's credentials from `a` are refused by `b`'s relay.
- [ ] `TestTurnOffNode`: a node without `turn` answers `STATUS_UNAVAILABLE`.
- [ ] Tests pass 3× with `-race`.

**Verify:** `cd otter-server && go test ./internal/meshsim/ -run 'Turn|CallRelay' -count=3 -race` → `ok`

**Steps:**

- [ ] **Step 1: Harness.** Add `turn bool` to `nodeOpts`; on `simNode` add `turn *turnsrv.Server; turnAddr string;
  turnTLSAddr string`. In `start(n)` when `opts.turn`: pick a free UDP port P (same port for TCP), a free TCP port
  for TLS, a relay port range unique per node (e.g. node index × 50 + 53000 … +40), generate a TLS cert with
  `pinning.GenerateCert([]string{"localhost"}, []net.IP{net.IPv4(127,0,0,1)}, time.Hour)` and
  `tls.X509KeyPair`, random 32-byte secret, `turnsrv.Start(...)` with `AllowPrivatePeers: true`,
  `RelayIP 127.0.0.1`, and set `n.svc.Turn = turnsrv.Issuer{...}` with the chosen ports. Close it in `stop(n)`.
  Assign fields under `n.mu` like the REALITY fields.

- [ ] **Step 2: Test file** `turn_test.go`:

```go
package meshsim

import (
	"crypto/tls"
	"net"
	"testing"
	"time"

	"github.com/pion/logging"
	"github.com/pion/turn/v5"

	pb "ottermsg/server/internal/proto/otterv1"
)

func creds(t *testing.T, c *client) *pb.TurnCredentials {
	var cr pb.TurnCredentials
	if st, msg := c.call("turn.credentials", &pb.Empty{}, &cr); st != pb.Status_STATUS_OK {
		t.Fatalf("turn.credentials: %v %s", st, msg)
	}
	return &cr
}

// turnClient connects over "udp", "tcp" or "tls" to addr and returns an allocated relay conn.
func turnClient(t *testing.T, transport, addr string, cr *pb.TurnCredentials) (net.PacketConn, error) {
	var conn net.PacketConn
	switch transport {
	case "udp":
		c, err := net.ListenPacket("udp4", "127.0.0.1:0")
		if err != nil { t.Fatal(err) }
		conn = c
	case "tcp":
		c, err := net.Dial("tcp4", addr)
		if err != nil { t.Fatal(err) }
		conn = turn.NewSTUNConn(c)
	case "tls":
		c, err := tls.Dial("tcp4", addr, &tls.Config{InsecureSkipVerify: true}) //nolint:gosec // same as phones (D77)
		if err != nil { t.Fatal(err) }
		conn = turn.NewSTUNConn(c)
	}
	cl, err := turn.NewClient(&turn.ClientConfig{STUNServerAddr: addr, TURNServerAddr: addr, Conn: conn,
		Username: cr.Username, Password: cr.Password, Realm: "otter", LoggerFactory: logging.NewDefaultLoggerFactory()})
	if err != nil { t.Fatal(err) }
	if err := cl.Listen(); err != nil { t.Fatal(err) }
	t.Cleanup(cl.Close)
	return cl.Allocate()
}

func exchange(t *testing.T, a, b net.PacketConn) {
	t.Helper()
	b.WriteTo([]byte("open"), a.LocalAddr())
	a.WriteTo([]byte("open"), b.LocalAddr())
	for _, pair := range [][2]net.PacketConn{{a, b}, {b, a}} {
		var got string
		eventuallyWithin(t, 5*time.Second, "relayed payload", func() bool {
			pair[0].WriteTo([]byte("voice"), pair[1].LocalAddr())
			buf := make([]byte, 64)
			pair[1].SetReadDeadline(time.Now().Add(300 * time.Millisecond))
			n, _, err := pair[1].ReadFrom(buf)
			got = string(buf[:max(n, 0)])
			return err == nil && got == "voice"
		})
	}
}

func TestCallRelayAcrossNodes(t *testing.T) {
	s := newSimWith(t, map[string]nodeOpts{"a": {turn: true}, "b": {turn: true}}, "a", "b")
	a, b := s.node("a"), s.node("b")
	anna, boris := s.register(a, "anna"), s.register(b, "boris")
	ca, cb := s.login(a, anna), s.login(b, boris)
	ra, err := turnClient(t, "udp", a.turnAddr, creds(t, ca))
	if err != nil { t.Fatal(err) }
	rb, err := turnClient(t, "tcp", b.turnAddr, creds(t, cb))
	if err != nil { t.Fatal(err) }
	exchange(t, ra, rb)
	rt, err := turnClient(t, "tls", b.turnTLSAddr, creds(t, cb))
	if err != nil { t.Fatal(err) }
	exchange(t, ra, rt)
}

func TestTurnCredentialsAreNodeLocal(t *testing.T) {
	s := newSimWith(t, map[string]nodeOpts{"a": {turn: true}, "b": {turn: true}}, "a", "b")
	a, b := s.node("a"), s.node("b")
	anna := s.register(a, "anna")
	ca := s.login(a, anna)
	if _, err := turnClient(t, "udp", b.turnAddr, creds(t, ca)); err == nil {
		t.Fatal("node b accepted credentials issued by node a")
	}
}

func TestTurnOffNode(t *testing.T) {
	s := newSim(t, "a")
	a := s.node("a")
	ca := s.login(a, s.register(a, "anna"))
	if st, _ := ca.call("turn.credentials", &pb.Empty{}, nil); st != pb.Status_STATUS_UNAVAILABLE {
		t.Fatalf("want UNAVAILABLE, got %v", st)
	}
}
```

  Adjust `s.register(...)` arguments to the real helper signature (`s.register(n, name, owners...)`).

- [ ] **Step 3: Run** the Verify command → `ok` (3×). Also `go test ./internal/meshsim/ -count=1 -race` → all
  existing scenarios still `ok`.

- [ ] **Step 4: Commit** — `git commit -m "meshsim: calls relay across two nodes over UDP, TCP and TLS"`.

---

### Task 7: Deploy — `[turn]` in new bundles, `turn-setup.sh` for upgrades, firewall, status

**Goal:** New 0.8.0 nodes come up with TURN on; existing nodes get it after the 0.8.0 upgrade through
`turn-setup.sh` (called by `upgrade-all.sh`); firewall and status cover it; the script tests pass.

**Files:**
- Create: `otter-server/deploy/templates/node.toml.turn`, `otter-server/deploy/turn-setup.sh`
- Modify: `otter-server/deploy/make-bundle.sh`, `deploy/bundle/install.sh`, `deploy/upgrade-all.sh`,
  `deploy/status.sh`, `deploy/test/scripts_test.sh`, `deploy/README.md`

**Acceptance Criteria:**
- [ ] `make-bundle.sh` appends `node.toml.turn` (with `relay_ip = "${OTTER_IP}"`) only for bundle version ≥ 0.8.0
  (`sort -V`), so an older binary never sees `[turn]`.
- [ ] `install.sh`: if `node.toml` has `[turn]` and `/etc/otter/turn.secret` is missing → `otter-node turn keygen`,
  `chown root:otter`, `chmod 0640`; if ufw is active → `ufw allow 3478/udp`, `3478/tcp`, `5349/tcp`,
  `49160:49200/udp`; otherwise prints the cloud-firewall reminder listing those ports.
- [ ] `turn-setup.sh LABEL [--if-missing] [--force]`: refuses nodes below 0.8.0; with `[turn]` already present →
  exit 0 when `--if-missing`, error otherwise unless `--force`; else builds `node.toml.new` (old section stripped,
  `[turn] enabled = true`, `relay_ip = "$OTTER_IP"`), keygen if missing, `otter-node check` on `.new`, ufw rules,
  `cp node.toml node.toml.pre-turn`, swap, restart, `health.sh` + journal `turn on` since restart; on failure
  restores `node.toml.pre-turn`, restarts, exits 1. Prints the cloud-firewall reminder.
- [ ] `upgrade-all.sh VERSION` runs `turn-setup.sh LABEL --if-missing` after each successful node upgrade when
  VERSION ≥ 0.8.0, unless `--no-turn`.
- [ ] `status.sh` header gains a `TURN` column (`on`/`off`/`-` for old nodes) and its STATS column shows the
  `turn_allocs=` suffix when present.
- [ ] `deploy/test/scripts_test.sh` (in a scratch copy) covers all of the above and passes.

**Verify:** `cd "$(mktemp -d)" && tar -C ~/Documents/Projects/OttterMSG/otter-server --exclude=.git --exclude=dist --exclude=.dev-mesh -cf - . | tar -xf - && bash deploy/test/scripts_test.sh` → `scripts_test: ok`

**Steps:**

- [ ] **Step 1: Read** `deploy/reality-setup.sh`, `deploy/make-bundle.sh`, `deploy/bundle/install.sh`,
  `deploy/upgrade-all.sh`, `deploy/status.sh`, `deploy/lib.sh` and the reality/status sections of
  `deploy/test/scripts_test.sh` (they are the patterns to copy).

- [ ] **Step 2: Write the failing script tests** (append to `scripts_test.sh`, same style as the reality-setup
  tests — ssh stubbed, remote stdin captured):

```bash
# --- M8: TURN ---------------------------------------------------------------
# bundle: [turn] only for >= 0.8.0
grep -q 'node.toml.turn' deploy/make-bundle.sh || fail "make-bundle does not know node.toml.turn"
grep -q '^relay_ip = "\${OTTER_IP}"$' deploy/templates/node.toml.turn || fail "turn template relay_ip"
grep -q 'otter-node turn keygen' deploy/bundle/install.sh || fail "install.sh does not create the TURN secret"
grep -q '49160:49200/udp' deploy/bundle/install.sh || fail "install.sh firewall: relay range"
# turn-setup: remote script content
cat > "$work/stub/ssh" <<'STUB'
#!/bin/sh
case "$*" in
  *"otter-node version"*) echo 0.8.0 ;;
  *) cat > "$STUB_DIR/turn-remote.sh"; echo "turn on" ;;
esac
STUB
chmod +x "$work/stub/ssh"
out=$(STUB_DIR="$work" PATH="$work/stub:$PATH" deploy/turn-setup.sh n1 2>&1) || fail "turn-setup: $out"
r="$work/turn-remote.sh"
grep -q 'node.toml.pre-turn' "$r" || fail "turn-setup: no rollback copy"
grep -q 'otter-node check --config /etc/otter/node.toml.new' "$r" || fail "turn-setup: no check of .new"
grep -q "relay_ip = " "$r" || fail "turn-setup: relay_ip not written"
grep -q 'turn on' "$r" || fail "turn-setup: no journal marker check"
grep -q '5349/tcp' <<< "$out$(cat "$r")" || fail "turn-setup: firewall reminder/rules"
# turn-setup refuses old nodes
sed -i 's/echo 0.8.0/echo 0.7.0/' "$work/stub/ssh"
if STUB_DIR="$work" PATH="$work/stub:$PATH" deploy/turn-setup.sh n1 >/dev/null 2>&1; then fail "turn-setup accepted 0.7.0"; fi
# upgrade-all hooks turn-setup
grep -q 'turn-setup.sh "\$label" --if-missing' deploy/upgrade-all.sh || fail "upgrade-all does not call turn-setup"
grep -q -- '--no-turn' deploy/upgrade-all.sh || fail "upgrade-all: no --no-turn"
# status shows TURN
cat > "$work/stub/ssh" <<'STUB'
#!/bin/sh
printf '0.8.0\nactive\nusers=1 turn_allocs=2 turn_relayed_bytes=10\n1M\non\non\n--netlog--\n'
STUB
out=$(PATH="$work/stub:$PATH" deploy/status.sh 2>&1) || true
grep -q '^LABEL .* PUSH TURN$' <<< "$out" || fail "status header: $out"
grep -qE '^n1 .* on +on$' <<< "$out" || fail "status TURN column: $out"
```

  Adapt the stub protocol to how `turn-setup.sh` will call ssh (mirror `reality-setup.sh`: one ssh for the version,
  one with the remote heredoc on stdin). Run in the scratch copy → the new checks fail.

- [ ] **Step 3: `deploy/templates/node.toml.turn`:**

```toml

# Embedded TURN relay for calls (M8, D77). Ports: UDP 3478, TCP 3478, TLS 5349, UDP 49160-49200.
[turn]
enabled = true
relay_ip = "${OTTER_IP}"
```

  In `make-bundle.sh`, after rendering `node.toml`, append:

```bash
if [[ "$(printf '%s\n0.8.0\n' "$version" | sort -V | head -1)" == "0.8.0" ]]; then
  OTTER_IP="$OTTER_IP" envsubst '${OTTER_IP}' < "$here/templates/node.toml.turn" >> "$stage/node.toml"
fi
```

  (use the script's real variable names for the version, the template dir and the staging dir; `OTTER_IP` comes
  from `node_env`).

- [ ] **Step 4: `install.sh`** after `otter-node check`… insert before it:

```bash
if grep -q '^\[turn\]' /etc/otter/node.toml && [[ ! -f /etc/otter/turn.secret ]]; then
  /usr/local/bin/otter-node turn keygen --config /etc/otter/node.toml
  chown root:otter /etc/otter/turn.secret && chmod 0640 /etc/otter/turn.secret
fi
```

  and in the ufw block:

```bash
  if grep -q '^\[turn\]' /etc/otter/node.toml; then
    ufw allow 3478/udp; ufw allow 3478/tcp; ufw allow 5349/tcp; ufw allow 49160:49200/udp
  fi
```

  plus, in the "no ufw" branch, `echo "cloud firewall: also open UDP 3478, TCP 3478, TCP 5349, UDP 49160-49200 for calls"`
  when `[turn]` is present.

- [ ] **Step 5: `deploy/turn-setup.sh`** (copy the structure of `reality-setup.sh`):

```bash
#!/usr/bin/env bash
# Turn on the embedded TURN relay (M8, D77) on a node already running 0.8.0+. Rolls back on failure.
# Usage: deploy/turn-setup.sh LABEL [--if-missing] [--force]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
label=${1:?usage: turn-setup.sh LABEL [--if-missing] [--force]}; shift
if_missing=0; force=0
for a in "$@"; do case "$a" in --if-missing) if_missing=1 ;; --force) force=1 ;; *) die "unknown option $a" ;; esac; done
node_env "$label"   # sets OTTER_HOST, OTTER_IP, ... (deploy/lib.sh)
target=$(host_target "$label")
ver=$(ssh "$target" /usr/local/bin/otter-node version)
[[ "$(printf '%s\n0.8.0\n' "$ver" | sort -V | head -1)" == "0.8.0" ]] || die "$label runs $ver; upgrade to 0.8.0+ first"
ssh "$target" "IF_MISSING=$if_missing FORCE=$force RELAY_IP=$OTTER_IP bash -s" <<'REMOTE'
set -euo pipefail
cfg=/etc/otter/node.toml
if grep -q '^\[turn\]' "$cfg"; then
  [[ $IF_MISSING == 1 ]] && { echo "turn already configured"; exit 0; }
  [[ $FORCE == 1 ]] || { echo "[turn] exists (use --force)" >&2; exit 1; }
fi
awk '/^\[turn\]/{s=1;next} /^\[/{s=0} !s' "$cfg" > "$cfg.new"
printf '\n[turn]\nenabled = true\nrelay_ip = "%s"\n' "$RELAY_IP" >> "$cfg.new"
chown root:otter "$cfg.new"; chmod 0640 "$cfg.new"
if [[ ! -f /etc/otter/turn.secret ]]; then
  /usr/local/bin/otter-node turn keygen --config "$cfg.new"
  chown root:otter /etc/otter/turn.secret; chmod 0640 /etc/otter/turn.secret
fi
/usr/local/bin/otter-node check --config /etc/otter/node.toml.new
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  ufw allow 3478/udp; ufw allow 3478/tcp; ufw allow 5349/tcp; ufw allow 49160:49200/udp
fi
cp -p "$cfg" "$cfg.pre-turn"; mv "$cfg.new" "$cfg"
since=$(date '+%Y-%m-%d %H:%M:%S'); systemctl restart otter-node
if /usr/local/lib/otter/health.sh && journalctl -u otter-node --since "$since" | grep -q 'turn on'; then
  echo "TURN is on"; exit 0
fi
echo "TURN did not start; rolling back" >&2
mv "$cfg.pre-turn" "$cfg"; systemctl restart otter-node; exit 1
REMOTE
echo "Cloud firewall (Hetzner/other panel): open UDP 3478, TCP 3478, TCP 5349, UDP 49160-49200 to this node."
```

  Use `lib.sh`'s real helpers for the ssh target and `die` (check names); `chmod +x`.

- [ ] **Step 6: `upgrade-all.sh`**: parse `--no-turn`; after a node's successful upgrade:

```bash
  if [[ $no_turn == 0 && "$(printf '%s\n0.8.0\n' "$version" | sort -V | head -1)" == "0.8.0" ]]; then
    "$here/turn-setup.sh" "$label" --if-missing || warn "$label: TURN not enabled (see above); calls via this node unavailable"
  fi
```

- [ ] **Step 7: `status.sh`**: remote adds one line after PUSH: `if grep -q '^\[turn\]' /etc/otter/node.toml;
  then journalctl -u otter-node -b --no-pager | grep -q 'turn on' && echo on || echo off; else echo -; fi`; header
  `... PUSH TURN`; print it as the last column.

- [ ] **Step 8: Run** the Verify command in a scratch copy → `scripts_test: ok`. Also `shellcheck deploy/*.sh` if
  installed.

- [ ] **Step 9: Docs** — `deploy/README.md`: section "Calls (TURN, M8, D77)": ports, `turn-setup.sh`, cloud firewall,
  rollback, "0.7.0 binaries refuse `[turn]`: a manual downgrade removes it first".

- [ ] **Step 10: Commit** — `git commit -m "deploy: TURN in new bundles, turn-setup.sh, firewall, status column"`.

---

### Task 8: Android — dependencies, `:feature:calls` module, release ABIs, `NodeApi` RPCs

**Goal:** The app builds with WebRTC and core-telecom, release APKs carry only ARM ABIs, and the network layer can
call `turn.credentials` and `push.status`.

**Files:**
- Modify: `otter-android/gradle/libs.versions.toml`, `settings.gradle.kts`, `app/build.gradle.kts`
- Create: `otter-android/feature/calls/build.gradle.kts`, `feature/calls/src/main/AndroidManifest.xml`,
  `feature/calls/src/main/res/values/strings.xml`, `values-en/strings.xml` (copy the `feature/settings` module
  skeleton)
- Modify: `core/network/src/main/kotlin/app/ottermsg/core/network/NodeApi.kt`
- Modify (tests): `core/data/src/test/.../FakeNode.kt`, `FakeNodeTransport.kt`
- Test: `core/network/src/test/.../NodeApiCallsTest.kt` (new)

**Acceptance Criteria:**
- [ ] Catalog entries `webrtc = "150.7871.04"` (`io.github.webrtc-sdk:android`) and `coreTelecom = "1.0.1"`
  (`androidx.core:core-telecom`); `:feature:calls` depends on WebRTC; `:app` depends on core-telecom and
  `:feature:calls`.
- [ ] `defaultConfig` abiFilters = `arm64-v8a`, `armeabi-v7a`; `debug` and `staging` add `x86_64` (emulator). `unzip
  -l` on the release APK lists no `x86`/`x86_64` libs; on the debug APK it lists `x86_64`.
- [ ] Release APK builds; size recorded in the commit message (expected 70–90 MB).
- [ ] `NodeApi.turnCredentials()` returns the parsed `TurnCredentials`; `pushStatus(userId)` returns `has_push`;
  defaults (for fakes/old code) throw `RpcException(STATUS_UNAVAILABLE)` / return `true`.
- [ ] `FakeNode` serves both RPCs (configurable `turn: TurnCredentials?`, push tokens per user).

**Verify:** `cd otter-android && ./gradlew :core:network:testDebugUnitTest :core:data:testDebugUnitTest assembleDebug assembleRelease -q && unzip -l app/build/outputs/apk/release/app-release.apk | grep -c 'lib/x86'` → tests pass, count `0`

**Steps:**

- [ ] **Step 1: Catalog** (`gradle/libs.versions.toml`):

```toml
[versions]
webrtc = "150.7871.04"
coreTelecom = "1.0.1"

[libraries]
webrtc-android = { module = "io.github.webrtc-sdk:android", version.ref = "webrtc" }
androidx-core-telecom = { module = "androidx.core:core-telecom", version.ref = "coreTelecom" }
```

- [ ] **Step 2: Module.** `settings.gradle.kts`: `include(":feature:calls")`. `feature/calls/build.gradle.kts`: copy
  `feature/settings/build.gradle.kts`, set `namespace = "app.ottermsg.feature.calls"`, add
  `implementation(libs.webrtc.android)`. `app/build.gradle.kts`: `implementation(project(":feature:calls"))`,
  `implementation(libs.androidx.core.telecom)`.

- [ ] **Step 3: ABIs** in `app/build.gradle.kts`:

```kotlin
    defaultConfig {
        // ...
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") } // phones (D80); x86_64 only for emulator builds
    }
    buildTypes {
        debug { ndk { abiFilters += "x86_64" } /* existing debug settings stay */ }
        create("staging") { initWith(getByName("release")); ndk { abiFilters += "x86_64" } /* existing */ }
    }
```

  Keep every existing line of those blocks. If AGP replaces instead of merging the build-type filter (check with
  `unzip -l` on the debug APK), list all three ABIs in `debug`/`staging`.

- [ ] **Step 4: Failing test** `core/network/src/test/kotlin/app/ottermsg/core/network/NodeApiCallsTest.kt`, using
  the existing `FakeTransport` in that test source set (see how other `RemoteNodeApi` tests stub a method → reply):

```kotlin
class NodeApiCallsTest {
    @Test fun turnCredentialsAndPushStatus() = runTest {
        val t = FakeTransport()
        t.reply("turn.credentials", TurnCredentials.newBuilder().setUsername("1:ab").setPassword("p").setTtlS(43200)
            .addUrls("turn:203.0.113.7:3478?transport=udp").build())
        t.reply("push.status", PushStatus.newBuilder().setHasPush(false).build())
        val api = remoteApi(t) // the helper the other RemoteNodeApi tests use
        assertEquals("1:ab", api.turnCredentials().username)
        assertFalse(api.pushStatus(ByteArray(16)))
        assertEquals(PushStatusRequest.newBuilder().setUserId(ByteString.copyFrom(ByteArray(16))).build().toByteString(),
            t.lastBody("push.status"))
    }
}
```

  Use the real `FakeTransport` API (read `core/network/src/test/.../FakeTransport.kt` first; add `reply`/`lastBody`
  helpers if missing).

- [ ] **Step 5: Implement** in `NodeApi`:

```kotlin
    /** TURN credentials for this node's relay (D77). Old nodes: STATUS_INVALID; TURN off: STATUS_UNAVAILABLE. */
    suspend fun turnCredentials(): TurnCredentials = throw RpcException(Status.STATUS_UNAVAILABLE, "turn.credentials")
    /** Can the user's phone be woken by push? (D61/D79) Defaults to true so callers never block on it. */
    suspend fun pushStatus(userId: ByteArray): Boolean = true
```

  In `RemoteNodeApi`:

```kotlin
    override suspend fun turnCredentials(): TurnCredentials =
        TurnCredentials.parseFrom(rpc.call("turn.credentials", Empty.getDefaultInstance()))
    override suspend fun pushStatus(userId: ByteArray): Boolean =
        PushStatus.parseFrom(rpc.call("push.status", PushStatusRequest.newBuilder().setUserId(ByteString.copyFrom(userId)).build())).hasPush
```

- [ ] **Step 6: Fakes.** `FakeNode`: `var turn: TurnCredentials? = null`; push status = whether a PUSH_TOKEN was
  registered for that user (the fake already stores push registrations — reuse). `FakeNodeTransport` `when (method)`:

```kotlin
            "turn.credentials" -> node.turn ?: throw RpcException(Status.STATUS_UNAVAILABLE, "turn off")
            "push.status" -> PushStatus.newBuilder().setHasPush(node.hasPush(PushStatusRequest.parseFrom(body).userId.toByteArray())).build()
```

  (match the transport's real request/response plumbing; require login like the other authenticated methods).

- [ ] **Step 7: Build and verify** (Verify command). Record `ls -l app/build/outputs/apk/release/app-release.apk`.

- [ ] **Step 8: Commit** — `git commit -m "app: WebRTC M150 + core-telecom deps, :feature:calls, ARM-only release ABIs, TURN/push-status RPCs"`.

---

### Task 9: Android — `CallStateMachine` (pure Kotlin) with tests

**Goal:** All call rules (answer, decline, busy, timeouts, glare, stale offer, ICE failure and restart, call lines,
missed calls) live in one pure, fully tested state machine with no Android or WebRTC types.

**Files:**
- Create: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/calls/CallModels.kt`,
  `CallStateMachine.kt`
- Test: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/calls/CallStateMachineTest.kt`

**Acceptance Criteria:**
- [ ] Every rule in the spec's "Phone: call flow" section has a test: dial → Outgoing; DELIVERED → ringing;
  45 s → TIMEOUT hangup + «Не отвечает»; incoming → ring; accept → Connecting → Active; decline → DECLINED; busy
  (in a call, or Telecom busy) → BUSY hangup + missed line; stale offer (≥ 45 s old or already hung up) → missed
  line only; glare (smaller `call_id` wins on both sides); 15 s without ICE after answer → FAILED; ICE lost → one
  restart (caller sends offer `restart`), 20 s → FAILED; remote/local hang up → call line with duration.
- [ ] No `android.*` or `org.webrtc.*` import in these files.

**Verify:** `cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*CallStateMachineTest*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Models** `CallModels.kt`:

```kotlin
package app.ottermsg.core.data.calls

/** 16-byte call id as lowercase hex; hex order == unsigned bytewise order (glare rule, D78). */
@JvmInline
value class CallId(val hex: String) : Comparable<CallId> {
    override fun compareTo(other: CallId): Int = hex.compareTo(other.hex)
    fun bytes(): ByteArray = ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    companion object {
        fun of(b: ByteArray) = CallId(b.joinToString("") { "%02x".format(it) })
        fun random(): CallId = of(ByteArray(16).also(java.security.SecureRandom()::nextBytes))
    }
}

data class Peer(val userId: List<Byte>, val name: String) {
    val id: ByteArray get() = userId.toByteArray()
    companion object { fun of(id: ByteArray, name: String) = Peer(id.toList(), name) }
}

enum class HangupReason { NORMAL, BUSY, DECLINED, TIMEOUT, FAILED }

/** Stored in messages.call_outcome (kind CALL); codes are persisted — never renumber. */
enum class CallOutcome(val code: Int) {
    OUTGOING(1), INCOMING(2), MISSED(3), DECLINED(4), NO_ANSWER(5), BUSY(6), FAILED(7);
    companion object { fun of(code: Int) = entries.firstOrNull { it.code == code } }
}

object CallTimers { // D81
    const val RING_MS = 45_000L
    const val ICE_CONNECT_MS = 15_000L
    const val ICE_RESTART_MS = 20_000L
    const val GATHER_MS = 2_000L
}

sealed interface CallState {
    data object Idle : CallState
    data class Outgoing(val id: CallId, val peer: Peer, val ringing: Boolean, val sinceMs: Long) : CallState
    data class Incoming(val id: CallId, val peer: Peer, val offerSdp: String, val sinceMs: Long) : CallState
    data class Connecting(val id: CallId, val peer: Peer, val outgoing: Boolean, val sinceMs: Long) : CallState
    data class Active(val id: CallId, val peer: Peer, val outgoing: Boolean, val startMs: Long,
                      val lostSinceMs: Long? = null, val restarted: Boolean = false) : CallState
}

sealed interface CallEvent {
    val nowMs: Long
    data class Dial(val id: CallId, val peer: Peer, override val nowMs: Long) : CallEvent
    data class OfferDelivered(val id: CallId, override val nowMs: Long) : CallEvent
    data class RemoteOffer(val id: CallId, val peer: Peer, val sdp: String, val restart: Boolean, val createdMs: Long,
                           val systemBusy: Boolean, override val nowMs: Long) : CallEvent
    data class RemoteAnswer(val id: CallId, val sdp: String, override val nowMs: Long) : CallEvent
    data class RemoteHangup(val id: CallId, val reason: HangupReason, override val nowMs: Long) : CallEvent
    data class Accept(override val nowMs: Long) : CallEvent
    data class Decline(override val nowMs: Long) : CallEvent
    data class HangUp(override val nowMs: Long) : CallEvent
    data class IceConnected(override val nowMs: Long) : CallEvent
    data class IceLost(override val nowMs: Long) : CallEvent
    data class Tick(override val nowMs: Long) : CallEvent
}

sealed interface CallEffect {
    data class SendOffer(val id: CallId, val peer: Peer, val restart: Boolean) : CallEffect
    data class SendAnswer(val id: CallId, val peer: Peer, val offerSdp: String) : CallEffect
    data class ApplyAnswer(val sdp: String) : CallEffect
    data class SendHangup(val id: CallId, val peer: Peer, val reason: HangupReason) : CallEffect
    data class Line(val peer: Peer, val outcome: CallOutcome, val durationS: Long, val atMs: Long) : CallEffect
    data class Missed(val peer: Peer, val atMs: Long) : CallEffect
    data class Ended(val outcome: CallOutcome) : CallEffect
    data object Release : CallEffect
}
```

- [ ] **Step 2: Failing tests** `CallStateMachineTest.kt` (JUnit4, plain JVM):

```kotlin
package app.ottermsg.core.data.calls

import app.ottermsg.core.data.calls.CallEffect.*
import app.ottermsg.core.data.calls.CallEvent.*
import org.junit.Assert.*
import org.junit.Test

class CallStateMachineTest {
    private val anna = Peer.of(ByteArray(16) { 1 }, "Anna")
    private val boris = Peer.of(ByteArray(16) { 2 }, "Boris")
    private val low = CallId("00".repeat(16))
    private val high = CallId("ff".repeat(16))

    private fun m() = CallStateMachine()

    @Test fun outgoingAnsweredThenHungUpWritesLineWithDuration() {
        val m = m()
        assertEquals(listOf(SendOffer(low, anna, false)), m.on(Dial(low, anna, 0)))
        m.on(OfferDelivered(low, 500))
        assertTrue((m.state as CallState.Outgoing).ringing)
        assertEquals(listOf(ApplyAnswer("ans")), m.on(RemoteAnswer(low, "ans", 3_000)))
        m.on(IceConnected(4_000))
        assertTrue(m.state is CallState.Active)
        val fx = m.on(HangUp(196_000))
        assertTrue(SendHangup(low, anna, HangupReason.NORMAL) in fx)
        assertTrue(Line(anna, CallOutcome.OUTGOING, 192, 196_000) in fx)
        assertTrue(Release in fx)
        assertEquals(CallState.Idle, m.state)
    }

    @Test fun noAnswerAfter45s() {
        val m = m(); m.on(Dial(low, anna, 0))
        assertTrue(m.on(Tick(44_000)).isEmpty())
        val fx = m.on(Tick(45_000))
        assertTrue(SendHangup(low, anna, HangupReason.TIMEOUT) in fx)
        assertTrue(Line(anna, CallOutcome.NO_ANSWER, 0, 45_000) in fx)
        assertTrue(Ended(CallOutcome.NO_ANSWER) in fx)
    }

    @Test fun incomingAcceptedConnectsAndRemoteHangupEnds() {
        val m = m()
        assertTrue(m.on(RemoteOffer(high, boris, "offer", false, 1_000, false, 1_500)).isEmpty())
        assertTrue(m.state is CallState.Incoming)
        assertEquals(listOf(SendAnswer(high, boris, "offer")), m.on(Accept(5_000)))
        m.on(IceConnected(6_000))
        val fx = m.on(RemoteHangup(high, HangupReason.NORMAL, 66_000))
        assertTrue(Line(boris, CallOutcome.INCOMING, 60, 66_000) in fx)
        assertEquals(CallState.Idle, m.state)
    }

    @Test fun declineSendsDeclined() {
        val m = m(); m.on(RemoteOffer(high, boris, "o", false, 0, false, 0))
        val fx = m.on(Decline(2_000))
        assertTrue(SendHangup(high, boris, HangupReason.DECLINED) in fx)
        assertTrue(Line(boris, CallOutcome.DECLINED, 0, 2_000) in fx)
    }

    @Test fun callerSeesDeclinedAndBusy() {
        val m = m(); m.on(Dial(low, anna, 0))
        assertTrue(Line(anna, CallOutcome.DECLINED, 0, 9_000) in m.on(RemoteHangup(low, HangupReason.DECLINED, 9_000)))
        val m2 = m(); m2.on(Dial(low, anna, 0))
        assertTrue(Ended(CallOutcome.BUSY) in m2.on(RemoteHangup(low, HangupReason.BUSY, 1_000)))
    }

    @Test fun busyWhenInCallOrSystemBusy() {
        val m = m(); m.on(Dial(low, anna, 0))
        val fx = m.on(RemoteOffer(high, boris, "o", false, 1_000, false, 1_000))
        assertTrue(SendHangup(high, boris, HangupReason.BUSY) in fx)
        assertTrue(Missed(boris, 1_000) in fx)
        assertTrue(m.state is CallState.Outgoing)
        val m2 = m()
        assertTrue(SendHangup(high, boris, HangupReason.BUSY) in m2.on(RemoteOffer(high, boris, "o", false, 0, true, 0)))
        assertEquals(CallState.Idle, m2.state)
    }

    @Test fun staleOrHungUpOfferIsMissedWithoutRinging() {
        val m = m()
        val fx = m.on(RemoteOffer(high, boris, "o", false, 0, false, 45_000))
        assertEquals(listOf(Line(boris, CallOutcome.MISSED, 0, 45_000), Missed(boris, 45_000)), fx)
        assertEquals(CallState.Idle, m.state)
        val m2 = m()
        m2.on(RemoteHangup(high, HangupReason.NORMAL, 100)) // hangup overtook the offer
        assertTrue(Missed(boris, 200) in m2.on(RemoteOffer(high, boris, "o", false, 50, false, 200)))
        assertEquals(CallState.Idle, m2.state)
    }

    @Test fun glareSmallerCallIdWins() {
        // we dialled with the larger id; their smaller id wins: our call is dropped silently and theirs answered
        val m = m(); m.on(Dial(high, anna, 0))
        val fx = m.on(RemoteOffer(low, anna, "o", false, 100, false, 100))
        assertEquals(listOf(SendAnswer(low, anna, "o")), fx)
        assertEquals(low, (m.state as CallState.Connecting).id)
        // we dialled with the smaller id: their offer is ignored (they will answer ours)
        val m2 = m(); m2.on(Dial(low, anna, 0))
        assertTrue(m2.on(RemoteOffer(high, anna, "o", false, 100, false, 100)).isEmpty())
        assertEquals(low, (m2.state as CallState.Outgoing).id)
    }

    @Test fun iceNotConnectedIn15sFails() {
        val m = m(); m.on(Dial(low, anna, 0)); m.on(RemoteAnswer(low, "a", 1_000))
        assertTrue(m.on(Tick(15_999)).isEmpty())
        val fx = m.on(Tick(16_000))
        assertTrue(SendHangup(low, anna, HangupReason.FAILED) in fx)
        assertTrue(Ended(CallOutcome.FAILED) in fx)
    }

    @Test fun oneIceRestartThenFailAfter20s() {
        val m = m(); m.on(Dial(low, anna, 0)); m.on(RemoteAnswer(low, "a", 1_000)); m.on(IceConnected(2_000))
        assertEquals(listOf(SendOffer(low, anna, true)), m.on(IceLost(10_000)))
        assertEquals(listOf(ApplyAnswer("a2")), m.on(RemoteAnswer(low, "a2", 11_000)))
        m.on(IceConnected(12_000))
        assertNull((m.state as CallState.Active).lostSinceMs)
        assertTrue(m.on(IceLost(20_000)).isEmpty()) // second loss: no second restart
        val fx = m.on(Tick(40_000))
        assertTrue(SendHangup(low, anna, HangupReason.FAILED) in fx)
        assertTrue(Line(anna, CallOutcome.OUTGOING, 38, 40_000) in fx)
    }

    @Test fun calleeAnswersRestartOffer() {
        val m = m(); m.on(RemoteOffer(high, boris, "o", false, 0, false, 0)); m.on(Accept(1_000)); m.on(IceConnected(2_000))
        assertEquals(listOf(SendAnswer(high, boris, "o2")), m.on(RemoteOffer(high, boris, "o2", true, 9_000, false, 9_000)))
        assertTrue(m.state is CallState.Active)
    }

    @Test fun duplicateOfferForCurrentCallIsIgnored() {
        val m = m(); m.on(RemoteOffer(high, boris, "o", false, 0, false, 0))
        assertTrue(m.on(RemoteOffer(high, boris, "o", false, 0, false, 500)).isEmpty())
        assertTrue(m.state is CallState.Incoming)
    }

    @Test fun incomingUnansweredRingTimesOutAsMissed() {
        val m = m(); m.on(RemoteOffer(high, boris, "o", false, 0, false, 0))
        val fx = m.on(Tick(45_000))
        assertTrue(Missed(boris, 45_000) in fx)
        assertEquals(CallState.Idle, m.state)
    }
}
```

- [ ] **Step 3: Run — fails** (`CallStateMachine` unresolved).

- [ ] **Step 4: Implement** `CallStateMachine.kt`:

```kotlin
package app.ottermsg.core.data.calls

import app.ottermsg.core.data.calls.CallEffect.*
import app.ottermsg.core.data.calls.CallEvent.*
import app.ottermsg.core.data.calls.CallTimers.ICE_CONNECT_MS
import app.ottermsg.core.data.calls.CallTimers.ICE_RESTART_MS
import app.ottermsg.core.data.calls.CallTimers.RING_MS

/** One call at a time (D78/D81). Not thread-safe: CallManager serializes events. */
class CallStateMachine {
    var state: CallState = CallState.Idle
        private set
    private val ended = LinkedHashMap<CallId, Long>() // call ids already hung up (a hangup may overtake its offer)

    fun on(ev: CallEvent): List<CallEffect> {
        ended.entries.removeIf { ev.nowMs - it.value > 10 * 60_000 }
        return when (ev) {
            is Dial -> dial(ev)
            is OfferDelivered -> { (state as? CallState.Outgoing)?.takeIf { it.id == ev.id }?.let { state = it.copy(ringing = true) }; emptyList() }
            is RemoteOffer -> remoteOffer(ev)
            is RemoteAnswer -> remoteAnswer(ev)
            is RemoteHangup -> remoteHangup(ev)
            is Accept -> (state as? CallState.Incoming)?.let {
                state = CallState.Connecting(it.id, it.peer, outgoing = false, sinceMs = ev.nowMs)
                listOf(SendAnswer(it.id, it.peer, it.offerSdp))
            } ?: emptyList()
            is Decline -> (state as? CallState.Incoming)?.let {
                end(it.id, listOf(SendHangup(it.id, it.peer, HangupReason.DECLINED), Line(it.peer, CallOutcome.DECLINED, 0, ev.nowMs)), ev.nowMs)
            } ?: emptyList()
            is HangUp -> hangUp(ev)
            is IceConnected -> {
                when (val s = state) {
                    is CallState.Connecting -> state = CallState.Active(s.id, s.peer, s.outgoing, startMs = ev.nowMs)
                    is CallState.Active -> state = s.copy(lostSinceMs = null)
                    else -> {}
                }
                emptyList()
            }
            is IceLost -> iceLost(ev)
            is Tick -> tick(ev)
        }
    }

    private fun dial(ev: Dial): List<CallEffect> {
        if (state != CallState.Idle) return emptyList()
        state = CallState.Outgoing(ev.id, ev.peer, ringing = false, sinceMs = ev.nowMs)
        return listOf(SendOffer(ev.id, ev.peer, restart = false))
    }

    private fun remoteOffer(ev: RemoteOffer): List<CallEffect> {
        val s = state
        if (ev.restart) {
            val same = (s as? CallState.Active)?.id == ev.id || (s as? CallState.Connecting)?.id == ev.id
            return if (same) listOf(SendAnswer(ev.id, ev.peer, ev.sdp)) else emptyList()
        }
        if (idOf(s) == ev.id) return emptyList() // the same offer delivered twice
        if (ev.id in ended || ev.nowMs - ev.createdMs >= RING_MS) {
            return listOf(Line(ev.peer, CallOutcome.MISSED, 0, ev.nowMs), Missed(ev.peer, ev.nowMs))
        }
        if (s is CallState.Outgoing && s.peer == ev.peer) { // glare (D78)
            if (ev.id < s.id) {
                state = CallState.Connecting(ev.id, ev.peer, outgoing = false, sinceMs = ev.nowMs)
                return listOf(SendAnswer(ev.id, ev.peer, ev.sdp))
            }
            return emptyList()
        }
        if (s != CallState.Idle || ev.systemBusy) {
            ended[ev.id] = ev.nowMs
            return listOf(SendHangup(ev.id, ev.peer, HangupReason.BUSY), Line(ev.peer, CallOutcome.MISSED, 0, ev.nowMs), Missed(ev.peer, ev.nowMs))
        }
        state = CallState.Incoming(ev.id, ev.peer, ev.sdp, sinceMs = ev.nowMs)
        return emptyList()
    }

    private fun remoteAnswer(ev: RemoteAnswer): List<CallEffect> = when (val s = state) {
        is CallState.Outgoing -> if (s.id == ev.id) {
            state = CallState.Connecting(s.id, s.peer, outgoing = true, sinceMs = ev.nowMs)
            listOf(ApplyAnswer(ev.sdp))
        } else emptyList()
        is CallState.Active -> if (s.id == ev.id && s.outgoing) listOf(ApplyAnswer(ev.sdp)) else emptyList()
        else -> emptyList()
    }

    private fun remoteHangup(ev: RemoteHangup): List<CallEffect> {
        ended[ev.id] = ev.nowMs
        return when (val s = state) {
            is CallState.Outgoing -> if (s.id != ev.id) emptyList() else {
                val o = when (ev.reason) {
                    HangupReason.BUSY -> CallOutcome.BUSY
                    HangupReason.DECLINED -> CallOutcome.DECLINED
                    HangupReason.FAILED -> CallOutcome.FAILED
                    else -> CallOutcome.NO_ANSWER
                }
                end(s.id, listOf(Line(s.peer, o, 0, ev.nowMs), Ended(o)), ev.nowMs)
            }
            is CallState.Incoming -> if (s.id != ev.id) emptyList() else
                end(s.id, listOf(Line(s.peer, CallOutcome.MISSED, 0, ev.nowMs), Missed(s.peer, ev.nowMs)), ev.nowMs)
            is CallState.Connecting -> if (s.id != ev.id) emptyList() else {
                val o = if (ev.reason == HangupReason.FAILED) CallOutcome.FAILED else dir(s.outgoing)
                end(s.id, listOf(Line(s.peer, o, 0, ev.nowMs), Ended(o)), ev.nowMs)
            }
            is CallState.Active -> if (s.id != ev.id) emptyList() else
                end(s.id, listOf(Line(s.peer, dir(s.outgoing), secs(s.startMs, ev.nowMs), ev.nowMs), Ended(dir(s.outgoing))), ev.nowMs)
            CallState.Idle -> emptyList()
        }
    }

    private fun hangUp(ev: HangUp): List<CallEffect> = when (val s = state) {
        is CallState.Outgoing -> end(s.id, listOf(SendHangup(s.id, s.peer, HangupReason.NORMAL),
            Line(s.peer, CallOutcome.OUTGOING, 0, ev.nowMs), Ended(CallOutcome.OUTGOING)), ev.nowMs)
        is CallState.Incoming -> end(s.id, listOf(SendHangup(s.id, s.peer, HangupReason.DECLINED),
            Line(s.peer, CallOutcome.DECLINED, 0, ev.nowMs)), ev.nowMs)
        is CallState.Connecting -> end(s.id, listOf(SendHangup(s.id, s.peer, HangupReason.NORMAL),
            Line(s.peer, dir(s.outgoing), 0, ev.nowMs), Ended(dir(s.outgoing))), ev.nowMs)
        is CallState.Active -> end(s.id, listOf(SendHangup(s.id, s.peer, HangupReason.NORMAL),
            Line(s.peer, dir(s.outgoing), secs(s.startMs, ev.nowMs), ev.nowMs), Ended(dir(s.outgoing))), ev.nowMs)
        CallState.Idle -> emptyList()
    }

    private fun iceLost(ev: IceLost): List<CallEffect> {
        val s = state as? CallState.Active ?: return emptyList()
        if (s.lostSinceMs != null) return emptyList()
        if (s.restarted) { state = s.copy(lostSinceMs = ev.nowMs); return emptyList() }
        state = s.copy(lostSinceMs = ev.nowMs, restarted = true)
        // only the caller restarts (no restart glare); the callee waits for the restart offer
        return if (s.outgoing) listOf(SendOffer(s.id, s.peer, restart = true)) else emptyList()
    }

    private fun tick(ev: Tick): List<CallEffect> = when (val s = state) {
        is CallState.Outgoing -> if (ev.nowMs - s.sinceMs < RING_MS) emptyList() else
            end(s.id, listOf(SendHangup(s.id, s.peer, HangupReason.TIMEOUT), Line(s.peer, CallOutcome.NO_ANSWER, 0, ev.nowMs),
                Ended(CallOutcome.NO_ANSWER)), ev.nowMs)
        is CallState.Incoming -> if (ev.nowMs - s.sinceMs < RING_MS) emptyList() else
            end(s.id, listOf(Line(s.peer, CallOutcome.MISSED, 0, ev.nowMs), Missed(s.peer, ev.nowMs)), ev.nowMs)
        is CallState.Connecting -> if (ev.nowMs - s.sinceMs < ICE_CONNECT_MS) emptyList() else
            end(s.id, listOf(SendHangup(s.id, s.peer, HangupReason.FAILED), Line(s.peer, CallOutcome.FAILED, 0, ev.nowMs),
                Ended(CallOutcome.FAILED)), ev.nowMs)
        is CallState.Active -> {
            val lost = s.lostSinceMs
            if (lost == null || ev.nowMs - lost < ICE_RESTART_MS) emptyList() else
                end(s.id, listOf(SendHangup(s.id, s.peer, HangupReason.FAILED),
                    Line(s.peer, dir(s.outgoing), secs(s.startMs, ev.nowMs), ev.nowMs), Ended(CallOutcome.FAILED)), ev.nowMs)
        }
        CallState.Idle -> emptyList()
    }

    private fun end(id: CallId, fx: List<CallEffect>, nowMs: Long): List<CallEffect> {
        ended[id] = nowMs
        state = CallState.Idle
        return fx + Release
    }

    private fun idOf(s: CallState): CallId? = when (s) {
        is CallState.Outgoing -> s.id; is CallState.Incoming -> s.id; is CallState.Connecting -> s.id; is CallState.Active -> s.id
        CallState.Idle -> null
    }

    private fun dir(outgoing: Boolean) = if (outgoing) CallOutcome.OUTGOING else CallOutcome.INCOMING
    private fun secs(from: Long, to: Long) = ((to - from) / 1000).coerceAtLeast(0)
}
```

- [ ] **Step 5: Run** → all tests pass. If a test and the code disagree, the spec decides; fix the side that is wrong.

- [ ] **Step 6: Commit** — `git commit -m "calls: pure CallStateMachine with timers, glare, busy, restart rules"`.

---

### Task 10: Android — Room v8, outbox expiry, call signaling, receiver dispatch, call lines in chats

**Goal:** Call messages go out as urgent 2-minute envelopes and come in to a `CallInbox`; call results are stored as
local `CALL` lines shown in the chat and chat list.

**Files:**
- Modify: `core/database/.../entity/MessageEntity.kt`, `entity/OutboxEntity.kt`, `model/MessageStatus.kt`
  (`MessageKind.CALL = 6`), `OtterDatabase.kt` (version 8, `AutoMigration(7, 8)`), `schemas/.../8.json` (generated)
- Modify: `core/data/.../messaging/Outbox.kt`, `messaging/MailboxReceiver.kt`, `di/DataModule.kt`,
  `backup/SnapshotCodec.kt` (skip CALL like NEWS), test `LiveClient.kt` (new constructor args)
- Create: `core/data/.../calls/CallSignaling.kt`, `CallInbox.kt`, `CallLines.kt`
- Modify: `feature/conversation/.../MessageGrouping.kt` (`MessageUi.call`), `ConversationViewModel.kt`,
  `ConversationScreen.kt` (+ `CallLineChip`), strings; `feature/chats/.../ChatListViewModel.kt` (+ strings)
- Test: `core/database/src/test/.../MigrationTest.kt` (7→8), `core/data/src/test/.../calls/CallSignalingTest.kt`,
  `core/data/src/test/.../OutboxTest.kt` (expiry case), `feature/conversation` test for the line text

**Acceptance Criteria:**
- [ ] Room 7→8 keeps data; adds `messages.call_outcome INTEGER NOT NULL DEFAULT 0`, `messages.call_duration_s
  INTEGER NOT NULL DEFAULT 0`, `outbox.expires_ms INTEGER NOT NULL DEFAULT 0`.
- [ ] `Outbox.enqueue(..., expiresMs)` stores the expiry, signs the ENVELOPE with `expires_ms`, and drops the item
  without sending once `now >= expiresMs`.
- [ ] `CallSignaling.send(peer, CallMessage)` enqueues `Content.call` urgent with `expires = now + 120 s`, item not
  kept for the 24 h resend; `delivered(peer, callId)` enqueues a DELIVERED receipt for the `call_id`, non-urgent,
  same expiry.
- [ ] `MailboxReceiver`: `Content.call` → `calls.onCallMessage(...)` outside the DB transaction, acked, **no chat
  created**; a receipt that `calls.isCallReceipt(...)` → `calls.onCallReceipt(...)`, acked, nothing stored.
- [ ] `CallLines.write(...)` inserts a `CALL` message (missed = unread incoming; others read) into the direct chat
  (created if needed) and touches it; never generates a read receipt; excluded from notifications (existing `SHOWN`
  set) and from backups.
- [ ] Chat shows «Исходящий звонок · 3:12», «Входящий звонок · 0:45», «Пропущенный звонок», «Отклонён»,
  «Не отвечает», «Занято», «Не удалось соединиться» (EN: "Outgoing call · 3:12", "Incoming call · 0:45", "Missed
  call", "Declined", "No answer", "Busy", "Couldn't connect"); chat list preview shows the same text.

**Verify:** `cd otter-android && ./gradlew :core:database:testDebugUnitTest :core:data:testDebugUnitTest :feature:conversation:testDebugUnitTest :feature:chats:testDebugUnitTest` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Entities.** `MessageEntity` add (keep field order stable; append at the end):

```kotlin
    /** kind = CALL: CallOutcome.code (D80); 0 otherwise. Local only, never sent. */
    @ColumnInfo(name = "call_outcome", defaultValue = "0") val callOutcome: Int = 0,
    @ColumnInfo(name = "call_duration_s", defaultValue = "0") val callDurationS: Long = 0,
```

  `OutboxEntity`: `@ColumnInfo(name = "expires_ms", defaultValue = "0") val expiresMs: Long = 0,` (0 = never).
  `MessageKind`: `const val CALL = 6`. `OtterDatabase`: `version = 8`, add `AutoMigration(from = 7, to = 8)`.

- [ ] **Step 2: Migration test** (append to `MigrationTest.kt`):

```kotlin
    @Test fun migrate7To8AddsCallColumnsAndOutboxExpiry() {
        helper.createDatabase("m8.db", 7).use {
            it.execSQL("INSERT INTO conversations(id, type, title, created_ms, updated_ms) VALUES (1, 0, 'Anna', 1, 1)")
            it.execSQL("INSERT INTO messages(message_id, conversation_id, sender_id, outgoing, sent_ms, received_ms, body, status, kind, read_receipt_sent) VALUES (x'01', 1, x'02', 0, 5, 6, 'hi', 2, 0, 0)")
        }
        helper.runMigrationsAndValidate("m8.db", 8, true).use { db ->
            db.query("SELECT body, call_outcome, call_duration_s FROM messages").use { c ->
                c.moveToFirst(); assertEquals("hi", c.getString(0)); assertEquals(0, c.getInt(1)); assertEquals(0L, c.getLong(2))
            }
            db.query("SELECT COUNT(*) FROM outbox WHERE expires_ms = 0").use { c -> c.moveToFirst(); assertEquals(0, c.getInt(0)) }
        }
    }
```

  Use the real column lists of `conversations`/`messages` from `schemas/.../7.json` for the inserts. Build once
  (`./gradlew :core:database:kspDebugKotlin`) so `8.json` is exported, then run → pass.

- [ ] **Step 3: Outbox expiry — failing test** in `OutboxTest.kt` (follow the existing test setup with `FakeNode`
  and a controllable clock):

```kotlin
    @Test fun expiredItemIsDroppedAndLiveItemCarriesExpiry() = runTest {
        // given a session with the peer (reuse the setup of the existing send test)
        val content = Content.newBuilder().setSentMs(0).build()
        val dead = outbox.enqueue(peer, content, messageLocalId = null, urgent = true, expiresMs = clock.now() - 1)
        val live = outbox.enqueue(peer, content, messageLocalId = null, urgent = true, expiresMs = clock.now() + 120_000)
        outbox.drainOnce(api) // the existing test's way of processing the queue
        assertNull(db.outboxDao().get(dead))
        val sent = node.sentEnvelopes.single() // whatever FakeNode records for msg.send
        assertEquals(clock.now() + 120_000, RecordBody.parseFrom(sent.body).expiresMs)
    }
```

- [ ] **Step 4: Implement Outbox.** `enqueue(recipient, content, messageLocalId, urgent, expiresMs: Long = 0)` stores
  it; in `process(api, item, me)` first:

```kotlin
        if (item.expiresMs in 1..clock.now()) { outbox.delete(item.id); return } // call signaling past its 2 min (D78)
```

  and pass `expiresMs = item.expiresMs` to `RecordCodec.body(...)`. Use the DAO's real delete method.

- [ ] **Step 5: Signaling.** `CallInbox.kt`:

```kotlin
package app.ottermsg.core.data.calls

import app.ottermsg.proto.v1.CallMessage
import app.ottermsg.proto.v1.ReceiptMessage

/** Receives call content from MailboxReceiver (implemented by CallManager). */
interface CallInbox {
    suspend fun onCallMessage(from: ByteArray, name: String, msg: CallMessage, createdMs: Long)
    fun isCallReceipt(r: ReceiptMessage): Boolean
    suspend fun onCallReceipt(from: ByteArray, r: ReceiptMessage)

    companion object {
        val NONE = object : CallInbox {
            override suspend fun onCallMessage(from: ByteArray, name: String, msg: CallMessage, createdMs: Long) {}
            override fun isCallReceipt(r: ReceiptMessage) = false
            override suspend fun onCallReceipt(from: ByteArray, r: ReceiptMessage) {}
        }
    }
}
```

  `CallSignaling.kt`:

```kotlin
package app.ottermsg.core.data.calls

import app.ottermsg.core.data.messaging.Outbox
import app.ottermsg.core.data.Clock
import app.ottermsg.proto.v1.CallMessage
import app.ottermsg.proto.v1.Content
import app.ottermsg.proto.v1.ReceiptMessage
import com.google.protobuf.ByteString
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class CallSignaling @Inject constructor(private val outbox: Outbox, private val clock: Clock) {
    /** Urgent (push wakes the callee), 2-minute record expiry, not kept for the 24 h resend. */
    suspend fun send(peer: ByteArray, msg: CallMessage) {
        val now = clock.now()
        outbox.enqueue(peer, Content.newBuilder().setCall(msg).setSentMs(now).build(), messageLocalId = null,
            urgent = true, expiresMs = now + EXPIRY_MS)
        outbox.kick()
    }

    /** DELIVERED for an offer: the caller switches «Соединение…» to «Звонит…». */
    suspend fun delivered(peer: ByteArray, callId: ByteArray) {
        val now = clock.now()
        val r = ReceiptMessage.newBuilder().setType(ReceiptMessage.Type.DELIVERED).addMessageIds(ByteString.copyFrom(callId))
        outbox.enqueue(peer, Content.newBuilder().setReceipt(r).setSentMs(now).build(), messageLocalId = null,
            urgent = false, expiresMs = now + EXPIRY_MS)
        outbox.kick()
    }

    companion object { const val EXPIRY_MS = 120_000L }
}
```

  (Use the real `Clock` import path in core:data.) `CallSignalingTest`: with the `TestGraph`/`FakeNode`, send an
  offer to a peer with a session → the outbox row has `urgent = true`, `expiresMs = now + 120_000`,
  `messageLocalId = null`; after processing, `FakeNode` received one ENVELOPE whose decrypted `Content.bodyCase ==
  CALL` and record `expiresMs = now + 120_000`.

- [ ] **Step 6: Receiver dispatch.** Add constructor parameter `private val calls: CallInbox = CallInbox.NONE` to
  `MailboxReceiver` and in the first `when (content?.bodyCase)` (outside the transaction):

```kotlin
                Content.BodyCase.CALL -> {
                    calls.onCallMessage(sender.userId, sender.displayName, content.call, body.createdMs)
                    acks += key; continue
                }
                Content.BodyCase.RECEIPT -> if (calls.isCallReceipt(content.receipt)) {
                    calls.onCallReceipt(sender.userId, content.receipt); acks += key; continue
                }
```

  Provide the binding in `DataModule` (`@Provides fun callInbox(m: CallManager): CallInbox = m` once `CallManager`
  exists in Task 11; until then `@Provides fun callInbox(): CallInbox = CallInbox.NONE`). Update `LiveClient.kt`
  and any test that constructs `MailboxReceiver` positionally. Test (in `MessagingFlowTest` style): a `CALL` content
  from a stranger reaches a recording `CallInbox`, is acked, and **no conversation** is created.

- [ ] **Step 7: Call lines.** `CallLines.kt`:

```kotlin
package app.ottermsg.core.data.calls

import androidx.room.withTransaction
import app.ottermsg.core.data.Clock
import app.ottermsg.core.database.OtterDatabase
import app.ottermsg.core.database.entity.MessageEntity
import app.ottermsg.core.database.model.MessageKind
import app.ottermsg.core.database.model.MessageStatus
import java.security.SecureRandom
import javax.inject.Inject
import javax.inject.Singleton

/** Local call lines in the 1:1 chat (D80). Never sent; never read-receipted. */
@Singleton
class CallLines @Inject constructor(private val db: OtterDatabase, private val clock: Clock) {
    /** Returns the conversation id. */
    suspend fun write(peer: Peer, outcome: CallOutcome, durationS: Long, atMs: Long): Long = db.withTransaction {
        val cid = db.conversationDao().getOrCreateDirect(peer.id, peer.name, clock.now())
        val outgoing = outcome in setOf(CallOutcome.OUTGOING, CallOutcome.NO_ANSWER, CallOutcome.BUSY) // line alignment only
        db.messageDao().insert(MessageEntity(messageId = ByteArray(16).also(SecureRandom()::nextBytes), conversationId = cid,
            senderId = peer.id, outgoing = outgoing, sentMs = atMs, receivedMs = clock.now(), body = "",
            status = if (outcome == CallOutcome.MISSED) MessageStatus.DELIVERED else MessageStatus.READ,
            kind = MessageKind.CALL, readReceiptSent = true, callOutcome = outcome.code, callDurationS = durationS))
        db.conversationDao().touch(cid, clock.now())
        cid
    }
}
```

  `outgoing` only aligns the line (DECLINED/FAILED lines align left). Check how unread counts are computed
  (`grep -rn "unread" core/database`) so a MISSED line counts as unread and others do not; adjust `status` /
  `readReceiptSent` accordingly. Test: write MISSED → chat unread +1; write OUTGOING → unread unchanged; the
  read-receipt sender ignores CALL lines (add `kind != CALL` wherever incoming messages are selected for read
  receipts — `ConversationViewModel.kt:102` `lastIncomingId` already excludes system kinds; add CALL there).

- [ ] **Step 8: Rendering.** `MessageUi` gains `val call: CallLineUi? = null` (`data class CallLineUi(val outcome:
  Int, val durationS: Long)`) and `isEvent` includes it. `ConversationViewModel` maps `kind == CALL`. In
  `ConversationScreen` render a `CallLineChip(text, onClick = onCallBack)` (phone icon + text; tap starts a call —
  wired in Task 12). Text function (shared, in `feature/conversation`, unit-tested):

```kotlin
fun callLineText(res: Resources, outcome: Int, durationS: Long): String {
    val d = "%d:%02d".format(durationS / 60, durationS % 60)
    return when (outcome) {
        1 -> res.getString(R.string.call_line_outgoing, d)
        2 -> res.getString(R.string.call_line_incoming, d)
        3 -> res.getString(R.string.call_line_missed)
        4 -> res.getString(R.string.call_line_declined)
        5 -> res.getString(R.string.call_line_no_answer)
        6 -> res.getString(R.string.call_line_busy)
        else -> res.getString(R.string.call_line_failed)
    }
}
```

  Strings RU (`values/strings.xml`): `call_line_outgoing` «Исходящий звонок · %1$s», `call_line_incoming` «Входящий
  звонок · %1$s», `call_line_missed` «Пропущенный звонок», `call_line_declined` «Отклонён», `call_line_no_answer`
  «Не отвечает», `call_line_busy` «Занято», `call_line_failed` «Не удалось соединиться»; EN as in the acceptance
  criteria. Put the strings and `callLineText` in `core/ui` if both `feature/conversation` and `feature/chats` need
  them (they do: chat list preview) — `core/ui/src/main/kotlin/app/ottermsg/core/ui/CallLineText.kt`.
  `ChatListViewModel` preview for `CALL` uses the same function. `SnapshotCodec` filters `CALL` where it filters
  `NEWS` (both lines 53 and 99).

- [ ] **Step 9: Run** the Verify command → `BUILD SUCCESSFUL`.

- [ ] **Step 10: Commit** — `git commit -m "calls: Room v8, outbox expiry, call signaling and receiver dispatch, call lines in chats"`.

---

### Task 11: Android — `MediaEngine` (WebRTC), TURN cache, `CallManager`

**Goal:** A `CallManager` runs the state machine against real signaling, TURN credentials and a WebRTC media engine,
keeps the node connection alive during a call, trickles late candidates and honours «Звонки только через сервер».

**Files:**
- Create: `core/data/.../calls/MediaEngine.kt`, `TurnCache.kt`, `CallAlerts.kt`, `CallManager.kt`
- Create: `feature/calls/src/main/kotlin/app/ottermsg/feature/calls/WebRtcEngine.kt`, `OpusSdp.kt`
- Modify: `core/data/.../settings/Settings.kt` (`callsRelayOnly`), `core/data/.../di/DataModule.kt` (bind
  `CallInbox` → `CallManager`)
- Create: `app/src/main/java/app/ottermsg/calls/CallModule.kt` (bind `MediaEngine.Factory` → WebRTC)
- Test: `core/data/src/test/.../calls/CallManagerTest.kt`, `TurnCacheTest.kt`;
  `feature/calls/src/test/.../OpusSdpTest.kt`

**Acceptance Criteria:**
- [ ] `TurnCache.get(api)` reuses credentials for the same node until 1 h before expiry; `UNAVAILABLE`, `INVALID`
  (old node) or `NOT_FOUND` → `null`; other errors propagate.
- [ ] `CallManager`: dial → engine opened with the node's TURN servers and `relayOnly` from settings → offer sent;
  remote answer applied; engine CONNECTED → `Active`; hang up → hangup sent, call line written, engine closed;
  late candidates batched (≤ 1 message per 300 ms); a `SyncEngine` lease `"call"` is held while not `Idle`.
- [ ] No TURN credentials → `notices` emits `CallNotice.NotAvailable` and the state returns to `Idle` (no line).
- [ ] An incoming offer sends a DELIVERED receipt for its `call_id` and calls `CallAlerts.incoming`.
- [ ] `WebRtcEngine`: Opus mono with DTX (`usedtx=1`, `maxaveragebitrate=32000`), hardware AEC/NS when available,
  `IceTransportsType.RELAY` when relay-only, TURN TLS with `TLS_CERT_POLICY_INSECURE_NO_CHECK` (D77), unified
  plan, max-bundle; gathering capped at 2 s; ICE restart via `restartIce()`.

**Verify:** `cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*Call*' --tests '*TurnCache*' :feature:calls:testDebugUnitTest` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Interfaces** (`core/data/.../calls/MediaEngine.kt`, `CallAlerts.kt`):

```kotlin
package app.ottermsg.core.data.calls

data class IceServerSpec(val urls: List<String>, val username: String, val password: String)
data class Candidate(val sdpMid: String, val mLineIndex: Int, val sdp: String)
enum class IcePhase { CONNECTED, LOST }
/** path: "relay-udp", "relay-tcp", "relay-tls" or "direct". */
data class PathInfo(val path: String, val rttMs: Long)

interface MediaListener {
    fun onIce(phase: IcePhase)
    fun onCandidate(c: Candidate) // only candidates found after the SDP was returned (trickle)
}

/** WebRTC behind an interface so CallManager stays testable on the JVM (D76). One instance per call. */
interface MediaEngine {
    suspend fun open(servers: List<IceServerSpec>, relayOnly: Boolean, listener: MediaListener)
    suspend fun offer(restart: Boolean): String
    suspend fun answer(remoteOffer: String): String
    suspend fun applyAnswer(sdp: String)
    fun addCandidates(c: List<Candidate>)
    fun setMuted(muted: Boolean)
    suspend fun path(): PathInfo?
    fun close()
    fun interface Factory { fun create(): MediaEngine }
}
```

```kotlin
package app.ottermsg.core.data.calls

/** Android side of calls (implemented in :app by CallNotifier). */
interface CallAlerts {
    fun incoming(call: CallState.Incoming)
    fun missed(peer: Peer, conversationId: Long)
    fun released()
    companion object {
        val NONE = object : CallAlerts {
            override fun incoming(call: CallState.Incoming) {}
            override fun missed(peer: Peer, conversationId: Long) {}
            override fun released() {}
        }
    }
}
```

- [ ] **Step 2: Settings** — add to `Settings.kt` (pattern of `notificationsEnabled`):

```kotlin
    suspend fun callsRelayOnly(): Boolean = (int(CALLS_RELAY_ONLY) ?: 1) != 0
    suspend fun setCallsRelayOnly(v: Boolean) = putInt(CALLS_RELAY_ONLY, if (v) 1 else 0)
    fun observeCallsRelayOnly(): Flow<Boolean> = observeInt(CALLS_RELAY_ONLY, 1).map { it != 0 }
    // companion: const val CALLS_RELAY_ONLY = "calls_relay_only"
```

- [ ] **Step 3: TurnCache — test then code.** `TurnCacheTest`: a fake `NodeApi` (only `nodeId()` and
  `turnCredentials()` overridden; count calls) → second `get` within validity makes no RPC; a clock 11.5 h later
  makes a new RPC; a node id change makes a new RPC; `RpcException(STATUS_UNAVAILABLE)` and `STATUS_INVALID` → `null`.

```kotlin
package app.ottermsg.core.data.calls

import app.ottermsg.core.data.Clock
import app.ottermsg.core.network.NodeApi
import app.ottermsg.core.network.RpcException
import app.ottermsg.proto.v1.Status
import app.ottermsg.proto.v1.TurnCredentials
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class TurnCache @Inject constructor(private val clock: Clock) {
    private var cached: Pair<String, TurnCredentials>? = null

    /** Credentials for the node behind [api]; null when calls are not available there. */
    suspend fun get(api: NodeApi): TurnCredentials? {
        val node = api.nodeId().joinToString("") { "%02x".format(it) }
        cached?.let { (n, c) -> if (n == node && expiryMs(c) - clock.now() > 3_600_000) return c }
        return try {
            api.turnCredentials().also { cached = node to it }
        } catch (e: RpcException) {
            if (e.status in NOT_AVAILABLE) null else throw e
        }
    }

    private fun expiryMs(c: TurnCredentials) = (c.username.substringBefore(':').toLongOrNull() ?: 0) * 1000

    companion object {
        private val NOT_AVAILABLE = setOf(Status.STATUS_UNAVAILABLE, Status.STATUS_INVALID, Status.STATUS_NOT_FOUND)
    }
}
```

- [ ] **Step 4: CallManager — failing test** `CallManagerTest.kt` with fakes:

```kotlin
class FakeEngine : MediaEngine {
    var opened: Pair<List<IceServerSpec>, Boolean>? = null; var listener: MediaListener? = null
    val calls = mutableListOf<String>(); var closed = false
    override suspend fun open(servers: List<IceServerSpec>, relayOnly: Boolean, listener: MediaListener) { opened = servers to relayOnly; this.listener = listener }
    override suspend fun offer(restart: Boolean) = "offer-sdp".also { calls += "offer:$restart" }
    override suspend fun answer(remoteOffer: String) = "answer-sdp".also { calls += "answer:$remoteOffer" }
    override suspend fun applyAnswer(sdp: String) { calls += "apply:$sdp" }
    override fun addCandidates(c: List<Candidate>) { calls += "cands:${c.size}" }
    override fun setMuted(muted: Boolean) {}
    override suspend fun path() = PathInfo("relay-udp", 40)
    override fun close() { closed = true }
}
```

  `CallTransport` is the seam for signaling: make `CallSignaling` implement
  `interface CallTransport { suspend fun send(peer: ByteArray, msg: CallMessage); suspend fun delivered(peer: ByteArray, callId: ByteArray) }`
  and inject `CallTransport` into `CallManager` (bind in `DataModule`). Test cases:
  1. `dial` → `FakeEngine.opened` has the 3 URLs from `FakeNode.turn` and `relayOnly == true` (default setting);
     transport got an `offer` with sdp `offer-sdp`; state `Outgoing`; lease `"call"` held.
  2. `onCallMessage(answer)` → `apply:answer-sdp`; `listener.onIce(CONNECTED)` → state `Active`.
  3. `hangUp()` → transport got `hangup NORMAL`; a `CALL` message exists in the direct chat; engine closed; lease
     released; state `Idle`.
  4. Remote offer → transport `delivered(callId)`; `CallAlerts.incoming` called; `accept()` → `answer:<offer>` and an
     `answer` message sent.
  5. `FakeNode.turn = null` → `dial` → `notices` emits `NotAvailable`, state `Idle`, no call line.
  Use `TestScope`/`StandardTestDispatcher` and an injected `CoroutineScope`; advance time for the ticker.

- [ ] **Step 5: Implement** `CallManager.kt`:

```kotlin
package app.ottermsg.core.data.calls

import app.ottermsg.core.data.Clock
import app.ottermsg.core.data.di.ApplicationScope
import app.ottermsg.core.data.settings.Settings
import app.ottermsg.core.data.sync.SyncEngine
import app.ottermsg.core.network.NetLog
import app.ottermsg.proto.v1.*
import com.google.protobuf.ByteString
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import javax.inject.Inject
import javax.inject.Singleton

sealed interface CallNotice { data object NotAvailable : CallNotice }

@Singleton
class CallManager @Inject constructor(
    private val transport: CallTransport,
    private val lines: CallLines,
    private val engines: MediaEngine.Factory,
    private val turn: TurnCache,
    private val sync: SyncEngine,
    private val settings: Settings,
    private val alerts: CallAlerts,
    private val netLog: NetLog,
    private val clock: Clock,
    @ApplicationScope private val scope: CoroutineScope,
) : CallInbox {
    private val machine = CallStateMachine()
    private val events = Channel<CallEvent>(Channel.UNLIMITED)
    private val _state = MutableStateFlow<CallState>(CallState.Idle)
    val state: StateFlow<CallState> = _state.asStateFlow()
    private val _ended = MutableSharedFlow<CallOutcome>(extraBufferCapacity = 4)
    val ended: SharedFlow<CallOutcome> = _ended.asSharedFlow()
    private val _notices = MutableSharedFlow<CallNotice>(extraBufferCapacity = 4)
    val notices: SharedFlow<CallNotice> = _notices.asSharedFlow()

    /** Set by the Android layer: another call (GSM or another VoIP app) is in progress. */
    @Volatile var systemBusy: () -> Boolean = { false }

    private var engine: MediaEngine? = null
    private var trickleTo: Pair<CallId, Peer>? = null
    private val pending = mutableListOf<Candidate>()
    private var flush: Job? = null
    private var ticker: Job? = null
    private var lastLineChat = -1L
    private var leased = false

    init { scope.launch { for (ev in events) process(ev) } }

    fun dial(peer: Peer) { post(CallEvent.Dial(CallId.random(), peer, clock.now())) }
    fun accept() = post(CallEvent.Accept(clock.now()))
    fun decline() = post(CallEvent.Decline(clock.now()))
    fun hangUp() = post(CallEvent.HangUp(clock.now()))
    fun setMuted(muted: Boolean) { engine?.setMuted(muted) }
    suspend fun peerHasPush(peer: ByteArray): Boolean =
        runCatching { sync.current()?.pushStatus(peer) ?: true }.getOrDefault(true)

    private fun post(ev: CallEvent) { events.trySend(ev) }

    override suspend fun onCallMessage(from: ByteArray, name: String, msg: CallMessage, createdMs: Long) {
        val id = CallId.of(msg.callId.toByteArray())
        val peer = Peer.of(from, name)
        val now = clock.now()
        when (msg.kindCase) {
            CallMessage.KindCase.OFFER -> {
                if (!msg.offer.restart) transport.delivered(from, msg.callId.toByteArray())
                post(CallEvent.RemoteOffer(id, peer, msg.offer.sdp, msg.offer.restart, createdMs, systemBusy(), now))
            }
            CallMessage.KindCase.ANSWER -> post(CallEvent.RemoteAnswer(id, msg.answer.sdp, now))
            CallMessage.KindCase.CANDIDATES -> if (trickleTo?.first == id) {
                engine?.addCandidates(msg.candidates.candidatesList.map { Candidate(it.sdpMid, it.sdpMlineIndex, it.candidate) })
            }
            CallMessage.KindCase.HANGUP -> post(CallEvent.RemoteHangup(id, reasonOf(msg.hangup.reason), now))
            else -> {}
        }
    }

    override fun isCallReceipt(r: ReceiptMessage): Boolean {
        val out = _state.value as? CallState.Outgoing ?: return false
        return r.type == ReceiptMessage.Type.DELIVERED && r.messageIdsList.any { CallId.of(it.toByteArray()) == out.id }
    }

    override suspend fun onCallReceipt(from: ByteArray, r: ReceiptMessage) {
        r.messageIdsList.forEach { post(CallEvent.OfferDelivered(CallId.of(it.toByteArray()), clock.now())) }
    }

    private suspend fun process(ev: CallEvent) {
        val before = machine.state
        val fx = machine.on(ev)
        _state.value = machine.state
        if (before == CallState.Idle && machine.state != CallState.Idle) onBusy()
        for (e in fx) runCatching { run(e) }.onFailure { if (it is CancellationException) throw it; fail() }
        if (machine.state is CallState.Incoming && before !is CallState.Incoming) alerts.incoming(machine.state as CallState.Incoming)
    }

    private suspend fun run(e: CallEffect) {
        when (e) {
            is CallEffect.SendOffer -> {
                val eng = engine ?: open(e.id, e.peer) ?: return
                val sdp = eng.offer(e.restart)
                transport.send(e.peer.id, msg(e.id).setOffer(CallOffer.newBuilder().setSdp(sdp).setRestart(e.restart)).build())
            }
            is CallEffect.SendAnswer -> {
                val eng = engine ?: open(e.id, e.peer) ?: return
                val sdp = eng.answer(e.offerSdp)
                transport.send(e.peer.id, msg(e.id).setAnswer(CallAnswer.newBuilder().setSdp(sdp)).build())
            }
            is CallEffect.ApplyAnswer -> engine?.applyAnswer(e.sdp)
            is CallEffect.SendHangup -> transport.send(e.peer.id,
                msg(e.id).setHangup(CallHangup.newBuilder().setReason(CallHangup.Reason.valueOf(e.reason.name))).build())
            is CallEffect.Line -> { lastLineChat = lines.write(e.peer, e.outcome, e.durationS, e.atMs); logCall(e) }
            is CallEffect.Missed -> alerts.missed(e.peer, lastLineChat)
            is CallEffect.Ended -> _ended.emit(e.outcome)
            CallEffect.Release -> release()
        }
    }

    /** Opens the media engine with this node's relay; null (and NotAvailable) when calls are not possible here. */
    private suspend fun open(id: CallId, peer: Peer): MediaEngine? {
        val api = sync.current()
        val creds = api?.let { turn.get(it) }
        if (creds == null) { _notices.emit(CallNotice.NotAvailable); post(CallEvent.HangUp(clock.now())); return null }
        val eng = engines.create()
        eng.open(listOf(IceServerSpec(creds.urlsList, creds.username, creds.password)), settings.callsRelayOnly(), object : MediaListener {
            override fun onIce(phase: IcePhase) = post(if (phase == IcePhase.CONNECTED) CallEvent.IceConnected(clock.now()) else CallEvent.IceLost(clock.now()))
            override fun onCandidate(c: Candidate) { synchronized(pending) { pending += c }; scheduleFlush() }
        })
        engine = eng
        trickleTo = id to peer
        return eng
    }

    private fun scheduleFlush() {
        if (flush?.isActive == true) return
        flush = scope.launch {
            delay(300)
            val (id, peer) = trickleTo ?: return@launch
            val batch = synchronized(pending) { pending.toList().also { pending.clear() } }
            if (batch.isEmpty()) return@launch
            val c = IceCandidates.newBuilder().addAllCandidates(batch.map {
                IceCandidate.newBuilder().setSdpMid(it.sdpMid).setSdpMlineIndex(it.mLineIndex).setCandidate(it.sdp).build() })
            transport.send(peer.id, msg(id).setCandidates(c).build())
        }
    }

    private fun onBusy() {
        if (!leased) { sync.acquire(LEASE); leased = true } // signaling needs the node connection during the call
        if (ticker == null) ticker = scope.launch { while (isActive) { delay(1_000); post(CallEvent.Tick(clock.now())) } }
    }

    private fun release() {
        engine?.close(); engine = null; trickleTo = null
        flush?.cancel(); synchronized(pending) { pending.clear() }
        ticker?.cancel(); ticker = null
        if (leased) { sync.release(LEASE); leased = false }
        alerts.released()
    }

    private fun fail() { post(CallEvent.HangUp(clock.now())) }

    private suspend fun logCall(e: CallEffect.Line) {} // filled in Task 13 (needs the media path)

    private fun msg(id: CallId) = CallMessage.newBuilder().setCallId(ByteString.copyFrom(id.bytes()))

    private fun reasonOf(r: CallHangup.Reason) = when (r) {
        CallHangup.Reason.BUSY -> HangupReason.BUSY
        CallHangup.Reason.DECLINED -> HangupReason.DECLINED
        CallHangup.Reason.TIMEOUT -> HangupReason.TIMEOUT
        CallHangup.Reason.FAILED -> HangupReason.FAILED
        else -> HangupReason.NORMAL
    }

    companion object { const val LEASE = "call" }
}
```

  Check `SyncEngine.acquire/release` are callable from `core:data` (they are `@Synchronized fun` on the engine) and
  that `sync.current()` is the right accessor (`SyncEngine.kt:94`). In `DataModule`: `@Provides fun callInbox(m:
  CallManager): CallInbox = m`, `@Provides fun callTransport(s: CallSignaling): CallTransport = s`, and a default
  `CallAlerts.NONE` provider is **not** added (the app binds `CallNotifier`); `LiveClient`/`TestGraph` construct
  `CallManager` with `CallAlerts.NONE` and a `MediaEngine.Factory { FakeEngine() }` where needed.

- [ ] **Step 6: Run** the CallManager and TurnCache tests → pass.

- [ ] **Step 7: Opus SDP — test then code** (`feature/calls`):

```kotlin
class OpusSdpTest {
    @Test fun addsDtxAndBitrateToOpusFmtp() {
        val sdp = "m=audio 9 UDP/TLS/RTP/SAVPF 111 63\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 minptime=10;useinbandfec=1\r\n"
        val out = tuneOpus(sdp)
        assertTrue(out.contains("a=fmtp:111 minptime=10;useinbandfec=1;usedtx=1;maxaveragebitrate=32000;stereo=0\r\n"))
        assertEquals(out, tuneOpus(out)) // idempotent
    }
}
```

```kotlin
package app.ottermsg.feature.calls

/** Opus mono, DTX, ≤ 32 kbit/s (D76): appended to the fmtp line of the opus payload type. */
fun tuneOpus(sdp: String): String {
    val pt = Regex("a=rtpmap:(\\d+) opus/48000/2").find(sdp)?.groupValues?.get(1) ?: return sdp
    return sdp.replace(Regex("a=fmtp:$pt ([^\\r\\n]*)")) { m ->
        val p = m.groupValues[1]
        if (p.contains("usedtx")) m.value else "a=fmtp:$pt $p;usedtx=1;maxaveragebitrate=32000;stereo=0"
    }
}
```

- [ ] **Step 8: WebRtcEngine** (`feature/calls/.../WebRtcEngine.kt`; not unit-tested — covered by the emulator
  acceptance in Task 14):

```kotlin
package app.ottermsg.feature.calls

import android.content.Context
import app.ottermsg.core.data.calls.*
import kotlinx.coroutines.*
import org.webrtc.*
import org.webrtc.audio.JavaAudioDeviceModule
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class WebRtcEngine(private val context: Context) : MediaEngine {
    private var factory: PeerConnectionFactory? = null
    private var adm: JavaAudioDeviceModule? = null
    private var pc: PeerConnection? = null
    private var track: AudioTrack? = null
    private var listener: MediaListener? = null
    @Volatile private var trickle = false
    @Volatile private var gatheringDone: CompletableDeferred<Unit>? = null

    override suspend fun open(servers: List<IceServerSpec>, relayOnly: Boolean, listener: MediaListener) = withContext(Dispatchers.Default) {
        init(context)
        this@WebRtcEngine.listener = listener
        adm = JavaAudioDeviceModule.builder(context)
            .setUseHardwareAcousticEchoCanceler(JavaAudioDeviceModule.isBuiltInAcousticEchoCancelerSupported())
            .setUseHardwareNoiseSuppressor(JavaAudioDeviceModule.isBuiltInNoiseSuppressorSupported())
            .createAudioDeviceModule()
        val f = PeerConnectionFactory.builder().setAudioDeviceModule(adm).createPeerConnectionFactory().also { factory = it }
        val ice = servers.map {
            PeerConnection.IceServer.builder(it.urls).setUsername(it.username).setPassword(it.password)
                .setTlsCertPolicy(PeerConnection.TlsCertPolicy.TLS_CERT_POLICY_INSECURE_NO_CHECK) // media is DTLS-SRTP end to end (D77)
                .createIceServer()
        }
        val cfg = PeerConnection.RTCConfiguration(ice).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            iceTransportsType = if (relayOnly) PeerConnection.IceTransportsType.RELAY else PeerConnection.IceTransportsType.ALL
            bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE
            rtcpMuxPolicy = PeerConnection.RtcpMuxPolicy.REQUIRE
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
        }
        pc = f.createPeerConnection(cfg, observer) ?: error("createPeerConnection failed")
        track = f.createAudioTrack("a0", f.createAudioSource(MediaConstraints()))
        pc!!.addTrack(track, listOf("s0"))
        Unit
    }

    override suspend fun offer(restart: Boolean): String {
        val p = checkNotNull(pc)
        if (restart) p.restartIce()
        val sdp = suspendSdp { p.createOffer(it, MediaConstraints()) }
        return setLocalAndGather(p, SessionDescription(sdp.type, tuneOpus(sdp.description)))
    }

    override suspend fun answer(remoteOffer: String): String {
        val p = checkNotNull(pc)
        suspendSet { p.setRemoteDescription(it, SessionDescription(SessionDescription.Type.OFFER, remoteOffer)) }
        val sdp = suspendSdp { p.createAnswer(it, MediaConstraints()) }
        return setLocalAndGather(p, SessionDescription(sdp.type, tuneOpus(sdp.description)))
    }

    override suspend fun applyAnswer(sdp: String) {
        val p = checkNotNull(pc)
        suspendSet { p.setRemoteDescription(it, SessionDescription(SessionDescription.Type.ANSWER, sdp)) }
    }

    override fun addCandidates(c: List<Candidate>) { c.forEach { pc?.addIceCandidate(IceCandidate(it.sdpMid, it.mLineIndex, it.sdp)) } }
    override fun setMuted(muted: Boolean) { track?.setEnabled(!muted) }

    override suspend fun path(): PathInfo? = suspendCancellableCoroutine { cont ->
        val p = pc ?: return@suspendCancellableCoroutine cont.resume(null)
        p.getStats { report ->
            val pair = report.statsMap.values.firstOrNull { it.type == "candidate-pair" && it.members["nominated"] == true && it.members["state"] == "succeeded" }
            val local = pair?.let { report.statsMap[it.members["localCandidateId"] as? String] }
            val path = when {
                local == null -> null
                local.members["candidateType"] == "relay" -> "relay-" + ((local.members["relayProtocol"] as? String) ?: "udp")
                else -> "direct"
            }
            val rtt = ((pair?.members?.get("currentRoundTripTime") as? Double) ?: 0.0) * 1000
            cont.resume(path?.let { PathInfo(it, rtt.toLong()) })
        }
    }

    override fun close() {
        runCatching { pc?.dispose() }; pc = null
        runCatching { factory?.dispose() }; factory = null
        runCatching { adm?.release() }; adm = null
        track = null; listener = null
    }

    private suspend fun setLocalAndGather(p: PeerConnection, sdp: SessionDescription): String {
        trickle = false
        gatheringDone = CompletableDeferred()
        suspendSet { p.setLocalDescription(it, sdp) }
        withTimeoutOrNull(CallTimers.GATHER_MS) { gatheringDone?.await() } // ≤ 2 s (D81)
        trickle = true
        return p.localDescription.description // includes the candidates gathered so far
    }

    private val observer = object : PeerConnection.Observer {
        override fun onIceCandidate(c: IceCandidate) { if (trickle) listener?.onCandidate(Candidate(c.sdpMid, c.sdpMLineIndex, c.sdp)) }
        override fun onIceGatheringChange(s: PeerConnection.IceGatheringState) { if (s == PeerConnection.IceGatheringState.COMPLETE) gatheringDone?.complete(Unit) }
        override fun onIceConnectionChange(s: PeerConnection.IceConnectionState) {
            when (s) {
                PeerConnection.IceConnectionState.CONNECTED, PeerConnection.IceConnectionState.COMPLETED -> listener?.onIce(IcePhase.CONNECTED)
                PeerConnection.IceConnectionState.DISCONNECTED, PeerConnection.IceConnectionState.FAILED -> listener?.onIce(IcePhase.LOST)
                else -> {}
            }
        }
        override fun onSignalingChange(s: PeerConnection.SignalingState) {}
        override fun onIceConnectionReceivingChange(b: Boolean) {}
        override fun onIceCandidatesRemoved(c: Array<out IceCandidate>) {}
        override fun onAddStream(s: MediaStream) {}
        override fun onRemoveStream(s: MediaStream) {}
        override fun onDataChannel(d: DataChannel) {}
        override fun onRenegotiationNeeded() {}
        override fun onAddTrack(r: RtpReceiver, s: Array<out MediaStream>) {}
    }

    private suspend fun suspendSdp(block: (SdpObserver) -> Unit): SessionDescription = suspendCancellableCoroutine { cont ->
        block(object : SdpObserver {
            override fun onCreateSuccess(d: SessionDescription) = cont.resume(d)
            override fun onCreateFailure(e: String) = cont.resumeWithException(IllegalStateException(e))
            override fun onSetSuccess() {}
            override fun onSetFailure(e: String) {}
        })
    }

    private suspend fun suspendSet(block: (SdpObserver) -> Unit): Unit = suspendCancellableCoroutine { cont ->
        block(object : SdpObserver {
            override fun onCreateSuccess(d: SessionDescription) {}
            override fun onCreateFailure(e: String) {}
            override fun onSetSuccess() = cont.resume(Unit)
            override fun onSetFailure(e: String) = cont.resumeWithException(IllegalStateException(e))
        })
    }

    companion object {
        @Volatile private var initialized = false
        @Synchronized fun init(context: Context) {
            if (initialized) return
            PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(context.applicationContext).createInitializationOptions())
            initialized = true
        }
    }
}
```

  Check observer method names against `javap -classpath <aar classes.jar> org.webrtc.PeerConnection\$Observer` for
  M150 (some callbacks have default implementations; remove overrides that do not exist). `CallModule.kt` in `:app`:

```kotlin
@Module @InstallIn(SingletonComponent::class)
object CallModule {
    @Provides fun mediaEngines(@ApplicationContext c: Context): MediaEngine.Factory = MediaEngine.Factory { WebRtcEngine(c) }
}
```

- [ ] **Step 9: Build** `./gradlew assembleDebug` and run the Verify command → pass.

- [ ] **Step 10: Commit** — `git commit -m "calls: CallManager, TURN cache, WebRTC M150 media engine (relay-only, Opus DTX)"`.

---

### Task 12: Android — ringing, Telecom, foreground service, call screen, call button, missed calls

**Goal:** A call rings full-screen on a locked phone with the app closed, runs as a Telecom-managed `phoneCall`
foreground service with a CallStyle notification, has a call screen (mute, speaker, hang up, timer) and starts from
the 1:1 chat's top bar.

**Files:**
- Modify: `app/src/main/AndroidManifest.xml`, `app/.../notify/Channels.kt` (channels `calls`, `missed_calls`),
  `app/.../notify/NotificationModule.kt` (bind `CallAlerts`)
- Create: `app/src/main/java/app/ottermsg/calls/CallNotifier.kt`, `CallService.kt`, `CallActivity.kt`,
  `CallAudio.kt`
- Create: `feature/calls/.../CallScreen.kt`, `CallViewModel.kt`, strings (RU/EN)
- Modify: `feature/conversation/.../ConversationScreen.kt` (top-bar action + permission + push warning dialog),
  `ConversationViewModel.kt` (`canCall`, `checkCall`), `app/.../AppNavHost.kt` (`onCall` → `CallActivity`)
- Test: `app/src/test/.../calls/CallNotifierTest.kt` (Robolectric), `feature/conversation` VM test for the
  push warning

**Acceptance Criteria:**
- [ ] Manifest: `RECORD_AUDIO`, `MANAGE_OWN_CALLS`, `FOREGROUND_SERVICE_PHONE_CALL`,
  `FOREGROUND_SERVICE_MICROPHONE`, `USE_FULL_SCREEN_INTENT`, `WAKE_LOCK`; `CallService`
  `foregroundServiceType="phoneCall|microphone"`, not exported; `CallActivity` `showWhenLocked`, `turnScreenOn`,
  `launchMode="singleTask"`, `excludeFromRecents`.
- [ ] Incoming call: CallStyle `forIncomingCall` notification on channel `calls` (ringtone, vibration,
  `FLAG_INSISTENT`, full-screen intent → `CallActivity`), Accept/Decline actions; then `CallService` start is
  attempted; if Android refuses a background FGS start, ringing still works through the notification and the service
  starts on Accept.
- [ ] `CallService` registers with `CallsManager` (`CAPABILITY_BASELINE`), `addCall` incoming/outgoing with
  `onAnswer → manager.accept()`, `onDisconnect → manager.hangUp()`, `setActive()` on `Active`, `disconnect` on
  `Idle`; foreground type `phoneCall` while ringing/outgoing, `phoneCall|microphone` after answer; CallStyle
  `forOngoingCall` with hang-up; stops itself on `Idle`.
- [ ] `manager.systemBusy` = `AudioManager.mode` is `MODE_IN_CALL` or `MODE_IN_COMMUNICATION` (no extra permission).
- [ ] Call screen: name, initials avatar (`OtterAvatar`, D34), state text («Соединение…», «Звонит…», «Входящий
  звонок», «Соединяем…», timer m:ss, end text from `ended`), mute, speaker (Telecom `requestEndpointChange`), hang
  up; incoming shows Accept/Decline; proximity wake lock while the earpiece is active; closes 2 s after `Idle`.
- [ ] Chat top bar: phone icon only for direct (not group, not news) chats; tap → `RECORD_AUDIO` permission (first
  time) → `push.status`; `false` → dialog «Собеседник может не услышать звонок — у него нет push-уведомлений»
  (Позвонить / Отмена) → `manager.dial(peer)` + `CallActivity`; `CallNotice.NotAvailable` → snackbar «Звонки
  недоступны: сервер не обновлён». Tapping a call line calls back the same way.
- [ ] Missed call: notification on `missed_calls` («Пропущенный звонок», name), tap opens the chat, action
  «Перезвонить» starts a call.

**Verify:** `cd otter-android && ./gradlew :app:testDebugUnitTest :feature:conversation:testDebugUnitTest assembleDebug lintDebug` → `BUILD SUCCESSFUL`, no new lint errors

**Steps:**

- [ ] **Step 1: Manifest** additions (`app/src/main/AndroidManifest.xml`):

```xml
    <uses-permission android:name="android.permission.RECORD_AUDIO" />
    <uses-permission android:name="android.permission.MANAGE_OWN_CALLS" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_PHONE_CALL" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
    <uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT" />
    <uses-permission android:name="android.permission.WAKE_LOCK" />
    <application ...>
        <activity android:name=".calls.CallActivity" android:exported="false" android:showWhenLocked="true"
            android:turnScreenOn="true" android:launchMode="singleTask" android:excludeFromRecents="true"
            android:taskAffinity="app.ottermsg.calls" />
        <service android:name=".calls.CallService" android:exported="false"
            android:foregroundServiceType="phoneCall|microphone" />
    </application>
```

- [ ] **Step 2: Channels.** In `Channels.kt` add `CALLS = "calls"` (IMPORTANCE_HIGH, sound
  `RingtoneManager.getDefaultUri(TYPE_RINGTONE)` with `AudioAttributes.USAGE_NOTIFICATION_RINGTONE`, vibration on,
  name «Звонки»/"Calls") and `MISSED_CALLS = "missed_calls"` (IMPORTANCE_HIGH, default sound, «Пропущенные звонки» /
  "Missed calls"). Channel sound is fixed at creation — existing installs get the new channels on first start after
  the update (`create()` runs at app start).

- [ ] **Step 3: CallNotifier** (`app/.../calls/CallNotifier.kt`) implements `CallAlerts`:

```kotlin
@Singleton
class CallNotifier @Inject constructor(@ApplicationContext private val ctx: Context) : CallAlerts {
    private val nm = NotificationManagerCompat.from(ctx)

    override fun incoming(call: CallState.Incoming) {
        post(INCOMING_ID, incomingNotification(call))
        try { ContextCompat.startForegroundService(ctx, Intent(ctx, CallService::class.java)) }
        catch (e: Exception) { /* background FGS start refused: notification-only ringing until Accept (D80) */ }
    }

    override fun missed(peer: Peer, conversationId: Long) {
        val open = PendingIntent.getActivity(ctx, conversationId.toInt(), Intent(ctx, MainActivity::class.java)
            .setAction(MessageNotifier.ACTION_OPEN).putExtra(MessageNotifier.EXTRA_CONVERSATION, conversationId)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val back = PendingIntent.getActivity(ctx, conversationId.toInt() * 4 + 3, CallActivity.callBack(ctx, peer),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(ctx, Channels.MISSED_CALLS).setSmallIcon(R.drawable.ic_stat_otter)
            .setContentTitle(ctx.getString(R.string.call_missed_title)).setContentText(peer.name)
            .setCategory(NotificationCompat.CATEGORY_MISSED_CALL).setAutoCancel(true).setContentIntent(open)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .addAction(0, ctx.getString(R.string.call_back), back).build()
        post(MISSED_BASE + conversationId.toInt(), n)
    }

    override fun released() { nm.cancel(INCOMING_ID) }

    fun incomingNotification(call: CallState.Incoming): Notification {
        val person = Person.Builder().setName(call.peer.name).setImportant(true).build()
        val full = PendingIntent.getActivity(ctx, 1, CallActivity.show(ctx), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val answer = PendingIntent.getActivity(ctx, 2, CallActivity.answer(ctx), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val decline = PendingIntent.getService(ctx, 3, CallService.decline(ctx), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(ctx, Channels.CALLS).setSmallIcon(R.drawable.ic_stat_otter)
            .setStyle(NotificationCompat.CallStyle.forIncomingCall(person, decline, answer))
            .setFullScreenIntent(full, true).setOngoing(true).setCategory(NotificationCompat.CATEGORY_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC) // name + Accept/Decline on the lock screen, like any phone call
            .build().apply { flags = flags or Notification.FLAG_INSISTENT }
    }

    fun ongoingNotification(name: String): Notification {
        val person = Person.Builder().setName(name).setImportant(true).build()
        val hang = PendingIntent.getService(ctx, 4, CallService.hangUp(ctx), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(ctx, 5, CallActivity.show(ctx), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(ctx, Channels.CALLS).setSmallIcon(R.drawable.ic_stat_otter)
            .setStyle(NotificationCompat.CallStyle.forOngoingCall(person, hang)).setContentIntent(open)
            .setOngoing(true).setSilent(true).setCategory(NotificationCompat.CATEGORY_CALL).build()
    }

    private fun post(id: Int, n: Notification) { try { nm.notify(id, n) } catch (_: SecurityException) {} }

    companion object { const val INCOMING_ID = Int.MAX_VALUE - 3; const val ONGOING_ID = Int.MAX_VALUE - 4; const val MISSED_BASE = 1_000_000 }
}
```

  Bind in `NotificationModule`: `@Binds abstract fun callAlerts(n: CallNotifier): CallAlerts`. Strings (app):
  `call_missed_title` «Пропущенный звонок»/"Missed call", `call_back` «Перезвонить»/"Call back". The incoming
  notification shows the contact's display name on the lock screen — the same as an ordinary phone call; note it in
  D80. Robolectric test: `incoming()` posts a notification on channel `calls` with `CATEGORY_CALL`, a full-screen
  intent and `FLAG_INSISTENT`; `missed()` posts one on `missed_calls` with the «Перезвонить» action; `released()`
  cancels the incoming one.

- [ ] **Step 4: CallAudio + CallService.** `CallAudio` (`@Singleton`) holds
  `MutableStateFlow<List<CallEndpointCompat>>` (available), `MutableStateFlow<CallEndpointCompat?>` (current) and a
  `var request: (suspend (CallEndpointCompat) -> Unit)?` set by the service; `toggleSpeaker()` picks the SPEAKER
  endpoint or back to EARPIECE/BLUETOOTH/WIRED_HEADSET. `CallService`:

```kotlin
@AndroidEntryPoint
class CallService : LifecycleService() {
    @Inject lateinit var manager: CallManager
    @Inject lateinit var notifier: CallNotifier
    @Inject lateinit var audio: CallAudio
    @Inject lateinit var accounts: AccountRepository
    private var callJob: Job? = null
    private var foreground = false

    override fun onCreate() {
        super.onCreate()
        val am = getSystemService(AudioManager::class.java)
        manager.systemBusy = { am.mode == AudioManager.MODE_IN_CALL || (am.mode == AudioManager.MODE_IN_COMMUNICATION && manager.state.value == CallState.Idle) }
        lifecycleScope.launch {
            accounts.load() // every background entry point loads the account first (D61)
            manager.state.collect { s -> onState(s) }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        when (intent?.action) {
            ACTION_DECLINE -> manager.decline()
            ACTION_HANGUP -> manager.hangUp()
        }
        ensureForeground(manager.state.value)
        return START_NOT_STICKY
    }

    private fun ensureForeground(s: CallState) {
        val (name, n) = when (s) {
            is CallState.Incoming -> s.peer.name to notifier.incomingNotification(s)
            is CallState.Outgoing -> s.peer.name to notifier.ongoingNotification(s.peer.name)
            is CallState.Connecting -> s.peer.name to notifier.ongoingNotification(s.peer.name)
            is CallState.Active -> s.peer.name to notifier.ongoingNotification(s.peer.name)
            CallState.Idle -> { stopSelf(); return }
        }
        val mic = s is CallState.Connecting || s is CallState.Active || s is CallState.Outgoing
        val type = if (mic && Build.VERSION.SDK_INT >= 30 && hasMic())
            ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        else ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
        ServiceCompat.startForeground(this, CallNotifier.ONGOING_ID, n, if (Build.VERSION.SDK_INT >= 29) type else 0)
        foreground = true
    }

    private suspend fun onState(s: CallState) {
        ensureForeground(s)
        when (s) {
            is CallState.Incoming, is CallState.Outgoing -> if (callJob == null) callJob = lifecycleScope.launch { telecom(s) }
            CallState.Idle -> { callJob?.cancel(); callJob = null; stopSelf() }
            else -> {}
        }
    }

    private suspend fun telecom(s: CallState) {
        val cm = CallsManager(this)
        cm.registerAppWithTelecom(CallsManager.CAPABILITY_BASELINE)
        val peer = (s as? CallState.Incoming)?.peer ?: (s as CallState.Outgoing).peer
        val attrs = CallAttributesCompat(peer.name, Uri.parse("otter:" + peer.id.joinToString("") { "%02x".format(it) }),
            if (s is CallState.Incoming) CallAttributesCompat.DIRECTION_INCOMING else CallAttributesCompat.DIRECTION_OUTGOING,
            CallAttributesCompat.CALL_TYPE_AUDIO_CALL, CallAttributesCompat.SUPPORTS_SET_INACTIVE)
        try {
            cm.addCall(attrs, onAnswer = { manager.accept() }, onDisconnect = { manager.hangUp() },
                onSetActive = {}, onSetInactive = { manager.hangUp() /* no hold in V1 */ }) {
                launch { availableEndpoints.collect { audio.available.value = it } }
                launch { currentCallEndpoint.collect { audio.current.value = it } }
                audio.request = { requestEndpointChange(it) }
                launch {
                    manager.state.collect { st ->
                        when (st) {
                            is CallState.Active -> setActive()
                            is CallState.Connecting -> if (s is CallState.Incoming) answer(CallAttributesCompat.CALL_TYPE_AUDIO_CALL)
                            CallState.Idle -> { disconnect(DisconnectCause(DisconnectCause.LOCAL)); cancel() }
                            else -> {}
                        }
                    }
                }
            }
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            // Telecom refused (e.g. another call): the call continues without system integration
        } finally { audio.request = null }
    }

    private fun hasMic() = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    companion object {
        const val ACTION_DECLINE = "app.ottermsg.calls.DECLINE"; const val ACTION_HANGUP = "app.ottermsg.calls.HANGUP"
        fun decline(c: Context) = Intent(c, CallService::class.java).setAction(ACTION_DECLINE)
        fun hangUp(c: Context) = Intent(c, CallService::class.java).setAction(ACTION_HANGUP)
    }
}
```

  `addCall`'s exact parameter names/lambda types must match `androidx.core.telecom.CallsManager` 1.0.1 (`javap` or
  the sources jar). The remote-surface lambdas return quickly (they only post to the manager). Post the CallStyle
  notification before/at `addCall` (it already is — `ensureForeground` runs first).

- [ ] **Step 5: CallActivity + screen.** `CallActivity` (`@AndroidEntryPoint`, `ComponentActivity`): handles
  intents `SHOW`, `ANSWER` (→ `manager.accept()` + `startForegroundService(CallService)`), `CALL_BACK` (extras
  `peer_id` hex, `peer_name` → same flow as the chat button), sets `setShowWhenLocked(true)`/`setTurnScreenOn(true)`,
  holds a `PROXIMITY_SCREEN_OFF_WAKE_LOCK` while state is `Connecting`/`Active` and the current endpoint is the
  earpiece, `finish()`es 2 s after `Idle`, content = `CallRoute()` from `:feature:calls`. Companion builders
  `show(ctx)`, `answer(ctx)`, `callBack(ctx, peer)`.

  `CallViewModel` (`@HiltViewModel`): exposes `CallUi(name, seed, status, elapsed, incoming, muted, speaker)` from
  `manager.state` + a 1 s ticker + `manager.ended` (end text shown for 2 s) + `CallAudio`; actions `accept`,
  `decline`, `hangUp`, `toggleMute`, `toggleSpeaker`. Status strings (`feature/calls` RU/EN): «Соединение…»
  /"Connecting…" (Outgoing, not ringing), «Звонит…»/"Ringing…", «Входящий звонок»/"Incoming call", «Соединяем…»
  /"Connecting…" (Connecting), «Переподключение…»/"Reconnecting…" (Active with `lostSinceMs`), end texts reuse the
  call-line strings. `CallScreen`: centered `OtterAvatar(name, seed, size = 96.dp)`, name, status/timer, bottom row
  of round buttons (mute, speaker, red hang-up) or (green accept, red decline) when incoming; content descriptions
  for TalkBack. Unit test `CallViewModel` status mapping (pure function `statusText(state, nowMs)` tested without
  Android).

- [ ] **Step 6: Call button.** `ConversationUi` gains `canCall = !isGroup && !isNews && canWrite`. `ConversationScreen`
  top bar `actions = { if (ui.canCall) IconButton(onClick = onCallClick) { Icon(Icons.Outlined.Call, stringResource(R.string.conv_call)) } }`.
  Flow inside `ConversationRoute`: `rememberLauncherForActivityResult(RequestPermission())` for `RECORD_AUDIO` →
  `vm.prepareCall()` which calls an injected `CallStarter` (`interface CallStarter { suspend fun peerHasPush(peer:
  ByteArray): Boolean; fun dial(peer: Peer) }`, implemented by `CallManager`, bound in `DataModule`) →
  `has_push=false` → `AlertDialog` with the warning text and «Позвонить»/«Отмена» → `dial` → `onCallStarted()`
  callback, which `AppNavHost` maps to `context.startActivity(CallActivity.show(context))` plus
  `ContextCompat.startForegroundService(context, Intent(context, CallService::class.java))`. A `CallNotice.NotAvailable`
  collected in `ConversationRoute` shows the snackbar. Denied permission → snackbar «Нужен доступ к микрофону» with
  «Настройки». Strings in `feature/conversation`: `conv_call` «Позвонить»/"Call", `conv_call_no_push` (warning),
  `conv_call_anyway` «Позвонить»/"Call anyway", `conv_call_unavailable` «Звонки недоступны: сервер не обновлён»/"Calls
  unavailable: the server is not updated", `conv_call_mic` «Нужен доступ к микрофону»/"Microphone access needed".
  VM test: `peerHasPush=false` → `ui.callWarning == true`; confirm → `dial` called once.

- [ ] **Step 7: Call lines call back.** `CallLineChip(onClick = onCallClick)` reuses the same flow.

- [ ] **Step 8: Run** the Verify command; fix lint findings introduced by the new code.

- [ ] **Step 9: Commit** — `git commit -m "calls: ringing (CallStyle, full-screen), Telecom FGS, call screen, chat call button, missed calls"`.

---

### Task 13: Android — call lines in «Журнал подключений», settings toggle, full-screen-intent fix, version 0.8.0

**Goal:** Each call adds one merged net_log line; Settings has «Звонки только через сервер» and a one-tap fix when
Android 14+ forbids full-screen ringing; the app is 0.8.0 / versionCode 8.

**Files:**
- Modify: `core/data/.../calls/CallManager.kt` (`logCall`), `feature/settings/.../SettingsScreen.kt`,
  `SettingsViewModel` (or a new `CallsSettingsViewModel`), strings; `app/build.gradle.kts`
- Test: `core/data/src/test/.../calls/CallManagerTest.kt` (netlog case), `feature/settings` VM test

**Acceptance Criteria:**
- [ ] After a call ends, `NetLog` gets `NetLogEntry(nodeLabel = <current node label>, endpoint = "call:<path>",
  result = OK for answered calls else TIMEOUT/REFUSED mapping below, detail = "<outcome> <m:ss>", rttMs = <rtt>)`,
  where `<path>` is `relay-udp|relay-tcp|relay-tls|direct|none` from `MediaEngine.path()` (read before release).
  Mapping: OUTGOING/INCOMING → `OK`; FAILED → `TIMEOUT`; NO_ANSWER/BUSY/DECLINED/MISSED → `OK` with the outcome in
  detail (the call worked technically). Same merge rule as M7.
- [ ] Settings → «Подключение»: switch «Звонки только через сервер» (subtitle «Собеседник не увидит ваш IP-адрес» /
  "The other person won't see your IP address"), default on; persisted via `Settings.callsRelayOnly`.
- [ ] On API 34+ when `NotificationManagerCompat.canUseFullScreenIntent()` is false, Settings shows a row
  «Разрешить звонки на заблокированном экране» that opens `Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT`
  for the app.
- [ ] `versionCode = 8`, `versionName = "0.8.0"`.

**Verify:** `cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*CallManager*' :feature:settings:testDebugUnitTest assembleRelease && aapt2 dump badging app/build/outputs/apk/release/app-release.apk | grep versionCode` → `versionCode='8' versionName='0.8.0'`

**Steps:**

- [ ] **Step 1: Failing test** (CallManagerTest): after dial → answer → CONNECTED → hangUp, the recording `NetLog`
  holds one entry with `endpoint == "call:relay-udp"` (FakeEngine path), `result == FailureClass.OK`, `rttMs == 40`,
  detail starting `"OUTGOING "`.

- [ ] **Step 2: Implement `logCall`.** Capture the path before `Release` closes the engine: in `run()` for
  `CallEffect.Line`, call `val p = engine?.path()` first, then:

```kotlin
    private suspend fun logCall(e: CallEffect.Line, p: PathInfo?) {
        val label = (sync.connection.value as? ConnectionState.Online)?.nodeLabel ?: "-"
        val d = "%d:%02d".format(e.durationS / 60, e.durationS % 60)
        netLog.add(NetLogEntry(label, "call:" + (p?.path ?: "none"),
            if (e.outcome == CallOutcome.FAILED) FailureClass.TIMEOUT else FailureClass.OK,
            "${e.outcome.name} $d", p?.rttMs ?: 0))
    }
```

  (use the real accessor for the connection state; `SyncEngine` exposes it to `SettingsViewModel` already).

- [ ] **Step 3: Settings UI.** Add the switch row (pattern `PhotoStorageScreen.kt:144-152`) to the «Подключение»
  section and the full-screen-intent row (only when `Build.VERSION.SDK_INT >= 34 &&
  !NotificationManagerCompat.from(ctx).canUseFullScreenIntent()`, re-checked on resume). Strings RU/EN in
  `feature/settings`: `settings_calls_relay_only`, `settings_calls_relay_only_sub`, `settings_calls_fsi`. VM test:
  toggling calls `setCallsRelayOnly(false)`; default emits `true`.

- [ ] **Step 4: Version** — `versionCode = 8`, `versionName = "0.8.0"` in `app/build.gradle.kts`.

- [ ] **Step 5: Run** the Verify command → pass.

- [ ] **Step 6: Commit** — `git commit -m "calls: call lines in the connection log, relay-only setting, full-screen fix, version 0.8.0"`.

---

### Task 14: Acceptance on the dev mesh and two emulators; manual checklists

**Goal:** Prove the local half of "Done when" before any real server or phone is touched, and leave exact
checklists for the owner's real-network rows.

**Files:**
- Create: `otter-server/docs/m8-manual-test.md`, `otter-android/docs/m8-manual-test.md`
- Modify (if needed): `otter-server/scripts/dev-mesh.sh` (optional `--turn`: writes `[turn]` with
  `relay_ip = "<LAN or 10.0.2.2-reachable IP>"`, `allow_private_peers = true`, runs `turn keygen`)

**Acceptance Criteria:**
- [ ] Server: `make check`; `go test ./internal/meshsim/ -run 'Turn|CallRelay' -count=3 -race`;
  `deploy/test/scripts_test.sh` in a scratch copy → all green. Binary size before/after recorded.
- [ ] Dev mesh with TURN on two nodes (`dev-mesh.sh --turn`), two emulators (API 34 and API 30; debug or staging
  build, `x86_64`), each logged in on a different node, **relay-only on**: A calls B with B's app closed and screen
  locked → B rings full-screen → accept → audio both ways (emulator mic: use the emulator's "virtual microphone uses
  host audio input" or a tone; record what was used) for ≥ 2 min → hang up → both chats show «Исходящий/Входящий
  звонок · m:ss»; «Журнал подключений» shows `call:relay-udp`.
- [ ] Decline → caller «Отклонён»; no answer 45 s → «Не отвечает» / «Пропущенный звонок» + notification; second
  call while in a call → «Занято»; TURN disabled on a node → «Звонки недоступны: сервер не обновлён».
- [ ] UDP blocked on this PC for the TURN ports (temporary `nft`/`iptables` rule **on this PC only**, removed after)
  → the call connects over TCP or TLS (`call:relay-tcp`/`relay-tls` in the log).
- [ ] `tcpdump -i lo -n udp portrange 49160-49200 -X` (dev mesh relay range) shows only DTLS/SRTP (no readable
  audio); documented in the server checklist.
- [ ] App 0.7.0 → 0.8.0 update on an emulator through a dev news announcement keeps account, chats and news (Room
  7→8).
- [ ] Both checklists list every spec row (8 phone rows + server rows), mark the local results PASS with a date, and
  leave the real-network rows (eeee, ru-1, two real phones, Bluetooth, Wi-Fi→mobile switch) as "—" for the owner.

**Verify:** both checklist files exist; every local row is marked PASS with a date; `nft list ruleset`/`iptables -S`
shows no leftover test rule.

**Steps:**

- [ ] **Step 1:** Run the automated checks; fix failures with the systematic-debugging skill.
- [ ] **Step 2:** Dev mesh with TURN; emulators; run the scenarios; record exact commands in
  `otter-server/docs/m8-manual-test.md` (model: `docs/m7-manual-test.md` — sections "Automated checks", "Local
  two-node run", "Rows" table `| # | Step | Expected | Result |`).
- [ ] **Step 3:** Phone rows in `otter-android/docs/m8-manual-test.md` (model: `docs/m7-manual-test.md`), rows 1–8
  from the spec plus: locked/closed ringing on API 30 and 34, full-screen-intent denied (heads-up only + Settings fix
  row), relay-only off (direct path on the same LAN shows `call:direct`), 0.7.0 phone receives a call (nothing
  rings; may get an empty chat — matches the news note).
- [ ] **Step 4:** Remove temporary firewall rules; verify.
- [ ] **Step 5: Commit** — `git commit -m "docs: M8 manual checklists"` in both repos.

---

### Task 15: Docs, decisions D76–D81, news draft

**Goal:** Docs describe M8 as built; the 0.8.0 news draft is ready.

**Files:**
- Modify (docs repo, branch `m8-calls`): `00-decisions.md` (D76–D81; D6 note: calls moved from V2 to M8/M8.5),
  `02-protocol.md` (done in Task 1; re-check), `05-transport.md` (TURN ports, relay choice, TCP/TLS fallback,
  relay-only), `06-node-architecture.md` (`internal/turnsrv`, `[turn]`, stats file, netlog classes),
  `07-android-architecture.md` (`:feature:calls`, CallManager/state machine/MediaEngine, Telecom, FGS, Room v8),
  `08-operations.md` (`turn-setup.sh`, firewall, status TURN column, `turn keygen`), `09-roadmap.md` (M8 row → done
  with notes "## M8 notes"), `README.md`
- Modify: `otter-server/README.md` ("Calls (TURN, M8)"), `otter-android/README.md` (one paragraph)
- Create: `otter-server/dist/news/0.8.0.md` (gitignored; never delete files in `dist/`)

**Acceptance Criteria:**
- [ ] D76 (WebRTC M150 `io.github.webrtc-sdk:android`, 1:1 audio, Opus; revises D6), D77 (embedded Pion TURN v5:
  ports, per-node secret, 12 h TURN-REST, quotas, rate cap, UDP relays only, peer deny list, no TLS verification),
  D78 (`CallMessage` field 6, urgent, 2-min expiry + node filter/purge, DELIVERED for offers, fingerprints only in
  encrypted SDP, glare rule), D79 (own-node relay, relay-only default on), D80 (core-telecom 1.0.1, `phoneCall` FGS,
  CallStyle full-screen, lock-screen shows the caller's name, call lines in the chat, no tab, background-FGS
  fallback), D81 (timers) recorded with reasons; the "pion/turn v5 instead of v4" and "webrtc-sdk instead of
  stream-webrtc" choices are in the reasons.
- [ ] News draft `## ru` / `## en`: calls in 1:1 chats, relay-only privacy, Android may ask for microphone and
  "full-screen notifications"; phones on 0.7.0 cannot receive calls and may see an empty chat appear when someone
  calls them — update to 0.8.0. No IPs or server names.

**Verify:** `cd docs && scripts/secrets-check.sh` → `secrets check: ok`; `grep -c '^| D7[6-9]\|^| D8[01]' 00-decisions.md` → `6`

**Steps:**

- [ ] **Step 1:** Write the docs; commit on `m8-calls` in `docs` (`git commit -m "docs: M8 calls (D76–D81)"`).
- [ ] **Step 2:** Write `otter-server/dist/news/0.8.0.md`:

```markdown
## ru
Otter 0.8.0
• Звонки! В личном чате нажмите на трубку вверху. Звонок зашифрован от телефона до телефона и идёт через наш сервер — собеседник не видит ваш IP-адрес (это можно выключить: Настройки → Подключение).
• При первом звонке Android попросит доступ к микрофону, а на новых телефонах — разрешение показывать звонок на заблокированном экране. Пожалуйста, разрешите.
• Пропущенные звонки видны в чате и в уведомлениях.
• Если у собеседника старая версия, звонок до него не дойдёт (и у него может появиться пустой чат с вами) — попросите его обновиться.

## en
Otter 0.8.0
• Calls! In a one-to-one chat, tap the phone icon at the top. Calls are encrypted from phone to phone and go through our server, so the other person never sees your IP address (you can turn this off: Settings → Connection).
• On the first call Android asks for microphone access and, on newer phones, permission to show calls on the lock screen. Please allow both.
• Missed calls appear in the chat and as notifications.
• If the other person still has the old version, the call won't reach them (and an empty chat with you may appear for them) — ask them to update.
```

---

### Task 16: Final verification; merge after the owner says so

**Goal:** Everything is green on all three branches; the owner approves; branches are merged with `--no-ff`.

**Files:** none new.

**Acceptance Criteria:**
- [ ] `otter-server`: `make check` → ok; `go test ./internal/meshsim/ -count=3 -race` → ok; `scripts_test.sh` in a
  scratch copy → `scripts_test: ok`; `make release VERSION=0.8.0` builds into `dist/` (nothing in `dist/` deleted).
- [ ] `otter-android`: `./gradlew test lintDebug assembleRelease` → BUILD SUCCESSFUL; release APK release-signed
  (`apksigner verify --print-certs` shows the release certificate, not the debug one); ABIs arm64-v8a + armeabi-v7a
  only; size recorded.
- [ ] `scripts/secrets-check.sh` → `secrets check: ok` in `otter-server`, `otter-android`, `docs`.
- [ ] The owner has seen a summary (what changed, sizes, checklist status, open owner rows) and said "merge"; then
  in each repo `git checkout main && git merge --no-ff m8-calls && git push`.

**Verify:** `git -C otter-server log --oneline -1 main` (and android, docs) shows the merge commit after the owner's
approval; secrets checks printed `ok` immediately before the push.

**Steps:**

- [ ] **Step 1:** Run every check above; fix and re-run until green (verification-before-completion skill).
- [ ] **Step 2:** `make release VERSION=0.8.0`; `JAVA_HOME=... ./gradlew assembleRelease` (the owner's
  `keystore.properties` signs it; never print or copy the keystore or its passwords).
- [ ] **Step 3:** Show the owner the summary; wait for "merge". Then merge and push all three repos (secrets checks
  first).

---

### Task 17: Owner rollout on the real network (each step asked first)

**Goal:** M8 running on eeee (and ru-1 once it exists); phones on 0.8.0; real-network checklist rows filled.

**Files:** none in git (state lives on the servers, in `~/.otter-admin` and on the phones).

**Acceptance Criteria:**
- [ ] Every node runs 0.8.0 with `TURN on` in `deploy/status.sh`; the host's other services on eeee still answer;
  cloud firewall opened for UDP 3478, TCP 3478, TCP 5349, UDP 49160–49200 (owner, in the provider's panel).
- [ ] Both phones on 0.8.0 via the news update; the real-network rows of both checklists are filled by the owner.

**Verify:** the owner marks the real-network rows PASS (or records what failed) in both `m8-manual-test.md` files.

**Steps (ask before each; passphrases only in the owner's terminal):**

- [ ] **Step 1 (ask):** `deploy/upgrade-all.sh 0.8.0 --no-news` → each node upgraded, health ok, then
  `turn-setup.sh --if-missing` turns TURN on. On eeee check the host's other services afterwards: `ss -ltnp` still shows them
  and the photo site answers. (ru-1: only if it was installed in M7 Task 13; otherwise its install with
  `add-node.sh` gets TURN from the 0.8.0 bundle.)
- [ ] **Step 2 (owner):** open the TURN ports in the hosting provider's firewall panel for each node.
- [ ] **Step 3 (ask):** `deploy/status.sh` → `TURN on` for every node; `otter-node netlog` shows no `turn … listen`
  failures.
- [ ] **Step 4 (owner runs):** `deploy/release-apk.sh 0.8.0 <release APK>` → news dialog with `dist/news/0.8.0.md`;
  phones update via «Обновить»; first call grants microphone and full-screen permissions.
- [ ] **Step 5 (owner, asked first for the firewall part):** the real-network rows: abroad ↔ abroad via eeee; RU ↔ RU
  via ru-1 (after M7 Task 13); RU mobile ↔ foreign Wi-Fi, 5 min, relay-only (best effort, D79 — record the path
  from «Журнал подключений»); UDP blocked by a temporary firewall rule on a node (asked first, removed after) → TCP/TLS;
  packet capture on the node shows only DTLS/SRTP; locked/closed ringing; Bluetooth/speaker/proximity; Wi-Fi →
  mobile switch mid-call recovers.
