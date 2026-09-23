# Roadmap

## Phase 0 — Feasibility proof: complete

- [x] Verify the rootless jailbreak environment.
- [x] Establish reliable development access over OpenSSH.
- [x] Review the TrollRecorder app and its entitlements.
- [x] Build the open CLI core as a rootless package.
- [x] Capture an incoming call, the caller's number and the state transitions.
- [x] Record and listen to the far-end/downlink audio of a real GSM call.

Exit criterion met: call events and downlink audio work on the real device.

## Phase 1 — Call control + duplex capture: control half complete

1. [ ] Run `speaker` and `microphone` capture simultaneously during the same call.
2. [ ] Verify the duration, channels and content of both files.
3. Add a `call-control` tool to the open CLI project:
   - [x] `status`
   - [x] `answer`
   - [x] `hangup`
   - [ ] `reject`
4. [x] Test with `CTCopyCurrentCalls`, `CTCallGetStatus`, `CTCallAnswer` and `CTCallDisconnect`.
5. [x] Log answer and hang-up timings — 54 ms and 109 ms on the reference device.

Call control is verified (CB-003). Duplex capture is blocked: the reference device's audio IC has
failed, so no call on it carries audio in either direction. Items 1 and 2 stay open and move to
whichever device replaces it.

## Phase 1b — Audio routing on a programmatic answer

Priority: high, and newly discovered. A call answered with `CTCallAnswer` does not acquire the
audio route that the phone's own answer path gives it: with a Bluetooth headset connected, an
outgoing call routed to the headset while an agent-answered incoming call stayed silent.

In the finished product every call is answered remotely, so this is not a test artifact — it is a
capability the agent needs.

1. Confirm the asymmetry: answer by hand with the headset connected and check that audio reaches it.
2. Try answering through `TUCallCenter` (TelephonyUtilities) instead of `CTCallAnswer`, so
   `callservicesd` performs its normal answer, including route selection.
3. If that is not enough, set the route explicitly after answering.
4. Re-run CB-002 during a call that is audible at the time of recording, which is the first test
   that will actually exercise the tap.

## Phase 2 — Uplink injection gate

Priority: critical. Blocked until phase 1b produces a call with working audio on this device, or
until a device with a healthy audio IC is available.

1. Generate a local test tone or pre-recorded PCM.
2. Investigate feeding that audio into the telephony uplink path without playing it through the
   system speaker.
3. Record that the signal is audible on the other phone and measure the latency.
4. Test echo, gain and audio route changes.

Success criterion: a generated test tone is heard by the far end without any acoustic audio
reaching the iPhone's physical microphone.

If this phase fails, real two-way conversation over the network is technically blocked. Call
notification, remote control and listen-only features remain feasible.

## Phase 3 — iPhone agent

Now the active phase, and deliberately ordered so that everything not involving audio comes first:
none of it depends on the failed audio hardware.

1. [x] Define the control protocol — [PROTOCOL.md](PROTOCOL.md).
2. [x] Merge `call-monitor` and the control code into a single long-lived process.
3. [x] Implement the canonical call state machine, de-duplicated on `callId + state`.
4. [x] Add the NDJSON TCP listener, the pairing token and HMAC authentication.
5. [x] Implement events, commands and `requestId` idempotency.
6. [x] Produce a rootless Debian package and a LaunchDaemon.
7. Add log rotation. Restart-after-crash is handled by the daemon's `KeepAlive`.
8. Stream downlink PCM live — blocked on hardware, last.

Verified on the device (CB-004): a paired client receives live `call.state` events and answers and
ends real calls through the agent. What is left in this phase is hardening — TLS, reconnection and
log rotation — not capability.

Success criterion: without opening any app UI, the service starts after a jailbreak and forwards an
incoming call to the network client.

## Phase 4 — Android PoC

1. Kotlin/Compose project skeleton.
2. Pairing and connection state.
3. Full-screen incoming call notification.
4. Answer/reject/hang up buttons.
5. Downlink playback.
6. Microphone capture and uplink send.
7. Foreground service and reconnection.

Success criterion: end-to-end call handling on a stock Xiaomi 15, without root.

## Phase 5 — Robustness

- Compare Wi-Fi and iPhone hotspot topologies.
- Test with the screen locked and apps closed.
- Handle a second incoming call, call hold and missed calls.
- Test audio route, Bluetooth and speaker changes.
- Measure long calls, power draw and thermals.
- Document package upgrade and clean removal steps.

## The first three concrete engineering tasks

1. [x] Write the `call-control` CLI prototype; [ ] produce a rootless artifact.
2. Complete the dual-channel test and create a new run under `evidence/private`.
3. Build the smallest possible test program for uplink injection.
