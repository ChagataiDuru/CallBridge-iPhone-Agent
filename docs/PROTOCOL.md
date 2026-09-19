# CallBridge control protocol v1

The contract between `callbridge-agent` on the iPhone and the CallBridge client on Android.
Both sides code against this document; changing it means changing both.

## Transport

A single TCP connection carrying **newline-delimited JSON (NDJSON)**.

- The agent listens on TCP port `8765` by default, configurable.
- Every message is one UTF-8 JSON object on one line, terminated by a single `\n` (0x0A).
  A message never contains a raw newline; JSON escapes them as `\n` inside strings.
- A line longer than 64 KiB is a protocol violation: the agent sends `error` with code
  `message_too_large` and closes the connection.
- Either side may close at any time. The client is responsible for reconnecting with backoff.
- The agent accepts **one authenticated client at a time**. A second connection is answered with
  `error` code `busy` and closed.

NDJSON rather than WebSocket: the client is a native Android app, so the WebSocket handshake,
masking and frame layer would buy nothing here and cost a hand-written implementation on the iOS
side. Live audio will not share this connection — it gets its own stream with binary framing
(see *Reserved for audio*).

## Connection lifecycle

```
client                                   agent
  |------------- TCP connect ------------->|
  |<------------ hello --------------------|   protocolVersion, nonce, device info
  |------------- auth -------------------->|   HMAC proof of the shared token
  |<------------ auth.result --------------|   ok:true
  |<------------ call.snapshot ------------|   calls in progress right now
  |                                        |
  |<------------ call.state ---------------|   events, pushed as they happen
  |------------- call.command ------------>|   answer / hangup
  |<------------ call.result --------------|   outcome of that requestId
  |                                        |
  |<------------ ping ---------------------|   every 15 s
  |------------- pong -------------------->|
```

The agent closes the connection if `auth` does not arrive within 5 seconds of `hello`, or if two
consecutive pings go unanswered.

## Common fields

| Field | Type | Meaning |
|---|---|---|
| `type` | string | Message type. Always present. |
| `timestamp` | string | ISO 8601 UTC with milliseconds, e.g. `2026-09-19T19:34:58.959Z`. Always present. |
| `requestId` | string | Client-generated id on commands, echoed on the matching result. |

Timestamps are always UTC. The client converts to local time for display.

## Call states

The agent publishes exactly these states, which are the same vocabulary `call-control` uses:

| State | Meaning |
|---|---|
| `ringing` | Incoming call, not yet answered |
| `active` | Call answered and in progress |
| `ended` | Call finished normally |
| `dropped` | Call interrupted by the network or the modem |
| `dialing` | Outgoing call initiated (not used in v1, reserved) |
| `unknown` | State could not be determined |

The canonical transition sequence is `ringing → active → ended`. The agent de-duplicates
CoreTelephony notifications on `callId + state`, so the client never receives the same state twice
for the same call and can treat every `call.state` message as a real change.

## Messages from the agent

### `hello`

Sent immediately on connect, before authentication.

```json
{"type":"hello","protocolVersion":1,"agentVersion":"0.4","device":"iPhone9,3","nonce":"6f1c…","authRequired":true,"timestamp":"2026-09-19T19:34:41.204Z"}
```

`nonce` is 32 random bytes, hex encoded, fresh for every connection. If `protocolVersion` is not
one the client supports, the client closes the connection and tells the user to update.

### `auth.result`

```json
{"type":"auth.result","ok":true,"timestamp":"2026-09-19T19:34:41.310Z"}
```

On failure, `ok` is `false` with an `error` object, and the agent closes the connection.

### `call.snapshot`

Sent once after successful authentication so a client that connects mid-call is not out of sync.
`calls` is empty when nothing is in progress.

```json
{"type":"call.snapshot","calls":[{"callId":"5BF63DC5-48F8-431B-A905-9E8090AF418F","state":"active","direction":"incoming","address":"+90…","type":"cellular"}],"timestamp":"2026-09-19T19:34:41.330Z"}
```

### `call.state`

One message per real state change.

```json
{"type":"call.state","callId":"5BF63DC5-48F8-431B-A905-9E8090AF418F","state":"ringing","direction":"incoming","address":"+90…","callType":"cellular","timestamp":"2026-09-19T19:34:52.118Z"}
```

| Field | Notes |
|---|---|
| `callId` | CoreTelephony `UniqueStringID`. Stable for the lifetime of the call. |
| `state` | One of the call states above. |
| `direction` | `incoming` or `outgoing`. |
| `address` | The caller's number in full. See *Privacy* below. |
| `callType` | `cellular`, `voip`, `video`, `voicemail` or `unknown`. v1 only acts on `cellular`. |

### `call.result`

The outcome of one `call.command`, correlated by `requestId`.

```json
{"type":"call.result","requestId":"a41f…","ok":true,"command":"answer","callId":"5BF63DC5-48F8-431B-A905-9E8090AF418F","fromState":"ringing","toState":"active","observedStates":["ringing","active"],"elapsedMs":54,"stableForMs":1042,"timestamp":"2026-09-19T19:34:58.959Z"}
```

Failure:

```json
{"type":"call.result","requestId":"a41f…","ok":false,"command":"answer","error":{"code":"no_matching_call","message":"No ringing cellular call was found"},"timestamp":"2026-09-19T19:34:58.959Z"}
```

`elapsedMs` is the measured time from issuing the telephony call to observing the expected state.
On the reference device this is ~54 ms for `answer` and ~109 ms for `hangup`; a client can treat
anything beyond a second as a problem worth showing to the user.

### `ping`

```json
{"type":"ping","timestamp":"2026-09-19T19:35:13.000Z"}
```

### `error`

Protocol-level failures that are not tied to a command.

```json
{"type":"error","error":{"code":"message_too_large","message":"Line exceeded 64 KiB"},"timestamp":"2026-09-19T19:35:13.000Z"}
```

## Messages from the client

### `auth`

`proof` is `HMAC-SHA256(key = token, message = nonce)`, hex encoded lowercase, where `nonce` is the
value from `hello` and `token` is the shared pairing key. The raw token is never sent.

```json
{"type":"auth","proof":"9c2e…","clientName":"Xiaomi 15","protocolVersion":1,"timestamp":"2026-09-19T19:34:41.290Z"}
```

### `call.command`

```json
{"type":"call.command","requestId":"a41f…","command":"answer","callId":"5BF63DC5-48F8-431B-A905-9E8090AF418F","timeoutMs":5000,"timestamp":"2026-09-19T19:34:58.900Z"}
```

| Field | Notes |
|---|---|
| `command` | `answer` or `hangup`. `reject` is reserved for v1.1. |
| `callId` | Optional. When omitted the agent acts on the single eligible call, and fails with `ambiguous_call` if there is more than one. Clients should always send it. |
| `timeoutMs` | Optional, 100–30000, default 5000. How long the agent waits for the transition. |
| `requestId` | Required. See *Idempotency*. |

### `pong`

```json
{"type":"pong","timestamp":"2026-09-19T19:35:13.040Z"}
```

## Idempotency

A command is applied **at most once per `requestId`**. The agent keeps every `requestId` and its
result for 60 seconds; a repeat within that window is answered with the stored `call.result`
instead of being executed again. This makes retrying safe on a flaky link, which matters because
the client will retry exactly when the network is unreliable — and answering a call twice, or
hanging up a call the user has just re-answered, is the kind of mistake the user notices.

Clients must generate a fresh `requestId` (a UUID) for every genuinely new command and reuse the
same one when retrying.

## Error codes

Command errors, carried in `call.result.error.code`. The first five match `call-control`'s exit
codes exactly, so the CLI and the agent report the same conditions by the same names.

| Code | Meaning |
|---|---|
| `no_matching_call` | No call in the state the command requires |
| `ambiguous_call` | More than one eligible call; nothing was done |
| `verification_timeout` | Command issued but the expected transition was not observed |
| `call_ended` | The call ended before the expected transition |
| `call_dropped_after_answer` | Answered, then torn down before it stayed active |
| `bad_request` | Malformed message or invalid field |

Connection errors, carried in `error.error.code`:

| Code | Meaning |
|---|---|
| `unauthorized` | Missing, late or incorrect `auth` |
| `busy` | Another client is already authenticated |
| `unsupported_version` | `protocolVersion` mismatch |
| `message_too_large` | Line exceeded 64 KiB |

## Pairing and security

- The token is 32 random bytes, hex encoded, generated on first start and stored at
  `/var/jb/etc/callbridge/token` with mode `0600`, owned by root.
- Pairing transfers the token out of band: the agent can print it, or display it as a QR code for
  the Android client to scan. It is never sent over the wire — only the HMAC proof is.
- The proof covers a per-connection nonce, so capturing traffic does not let an attacker replay
  authentication.
- v1 is otherwise **plaintext**. Message contents, including phone numbers, are readable by anyone
  on the same network segment. This is acceptable only on a trusted home network or the phone's own
  hotspot. TLS with a self-signed certificate pinned at pairing time is the intended v2 change, and
  should come before anything resembling a release.
- The agent binds to all interfaces because the client reaches it over Wi-Fi or the hotspot. It
  accepts one authenticated client and drops unauthenticated connections after 5 seconds.

## Privacy

`address` carries the caller's real number, because displaying the caller is the entire point of
the product. This is a deliberate difference from `call-control`, whose CLI output masks numbers by
default.

The agent's own log file is the opposite: numbers are masked there by default, and the full number
appears only when diagnostics are explicitly enabled. Nothing in `evidence/` is ever published. See
[PRIVACY.md](PRIVACY.md).

## Reserved for audio

Live audio is not part of v1 and is blocked on hardware; the reference device has a failed audio
IC. The design it will follow:

- Audio does not share this connection. The client opens a second TCP connection, authenticates the
  same way, and sends `audio.attach` naming the call.
- Frames are length-prefixed binary, not JSON: a 4-byte big-endian length, a small fixed header
  (sequence number, channel, timestamp), then PCM.
- Negotiation (`audio.offer` / `audio.accept`) carries the sample rate, channel count and frame
  duration, so the format can change without a protocol version bump.
- The message names `audio.attach`, `audio.offer`, `audio.accept` and `audio.frame` are reserved in
  v1 and must not be reused.
