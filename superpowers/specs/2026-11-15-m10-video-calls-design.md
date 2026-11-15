# M10 1:1 video calls — design

Approved by the owner 2026-11-15 (brainstorm). Was "M8.5" in the roadmap; renamed **M10** because it is built **after all
of M9** (owner). Extends the M8 audio calls (`2026-11-13-m8-audio-calls-design.md`, D76–D81); everything not mentioned
here stays as in M8. Versions: **app 0.11.0, server 0.11.0** (after M9.4's 0.10.1).

## Owner decisions

1. **Camera can be switched on at any time** in any call. There is no separate "video call" type.
2. **Quality:** up to 720p at ≤ 1.5 Mbit/s, adapted down automatically. A manual «Экономить трафик» limit caps it at
   360p and ≤ 500 kbit/s. It can be set in Settings (default off) and toggled during a call.
3. **Built after M9**, on branches `m10-video` in each repo touched.

## Privacy rules (owner, 2026-11-15)

- **The camera starts only when the local user taps the camera button.** No remote message, node answer or call event
  can open the camera. A test enforces this.
- **Answering never turns the camera on**, even if the caller's camera is on. Remote video is shown only after answering,
  never on the lock screen or in the incoming-call notification.
- Video is end-to-end encrypted like audio (DTLS-SRTP; fingerprints only inside the Signal-encrypted offer/answer). The
  `camera_on` signal is inside the encrypted `CallMessage`.
- Accepted: nodes and providers see the bitrate jump when a camera is on (that video flows, not what it shows).
  Only the peer sees the codec list in the encrypted SDP.

## Approach

WebRTC's own congestion control adapts resolution and bitrate. We add:
- a **cap**: normal 1280×720, 30 fps, ≤ 1500 kbit/s; saver 640×360, 20 fps, ≤ 500 kbit/s.
  The cap is set with `RtpSender` encoding parameters plus the capture format.
- a **pause watchdog**: while the camera is on, if the estimated available outgoing bitrate stays under 150 kbit/s for
  10 s, sending video pauses and the call stays audio. Both screens say «Видео приостановлено: слабая связь». Video
  resumes through short **test bursts** (WebRTC cannot measure spare bandwidth while only audio flows): bursts at 15 s,
  30 s, 60 s and then every 2 min after the pause; a burst stops after 5 s unless the link measures ≥ 400 kbit/s, and
  15 s at ≥ 400 kbit/s resumes video. The other phone keeps the notice during a burst (plan D127). The camera hardware stays open while paused, and the UI keeps showing the
  local preview.

Rejected: simulcast/SVC (made for group calls; wastes uplink in 1:1), our own quality-by-network-type logic.

## Signaling

- **Every new call negotiates one audio and one video transceiver** (Unified Plan, BUNDLE: same ICE transport and the same
  TURN allocation, no extra ports). The video transceiver is `sendrecv` from the start with **no track**: no video
  RTP is sent until a track is attached with `RtpSender.setTrack`. **No renegotiation** when the camera turns on/off or
  switches.
- New `CallMessage.media = 6` → `CallMedia { bool camera_on = 1; bool paused = 2; }`, sent end-to-end like the other call
  messages (same expiry rules as M8 call signaling) but **not urgent**: no push, so camera toggles never use up the
  call-wake budget of M9 Task 46 whenever the local camera state changes. The receiver shows or hides
  the remote video view. Frames that arrive without a `camera_on` are still shown, because the message may be late.
- **Compatibility:** an offer from an older app (audio only) gets an audio-only answer; the camera button is disabled
  with «У собеседника старая версия». An older app answering a video-capable offer answers the video section
  `recvonly`; "the peer can do video" means the negotiated direction is `sendrecv`, and the answering side does not
  create its video transceiver in advance. The new app sees a non-`sendrecv` direction and disables the camera button the same way.
- Codecs: WebRTC defaults with `DefaultVideoEncoderFactory`/`DefaultVideoDecoderFactory` and hardware acceleration enabled
  (`EglBase` shared context). Hardware H.264/VP8 when the phone has it, software VP8 otherwise.

## Android

- `MediaEngine` (interface, JVM-testable) gains:
  - `setCamera(on: Boolean)`
  - `switchCamera()`
  - `setSaver(saver: Boolean)`
  - `stats(): MediaStats?` (available outgoing bitrate, sent/received video bitrate, frame size)
  - `MediaListener.onRemoteVideo(active: Boolean)`

  `WebRtcEngine` implements them with `Camera2Enumerator`, `CameraVideoCapturer`, `SurfaceTextureHelper`, a `VideoSource`
  and track, and `SurfaceViewRenderer` sinks (this WebRTC build has no `TextureViewRenderer`) owned by the UI layer through a small `VideoSinks` holder.
- `CallStateMachine`/`CallManager`:
  - local `cameraOn`, `paused`, `saver` state and remote `cameraOn`;
  - the watchdog (pure Kotlin, driven by `stats()` once a second through the existing timer seam);
  - sending `CallMedia`;
  - **hard rule:** only a `UserCamera(on)` event can produce a `StartCamera` effect.
- Call screen (Compose):
  - remote video fills the screen, with the local preview as a small draggable tile (mirrored for the front camera);
  - buttons: camera, switch camera (only while the camera is on), «Экономить трафик», plus the existing mute, speaker
    and end;
  - when video is on, the speaker becomes the default route (it is the earpiece for audio calls).
- **Picture-in-picture:** the call activity declares `supportsPictureInPicture`. It enters PiP on leaving the app (home
  button / `onUserLeaveHint`, and auto-enter on Android 12+) while remote video is shown; PiP shows the remote video with
  an end-call action.
- **Camera permission:**
  - `CAMERA` is asked the first time the user taps the camera button;
  - a refusal shows «Нет доступа к камере» with a link to the settings;
  - the call foreground service adds type `camera` only while the camera is on (Android 14 rules: start the type after
    the permission is granted and while the activity is visible).
- **Screen off or app in background without PiP:** the camera stops sending (`paused`) and resumes when the call screen
  is visible again.
- The lock screen and incoming-call notification never show video.
- Settings: «Экономить трафик в видеозвонках» (default off) directly under «Звонки только через сервер» in «Подключение».

## Server (same binary on every node; only a setting changes)

- `[turn] relay_kbps` default **200 → 2000** (per allocation, each direction: 720p video + audio + overhead).
  Worst case per node: 41 allocations × 2 Mbit/s ≈ 82 Mbit/s.
- **Per-call bitrate logging:** when an allocation ends, the node logs `turn allocation closed` with the duration, the
  average and peak kbit/s in each direction, and whether the rate limiter dropped packets. The log has no user names; it
  uses the TURN user id, as the M8 logs do.
- Rollout: the owner runs the commands. Install 0.11.0 on every node first, then set `relay_kbps = 2000` (or rely on the
  new default), then release the APK.

## Testing and acceptance

- **JVM:**
  - the state machine, with the camera only started by user events;
  - answering keeps the camera off;
  - remote `CallMedia` shows and hides the remote view;
  - watchdog: pause after 10 s under 150 kbit/s, resume after 15 s over 400 kbit/s, no flapping;
  - the saver cap is applied;
  - old-peer fallback disables the camera button.
- **Fake engine** (`FakeEngine` from M8; video calls recorded in a separate list so M8's exact-call assertions stay valid) extended with the new calls.
- **Instrumented smoke test** on the emulator:
  - `WebRtcEngine` opens two peer connections in one process over loopback, turns a camera on (emulator camera or
    `FileVideoCapturer` fallback), and the other side receives frames;
  - after `setTrack(null)` no video RTP is counted.
- **Server:** config default test, and a bitrate log line in the TURN meshsim test.
- **Owner manual test (both phones on 0.11.0, relay only):**
  1. 5-minute video call over the relays: camera on/off, switch, PiP, saver.
  2. A throttled link (a hotspot limited to about 200 kbit/s) turns into audio with the notice instead of dropping, and
     video comes back when the limit is removed.
  3. Answering with the caller's camera on keeps the answering phone's camera off; the lock screen shows no video.

## Out of scope

- Group video
- Screen sharing
- Recording
- Video messages
- Media over the mesh/REALITY (V2)
- A «Видеозвонок» button that starts with the camera on (possible later as a small addition)
