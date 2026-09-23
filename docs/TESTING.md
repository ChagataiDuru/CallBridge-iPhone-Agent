# Test log and reproduction steps

## CB-001 — Incoming call and downlink capture

Date: **18 September 2026**  
Result: **Pass**

### Environment

- iPhone 7 / `iPhone9,3` / `D101AP`
- iOS 15.8.8 (`19H422`)
- Rootless jailbreak, `/var/jb`
- `audio-commands` 0.1
- Tools: `/var/jb/usr/local/bin/call-monitor` and `call-recorder`

### Procedure

1. `call-monitor` was started in the background.
2. `call-recorder speaker` was started while idle.
3. A GSM call was placed to the iPhone from another phone.
4. The call was answered manually after about five seconds.
5. The parties talked for about thirty seconds and the call was ended.
6. The processes were terminated with `SIGINT`; the log and the CAF file were copied to the Mac.

### Results

- CoreTelephony: `Incoming`, `Answered`, `Incoming Ended`
- Caller address: captured; masked in the shareable copy
- CallKit: reported the same lifecycle under a separate UUID
- CAF: 29.234490 seconds; 44,100 Hz; 2 channels; Float32 interleaved
- QuickTime: opened it directly
- Listening check: the far end was clearly audible

Raw files are under `evidence/private/2026-09-18-incoming-call/`; the logs with the number masked
are under `evidence/sanitized/2026-09-18-incoming-call/`.

## CB-002 — Simultaneous speaker + microphone capture

Date attempted: **19 and 23 September 2026**  
Result: **Blocked — cannot be validated on this device**

On 19 September both recorders started correctly and both produced header-only 4 KB CAF files,
because the call carried no audio in either direction: the device's audio IC has failed (see
[STATUS.md](STATUS.md#device-audio-fault--19-september-2026)).

On 23 September the test was retried with a Bluetooth headset. The headset does restore a working
audio path: an outgoing call dialled on the phone routed to it and was audible both ways. The
capture run, however, was made during an incoming call answered through the agent, and that call
never moved to the headset and carried no audio. The resulting 4 KB header therefore says nothing
about the tap — it is the same silent-call result as 19 September, for a different reason.

Both attempts so far have measured a silent call rather than the capture path. The next attempt
must record during a call that is **audible at the time of recording**, which on this device means
answering it by hand so the route reaches the headset.

The procedure below is unchanged and is the one to run on a device with working audio.

### Copying the helpers to the iPhone

In the Mac terminal:

```sh
scp scripts/iphone/start-duplex-capture.sh \
    scripts/iphone/stop-capture.sh \
    mobile@<iphone-ip>:/var/mobile/
```

### Starting the capture

In an SSH session on the iPhone:

```sh
sudo sh /var/mobile/start-duplex-capture.sh
```

The command prints a run directory. Call the phone from another handset, answer, and have both
sides speak in turn. End the call after about 20–30 seconds.

### Stopping the capture

```sh
sudo sh /var/mobile/stop-capture.sh
```

### Fetching to the Mac

From the project root on the Mac:

```sh
sh scripts/mac/fetch-latest-run.sh <iphone-ip>
```

### Acceptance criteria

- `downlink-speaker.caf` must contain the far end clearly.
- `uplink-microphone.caf` must contain the iPhone-side speech clearly.
- The file durations must roughly match the active conversation.
- No call event may be lost while both recorders run together.

This test only verifies that both directions can be **captured**; it does not verify uplink
injection.

## CB-003 — Programmatic answer/hang up

Date: **19 September 2026**  
Result: **Pass**

A full incoming call was answered and ended by command, without touching the screen:

```json
{"ok":true,"command":"answer","fromState":"ringing","toState":"active","observedStates":["ringing","active"],"elapsedMs":54,"stableForMs":1042}
{"ok":true,"command":"hangup","fromState":"active","toState":"ended","observedStates":["active","ended"],"elapsedMs":109}
```

Both were confirmed by an independent `call-control status` run and by the `call-monitor` log.
The no-call baseline behaved as specified: `status` returned `count: 0` with exit `0`, while
`answer` and `hangup` returned `no_matching_call` with exit `3`.

One earlier attempt returned `verification_timeout` with `observedState: ringing` while the event
log showed the call had been answered and then ended 223 ms later. That was the stale-cache defect
in the verification loop, since fixed; the caller hanging up at that moment explained the drop.

Source: `cli/call-control.mm`

### Setup

The `.github/workflows/build-rootless.yml` GitHub Actions workflow is run via `workflow_dispatch`.
The resulting `.deb` is copied to the iPhone and installed with Sileo or `dpkg`. After
installation:

```sh
sudo /var/jb/usr/local/bin/call-control status
```

### Test procedure

1. With no call in progress, run `status`, `answer` and `hangup`; verify that the latter two return
   `no_matching_call`.
2. Place a GSM call to the iPhone.
3. Run `sudo call-control status` over SSH; verify that the single call is `ringing`.
4. Run `sudo call-control answer`; record the `ringing → active` transition and the `elapsedMs`
   value from the JSON result.
5. While the conversation is active, run `sudo call-control hangup`; verify the `active → ended`
   transition.
6. Append the output to the duplex capture run directory as `call-control.log`.

Use `status --include-address` when the number has to be visible in the private evidence only; the
default output masks it.

Acceptance criteria:

- `call-control status` returns the current call and its state.
- `call-control answer` answers the single ringing cellular call and the call stays up, so the
  result is `ok: true` with `observedStates` of `["ringing", "active"]`.
- `call-control hangup` ends the single active call.
- With no call in progress the commands produce a safe, machine-readable error.
- If more than one eligible call exists the command does not act and returns `ambiguous_call`.

A result of `call_dropped_after_answer` means `CTCallAnswer` reached the modem but the call was
torn down before it stayed active; record `observedStates` and `activeForMs` and compare them with
the `call-monitor` log, because that is the signature of the call being answered outside
`callservicesd` rather than of a command that failed to arrive.

## CB-004 — Call control through the agent

Date: **23 September 2026**  
Result: **Pass**

The first end-to-end run of `callbridge-agent`: a client on the Mac paired over the network,
received live call events, and answered and ended two calls without the phone being touched.

### Procedure

1. The agent ran as the `com.callbridge.agent` LaunchDaemon.
2. `scripts/mac/agent-probe.py <iphone-ip> <token>` connected from the Mac.
3. A Bluetooth headset was paired so the call audio was audible.
4. For each of two incoming calls: `a` to answer, talk, `h` to hang up.

### Results

| Call | `answer` | `hangup` |
|---|---|---|
| `A3B13B03` | `ringing → active`, 176 ms | `active → ended`, 296 ms |
| `A87EE6F7` | `ringing → active`, 124 ms | `active → ended`, 427 ms |

- Every state was published exactly once per call, so the de-duplication holds against the repeated
  `kCTCallIdentificationChangeNotification` that CoreTelephony emits for one state.
- Outgoing calls dialled on the phone were reported as `dialing → active → ended`.
- Pairing, `hello`, `auth.result`, `call.snapshot` and the keepalive all behaved as specified.

Two defects showed up in the output and were fixed afterwards: an `unknown` state was published
ahead of the real one for outgoing calls, and the address changed from local format to E.164
mid-call.

A third finding is not a defect in the agent but a gap in the approach: with a Bluetooth headset
connected, a call answered through the agent did not move its audio to the headset, while an
outgoing call dialled on the phone did. `CTCallAnswer` answers without the route selection that
the phone's own answer path performs.

Command latency through the agent is several times the ~54 ms measured for the CLI in CB-003. The
agent resolves a command when the CoreTelephony notification arrives or on its 100 ms tick,
whichever comes first, so the figure includes notification delivery and tick granularity. It is
comfortably below anything a user would notice, but it is not the same measurement as CB-003 and
should not be compared with it directly.

## CB-005 — Duplex capture on an outgoing call

Date: **23 September 2026**  
Result: **Pass**

CB-002 could not be run on this device because incoming calls carry no audio (see
[STATUS.md](STATUS.md#device-audio-fault--19-september-2026)). Outgoing calls do, over a Bluetooth
headset, and the tap does not care which direction the call was set up in — so the capability was
tested that way instead.

### Procedure

1. Bluetooth headset connected.
2. `start-duplex-capture.sh` started `call-monitor` plus both recorders.
3. An outgoing call was dialled from the phone; both parties spoke in turn for about a minute.
4. `stop-capture.sh` ended the run.

### Results

| File | Format | Duration | Audio |
|---|---|---|---|
| `downlink-speaker.caf` | 2 ch, 44,100 Hz, Float32 interleaved | 96.700680 s | Far end, clear |
| `uplink-microphone.caf` | 1 ch, 44,100 Hz, Float32 | 96.700680 s | Near end, clear |

Both were confirmed by listening. Three things this settles:

- **`ATAudioTap` captures both directions.** Only the downlink had ever been proven, in CB-001.
- **Two taps run simultaneously without conflict.** The September hypothesis, that the empty CAF
  files came from two recorders fighting over one tap, is wrong — that run was simply silent.
- **The two streams are frame-locked.** Both files hold exactly 4,264,500 frames for the same
  duration, so the channels are sample-aligned with no drift between them. Live streaming will not
  need to resynchronize them, and echo cancellation later has a sound basis.

Two details that shape the design:

- The downlink is stereo and the uplink is mono. Format negotiation has to carry the channel count
  per direction rather than assume one format for both.
- Both taps record continuously from start to stop, not only while a call is up. The agent must
  gate streaming on call state, or it will publish audio when there is no call.

## CB-006 — Uplink injection

Date: **23 September 2026**  
Result: **Pass — the far end hears audio written by software**

The question the whole product turned on: can generated PCM be placed on the cellular uplink, so the
far end hears it, without it being played through a speaker for the microphone to pick up?

It can.

### Results

1. Control run with no call, `--no-tap`: the tool plays normally.
2. Control run with the tap attached to the output queue:
   `AudioQueueSetProperty(TapOutputBypass) -> 0 (accepted)`. An output `AudioQueue` accepts an
   `ATAudioTap`, which is what made the rest worth trying.
3. During an outgoing call, `uplink-player --channel microphone`: the person on the other end heard
   the 1 kHz tone.

### Why the result is trustworthy

A tone played out loud could be picked up by the phone's own microphone and reach the far end
acoustically, which would look identical from the outside. With a Bluetooth headset that risk is
acute, because the headset's microphone sits centimetres from its speaker.

So the decisive run was made with **the headset disconnected entirely**. On this device that leaves
no acoustic path at all: the failed audio IC means the internal speaker and the internal microphone
are both dead, which is why incoming calls carry no audio here. Nothing was audible locally, the
microphone could not have picked anything up, and the far end still heard the tone. The only route
left is the one the tool wrote to.

The hardware fault that has blocked this project for days is what made this particular test
rigorous.

### What this establishes, and what it does not

Established: software-generated PCM, written to an output `AudioQueue` carrying an `ATAudioTap`
built for the microphone PID (`-3`), reaches the cellular uplink and is audible to the far end.
Format under test was 44.1 kHz mono Float32.

Not yet established:

- Streaming live, arriving audio rather than a locally generated tone. Same path, but the timing
  behaviour under a network jitter buffer is untested.
- Whether the device's own microphone is mixed in or replaced. It could not be tested here because
  this device's microphone is dead. TrollRecorder's `requestMuteExistingUplinks` alongside its
  uplink playback suggests the real microphone has to be muted deliberately.
- Latency, and behaviour on an incoming call, which needs healthy hardware.

### The original tool description follows

### Why this is worth attempting

Static review of the installed TrollRecorder app shows it ships an uplink playback feature —
`PlayUplinkAudioIntent`, `StopUplinkPlaybackIntent`, `PreparedUplinkAudioFile`,
`requestMuteExistingUplinks` / `requestUnmuteExistingUplinks`, and `setUplinkMuted:` alongside
`playBackgroundAudioWithContentsOfFile:rate:volume:repeat:`. Injection on iOS is therefore not a
question of whether it is possible at all, only of which path reaches it. The shape suggested by
those names is: mute the real microphone uplink, then play a file into it.

### The approach under test

`call-recorder` attaches an `ATAudioTap` to an **input** `AudioQueue` with
`kAudioQueueProperty_TapOutputBypass` and reads the telephony stream. `uplink-player` does the
symmetric thing: it attaches the same kind of tap, built for the microphone PID (`-3`), to an
**output** queue and writes a 1 kHz tone into it.

`AudioQueueSetProperty(TapOutputBypass)` on an output queue is the decisive call. The tool logs its
status explicitly, because a refusal there rules the approach out immediately, with no call needed.

### Procedure

This device cannot carry audio on an incoming call, so use an outgoing one, which works over a
Bluetooth headset.

1. Control run, no call: `uplink-player --no-tap --seconds 5`. The tone should be audible on the
   phone. This proves the tool and the audio route before anything subtle is tested.
2. Control run with the tap, no call: `uplink-player --seconds 5`. Record what
   `AudioQueueSetProperty` returns.
3. Dial out to a helper over Bluetooth and, once talking, run
   `uplink-player --channel microphone --seconds 20`.
4. Ask the helper what they hear, and keep the headset away from the phone's microphone so that an
   acoustic path cannot be mistaken for injection.

### How to read the result

| Observation | Meaning |
|---|---|
| `AudioQueueSetProperty` refuses | An output queue cannot carry a tap; this path is dead, try the mute-and-play shape instead |
| It is accepted and the far end hears the tone | Injection works — the central risk of the project is gone |
| Accepted, far end hears nothing, tone audible locally | The tap attached but the audio still went to the speaker |
| Accepted, far end hears nothing, nothing audible locally | The audio went somewhere, just not the uplink — worth tapping `speaker` while playing to see where |

Step 4 matters more than it looks: with a headset connected the phone's own microphone is still
live, so a tone played out loud could reach the far end acoustically and look like success.
