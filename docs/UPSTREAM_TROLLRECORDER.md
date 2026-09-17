# Upstream: TrollRecorder

This repository is a fork of [Lessica/TrollRecorder](https://github.com/Lessica/TrollRecorder).

- Base commit reviewed and forked from: `4e8b65aacbc77d32540b5b4c06ce4ebbc4777e68`
- Upstream license: GNU AGPL v3 — see [LICENSE](../LICENSE)
- The upstream repository contains **only the CLI core**. The paid features of the TrollRecorder
  app are not open source and are not the basis of this project.

## Inherited from upstream

| Path | Contents |
|---|---|
| `cli/recorder.mm`, `player.mm`, `mixer.mm` | General-purpose audio tools |
| `cli/call-recorder.mm`, `call-monitor.mm` | Call recording and CoreTelephony/CallKit observation |
| `cli/dtmf-decoder.mm` | DTMF decoder |
| `include/` | Private `ATAudioTap`, `CTCall` and `CTTelephonyCenter` headers |
| `Makefile`, `layout/DEBIAN/` | Theos build and packaging skeleton |

## Changes made in this fork

- Added `cli/call-control.mm` and `cli/call-control.plist`: a one-shot tool exposing `status`,
  `answer` and `hangup` with machine-readable JSON output.
- Extended the `Makefile` to build the `call-control` target.
- Added `.github/workflows/build-rootless.yml`, which produces the rootless `.deb`.
- Removed the upstream application sources, localization files (`res/`) and the store/legal pages
  (`EULA.md`, `PrivacyPolicy.md`, `DropboxIntegration.md`, `_config.yml`, `CNAME` and similar);
  this repository carries only the CLI and the CallBridge layer.
- Added the CallBridge documentation, test helpers and evidence layout.

## Why fork

`call-control` uses the same private headers, the same signature entitlements
(`com.apple.CommCenter.fine-grained`, `com.apple.telephonyutilities.callservicesd`) and the same
Theos packaging pipeline as the upstream CLI tools. Building it inside the same `.deb` keeps the
entitlement profile and the build environment fixed for the first device validation. The
entitlement profile will be narrowed once `answer`/`hangup` behavior is confirmed on the device.

## Credits

- [Lessica/TrollRecorder](https://github.com/Lessica/TrollRecorder) — the CLI core
- [owngoal-dev/TrollVNC](https://github.com/owngoal-dev/TrollVNC) — the rootless Theos/GitHub
  Actions example; reviewed commit `a3e40816ea5b93a7c80c09625175893d15bd1070`
