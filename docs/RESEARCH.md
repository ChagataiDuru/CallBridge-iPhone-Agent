# Source research

## TrollRecorder CLI

Source: <https://github.com/Lessica/TrollRecorder>  
Reviewed commit: `4e8b65aacbc77d32540b5b4c06ce4ebbc4777e68`

The upstream README states explicitly that only the command-line core is open source. The reviewed
source produces these tools:

- `audio-player`
- `audio-recorder`
- `audio-mixer`
- `call-recorder`
- `call-monitor`
- `dtmf-decoder`

`call-monitor` uses CoreTelephony notifications and a CallKit observer in the same process. On the
CoreTelephony side it reads the address, name, country code, network code, status, type and unique
call identifier.

`call-recorder` uses the private `ATAudioTap` and a private AudioQueue property whose FourCC is
presumed to be `qtob`. The special PID values are:

- system audio: `-1`
- speaker/downlink: `-2`
- microphone: `-3`

On the iOS 15 path the recorder uses `initProcessTapInternalWithFormat:PID:` and produces 44.1 kHz
Float32 PCM CAF files.

`include/CTCall.h` declares `CTCopyCurrentCalls`, `CTCallAnswer`, `CTCallDisconnect`,
`CTCallListDisconnectAll` and `CTCallDial`. The upstream CLI does not expose these functions as
commands; CallBridge's `call-control` tool can use them.

## Entitlement review

The signature entitlements of the installed TrollRecorder 4.5 package contained the following
relevant items:

- `platform-application`
- `com.apple.coreaudio.CanTapTelephony`
- `com.apple.coreaudio.app-tap`
- `com.apple.coreaudio.private.SystemWideTap`
- `com.apple.coreaudio.CanRecordWithoutSessionActivation`
- `com.apple.private.mediaexperience.startrecordinginthebackground.allow`
- `access-calls` and `modify-calls` under `com.apple.telephonyutilities.callservicesd`
- `com.apple.private.security.no-sandbox`

In the open CLI, `call-monitor.plist` carries the call access/modify entitlements and
`call-recorder.plist` carries the telephony tap and microphone entitlements. The device test
confirmed that these entitlements work in a rootless package for call observation and downlink
capture.

## TrollVNC

Source: <https://github.com/owngoal-dev/TrollVNC>  
Reviewed commit: `a3e40816ea5b93a7c80c09625175893d15bd1070`

TrollVNC's Theos/rootless build approach was used as the GitHub Actions template for the
TrollRecorder CLI. The first workflow attempt failed because the Theos path was not passed to the
SDK installation step; it was fixed by exporting `THEOS` explicitly and symlinking `$HOME/theos`.

## Limits

- The open TrollRecorder repository does not contain the full Pro app or its licensing/persistence
  layer.
- `audio-player` provides ordinary AudioQueue output; on its own it does not prove telephony uplink
  injection.
- Recording from the microphone tap is not the same operation as writing remotely received PCM into
  the cellular uplink.
- Private APIs are tied to the iOS version; the target is the verified iOS 15.8.8 device first.
