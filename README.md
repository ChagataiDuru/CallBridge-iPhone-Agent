# CallBridge iPhone Agent

CallBridge turns a jailbroken iPhone into a cellular call endpoint that a **stock, non-rooted
Android phone** drives over the local network — incoming call display, answer/reject/hang up, and
two-way audio, with no cloud service in the path.

This repository holds the **iPhone side**: rootless command-line tools, the call-control prototype,
on-device test helpers, and the engineering documentation.

It is a fork of [Lessica/TrollRecorder](https://github.com/Lessica/TrollRecorder)'s open CLI core.
See [docs/UPSTREAM_TROLLRECORDER.md](docs/UPSTREAM_TROLLRECORDER.md) for what was inherited, what
was added, and licensing.

> Project documentation under `docs/` is currently written in Turkish.

## Target setup

| | |
|---|---|
| **Cellular end** | iPhone 7 (`iPhone9,3`), iOS 15.8.8, rootless jailbreak (`/var/jb`) |
| **Client** | Xiaomi 15, stock Android, no root required |
| **Link** | Same Wi-Fi or the phone's hotspot; no cloud dependency |
| **Function** | Show the incoming call and caller on Android, answer/reject/hang up, talk both ways |

## Status — 18 September 2026

Two of the first technical risks are verified on real hardware:

1. **Call events.** Incoming calls, the caller's number, and the `Incoming → Answered → Ended`
   transitions are captured through CoreTelephony.
2. **Downlink audio.** The far end of a live cellular call is recorded cleanly from the
   speaker/downlink channel via `ATAudioTap`.

The successful test produced a 29.234 s, 44.1 kHz, stereo Float32 PCM CAF file for a ~30 s call.
QuickTime opened it directly and the far end was clearly audible.

The `call-control` prototype (`status` / `answer` / `hangup`) is written and builds; rootless
packaging and on-device validation are the next step.

**The biggest open risk is uplink injection** — pushing audio from Android into the cellular
microphone/uplink path. Capturing the microphone channel is proven; injecting into it is not, and
nothing in this repo should assume it works. If that gate fails, remote notification, remote
control, and listen-only features remain viable, but real two-way conversation does not.

Full verification matrix: [docs/STATUS.md](docs/STATUS.md).

## Tools

All tools build into a single rootless `.deb` and install to `/var/jb/usr/local/bin`.

| Tool | Purpose |
|---|---|
| `call-monitor` | Streams CoreTelephony and CallKit call events |
| `call-control` | `status`, `answer`, `hangup` — emits a single JSON object |
| `call-recorder` | Records the `speaker` (downlink) or `microphone` (uplink) channel to CAF |
| `audio-recorder` / `audio-player` / `audio-mixer` | Upstream general-purpose audio utilities |
| `dtmf-decoder` | Upstream DTMF decoder |

`call-control` is one-shot and machine-readable. Phone numbers are redacted by default; pass
`status --include-address` to see them. `answer` and `hangup` act only when exactly one matching
cellular call exists, and verify the observed state transition before reporting success.

Exit codes: `0` success, `2` usage error, `3` no matching call, `4` transition verification
timeout, `5` ambiguous call selection.

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
├── evidence/
│   ├── private/    # Raw evidence with real numbers and audio (never committed)
│   └── sanitized/  # Redacted, shareable text logs
├── reports/        # Device and static-analysis reports (local only)
├── research/       # Extracted third-party app content (local only)
└── artifacts/      # Built .deb packages and archives (local only)
```

## Privacy

Real phone numbers and call audio never enter Git. `evidence/private/`, `reports/`, `research/`
and `artifacts/` are local-only by `.gitignore`; only `evidence/sanitized/` text logs are tracked,
with numbers replaced by `[REDACTED_PHONE]`. See [docs/PRIVACY.md](docs/PRIVACY.md).

## Roadmap

1. **Phase 1 — Call control + duplex capture.** Capture `speaker` and `microphone` simultaneously
   during one call; validate `call-control answer` / `hangup` on the device.
2. **Phase 2 — Uplink injection gate.** Determine whether generated PCM can reach the telephony
   uplink without acoustic playback.
3. **Phase 3 — `callbridge-agent`.** One long-lived service publishing JSON events over an
   authenticated local WebSocket, persistent via a rootless LaunchDaemon.
4. **Phase 4 — Android PoC.** Kotlin/Compose client.

Details: [docs/ROADMAP.md](docs/ROADMAP.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Scope and legal notice

This is a research and feasibility project carried out on hardware owned by the author. Call
recording and access to call content are regulated in many jurisdictions; complying with local law
is the user's responsibility. No real phone numbers or call audio are distributed in this
repository.

## License

Like the upstream CLI core, this repository is licensed under the GNU AGPL v3 — see [LICENSE](LICENSE).
