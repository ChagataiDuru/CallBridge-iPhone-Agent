# Project status and evidence

Last updated: **18 September 2026**

## Verification matrix

| Capability | Status | Evidence | Next action |
|---|---|---|---|
| Detect an incoming GSM call | Verified | CoreTelephony `kCTCallStatusChangeNotification` | Emit a structured JSON event |
| Read the caller's number | Verified | `Name` and `Address` fields populated | Log masking and Android display |
| Call state transitions | Verified | `Incoming → Answered → Incoming Ended` | Reduce to a single state machine |
| Receive CallKit events | Verified | CallKit notifications for the same call | Correlate with CoreTelephony |
| Capture downlink/far-end audio | Verified | 29.234 s CAF; confirmed by listening | Try live framing |
| Capture microphone/uplink audio | Pending | The CLI supports the `microphone` channel | Simultaneous dual-channel test |
| Answer a call programmatically | Prototype ready, device test pending | `cli/call-control.mm`; `CTCallAnswer` | Build the rootless package and test `call-control answer` |
| Hang up a call programmatically | Prototype ready, device test pending | `cli/call-control.mm`; `CTCallDisconnect` | Build the rootless package and test `call-control hangup` |
| Inject Android audio into the uplink | Critical research | The current CLI only captures | Validate an audio tap/output path experimentally |
| Local network control channel | Design | Not implemented yet | Authenticated WebSocket prototype |
| Live downlink streaming | Design | Capture-to-file is proven | Publish PCM frames to a socket |
| Persistence across reboots | Design | A rootless LaunchDaemon is viable | Prepare the `callbridge-agent` plist |
| Stock Android client | Design | Not implemented yet | Kotlin foreground service + Compose screen |
| Reachability over the iPhone hotspot | Pending | Local Wi-Fi/SSH works | Hotspot routing test matrix |

## The successful call test

- Incoming call: `00:53:14.556`
- Answered: `00:53:19.634`
- Ended: `00:53:49.292`
- Ring duration: approximately **5.078 seconds**
- Active conversation: approximately **29.658 seconds**
- CAF content: **29.234 seconds**
- Format: **44,100 Hz, 2 channels, Float32, interleaved PCM**
- Audio data: **10,313,928 bytes**
- Result: QuickTime opened it directly; the far end was clearly audible.

The file duration matching the active conversation closely is strong evidence that the `speaker`
tap starts producing audio when the call becomes active and stops when the call ends.

## Implications for the implementation

CoreTelephony should be the primary source for the number and for cellular call state. CallKit
produces a separate UUID for the same call and can serve as a second observation channel.

`kCTCallIdentificationChangeNotification` can arrive repeatedly for the same state. The agent must
de-duplicate events on at least the combination of `CoreTelephony UniqueStringID + normalized
status`. The state machine should publish these plain transitions:

```text
IDLE → RINGING → ACTIVE → ENDED → IDLE
```

`AudioQueueGetPropertySize (1886547824)` appeared during teardown in the first test. The decimal
value corresponds to the FourCC `prop`. The source ignores this error when the Magic Cookie
property is unavailable; the file closed cleanly and played back. It is therefore not a blocker
for the current test.
