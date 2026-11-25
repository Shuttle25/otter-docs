# M10 1:1 Video Calls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In any 1:1 Otter call either person can switch their camera on at any time; video (up to 720p, ≤ 1.5 Mbit/s,
360p ≤ 500 kbit/s in «Экономить трафик») flows end-to-end encrypted over the same relays as the audio, pauses to
audio-only on a weak link instead of dropping the call, and the camera starts only when the local user taps it.

**Architecture:** Every new call negotiates one audio and one video transceiver (Unified Plan, BUNDLE, one TURN
allocation). The video transceiver is `sendrecv` with no track; the camera is attached with `RtpSender.setTrack` and
detached with `setTrack(null)` — no renegotiation. The camera state travels as a new `CallMessage.media = 6`
(`CallMedia{camera_on, paused}`) inside the Signal-encrypted call signaling, sent **non-urgent**. A pure-Kotlin
`CallStateMachine` gains a `VideoState` and a `VideoWatchdog` (pause < 150 kbit/s for 10 s, resume after 15 s
> 400 kbit/s measured in short test bursts) driven once a second by `MediaEngine.stats()`; the hard rule "only a
`UserCamera(on = true)` event produces `StartCamera`" is enforced by a property test and a source-scan test. The
Android layer adds renderers (`SurfaceViewRenderer` through a `VideoSinks` holder), the camera permission on the first
tap, a `camera` foreground-service type only while the camera is on, picture-in-picture, and a Settings switch. Nodes
only change a setting: `[turn] relay_kbps` 200 → 2000, plus one log line per closed allocation with its bit rates.

**Tech Stack:** Go 1.26, `github.com/pion/turn/v5 v5.1.3`; Android Kotlin 2.2.21, AGP 8.13.2,
`io.github.webrtc-sdk:android:150.7871.04` (WebRTC M150), `androidx.core:core-telecom:1.0.1`, `androidx.activity
1.11.0`, Compose BOM 2025.10.01 (`material-icons-extended` 1.7.8), Hilt, Robolectric 4.16; protobuf shared by both
repos.

**Spec:** `docs/superpowers/specs/2026-11-15-m10-video-calls-design.md` (owner approved 2026-11-15). Extends M8
(`2026-11-13-m8-audio-calls-design.md`, D76–D81).

**Ground rules (owner):**
* Branch **`m10-video`** in `otter-server`, `otter-android` and `docs`, created from `main` **after all of M9 is merged**
  (M9.0–M9.5). TDD, small commits. Merge with `--no-ff` **only after the owner says so**. Run
  `scripts/secrets-check.sh` in every repo before any push.
* **This plan was written against the code of 2026-11-15 (M9.0 merged, M9.1–M9.4 not built yet).** M9 changes
  several files this plan touches (`CallManager.kt`, `CallStateMachine.kt`, `TurnCache.kt`, `MailboxReceiver.kt`,
  `SettingsScreen.kt`, `turnsrv/server.go`, `deploy/upgrade-all.sh`, `deploy/test/scripts_test.sh`, versions, Room
  version, decision numbers). **Before each task, re-check every `file:line` reference and every quoted snippet
  against the current code**; apply the change to the current shape of the code, keeping the names and behaviour this
  plan specifies.
* Never touch `root@eeee`, ru-1, DNS, `~/.otter-admin` or the phones without asking. Passphrases are typed only in the
  owner's terminal, never in chat. Never delete anything in `otter-server/dist/`. Run `deploy/test/scripts_test.sh`
  only in a scratch copy (it writes into `dist/`).
* Never create, print or commit `google-services.json`, `fcm*.json`, `release.jks`, `keystore.properties`. Never write
  to the desktop keyring without asking. Real IPs never in repos (`<eeee-ip>`, `203.0.113.x`).
* **Server commands on real nodes are run by the owner himself** (Task 19 gives each command, its expected output and
  its rollback). Claude prepares, explains and reads the output the owner pastes; it never runs anything on a server.
* Privacy rules of the spec are hard requirements with their own tests (Task 7, 8, 12, 15): the camera starts only from
  a user tap; answering never turns the camera on; no video on the lock screen or in the incoming-call notification.
* Environment: `export PATH=/usr/lib/go-1.26/bin:$HOME/go/bin:$PATH`;
  `export JAVA_HOME=~/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2`.
* **Commits (D57):** UTC date, time of day shown as 12:00:SS, no `Claude-Session` line. Define once per shell:
  ```bash
  oc() {  # otter commit: D57 date, then normal git commit args
    local day last n d
    day=$(date -u +%F)
    last=$(TZ=UTC git log -1 --format=%cd --date=format-local:'%F %M %S' 2>/dev/null)
    if [ "${last%% *}" = "$day" ]; then
      n=$(( 10#$(echo "$last" | cut -d' ' -f2) * 60 + 10#$(echo "$last" | cut -d' ' -f3) + 1 ))
    else n=0; fi
    d=$(printf '%sT12:%02d:%02d+0000' "$day" $((n / 60)) $((n % 60)))
    TZ=UTC GIT_AUTHOR_DATE=$d GIT_COMMITTER_DATE=$d git commit "$@"
  }
  ```
  Every message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` (pass it as a second `-m`).
* Versions: app **0.12.0 / versionCode 16**, server **0.12.0**. Decisions **D125–D129** (next free after M9's
  D82–D124; if `00-decisions.md` ends elsewhere when you get there, shift all five consistently).
* Room: **no database change** in M10 (the only new persistent value is a row of the key-value `settings` table).

## Verified facts (2026-11-15, recorded before writing the tasks)

| Question | Answer | Source |
|---|---|---|
| Repo state | All three repos on `main` at the M9.0 merge; M9.1–M9.4 not built. App 0.8.2 / versionCode 10 today; M9.4 ends at 0.10.1 / 14, M9.5 at 0.11.0 / 15 → M10 is 0.12.0 / 16. | `git log`, `app/build.gradle.kts:35`, M9 plan Task 72 |
| Proto field 6 | `CallMessage.oneof kind` uses 2–5 (`offer`, `answer`, `candidates`, `hangup`); **6 is free**; no M9 task adds a `CallMessage` field. Server and Android copies of `content.proto` are identical (`diff` → no output). Go: `make gen` (buf v1.75.0 + protoc-gen-go v1.36.12); Android: `otter-android/scripts/sync-proto.sh` copies `proto/otter/v1/*.proto`; Android uses protobuf **javalite** → `CallMessage.KindCase.MEDIA`, `CallMessage.MEDIA_FIELD_NUMBER`, `CallMedia.newBuilder().setCameraOn().setPaused()`. | `content.proto:107-115`, `Makefile:10-13`, `core/proto/build.gradle.kts:10` |
| Old app receiving `media` | 0.11.x parses the unknown oneof field as an unknown field → `kindCase == KIND_NOT_SET`; `CallManager.onCallMessage` has `else -> {}`; `MailboxReceiver` routes every `Content.BodyCase.CALL` to `CallInbox` and acks it. So an old app ignores `CallMedia` silently (no chat, no bubble). | `CallManager.kt:139-150`, `MailboxReceiver.kt:87-88` |
| Urgency of call signaling | `CallSignaling.send` makes **every** call message urgent with a 2-min expiry. M9 Task 46 treats an urgent short-expiry envelope as a call wake and allows 8 per minute per sender → camera toggles must not be urgent (they would eat the budget an offer needs). `CallMedia` goes out non-urgent (the peer is in the call and connected through the call lease). | `CallSignaling.kt:20-26`, M9 plan Task 46 |
| Fake engine name | The spec's "FakeMediaEngine" is `class FakeEngine` at the top of `CallManagerTest.kt`. Several tests assert the **exact** list `FakeEngine.calls` (e.g. `listOf("answer:their-offer", "cands:1")`) → the new video calls are recorded in a separate list `FakeEngine.video`, saver in `FakeEngine.saver`. | `CallManagerTest.kt:45-58,243,279` |
| Timer seam | `CallManager.onBusy()` starts a ticker that posts `CallEvent.Tick` every 1 s while not Idle; all state changes run on one event loop (`ops` channel). The watchdog sample is a second op posted by the same ticker. | `CallManager.kt:99-114,311-314` |
| WebRTC AAR | `~/.gradle/caches/modules-2/files-2.1/io.github.webrtc-sdk/android/150.7871.04/662256e1…/android-150.7871.04.aar`. Verified with `javap` on its `classes.jar`: `Camera2Enumerator(Context)`: `getDeviceNames()`, `isFrontFacing(String)`, `isBackFacing(String)`, `createCapturer(String, CameraVideoCapturer.CameraEventsHandler): CameraVideoCapturer`; `CameraVideoCapturer.switchCamera(CameraSwitchHandler)` with `onCameraSwitchDone(boolean isFront)` / `onCameraSwitchError(String)`; `CameraEventsHandler`: `onCameraError(String)`, `onCameraDisconnected()`, `onCameraFreezed(String)`, `onCameraOpening(String)`, `onFirstFrameAvailable()`, `onCameraClosed()`; `VideoCapturer.initialize(SurfaceTextureHelper, Context, CapturerObserver)`, `startCapture(w,h,fps)`, `stopCapture()` (throws InterruptedException), `changeCaptureFormat(w,h,fps)`, `dispose()`; `SurfaceTextureHelper.create(String, EglBase.Context)`; `PeerConnectionFactory.createVideoSource(boolean isScreencast)`, `createVideoTrack(String, VideoSource)`; `VideoSource.getCapturerObserver()`, `adaptOutputFormat(int,int,int)` (uses max/min of w,h → both orientations); `VideoTrack.addSink/removeSink(VideoSink)`; `PeerConnection.addTransceiver(MediaStreamTrack.MediaType, RtpTransceiver.RtpTransceiverInit)`, `getTransceivers()`, `getStats(RTCStatsCollectorCallback)`; `RtpTransceiverInit(RtpTransceiverDirection, List<String> streamIds)`; `RtpTransceiver.getMediaType()`, `getSender()`, `getReceiver()`, `isStopped()`, `getCurrentDirection()` (may be null), `setDirection(dir): boolean`; `RtpSender.setTrack(MediaStreamTrack?, boolean takeOwnership): boolean` (**two arguments**; null allowed), `getParameters()`, `setParameters(RtpParameters): boolean`; `RtpParameters.encodings: List<Encoding>`, `Encoding.maxBitrateBps: Integer`, `maxFramerate: Integer`, `scaleResolutionDownBy: Double`, `active`; `DefaultVideoEncoderFactory(EglBase.Context, boolean enableIntelVp8Encoder, boolean enableH264HighProfile)`, `DefaultVideoDecoderFactory(EglBase.Context)`; `PeerConnectionFactory.Builder.setVideoEncoderFactory/setVideoDecoderFactory`; `EglBase.create()`, `getEglBaseContext()`, `release()`; `SurfaceViewRenderer(Context)`: `init(EglBase.Context, RendererCommon.RendererEvents)`, `setMirror`, `setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FILL)`, `setEnableHardwareScaler`, `release()` (+ `SurfaceView.setZOrderMediaOverlay`); `FileVideoCapturer(String path)` reads **Y4M** (`C420`/`C420mpeg2`, even sizes) and ticks with a `java.util.Timer`; `PeerConnection.Observer.onTrack(RtpTransceiver)` is a default method. **No `TextureViewRenderer`** in this AAR → `SurfaceViewRenderer` only. Kotlin: setters returning `boolean` are called as methods (`setDirection(...)`, `setParameters(...)`), not as properties. | `unzip` + `javap -public` on the AAR |
| Stats | `RTCStatsReport.getStatsMap(): Map<String, RTCStats>`; `RTCStats(long timestampUs, String type, String id, Map<String,Object> members)` — plain Java, **constructible in JVM tests**. Member names present in the native lib: `availableOutgoingBitrate` (Double, bit/s, on the selected `candidate-pair`), `selectedCandidatePairId` (`transport`), `kind`, `bytesSent`, `bytesReceived`, `framesDecoded`, `framesEncoded`, `framesSent`, `frameWidth`, `frameHeight`, `packetsSent`, `nominated`. uint64 members arrive as **`java.math.BigInteger`** (the lib references it), so numbers are read with `(v as? Number)?.toLong()`. `bytesSent` excludes headers and padding (W3C), so "no video RTP after `setTrack(null)`" is checked with the sent-bytes delta. | `javap`, `strings` on `libjingle_peerconnection_so.so` |
| Old app answering a video offer | Per JSEP (RFC 8829 §5.10) a remote offer's m-section is matched only to a transceiver **created by `addTrack`**; otherwise a new transceiver is created **`recvonly`**. The M8 engine adds audio with `addTrack` and has no video, so a 0.11 app answers our video section `recvonly` (or rejects it), **not "inactive"** as the spec says. Consequences: (a) the answerer must not pre-create the video transceiver — it takes the one `setRemoteDescription` created and sets it `SEND_RECV`; (b) "peer supports video" = `videoTransceiver.currentDirection == SEND_RECV` after the exchange (false for `SEND_ONLY`, `INACTIVE`, `STOPPED`, null). Task 11 proves both directions on the emulator. | RFC 8829 §5.10; `WebRtcEngine.kt:429-434` |
| Bandwidth estimate while paused | GoogCC does not raise its estimate much above ~1.5 × the rate actually sent while the sender is application-limited, so with only Opus flowing (~30 kbit/s) `availableOutgoingBitrate` cannot climb to 400 kbit/s; adding a video track (higher allocation) triggers probing. → While paused, the resume measurement needs **short video test bursts** (Task 6, D126; owner question 1). | libwebrtc AimdRateControl / ProbeController behaviour |
| Android APIs | `ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA` API 30; permission `FOREGROUND_SERVICE_CAMERA` API 34; `PictureInPictureParams.Builder.setActions(List<RemoteAction>)`, `setAspectRatio(Rational)` API 26, `setAutoEnterEnabled` API 31; `Activity.enterPictureInPictureMode(PictureInPictureParams)` API 26 (= minSdk); `RemoteAction(Icon, CharSequence, CharSequence, PendingIntent)`; activity 1.11.0 `ComponentActivity.addOnPictureInPictureModeChangedListener(Consumer<PictureInPictureModeChangedInfo>)` and `addOnUserLeaveHintListener(Runnable)`. `CAMERA` is already declared (feature:conversation manifest; `SmokeTest.cameraFileProviderAndPermissionDeclared`). | `android-36/data/api-versions.xml`, `javap` on android.jar and activity-1.11.0.aar |
| Icons | `material-icons-extended` 1.7.8 has `Icons.Filled.Videocam`, `VideocamOff`, `Cameraswitch`, `DataSaverOn`, `DataSaverOff`. | `unzip -l` on the AAR |
| Settings place | Settings are a key-value table (`Settings.kt`, `SettingEntity`) → a new key needs no Room change. The call rows live in `CallSettingsRows` inside the **«Подключение»** section (`SettingsScreen.kt:118,135`); there is **no «Звонки» section**, and M9 D124 keeps them in «Подключение». The saver switch goes right under «Звонки только через сервер» in `CallSettingsRows`. | `Settings.kt:104-107,124`, `SettingsScreen.kt`, M9 plan D124 |
| Server rate | `defInt(&t.RelayKbps, 200)` (`config.go:196`), asserted in `turn_test.go:21`; `relayGen.wrap` builds one `limitedConn` per allocation with a token bucket per direction (`relay.go:54-56`); `turn.AllocateListenerConfig.UserID` is the TURN user id (pion `allocation_manager.go:25-40`); pion's `Allocation.Close` closes the relay `PacketConn` (`allocation.go:330`) → `limitedConn.Close` is the per-allocation end hook. The "turn on" log line is `server.go:287`. `turn-setup.sh` and `templates/node.toml.turn` write **no** `relay_kbps`, so nodes take the default. | server code, pion v5.1.3 source |
| Throttling an emulator | Emulator console `network speed <up>:<down>` (kbit/s), e.g. `adb -s emulator-5554 emu network speed 200:200`, back with `network speed full`. | Android emulator console |

## File map

**otter-server**
| File | Responsibility |
|---|---|
| `proto/otter/v1/content.proto` | `CallMessage.media = 6`, `CallMedia` |
| `internal/proto/otterv1/*.pb.go` (generated), `internal/proto/otterv1/call_media_test.go` (new) | round trip |
| `internal/config/config.go`, `internal/config/turn_test.go` | `relay_kbps` default 2000 |
| `internal/turnsrv/relay.go`, `relay_test.go`, `server.go`, `server_test.go` | per-allocation meters + `turn allocation closed` line; rate in the `turn on` line |
| `internal/meshsim/harness_test.go`, `internal/meshsim/turn_test.go` | the log line through a real relay |
| `deploy/turn-kbps.sh` (new), `deploy/test/scripts_test.sh`, `deploy/README.md` | set `relay_kbps` on one node with check and rollback |
| `README.md`, `docs/m10-manual-test.md` (new) | docs |

**otter-android**
| File | Responsibility |
|---|---|
| `core/proto/src/main/proto/otter/v1/content.proto` | synced |
| `core/data/.../calls/CallModels.kt` | `VideoProfile`, `MediaStats`, `VideoState`, `RemoteMedia`, new events/effects |
| `core/data/.../calls/MediaEngine.kt` | camera, pause, switch, saver, stats, peerVideo; `onRemoteVideo`, `onCameraError` |
| `core/data/.../calls/VideoWatchdog.kt` (new) | pause/burst/resume rules |
| `core/data/.../calls/CallStateMachine.kt` | video rules, "only a tap starts the camera" |
| `core/data/.../calls/CallManager.kt`, `CallSignaling.kt` | engine calls, `CallMedia` send/receive (non-urgent), sampling, `video` flow |
| `core/data/.../settings/Settings.kt` | `videoSaver` |
| `feature/calls/.../VideoSinks.kt` (new), `StatsParse.kt` (new), `WebRtcEngine.kt` | WebRTC video |
| `feature/calls/.../CallViewModel.kt`, `CallScreen.kt`, `VideoView.kt` (new), `CallAudio.kt`, `res/values*/strings.xml` | call screen |
| `feature/calls/build.gradle.kts`, `src/androidTest/...` (new) | instrumented loopback test |
| `feature/settings/.../SettingsScreen.kt`, `res/values*/strings.xml` | «Экономить трафик в видеозвонках» |
| `app/.../calls/CallActivity.kt`, `CallService.kt`, `CallModule.kt`, `app/src/main/AndroidManifest.xml`, `app/src/main/res/drawable/ic_pip_hang_up.xml` (new) | permission, visibility, FGS camera type, PiP |
| `app/build.gradle.kts` | 0.12.0 / 16 |
| `docs/m10-manual-test.md` (new), `README.md` | docs |

**docs**: `00-decisions.md` (D125–D129), `02-protocol.md`, `05-transport.md`, `06-node-architecture.md`,
`07-android-architecture.md`, `08-operations.md`, `09-roadmap.md` (M10 row + "## M10 notes"), `README.md`.

## Task list

| # | Task | Repo |
|---|---|---|
| 1 | Branches, `CallMedia` proto (field 6), protocol doc | server, android, docs |
| 2 | Node: `relay_kbps` default 2000, rate in the `turn on` line | server |
| 3 | Node: one bit-rate log line per closed allocation (+ meshsim) | server |
| 4 | Deploy: `turn-kbps.sh` sets `relay_kbps` on a node with check and rollback | server |
| 5 | Android: video model, `MediaEngine` additions, `FakeEngine` | android |
| 6 | Android: `VideoWatchdog` (pause, test bursts, resume, no flapping) | android |
| 7 | Android: `CallStateMachine` video rules; only a tap starts the camera | android |
| 8 | Android: `CallManager` video, `CallMedia` send/receive (non-urgent), sampling | android |
| 9 | Android: «Экономить трафик в видеозвонках» setting and switch | android |
| 10 | Android: `WebRtcEngine` video (transceiver, `setTrack`, camera, caps, saver, switch, stats, EGL) | android |
| 11 | Android: instrumented loopback smoke test | android |
| 12 | Android: call screen (renderers, local tile, buttons, notices, speaker default) | android |
| 13 | Android: camera permission, screen-off/background/lock pause, `camera` FGS type | android |
| 14 | Android: picture-in-picture | android |
| 15 | Android: privacy guard tests (entry points, notifications) | android |
| 16 | Versions 0.12.0, emulator acceptance, manual checklists | server, android |
| 17 | Docs: D125–D129, protocol/architecture/operations, roadmap, news draft | docs, server |
| 18 | Final verification; merge after the owner says so | all |
| 19 | Owner rollout: 0.12.0 on every node, `relay_kbps = 2000`, then the APK | owner |

---
### Task 1: Branches, `CallMedia` proto (field 6), protocol doc

**Goal:** The camera-state message exists on the wire in both repos and is documented.

**Files:**
- Modify: `otter-server/proto/otter/v1/content.proto` (`CallMessage`, new `CallMedia`)
- Generated: `otter-server/internal/proto/otterv1/content.pb.go` (`make gen`)
- Create: `otter-server/internal/proto/otterv1/call_media_test.go`
- Sync: `otter-android/core/proto/src/main/proto/otter/v1/content.proto` (`scripts/sync-proto.sh`)
- Create: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/calls/CallMediaProtoTest.kt`
- Modify: `docs/02-protocol.md` (§Content, call signaling paragraph)

**Acceptance Criteria:**
- [ ] Branch `m10-video` exists in `otter-server`, `otter-android`, `docs` (from `main` after all of M9).
- [ ] `CallMessage.media` has field number 6 and round-trips `camera_on` and `paused` in Go and Kotlin; `buf lint` passes.
- [ ] `diff otter-server/proto/otter/v1/content.proto otter-android/core/proto/src/main/proto/otter/v1/content.proto` prints nothing.
- [ ] `docs/02-protocol.md` describes `CallMedia` (non-urgent, 2-min expiry, old apps ignore it).

**Verify:** `cd otter-server && make gen && go test ./internal/proto/... -count=1` → `ok`;
`cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*CallMediaProtoTest'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Branches** (only after the owner confirms M9.5 is merged everywhere)

```bash
cd ~/Documents/Projects/OttterMSG
for r in otter-server otter-android docs; do git -C $r checkout main && git -C $r pull --ff-only && git -C $r checkout -b m10-video; done
grep -n 'oneof kind' -A8 otter-server/proto/otter/v1/content.proto   # field 6 must still be free; else use the next free number everywhere below and say so in D125
```

- [ ] **Step 2: Failing Go test** `otter-server/internal/proto/otterv1/call_media_test.go`

```go
package otterv1

import (
	"bytes"
	"testing"

	"google.golang.org/protobuf/proto"
)

func TestCallMediaRoundTrip(t *testing.T) {
	id := bytes.Repeat([]byte{9}, 16)
	in := &CallMessage{CallId: id, Kind: &CallMessage_Media{Media: &CallMedia{CameraOn: true, Paused: true}}}
	raw, err := proto.Marshal(in)
	if err != nil {
		t.Fatal(err)
	}
	var out CallMessage
	if err := proto.Unmarshal(raw, &out); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(out.GetCallId(), id) || !out.GetMedia().GetCameraOn() || !out.GetMedia().GetPaused() {
		t.Fatalf("round trip lost data: %v", &out)
	}
	if n := (&CallMessage{}).ProtoReflect().Descriptor().Fields().ByName("media").Number(); n != 6 {
		t.Fatalf("CallMessage.media must be field 6, is %d", n)
	}
}
```

- [ ] **Step 3: Run — fails:** `go test ./internal/proto/...` → `undefined: CallMessage_Media`.

- [ ] **Step 4: Edit `content.proto`.** In `message CallMessage`'s `oneof kind` add after `CallHangup hangup = 5;`:

```proto
    CallMedia media = 6;          // M10, D125: the sender's camera state
```

  and after `message CallHangup { … }` add:

```proto
// The sender's camera state (M10, D125). Sent whenever it changes, NOT urgent (it must not use the call-wake
// budget), same 2-minute record expiry as the other call messages. Apps before 0.12.0 ignore it.
message CallMedia {
  bool camera_on = 1; // video from this side is (about to be) shown; false also while the sender's screen is off
  bool paused = 2;    // camera on, sending stopped by the weak-link watchdog: show «Видео приостановлено: слабая связь»
}
```

- [ ] **Step 5: Generate and test:** `make gen && go test ./internal/proto/... -count=1` → `ok`.

- [ ] **Step 6: Commit (server)**

```bash
git add proto/otter/v1/content.proto internal/proto/otterv1/
oc -m "proto: CallMessage.media (CallMedia camera_on/paused) for video calls (M10, D125)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 7: Sync and failing Kotlin test.**
  `cd ~/Documents/Projects/OttterMSG/otter-android && scripts/sync-proto.sh && diff ../otter-server/proto/otter/v1/content.proto core/proto/src/main/proto/otter/v1/content.proto`
  (no output). Create `core/data/src/test/kotlin/app/ottermsg/core/data/calls/CallMediaProtoTest.kt`:

```kotlin
package app.ottermsg.core.data.calls

import app.ottermsg.proto.v1.CallMedia
import app.ottermsg.proto.v1.CallMessage
import com.google.protobuf.ByteString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CallMediaProtoTest {
    @Test fun mediaIsField6AndRoundTrips() {
        assertEquals(6, CallMessage.MEDIA_FIELD_NUMBER)
        val m = CallMessage.newBuilder().setCallId(ByteString.copyFrom(ByteArray(16) { 7 }))
            .setMedia(CallMedia.newBuilder().setCameraOn(true).setPaused(false)).build()
        val back = CallMessage.parseFrom(m.toByteArray())
        assertEquals(CallMessage.KindCase.MEDIA, back.kindCase)
        assertTrue(back.media.cameraOn)
        assertFalse(back.media.paused)
    }
}
```

  Run `./gradlew :core:data:testDebugUnitTest --tests '*CallMediaProtoTest'`. If the sync ran first it already passes;
  run it once **before** `sync-proto.sh` to see `Unresolved reference: CallMedia`, then after it to see PASS.

- [ ] **Step 8: Commit (android)**

```bash
git add core/proto/src/main/proto/otter/v1/content.proto core/data/src/test/kotlin/app/ottermsg/core/data/calls/CallMediaProtoTest.kt
oc -m "proto: sync CallMedia (M10)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 9: Protocol doc.** In `docs/02-protocol.md` add `CallMedia media = 6` to the `CallMessage` block and this
  paragraph after "**Call signaling (M8, D78).**":

```markdown
**Camera state (M10, D125).** `CallMessage.media = 6` → `CallMedia{camera_on, paused}`, sent by each phone whenever its
camera state changes: tap on/off, the weak-link pause (`paused = true`) and its end, the call screen hidden
(`camera_on = false`) and shown again. Same Signal-encrypted 1:1 envelope and 2-minute record expiry as the other call
messages but **not urgent** (it must not use the per-sender call-wake budget, M9 Task 46; the peer is connected
because of the call). Every call negotiates one audio and one video transceiver; video starts and stops without a
new offer. Apps before 0.12.0 ignore `media` (unknown oneof case). An offer without a video section, or an answer whose
video section is not `sendrecv`, means "the peer cannot do video".
```

  Commit in `docs`: `oc -m "02-protocol: CallMedia (M10)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`.

---

### Task 2: Node — `relay_kbps` default 2000, rate in the `turn on` line

**Goal:** A node started without an explicit `relay_kbps` relays up to 2000 kbit/s per allocation and direction, and
its log says which rate it runs with.

**Files:**
- Modify: `otter-server/internal/config/config.go:196`, `otter-server/internal/turnsrv/server.go:287-288`
- Test: `otter-server/internal/config/turn_test.go:21`, `otter-server/internal/turnsrv/server_test.go`
- Modify: `otter-server/README.md:102`

**Acceptance Criteria:**
- [ ] `[turn]` without `relay_kbps` → `Turn.RelayKbps == 2000`; an explicit `relay_kbps = 200` still loads as 200.
- [ ] The `turn on` JSON log line contains `"relay_kbps":<value>`.

**Verify:** `cd otter-server && go test ./internal/config/ ./internal/turnsrv/ -count=1 -race` → `ok`

**Steps:**

- [ ] **Step 1: Failing tests.** In `internal/config/turn_test.go` change `tc.RelayKbps != 200` to `tc.RelayKbps != 2000`
  and append:

```go
func TestTurnExplicitRelayKbpsWins(t *testing.T) {
	c, err := Load(write(t, withTLS+"[turn]\nenabled = true\nrelay_ip = \"203.0.113.7\"\nrelay_kbps = 200\n"))
	if err != nil {
		t.Fatal(err)
	}
	if c.Turn.RelayKbps != 200 {
		t.Fatalf("explicit relay_kbps lost: %d", c.Turn.RelayKbps)
	}
}
```

  Append to `internal/turnsrv/server_test.go`:

```go
func TestTurnOnLogShowsTheRelayRate(t *testing.T) {
	var buf syncBuf
	cfg := testConfig(bytes.Repeat([]byte{5}, SecretLen), 4, 41, netlog.Nop{})
	cfg.Log = slog.New(slog.NewJSONHandler(&buf, nil))
	startCfg(t, cfg)
	if s := buf.String(); !strings.Contains(s, `"msg":"turn on"`) || !strings.Contains(s, `"relay_kbps":2000`) {
		t.Fatalf("turn on line without the rate: %s", s)
	}
}
```

- [ ] **Step 2: Run — fails** (`defaults: … RelayKbps:200`; `turn on line without the rate`).

- [ ] **Step 3: Implement.** `config.go:196`:

```go
	defInt(&t.RelayKbps, 2000) // 720p video + Opus + overhead, per allocation and direction (M10, D129); M8 had 200
```

  `server.go` "turn on" line:

```go
	cfg.Log.Info("turn on", "udp", cfg.UDPListen, "tcp", cfg.TCPListen, "tls", cfg.TLSListen,
		"relay", cfg.RelayIP.String(), "ports", fmt.Sprintf("%d-%d", cfg.PortMin, cfg.PortMax), "relay_kbps", cfg.RelayKbps)
```

  `README.md:102`: "200 kbit/s per allocation (`relay_kbps`)" → "2000 kbit/s per allocation and direction
  (`relay_kbps`; 200 before 0.12.0)".

- [ ] **Step 4: Run** the Verify command → `ok`; `go vet ./...` → no output.

- [ ] **Step 5: Commit**

```bash
git add internal/config/config.go internal/config/turn_test.go internal/turnsrv/server.go internal/turnsrv/server_test.go README.md
oc -m "turn: relay_kbps default 2000 for video; the turn on line shows the rate (M10, D129)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Node — one bit-rate log line per closed allocation (+ meshsim)

**Goal:** When an allocation ends the node logs `turn allocation closed` with the TURN user id, duration, average and
peak kbit/s in each direction and whether the rate limiter dropped packets — no user names, no addresses.

**Files:**
- Modify: `otter-server/internal/turnsrv/relay.go` (`relayGen.log`, `wrap(pc, user)`, `limitedConn` meters, `Close`)
- Modify: `otter-server/internal/turnsrv/server.go:178-183` (`gen` gets `log: cfg.Log`)
- Test: `otter-server/internal/turnsrv/relay_test.go`, `otter-server/internal/meshsim/harness_test.go`, `otter-server/internal/meshsim/turn_test.go`

**Acceptance Criteria:**
- [ ] One line per allocation, written once (a second `Close` writes nothing), with fields `user`, `duration_s`,
  `to_peer_avg_kbps`, `to_peer_peak_kbps`, `to_peer_dropped`, `from_peer_avg_kbps`, `from_peer_peak_kbps`,
  `from_peer_dropped`, `rate_limited`.
- [ ] Peak = busiest one-second window; drops counted are rate-limiter drops only (not own-address blocks).
- [ ] meshsim: after two phones relay through one node and one allocation closes, the node log has the line, and it
  contains neither user names nor IP addresses.

**Verify:** `cd otter-server && go test ./internal/turnsrv/ -count=1 -race && go test ./internal/meshsim/ -run 'Turn|CallRelay' -count=1 -race` → `ok`

**Steps:**

- [ ] **Step 1: Failing unit test.** In `internal/turnsrv/relay_test.go`: add `"log/slog"` and `"strings"` to the imports,
  give `fakePC` a `Close` (it embeds a nil `net.PacketConn`):

```go
func (f *fakePC) Close() error { return nil }
```

  change the two existing `g.wrap(f)` / `testGen(st, clk).wrap(f)` calls to `wrap(f, "t")`, and append:

```go
func TestAllocationClosedLogLine(t *testing.T) {
	clk := &clock{t: time.Unix(1000, 0)}
	var buf syncBuf
	g := testGen(&Stats{}, clk) // 1000 B/s per direction
	g.log = slog.New(slog.NewJSONHandler(&buf, nil))
	f := &fakePC{reads: make(chan []byte, 4)}
	c := g.wrap(f, "0123456789abcdef")
	peer := &net.UDPAddr{IP: net.IPv4(8, 8, 8, 8), Port: 9}
	c.WriteTo(make([]byte, 600), peer) // second 0: 600 B to the peer
	c.WriteTo(make([]byte, 600), peer) // over the cap: dropped by the rate limiter
	c.WriteTo(make([]byte, 50), &net.UDPAddr{IP: net.IPv4(203, 0, 113, 7), Port: 22}) // own address: blocked, not a rate drop
	clk.add(time.Second)
	c.WriteTo(make([]byte, 400), peer) // second 1
	f.reads <- make([]byte, 250)
	if _, _, err := c.ReadFrom(make([]byte, 2000)); err != nil { // 250 B from the peer
		t.Fatal(err)
	}
	clk.add(3 * time.Second)
	c.Close()
	c.Close() // logged once
	out := buf.String()
	if strings.Count(out, `"msg":"turn allocation closed"`) != 1 {
		t.Fatalf("want one line: %s", out)
	}
	for _, want := range []string{`"user":"0123456789abcdef"`, `"duration_s":4`, `"to_peer_avg_kbps":2`, `"to_peer_peak_kbps":5`,
		`"to_peer_dropped":1`, `"from_peer_avg_kbps":1`, `"from_peer_peak_kbps":2`, `"from_peer_dropped":0`, `"rate_limited":true`} {
		if !strings.Contains(out, want) {
			t.Fatalf("missing %s in %s", want, out)
		}
	}
	if strings.Contains(out, "8.8.8.8") || strings.Contains(out, "203.0.113.7") {
		t.Fatalf("addresses in the log: %s", out)
	}
}
```

  (`syncBuf` is defined in `server_test.go`, same package.) Arithmetic: to the peer 1000 B in 4 s → 2 kbit/s average,
  busiest second 600 B → 4.8 → 5; from the peer 250 B → 0.5 → 1 average, 2 peak (`math.Round`).

- [ ] **Step 2: Run — fails:** `too many arguments in call to g.wrap`, `g.log undefined`.

- [ ] **Step 3: Implement `relay.go`.** Add `"log/slog"` to imports; add a `log *slog.Logger` field to `relayGen`
  (comment: `// "turn allocation closed" lines; nil = none`); replace `AllocatePacketConn`'s return with
  `return g.wrap(pc, c.UserID), addr, nil`; replace `wrap`, `limitedConn`, `WriteTo`, `ReadFrom` with:

```go
func (g *relayGen) clock() time.Time {
	if g.now == nil {
		return time.Now()
	}
	return g.now()
}

// wrap adds the rate cap, the own-port filter and the per-allocation meters; user is the TURN user id (hash tag).
func (g *relayGen) wrap(pc net.PacketConn, user string) net.PacketConn {
	return &limitedConn{PacketConn: pc, g: g, user: user, start: g.clock(),
		in: newBucket(g.bytesPerSec, g.bytesPerSec, g.now), out: newBucket(g.bytesPerSec, g.bytesPerSec, g.now)}
}

type limitedConn struct {
	net.PacketConn
	g        *relayGen
	in, out  *bucket
	user     string
	start    time.Time
	toPeer   meter // phone → relay → peer (WriteTo)
	fromPeer meter // peer → relay → phone (ReadFrom)
	once     sync.Once
}

func (c *limitedConn) WriteTo(p []byte, addr net.Addr) (int, error) {
	if c.g.blocked(addr) {
		c.g.stats.Dropped.Add(1)
		return len(p), nil // UDP: a dropped packet is not an error
	}
	if !c.out.take(len(p)) {
		c.g.stats.Dropped.Add(1)
		c.toPeer.drop()
		return len(p), nil
	}
	c.g.stats.Relayed.Add(int64(len(p)))
	c.toPeer.add(len(p), c.g.clock())
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
			c.fromPeer.add(n, c.g.clock())
			return n, addr, nil
		}
		c.g.stats.Dropped.Add(1)
		c.fromPeer.drop()
	}
}

// Close ends the allocation (pion closes the relay socket when the allocation goes) and logs its bit rates once.
func (c *limitedConn) Close() error {
	c.once.Do(c.logClosed)
	return c.PacketConn.Close()
}

// logClosed: no names, no addresses — the TURN user id is a hash tag, as in the M8 logs (D129).
func (c *limitedConn) logClosed() {
	if c.g.log == nil {
		return
	}
	d := c.g.clock().Sub(c.start)
	secs := math.Max(d.Seconds(), 1)
	to, from := c.toPeer.snapshot(), c.fromPeer.snapshot()
	c.g.log.Info("turn allocation closed", "user", c.user, "duration_s", int64(d.Seconds()),
		"to_peer_avg_kbps", kbps(to.total, secs), "to_peer_peak_kbps", kbps(to.peak, 1), "to_peer_dropped", to.dropped,
		"from_peer_avg_kbps", kbps(from.total, secs), "from_peer_peak_kbps", kbps(from.peak, 1), "from_peer_dropped", from.dropped,
		"rate_limited", to.dropped+from.dropped > 0)
}

// meter counts one direction's relayed bytes, its busiest one-second window and its rate-limiter drops.
type meter struct {
	mu                        sync.Mutex
	total, win, peak, dropped int64
	winStart                  time.Time
}

func (m *meter) add(n int, now time.Time) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.winStart.IsZero() || now.Sub(m.winStart) >= time.Second {
		m.peak = max(m.peak, m.win)
		m.win, m.winStart = 0, now
	}
	m.win += int64(n)
	m.total += int64(n)
}

func (m *meter) drop() { m.mu.Lock(); m.dropped++; m.mu.Unlock() }

type meterSnap struct{ total, peak, dropped int64 }

func (m *meter) snapshot() meterSnap {
	m.mu.Lock()
	defer m.mu.Unlock()
	return meterSnap{m.total, max(m.peak, m.win), m.dropped}
}

func kbps(bytes int64, secs float64) int64 { return int64(math.Round(float64(bytes) * 8 / 1000 / secs)) }
```

  In `server.go`'s `gen := &relayGen{…}` add `log: cfg.Log,`.

- [ ] **Step 4: Run** `go test ./internal/turnsrv/ -count=1 -race` → `ok`.

- [ ] **Step 5: Failing meshsim test.** In `internal/meshsim/harness_test.go` add to `simNode` (after `turnKey`):

```go
	turnLog syncLog // the node's TURN log lines (JSON), for the bit-rate line (turn_test.go)
```

  add the type (with `"bytes"` imported if it is not yet):

```go
// syncLog collects log output written from pion's goroutines.
type syncLog struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *syncLog) Write(p []byte) (int, error) { l.mu.Lock(); defer l.mu.Unlock(); return l.b.Write(p) }
func (l *syncLog) String() string              { l.mu.Lock(); defer l.mu.Unlock(); return l.b.String() }
```

  and in `startTurn` replace `Log: quiet` in the `turnsrv.Config{…}` with `Log: slog.New(slog.NewJSONHandler(&n.turnLog, nil))`.
  Append to `internal/meshsim/turn_test.go` (imports `"strings"`):

```go
func TestRelayLogsBitRatesWhenAnAllocationCloses(t *testing.T) {
	s := newSimWith(t, map[string]nodeOpts{"a": {turn: true}}, "a")
	a := s.node("a")
	anna, boris := s.register(a, "anna"), s.register(a, "boris")
	ca, cb := s.login(a, anna), s.login(a, boris)
	defer ca.close()
	defer cb.close()
	ra, err := turnClient(t, "udp", a.turnAddr, creds(t, ca))
	if err != nil {
		t.Fatal(err)
	}
	rb, err := turnClient(t, "udp", a.turnAddr, creds(t, cb))
	if err != nil {
		t.Fatal(err)
	}
	exchange(t, ra, rb)
	ra.Close() // refresh with lifetime 0: the node deletes the allocation
	var line string
	eventually(t, "turn allocation closed line", func() bool {
		for _, l := range strings.Split(a.turnLog.String(), "\n") {
			if strings.Contains(l, `"msg":"turn allocation closed"`) {
				line = l
				return true
			}
		}
		return false
	})
	for _, want := range []string{`"user":"`, `"duration_s":`, `"to_peer_avg_kbps":`, `"to_peer_peak_kbps":`,
		`"from_peer_avg_kbps":`, `"from_peer_peak_kbps":`, `"rate_limited":false`} {
		if !strings.Contains(line, want) {
			t.Fatalf("missing %s in %s", want, line)
		}
	}
	if strings.Contains(line, "anna") || strings.Contains(line, "boris") || strings.Contains(line, "127.0.0.1") {
		t.Fatalf("names or addresses in the log: %s", line)
	}
}
```

- [ ] **Step 6: Run** the Verify command → `ok` (run the meshsim part `-count=3` once to rule out flakiness).

- [ ] **Step 7: Commit**

```bash
git add internal/turnsrv/relay.go internal/turnsrv/relay_test.go internal/turnsrv/server.go internal/meshsim/harness_test.go internal/meshsim/turn_test.go
oc -m "turn: one 'turn allocation closed' line per allocation with avg/peak kbit/s per direction (M10, D129)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Deploy — `turn-kbps.sh` sets `relay_kbps` on a node with check and rollback

**Goal:** The owner can set (and undo) `[turn] relay_kbps` on one node with one command that validates the new
config, restarts, confirms the new rate in the node's own log and restores the old file on any failure.

**Files:**
- Create: `otter-server/deploy/turn-kbps.sh` (mode 0755)
- Modify: `otter-server/deploy/test/scripts_test.sh` (new section before the final `echo "scripts test: ok"`)
- Modify: `otter-server/deploy/README.md` (one paragraph under the TURN section)

**Acceptance Criteria:**
- [ ] `turn-kbps.sh LABEL KBPS` refuses: missing/extra arguments, a non-number, a node without an SSH target, a node
  below 0.12.0 (message `install 0.12.0 first`), a node without `[turn]` (hint `turn-setup.sh LABEL`).
- [ ] Remote part: exactly one `relay_kbps = KBPS` line, directly under `[turn]`, other lines and sections kept;
  `otter-node check` runs on the new file before anything changes; old file kept as `node.toml.pre-kbps`; after the
  restart the health check passes **and** the `turn on` journal line shows `"relay_kbps":KBPS`, else the old file is
  restored and the node restarted again.
- [ ] A refused check leaves `node.toml` untouched and does not restart.

**Verify:** `T=$(mktemp -d); git ls-files -z | xargs -0 tar -c | tar -x -C "$T"; cp deploy/turn-kbps.sh "$T/deploy/"; (cd "$T" && bash deploy/test/scripts_test.sh)` → `scripts test: ok`

**Steps:**

- [ ] **Step 1: Failing tests.** Insert before the final `echo "scripts test: ok"` of `deploy/test/scripts_test.sh`
  (it reuses `$work`, `$fake` and the fake tools of the `turn-setup.sh` section above it; if M9 moved that section,
  keep this block after it):

```bash
# --- turn-kbps.sh (M10, D129): stubbed ssh; the probe answers "$VER / $HAS"; the remote script's stdin is saved
if out=$(deploy/turn-kbps.sh 2>&1); then fail "turn-kbps without arguments"; fi
grep -q 'usage: turn-kbps.sh LABEL KBPS' <<< "$out" || fail "turn-kbps usage: $out"
if deploy/turn-kbps.sh n1 fast >/dev/null 2>&1; then fail "turn-kbps accepted a word"; fi
if deploy/turn-kbps.sh n1 2000 extra >/dev/null 2>&1; then fail "turn-kbps accepted an extra argument"; fi
if out=$(deploy/turn-kbps.sh n2 2000 2>&1); then fail "turn-kbps without a host"; fi
grep -q 'hosts.sh set n2' <<< "$out" || fail "turn-kbps host message: $out"
cat > "$work/stub/ssh" <<STUB
#!/bin/sh
echo "ssh \$*" >> "$work/ssh.log"
case "\$*" in
  *"bash -s"*) cat > "$work/kbps-remote.sh"; [ -z "\$REMOTE_FAIL" ] || exit 1; echo "relay_kbps is 2000" ;;
  *"otter-node version"*) printf '%s\n%s\n' "\${VER:-0.12.0}" "\${HAS:-turn}" ;;
esac
STUB
chmod +x "$work/stub/ssh"
kbps() { rm -f "$work/ssh.log" "$work/kbps-remote.sh"; touch "$work/ssh.log"; PATH="$work/stub:$PATH" deploy/turn-kbps.sh "$@" < /dev/null 2>&1; }
out=$(kbps n1 2000) || fail "turn-kbps: $out"
grep -q '^ssh -p 22 .*root@n1.example bash -s -- 2000$' "$work/ssh.log" || fail "turn-kbps remote call: $(cat "$work/ssh.log")"
grep -q 'n1: TURN relay_kbps = 2000' <<< "$out" || fail "turn-kbps summary: $out"
for v in 0.11.0 dev-abc123; do
  if out=$(VER=$v kbps n1 2000); then fail "turn-kbps accepted $v"; fi
  grep -q 'install 0.12.0 first' <<< "$out" || fail "turn-kbps old-version message: $out"
  if grep -q 'bash -s' "$work/ssh.log"; then fail "turn-kbps changed a $v node"; fi
done
if out=$(HAS=no-turn kbps n1 2000); then fail "turn-kbps without [turn]"; fi
grep -q 'turn-setup.sh n1' <<< "$out" || fail "turn-kbps no-turn hint: $out"
if out=$(REMOTE_FAIL=1 kbps n1 2000); then fail "turn-kbps ignored a remote failure"; fi
grep -q 'previous config' <<< "$out" || fail "turn-kbps failure message: $out"
# the remote script itself against the fake /etc/otter
r="$work/kbps-remote.sh"; kbps n1 2000 >/dev/null
bash -n "$r" || fail "turn-kbps remote script syntax"
sed -e "s#/etc/otter#$fake/etc#g" -e 's#/usr/local/bin/otter-node#otter-node#g' \
  -e 's#/usr/local/lib/otter/health.sh#health.sh#g' "$r" > "$work/kbps-local.sh"
printf '#!/bin/sh\necho "{\\"msg\\":\\"turn on\\",\\"relay_kbps\\":${SEEN:-2000}}"\n' > "$fake/bin/journalctl"
chmod +x "$fake/bin/journalctl"
withturn=$'data_dir = "/var/lib/otter"\n\n[turn]\nenabled = true\nrelay_ip = "192.0.2.1"\nrelay_kbps = 200\n\n[limits]\nmax_blob = "50MiB"'
kremote() { rm -f "$fake/actions.log"; PATH="$fake/bin:$PATH" bash "$work/kbps-local.sh" "$@" 2>&1; }
printf '%s\n' "$withturn" > "$fake/etc/node.toml"
out=$(kremote 2000) || fail "kbps remote: $out"
cfg=$(cat "$fake/etc/node.toml")
[[ "$(grep -c '^relay_kbps' <<< "$cfg")" == 1 ]] && grep -q '^relay_kbps = 2000$' <<< "$cfg" || fail "kbps remote: $cfg"
[[ "$(sed -n '/^\[turn\]/{n;p}' <<< "$cfg")" == "relay_kbps = 2000" ]] || fail "relay_kbps not under [turn]: $cfg"
grep -q '^max_blob = "50MiB"$' <<< "$cfg" && grep -q '^relay_ip = "192.0.2.1"$' <<< "$cfg" || fail "kbps remote lost lines: $cfg"
[[ "$(cat "$fake/etc/node.toml.pre-kbps")" == "$withturn" ]] || fail "node.toml.pre-kbps is not the old config"
[[ ! -e "$fake/etc/node.toml.new" ]] || fail "kbps: node.toml.new left behind"
printf 'data_dir = "/var/lib/otter"\n\n[turn]\nenabled = true\nrelay_ip = "192.0.2.1"\n' > "$fake/etc/node.toml"
out=$(kremote 2000) || fail "kbps remote (no line yet): $out"
grep -q '^relay_kbps = 2000$' "$fake/etc/node.toml" || fail "kbps remote (no line yet): $(cat "$fake/etc/node.toml")"
printf '%s\n' "$withturn" > "$fake/etc/node.toml"
if out=$(SEEN=200 kremote 2000); then fail "kbps remote ignored a node that did not take the rate"; fi
[[ "$(cat "$fake/etc/node.toml")" == "$withturn" ]] || fail "kbps: no rollback: $(cat "$fake/etc/node.toml")"
[[ "$(grep -c '^systemctl restart otter-node$' "$fake/actions.log")" == 2 ]] || fail "kbps rollback restarts: $(cat "$fake/actions.log")"
if out=$(CHECK_FAIL=1 kremote 2000); then fail "kbps remote ignored a failed check"; fi
[[ "$(cat "$fake/etc/node.toml")" == "$withturn" && ! -e "$fake/etc/node.toml.new" ]] || fail "kbps: failed check changed the config"
[[ ! -e "$fake/actions.log" ]] || fail "kbps: failed check restarted: $(cat "$fake/actions.log")"
```

- [ ] **Step 2: Run — fails** (Verify command → `scripts test: FAIL: turn-kbps usage: …No such file…`).

- [ ] **Step 3: Implement `deploy/turn-kbps.sh`** (`chmod 0755`):

```bash
#!/usr/bin/env bash
# Sets the TURN relay rate per allocation and direction ([turn] relay_kbps, M10 D129) on one node running 0.12.0+.
# Usage: turn-kbps.sh LABEL KBPS      M10 rollout: 2000; back to the M8 rate: 200
# node.toml changes only after the new file passed `otter-node check`; if the node does not come back healthy with
# "turn on" and the new rate in its log, the previous file (node.toml.pre-kbps) is restored and the node restarted.
source "$(dirname "$0")/lib.sh"
usage="usage: turn-kbps.sh LABEL KBPS"
(( $# == 2 )) || die "$usage"
label=$1 kbps=$2
[[ -n "$label" && "$label" != --* ]] || die "$usage"
[[ "$kbps" =~ ^[1-9][0-9]{1,5}$ ]] || die "KBPS must be a number from 10 to 999999 (got '$kbps')"
host_lookup "$label" || die "node $label has no SSH target: deploy/hosts.sh set $label root@HOST"
export SSH_PORT=$TARGET_PORT
probe=$(remote "$TARGET" '/usr/local/bin/otter-node version;
  if grep -q "^\[turn\]" /etc/otter/node.toml; then echo turn; else echo no-turn; fi') || die "cannot query $label ($TARGET)"
ver="" has_turn=""
{ read -r ver || true; read -r has_turn || true; } <<< "$probe"
version_ge "$ver" 0.12.0 || die "$label runs otter-node ${ver:-?}; install 0.12.0 first (deploy/upgrade-all.sh 0.12.0 --only $label)"
[[ "$has_turn" == turn ]] || die "$label has no [turn] section; turn the relay on first: deploy/turn-setup.sh $label"
say "setting relay_kbps = $kbps on $label"
remote "$TARGET" bash -s -- "$kbps" <<'REMOTE' || die "relay_kbps not changed on $label (node left on its previous config)"
set -euo pipefail
kbps=$1
cfg=/etc/otter/node.toml
trap 'rm -f /etc/otter/node.toml.new' EXIT
# drop relay_kbps lines inside [turn], write the new one right under the [turn] header
awk -v k="$kbps" '/^\[/{s=($0=="[turn]")} s && /^relay_kbps[ \t]*=/{next} {print} $0=="[turn]"{print "relay_kbps = " k}' \
  "$cfg" > /etc/otter/node.toml.new
chown root:otter /etc/otter/node.toml.new; chmod 0640 /etc/otter/node.toml.new
if ! runuser -u otter -- /usr/local/bin/otter-node check --config /etc/otter/node.toml.new >&2; then
  echo "otter-node check refused the new config" >&2; exit 1
fi
cp -p "$cfg" /etc/otter/node.toml.pre-kbps
mv /etc/otter/node.toml.new "$cfg"
since=$(date '+%Y-%m-%d %H:%M:%S')
systemctl restart otter-node
if ! /usr/local/lib/otter/health.sh >&2 ||
   ! journalctl -u otter-node --since "$since" --no-pager -o cat | grep '"msg":"turn on"' | grep -q "\"relay_kbps\":$kbps[,}]"; then
  echo "TURN did not come back with relay_kbps $kbps; restoring node.toml.pre-kbps" >&2
  mv /etc/otter/node.toml.pre-kbps "$cfg"
  systemctl restart otter-node; /usr/local/lib/otter/health.sh >&2 || true
  exit 1
fi
echo "relay_kbps is $kbps"
REMOTE
say "$label: TURN relay_kbps = $kbps"
```

  (D82 holds: `/etc/otter` is root's directory; the same pattern as `turn-setup.sh`.)

- [ ] **Step 4: Run** the Verify command → `scripts test: ok`. `shellcheck deploy/turn-kbps.sh` if installed.

- [ ] **Step 5: `deploy/README.md`** — add under the TURN paragraph:

```markdown
`deploy/turn-kbps.sh LABEL KBPS` sets `[turn] relay_kbps` on one node (0.12.0+): checks the new file with
`otter-node check`, restarts, confirms `"relay_kbps":KBPS` in the node's `turn on` log line, and restores
`node.toml.pre-kbps` otherwise. Video calls (M10) need 2000; `turn-kbps.sh LABEL 200` goes back to the M8 rate.
Each closed allocation logs `turn allocation closed` with avg/peak kbit/s per direction:
`journalctl -u otter-node -o cat | grep '"turn allocation closed"'`.
```

- [ ] **Step 6: Commit**

```bash
git add deploy/turn-kbps.sh deploy/test/scripts_test.sh deploy/README.md
oc -m "deploy: turn-kbps.sh sets relay_kbps with check, log confirmation and rollback (M10)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 5: Android — video model, `MediaEngine` additions, `FakeEngine`

**Goal:** The JVM-testable types every later task uses exist, and the test fake implements the new engine calls.

**Files:**
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/calls/CallModels.kt`
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/calls/MediaEngine.kt`
- Modify: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/calls/CallManagerTest.kt` (`FakeEngine`)
- Modify (compile only, filled in Tasks 7, 8, 10): `CallStateMachine.kt`, `CallManager.kt`, `feature/calls/.../WebRtcEngine.kt`
- Create: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/calls/VideoModelTest.kt`

**Acceptance Criteria:**
- [ ] `VideoProfile.NORMAL` = 1280×720, 30 fps, 1 500 000 bit/s; `VideoProfile.SAVER` = 640×360, 20 fps, 500 000 bit/s.
- [ ] `VideoState.showRemote` = frames arriving **and** (no `CallMedia` yet, or the last one says on and not paused);
  `weakLink` = own pause or the peer's `paused`; `sending` = camera on, not paused, not hidden.
- [ ] `MediaEngine` has `setCamera`, `setPaused`, `switchCamera`, `setSaver`, `stats`, `peerVideo`; `MediaListener` has
  `onRemoteVideo`, `onCameraError`; `FakeEngine` records them without touching `calls`.
- [ ] `./gradlew :core:data:testDebugUnitTest :feature:calls:compileDebugKotlin` is green (all M8 tests still pass).

**Verify:** `cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*VideoModelTest' --tests '*CallManagerTest' :feature:calls:compileDebugKotlin` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing test** `core/data/src/test/kotlin/app/ottermsg/core/data/calls/VideoModelTest.kt`:

```kotlin
package app.ottermsg.core.data.calls

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoModelTest {
    @Test fun capsMatchTheSpec() {
        assertEquals(VideoProfile(1280, 720, 30, 1_500_000), VideoProfile.of(saver = false))
        assertEquals(VideoProfile(640, 360, 20, 500_000), VideoProfile.of(saver = true))
    }

    @Test fun remoteVideoIsShownFromFramesUntilTheMessageSaysOtherwise() {
        assertFalse(VideoState().showRemote)
        assertTrue("frames before any CallMedia (it may be late)", VideoState(remoteFrames = true).showRemote)
        assertTrue(VideoState(remoteFrames = true, remote = RemoteMedia(cameraOn = true, paused = false)).showRemote)
        assertFalse("camera_on but no frames yet", VideoState(remote = RemoteMedia(true, false)).showRemote)
        assertFalse("off wins over stray frames", VideoState(remoteFrames = true, remote = RemoteMedia(false, false)).showRemote)
        assertFalse("paused wins over test-burst frames", VideoState(remoteFrames = true, remote = RemoteMedia(true, true)).showRemote)
    }

    @Test fun weakLinkAndSending() {
        assertTrue(VideoState(netPaused = true).weakLink)
        assertTrue(VideoState(remote = RemoteMedia(true, true)).weakLink)
        assertFalse(VideoState(remote = RemoteMedia(true, false)).weakLink)
        assertTrue(VideoState(cameraOn = true).sending)
        assertFalse(VideoState(cameraOn = true, netPaused = true).sending)
        assertFalse(VideoState(cameraOn = true, hidden = true).sending)
    }
}
```

- [ ] **Step 2: Run — fails** (`Unresolved reference: VideoProfile`).

- [ ] **Step 3: `CallModels.kt`.** Append after `object CallTimers`:

```kotlin
/** Video caps (D126): set with the RtpSender encoding and the capture format; WebRTC adapts down from there. */
data class VideoProfile(val width: Int, val height: Int, val fps: Int, val maxBitrateBps: Int) {
    companion object {
        val NORMAL = VideoProfile(1280, 720, 30, 1_500_000)
        val SAVER = VideoProfile(640, 360, 20, 500_000)
        fun of(saver: Boolean) = if (saver) SAVER else NORMAL
    }
}

/** One second of measurements from the engine (bit rates are deltas since the previous call). */
data class MediaStats(
    /** Congestion controller's estimate for this connection; null before ICE has a selected pair. */
    val availableOutgoingKbps: Long?,
    val sentVideoKbps: Long, val receivedVideoKbps: Long,
    val sentWidth: Int, val sentHeight: Int, val receivedWidth: Int, val receivedHeight: Int,
)

/** The peer's last CallMedia of this call. */
data class RemoteMedia(val cameraOn: Boolean, val paused: Boolean)

/** Camera and video of the current call (D125–D127). Reset when the call ends (only [hidden] survives). */
data class VideoState(
    /** null until the offer/answer exchange shows it; false: the peer's app is older than 0.12.0. */
    val peerVideo: Boolean? = null,
    val cameraOn: Boolean = false,
    val front: Boolean = true,
    val saver: Boolean = false,
    /** Sending stopped by the weak-link watchdog; the camera and the local preview stay on. */
    val netPaused: Boolean = false,
    /** The call screen is not visible (screen off, background without PiP, lock screen): sending stopped. */
    val hidden: Boolean = false,
    val cameraDenied: Boolean = false,
    val remote: RemoteMedia? = null,
    /** Video frames from the peer are arriving (MediaListener.onRemoteVideo). */
    val remoteFrames: Boolean = false,
) {
    val sending: Boolean get() = cameraOn && !netPaused && !hidden
    /** Frames arrive and the peer's last CallMedia (if any yet — it may be late) says on and not paused. */
    val showRemote: Boolean get() = remoteFrames && (remote?.let { it.cameraOn && !it.paused } ?: true)
    /** «Видео приостановлено: слабая связь» on both screens. */
    val weakLink: Boolean get() = netPaused || remote?.paused == true
}
```

  Append to `sealed interface CallEvent` (before its closing brace):

```kotlin
    /** The local user tapped the camera button. The ONLY event that may start the camera (D127). */
    data class UserCamera(val on: Boolean, override val nowMs: Long) : CallEvent
    data class UserSwitchCamera(override val nowMs: Long) : CallEvent
    /** «Экономить трафик»: the Settings default at call start, or the in-call button. */
    data class SaverChanged(val on: Boolean, override val nowMs: Long) : CallEvent
    data class CameraDenied(override val nowMs: Long) : CallEvent
    /** The open camera failed or Android took it away. */
    data class CameraFailed(override val nowMs: Long) : CallEvent
    data class CameraSwitched(val front: Boolean, override val nowMs: Long) : CallEvent
    /** After the offer/answer exchange: can the peer do video (app 0.12.0+)? */
    data class PeerVideo(val capable: Boolean, override val nowMs: Long) : CallEvent
    /** CallMedia from the peer. */
    data class RemoteCamera(val id: CallId, val cameraOn: Boolean, val paused: Boolean, override val nowMs: Long) : CallEvent
    data class RemoteVideo(val active: Boolean, override val nowMs: Long) : CallEvent
    /** Call screen visible and unlocked (PiP counts as visible). */
    data class ScreenVisible(val visible: Boolean, override val nowMs: Long) : CallEvent
    /** Once a second while the camera is on: the engine's available outgoing bit rate (null = unknown). */
    data class Bandwidth(val availableKbps: Long?, override val nowMs: Long) : CallEvent
```

  Append to `sealed interface CallEffect`:

```kotlin
    /** Open the camera. Emitted ONLY for CallEvent.UserCamera(on = true) (D127; VideoPrivacyTest). */
    data object StartCamera : CallEffect
    data object StopCamera : CallEffect
    data object SwitchCamera : CallEffect
    /** Stop (true) or resume (false) sending video; the camera stays open. */
    data class SetVideoPaused(val paused: Boolean) : CallEffect
    data class ApplySaver(val saver: Boolean) : CallEffect
    data class SendMedia(val id: CallId, val peer: Peer, val cameraOn: Boolean, val paused: Boolean) : CallEffect
```

- [ ] **Step 4: `MediaEngine.kt`.** Replace `MediaListener` and add to `MediaEngine` (before `close()`):

```kotlin
interface MediaListener {
    fun onIce(phase: IcePhase)
    fun onCandidate(c: Candidate) // only candidates found after the SDP was returned (trickle)
    /** Video frames from the peer started (true) or have stopped for ~2 s (false). */
    fun onRemoteVideo(active: Boolean)
    /** The open camera failed or Android took it away; the engine has stopped using it. */
    fun onCameraError()
}
```

```kotlin
    /** Opens (true) or closes (false) the camera; video is sent while it is on and not paused. CallManager calls
     *  it only for a StartCamera/StopCamera effect (D127). */
    suspend fun setCamera(on: Boolean)
    /** Stops (true) or resumes (false) sending video (`RtpSender.setTrack(null)` / the camera track). */
    suspend fun setPaused(paused: Boolean)
    /** Front ↔ back; the new side (true = front), or null when there is no camera to switch. */
    suspend fun switchCamera(): Boolean?
    /** The saver cap (true) or the normal cap (false), D126. */
    suspend fun setSaver(saver: Boolean)
    /** The last second's measurements; null before ICE connects. Also notices that remote frames stopped. */
    suspend fun stats(): MediaStats?
    /** After the offer/answer exchange: the peer negotiated a send-receive video section (app 0.12.0+). */
    fun peerVideo(): Boolean
```

- [ ] **Step 5: Keep everything compiling.**
  * `CallStateMachine.on`: until Task 7 add one branch to the `when` so it stays exhaustive:
    `is UserCamera, is UserSwitchCamera, is SaverChanged, is CameraDenied, is CameraFailed, is CameraSwitched, is PeerVideo, is RemoteCamera, is RemoteVideo, is ScreenVisible, is Bandwidth -> emptyList()`
  * `CallManager.run`: add `CallEffect.StartCamera, CallEffect.StopCamera, CallEffect.SwitchCamera, is CallEffect.SetVideoPaused, is CallEffect.ApplySaver, is CallEffect.SendMedia -> {}` (Task 8 fills it); in `open()`'s `MediaListener` add
    `override fun onRemoteVideo(active: Boolean) {}` and `override fun onCameraError() {}` (Task 8 fills them).
  * `WebRtcEngine`: add `override suspend fun setCamera(on: Boolean) {}`, `override suspend fun setPaused(paused: Boolean) {}`,
    `override suspend fun switchCamera(): Boolean? = null`, `override suspend fun setSaver(saver: Boolean) {}`,
    `override suspend fun stats(): MediaStats? = null`, `override fun peerVideo() = false` (Task 10 replaces them).
  * `FakeEngine` in `CallManagerTest.kt` — add:

```kotlin
    /** Video calls in order: "camera:true", "paused:false", "switch" (kept apart from [calls], whose exact lists M8 tests assert). */
    val video: MutableList<String> = Collections.synchronizedList(mutableListOf())
    @Volatile var saver: Boolean? = null
    @Volatile var peerVideoResult = true
    @Volatile var nextStats: MediaStats? = null
    @Volatile var front = true
    override suspend fun setCamera(on: Boolean) { video += "camera:$on" }
    override suspend fun setPaused(paused: Boolean) { video += "paused:$paused" }
    override suspend fun switchCamera(): Boolean? { video += "switch"; front = !front; return front }
    override suspend fun setSaver(saver: Boolean) { this.saver = saver }
    override suspend fun stats(): MediaStats? = nextStats
    override fun peerVideo() = peerVideoResult
```

- [ ] **Step 6: Run** the Verify command → `BUILD SUCCESSFUL`.

- [ ] **Step 7: Commit**

```bash
git add core/data/src/main/kotlin/app/ottermsg/core/data/calls/ core/data/src/test/kotlin/app/ottermsg/core/data/calls/ feature/calls/src/main/kotlin/app/ottermsg/feature/calls/WebRtcEngine.kt
oc -m "calls: video model, MediaEngine camera/stats calls, FakeEngine (M10)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Android — `VideoWatchdog` (pause, test bursts, resume, no flapping)

**Goal:** A pure rule turns one bandwidth sample per second into pause / burst / resume decisions exactly as D126 says.

**Files:**
- Create: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/calls/VideoWatchdog.kt`
- Test: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/calls/VideoWatchdogTest.kt`

**Acceptance Criteria:**
- [ ] Sending: samples < 150 kbit/s for 10 s in a row → `PAUSE`; one sample ≥ 150 or an unknown sample restarts the count.
- [ ] Paused: a test burst (`PROBE_START`) 15 s after the pause, then 30 s, 60 s, every 120 s after failed bursts.
- [ ] Burst: ≥ 400 kbit/s for 15 s in a row → `RESUME`; still < 400 after the first 5 s, or any dip below 400 once it
  was above → `PROBE_STOP`.
- [ ] Alternating 140/160 for 2 min never pauses; alternating 390/410 during bursts never resumes.

**Verify:** `cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*VideoWatchdogTest'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing test** `VideoWatchdogTest.kt`:

```kotlin
package app.ottermsg.core.data.calls

import app.ottermsg.core.data.calls.VideoWatchdog.Action
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoWatchdogTest {
    /** Feeds one sample per second from [fromMs] (inclusive) for [seconds]; returns the non-NONE actions with their time. */
    private fun VideoWatchdog.run(fromMs: Long, seconds: Int, kbps: (Long) -> Long?): List<Pair<Long, Action>> =
        (0 until seconds).mapNotNull { i -> val t = fromMs + i * 1_000L; sample(kbps(t), t).takeIf { it != Action.NONE }?.let { t to it } }

    @Test fun pausesAfterTenSecondsBelow150() {
        val w = VideoWatchdog()
        assertEquals(emptyList<Any>(), w.run(0, 10) { 100 })        // t = 0 … 9 s
        assertEquals(Action.PAUSE, w.sample(100, 10_000))
        assertTrue(w.paused)
    }

    @Test fun oneGoodOrUnknownSampleRestartsTheCount() {
        val w = VideoWatchdog()
        w.run(0, 9) { 100 }
        assertEquals(Action.NONE, w.sample(150, 9_000))
        assertEquals(emptyList<Any>(), w.run(10_000, 9) { 100 })
        assertEquals(Action.NONE, w.sample(null, 19_000))
        assertEquals(emptyList<Any>(), w.run(20_000, 10) { 100 })
        assertEquals(Action.PAUSE, w.sample(100, 30_000))
    }

    @Test fun burstAfter15sResumesAfter15sAbove400() {
        val w = VideoWatchdog()
        w.run(0, 10) { 100 }; assertEquals(Action.PAUSE, w.sample(100, 10_000))
        assertEquals(emptyList<Any>(), w.run(11_000, 14) { 900 })  // nothing measurable while paused
        assertEquals(Action.PROBE_START, w.sample(900, 25_000))
        assertEquals(emptyList<Any>(), w.run(26_000, 15) { 900 })  // the burst's first sample only starts it
        assertEquals(Action.RESUME, w.sample(900, 41_000))
        assertFalse(w.paused)
    }

    @Test fun aFailedBurstStopsAfterFiveSecondsAndBacksOff() {
        val w = VideoWatchdog()
        w.run(0, 10) { 100 }; w.sample(100, 10_000)
        val acts = w.run(11_000, 400) { 200 }.map { it.second to it.first }
        val starts = acts.filter { it.first == Action.PROBE_START }.map { it.second }
        val stops = acts.filter { it.first == Action.PROBE_STOP }.map { it.second }
        assertEquals(listOf(25_000L, 60_000L, 125_000L, 250_000L, 375_000L), starts.take(5))
        assertEquals(starts.take(5).map { it + 5_000 }, stops.take(5))
        assertTrue(Action.RESUME !in acts.map { it.first })
    }

    @Test fun noFlapping() {
        val w = VideoWatchdog()
        assertEquals(emptyList<Any>(), w.run(0, 120) { t -> if ((t / 1000) % 2 == 0L) 140 else 160 })
        w.run(120_000, 10) { 100 }; assertEquals(Action.PAUSE, w.sample(100, 130_000))
        val acts = w.run(131_000, 300) { t -> if ((t / 1000) % 2 == 0L) 390 else 410 }
        assertTrue("must never resume on a link that keeps dipping under 400: $acts", acts.none { it.second == Action.RESUME })
    }

    @Test fun restartPausedWaitsAFullDelay() {
        val w = VideoWatchdog()
        w.restartPaused(1_000)
        assertTrue(w.paused)
        assertEquals(Action.NONE, w.sample(900, 15_000))
        assertEquals(Action.PROBE_START, w.sample(900, 16_000))
        w.reset()
        assertFalse(w.paused)
    }
}
```

- [ ] **Step 2: Run — fails** (`Unresolved reference: VideoWatchdog`).

- [ ] **Step 3: Implement** `VideoWatchdog.kt`:

```kotlin
package app.ottermsg.core.data.calls

/**
 * Weak-link pause (D126), pure. One [sample] per second while the camera is on and the call screen is visible.
 * While paused nothing measures the link (WebRTC's estimate stays near the audio rate when only audio flows), so
 * short test bursts of video are sent: resume needs 15 s ≥ 400 kbit/s inside a burst.
 */
class VideoWatchdog {
    enum class Action { NONE, PAUSE, PROBE_START, PROBE_STOP, RESUME }

    private sealed interface S
    private data class Sending(val belowSinceMs: Long?) : S
    private data class Paused(val nextBurstMs: Long, val step: Int) : S
    private data class Probing(val startMs: Long, val aboveSinceMs: Long?, val step: Int) : S

    private var s: S = Sending(null)
    /** True from PAUSE until RESUME (also during a burst). */
    val paused: Boolean get() = s !is Sending

    fun reset() { s = Sending(null) }

    /** The pause continues after a gap (screen hidden): the next burst comes a full first delay later. */
    fun restartPaused(nowMs: Long) { s = Paused(nowMs + BURST_DELAYS_MS[0], 0) }

    fun sample(kbps: Long?, nowMs: Long): Action = when (val c = s) {
        is Sending ->
            if (kbps == null || kbps >= PAUSE_BELOW_KBPS) { s = Sending(null); Action.NONE }
            else {
                val since = c.belowSinceMs ?: nowMs
                if (nowMs - since >= PAUSE_AFTER_MS) { s = Paused(nowMs + BURST_DELAYS_MS[0], 0); Action.PAUSE }
                else { s = Sending(since); Action.NONE }
            }
        is Paused ->
            if (nowMs >= c.nextBurstMs) { s = Probing(nowMs, null, c.step); Action.PROBE_START } else Action.NONE
        is Probing ->
            if (kbps != null && kbps >= RESUME_ABOVE_KBPS) {
                val since = c.aboveSinceMs ?: nowMs
                if (nowMs - since >= RESUME_AFTER_MS) { s = Sending(null); Action.RESUME }
                else { s = c.copy(aboveSinceMs = since); Action.NONE }
            } else if (c.aboveSinceMs != null || nowMs - c.startMs >= BURST_GRACE_MS) {
                val step = (c.step + 1).coerceAtMost(BURST_DELAYS_MS.lastIndex)
                s = Paused(nowMs + BURST_DELAYS_MS[step], step)
                Action.PROBE_STOP
            } else Action.NONE
    }

    companion object {
        const val PAUSE_BELOW_KBPS = 150L
        const val PAUSE_AFTER_MS = 10_000L
        const val RESUME_ABOVE_KBPS = 400L
        const val RESUME_AFTER_MS = 15_000L
        /** A burst that has not reached 400 kbit/s after this long ends (audio must not suffer for long). */
        const val BURST_GRACE_MS = 5_000L
        /** Pause → first burst, then after each failed burst. */
        val BURST_DELAYS_MS = longArrayOf(15_000, 30_000, 60_000, 120_000)
    }
}
```

  Check against `aFailedBurstStopsAfterFiveSecondsAndBacksOff`: pause at 10 s → burst 25 s, stop 30 s → +30 s → burst
  60 s, stop 65 s → +60 s → 125 s, stop 130 s → +120 s → 250 s, 375 s. Adjust nothing else if it passes.

- [ ] **Step 4: Run** the Verify command → `BUILD SUCCESSFUL`.

- [ ] **Step 5: Commit**

```bash
git add core/data/src/main/kotlin/app/ottermsg/core/data/calls/VideoWatchdog.kt core/data/src/test/kotlin/app/ottermsg/core/data/calls/VideoWatchdogTest.kt
oc -m "calls: VideoWatchdog — pause <150 kbit/s 10 s, test bursts, resume 15 s >400 (M10, D126)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Android — `CallStateMachine` video rules; only a tap starts the camera

**Goal:** The pure machine owns the video state: camera on/off only from a tap, answering keeps the camera off, the
peer's `CallMedia` and frames drive the remote view, old peers disable the camera, the screen-hidden pause, the saver,
and the watchdog — with a property test that no other event ever opens the camera.

**Files:**
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/calls/CallStateMachine.kt`
- Create: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/calls/VideoPrivacyTest.kt`
- Create: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/calls/VideoStateMachineTest.kt`

**Acceptance Criteria:**
- [ ] `StartCamera` appears **only** in the result of `UserCamera(on = true)`, and only in Outgoing/Connecting/Active
  with `peerVideo != false` and the camera off (200 random runs × 300 events of every other kind never produce it).
- [ ] Accept with the caller's camera on → our camera stays off, `remote` recorded; Incoming never offers the camera.
- [ ] `PeerVideo(false)` with the camera on → `StopCamera`; later taps do nothing; no `SendMedia` to an old peer.
- [ ] `ScreenVisible(false)` with the camera on → `SetVideoPaused(true)` + `SendMedia(cameraOn = false)`; visible again
  → `SetVideoPaused(false)` + `SendMedia(cameraOn = true)`; the camera is not restarted.
- [ ] Watchdog: in Active with the camera on, 10 s under 150 → `SetVideoPaused(true)` + `SendMedia(paused = true)`;
  bursts → `SetVideoPaused(false/true)` only; resume → `SendMedia(paused = false)`.
- [ ] The end of a call resets `video` (keeps `hidden`).

**Verify:** `cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*VideoPrivacyTest' --tests '*VideoStateMachineTest' --tests '*CallStateMachineTest'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing privacy test** `VideoPrivacyTest.kt`:

```kotlin
package app.ottermsg.core.data.calls

import app.ottermsg.core.data.calls.CallEffect.*
import app.ottermsg.core.data.calls.CallEvent.*
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/** D127 privacy rules on the pure machine. */
class VideoPrivacyTest {
    private val anna = Peer.of(ByteArray(16) { 1 }, "Anna")
    private val id = CallId("00".repeat(16))

    /** One event of every kind except UserCamera(on = true). */
    private fun others(now: Long, r: Random): List<CallEvent> = listOf(
        Dial(id, anna, now), OfferDelivered(id, now), RemoteOffer(id, anna, "o", r.nextBoolean(), now - 1, false, now),
        RemoteAnswer(id, "a", now), RemoteHangup(id, HangupReason.NORMAL, now), Accept(now), Decline(now), HangUp(now),
        IceConnected(now), IceLost(now), Tick(now), UserCamera(false, now), UserSwitchCamera(now),
        SaverChanged(r.nextBoolean(), now), CameraDenied(now), CameraFailed(now), CameraSwitched(r.nextBoolean(), now),
        PeerVideo(r.nextBoolean(), now), RemoteCamera(id, true, r.nextBoolean(), now), RemoteVideo(r.nextBoolean(), now),
        ScreenVisible(r.nextBoolean(), now), Bandwidth(if (r.nextInt(5) == 0) null else r.nextLong(0, 3_000), now),
    )

    /** Exhaustive on purpose (no else): a new CallEvent kind fails to compile here until it is added to [others]. */
    private fun kind(e: CallEvent): Int = when (e) {
        is Dial -> 0; is OfferDelivered -> 1; is RemoteOffer -> 2; is RemoteAnswer -> 3; is RemoteHangup -> 4
        is Accept -> 5; is Decline -> 6; is HangUp -> 7; is IceConnected -> 8; is IceLost -> 9; is Tick -> 10
        is UserCamera -> 11; is UserSwitchCamera -> 12; is SaverChanged -> 13; is CameraDenied -> 14; is CameraFailed -> 15
        is CameraSwitched -> 16; is PeerVideo -> 17; is RemoteCamera -> 18; is RemoteVideo -> 19; is ScreenVisible -> 20
        is Bandwidth -> 21
    }

    @Test fun onlyATapStartsTheCamera() {
        val r = Random(2026)
        assertEquals("every event kind is exercised", 22, others(0, r).map(::kind).toSet().size)
        var reachedActive = 0
        repeat(200) { run ->
            val m = CallStateMachine()
            var now = 0L
            repeat(300) {
                now += r.nextLong(1, 3_000)
                val e = others(now, r).random(r)
                assertFalse("run $run: $e opened the camera", StartCamera in m.on(e))
                if (m.state is CallState.Active) reachedActive++
            }
        }
        assertTrue("the random walks must reach active calls", reachedActive > 0)
    }

    @Test fun aTapStartsTheCameraOnlyInACall() {
        val m = CallStateMachine()
        assertTrue(m.on(UserCamera(true, 0)).isEmpty())                     // idle
        m.on(RemoteOffer(id, anna, "o", false, 0, false, 1))
        assertTrue("never while ringing", m.on(UserCamera(true, 2)).isEmpty())
        m.on(Accept(3)); m.on(IceConnected(4))
        assertTrue(StartCamera in m.on(UserCamera(true, 5)))
        assertTrue("already on", m.on(UserCamera(true, 6)).isEmpty())
    }

    @Test fun answeringWithTheCallersCameraOnKeepsOursOff() {
        val m = CallStateMachine()
        m.on(RemoteOffer(id, anna, "o", false, 0, false, 1))
        m.on(RemoteCamera(id, cameraOn = true, paused = false, nowMs = 2))
        val fx = m.on(Accept(3)) + m.on(IceConnected(4)) + m.on(PeerVideo(true, 5)) + m.on(RemoteVideo(true, 6)) +
            m.on(ScreenVisible(true, 7)) + m.on(RemoteCamera(id, true, false, 8))
        assertFalse(StartCamera in fx)
        assertFalse(m.video.cameraOn)
        assertTrue(m.video.showRemote)
        assertTrue("no camera state is sent for a camera that is off", fx.none { it is SendMedia })
    }
}
```

- [ ] **Step 2: Failing behaviour test** `VideoStateMachineTest.kt`:

```kotlin
package app.ottermsg.core.data.calls

import app.ottermsg.core.data.calls.CallEffect.*
import app.ottermsg.core.data.calls.CallEvent.*
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoStateMachineTest {
    private val anna = Peer.of(ByteArray(16) { 1 }, "Anna")
    private val id = CallId("00".repeat(16))

    /** Outgoing call, answered by a video-capable peer, media connected, camera on at t = 10 s. */
    private fun activeWithCamera(): CallStateMachine = CallStateMachine().apply {
        on(Dial(id, anna, 0)); on(RemoteAnswer(id, "a", 1_000)); on(PeerVideo(true, 1_100)); on(IceConnected(2_000))
        on(UserCamera(true, 10_000))
    }

    @Test fun tapOnAndOffTellThePeer() {
        val m = CallStateMachine()
        m.on(Dial(id, anna, 0)); m.on(RemoteAnswer(id, "a", 1_000)); m.on(PeerVideo(true, 1_100)); m.on(IceConnected(2_000))
        assertEquals(listOf(StartCamera, SetVideoPaused(false), SendMedia(id, anna, cameraOn = true, paused = false)), m.on(UserCamera(true, 3_000)))
        assertTrue(m.video.cameraOn)
        assertEquals(listOf(StopCamera, SendMedia(id, anna, cameraOn = false, paused = false)), m.on(UserCamera(false, 4_000)))
        assertFalse(m.video.cameraOn)
    }

    @Test fun cameraBeforeTheAnswerIsAllowedAndAnOldPeerTurnsItOff() {
        val m = CallStateMachine()
        m.on(Dial(id, anna, 0))
        assertTrue(StartCamera in m.on(UserCamera(true, 500)))               // ringing on their side: preview here
        m.on(RemoteAnswer(id, "a", 1_000))
        assertEquals(listOf(StopCamera), m.on(PeerVideo(false, 1_100)))
        assertFalse(m.video.cameraOn)
        assertEquals(false, m.video.peerVideo)
        assertTrue(m.on(UserCamera(true, 2_000)).isEmpty())
        assertTrue(m.on(ScreenVisible(false, 3_000)).none { it is SendMedia })
    }

    @Test fun remoteMediaAndFramesDriveTheRemoteView() {
        val m = activeWithCamera()
        m.on(RemoteVideo(true, 11_000)); assertTrue(m.video.showRemote)      // frames before their CallMedia
        m.on(RemoteCamera(id, false, false, 12_000)); assertFalse(m.video.showRemote)
        m.on(RemoteCamera(id, true, false, 13_000)); assertTrue(m.video.showRemote)
        m.on(RemoteCamera(id, true, true, 14_000)); assertFalse(m.video.showRemote); assertTrue(m.video.weakLink)
        m.on(RemoteCamera(CallId("ff".repeat(16)), true, false, 15_000)); assertTrue("other call ids are ignored", m.video.weakLink)
    }

    @Test fun hiddenScreenPausesAndShowsCameraOffToThePeer() {
        val m = activeWithCamera()
        assertEquals(listOf(SetVideoPaused(true), SendMedia(id, anna, cameraOn = false, paused = false)), m.on(ScreenVisible(false, 11_000)))
        assertTrue(m.video.cameraOn); assertFalse(m.video.sending)
        assertTrue("no watchdog while hidden", m.on(Bandwidth(10, 30_000)).isEmpty())
        assertEquals(listOf(SetVideoPaused(false), SendMedia(id, anna, cameraOn = true, paused = false)), m.on(ScreenVisible(true, 31_000)))
        assertTrue(m.on(ScreenVisible(true, 32_000)).isEmpty())
    }

    @Test fun weakLinkPausesBurstsAndResumes() {
        val m = activeWithCamera()
        val fx = (11..21).flatMap { s -> m.on(Bandwidth(100, s * 1_000L)) }  // 11 … 21 s below 150 → pause at 21 s
        assertEquals(listOf(SetVideoPaused(true), SendMedia(id, anna, cameraOn = true, paused = true)), fx)
        assertTrue(m.video.netPaused)
        assertEquals(listOf(SetVideoPaused(false)), (22..36).flatMap { s -> m.on(Bandwidth(900, s * 1_000L)) })  // burst at 36 s
        val resume = (37..52).flatMap { s -> m.on(Bandwidth(900, s * 1_000L)) }  // ≥ 400 from 37 s → resume at 52 s
        assertEquals(listOf(SendMedia(id, anna, cameraOn = true, paused = false)), resume)
        assertFalse(m.video.netPaused)
    }

    @Test fun saverSwitchAndFailures() {
        val m = activeWithCamera()
        assertEquals(listOf(ApplySaver(true)), m.on(SaverChanged(true, 11_000)))
        assertTrue(m.video.saver)
        assertEquals(listOf(SwitchCamera), m.on(UserSwitchCamera(12_000)))
        m.on(CameraSwitched(false, 12_500)); assertFalse(m.video.front)
        assertEquals(listOf(StopCamera, SendMedia(id, anna, cameraOn = false, paused = false)), m.on(CameraFailed(13_000)))
        assertTrue(m.on(UserSwitchCamera(14_000)).isEmpty())
        m.on(CameraDenied(15_000)); assertTrue(m.video.cameraDenied)
    }

    @Test fun theEndResetsVideoButKeepsHidden() {
        val m = activeWithCamera()
        m.on(ScreenVisible(false, 11_000))
        m.on(HangUp(12_000))
        assertEquals(VideoState(hidden = true), m.video)
    }
}
```

- [ ] **Step 3: Run — fails** (Task 5's placeholder branch returns empty lists).

- [ ] **Step 4: Implement in `CallStateMachine.kt`.** Add fields after `ended`:

```kotlin
    /** Camera and video of the current call (D125–D127). */
    var video: VideoState = VideoState()
        private set
    private val watchdog = VideoWatchdog()
```

  Replace Task 5's placeholder branch in `on()` with:

```kotlin
            is UserCamera -> if (ev.on) userCameraOn() else cameraOff()
            is UserSwitchCamera -> if (video.cameraOn && inCall()) listOf(SwitchCamera) else emptyList()
            is CameraSwitched -> { video = video.copy(front = ev.front); emptyList() }
            is SaverChanged -> { video = video.copy(saver = ev.on); listOf(ApplySaver(ev.on)) }
            is CameraDenied -> { video = video.copy(cameraDenied = true); emptyList() }
            is CameraFailed -> cameraOff()
            is PeerVideo -> peerVideo(ev)
            is RemoteCamera -> { if (idOf(state) == ev.id) video = video.copy(remote = RemoteMedia(ev.cameraOn, ev.paused)); emptyList() }
            is RemoteVideo -> { if (state != CallState.Idle) video = video.copy(remoteFrames = ev.active); emptyList() }
            is ScreenVisible -> screen(ev)
            is Bandwidth -> bandwidth(ev)
```

  In `end()` add before `state = CallState.Idle`:

```kotlin
        video = VideoState(hidden = video.hidden)
        watchdog.reset()
```

  Add the private functions (next to `idOf`):

```kotlin
    /** Outgoing, connecting or active: the camera may be used (never while ringing, D127). */
    private fun inCall() = state is CallState.Outgoing || state is CallState.Connecting || state is CallState.Active

    /** The ONLY place StartCamera is produced (D127): reached from CallEvent.UserCamera(on = true) alone. */
    private fun userCameraOn(): List<CallEffect> {
        if (!inCall() || video.cameraOn || video.peerVideo == false) return emptyList()
        video = video.copy(cameraOn = true, cameraDenied = false, netPaused = false)
        watchdog.reset()
        return listOf(StartCamera, SetVideoPaused(video.hidden)) + media()
    }

    private fun cameraOff(): List<CallEffect> {
        if (!video.cameraOn) return emptyList()
        video = video.copy(cameraOn = false, netPaused = false)
        watchdog.reset()
        return listOf(StopCamera) + media()
    }

    private fun peerVideo(ev: PeerVideo): List<CallEffect> {
        if (!inCall()) return emptyList()
        video = video.copy(peerVideo = ev.capable)
        if (ev.capable || !video.cameraOn) return emptyList()
        video = video.copy(cameraOn = false, netPaused = false)
        watchdog.reset()
        return listOf(StopCamera)
    }

    /** What the peer should show; nothing for a peer known to be old (it would ignore it anyway). */
    private fun media(): List<CallEffect> {
        if (video.peerVideo == false) return emptyList()
        val (id, peer) = idPeer(state) ?: return emptyList()
        val on = video.cameraOn && !video.hidden
        return listOf(SendMedia(id, peer, cameraOn = on, paused = on && video.netPaused))
    }

    private fun screen(ev: ScreenVisible): List<CallEffect> {
        val hidden = !ev.visible
        if (hidden == video.hidden) return emptyList()
        video = video.copy(hidden = hidden)
        if (!video.cameraOn) return emptyList()
        if (video.netPaused) watchdog.restartPaused(ev.nowMs) else watchdog.reset()
        return listOf(SetVideoPaused(hidden || video.netPaused)) + media()
    }

    private fun bandwidth(ev: Bandwidth): List<CallEffect> {
        if (state !is CallState.Active || !video.cameraOn || video.hidden || video.peerVideo != true) return emptyList()
        return when (watchdog.sample(ev.availableKbps, ev.nowMs)) {
            VideoWatchdog.Action.NONE -> emptyList()
            VideoWatchdog.Action.PAUSE -> { video = video.copy(netPaused = true); listOf(SetVideoPaused(true)) + media() }
            VideoWatchdog.Action.PROBE_START -> listOf(SetVideoPaused(false)) // test burst: the peer keeps the notice
            VideoWatchdog.Action.PROBE_STOP -> listOf(SetVideoPaused(true))
            VideoWatchdog.Action.RESUME -> { video = video.copy(netPaused = false); media() }
        }
    }

    private fun idPeer(s: CallState): Pair<CallId, Peer>? = when (s) {
        is CallState.Outgoing -> s.id to s.peer; is CallState.Incoming -> s.id to s.peer
        is CallState.Connecting -> s.id to s.peer; is CallState.Active -> s.id to s.peer
        CallState.Idle -> null
    }
```

  Note on `weakLinkPausesBurstsAndResumes`: the first `Bandwidth` sample is at 11 s, so the pause comes at 21 s, the
  burst at 36 s (15 s later; that sample only starts the burst) and the resume at 52 s (15 s ≥ 400 counted from the
  first burst sample at 37 s).

- [ ] **Step 5: Run** the Verify command → `BUILD SUCCESSFUL` (all existing `CallStateMachineTest` cases still pass).

- [ ] **Step 6: Commit**

```bash
git add core/data/src/main/kotlin/app/ottermsg/core/data/calls/CallStateMachine.kt core/data/src/test/kotlin/app/ottermsg/core/data/calls/VideoPrivacyTest.kt core/data/src/test/kotlin/app/ottermsg/core/data/calls/VideoStateMachineTest.kt
oc -m "calls: video in the state machine; only a tap starts the camera, answering keeps it off (M10, D127)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Android — `CallManager` video, `CallMedia` send/receive (non-urgent), sampling

**Goal:** `CallManager` connects the machine's video effects to the engine and to signaling, feeds remote `CallMedia`,
frames, camera errors and the once-a-second bandwidth sample into the machine, applies the saver default at call start,
and exposes `video: StateFlow<VideoState>` plus the user actions.

**Files:**
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/calls/CallManager.kt`
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/calls/CallSignaling.kt`
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/settings/Settings.kt` (only `videoSaver()`; the full setting is Task 9 — do Task 9 Steps 1–3 first if you prefer)
- Test: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/calls/CallManagerVideoTest.kt` (new), `CallSignalingTest.kt`

**Acceptance Criteria:**
- [ ] `userCamera(true)` in an active call with a 0.11 peer → engine `camera:true`, `paused:false`; a non-urgent
  `CallMedia{camera_on = true}` goes out with the call id.
- [ ] Offer + caller's `CallMedia{camera_on}` + accept + ICE + frames → engine never gets `camera:true`;
  `video.showRemote` true.
- [ ] Engine `peerVideo() == false` after the answer → `video.peerVideo == false`; taps do nothing; no `CallMedia` sent.
- [ ] A stats estimate of 100 kbit/s for > 10 s → `paused:true` and `CallMedia{paused}`; 900 kbit/s afterwards →
  resumed within 35 s (burst after 15 s, resume after 15 s ≥ 400) with `CallMedia{paused = false}`.
- [ ] Settings saver on → engine `setSaver(true)` right after it opens; `setSaver(false)` in the call changes only this call.
- [ ] Hidden screen → `paused:true` + `CallMedia{camera_on = false}`; visible → `paused:false` + `CallMedia{camera_on}`;
  the camera is opened once.
- [ ] Hang-up closes the engine and resets `video` to `VideoState()`.
- [ ] `CallSignaling` sends `media` non-urgent (other kinds stay urgent).

**Verify:** `cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*CallManagerVideoTest' --tests '*CallManagerTest' --tests '*CallSignalingTest'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing signaling test** — append to `CallSignalingTest.kt` (import `app.ottermsg.proto.v1.CallMedia`):

```kotlin
    @Test fun cameraStateGoesOutNotUrgent() = runBlocking {
        setup()
        val m = CallMessage.newBuilder().setCallId(ByteString.copyFrom(callId.bytes()))
            .setMedia(CallMedia.newBuilder().setCameraOn(true)).build()
        CallSignaling(b.outbox, clock).send(a.me.userId, m)
        val item = b.db.outboxDao().due(Long.MAX_VALUE).single()
        assertFalse("camera state must not use the call-wake budget", item.urgent)
        assertTrue(item.expiresMs > clock.now())
    }
```

- [ ] **Step 2: Failing manager test** `CallManagerVideoTest.kt` (same package; reuses `FakeEngine`, `RecordingTransport`,
  `TurnApi`, `FakeLink`, `CallNetLog`, `RecordingAlerts` from `CallManagerTest.kt`):

```kotlin
package app.ottermsg.core.data.calls

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.ottermsg.core.data.Clock
import app.ottermsg.core.data.settings.Settings
import app.ottermsg.core.database.OtterDatabase
import app.ottermsg.proto.v1.CallAnswer
import app.ottermsg.proto.v1.CallMedia
import app.ottermsg.proto.v1.CallMessage
import app.ottermsg.proto.v1.CallOffer
import app.ottermsg.proto.v1.TurnCredentials
import com.google.protobuf.ByteString
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.Collections

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class CallManagerVideoTest {
    private val test = TestScope(StandardTestDispatcher())
    private val job = Job()
    private val scope = CoroutineScope(test.coroutineContext.minusKey(Job) + job)
    private val clock = Clock { 1_800_000_000_000L + test.testScheduler.currentTime }
    private val db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), OtterDatabase::class.java).build()
    private val settings = Settings(db.settingsDao())
    private val turn = TurnCredentials.newBuilder().setUsername("${clock.now() / 1000 + 43_200}:abcd").setPassword("pw").setTtlS(43_200)
        .addUrls("turn:203.0.113.7:3478?transport=udp").build()
    private val transport = RecordingTransport()
    private val alerts = RecordingAlerts()
    private val engines: MutableList<FakeEngine> = Collections.synchronizedList(mutableListOf())
    private val manager = CallManager(transport, CallLines(db, clock), { FakeEngine().also { engines += it } }, TurnCache(clock),
        FakeLink(TurnApi(turn)), settings, alerts, CallNetLog(), clock, scope)
    private val peer = Peer.of(ByteArray(16) { 5 }, "Анна")

    @After fun tearDown() { job.cancel(); test.cancel(); db.close() }

    private fun settle(what: String = "condition", cond: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 20_000
        while (System.currentTimeMillis() < deadline) { test.runCurrent(); if (cond()) return; Thread.sleep(5) }
        throw AssertionError("timed out waiting for $what")
    }
    private fun msg(id: CallId) = CallMessage.newBuilder().setCallId(ByteString.copyFrom(id.bytes()))
    private fun deliver(m: CallMessage) = runBlocking { manager.onCallMessage(peer.id, peer.name, m, clock.now()) }
    private fun engine() = engines.last()
    private fun media() = synchronized(transport.sent) { transport.sent.filter { it.second.kindCase == CallMessage.KindCase.MEDIA }.map { it.second } }

    /** Our outgoing call answered by a 0.11 peer and connected. */
    private fun activeOutgoing(): CallId {
        manager.dial(peer)
        settle("offer") { transport.sent.isNotEmpty() }
        val id = (manager.state.value as CallState.Outgoing).id
        deliver(msg(id).setAnswer(CallAnswer.newBuilder().setSdp("answer-sdp")).build())
        settle("answer applied") { "apply:answer-sdp" in engine().calls }
        engine().listener!!.onIce(IcePhase.CONNECTED)
        settle("active") { manager.state.value is CallState.Active && manager.video.value.peerVideo == true }
        return id
    }

    private fun cameraOn() { manager.userCamera(true); settle("camera") { "camera:true" in engine().video } }

    @Test fun aTapOpensTheCameraAndTellsThePeer() {
        val id = activeOutgoing()
        cameraOn()
        settle("media sent") { media().isNotEmpty() }
        assertEquals(listOf("camera:true", "paused:false"), engine().video.toList())
        val m = media().single()
        assertEquals(id, CallId.of(m.callId.toByteArray()))
        assertTrue(m.media.cameraOn); assertFalse(m.media.paused)
        manager.userCamera(false)
        settle("off sent") { media().size == 2 }
        assertEquals("camera:false", engine().video.last())
        assertFalse(media().last().media.cameraOn)
    }

    @Test fun answeringWithTheCallersCameraOnNeverOpensOurs() {
        val id = CallId.random()
        deliver(msg(id).setOffer(CallOffer.newBuilder().setSdp("their-offer")).build())
        deliver(msg(id).setMedia(CallMedia.newBuilder().setCameraOn(true)).build())
        settle("ringing") { alerts.incoming.isNotEmpty() && manager.video.value.remote?.cameraOn == true }
        manager.accept()
        settle("answered") { transport.sent.any { it.second.kindCase == CallMessage.KindCase.ANSWER } }
        engine().listener!!.onIce(IcePhase.CONNECTED)
        engine().listener!!.onRemoteVideo(true)
        settle("remote shown") { manager.state.value is CallState.Active && manager.video.value.showRemote }
        test.advanceTimeBy(5_000); test.runCurrent()
        assertTrue("camera never touched: ${engine().video}", engine().video.none { it == "camera:true" })
        assertFalse(manager.video.value.cameraOn)
        assertTrue(media().isEmpty())
    }

    @Test fun anOldPeerKeepsTheCameraOff() {
        manager.dial(peer)
        settle("offer") { transport.sent.isNotEmpty() }
        engine().peerVideoResult = false
        val id = (manager.state.value as CallState.Outgoing).id
        deliver(msg(id).setAnswer(CallAnswer.newBuilder().setSdp("answer-sdp")).build())
        settle("old peer seen") { manager.video.value.peerVideo == false }
        manager.userCamera(true)
        test.advanceTimeBy(1_000); test.runCurrent()
        assertTrue(engine().video.isEmpty())
        assertTrue(media().isEmpty())
    }

    @Test fun aWeakLinkPausesSendingAndAGoodOneResumes() {
        activeOutgoing(); cameraOn()
        engine().nextStats = MediaStats(100, 90, 0, 640, 360, 0, 0)
        test.advanceTimeBy(12_000)
        settle("paused") { manager.video.value.netPaused && media().lastOrNull()?.media?.paused == true }
        assertEquals("paused:true", engine().video.last())
        engine().nextStats = MediaStats(900, 800, 0, 1280, 720, 0, 0)
        test.advanceTimeBy(35_000) // burst 15 s after the pause, resume 16 s later
        settle("resumed") { !manager.video.value.netPaused && media().last().media.let { it.cameraOn && !it.paused } }
        assertEquals("paused:false", engine().video.last())
    }

    @Test fun theSaverSettingStartsEveryCallAndTheButtonChangesOnlyThisCall() {
        runBlocking { settings.setVideoSaver(true) }
        manager.dial(peer)
        settle("offer") { transport.sent.isNotEmpty() }
        assertEquals(true, engine().saver)
        assertTrue(manager.video.value.saver)
        manager.setSaver(false)
        settle("saver off") { engine().saver == false && !manager.video.value.saver }
        assertTrue(runBlocking { settings.videoSaver() })
    }

    @Test fun aHiddenScreenStopsSendingAndShowsTheCameraOffToThePeer() {
        activeOutgoing(); cameraOn()
        manager.setScreenVisible(false)
        settle("hidden") { engine().video.last() == "paused:true" && media().last().media.let { !it.cameraOn && !it.paused } }
        manager.setScreenVisible(true)
        settle("visible") { engine().video.last() == "paused:false" && media().last().media.cameraOn }
        assertEquals("the camera was opened once", 1, engine().video.count { it == "camera:true" })
    }

    @Test fun theCallEndClosesTheCameraWithTheEngine() {
        activeOutgoing(); cameraOn()
        manager.hangUp()
        settle("released") { alerts.released == 1 }
        assertTrue(engine().closed)
        assertEquals(VideoState(), manager.video.value)
    }
}
```

- [ ] **Step 3: Run — fails** (`Unresolved reference: userCamera`, `video`, `setScreenVisible`, `videoSaver`).

- [ ] **Step 4: `CallSignaling.send`** — replace `urgent = true` with
  `urgent = msg.kindCase != CallMessage.KindCase.MEDIA` and extend its KDoc: "Urgent (push wakes the callee), except
  the camera state (D125: it must not use the call-wake budget)".

- [ ] **Step 5: `Settings.videoSaver()`** (if Task 9 is not done yet, add the three functions and the key from Task 9
  Step 3 now).

- [ ] **Step 6: `CallManager.kt`.** Import `app.ottermsg.proto.v1.CallMedia`. Add `data object Sample : Op` to `Op` and
  `is Op.Sample -> sample()` to the loop's `when`. Add the flow and actions next to `muted`:

```kotlin
    private val _video = MutableStateFlow(VideoState())
    /** Camera and video of the current call (D125–D127). */
    val video: StateFlow<VideoState> = _video.asStateFlow()
```

```kotlin
    /** The camera button was tapped (D127). Its only caller is CallViewModel.cameraTapped (CameraEntryPointsTest). */
    fun userCamera(on: Boolean) = post(CallEvent.UserCamera(on, clock.now()))
    fun switchCamera() = post(CallEvent.UserSwitchCamera(clock.now()))
    /** «Экономить трафик» for this call only; the Settings default is read at the start of every call. */
    fun setSaver(on: Boolean) = post(CallEvent.SaverChanged(on, clock.now()))
    fun cameraDenied() = post(CallEvent.CameraDenied(clock.now()))
    /** The call screen is visible and unlocked (PiP counts), or not (screen off, background, lock screen). */
    fun setScreenVisible(visible: Boolean) = post(CallEvent.ScreenVisible(visible, clock.now()))
```

  In `onCallMessage` add the branch
  `CallMessage.KindCase.MEDIA -> post(CallEvent.RemoteCamera(id, msg.media.cameraOn, msg.media.paused, now))`.

  In `process(ev)` replace the first lines up to `_state.value = machine.state` with:

```kotlin
        val before = machine.state
        // every call starts with the Settings saver (D126); read before the effects open the engine
        val saverDefault = if (before == CallState.Idle && (ev is CallEvent.Dial || ev is CallEvent.RemoteOffer)) settings.videoSaver() else null
        val fx = machine.on(ev)
        if (saverDefault != null && machine.state != CallState.Idle) machine.on(CallEvent.SaverChanged(saverDefault, ev.nowMs))
        _state.value = machine.state
        _video.value = machine.video
```

  and add `_video.value = machine.video` at the end of `process` and after `_state.value = machine.state` in `abort`.

  In `run(e)` replace Task 5's placeholder with:

```kotlin
            CallEffect.StartCamera -> engine?.setCamera(true)
            CallEffect.StopCamera -> engine?.setCamera(false)
            CallEffect.SwitchCamera -> engine?.switchCamera()?.let { post(CallEvent.CameraSwitched(it, clock.now())) }
            is CallEffect.SetVideoPaused -> engine?.setPaused(e.paused)
            is CallEffect.ApplySaver -> engine?.setSaver(e.saver)
            is CallEffect.SendMedia -> transport.send(e.peer.id,
                msg(e.id).setMedia(CallMedia.newBuilder().setCameraOn(e.cameraOn).setPaused(e.paused)).build())
```

  In `SendAnswer` after `val sdp = eng.answer(e.offerSdp)` and in `ApplyAnswer` after `eng.applyAnswer(e.sdp)` add
  `post(CallEvent.PeerVideo(eng.peerVideo(), clock.now()))`.

  In `open()`: replace Task 5's listener stubs with

```kotlin
            override fun onRemoteVideo(active: Boolean) { if (engine === eng) post(CallEvent.RemoteVideo(active, clock.now())) }
            override fun onCameraError() { if (engine === eng) post(CallEvent.CameraFailed(clock.now())) }
```

  and after `if (_muted.value) eng.setMuted(true)` add `eng.setSaver(machine.video.saver)`.

  In `onBusy()` the ticker becomes
  `while (isActive) { delay(1_000); post(CallEvent.Tick(clock.now())); ops.trySend(Op.Sample) }`, and add:

```kotlin
    /** Once a second in an answered call with a 0.11 peer (D126): engine stats feed the watchdog and notice stopped frames. */
    private suspend fun sample() {
        if (machine.state !is CallState.Active || machine.video.peerVideo != true) return
        val eng = engine ?: return
        val st = try { eng.stats() } catch (c: CancellationException) { throw c } catch (_: Exception) { null }
        if (machine.video.cameraOn) process(CallEvent.Bandwidth(st?.availableOutgoingKbps, clock.now()))
    }
```

- [ ] **Step 7: Run** the Verify command → `BUILD SUCCESSFUL` (M8's `CallManagerTest` unchanged and green).

- [ ] **Step 8: Commit**

```bash
git add core/data/src/main/kotlin/app/ottermsg/core/data/calls/ core/data/src/main/kotlin/app/ottermsg/core/data/settings/Settings.kt core/data/src/test/kotlin/app/ottermsg/core/data/calls/
oc -m "calls: CallManager drives camera, CallMedia (non-urgent), saver default and the bandwidth sample (M10)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 9: Android — «Экономить трафик в видеозвонках» setting and switch

**Goal:** A Settings switch (default off) right under «Звонки только через сервер» makes every call start with the
saver cap.

**Files:**
- Modify: `otter-android/core/data/src/main/kotlin/app/ottermsg/core/data/settings/Settings.kt` (+ key `VIDEO_SAVER`)
- Modify: `otter-android/feature/settings/src/main/kotlin/app/ottermsg/feature/settings/SettingsScreen.kt` (`SettingsViewModel`, `CallSettingsRows`)
- Modify: `otter-android/feature/settings/src/main/res/values/strings.xml`, `values-en/strings.xml`
- Test: `otter-android/core/data/src/test/kotlin/app/ottermsg/core/data/settings/VideoSaverSettingTest.kt` (new), `otter-android/feature/settings/src/test/kotlin/app/ottermsg/feature/settings/CallSettingsTest.kt`

**Acceptance Criteria:**
- [ ] `Settings.videoSaver()` false by default, persists, observable.
- [ ] `SettingsViewModel.videoSaver` is false before the store answers; `setVideoSaver(true)` saves it.
- [ ] `CallSettingsRows` shows «Экономить трафик в видеозвонках» with the caption «Видео до 360p и не больше
  500 кбит/с» as a second switch directly after the relay-only switch; toggling it calls `onSaver`.

**Verify:** `cd otter-android && ./gradlew :core:data:testDebugUnitTest --tests '*VideoSaverSettingTest' :feature:settings:testDebugUnitTest --tests '*CallSettingsTest'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing tests.** `core/data/src/test/kotlin/app/ottermsg/core/data/settings/VideoSaverSettingTest.kt`:

```kotlin
package app.ottermsg.core.data.settings

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.ottermsg.core.database.OtterDatabase
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class VideoSaverSettingTest {
    private val db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), OtterDatabase::class.java).build()
    @After fun close() = db.close()

    @Test fun defaultsOffAndPersists() = runBlocking {
        val s = Settings(db.settingsDao())
        assertFalse(s.videoSaver())
        assertFalse(s.observeVideoSaver().first())
        s.setVideoSaver(true)
        assertTrue(s.videoSaver())
        assertTrue(s.observeVideoSaver().first())
    }
}
```

  In `CallSettingsTest.kt` replace the two `compose.onNode(isToggleable())` calls in
  `switchRowTogglesAndFsiRowShowsOnlyWhenBlocked` with `compose.onNode(isToggleable() and hasText("Звонки только через сервер"))`
  (import `androidx.compose.ui.test.hasText`; there are two switches now) and append:

```kotlin
    @Test fun videoSaverDefaultsOffAndTogglingSavesIt() {
        val d = StandardTestDispatcher()
        Dispatchers.setMain(d)
        try {
            runTest(d) {
                val stored = MutableStateFlow(false)
                val saved = mutableListOf<Boolean>()
                val vm = SettingsViewModel(MutableStateFlow(null), MutableStateFlow(ConnectionState.Connecting), MutableStateFlow(true), {},
                    saver = stored, saveSaver = { saved += it; stored.value = it })
                advanceUntilIdle()
                assertEquals(false, vm.videoSaver.value)
                vm.setVideoSaver(true); advanceUntilIdle()
                assertEquals(listOf(true), saved)
                assertEquals(true, vm.videoSaver.value)
            }
        } finally { Dispatchers.resetMain() }
    }

    @Test fun saverRowSitsUnderTheRelayRowAndToggles() {
        var saver by mutableStateOf(false)
        compose.setContent { OtterTheme { Column { CallSettingsRows(true, {}, fsiBlocked = false, onFsiFix = {}, saver = saver, onSaver = { saver = it }) } } }
        compose.onNodeWithText("Видео до 360p и не больше 500 кбит/с").assertExists()
        val row = compose.onNode(isToggleable() and hasText("Экономить трафик в видеозвонках"))
        row.assertIsOff().performClick()
        assertEquals(true, saver)
        row.assertIsOn()
        val top = compose.onNodeWithText("Звонки только через сервер").fetchSemanticsNode().boundsInRoot.top
        val below = compose.onNodeWithText("Экономить трафик в видеозвонках").fetchSemanticsNode().boundsInRoot.top
        assertTrue("saver row is below the relay row", below > top)
    }
```

  (imports: `androidx.compose.ui.test.hasText`, `org.junit.Assert.assertTrue`.)

- [ ] **Step 2: Run — fails** (`Unresolved reference: videoSaver` / no parameter `saver`).

- [ ] **Step 3: `Settings.kt`.** After `observeCallsRelayOnly()`:

```kotlin
    /** «Экономить трафик в видеозвонках» (D126): every call starts with the 360p ≤ 500 kbit/s cap; default off. */
    suspend fun videoSaver(): Boolean = (int(VIDEO_SAVER) ?: 0) != 0
    suspend fun setVideoSaver(v: Boolean) = putInt(VIDEO_SAVER, if (v) 1 else 0)
    fun observeVideoSaver(): Flow<Boolean> = observeInt(VIDEO_SAVER, 0).map { it != 0 }
```

  and in the companion after `CALLS_RELAY_ONLY`: `const val VIDEO_SAVER = "calls_video_saver"`.

- [ ] **Step 4: `SettingsScreen.kt`.** Extend the internal constructor with defaulted parameters (old call sites keep
  compiling) and the `@Inject` constructor:

```kotlin
class SettingsViewModel internal constructor(
    val account: StateFlow<LocalAccount?>, val connection: StateFlow<ConnectionState>,
    relayOnly: Flow<Boolean>, private val saveRelayOnly: suspend (Boolean) -> Unit,
    saver: Flow<Boolean> = flowOf(false), private val saveSaver: suspend (Boolean) -> Unit = {},
) : ViewModel() {
    @Inject constructor(accounts: AccountRepository, sync: SyncEngine, settings: AppSettings) :
        this(accounts.account, sync.connection, settings.observeCallsRelayOnly(), { settings.setCallsRelayOnly(it) },
            settings.observeVideoSaver(), { settings.setVideoSaver(it) })
    …
    /** «Экономить трафик в видеозвонках» (D126), off by default. */
    val videoSaver: StateFlow<Boolean> = saver.stateIn(viewModelScope, SharingStarted.Eagerly, false)
    fun setVideoSaver(v: Boolean) { viewModelScope.launch { saveSaver(v) } }
```

  (If M9 added parameters to this constructor, put `saver`/`saveSaver` last, still defaulted; import
  `kotlinx.coroutines.flow.flowOf`.) In `SettingsRoute` collect `val saver by vm.videoSaver.collectAsStateWithLifecycle()`
  and pass `saver = saver, onSaver = vm::setVideoSaver` to `CallSettingsRows`. Replace `CallSettingsRows` with:

```kotlin
@Composable
internal fun CallSettingsRows(relayOnly: Boolean, onRelayOnly: (Boolean) -> Unit, fsiBlocked: Boolean, onFsiFix: () -> Unit,
                              saver: Boolean = false, onSaver: (Boolean) -> Unit = {}) {
    SwitchRow(stringResource(R.string.settings_calls_relay_only), stringResource(R.string.settings_calls_relay_only_sub), relayOnly, onRelayOnly)
    SwitchRow(stringResource(R.string.settings_calls_video_saver), stringResource(R.string.settings_calls_video_saver_sub), saver, onSaver)
    if (fsiBlocked) OtterSettingsRow(stringResource(R.string.settings_calls_fsi), icon = Icons.Outlined.PhoneLocked, onClick = onFsiFix)
}

@Composable
private fun SwitchRow(title: String, caption: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = Dimens.settingsRowWithCaptionMin)
        .toggleable(value = checked, onValueChange = onChange, role = Role.Switch)
        .padding(horizontal = Dimens.screenGutter, vertical = Dimens.s8), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Text(caption, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked = checked, onCheckedChange = null)
    }
}
```

  Strings — `values/strings.xml`: `settings_calls_video_saver` «Экономить трафик в видеозвонках»,
  `settings_calls_video_saver_sub` «Видео до 360p и не больше 500 кбит/с»; `values-en/strings.xml`: "Save data in video
  calls", "Video up to 360p and at most 500 kbit/s".

- [ ] **Step 5: Run** the Verify command → `BUILD SUCCESSFUL`.

- [ ] **Step 6: Commit**

```bash
git add core/data/src/main/kotlin/app/ottermsg/core/data/settings/Settings.kt core/data/src/test/kotlin/app/ottermsg/core/data/settings/VideoSaverSettingTest.kt feature/settings/
oc -m "settings: «Экономить трафик в видеозвонках» (M10, D126)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Android — `WebRtcEngine` video (transceiver, `setTrack`, camera, caps, saver, switch, stats, EGL)

**Goal:** The real engine negotiates a track-less `sendrecv` video transceiver in every call, attaches/detaches the
camera with `setTrack`, applies the caps, switches cameras, reports stats and remote frames, and uses hardware codecs
through one shared EGL context.

**Files:**
- Create: `otter-android/feature/calls/src/main/kotlin/app/ottermsg/feature/calls/VideoSinks.kt`
- Create: `otter-android/feature/calls/src/main/kotlin/app/ottermsg/feature/calls/StatsParse.kt`
- Modify: `otter-android/feature/calls/src/main/kotlin/app/ottermsg/feature/calls/WebRtcEngine.kt` (whole file below)
- Modify: `otter-android/app/src/main/java/app/ottermsg/calls/CallModule.kt`
- Test: `otter-android/feature/calls/src/test/kotlin/app/ottermsg/feature/calls/StatsParseTest.kt` (new)

**Acceptance Criteria:**
- [ ] `parseMediaStats` reads `availableOutgoingBitrate` from the selected pair (via `transport.selectedCandidatePairId`,
  else the nominated succeeded pair), sums video `bytesSent`/`bytesReceived` (BigInteger or Long) into kbit/s deltas,
  and frame sizes; first call gives 0 kbit/s.
- [ ] Offerer adds the video transceiver (`SEND_RECV`, stream `s0`) in `offer()` once; answerer takes the transceiver the
  remote offer created and sets it `SEND_RECV`; `peerVideo()` = `currentDirection == SEND_RECV`.
- [ ] `setCamera(true)` opens the front camera (or the test capturer), feeds the local sink, attaches the track unless
  paused; `setPaused(true)` = `setTrack(null, false)`; caps: `maxBitrateBps`, `maxFramerate`, `scaleResolutionDownBy = 1.0`
  + capture format; `close()` releases camera, textures, tracks, source.
- [ ] `./gradlew :app:assembleDebug` builds.

**Verify:** `cd otter-android && ./gradlew :feature:calls:testDebugUnitTest --tests '*StatsParseTest' :app:assembleDebug` → `BUILD SUCCESSFUL`
(the engine's behaviour on a device is Task 11's test).

**Steps:**

- [ ] **Step 1: Failing test** `feature/calls/src/test/kotlin/app/ottermsg/feature/calls/StatsParseTest.kt`:

```kotlin
package app.ottermsg.feature.calls

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.webrtc.RTCStats
import java.math.BigInteger

class StatsParseTest {
    private fun s(type: String, id: String, vararg m: Pair<String, Any>) = id to RTCStats(0L, type, id, mapOf(*m))

    private fun report(sent: Long, received: Long) = mapOf(
        s("transport", "T1", "selectedCandidatePairId" to "CP2"),
        s("candidate-pair", "CP1", "nominated" to true, "state" to "succeeded", "availableOutgoingBitrate" to 99_000.0),
        s("candidate-pair", "CP2", "nominated" to true, "state" to "succeeded", "availableOutgoingBitrate" to 1_234_567.0),
        s("outbound-rtp", "O1", "kind" to "video", "bytesSent" to BigInteger.valueOf(sent), "frameWidth" to 1280L, "frameHeight" to 720L),
        s("outbound-rtp", "O2", "kind" to "audio", "bytesSent" to BigInteger.valueOf(999_999)),
        s("inbound-rtp", "I1", "kind" to "video", "bytesReceived" to BigInteger.valueOf(received), "frameWidth" to 640L, "frameHeight" to 360L),
    )

    @Test fun firstSampleHasNoRatesThenDeltasInKbps() {
        val (first, sample) = parseMediaStats(report(10_000, 5_000), prev = null, nowMs = 1_000)
        assertEquals(1_234L, first.availableOutgoingKbps)
        assertEquals(0L, first.sentVideoKbps)
        assertEquals(1280 to 720, first.sentWidth to first.sentHeight)
        assertEquals(640 to 360, first.receivedWidth to first.receivedHeight)
        val (second, _) = parseMediaStats(report(10_000 + 125_000, 5_000 + 62_500), sample, nowMs = 2_000)
        assertEquals(1_000L, second.sentVideoKbps)     // 125 000 B in 1 s = 1000 kbit/s
        assertEquals(500L, second.receivedVideoKbps)
    }

    @Test fun nominatedPairWhenNoTransportAndNullWithoutPair() {
        val noTransport = report(0, 0).filterKeys { it != "T1" && it != "CP2" }
        assertEquals(99L, parseMediaStats(noTransport, null, 0).first.availableOutgoingKbps)
        assertNull(parseMediaStats(emptyMap(), null, 0).first.availableOutgoingKbps)
    }
}
```

- [ ] **Step 2: Run — fails** (`Unresolved reference: parseMediaStats`).

- [ ] **Step 3: `StatsParse.kt`:**

```kotlin
package app.ottermsg.feature.calls

import app.ottermsg.core.data.calls.MediaStats
import org.webrtc.RTCStats

/** Byte counters of the previous [parseMediaStats] call: bit rates are deltas over the elapsed time. */
data class StatsSample(val atMs: Long, val sentBytes: Long, val receivedBytes: Long)

/** One `getStats` report → [MediaStats] (D126). uint64 members arrive as BigInteger, uint32 as Long: read as Number. */
fun parseMediaStats(stats: Map<String, RTCStats>, prev: StatsSample?, nowMs: Long): Pair<MediaStats, StatsSample> {
    fun RTCStats.num(k: String): Long? = (members[k] as? Number)?.toLong()
    val selected = stats.values.firstOrNull { it.type == "transport" }?.members?.get("selectedCandidatePairId") as? String
    val pair = selected?.let { stats[it] }
        ?: stats.values.firstOrNull { it.type == "candidate-pair" && it.members["nominated"] == true && it.members["state"] == "succeeded" }
    val available = (pair?.members?.get("availableOutgoingBitrate") as? Number)?.toDouble()?.let { (it / 1000).toLong() }
    val out = stats.values.filter { it.type == "outbound-rtp" && it.members["kind"] == "video" }
    val inb = stats.values.filter { it.type == "inbound-rtp" && it.members["kind"] == "video" }
    val sent = out.sumOf { it.num("bytesSent") ?: 0L }
    val received = inb.sumOf { it.num("bytesReceived") ?: 0L }
    val dt = prev?.let { nowMs - it.atMs }?.takeIf { it > 0 }
    fun kbps(now: Long, before: Long?): Long = if (dt == null || before == null) 0 else (now - before).coerceAtLeast(0) * 8 / dt
    val o = out.firstOrNull()
    val i = inb.firstOrNull()
    return MediaStats(available, kbps(sent, prev?.sentBytes), kbps(received, prev?.receivedBytes),
        o?.num("frameWidth")?.toInt() ?: 0, o?.num("frameHeight")?.toInt() ?: 0,
        i?.num("frameWidth")?.toInt() ?: 0, i?.num("frameHeight")?.toInt() ?: 0) to StatsSample(nowMs, sent, received)
}
```

- [ ] **Step 4: Run** `./gradlew :feature:calls:testDebugUnitTest --tests '*StatsParseTest'` → PASS.

- [ ] **Step 5: `VideoSinks.kt`:**

```kotlin
package app.ottermsg.feature.calls

import org.webrtc.EglBase
import org.webrtc.VideoSink
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Where the call screen shows video (D128). One EGL context for the process (hardware encoders/decoders, the camera's
 * texture helper and both renderers share it); the engine writes frames to [local]/[remote], which the UI points at
 * its SurfaceViewRenderers while they exist.
 */
@Singleton
class VideoSinks @Inject constructor() {
    val egl: EglBase by lazy { EglBase.create() }
    @Volatile var local: VideoSink? = null
    @Volatile var remote: VideoSink? = null
}
```

- [ ] **Step 6: Replace `WebRtcEngine.kt`** with (the M8 parts are unchanged except where marked):

```kotlin
package app.ottermsg.feature.calls

import android.content.Context
import app.ottermsg.core.data.calls.CallTimers
import app.ottermsg.core.data.calls.Candidate
import app.ottermsg.core.data.calls.IcePhase
import app.ottermsg.core.data.calls.IceServerSpec
import app.ottermsg.core.data.calls.MediaEngine
import app.ottermsg.core.data.calls.MediaListener
import app.ottermsg.core.data.calls.MediaStats
import app.ottermsg.core.data.calls.PathInfo
import app.ottermsg.core.data.calls.VideoProfile
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.webrtc.AudioSource
import org.webrtc.AudioTrack
import org.webrtc.Camera2Enumerator
import org.webrtc.CameraVideoCapturer
import org.webrtc.DataChannel
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.MediaStreamTrack
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RTCStatsReport
import org.webrtc.RtpTransceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoCapturer
import org.webrtc.VideoSink
import org.webrtc.VideoSource
import org.webrtc.VideoTrack
import org.webrtc.audio.JavaAudioDeviceModule
import java.util.logging.Logger
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * WebRTC M150 engine (D76/D77, video D125–D128): Opus mono with DTX, one audio and one video transceiver in every call
 * (unified plan, max-bundle: one ICE transport, one TURN allocation), ICE policy RELAY when «Звонки только через
 * сервер» is on. Video: the camera is attached with RtpSender.setTrack and detached with setTrack(null), never a new
 * offer. One instance per call.
 */
class WebRtcEngine(
    private val context: Context,
    private val sinks: VideoSinks,
    /** false = behave like a 0.11 app (audio only, no video factories); Task 11's test plays an old peer with it. */
    private val video: Boolean = true,
    /** Tests: a frame source instead of the camera (front = which side was asked for). */
    private val capturers: ((front: Boolean) -> VideoCapturer?)? = null,
) : MediaEngine {
    private var factory: PeerConnectionFactory? = null
    private var adm: JavaAudioDeviceModule? = null
    private var source: AudioSource? = null
    @Volatile private var pc: PeerConnection? = null
    @Volatile private var track: AudioTrack? = null
    @Volatile private var listener: MediaListener? = null
    @Volatile private var trickle = false
    @Volatile private var gatheringDone: CompletableDeferred<Unit>? = null
    // ---- video (M10) ----
    @Volatile private var videoTx: RtpTransceiver? = null
    private var videoSource: VideoSource? = null
    @Volatile private var videoTrack: VideoTrack? = null
    private var capturer: VideoCapturer? = null
    private var textures: SurfaceTextureHelper? = null
    @Volatile private var remoteVideo: VideoTrack? = null
    @Volatile private var cameraOn = false
    @Volatile private var paused = false
    @Volatile private var saver = false
    @Volatile private var front = true
    @Volatile private var remoteActive = false
    @Volatile private var lastRemoteFrameNs = 0L
    private var lastSample: StatsSample? = null

    private val localSink = VideoSink { f -> sinks.local?.onFrame(f) }
    private val remoteSink = VideoSink { f ->
        lastRemoteFrameNs = System.nanoTime()
        if (!remoteActive) { remoteActive = true; listener?.onRemoteVideo(true) }
        sinks.remote?.onFrame(f)
    }
    private val cameraEvents = object : CameraVideoCapturer.CameraEventsHandler {
        override fun onCameraError(e: String?) { log.warning("camera error: $e"); if (cameraOn) listener?.onCameraError() }
        override fun onCameraDisconnected() { if (cameraOn) listener?.onCameraError() }
        override fun onCameraFreezed(e: String?) { log.warning("camera frozen: $e") }
        override fun onCameraOpening(name: String?) {}
        override fun onFirstFrameAvailable() {}
        override fun onCameraClosed() {}
    }

    override suspend fun open(servers: List<IceServerSpec>, relayOnly: Boolean, listener: MediaListener) = withContext(Dispatchers.Default) {
        init(context)
        this@WebRtcEngine.listener = listener
        val a = JavaAudioDeviceModule.builder(context)
            .setUseHardwareAcousticEchoCanceler(JavaAudioDeviceModule.isBuiltInAcousticEchoCancelerSupported())
            .setUseHardwareNoiseSuppressor(JavaAudioDeviceModule.isBuiltInNoiseSuppressorSupported())
            .setUseStereoInput(false).setUseStereoOutput(false)
            .createAudioDeviceModule().also { adm = it }
        val b = PeerConnectionFactory.builder().setAudioDeviceModule(a)
        if (video) {
            val egl = sinks.egl.eglBaseContext
            // hardware H.264/VP8 when the phone has it, software VP8 otherwise (D125); H.264 High off: baseline is safest
            b.setVideoEncoderFactory(DefaultVideoEncoderFactory(egl, true, false))
                .setVideoDecoderFactory(DefaultVideoDecoderFactory(egl))
        }
        val f = b.createPeerConnectionFactory().also { factory = it }
        val ice = servers.map {
            PeerConnection.IceServer.builder(it.urls).setUsername(it.username).setPassword(it.password)
                // the node's TURN TLS certificate is not checked: media is DTLS-SRTP end to end and the
                // fingerprints travel only inside the Signal-encrypted offer/answer (D77)
                .setTlsCertPolicy(PeerConnection.TlsCertPolicy.TLS_CERT_POLICY_INSECURE_NO_CHECK)
                .createIceServer()
        }
        val cfg = PeerConnection.RTCConfiguration(ice).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            iceTransportsType = if (relayOnly) PeerConnection.IceTransportsType.RELAY else PeerConnection.IceTransportsType.ALL
            bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE
            rtcpMuxPolicy = PeerConnection.RtcpMuxPolicy.REQUIRE
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
        }
        val p = f.createPeerConnection(cfg, observer) ?: error("createPeerConnection failed")
        pc = p
        val s = f.createAudioSource(MediaConstraints()).also { source = it }
        val t = f.createAudioTrack("a0", s).also { track = it }
        p.addTrack(t, listOf("s0"))
        Unit
    }

    override suspend fun offer(restart: Boolean): String {
        val p = checkNotNull(pc)
        // M10: the caller adds the video section once; it stays for ICE restarts (no renegotiation for the camera)
        if (video && videoTx == null) videoTx = p.addTransceiver(MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO,
            RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.SEND_RECV, listOf("s0")))
        attachRemote()
        if (restart) p.restartIce()
        val sdp = suspendSdp { p.createOffer(it, MediaConstraints()) }
        return setLocalAndGather(p, SessionDescription(sdp.type, tuneOpus(sdp.description)))
    }

    override suspend fun answer(remoteOffer: String): String {
        val p = checkNotNull(pc)
        suspendSet { p.setRemoteDescription(it, SessionDescription(SessionDescription.Type.OFFER, remoteOffer)) }
        // M10: a remote video section created its own transceiver (JSEP matches only addTrack ones): make it sendrecv.
        // An offer from an app before 0.12.0 has no video section → no transceiver → peerVideo() false.
        if (video && videoTx == null) videoTx = p.transceivers.firstOrNull {
            it.mediaType == MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO && !it.isStopped
        }?.also { it.setDirection(RtpTransceiver.RtpTransceiverDirection.SEND_RECV) }
        attachRemote()
        val sdp = suspendSdp { p.createAnswer(it, MediaConstraints()) }
        val local = setLocalAndGather(p, SessionDescription(sdp.type, tuneOpus(sdp.description)))
        applyCaps()
        return local
    }

    override suspend fun applyAnswer(sdp: String) {
        val p = checkNotNull(pc)
        suspendSet { p.setRemoteDescription(it, SessionDescription(SessionDescription.Type.ANSWER, sdp)) }
        attachRemote()
        applyCaps()
    }

    override fun addCandidates(c: List<Candidate>) { c.forEach { pc?.addIceCandidate(IceCandidate(it.sdpMid, it.mLineIndex, it.sdp)) } }
    override fun setMuted(muted: Boolean) { track?.setEnabled(!muted) }

    /** An app before 0.12.0 answers our video section recvonly (or rejects it): only sendrecv means video works. */
    override fun peerVideo(): Boolean = videoTx?.currentDirection == RtpTransceiver.RtpTransceiverDirection.SEND_RECV

    override suspend fun setCamera(on: Boolean) = withContext(Dispatchers.Default) {
        if (on == cameraOn) return@withContext
        if (on) startCamera() else stopCamera()
    }

    override suspend fun setPaused(paused: Boolean) = withContext(Dispatchers.Default) {
        this@WebRtcEngine.paused = paused
        applySending()
    }

    override suspend fun setSaver(saver: Boolean) = withContext(Dispatchers.Default) {
        this@WebRtcEngine.saver = saver
        val prof = VideoProfile.of(saver)
        if (cameraOn) {
            videoSource?.adaptOutputFormat(prof.width, prof.height, prof.fps)
            runCatching { capturer?.changeCaptureFormat(prof.width, prof.height, prof.fps) }
        }
        applyCaps()
    }

    override suspend fun switchCamera(): Boolean? {
        val cap = capturer as? CameraVideoCapturer ?: return null
        return suspendCancellableCoroutine { cont ->
            cap.switchCamera(object : CameraVideoCapturer.CameraSwitchHandler {
                override fun onCameraSwitchDone(isFront: Boolean) { front = isFront; if (cont.isActive) cont.resume(isFront) }
                override fun onCameraSwitchError(e: String?) { log.warning("switch failed: $e"); if (cont.isActive) cont.resume(null) }
            })
        }
    }

    override suspend fun stats(): MediaStats? {
        val p = pc ?: return null
        val report = suspendCancellableCoroutine<RTCStatsReport> { cont -> p.getStats { r -> if (cont.isActive) cont.resume(r) } }
        val (st, sample) = parseMediaStats(report.statsMap, lastSample, System.nanoTime() / 1_000_000)
        lastSample = sample
        if (remoteActive && System.nanoTime() - lastRemoteFrameNs > REMOTE_IDLE_NS) {
            remoteActive = false
            listener?.onRemoteVideo(false)
        }
        return st
    }

    override suspend fun path(): PathInfo? = suspendCancellableCoroutine { cont ->
        val p = pc ?: return@suspendCancellableCoroutine cont.resume(null)
        p.getStats { report ->
            val stats = report.statsMap
            val pair = stats.values.firstOrNull {
                it.type == "candidate-pair" && it.members["nominated"] == true && it.members["state"] == "succeeded"
            }
            val local = pair?.let { stats[it.members["localCandidateId"] as? String] }
            val path = when {
                local == null -> null
                local.members["candidateType"] == "relay" -> "relay-" + ((local.members["relayProtocol"] as? String) ?: "udp")
                else -> "direct"
            }
            val rtt = ((pair?.members?.get("currentRoundTripTime") as? Double) ?: 0.0) * 1000
            if (cont.isActive) cont.resume(path?.let { PathInfo(it, rtt.toLong()) })
        }
    }

    override fun close() {
        listener = null; trickle = false
        cameraOn = false
        val cap = capturer; capturer = null
        runCatching { cap?.stopCapture() }; runCatching { cap?.dispose() }
        runCatching { remoteVideo?.removeSink(remoteSink) }; remoteVideo = null
        runCatching { videoTrack?.removeSink(localSink) }
        runCatching { pc?.dispose() }; pc = null; videoTx = null // also disposes the audio sender's track
        track = null
        runCatching { videoTrack?.dispose() }; videoTrack = null  // ours: setTrack(…, takeOwnership = false)
        runCatching { videoSource?.dispose() }; videoSource = null
        runCatching { textures?.dispose() }; textures = null
        runCatching { source?.dispose() }; source = null
        runCatching { factory?.dispose() }; factory = null
        runCatching { adm?.release() }; adm = null
        remoteActive = false; lastSample = null
    }

    // ---- video internals ----

    private fun startCamera() {
        val f = factory ?: return
        val cap = capturers?.invoke(front) ?: cameraCapturer(front)
        if (cap == null) { listener?.onCameraError(); return }
        val src = videoSource ?: f.createVideoSource(false).also { videoSource = it }
        val tex = textures ?: SurfaceTextureHelper.create("otter-camera", sinks.egl.eglBaseContext).also { textures = it }
        cap.initialize(tex, context.applicationContext, src.capturerObserver)
        val prof = VideoProfile.of(saver)
        src.adaptOutputFormat(prof.width, prof.height, prof.fps)
        cap.startCapture(prof.width, prof.height, prof.fps)
        if (videoTrack == null) videoTrack = f.createVideoTrack("v0", src).also { it.addSink(localSink) }
        capturer = cap
        cameraOn = true
        applySending()
        applyCaps()
    }

    private fun stopCamera() {
        cameraOn = false
        applySending()
        val cap = capturer; capturer = null
        runCatching { cap?.stopCapture() }
        runCatching { cap?.dispose() }
    }

    /** The front camera (or the back one, or any) by name; null when the phone has no camera. */
    private fun cameraCapturer(wantFront: Boolean): CameraVideoCapturer? {
        val e = Camera2Enumerator(context)
        val names = e.deviceNames
        val name = names.firstOrNull { if (wantFront) e.isFrontFacing(it) else e.isBackFacing(it) } ?: names.firstOrNull() ?: return null
        front = e.isFrontFacing(name)
        return e.createCapturer(name, cameraEvents)
    }

    /** Video RTP flows only while the camera is on and not paused (D125: setTrack, no renegotiation). */
    private fun applySending() {
        val s = videoTx?.sender ?: return
        s.setTrack(if (cameraOn && !paused) videoTrack else null, false)
    }

    /** The cap (D126) on the sender's encoding; WebRTC's congestion control adapts below it. */
    private fun applyCaps() {
        val s = videoTx?.sender ?: return
        val prof = VideoProfile.of(saver)
        val params = s.parameters
        if (params.encodings.isEmpty()) return
        params.encodings.forEach { it.maxBitrateBps = prof.maxBitrateBps; it.maxFramerate = prof.fps; it.scaleResolutionDownBy = 1.0 }
        if (!s.setParameters(params)) log.warning("video caps not applied")
    }

    private fun attachRemote() {
        val t = videoTx?.receiver?.track() as? VideoTrack ?: return
        if (remoteVideo === t) return
        remoteVideo?.removeSink(remoteSink)
        t.addSink(remoteSink)
        remoteVideo = t
    }

    /** Sets the local description and waits ≤ 2 s for candidates (D81); later ones are trickled. */
    private suspend fun setLocalAndGather(p: PeerConnection, sdp: SessionDescription): String {
        trickle = false
        gatheringDone = CompletableDeferred()
        suspendSet { p.setLocalDescription(it, sdp) }
        withTimeoutOrNull(CallTimers.GATHER_MS) { gatheringDone?.await() }
        trickle = true
        return p.localDescription.description // includes the candidates gathered so far
    }

    private val observer = object : PeerConnection.Observer {
        override fun onIceCandidate(c: IceCandidate) { if (trickle) listener?.onCandidate(Candidate(c.sdpMid, c.sdpMLineIndex, c.sdp)) }
        override fun onIceGatheringChange(s: PeerConnection.IceGatheringState) {
            if (s == PeerConnection.IceGatheringState.COMPLETE) gatheringDone?.complete(Unit)
        }
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
        override fun onRenegotiationNeeded() {} // setTrack never needs it; the camera never renegotiates (D125)
    }

    private suspend fun suspendSdp(block: (SdpObserver) -> Unit): SessionDescription = suspendCancellableCoroutine { cont ->
        block(object : SdpObserver {
            override fun onCreateSuccess(d: SessionDescription) { if (cont.isActive) cont.resume(d) }
            override fun onCreateFailure(e: String?) { if (cont.isActive) cont.resumeWithException(IllegalStateException(e)) }
            override fun onSetSuccess() {}
            override fun onSetFailure(e: String?) {}
        })
    }

    private suspend fun suspendSet(block: (SdpObserver) -> Unit): Unit = suspendCancellableCoroutine { cont ->
        block(object : SdpObserver {
            override fun onCreateSuccess(d: SessionDescription) {}
            override fun onCreateFailure(e: String?) {}
            override fun onSetSuccess() { if (cont.isActive) cont.resume(Unit) }
            override fun onSetFailure(e: String?) { if (cont.isActive) cont.resumeWithException(IllegalStateException(e)) }
        })
    }

    companion object {
        /** No remote frame for this long → onRemoteVideo(false) (checked in [stats], once a second). */
        private const val REMOTE_IDLE_NS = 2_000_000_000L
        private val log = Logger.getLogger("WebRtcEngine")
        @Volatile private var initialized = false
        @Synchronized fun init(context: Context) {
            if (initialized) return
            PeerConnectionFactory.initialize(
                PeerConnectionFactory.InitializationOptions.builder(context.applicationContext).createInitializationOptions())
            initialized = true
        }
    }
}
```

  Notes: `applyCaps()` runs after negotiation (encodings exist then) and again when the camera starts or the saver
  changes. If M9 changed parts of the M8 engine, keep M9's changes and add the M10 parts.

- [ ] **Step 7: `CallModule.kt`** — the factory gets the sinks:

```kotlin
    @Provides fun mediaEngines(@ApplicationContext c: Context, sinks: VideoSinks): MediaEngine.Factory =
        MediaEngine.Factory { WebRtcEngine(c, sinks) }
```

  (import `app.ottermsg.feature.calls.VideoSinks`).

- [ ] **Step 8: Run** the Verify command → `BUILD SUCCESSFUL`.

- [ ] **Step 9: Commit**

```bash
git add feature/calls/src/main/kotlin/app/ottermsg/feature/calls/ feature/calls/src/test/kotlin/app/ottermsg/feature/calls/StatsParseTest.kt app/src/main/java/app/ottermsg/calls/CallModule.kt
oc -m "calls: WebRTC video — track-less sendrecv transceiver, setTrack camera, caps, switch, stats, shared EGL (M10, D125/D126)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Android — instrumented loopback smoke test

**Goal:** On an emulator two real `WebRtcEngine`s in one process connect over loopback; a camera (a Y4M file through
`FileVideoCapturer`) turned on at one end delivers frames to the other; after `setTrack(null)` no video bytes are sent;
an "old" audio-only engine is detected in both directions.

**Files:**
- Modify: `otter-android/feature/calls/build.gradle.kts` (runner + androidTest deps)
- Create: `otter-android/feature/calls/src/androidTest/AndroidManifest.xml`
- Create: `otter-android/feature/calls/src/androidTest/kotlin/app/ottermsg/feature/calls/VideoLoopbackTest.kt`

**Acceptance Criteria:**
- [ ] Before `setCamera(true)` the receiver sees 0 frames; after it ≥ 10 frames within 15 s, `onRemoteVideo(true)`,
  `receivedVideoKbps > 0`, `receivedHeight > 0`; both ends `peerVideo() == true`.
- [ ] After `setPaused(true)` the sender's `sentVideoKbps == 0` and the receiver's frame count stops; the receiver gets
  `onRemoteVideo(false)`; `setPaused(false)` brings frames back.
- [ ] New caller ↔ old (`video = false`) callee and old caller ↔ new callee: the new side's `peerVideo() == false`.
- [ ] Passes on the API 34 and API 30 emulators.

**Verify:** with an emulator running: `cd otter-android && ANDROID_SERIAL=emulator-5554 ./gradlew :feature:calls:connectedDebugAndroidTest` → `BUILD SUCCESSFUL`, report shows 2 tests passed

**Steps:**

- [ ] **Step 1: Build config.** In `feature/calls/build.gradle.kts` `defaultConfig { minSdk = 26; testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner" }` and add to `dependencies`:

```kotlin
    androidTestImplementation(libs.junit); androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit); androidTestImplementation(libs.coroutines.test)
```

  `feature/calls/src/androidTest/AndroidManifest.xml` (sockets and the audio device module of the test APK):

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.RECORD_AUDIO" />
</manifest>
```

- [ ] **Step 2: The test** `VideoLoopbackTest.kt` (it is the failing test: before Task 10 it does not compile; with
  Task 10's engine it must pass — if it fails, debug the engine, not the test):

```kotlin
package app.ottermsg.feature.calls

import android.Manifest
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import app.ottermsg.core.data.calls.Candidate
import app.ottermsg.core.data.calls.IcePhase
import app.ottermsg.core.data.calls.MediaListener
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.webrtc.FileVideoCapturer
import org.webrtc.VideoSink
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

/** M10 Task 11: two engines in one process over loopback host candidates (no TURN). */
@RunWith(AndroidJUnit4::class)
class VideoLoopbackTest {
    private val ctx = InstrumentationRegistry.getInstrumentation().targetContext
    private val engines = mutableListOf<WebRtcEngine>()

    private class Events : MediaListener {
        val connected = CompletableDeferred<Unit>()
        @Volatile var remoteVideo = false
        override fun onIce(phase: IcePhase) { if (phase == IcePhase.CONNECTED) connected.complete(Unit) }
        override fun onCandidate(c: Candidate) {}
        override fun onRemoteVideo(active: Boolean) { remoteVideo = active }
        override fun onCameraError() {}
    }

    @Before fun grant() {
        InstrumentationRegistry.getInstrumentation().uiAutomation.grantRuntimePermission(ctx.packageName, Manifest.permission.RECORD_AUDIO)
    }

    @After fun close() { engines.forEach { it.close() } }

    /** 320×240 I420, 30 frames of changing grey (FileVideoCapturer loops it). */
    private val y4m: String by lazy {
        val f = File(ctx.cacheDir, "m10-test.y4m")
        f.outputStream().use { o ->
            o.write("YUV4MPEG2 W320 H240 F30:1 C420\n".toByteArray())
            repeat(30) { i -> o.write("FRAME\n".toByteArray()); o.write(ByteArray(320 * 240 * 3 / 2) { (i * 8).toByte() }) }
        }
        f.path
    }

    private fun engine(sinks: VideoSinks, video: Boolean = true) =
        WebRtcEngine(ctx, sinks, video, capturers = { FileVideoCapturer(y4m) }).also { engines += it }

    private suspend fun connect(caller: WebRtcEngine, ec: Events, callee: WebRtcEngine, ee: Events) {
        caller.open(emptyList(), relayOnly = false, listener = ec)
        callee.open(emptyList(), relayOnly = false, listener = ee)
        val offer = caller.offer(false)
        val answer = callee.answer(offer)
        caller.applyAnswer(answer)
        withTimeout(20_000) { ec.connected.await(); ee.connected.await() }
    }

    @Test fun cameraFramesReachThePeerAndStopWithTheTrack() = runBlocking {
        val sa = VideoSinks(); val sb = VideoSinks()
        val frames = AtomicInteger()
        sb.remote = VideoSink { frames.incrementAndGet() }
        val ea = Events(); val eb = Events()
        val a = engine(sa); val b = engine(sb)
        connect(a, ea, b, eb)
        assertTrue(a.peerVideo()); assertTrue(b.peerVideo())
        delay(2_000)
        assertEquals("nothing is sent before the camera is turned on", 0, frames.get())

        a.setCamera(true)
        withTimeout(15_000) { while (frames.get() < 10) delay(100) }
        assertTrue(eb.remoteVideo)
        b.stats(); delay(1_000)
        val rx = b.stats()!!
        assertTrue("received ${rx.receivedVideoKbps} kbit/s", rx.receivedVideoKbps > 0)
        assertTrue(rx.receivedHeight > 0)

        a.setPaused(true)                       // RtpSender.setTrack(null)
        delay(2_000); a.stats(); delay(1_000)
        assertEquals("video bytes sent after setTrack(null)", 0L, a.stats()!!.sentVideoKbps)
        val before = frames.get(); delay(2_000)
        assertEquals("frames after setTrack(null)", before, frames.get())
        withTimeout(6_000) { while (eb.remoteVideo) { b.stats(); delay(500) } }

        a.setPaused(false)
        withTimeout(10_000) { while (frames.get() <= before) delay(100) }
        a.setCamera(false)
    }

    @Test fun anOldPeerIsDetectedBothWays() = runBlocking {
        val newCaller = engine(VideoSinks()); val oldCallee = engine(VideoSinks(), video = false)
        connect(newCaller, Events(), oldCallee, Events())
        assertFalse("an old app answers our video section recvonly or rejects it", newCaller.peerVideo())

        val oldCaller = engine(VideoSinks(), video = false); val newCallee = engine(VideoSinks())
        connect(oldCaller, Events(), newCallee, Events())
        assertFalse("an old offer has no video section", newCallee.peerVideo())
    }
}
```

- [ ] **Step 3: Run** the Verify command on `m8_api34` (start it with `emulator -avd m8_api34 -no-snapshot-save &`;
  `adb wait-for-device`), then on `m8_api30` (`ANDROID_SERIAL=emulator-5556`). Record both results in
  `otter-android/docs/m10-manual-test.md` (Task 16). If the second `JavaAudioDeviceModule` in one process fails to open
  the emulator microphone, the call still connects (WebRTC logs the error); the test does not depend on audio.

- [ ] **Step 4: Commit**

```bash
git add feature/calls/build.gradle.kts feature/calls/src/androidTest/
oc -m "calls: instrumented loopback test — frames arrive, none after setTrack(null), old peers detected (M10)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 12: Android — call screen (renderers, local tile, buttons, notices, speaker default)

**Goal:** The call screen shows the remote video full screen and the local preview as a small draggable, mirrored
(front camera) tile; offers camera, switch (only while on) and «Экономить трафик» buttons next to mute/speaker/end;
shows «У собеседника старая версия», «Видео приостановлено: слабая связь», «Нет доступа к камере» (with a link to the
settings) and, over the lock screen, no video; moves the audio to the speaker the first time video appears in a call.

**Files:**
- Modify: `otter-android/feature/calls/src/main/kotlin/app/ottermsg/feature/calls/CallViewModel.kt` (`VideoUi`, `videoUi`, `pipWanted`, actions, speaker rule, `atEar`)
- Modify: `otter-android/feature/calls/src/main/kotlin/app/ottermsg/feature/calls/CallScreen.kt`
- Create: `otter-android/feature/calls/src/main/kotlin/app/ottermsg/feature/calls/VideoView.kt`
- Modify: `otter-android/feature/calls/src/main/kotlin/app/ottermsg/feature/calls/CallAudio.kt`
- Modify: `otter-android/feature/calls/src/main/res/values/strings.xml`, `values-en/strings.xml`
- Test: `otter-android/feature/calls/src/test/kotlin/app/ottermsg/feature/calls/VideoUiTest.kt` (new), `CallScreenVideoTest.kt` (new), `CallStatusTest.kt`

**Acceptance Criteria:**
- [ ] `videoUi`: camera button HIDDEN unless Outgoing/Connecting/Active; DISABLED for an old peer; remote video only
  after answering (Connecting/Active) and never when `locked`; local tile only while the camera is on and not locked;
  notice priority OLD_PEER > NO_CAMERA > LOCKED > WEAK_LINK; `mirrorLocal = front`; `pipWanted` = Active and remote
  video shown.
- [ ] `CallScreen`: the camera button calls `onCamera` only when tapped; incoming shows neither camera button nor video;
  disabled button + «У собеседника старая версия»; «Нет доступа к камере» + «Настройки» → `onOpenSettings`; LOCKED
  notice + «Разблокировать» → `onUnlock`; `pip = true` shows only the remote video (or the avatar), no buttons.
- [ ] `CallAudio.speakerForVideo`: earpiece (or unknown) → speaker when available; Bluetooth/wired/speaker → no change;
  `preferSpeakerForVideo()` acts once per call (reset by `reset()`).
- [ ] No proximity screen-off while video is on.

**Verify:** `cd otter-android && ./gradlew :feature:calls:testDebugUnitTest` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing tests.** `VideoUiTest.kt`:

```kotlin
package app.ottermsg.feature.calls

import app.ottermsg.core.data.calls.CallId
import app.ottermsg.core.data.calls.CallState
import app.ottermsg.core.data.calls.Peer
import app.ottermsg.core.data.calls.RemoteMedia
import app.ottermsg.core.data.calls.VideoState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoUiTest {
    private val id = CallId("00".repeat(16))
    private val peer = Peer.of(ByteArray(16) { 1 }, "Мама")
    private val incoming = CallState.Incoming(id, peer, "sdp", 0)
    private val outgoing = CallState.Outgoing(id, peer, ringing = true, sinceMs = 0)
    private val active = CallState.Active(id, peer, true, startMs = 0)
    private val theirVideo = VideoState(peerVideo = true, remote = RemoteMedia(true, false), remoteFrames = true)

    @Test fun ringingShowsNoVideoAndNoCameraButton() {
        val v = videoUi(incoming, theirVideo, locked = false)
        assertEquals(CameraButton.HIDDEN, v.cameraButton)
        assertFalse(v.showRemote); assertFalse(v.showLocal); assertFalse(pipWanted(incoming, v))
    }

    @Test fun remoteVideoOnlyAfterAnsweringAndPipOnlyWhenActive() {
        assertFalse(videoUi(outgoing, theirVideo, false).showRemote)
        val v = videoUi(active, theirVideo, false)
        assertTrue(v.showRemote); assertTrue(pipWanted(active, v)); assertNull(v.notice)
        assertEquals(CameraButton.OFF, v.cameraButton)
    }

    @Test fun theLockScreenShowsNoVideo() {
        val v = videoUi(active, theirVideo.copy(cameraOn = true), locked = true)
        assertFalse(v.showRemote); assertFalse(v.showLocal); assertFalse(v.canSwitch)
        assertEquals(VideoNotice.LOCKED, v.notice); assertFalse(pipWanted(active, v))
    }

    @Test fun cameraOnShowsTheMirroredTileAndSwitch() {
        val v = videoUi(active, VideoState(peerVideo = true, cameraOn = true, front = true), false)
        assertEquals(CameraButton.ON, v.cameraButton); assertTrue(v.showLocal); assertTrue(v.canSwitch); assertTrue(v.mirrorLocal)
        assertFalse(videoUi(active, VideoState(peerVideo = true, cameraOn = true, front = false), false).mirrorLocal)
    }

    @Test fun noticesInPriorityOrder() {
        assertEquals(VideoNotice.OLD_PEER, videoUi(active, VideoState(peerVideo = false, cameraDenied = true), false).notice)
        assertEquals(CameraButton.DISABLED, videoUi(active, VideoState(peerVideo = false), false).cameraButton)
        assertEquals(VideoNotice.NO_CAMERA, videoUi(active, VideoState(peerVideo = true, cameraDenied = true, netPaused = true), false).notice)
        assertEquals(VideoNotice.WEAK_LINK, videoUi(active, VideoState(peerVideo = true, cameraOn = true, netPaused = true), false).notice)
        assertEquals(VideoNotice.WEAK_LINK, videoUi(active, VideoState(peerVideo = true, remote = RemoteMedia(true, true)), false).notice)
        assertEquals(CameraButton.HIDDEN, videoUi(CallState.Idle, VideoState(peerVideo = false), false).cameraButton)
        assertNull(videoUi(CallState.Idle, VideoState(peerVideo = false), false).notice)
    }
}
```

  `CallScreenVideoTest.kt`:

```kotlin
package app.ottermsg.feature.calls

import androidx.compose.foundation.layout.Box
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import app.ottermsg.core.ui.theme.OtterTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "ru")
class CallScreenVideoTest {
    @get:Rule val compose = createComposeRule()
    private val inCall = CallUi(name = "Мама", status = CallStatus.Timer(5), inCall = true)
    private var taps = 0
    private var settings = 0
    private var unlocks = 0

    private fun show(ui: CallUi, pip: Boolean = false) = compose.setContent {
        OtterTheme {
            CallScreen(ui, onAccept = {}, onDecline = {}, onHangUp = {}, onMute = {}, onSpeaker = {},
                onCamera = { taps++ }, onOpenSettings = { settings++ }, onUnlock = { unlocks++ }, pip = pip,
                remoteVideo = { m -> Box(m) }, localVideo = { m -> Box(m) })
        }
    }

    @Test fun theCameraButtonCallsBackOnlyOnATap() {
        show(inCall.copy(video = VideoUi(cameraButton = CameraButton.OFF)))
        compose.waitForIdle()
        assertEquals("nothing but a tap may ask for the camera", 0, taps)
        compose.onNodeWithContentDescription("Камера").performClick()
        assertEquals(1, taps)
    }

    @Test fun incomingHasNoCameraButtonAndNoVideo() {
        show(CallUi(name = "Мама", status = CallStatus.Incoming, incoming = true))
        compose.onNodeWithContentDescription("Камера").assertDoesNotExist()
        compose.onNodeWithTag(REMOTE_VIDEO_TAG).assertDoesNotExist()
        compose.onNodeWithTag(LOCAL_VIDEO_TAG).assertDoesNotExist()
    }

    @Test fun remoteVideoLocalTileAndSwitch() {
        show(inCall.copy(video = VideoUi(cameraButton = CameraButton.ON, canSwitch = true, showRemote = true, showLocal = true)))
        compose.onNodeWithTag(REMOTE_VIDEO_TAG).assertExists()
        compose.onNodeWithTag(LOCAL_VIDEO_TAG).assertExists()
        compose.onNodeWithContentDescription("Сменить камеру").assertExists()
        compose.onNodeWithContentDescription("Экономить трафик").assertExists()
    }

    @Test fun anOldPeerDisablesTheCameraButton() {
        show(inCall.copy(video = VideoUi(cameraButton = CameraButton.DISABLED, notice = VideoNotice.OLD_PEER)))
        compose.onNodeWithContentDescription("Камера").assertIsNotEnabled()
        compose.onNodeWithText("У собеседника старая версия").assertExists()
    }

    @Test fun noticesAndTheirActions() {
        show(inCall.copy(video = VideoUi(cameraButton = CameraButton.OFF, notice = VideoNotice.NO_CAMERA)))
        compose.onNodeWithText("Нет доступа к камере").assertExists()
        compose.onNodeWithText("Настройки").performClick()
        assertEquals(1, settings)
    }

    @Test fun weakLinkNotice() {
        show(inCall.copy(video = VideoUi(cameraButton = CameraButton.ON, notice = VideoNotice.WEAK_LINK)))
        compose.onNodeWithText("Видео приостановлено: слабая связь").assertExists()
    }

    @Test fun lockedShowsTheUnlockButtonAndNoVideo() {
        show(inCall.copy(video = VideoUi(cameraButton = CameraButton.ON, notice = VideoNotice.LOCKED)))
        compose.onNodeWithText("Разблокируйте телефон, чтобы видеть видео").assertExists()
        compose.onNodeWithTag(REMOTE_VIDEO_TAG).assertDoesNotExist()
        compose.onNodeWithText("Разблокировать").performClick()
        assertEquals(1, unlocks)
    }

    @Test fun pictureInPictureShowsOnlyTheVideo() {
        show(inCall.copy(video = VideoUi(cameraButton = CameraButton.ON, showRemote = true, showLocal = true)), pip = true)
        compose.onNodeWithTag(REMOTE_VIDEO_TAG).assertExists()
        compose.onNodeWithTag(LOCAL_VIDEO_TAG).assertDoesNotExist()
        compose.onNodeWithContentDescription("Завершить звонок").assertDoesNotExist()
    }
}
```

  Append to `CallStatusTest.kt`:

```kotlin
    @Test fun videoMovesOnlyTheEarpieceToTheSpeaker() {
        assertEquals(TYPE_SPEAKER, CallAudio.speakerForVideo(TYPE_EARPIECE, listOf(TYPE_EARPIECE, TYPE_SPEAKER)))
        assertEquals(TYPE_SPEAKER, CallAudio.speakerForVideo(null, listOf(TYPE_SPEAKER)))
        assertNull(CallAudio.speakerForVideo(TYPE_BLUETOOTH, listOf(TYPE_BLUETOOTH, TYPE_SPEAKER)))
        assertNull(CallAudio.speakerForVideo(TYPE_WIRED_HEADSET, listOf(TYPE_WIRED_HEADSET, TYPE_SPEAKER)))
        assertNull(CallAudio.speakerForVideo(TYPE_SPEAKER, listOf(TYPE_SPEAKER)))
        assertNull(CallAudio.speakerForVideo(TYPE_EARPIECE, listOf(TYPE_EARPIECE)))
    }
```

- [ ] **Step 2: Run — fails** (`Unresolved reference: videoUi`, `VideoUi`, `speakerForVideo`, …).

- [ ] **Step 3: Strings.** `feature/calls/src/main/res/values/strings.xml` (ru) and `values-en/strings.xml`:

| name | ru | en |
|---|---|---|
| `call_camera` | Камера | Camera |
| `call_switch_camera` | Сменить камеру | Switch camera |
| `call_saver` | Экономить трафик | Save data |
| `call_old_peer` | У собеседника старая версия | The other person has an old version |
| `call_video_paused` | Видео приостановлено: слабая связь | Video paused: weak connection |
| `call_no_camera` | Нет доступа к камере | No access to the camera |
| `call_open_settings` | Настройки | Settings |
| `call_video_locked` | Разблокируйте телефон, чтобы видеть видео | Unlock the phone to see video |
| `call_unlock` | Разблокировать | Unlock |

- [ ] **Step 4: `CallViewModel.kt`.** Add (top level, after `CallUi`), and give `CallUi` a field `val video: VideoUi = VideoUi()`:

```kotlin
enum class CameraButton { HIDDEN, OFF, ON, DISABLED }
enum class VideoNotice { OLD_PEER, NO_CAMERA, LOCKED, WEAK_LINK }

data class VideoUi(
    val cameraButton: CameraButton = CameraButton.HIDDEN,
    val canSwitch: Boolean = false,
    val saver: Boolean = false,
    val showRemote: Boolean = false,
    val showLocal: Boolean = false,
    val mirrorLocal: Boolean = true,
    val notice: VideoNotice? = null,
)

/** Pure mapping (unit-tested). D127: no camera while ringing, remote video only after answering, nothing when locked. */
fun videoUi(state: CallState, v: VideoState, locked: Boolean): VideoUi {
    val inCall = state is CallState.Outgoing || state is CallState.Connecting || state is CallState.Active
    val answered = state is CallState.Connecting || state is CallState.Active
    val button = when {
        !inCall -> CameraButton.HIDDEN
        v.peerVideo == false -> CameraButton.DISABLED
        v.cameraOn -> CameraButton.ON
        else -> CameraButton.OFF
    }
    val notice = when {
        !inCall -> null
        v.peerVideo == false -> VideoNotice.OLD_PEER
        v.cameraDenied -> VideoNotice.NO_CAMERA
        locked && (v.cameraOn || (answered && v.showRemote)) -> VideoNotice.LOCKED
        answered && v.weakLink -> VideoNotice.WEAK_LINK
        else -> null
    }
    return VideoUi(button, canSwitch = v.cameraOn && !locked, saver = v.saver,
        showRemote = answered && !locked && v.showRemote, showLocal = inCall && !locked && v.cameraOn,
        mirrorLocal = v.front, notice = notice)
}

/** Picture-in-picture on leaving the app: only while the peer's video is shown (D128). */
fun pipWanted(state: CallState, v: VideoUi): Boolean = state is CallState.Active && v.showRemote
```

  In `CallViewModel`: add `private val locked = MutableStateFlow(false)`; build the ui from the existing combine plus
  video:

```kotlin
    private val videoFlow = combine(manager.state, manager.video, locked) { s, v, l -> videoUi(s, v, l) }

    val ui: StateFlow<CallUi> = combine(
        combine(manager.state, ticker, endStatus, manager.muted, audio.speaker) { s, now, end, muted, speaker ->
            peerOf(s)?.let { lastPeer = it }
            if (s is CallState.Active) lastActiveStart = s.startMs
            val p = lastPeer
            CallUi(p?.name.orEmpty(), p?.id ?: ByteArray(0), if (s == CallState.Idle) end ?: CallStatus.None else callStatus(s, now),
                incoming = s is CallState.Incoming, inCall = s != CallState.Idle && s !is CallState.Incoming, muted = muted, speaker = speaker)
        },
        videoFlow,
    ) { u, v -> u.copy(video = v) }.stateIn(viewModelScope, SharingStarted.Eagerly, CallUi())

    val pipWanted: StateFlow<Boolean> = combine(manager.state, videoFlow) { s, v -> pipWanted(s, v) }
        .stateIn(viewModelScope, SharingStarted.Eagerly, false)
```

  `atEar` gains the video condition:

```kotlin
    val atEar: StateFlow<Boolean> = combine(manager.state, audio.earpiece, manager.video) { s, ear, v ->
        ear && (s is CallState.Connecting || s is CallState.Active) && !v.cameraOn && !v.showRemote
    }.stateIn(viewModelScope, SharingStarted.Eagerly, false)
```

  In `init` add the speaker rule:

```kotlin
        viewModelScope.launch {
            combine(manager.state, manager.video) { s, v -> (s is CallState.Connecting || s is CallState.Active) && (v.cameraOn || v.showRemote) }
                .distinctUntilChanged().collect { if (it) runCatching { audio.preferSpeakerForVideo() } }
        }
```

  And the actions:

```kotlin
    /** The camera button, after the activity's permission check (D127). The only caller of CallManager.userCamera. */
    fun cameraTapped(on: Boolean) = manager.userCamera(on)
    fun cameraOn(): Boolean = manager.video.value.cameraOn
    fun cameraDenied() = manager.cameraDenied()
    fun switchCamera() = manager.switchCamera()
    fun toggleSaver() = manager.setSaver(!manager.video.value.saver)
    /** From the activity: started (PiP counts) and not under the lock screen. */
    fun setScreen(visible: Boolean, locked: Boolean) { this.locked.value = locked; manager.setScreenVisible(visible) }
```

  (imports: `app.ottermsg.core.data.calls.VideoState`, `kotlinx.coroutines.flow.distinctUntilChanged`.)

- [ ] **Step 5: `CallAudio.kt`.** Add:

```kotlin
    @Volatile private var videoRouted = false

    /** The first time video appears in a call the speaker becomes the route (D128); later user choices win. */
    suspend fun preferSpeakerForVideo() {
        if (videoRouted) return
        videoRouted = true
        val req = request
        if (req != null) {
            speakerForVideo(current.value?.type, available.value.map { it.type })?.let { t -> available.value.firstOrNull { it.type == t }?.let { req(it) } }
            return
        }
        val fb = fallback ?: return
        if (!fallbackSpeaker.value) { fb(true); fallbackSpeaker.value = true }
    }
```

  in `reset()` add `videoRouted = false`, and in the companion:

```kotlin
        /** Video: earpiece (or not known yet) → speaker; a headset, Bluetooth or the speaker already stays. */
        fun speakerForVideo(current: Int?, available: List<Int>): Int? =
            if (current == null || current == CallEndpointCompat.TYPE_EARPIECE) CallEndpointCompat.TYPE_SPEAKER.takeIf { it in available } else null
```

- [ ] **Step 6: `VideoView.kt`:**

```kotlin
package app.ottermsg.feature.calls

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import org.webrtc.RendererCommon
import org.webrtc.SurfaceViewRenderer

/** A WebRTC renderer for the peer's video ([remote]) or the local preview; registers itself in [sinks] while shown. */
@Composable
fun VideoView(sinks: VideoSinks, remote: Boolean, mirror: Boolean, modifier: Modifier = Modifier) {
    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            SurfaceViewRenderer(ctx).apply {
                init(sinks.egl.eglBaseContext, null)
                setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FILL)
                setEnableHardwareScaler(true)
                if (!remote) setZOrderMediaOverlay(true) // the tile is drawn above the full-screen remote surface
                if (remote) sinks.remote = this else sinks.local = this
            }
        },
        update = { it.setMirror(mirror) },
        onRelease = { r ->
            if (remote) { if (sinks.remote === r) sinks.remote = null } else if (sinks.local === r) sinks.local = null
            r.release()
        },
    )
}
```

- [ ] **Step 7: `CallScreen.kt`.** Add the tags and new parameters, the video layer, buttons, notices, tile and PiP
  content. `CallRoute` passes the real renderers:

```kotlin
const val REMOTE_VIDEO_TAG = "call_remote_video"
const val LOCAL_VIDEO_TAG = "call_local_video"

@Composable
fun CallRoute(vm: CallViewModel, sinks: VideoSinks?, pip: Boolean, onAccept: () -> Unit, onCamera: () -> Unit,
              onOpenSettings: () -> Unit, onUnlock: () -> Unit) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    val warn by vm.warnPeer.collectAsStateWithLifecycle()
    CallScreen(ui, onAccept = onAccept, onDecline = vm::decline, onHangUp = vm::hangUp, onMute = vm::toggleMute,
        onSpeaker = vm::toggleSpeaker, onCamera = onCamera, onSwitchCamera = vm::switchCamera, onSaver = vm::toggleSaver,
        onOpenSettings = onOpenSettings, onUnlock = onUnlock, pip = pip,
        remoteVideo = { m -> if (sinks != null) VideoView(sinks, remote = true, mirror = false, modifier = m) },
        localVideo = { m -> if (sinks != null) VideoView(sinks, remote = false, mirror = ui.video.mirrorLocal, modifier = m) })
    if (warn != null && !pip) {
        AlertDialog(
            onDismissRequest = vm::cancelCallBack,
            text = { Text(stringResource(R.string.call_no_push)) },
            confirmButton = { TextButton(onClick = vm::confirmCallBack) { Text(stringResource(R.string.call_anyway)) } },
            dismissButton = { TextButton(onClick = vm::cancelCallBack) { Text(stringResource(R.string.call_cancel)) } },
        )
    }
}

@Composable
fun CallScreen(
    ui: CallUi, onAccept: () -> Unit, onDecline: () -> Unit, onHangUp: () -> Unit, onMute: () -> Unit, onSpeaker: () -> Unit,
    onCamera: () -> Unit = {}, onSwitchCamera: () -> Unit = {}, onSaver: () -> Unit = {},
    onOpenSettings: () -> Unit = {}, onUnlock: () -> Unit = {}, pip: Boolean = false,
    remoteVideo: @Composable (Modifier) -> Unit = {}, localVideo: @Composable (Modifier) -> Unit = {},
) {
    val v = ui.video
    if (pip) { PipContent(ui, remoteVideo); return }
    val onVideo = v.showRemote
    val fg = if (onVideo) Color.White else MaterialTheme.colorScheme.onSurface
    Surface(Modifier.fillMaxSize(), color = if (onVideo) Color.Black else MaterialTheme.colorScheme.background) {
        Box(Modifier.fillMaxSize()) {
            if (onVideo) remoteVideo(Modifier.fillMaxSize().testTag(REMOTE_VIDEO_TAG))
            Column(Modifier.fillMaxSize().safeDrawingPadding().padding(Dimens.screenGutter), horizontalAlignment = Alignment.CenterHorizontally) {
                if (onVideo) {
                    Text(ui.name, style = MaterialTheme.typography.titleMedium, color = fg, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(statusText(ui.status), style = MaterialTheme.typography.bodyMedium, color = fg,
                        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                    Spacer(Modifier.weight(1f))
                } else {
                    Spacer(Modifier.weight(1f))
                    if (ui.name.isNotEmpty()) OtterAvatar(ui.name, ui.seed, size = 96.dp)
                    Spacer(Modifier.height(Dimens.s24))
                    Text(ui.name, style = MaterialTheme.typography.headlineMedium, maxLines = 2, overflow = TextOverflow.Ellipsis,
                        textAlign = TextAlign.Center, color = fg)
                    Spacer(Modifier.height(Dimens.s8))
                    Text(statusText(ui.status), style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                    Spacer(Modifier.weight(2f))
                }
                v.notice?.let { VideoNoticeRow(it, if (onVideo) Color.White else MaterialTheme.colorScheme.onSurfaceVariant, onOpenSettings, onUnlock) }
                if (ui.inCall && v.cameraButton != CameraButton.HIDDEN) VideoButtons(v, onCamera, onSwitchCamera, onSaver)
                Row(Modifier.fillMaxWidth().padding(bottom = Dimens.s32), horizontalArrangement = Arrangement.SpaceEvenly,
                    verticalAlignment = Alignment.CenterVertically) {
                    when {
                        ui.incoming -> {
                            RoundButton(Icons.Filled.CallEnd, stringResource(R.string.call_decline), HangUpRed, onDecline)
                            RoundButton(Icons.Filled.Call, stringResource(R.string.call_accept), AcceptGreen, onAccept)
                        }
                        ui.inCall -> {
                            FilledIconToggleButton(checked = ui.muted, onCheckedChange = { onMute() }, modifier = Modifier.size(64.dp)) {
                                Icon(if (ui.muted) Icons.Filled.MicOff else Icons.Filled.Mic, stringResource(R.string.call_mute))
                            }
                            RoundButton(Icons.Filled.CallEnd, stringResource(R.string.call_hang_up), HangUpRed, onHangUp)
                            FilledIconToggleButton(checked = ui.speaker, onCheckedChange = { onSpeaker() }, modifier = Modifier.size(64.dp)) {
                                Icon(Icons.AutoMirrored.Filled.VolumeUp, stringResource(R.string.call_speaker))
                            }
                        }
                        else -> Box(Modifier.size(72.dp))
                    }
                }
            }
            if (v.showLocal) LocalTile(localVideo)
        }
    }
}

@Composable
private fun VideoButtons(v: VideoUi, onCamera: () -> Unit, onSwitchCamera: () -> Unit, onSaver: () -> Unit) {
    val enabled = v.cameraButton != CameraButton.DISABLED
    Row(Modifier.fillMaxWidth().padding(bottom = Dimens.s16), horizontalArrangement = Arrangement.SpaceEvenly,
        verticalAlignment = Alignment.CenterVertically) {
        FilledIconToggleButton(checked = v.cameraButton == CameraButton.ON, onCheckedChange = { onCamera() }, enabled = enabled,
            modifier = Modifier.size(56.dp)) {
            Icon(if (v.cameraButton == CameraButton.ON) Icons.Filled.Videocam else Icons.Filled.VideocamOff, stringResource(R.string.call_camera))
        }
        if (v.canSwitch) FilledIconButton(onClick = onSwitchCamera, modifier = Modifier.size(56.dp)) {
            Icon(Icons.Filled.Cameraswitch, stringResource(R.string.call_switch_camera))
        }
        FilledIconToggleButton(checked = v.saver, onCheckedChange = { onSaver() }, enabled = enabled, modifier = Modifier.size(56.dp)) {
            Icon(if (v.saver) Icons.Filled.DataSaverOn else Icons.Filled.DataSaverOff, stringResource(R.string.call_saver))
        }
    }
}

@Composable
private fun VideoNoticeRow(n: VideoNotice, color: Color, onOpenSettings: () -> Unit, onUnlock: () -> Unit) {
    val text = when (n) {
        VideoNotice.OLD_PEER -> R.string.call_old_peer
        VideoNotice.NO_CAMERA -> R.string.call_no_camera
        VideoNotice.LOCKED -> R.string.call_video_locked
        VideoNotice.WEAK_LINK -> R.string.call_video_paused
    }
    Column(Modifier.fillMaxWidth().padding(bottom = Dimens.s8), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(stringResource(text), style = MaterialTheme.typography.bodyMedium, color = color, textAlign = TextAlign.Center,
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
        when (n) {
            VideoNotice.NO_CAMERA -> TextButton(onClick = onOpenSettings) { Text(stringResource(R.string.call_open_settings)) }
            VideoNotice.LOCKED -> TextButton(onClick = onUnlock) { Text(stringResource(R.string.call_unlock)) }
            else -> {}
        }
    }
}

/** The local preview: 96×160 dp in the top-right corner, draggable inside the screen. */
@Composable
private fun BoxScope.LocalTile(localVideo: @Composable (Modifier) -> Unit) {
    val conf = LocalConfiguration.current
    val density = LocalDensity.current
    val maxX = with(density) { (conf.screenWidthDp.dp - 96.dp - 32.dp).toPx() }.coerceAtLeast(0f)
    val maxY = with(density) { (conf.screenHeightDp.dp - 160.dp - 32.dp).toPx() }.coerceAtLeast(0f)
    var offset by remember { mutableStateOf(Offset.Zero) }
    Box(Modifier.align(Alignment.TopEnd).safeDrawingPadding().padding(Dimens.s16)
        .offset { IntOffset(offset.x.roundToInt(), offset.y.roundToInt()) }
        .size(width = 96.dp, height = 160.dp).clip(RoundedCornerShape(12.dp))
        .pointerInput(Unit) {
            detectDragGestures { change, drag ->
                change.consume()
                offset = Offset((offset.x + drag.x).coerceIn(-maxX, 0f), (offset.y + drag.y).coerceIn(0f, maxY))
            }
        }
        .testTag(LOCAL_VIDEO_TAG)) { localVideo(Modifier.fillMaxSize()) }
}

@Composable
private fun PipContent(ui: CallUi, remoteVideo: @Composable (Modifier) -> Unit) {
    Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
        if (ui.video.showRemote) remoteVideo(Modifier.fillMaxSize().testTag(REMOTE_VIDEO_TAG))
        else if (ui.name.isNotEmpty()) OtterAvatar(ui.name, ui.seed, size = 56.dp)
    }
}
```

  Imports to add: `androidx.compose.foundation.background`, `androidx.compose.foundation.gestures.detectDragGestures`,
  `androidx.compose.foundation.layout.BoxScope`, `androidx.compose.foundation.layout.offset`,
  `androidx.compose.foundation.shape.RoundedCornerShape`, `androidx.compose.material.icons.filled.{Videocam, VideocamOff, Cameraswitch, DataSaverOn, DataSaverOff}`,
  `androidx.compose.runtime.{mutableStateOf, remember, setValue}`, `androidx.compose.ui.draw.clip`,
  `androidx.compose.ui.geometry.Offset`, `androidx.compose.ui.input.pointer.pointerInput`,
  `androidx.compose.ui.platform.{LocalConfiguration, LocalDensity, testTag}` (`testTag` is `androidx.compose.ui.platform.testTag`),
  `androidx.compose.ui.unit.IntOffset`, `kotlin.math.roundToInt`.

- [ ] **Step 8: Keep `:app` compiling.** In `CallActivity.onCreate` change the `CallRoute` call to
  `CallRoute(vm, sinks = null, pip = false, onAccept = ::accept, onCamera = {}, onOpenSettings = {}, onUnlock = {})`
  (no camera path yet; Task 13 wires the real one). Run the Verify command and `./gradlew :app:assembleDebug` →
  `BUILD SUCCESSFUL`.

- [ ] **Step 9: Commit**

```bash
git add feature/calls/src/ app/src/main/java/app/ottermsg/calls/CallActivity.kt
oc -m "calls: video call screen — remote video, draggable mirrored tile, camera/switch/saver, notices, speaker default (M10, D127/D128)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Android — camera permission, screen-off/background/lock pause, `camera` FGS type

**Goal:** The first camera tap asks for `CAMERA` (refusal → «Нет доступа к камере» with the settings link); the call
service adds the `camera` foreground-service type only while the camera is on (added right after the tap, while the
activity is visible — Android 14 rules); the camera stops sending when the screen is off, the app is in the
background without PiP, or the lock screen is up, and resumes when the call screen is visible and unlocked again.

**Files:**
- Modify: `otter-android/app/src/main/java/app/ottermsg/calls/CallActivity.kt`
- Modify: `otter-android/app/src/main/java/app/ottermsg/calls/CallService.kt` (`foregroundType`, camera type, observe `video`)
- Modify: `otter-android/app/src/main/AndroidManifest.xml`
- Test: `otter-android/app/src/test/kotlin/app/ottermsg/calls/CallServiceTypeTest.kt` (new), `otter-android/app/src/androidTest/kotlin/app/ottermsg/SmokeTest.kt`

**Acceptance Criteria:**
- [ ] `foregroundType(sdk, answered, mic, cameraOn, camera)`: phoneCall from API 29; microphone after answering with the
  permission (API 30+); camera only while on **and** granted (API 30+).
- [ ] Manifest: `CAMERA` and `FOREGROUND_SERVICE_CAMERA` declared; `CallService` types `phoneCall|microphone|camera`.
- [ ] `CallActivity` reports `visible = started && !keyguardLocked` on start, resume, stop and `ACTION_USER_PRESENT`; the
  camera button path is `onCameraTapped` → permission → `vm.cameraTapped(true)` / `vm.cameraDenied()`.
- [ ] `./gradlew :app:assembleDebug :app:testDebugUnitTest` green.

**Verify:** `cd otter-android && ./gradlew :app:testDebugUnitTest --tests '*CallServiceTypeTest' --tests '*CallNotifierTest' :app:assembleDebug` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing test** `app/src/test/kotlin/app/ottermsg/calls/CallServiceTypeTest.kt`:

```kotlin
package app.ottermsg.calls

import android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
import android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
import android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
import org.junit.Assert.assertEquals
import org.junit.Test

class CallServiceTypeTest {
    @Test fun cameraTypeOnlyWhileOnAndGranted() {
        fun t(sdk: Int, answered: Boolean, mic: Boolean, cameraOn: Boolean, camera: Boolean) =
            CallService.foregroundType(sdk, answered, mic, cameraOn, camera)
        assertEquals(FOREGROUND_SERVICE_TYPE_PHONE_CALL, t(34, false, true, false, true))                 // ringing
        assertEquals(FOREGROUND_SERVICE_TYPE_PHONE_CALL or FOREGROUND_SERVICE_TYPE_MICROPHONE, t(34, true, true, false, true))
        assertEquals(FOREGROUND_SERVICE_TYPE_PHONE_CALL or FOREGROUND_SERVICE_TYPE_MICROPHONE or FOREGROUND_SERVICE_TYPE_CAMERA,
            t(34, true, true, true, true))
        assertEquals("camera on but not granted", FOREGROUND_SERVICE_TYPE_PHONE_CALL or FOREGROUND_SERVICE_TYPE_MICROPHONE, t(34, true, true, true, false))
        assertEquals("no typed FGS before API 29", 0, t(28, true, true, true, true))
        assertEquals("camera/microphone types from API 30", FOREGROUND_SERVICE_TYPE_PHONE_CALL, t(29, true, true, true, true))
    }
}
```

- [ ] **Step 2: Run — fails** (`Unresolved reference: foregroundType`).

- [ ] **Step 3: `CallService.kt`.** In the companion:

```kotlin
        /** Foreground types (D80, D128): microphone once answered, camera only while it is on and granted (Android 14). */
        internal fun foregroundType(sdk: Int, answered: Boolean, mic: Boolean, cameraOn: Boolean, camera: Boolean): Int {
            var t = if (sdk >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL else 0
            if (answered && sdk >= 30 && mic) t = t or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            if (cameraOn && sdk >= 30 && camera) t = t or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            return t
        }
```

  In `ensureForeground` replace the `mic`/`phone`/`type`/`try … catch` block with:

```kotlin
        val answered = s is CallState.Outgoing || s is CallState.Connecting || s is CallState.Active
        val type = foregroundType(Build.VERSION.SDK_INT, answered, hasMic(), manager.video.value.cameraOn, hasCamera())
        val phone = foregroundType(Build.VERSION.SDK_INT, false, false, false, false)
        // camera/microphone refused (app not visible at that moment): drop the camera first, then keep phoneCall only
        val tries = listOf(type, type and ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA.inv(), phone).distinct()
        var used = phone
        for (t in tries) {
            try { ServiceCompat.startForeground(this, id, n, t); used = t; break }
            catch (e: Exception) { log.log(Level.WARNING, "startForeground type $t refused", e) }
        }
        foregroundKey = id to used
```

  add `private fun hasCamera() = ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED`,
  and in `onCreate` (inside the existing `scope.launch` after `accounts.load()` start a second collector):

```kotlin
        scope.launch {
            // the camera type follows the camera (D128): added right after the tap (activity visible), dropped when off
            manager.video.map { it.cameraOn }.distinctUntilChanged().drop(1).collect {
                if (seenCall) ensureForeground(manager.state.value, force = true)
            }
        }
```

  (imports `kotlinx.coroutines.flow.{map, distinctUntilChanged, drop}`.)

- [ ] **Step 4: Manifest.** Add next to the M8 permissions:

```xml
    <!-- M10 video calls (D128): the camera (also declared by feature:conversation) and the camera FGS type while it is on -->
    <uses-permission android:name="android.permission.CAMERA" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CAMERA" />
```

  and change the service to `android:foregroundServiceType="phoneCall|microphone|camera"`.

- [ ] **Step 5: `CallActivity.kt`.** Add fields, the permission launcher, the visibility report and the camera path;
  `setContent` uses the new `CallRoute` (PiP parameters are filled in Task 14; pass `pip = false` until then):

```kotlin
    @Inject lateinit var sinks: VideoSinks
    private val keyguard by lazy { getSystemService(KeyguardManager::class.java) }
    private var started = false
    private var afterCamera: ((Boolean) -> Unit)? = null
    private val cameraPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val next = afterCamera
        afterCamera = null
        next?.invoke(granted)
    }
    private val unlocked = object : BroadcastReceiver() { override fun onReceive(c: Context, i: Intent) = reportScreen() }
```

  In `onCreate` replace `setContent { … }` with

```kotlin
        setContent {
            OtterTheme {
                CallRoute(vm, sinks, pip = false, onAccept = ::accept, onCamera = ::onCameraTapped,
                    onOpenSettings = ::openAppSettings, onUnlock = ::unlock)
            }
        }
        ContextCompat.registerReceiver(this, unlocked, IntentFilter(Intent.ACTION_USER_PRESENT), ContextCompat.RECEIVER_NOT_EXPORTED)
```

  and add:

```kotlin
    override fun onStart() { super.onStart(); started = true; reportScreen() }
    override fun onResume() { super.onResume(); reportScreen() }
    // existing onStop: add the two lines before setProximity(false)
    //     started = false
    //     reportScreen()
    override fun onDestroy() { runCatching { unregisterReceiver(unlocked) }; super.onDestroy() }

    /** Visible = started (PiP counts) and not under the lock screen: no video on the lock screen (D127). */
    private fun reportScreen() {
        val locked = keyguard.isKeyguardLocked
        vm.setScreen(visible = started && !locked, locked = locked)
    }

    /** The camera button (D127): the only path to vm.cameraTapped (CameraEntryPointsTest); CAMERA on the first tap. */
    private fun onCameraTapped() {
        if (vm.cameraOn()) { vm.cameraTapped(false); return }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) { vm.cameraTapped(true); return }
        afterCamera = { granted -> if (granted) vm.cameraTapped(true) else vm.cameraDenied() }
        cameraPermission.launch(Manifest.permission.CAMERA)
    }

    private fun openAppSettings() {
        runCatching { startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))) }
    }

    private fun unlock() = keyguard.requestDismissKeyguard(this, null)
```

  Imports: `android.app.KeyguardManager`, `android.content.BroadcastReceiver`, `android.content.IntentFilter`,
  `android.net.Uri`, `android.provider.Settings`, `app.ottermsg.feature.calls.VideoSinks`.

- [ ] **Step 6: SmokeTest** (`app/src/androidTest/kotlin/app/ottermsg/SmokeTest.kt`) — append:

```kotlin
    /** M10: the call service may hold the camera; FOREGROUND_SERVICE_CAMERA is declared (Android 14). */
    @Test fun callServiceMayUseTheCamera() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val s = ctx.packageManager.getServiceInfo(android.content.ComponentName(ctx, "app.ottermsg.calls.CallService"), 0)
        assert(s.foregroundServiceType and android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA != 0)
        val requested = ctx.packageManager.getPackageInfo(ctx.packageName, PackageManager.GET_PERMISSIONS).requestedPermissions.orEmpty()
        assert("android.permission.FOREGROUND_SERVICE_CAMERA" in requested)
    }
```

- [ ] **Step 7: Run** the Verify command → `BUILD SUCCESSFUL`. Emulator check (API 34): call between the two emulators
  (dev network of Task 16), tap the camera → permission dialog → allow → local tile; `adb shell dumpsys activity services app.ottermsg | grep -i 'types='`
  shows `camera` while it is on and not after the camera is off; deny on the second emulator → «Нет доступа к камере»,
  «Настройки» opens the app's system page; press the power button → the peer's video disappears within ~2 s; power on
  without unlocking → «Разблокируйте телефон, чтобы видеть видео», no video; unlock → video both ways again.

- [ ] **Step 8: Commit**

```bash
git add app/src/main/java/app/ottermsg/calls/ app/src/main/AndroidManifest.xml app/src/test/kotlin/app/ottermsg/calls/CallServiceTypeTest.kt app/src/androidTest/kotlin/app/ottermsg/SmokeTest.kt
oc -m "calls: camera permission on the first tap, camera FGS type while on, pause when hidden or locked (M10, D127/D128)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: Android — picture-in-picture

**Goal:** While the peer's video is shown, leaving the call screen (home button, `onUserLeaveHint`, auto-enter on
Android 12+) puts the call into a 9:16 picture-in-picture window showing the remote video with an end-call action.

**Files:**
- Modify: `otter-android/app/src/main/java/app/ottermsg/calls/CallActivity.kt`
- Modify: `otter-android/app/src/main/AndroidManifest.xml` (`CallActivity`)
- Create: `otter-android/app/src/main/res/drawable/ic_pip_hang_up.xml`

**Acceptance Criteria:**
- [ ] `CallActivity` declares `android:supportsPictureInPicture="true"` and
  `android:configChanges="screenSize|smallestScreenSize|screenLayout|orientation"` (no recreation on PiP entry/exit).
- [ ] PiP params: aspect 9:16, one `RemoteAction` «Завершить звонок» → `CallActionReceiver.hangUp`, `setAutoEnterEnabled(pipWanted)` on API 31+;
  API 26–30 enter in the user-leave-hint listener while `pipWanted`; nothing on devices without `FEATURE_PICTURE_IN_PICTURE`.
- [ ] In PiP the screen shows only the remote video (Task 12's `pip = true` content); PiP counts as visible (no pause).

**Verify:** `cd otter-android && ./gradlew :app:assembleDebug` → `BUILD SUCCESSFUL`; on the API 34 emulator in a video
call: `adb shell input keyevent KEYCODE_HOME; adb shell dumpsys activity activities | grep -i -m1 pinned` → a line
containing `pinned`; the PiP window's end-call action ends the call on both emulators.

**Steps:**

- [ ] **Step 1: Pure part is tested** (`pipWanted` in Task 12's `VideoUiTest`). Run
  `./gradlew :feature:calls:testDebugUnitTest --tests '*VideoUiTest'` → PASS before touching the activity.

- [ ] **Step 2: Drawable** `app/src/main/res/drawable/ic_pip_hang_up.xml`:

```xml
<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="24dp" android:height="24dp"
    android:viewportWidth="24" android:viewportHeight="24">
    <path android:fillColor="#FFFFFFFF"
        android:pathData="M12,9c-1.6,0 -3.15,0.25 -4.6,0.72v3.1c0,0.39 -0.23,0.74 -0.56,0.9 -0.98,0.49 -1.87,1.12 -2.66,1.85 -0.18,0.18 -0.43,0.28 -0.7,0.28 -0.28,0 -0.53,-0.11 -0.71,-0.29L0.29,13.08c-0.18,-0.17 -0.29,-0.42 -0.29,-0.7 0,-0.28 0.11,-0.53 0.29,-0.71C3.34,8.78 7.46,7 12,7s8.66,1.78 11.71,4.67c0.18,0.18 0.29,0.43 0.29,0.71 0,0.28 -0.11,0.53 -0.29,0.71l-2.48,2.48c-0.18,0.18 -0.43,0.29 -0.71,0.29 -0.27,0 -0.52,-0.11 -0.7,-0.28 -0.79,-0.74 -1.69,-1.36 -2.67,-1.85 -0.33,-0.16 -0.56,-0.5 -0.56,-0.9v-3.1C15.15,9.25 13.6,9 12,9z" />
</vector>
```

- [ ] **Step 3: Manifest.** `CallActivity` element gets
  `android:supportsPictureInPicture="true" android:configChanges="screenSize|smallestScreenSize|screenLayout|orientation"`.

- [ ] **Step 4: `CallActivity.kt`:**

```kotlin
    private val inPip = MutableStateFlow(false)
    @Volatile private var pipWanted = false
```

  In `onCreate`: `setContent` collects the PiP flag —

```kotlin
        setContent {
            OtterTheme {
                val pip by inPip.collectAsStateWithLifecycle()
                CallRoute(vm, sinks, pip, onAccept = ::accept, onCamera = ::onCameraTapped,
                    onOpenSettings = ::openAppSettings, onUnlock = ::unlock)
            }
        }
        addOnPictureInPictureModeChangedListener { inPip.value = it.isInPictureInPictureMode }
        addOnUserLeaveHintListener { if (pipWanted && Build.VERSION.SDK_INT < 31) enterPip() }
        lifecycleScope.launch { vm.pipWanted.collect { pipWanted = it; updatePip() } }
```

  and:

```kotlin
    /** D128: 9:16 window with the peer's video and «Завершить звонок»; auto-enter on Android 12+ while video is shown. */
    private fun pipParams(): PictureInPictureParams {
        val label = getString(CallsR.string.call_hang_up)
        val hang = PendingIntent.getBroadcast(this, PIP_HANG_UP_REQUEST, CallActionReceiver.hangUp(this),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val b = PictureInPictureParams.Builder().setAspectRatio(Rational(9, 16))
            .setActions(listOf(RemoteAction(Icon.createWithResource(this, R.drawable.ic_pip_hang_up), label, label, hang)))
        if (Build.VERSION.SDK_INT >= 31) b.setAutoEnterEnabled(pipWanted)
        return b.build()
    }

    private fun pipSupported() = packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
    private fun updatePip() { if (pipSupported()) runCatching { setPictureInPictureParams(pipParams()) } }
    private fun enterPip() { if (pipSupported()) runCatching { enterPictureInPictureMode(pipParams()) } }
```

  companion: `private const val PIP_HANG_UP_REQUEST = 6` (4 and 5 are the notifier's). Imports:
  `android.app.PendingIntent`, `android.app.PictureInPictureParams`, `android.app.RemoteAction`,
  `android.graphics.drawable.Icon`, `android.util.Rational`, `androidx.compose.runtime.getValue`,
  `androidx.lifecycle.compose.collectAsStateWithLifecycle`, `kotlinx.coroutines.flow.MutableStateFlow`, `app.ottermsg.R`.

- [ ] **Step 5: Run** the Verify command and the emulator check. Also check: PiP closed with its ✕ → the call goes on
  (notification), the peer sees the camera paused (activity stopped → hidden); tapping the ongoing notification
  reopens the full call screen and video resumes.

- [ ] **Step 6: Commit**

```bash
git add app/src/main/java/app/ottermsg/calls/CallActivity.kt app/src/main/AndroidManifest.xml app/src/main/res/drawable/ic_pip_hang_up.xml
oc -m "calls: picture-in-picture with the peer's video and an end-call action (M10, D128)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: Android — privacy guard tests (entry points, notifications)

**Goal:** Two more guards for D127 beyond the machine and UI tests: the only code path to `UserCamera` is the camera
button, and call notifications carry no picture.

**Files:**
- Create: `otter-android/feature/calls/src/test/kotlin/app/ottermsg/feature/calls/CameraEntryPointsTest.kt`
- Modify: `otter-android/app/src/test/kotlin/app/ottermsg/calls/CallNotifierTest.kt`

**Acceptance Criteria:**
- [ ] In every `src/main` Kotlin file of the project: `UserCamera(` is constructed only in `CallManager.kt` (once);
  `.userCamera(` is called only in `CallViewModel.kt`; `.cameraTapped(` is called only in `CallActivity.kt` and only
  inside `onCameraTapped()`, whose reference `::onCameraTapped` appears exactly once, as `onCamera = ::onCameraTapped`.
- [ ] Incoming and ongoing call notifications have no large icon and no `EXTRA_PICTURE`.
- [ ] The full privacy set passes: `VideoPrivacyTest`, `CallManagerVideoTest.answeringWithTheCallersCameraOnNeverOpensOurs`,
  `VideoUiTest.ringingShowsNoVideoAndNoCameraButton`, `VideoUiTest.theLockScreenShowsNoVideo`,
  `CallScreenVideoTest.theCameraButtonCallsBackOnlyOnATap`, `CallScreenVideoTest.incomingHasNoCameraButtonAndNoVideo`,
  this task's two tests.

**Verify:** `cd otter-android && ./gradlew :feature:calls:testDebugUnitTest --tests '*CameraEntryPointsTest' :app:testDebugUnitTest --tests '*CallNotifierTest' :core:data:testDebugUnitTest --tests '*VideoPrivacyTest'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Tests.** `CameraEntryPointsTest.kt`:

```kotlin
package app.ottermsg.feature.calls

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** D127: the camera starts only from the camera button. Every code path to CallEvent.UserCamera is pinned here. */
class CameraEntryPointsTest {
    private val root: File = generateSequence(File("").absoluteFile) { it.parentFile }
        .first { File(it, "settings.gradle.kts").exists() && File(it, "feature").isDirectory }

    private fun mainSources() = root.walkTopDown()
        .filter { it.isFile && it.extension == "kt" && "/src/main/" in it.invariantSeparatorsPath && "/build/" !in it.invariantSeparatorsPath }
        .toList()

    private fun sites(pattern: Regex) = mainSources().flatMap { f ->
        f.readLines().mapIndexedNotNull { i, l -> if (pattern.containsMatchIn(l)) "${f.name}:${i + 1}" else null }
    }

    @Test fun onlyCallManagerBuildsTheTapEvent() {
        val s = sites(Regex("""(?<!class )\bUserCamera\("""))
        assertEquals("UserCamera( built at: $s", listOf("CallManager.kt"), s.map { it.substringBefore(':') })
    }

    @Test fun onlyTheViewModelCallsUserCamera() {
        val s = sites(Regex("""\.userCamera\("""))
        assertEquals("userCamera( called at: $s", setOf("CallViewModel.kt"), s.map { it.substringBefore(':') }.toSet())
    }

    @Test fun onlyTheCameraButtonReachesTheViewModel() {
        val s = sites(Regex("""\.cameraTapped\("""))
        assertEquals("cameraTapped( called at: $s", setOf("CallActivity.kt"), s.map { it.substringBefore(':') }.toSet())
        val activity = mainSources().single { it.name == "CallActivity.kt" }.readText()
        assertEquals(1, Regex("""::onCameraTapped""").findAll(activity).count())
        assertTrue(activity.contains("onCamera = ::onCameraTapped"))
    }

    @Test fun everyCameraTappedCallIsInsideOnCameraTapped() {
        val lines = mainSources().single { it.name == "CallActivity.kt" }.readLines()
        val start = lines.indexOfFirst { it.contains("private fun onCameraTapped()") }
        val end = (start + 1 until lines.size).first { lines[it].startsWith("    }") }
        val calls = lines.indices.filter { lines[it].contains(".cameraTapped(") }
        assertTrue("cameraTapped outside onCameraTapped: lines ${calls.map { it + 1 }} (body ${start + 1}..${end + 1})",
            calls.isNotEmpty() && calls.all { it in start..end })
    }
}
```

  Append to `CallNotifierTest.kt`:

```kotlin
    /** D127: no video (or any picture) in the incoming-call notification or on the lock screen. */
    @Test fun callNotificationsCarryNoPicture() {
        val n = incoming()!!
        assertNull(n.getLargeIcon())
        assertNull(n.extras.get(Notification.EXTRA_PICTURE))
        val o = notifier.ongoingNotification("Мама")
        assertNull(o.getLargeIcon())
        assertNull(o.extras.get(Notification.EXTRA_PICTURE))
    }
```

- [ ] **Step 2: Run** the Verify command. These guard code written in Tasks 7–14; if one fails, the code (not the
  test) is wrong — e.g. a second caller of `userCamera` must be removed.

- [ ] **Step 3: Prove the guard bites.** Temporarily add `vm.cameraTapped(true)` as the first line of
  `CallActivity.accept()` and run `--tests '*CameraEntryPointsTest'` → `everyCameraTappedCallIsInsideOnCameraTapped`
  FAILS naming that line. Remove the line → PASS.

- [ ] **Step 4: Commit**

```bash
git add feature/calls/src/test/kotlin/app/ottermsg/feature/calls/CameraEntryPointsTest.kt app/src/test/kotlin/app/ottermsg/calls/CallNotifierTest.kt
oc -m "calls: privacy guards — the camera button is the only way to the camera; notifications carry no picture (M10, D127)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 16: Versions 0.12.0, emulator acceptance, manual checklists

**Goal:** The app is 0.12.0 (16); everything that can be proven locally is proven on the dev network and two
emulators; both checklists list every spec row with local results and leave the real-network rows to the owner.

**Files:**
- Modify: `otter-android/app/build.gradle.kts:35` (`versionCode = 16; versionName = "0.12.0"`)
- Create: `otter-android/docs/m10-manual-test.md`, `otter-server/docs/m10-manual-test.md`

**Acceptance Criteria:**
- [ ] Server: `make check`; `go test ./internal/meshsim/ -run 'Turn|CallRelay|RelayLogs' -count=3 -race`;
  `scripts_test.sh` in a scratch copy → all green.
- [ ] Android: `./gradlew test lintDebug` green; Task 11's test green on API 34 and API 30 emulators.
- [ ] Local two-node network `x`/`y` with TURN (as in `otter-server/docs/m8-manual-test.md`, "Local two-node run"),
  emulators A (`m8_api34`) and B (`m8_api30`), relay-only on, rows 1–12 of the phone checklist below PASS with a date;
  each node's log shows `turn allocation closed` lines after the calls with peaks ≤ 2000 kbit/s.
- [ ] 0.11.0 → 0.12.0 `adb install -r` keeps account and chats (no Room change).
- [ ] Both checklists exist; owner rows marked "—".

**Verify:** both checklist files exist; every local row has `PASS 2026-…`; `grep -c '| — |' otter-android/docs/m10-manual-test.md` ≥ 6.

**Steps:**

- [ ] **Step 1: Version.** `app/build.gradle.kts`: `versionCode = 16; versionName = "0.12.0"`. Commit:
  `oc -m "app 0.12.0 (versionCode 16)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`.

- [ ] **Step 2: Automated checks** (commands above); fix failures with the systematic-debugging skill.

- [ ] **Step 3: Local run.** Start `x`/`y` with TURN exactly as in `otter-server/docs/m8-manual-test.md` (the nodes run the
  `m10-video` build; `relay_kbps` unset → 2000). Debug builds on A and B, each logged in on a different node. Emulator
  cameras: A `-camera-front emulated -camera-back virtualscene`, B `-camera-front emulated`. Run the rows; for the
  throttle row use `adb -s emulator-5554 emu network speed 200:200` and `adb -s emulator-5554 emu network speed full`.
  For the bit-rate rows read the node logs: `grep '"turn allocation closed"' <node log file>`.

- [ ] **Step 4: Write `otter-android/docs/m10-manual-test.md`** (model: `m8-manual-test.md`: setup paragraph, then the
  table `| # | Step | Expected | Result |`):

| # | Step | Expected |
|---|------|----------|
| 1 | A calls B (relay-only), B answers; A taps the camera the first time | Android asks for the camera on A; after «Разрешить» A shows its tile (mirrored, front); B shows A's video within ~2 s; B's camera stays off; speaker turns on on both |
| 2 | B taps the camera, then «Сменить камеру» on B | both videos; B's tile un-mirrored with the back camera; A sees the back camera |
| 3 | A taps the camera off | A's tile gone; B shows A's avatar within ~2 s |
| 4 | A calls B with A's camera on before B answers; B's screen locked | B's full-screen ringing shows name and buttons only, no video; after Accept B's camera is off and B sees «Разблокируйте телефон, чтобы видеть видео» until unlocked, then A's video |
| 5 | Deny the camera on B (first tap) | «Нет доступа к камере»; «Настройки» opens Otter's system page; after allowing there, the next tap works |
| 6 | «Экономить трафик» on in the call (A camera on), 60 s; then off, 60 s | node log for A's allocation: peak `to_peer` ≤ ~600 kbit/s during saver, ≤ ~1600 kbit/s without |
| 7 | Settings → Подключение → «Экономить трафик в видеозвонках» on; new call, camera on | the in-call saver button is already on; the setting itself is unchanged by in-call toggles |
| 8 | B presses Home while A's video is shown (API 34 and API 30) | B goes into a 9:16 picture-in-picture window with A's video; its end-call action ends the call on both |
| 9 | A (camera on) presses power (screen off), waits 10 s, powers on, unlocks | B shows A's avatar within ~2 s; nothing while locked; A's video back after the unlock without a new permission prompt |
| 10 | Throttle A to 200:200 kbit/s with both cameras on, 60 s; then `network speed full` | both screens «Видео приостановлено: слабая связь» within ~10–15 s, audio continues; after the limit is removed video returns within ~2 min (test bursts) and the notice goes away |
| 11 | A on 0.11.0 (debug build of the M9.5 merge commit: `git worktree add /tmp/otter-0110 <that commit>`) calls B on 0.12.0, and the other way round | calls connect with audio; on the 0.12.0 side the camera button is disabled with «У собеседника старая версия»; the 0.11.0 side shows nothing new |
| 12 | `adb install -r` 0.12.0 over 0.11.0 on B | account and chats kept; the next call works with video |
| 13 | (owner) both phones 0.12.0, relay only, 5-min video call via the relays: camera on/off, switch, PiP, saver | clear video and audio for 5 min; «Журнал подключений» `call:relay-…` |
| 14 | (owner) one phone on a hotspot limited to ~200 kbit/s | the call turns to audio with «Видео приостановлено: слабая связь» on both instead of dropping; video comes back when the limit is removed |
| 15 | (owner) answer while the caller's camera is on | the answering phone's camera stays off; its lock screen and incoming notification show no video |
| 16 | (owner) Bluetooth headset in a video call | audio stays on the headset (no forced speaker) |
| 17 | (owner) «Запрет скриншотов» on (M9) in a video call, then PiP | screenshot black; PiP window black or hidden per Android; the call goes on |
| 18 | (owner) node logs after row 13 | `turn allocation closed … to_peer_peak_kbps` ≤ 2000, `rate_limited` false on a good link |

- [ ] **Step 5: Write `otter-server/docs/m10-manual-test.md`:** sections "Automated checks" (the commands of the
  Acceptance Criteria), "Local run" (which nodes, log lines seen, with example lines whose user tags are replaced by
  `<tag>`), and the rows:

| # | Step | Expected |
|---|------|----------|
| 1 | `make check`, meshsim `Turn|CallRelay|RelayLogs` ×3, `scripts_test.sh` (scratch copy) | ok |
| 2 | local nodes without `relay_kbps` | `turn on` line has `"relay_kbps":2000` |
| 3 | video call on the local nodes, then hang up | one `turn allocation closed` line per allocation, no names or IPs, peaks ≤ 2000 |
| 4 | (owner) every node after `upgrade-all.sh 0.12.0` | `deploy/status.sh` VERSION 0.12.0, TURN on |
| 5 | (owner) `turn-kbps.sh LABEL 2000` on every node | `LABEL: TURN relay_kbps = 2000`; journal `turn on … "relay_kbps":2000` |
| 6 | (owner) after the 5-min video call | `turn allocation closed` lines on the nodes used, peak ≤ 2000, `rate_limited` false |

- [ ] **Step 6: Commit** both checklists (`oc -m "docs: M10 manual checklists" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"` in each repo).

---

### Task 17: Docs — D125–D129, protocol/architecture/operations, roadmap, news draft

**Goal:** The docs describe M10 as built; the 0.12.0 news draft is ready.

**Files:**
- Modify (docs repo, branch `m10-video`): `00-decisions.md`, `02-protocol.md` (Task 1; re-check), `05-transport.md`,
  `06-node-architecture.md` (lines 156, 191, 227: rate 2000; the log line), `07-android-architecture.md`,
  `08-operations.md`, `09-roadmap.md`, `README.md`
- Modify: `otter-server/README.md` (Calls section: video, 2000 kbit/s, log line, `turn-kbps.sh`), `otter-android/README.md` (one paragraph)
- Create: `otter-server/dist/news/0.12.0.md` (gitignored; never delete files in `dist/`)

**Acceptance Criteria:**
- [ ] Five decision rows (numbers shifted if `00-decisions.md` does not end at D124):
  * **D125 Video calls: one video transceiver in every call.** Unified Plan + BUNDLE: same ICE transport and TURN
    allocation, no extra ports. Caller adds `sendrecv` video without a track in `offer()`; answerer makes the
    transceiver created by the remote offer `sendrecv` (JSEP matches only `addTrack` transceivers). Camera on/off/switch
    = `RtpSender.setTrack(track | null)`, never a new offer. `CallMessage.media = 6` → `CallMedia{camera_on, paused}`,
    sent on every change, **not urgent** (the per-sender call-wake budget, M9 Task 46), 2-min expiry. Peer can do
    video ⇔ video `currentDirection == sendrecv` after the exchange (an app before 0.12.0 answers `recvonly` or has no
    video section) → camera button disabled «У собеседника старая версия». Codecs: `DefaultVideoEncoderFactory(egl,
    true, false)` / `DefaultVideoDecoderFactory(egl)` with one shared `EglBase` (hardware H.264/VP8, software VP8
    otherwise; H.264 High off). Rejected: simulcast/SVC, renegotiation per toggle, a separate "video call" type.
  * **D126 Video quality and the weak-link pause.** Caps on the sender encoding + capture format: normal 1280×720,
    30 fps, ≤ 1.5 Mbit/s; «Экономить трафик» 640×360, 20 fps, ≤ 500 kbit/s (Settings default off, per-call button).
    Watchdog on `candidate-pair.availableOutgoingBitrate`, sampled once a second: < 150 kbit/s for 10 s → stop sending
    video (camera and preview stay), both screens «Видео приостановлено: слабая связь». Because the estimate cannot
    rise while only audio flows, resuming uses **test bursts** of video 15 s after the pause, then 30 s, 60 s, every
    2 min: a burst ends after 5 s below 400 kbit/s or at any dip below 400 once above; 15 s ≥ 400 kbit/s resumes. The
    peer keeps showing the notice during a burst (its last `CallMedia` says paused). *(Owner question 1.)*
  * **D127 Video privacy.** Only a `UserCamera(on = true)` event — produced only by the camera button, after the
    permission — can make the state machine emit `StartCamera` (property test + source-scan test). Answering never
    turns the camera on; the camera button is not offered while ringing; remote video only after answering, never on
    the lock screen (the call screen shows «Разблокируйте телефон, чтобы видеть видео») or in any notification. When the
    call screen is not visible or is locked, sending stops and the peer is told `camera_on = false` (the camera stays
    open so returning never needs a camera start); it resumes when the screen is visible and unlocked. Remote display:
    frames are shown if no `CallMedia` has arrived yet in the call (it may be late); after one arrives, it decides
    (off/paused hide stray or burst frames). Media stays DTLS-SRTP with fingerprints only in the encrypted SDP; nodes
    see the bit rate, not the picture.
  * **D128 Android video integration.** `CAMERA` asked on the first camera tap; refusal → «Нет доступа к камере» +
    «Настройки» (app details page). Call FGS adds type `camera` only while the camera is on and granted, right after
    the tap (activity visible — Android 14), dropped when off; manifest `FOREGROUND_SERVICE_CAMERA`. Renderers:
    `SurfaceViewRenderer` (no TextureViewRenderer in the AAR) through the `VideoSinks` holder; remote full screen,
    local 96×160 dp draggable tile, mirrored for the front camera. First video in a call moves an earpiece route to the
    speaker (Bluetooth/wired stay); no proximity screen-off with video. Picture-in-picture 9:16 with «Завершить звонок»
    while remote video is shown (auto-enter API 31+, user-leave hint below); PiP counts as visible. Settings switch
    under «Звонки только через сервер» in «Подключение» (there is no «Звонки» section).
  * **D129 TURN rate for video and per-allocation logging.** `[turn] relay_kbps` default 200 → **2000** per allocation
    and direction (720p + Opus + overhead); worst case per node 41 × 2 Mbit/s ≈ 82 Mbit/s. One `turn allocation closed`
    log line per allocation: TURN user id (hash tag), `duration_s`, avg/peak kbit/s each direction (peak = busiest
    second), rate-limiter drops, `rate_limited`; no names, no addresses. `deploy/turn-kbps.sh LABEL KBPS` sets it with
    `otter-node check`, log confirmation and rollback. Same binary on every node; all nodes before the APK.
- [ ] `09-roadmap.md`: M10 row → "**done YYYY-MM-DD** (see M10 notes; real-network rows open)"; new "## M10 notes"
  (what was built, the JSEP/`recvonly` finding, the test-burst rule, the local results, open owner rows).
- [ ] `06-node-architecture.md`: rate 2000 at lines 156/191/227 and the log line; `08-operations.md`: `turn-kbps.sh`,
  reading `turn allocation closed`, the rollout order; `07-android-architecture.md`: VideoState/VideoWatchdog,
  MediaEngine video calls, VideoSinks, FGS camera type, PiP; `05-transport.md`: video over the same TURN allocation and
  the bit-rate budget.
- [ ] News draft `## ru` / `## en` (below). No IPs, no server names.

**Verify:** `cd docs && scripts/secrets-check.sh` → `secrets check: ok`; `grep -c '^| D12[5-9]' 00-decisions.md` → `5`

**Steps:**

- [ ] **Step 1:** Write the docs; commit on `m10-video` in `docs`:
  `oc -m "docs: M10 video calls (D125–D129), roadmap M10 notes" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`;
  READMEs in the code repos with `oc -m "README: video calls (M10)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`.

- [ ] **Step 2:** `otter-server/dist/news/0.12.0.md`:

```markdown
## ru
Otter 0.12.0
• Видеозвонки! Во время любого звонка нажмите на кнопку камеры — собеседник увидит вас. Камера включается только вашей кнопкой: ни звонок, ни ответ на него камеру не включают.
• При первом нажатии Android спросит доступ к камере — пожалуйста, разрешите.
• Видео зашифровано так же, как голос, и идёт через наш сервер.
• Если связь слабая, видео ставится на паузу, а разговор продолжается голосом. Когда связь улучшится, видео вернётся само.
• «Экономить трафик» (кнопка в звонке и в Настройках → Подключение) делает видео чуть хуже, но в три раза дешевле для мобильного интернета.
• Если выйти из звонка на главный экран, видео собеседника останется в маленьком окошке.
• У собеседника со старой версией видео не будет — попросите его обновиться.

## en
Otter 0.12.0
• Video calls! During any call, tap the camera button and the other person will see you. Only your tap turns the camera on: neither calling nor answering does.
• The first time, Android asks for camera access — please allow it.
• Video is encrypted just like the voice and goes through our server.
• On a weak connection video pauses and the call continues with voice; it comes back by itself when the connection improves.
• "Save data" (button in the call and in Settings → Connection) makes video a bit softer but about three times lighter on mobile data.
• If you leave the call for the home screen, the other person's video stays in a small window.
• If the other person still has the old version, there is no video — ask them to update.
```

---

### Task 18: Final verification; merge after the owner says so

**Goal:** Everything is green on all three `m10-video` branches; the owner approves; branches merge with `--no-ff`.

**Files:** none new.

**Acceptance Criteria:**
- [ ] `otter-server`: `make check` → ok; `go test ./internal/meshsim/ -count=3 -race` → ok; `scripts_test.sh` in a
  scratch copy → `scripts test: ok`; `make release VERSION=0.12.0` builds `dist/otter-node_0.12.0_linux_{amd64,arm64}`
  and `SHA256SUMS` (nothing in `dist/` deleted).
- [ ] `otter-android`: `./gradlew test lintDebug assembleRelease` → BUILD SUCCESSFUL; `connectedDebugAndroidTest` for
  `:feature:calls` and `:app` on API 34 → passed; release APK release-signed (`apksigner verify --print-certs` shows the
  release certificate); ABIs arm64-v8a + armeabi-v7a only; size recorded (WebRTC already in since M8: expect ≤ +1 MB).
- [ ] `scripts/secrets-check.sh` → `secrets check: ok` in `otter-server`, `otter-android`, `docs`.
- [ ] The owner has seen a summary (what changed, privacy tests, checklist status, the owner question answers, open
  owner rows) and said "merge"; then in each repo `git checkout main && git merge --no-ff m10-video && git push`.

**Verify:** `git -C otter-server log --oneline -1 main` (and android, docs) shows the merge commit made after the owner's
approval; the secrets checks printed `ok` immediately before each push.

**Steps:**

- [ ] **Step 1:** Run every check above; fix and re-run until green (verification-before-completion skill).
- [ ] **Step 2:** `make release VERSION=0.12.0`; `./gradlew assembleRelease` (the owner's `keystore.properties` signs
  it; never print or copy the keystore or its passwords). Strip metadata is not needed (no new PNGs; the PiP icon is a
  vector).
- [ ] **Step 3:** Show the owner the summary; wait for "merge". Merge and push all three repos (secrets checks first).

---

### Task 19: Owner rollout — 0.12.0 on every node, `relay_kbps = 2000`, then the APK

**Goal:** Every node runs the same 0.12.0 binary with `relay_kbps = 2000`, confirmed in its own log, **before** the APK
is published; both phones on 0.12.0; the owner's checklist rows filled.

**Files:** none in git (state lives on the servers, in `~/.otter-admin`, on the phones).

**Acceptance Criteria:**
- [ ] `deploy/status.sh` → every node `0.12.0`, `active`, TURN `on`; the gate in Step 4 prints nothing.
- [ ] Every node's newest `turn on` journal line contains `"relay_kbps":2000`.
- [ ] Only then: APK 0.12.0 published; both phones updated via «Обновить»; rows 13–18 (phone) and 4–6 (server) filled.

**Verify:** the owner marks the rows PASS (or records what failed) in both `m10-manual-test.md` files.

**Steps — the owner runs every command himself, in his own terminal, from `~/Documents/Projects/OttterMSG/otter-server`;
Claude explains each step first, reads the pasted output, and never runs anything against a server. Passphrases only
in the owner's terminal.**

- [ ] **Step 1 (owner, read-only): baseline.**

```bash
deploy/status.sh
```

  Expected: one row per node (eeee, and ru-1 if it exists by then) with VERSION `0.11.0`, SERVICE `active`, HELLO `ok`,
  TURN `on`. Anything else: stop and look at it with Claude before going on.

- [ ] **Step 2 (owner): the same binary on every node.**

```bash
ls -l dist/otter-node_0.12.0_linux_amd64 dist/otter-node_0.12.0_linux_arm64 && (cd dist && sha256sum -c SHA256SUMS --ignore-missing)
deploy/upgrade-all.sh 0.12.0 --no-news
```

  Expected: `sha256sum` prints `OK` for both binaries; then for each node `==> upgrading LABEL (…) from 0.11.0 to 0.12.0`,
  `==> backing up the database …`, `==> swapping binaries`, `==> upgraded to 0.12.0`, `==> upgrade of root@… done`, the
  TURN summary `LABEL … upgraded 0.11.0 → 0.12.0, TURN ok`, and finally `==> all selected nodes are on 0.12.0`, exit 0.
  (If M9 changed the script's wording, the meaning is the same: upgraded, health ok, TURN ok.) On eeee, afterwards:
  `ssh root@<eeee> 'ss -ltnp'` still lists the host's other services, and the owner checks that they answer.
  **Rollback of this step:** `deploy/upgrade-all.sh 0.11.0 --no-news` (0.12.0 adds no database migration, so 0.11.0
  runs on the same database; `upgrade.sh` already rolls a node back by itself if its health check fails).

- [ ] **Step 3 (owner): set the video rate on every node, one at a time.**

```bash
deploy/hosts.sh list                      # every node label with its SSH target; a "-" target must be fixed first
for l in $(deploy/hosts.sh list | awk '$2 != "-" {print $1}'); do deploy/turn-kbps.sh "$l" 2000 || break; done
```

  Expected per node: `==> setting relay_kbps = 2000 on LABEL`, then `relay_kbps is 2000`, then
  `==> LABEL: TURN relay_kbps = 2000`. A failure prints
  `relay_kbps not changed on LABEL (node left on its previous config)` and the loop stops; the node is back on its
  old `node.toml` (restored from `node.toml.pre-kbps`) and healthy — show the output to Claude.
  **Rollback of this step:** `deploy/turn-kbps.sh LABEL 200` (back to the M8 rate; same checks).

- [ ] **Step 4 (owner, read-only): gate — no APK until this is clean.**

```bash
deploy/status.sh | awk 'NR > 1 && ($3 != "0.12.0" || $NF != "on")'
deploy/hosts.sh list | while read -r l t p; do
  [ "$t" = "-" ] && { echo "== $l: NO SSH TARGET"; continue; }
  echo "== $l"; ssh -n -p "$p" "$t" "journalctl -u otter-node -o cat --since '-2 h' | grep '\"msg\":\"turn on\"' | tail -1"
done
```

  Expected: the `awk` line prints **nothing** (every node 0.12.0 with TURN on); every node's line contains
  `"relay_kbps":2000`. If a node is missing or shows another rate, repeat Step 2/3 for it (`--only LABEL`) before going on.
  (Columns per `status.sh`'s header: LABEL TARGET VERSION … TURN; if M9 changed the column order, check the VERSION and
  TURN columns by eye instead.)

- [ ] **Step 5 (owner): publish the APK.**

```bash
deploy/release-apk.sh 0.12.0 ~/Documents/Projects/OttterMSG/otter-android/app/build/outputs/apk/release/app-release.apk
```

  Expected: the APK copied to every node and the news dialog with `dist/news/0.12.0.md` (from Task 17); answer it as
  usual. Phones update via «Обновить» in «Новости Выдры». **Rollback:** the APK cannot be pulled back from phones that
  installed it; if 0.12.0 misbehaves, a 0.12.1 fix follows. Nodes stay compatible with 0.11.x phones (audio calls
  unchanged; 0.11.x ignores `CallMedia`).

- [ ] **Step 6 (owner, phones + read-only on nodes): real-network rows.** Phone rows 13–18 of
  `otter-android/docs/m10-manual-test.md`; after row 13 read the bit-rate lines on the node(s) used:

```bash
read -r t p < <(deploy/hosts.sh get eeee)     # and the same for ru-1 if the call used it
ssh -p "$p" "$t" "journalctl -u otter-node -o cat --since '-30 min' | grep '\"turn allocation closed\"'"
```

  Expected: one line per allocation of the call with `to_peer_peak_kbps`/`from_peer_peak_kbps` ≤ 2000 and
  `"rate_limited":false` (also in row 14: there the phone's own link is the bottleneck, not the node). `true` means the
  node's 2000 kbit/s cap cut packets — tell Claude. Record the numbers (user tags replaced by `<tag>`) in `otter-server/docs/m10-manual-test.md`.

---

## Owner questions (each task assumes the recommendation; answer before Task 6)

1. **Resuming video after a weak-link pause needs short test bursts of video.** The spec says "video resumes after 15 s
   above 400 kbit/s", but while only audio flows WebRTC's estimate stays near the audio rate and can never show
   400 kbit/s, so a paused call would stay audio-only for good. **Recommended:** test bursts — 15 s after the pause,
   then 30 s, 60 s and every 2 min, each burst sends video for at most 5 s unless the link already measures ≥ 400 kbit/s,
   and 15 s ≥ 400 kbit/s inside a burst resumes video. On a truly bad link this costs a few seconds of slightly worse
   audio every 2 minutes; the other phone keeps the «Видео приостановлено» notice during a burst. (Alternative: no
   automatic resume — the camera stays paused until either person taps it off and on again.)

**Answer (owner, 2026-11-26):** question 1 — test bursts, as recommended.
