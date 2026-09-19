# CallBridge iPhone Agent

CallBridge turns a jailbroken iPhone into a cellular call endpoint that a **stock, non-rooted
Android phone** drives over the local network — incoming call display, answer/reject/hang up, and
two-way audio, with no cloud service in the path.

This repository holds the **iPhone side**: rootless command-line tools, the call-control prototype,
on-device test helpers, and the engineering documentation.

It is a fork of [Lessica/TrollRecorder](https://github.com/Lessica/TrollRecorder)'s open CLI core.
See [docs/UPSTREAM_TROLLRECORDER.md](docs/UPSTREAM_TROLLRECORDER.md) for what was inherited, what
was added, and licensing.

## Target setup

| | |
|---|---|
| **Cellular end** | iPhone 7 (`iPhone9,3`), iOS 15.8.8, rootless jailbreak (`/var/jb`) |
| **Client** | Xiaomi 15, stock Android, no root required |
| **Link** | Same Wi-Fi or the phone's hotspot; no cloud dependency |
| **Function** | Show the incoming call and caller on Android, answer/reject/hang up, talk both ways |

## Status — 19 September 2026

Three of the early technical risks are settled on real hardware:

1. **Call events.** Incoming calls, the caller's number, and the `Incoming → Answered → Ended`
   transitions are captured through CoreTelephony.
2. **Downlink audio.** The far end of a live cellular call is recorded cleanly from the
   speaker/downlink channel via `ATAudioTap` — a 29.234 s, 44.1 kHz, stereo Float32 PCM CAF file,
   audibly correct.
3. **Call control.** A full incoming call was answered and ended by command without touching the
   screen: `ringing → active` in **54 ms**, `active → ended` in **109 ms**.

Current work is the `callbridge-agent` service and its control protocol, defined in
[docs/PROTOCOL.md](docs/PROTOCOL.md).

Two things are **blocked on hardware**. The reference iPhone 7's audio IC has failed — calls
connect and the state machine works, but no audio passes in either direction. That makes duplex
capture impossible to validate on this device, and it puts the project's biggest open risk,
**uplink injection**, out of reach until the device is repaired or replaced. Capturing the
microphone channel was never proven; injecting into it is a separate question again, and nothing
in this repo should assume either works. Call notification and remote control remain fully
viable regardless.

Full verification matrix: [docs/STATUS.md](docs/STATUS.md).

## Tools

All tools build into a single rootless `.deb` and install to `/var/jb/usr/local/bin`.

| Tool | Purpose |
|---|---|
| `callbridge-agent` | Long-lived service: publishes call state and accepts commands over NDJSON |
| `call-monitor` | Streams CoreTelephony and CallKit call events |
| `call-control` | `status`, `answer`, `hangup` — emits a single JSON object |
| `call-recorder` | Records the `speaker` (downlink) or `microphone` (uplink) channel to CAF |
| `audio-recorder` / `audio-player` / `audio-mixer` | Upstream general-purpose audio utilities |
| `dtmf-decoder` | Upstream DTMF decoder |

`call-control` is one-shot and machine-readable. Phone numbers are redacted by default; pass
`status --include-address` to see them. `answer` and `hangup` act only when exactly one matching
cellular call exists, and verify the observed state transition before reporting success.

Verification registers a `CTTelephonyCenter` observer and runs the run loop, because
`CTCopyCurrentCalls` otherwise keeps returning the snapshot the process took at startup. Every
result carries `observedStates`, the ordered list of states seen while the command ran. `answer`
additionally requires the call to stay active for one second before it reports success, so a call
that is torn down right after being answered is reported as a failure rather than as an answer.

Exit codes: `0` success, `2` usage error, `3` no matching call, `4` transition verification
timeout, `5` ambiguous call selection, `6` the call ended before the expected transition,
`7` the call was answered but dropped before it stayed active.

```sh
call-control status
call-control status --include-address
call-control answer --timeout-ms 10000
call-control hangup
```

## Build

The package is built with Theos. CI is the recommended path: run
[`.github/workflows/build-rootless.yml`](.github/workflows/build-rootless.yml) via
`workflow_dispatch` and download the `callbridge-cli-rootless` artifact.

Locally, on macOS with Theos installed:

```sh
source devkit/rootless.sh          # rootless scheme; use devkit/roothide.sh for roothide
FINALPACKAGE=1 gmake clean package # output in packages/*.deb
```

Install and smoke-test on the device:

```sh
scp packages/*.deb mobile@<iphone-ip>:/var/mobile/
ssh mobile@<iphone-ip> 'sudo dpkg -i /var/mobile/<package>.deb'
ssh mobile@<iphone-ip> 'sudo /var/jb/usr/local/bin/call-control status'
```

## Running the agent

`callbridge-agent` runs in the foreground for now; persistence via a LaunchDaemon comes once it has
been exercised by hand. It generates a pairing token on first start.

```sh
ssh mobile@<iphone-ip> 'sudo /var/jb/usr/local/bin/callbridge-agent --print-token'
ssh mobile@<iphone-ip> 'sudo /var/jb/usr/local/bin/callbridge-agent'   # --port 8765 by default
```

To exercise it without the Android client, from the Mac:

```sh
python3 - <<'PY'
import hashlib, hmac, json, socket
HOST, PORT, TOKEN = "<iphone-ip>", 8765, "<token>"
sock = socket.create_connection((HOST, PORT))
lines = sock.makefile("rw", encoding="utf-8", newline="\n")
hello = json.loads(lines.readline())
print("hello", hello)
proof = hmac.new(TOKEN.encode(), hello["nonce"].encode(), hashlib.sha256).hexdigest()
lines.write(json.dumps({"type": "auth", "proof": proof, "clientName": "probe",
                        "protocolVersion": 1}) + "\n")
lines.flush()
for line in lines:                      # auth.result, call.snapshot, then live events
    print(line.strip())
PY
```

The protocol is [docs/PROTOCOL.md](docs/PROTOCOL.md).

## On-device testing

```sh
scp scripts/iphone/*.sh mobile@<iphone-ip>:/var/mobile/
ssh mobile@<iphone-ip> 'sudo sh /var/mobile/start-duplex-capture.sh'
# place a call, talk, hang up
ssh mobile@<iphone-ip> 'sudo sh /var/mobile/stop-capture.sh'
sh scripts/mac/fetch-latest-run.sh <iphone-ip>   # pulls the run into evidence/private/
```

Numbered test cases, procedures and acceptance criteria live in [docs/TESTING.md](docs/TESTING.md).

## Repository layout

```text
CallBridge-iPhone-Agent/
├── cli/            # Objective-C++ CLI sources and their entitlement plists
├── include/        # Private CoreTelephony and ATAudioTap headers
├── layout/DEBIAN/  # Debian package metadata
├── devkit/         # Theos environment schemes (rootless, roothide)
├── docs/           # Status, architecture, roadmap, testing and privacy docs
├── scripts/
│   ├── iphone/     # Capture helpers that run on the device
│   └── mac/        # Fetch and verification helpers that run on the Mac
├── evidence/       # Call test evidence (local only)
│   ├── private/    # Raw evidence with real numbers and audio
│   └── sanitized/  # Logs with numbers redacted, for local review and manual sharing
├── reports/        # Device and static-analysis reports (local only)
├── research/       # Extracted third-party app content (local only)
└── artifacts/      # Built .deb packages and archives (local only)
```

## Privacy

Real phone numbers and call audio never enter Git. The whole of `evidence/`, along with `reports/`,
`research/` and `artifacts/`, is local-only by `.gitignore` — no call evidence is published from
this repository, masked or otherwise. See [docs/PRIVACY.md](docs/PRIVACY.md).

## Roadmap

1. **Phase 1 — Call control + duplex capture.** Control half done; duplex capture blocked on
   hardware.
2. **Phase 2 — Uplink injection gate.** Blocked on hardware. Can generated PCM reach the telephony
   uplink without acoustic playback?
3. **Phase 3 — `callbridge-agent`.** Active. One long-lived service publishing call events and
   accepting commands over an authenticated NDJSON connection, persistent via a rootless
   LaunchDaemon. Protocol: [docs/PROTOCOL.md](docs/PROTOCOL.md).
4. **Phase 4 — Android PoC.** Kotlin/Compose client, in its own repository.

Details: [docs/ROADMAP.md](docs/ROADMAP.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Scope and legal notice

This is a research and feasibility project carried out on hardware owned by the author. Call
recording and access to call content are regulated in many jurisdictions; complying with local law
is the user's responsibility. No real phone numbers or call audio are distributed in this
repository.

## License

Like the upstream CLI core, this repository is licensed under the GNU AGPL v3 — see [LICENSE](LICENSE).
