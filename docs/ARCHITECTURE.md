# Proposed architecture

## System boundary

```mermaid
flowchart LR
    GSM["GSM network"] <-->|"cellular call"| IPHONE["iPhone 7\nCallBridge Agent"]
    IPHONE <-->|"local network\ncontrol + audio"| ANDROID["Xiaomi 15\nCallBridge Android"]

    subgraph IA["iPhone agent"]
      MON["Call observer"]
      CTRL["Answer / hang up"]
      DOWN["Downlink tap"]
      UP["Uplink injection\nresearch"]
      NET["Authenticated network service"]
    end

    subgraph AA["Android app"]
      UI["Incoming call screen"]
      AUDIO["Microphone + speaker"]
      SERVICE["Foreground service"]
    end
```

## iPhone side

A single `callbridge-agent` process is proposed:

- Listens to CoreTelephony and CallKit events.
- Reduces those events to one call state machine.
- Executes `answer`, `reject` and `hangup` commands from an authorized client.
- Converts downlink PCM into live audio frames.
- Feeds frames from the Android microphone into the uplink path; this part is the experimental gate.
- Starts automatically after a jailbreak via a rootless LaunchDaemon.

In the first release the agent can be derived from the existing TrollRecorder CLI code in
Objective-C++/Theos. Under the rootless layout the package path must be `/var/jb/usr/local/bin`
and the LaunchDaemon path `/var/jb/Library/LaunchDaemons`.

## Android side

A Kotlin app on stock Android is proposed:

- A foreground service keeps the local connection alive.
- A Compose UI shows the caller and the call state.
- Answer, reject and hang up commands are sent to the agent.
- `AudioRecord` handles the microphone, `AudioTrack` plays the far end.
- Android Telecom integration can be considered later; a custom full-screen call UI is enough for
  the first PoC.

## Protocol

A single authenticated WebSocket connection is enough for the first PoC. Control messages can be
JSON and audio frames binary.

Example event:

```json
{
  "type": "call.state",
  "callId": "opaque-local-id",
  "state": "ringing",
  "direction": "incoming",
  "address": "+90…",
  "timestamp": "2026-09-18T00:53:14.556+03:00"
}
```

Example command:

```json
{
  "type": "call.command",
  "callId": "opaque-local-id",
  "command": "answer",
  "requestId": "client-generated-id"
}
```

Every command must be applied exactly once per `requestId` and must produce an explicit result
message.

## Audio transport plan

The verified source format is 44.1 kHz stereo Float32 PCM. The first live experiment can start
with raw PCM to keep conversion cost low. Once the link works:

1. Convert the downlink to mono 16 or 24 kHz PCM.
2. Use 20 ms frames with sequence numbers.
3. Add a jitter buffer and latency measurement.
4. Move to Opus if needed.

Recording to a file should remain available alongside live streaming as a diagnostic option.

## Network and security

- The service must only listen on local interfaces.
- A long, randomly generated key must be used at first pairing.
- Control commands must not be accepted without authentication.
- Start with a single active Android client at a time.
- Phone numbers must be masked in logs by default.
- Client access to the iPhone over its hotspot must be tested separately; an SSH test that works
  over Wi-Fi does not by itself prove hotspot behavior.

## Core technical risk

`call-recorder microphone` captures audio from the iPhone's microphone. That does not prove we can
write audio from the network into the modem uplink. Uplink injection must be treated as a separate
low-level experiment, and if it fails the product architecture has to be reconsidered.
