# Project status and evidence

Last updated: **23 September 2026**

## Verification matrix

| Capability | Status | Evidence | Next action |
|---|---|---|---|
| Detect an incoming GSM call | Verified | CoreTelephony `kCTCallStatusChangeNotification` | Emit a structured JSON event |
| Read the caller's number | Verified | `Name` and `Address` fields populated | Log masking and Android display |
| Call state transitions | Verified | `Incoming → Answered → Incoming Ended` | Reduce to a single state machine |
| Receive CallKit events | Verified | CallKit notifications for the same call | Correlate with CoreTelephony |
| Capture downlink/far-end audio | Verified | 29.234 s CAF; confirmed by listening | Try live framing |
| Capture microphone/uplink audio | Verified | CB-005: 96.7 s mono uplink alongside the stereo downlink, both audibly correct | Gate on call state and stream it |
| Answer a call programmatically | Verified | CB-003: `ringing → active` in 54 ms, stable | Check the audio route on healthy hardware |
| Hang up a call programmatically | Verified | CB-003: `active → ended` in 109 ms | Expose as an agent command |
| Inject Android audio into the uplink | Critical research | The current CLI only captures; outgoing calls on this device have a working audio path to test against | Validate an audio tap/output path experimentally |
| Local network control channel | Verified | CB-004: paired client received live events and drove two calls | Harden: TLS, reconnection |
| Live downlink streaming | Design | Capture-to-file is proven in both directions | Publish PCM frames to a socket |
| Persistence across reboots | Implemented | `com.callbridge.agent` LaunchDaemon, `RunAtLoad` + `KeepAlive` | Confirm across a reboot; add log rotation |
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

## Programmatic call control — 19 September 2026

A full incoming call was handled without touching the screen (test CB-003):

| Command | Transition | Latency |
|---|---|---|
| `call-control answer` | `ringing → active` | **54 ms**, then stable for 1042 ms |
| `call-control hangup` | `active → ended` | **109 ms** |

Both results were confirmed by a second, independent `call-control status` process and by the
`call-monitor` event log. Answering is measured from issuing `CTCallAnswer` to observing the
`active` state, so ~54 ms is the real cost of the telephony operation; the rest of the end-to-end
latency budget belongs to the network and the Android client.

Getting there required fixing how the transition is observed. `CTCopyCurrentCalls` reads a
client-side cache that CoreTelephony refreshes through notifications, so the original verification
loop — polling that function while sleeping — kept reading the snapshot taken at process start and
reported a call as still ringing for the whole timeout, long after it had been answered and ended.
The tool now registers a `CTTelephonyCenter` observer and drives the run loop, and treats the
notification as authoritative. Any long-lived process built on these APIs needs the same
treatment.

## Device audio fault — 19 September 2026

The reference iPhone 7 has lost its audio path. Calls connect and the call state machine works
perfectly, but no audio passes in either direction and the speaker button is greyed out and
unresponsive. These are the classic symptoms of the iPhone 7 audio IC failure known as "loop
disease", where the solder joints under the audio IC crack.

This is a hardware fault, not a regression in this project: the CB-001 downlink capture on
18 September produced 29 seconds of clean audio on the same device.

Consequences:

- Duplex capture (CB-002) cannot be validated here. The header-only CAF files it produced are the
  correct behavior for a call that carried no audio, not evidence about the capture path.
- Phase 2, uplink injection, cannot be attempted on this device at all.
- Everything that does not involve audio — call events, call control, the network protocol, the
  Android client — remains fully testable, which is why those are being built first.

Resolving it needs microsoldering repair or a second iPhone 7.

## Agent end to end — 23 September 2026

`callbridge-agent` handled two full incoming calls for a client on the Mac (test CB-004): live
`call.state` events over the network, `answer` and `hangup` issued remotely, the phone never
touched. Each state was published exactly once per call, which is the de-duplication holding
against CoreTelephony's repeated identification notifications.

That closes the part of phase 3 that does not involve audio. What remains before the Android client
is hardening rather than capability: TLS, reconnection behavior, and log rotation.

A Bluetooth headset was connected throughout, and it exposed a new problem. An outgoing call the
user dialled themselves routed to the headset and was fully audible in both directions, so the
headset does restore a working audio path around the failed audio IC. But an incoming call answered
through the agent did **not** move to the headset, and carried no audio at all.

So `CTCallAnswer` answers the call at the telephony layer without the audio-route selection that
happens when the call is answered through the phone's own UI. This matters for the product, not
just for testing: in the finished system every call is answered remotely, so whatever normally
picks the route has to be driven explicitly.

It also means the capture question is still open rather than settled. The `call-recorder speaker`
run on 23 September happened during that silent, programmatically answered call, so it says nothing
about whether the tap can see Bluetooth audio.

## Duplex capture — 23 September 2026

Test CB-005 captured both directions of a live call into separate files, each 96.700680 seconds and
audibly correct: a stereo downlink carrying the far end, and a mono uplink carrying the near end.

It had to be done on an **outgoing** call. Incoming calls on this device produce no audio at all —
the speaker button is greyed out and no route can be selected, whether the call is answered by hand
or through the agent — while outgoing calls route to a Bluetooth headset and work normally. The
likely reason is that an outgoing call inherits the already-active route while an incoming call has
to build one, which is what the failed audio IC prevents. The tap does not care how the call was
set up, so testing the capability this way is sound.

Three results worth carrying forward:

- Both directions can be captured, which was never proven before. CB-001 only established the
  downlink.
- Two taps run at once without interfering. The empty files in September were a silent call, not a
  conflict between recorders.
- The streams are frame-locked: both files hold exactly 4,264,500 frames. The channels are
  sample-aligned, so live streaming will not have to correct drift between them.

Two constraints for the agent: the downlink is stereo while the uplink is mono, so audio format
negotiation is per direction; and both taps run continuously rather than only during a call, so
streaming has to be gated on call state.

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
