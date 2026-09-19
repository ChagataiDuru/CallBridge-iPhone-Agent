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

Status: **Next test**

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

Status: **CLI prototype ready; rootless build and device test pending**

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
