# Roadmap

## Phase 0 — Feasibility proof: complete

- [x] Verify the rootless jailbreak environment.
- [x] Establish reliable development access over OpenSSH.
- [x] Review the TrollRecorder app and its entitlements.
- [x] Build the open CLI core as a rootless package.
- [x] Capture an incoming call, the caller's number and the state transitions.
- [x] Record and listen to the far-end/downlink audio of a real GSM call.

Exit criterion met: call events and downlink audio work on the real device.

## Phase 1 — Call control + duplex capture

Priority: highest.

1. Run `speaker` and `microphone` capture simultaneously during the same call.
2. Verify the duration, channels and content of both files.
3. Add a `call-control` tool to the open CLI project:
   - [x] `status` prototype
   - [x] `answer` prototype
   - [x] `hangup` prototype
   - `reject` later
4. Test with `CTCopyCurrentCalls`, `CTCallGetStatus`, `CTCallAnswer` and `CTCallDisconnect`.
5. Log answer and hang-up timings.

Success criterion: an incoming call can be answered and an active call hung up by a command issued
over SSH, and both audio directions are captured into separate files.

## Phase 2 — Uplink injection gate

Priority: critical.

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

1. Merge `call-monitor` and the recording code into a single long-lived process.
2. Implement the canonical call state machine.
3. Add a local WebSocket server and a pairing key.
4. Implement JSON events and command responses.
5. Stream downlink PCM live.
6. Produce a rootless Debian package and a LaunchDaemon.
7. Add restart-after-crash and log rotation.

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
