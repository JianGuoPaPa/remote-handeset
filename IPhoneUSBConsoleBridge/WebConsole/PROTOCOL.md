# iPhone USB Console Web Protocol v1

The browser console is served from the same HTTPS origin as these endpoints. All API calls and WebSocket upgrades use the same opaque, `HttpOnly` session cookie. A backend must reject cross-origin requests/upgrades and must never expose the TrollVNC password to the browser.

## HTTP authentication and status

All JSON responses use `Content-Type: application/json` and all non-GET requests require `Content-Type: application/json` when they carry a body.

### `GET /api/session`

- Authenticated: `200 {"authenticated":true,"csrfToken":"<opaque>"}`
- Anonymous: `401 {"code":"unauthorized","message":"..."}`

The session token and CSRF token are each generated from 32 random bytes and encoded with base64url. The session token is stored only in the `__Host-IUSC` cookie with `Secure; HttpOnly; SameSite=Strict; Path=/; Max-Age=28800`; `csrfToken` is returned only to authenticated-page memory and sent as `X-CSRF-Token` for logout. Sessions expire after 30 minutes idle or 8 hours absolute.

### `POST /api/login`

Request: `{"password":"..."}`

- Success: `200 {"authenticated":true,"csrfToken":"<opaque>"}` plus the session cookie.
- Wrong credentials: `401 {"code":"invalid_credentials","message":"..."}`.
- Rate limited: `429 {"code":"rate_limited","message":"..."}`.

The backend verifies the password with PBKDF2-HMAC-SHA256 using a 16-byte salt, 600,000 iterations, and a 32-byte verifier, then compares in constant time. PBKDF2 work is limited to a queue depth of 4. A source is blocked for 15 minutes after 5 failed attempts in 10 minutes; the global limiter blocks new attempts for 10 minutes after 20 failures in 10 minutes. A new session and CSRF token are generated after every successful login.

### `POST /api/logout`

Header: `X-CSRF-Token: <opaque>`

Success: `204` and expire the session cookie.

The browser clears its authenticated UI state only after this success response. A failed or timed-out logout keeps the current console session active and allows the user to retry.

### `GET /api/status`

Authenticated response:

```json
{
  "usbVideo": {
    "state": "connected",
    "connected": true,
    "fps": 59.9,
    "frameAgeMs": 38
  },
  "control": {
    "state": "connected",
    "connected": true
  },
  "device": {
    "name": "iPhone (USB)"
  }
}
```

Metrics may be `null` when unavailable. They must be measured values, not target/configured values.

## WebSocket authorization

All upgrades require a valid session cookie and an exact allowed `Origin`. Unauthorized upgrades are rejected with HTTP 401; an already-upgraded socket whose session expires closes with code `4401`. Payloads above the documented maximum are closed with `1009`.

## Video: `/ws/video`

The browser sends no subscription message. Immediately after the upgrade, and whenever the H.264 format description changes, the server sends this UTF-8 JSON text message:

```json
{
  "v": 1,
  "type": "config",
  "codec": "avc1.640028",
  "codedWidth": 1179,
  "codedHeight": 2556,
  "description": "<base64 AVCDecoderConfigurationRecord (avcC bytes)>"
}
```

`codec` must match the encoded profile/level. `description` is the AVCDecoderConfigurationRecord only, not a full MP4 atom.

Every encoded access unit is one binary WebSocket message. It consists of a 20-byte network-byte-order header followed by the AVCC access unit (4-byte big-endian NAL lengths):

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | ASCII `IUVC` (`49 55 56 43`) |
| 4 | 1 | protocol version `1` |
| 5 | 1 | flags; bit 0 = key frame; remaining bits are zero |
| 6 | 2 | header byte length, currently `20` |
| 8 | 8 | unsigned monotonic presentation timestamp in microseconds |
| 16 | 4 | unsigned frame sequence, wrapping modulo 2^32 |
| 20 | rest | one AVCC H.264 access unit |

The encoder must disable B-frame reordering. Timestamps must be safe when converted to a JavaScript integer. A new video client must receive a key frame promptly.

The browser may send:

```json
{"v":1,"type":"resync","afterSequence":1234}
```

On `resync`, force or deliver the next IDR and send it without waiting behind older frames. If a client's network write queue grows, discard its queued video, wait for/force an IDR, then resume. Do not silently omit a delta frame and continue the same dependency chain. The current encoder uses a 60-frame key-frame interval at 60 fps (about one second). The NIO WebSocket frame ceiling is 4 MiB; video and audio sockets accept at most 1 KiB of client text control and do not treat 4 MiB as an application-level inbound video allowance.

## Phone audio: `/ws/audio` and `/ws/audio-pcm`

The browser opens exactly one audio endpoint after an explicit user gesture. `/ws/audio` is the preferred raw-Opus transport. `/ws/audio-pcm` is the no-WebCodecs/no-AudioWorklet fallback and uses an ordinary `AudioContext`. Both endpoints share one 16-viewer capacity budget and the same authentication, Origin checks, heartbeat handling, per-client five-packet queue, and five-second write deadline.

Opus configuration:

```json
{"v":1,"type":"config","stream":"audio","codec":"opus","sampleRate":48000,"numberOfChannels":2,"frameDurationUs":20000}
```

PCM fallback configuration:

```json
{"v":1,"type":"config","stream":"audio-pcm","codec":"pcm_s16le","sampleFormat":"s16le-interleaved","sampleRate":48000,"numberOfChannels":2,"frameDurationUs":20000}
```

Every audio binary WebSocket message consists of this 24-byte network-byte-order `IUAC` header followed by one payload:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | ASCII `IUAC` (`49 55 41 43`) |
| 4 | 1 | protocol version `1` |
| 5 | 1 | flags; bit 0 = discontinuity; remaining bits are zero |
| 6 | 2 | header byte length, currently `24` |
| 8 | 8 | unsigned host-clock presentation timestamp in microseconds |
| 16 | 4 | unsigned sequence, wrapping modulo 2^32 |
| 20 | 2 | frame count per channel, currently `960` |
| 22 | 2 | payload byte length |
| 24 | rest | raw Opus packet, or exactly 3,840 bytes of interleaved stereo S16LE PCM |

A new client and the first packet after a per-client drop carry discontinuity. The browser must clear decoder/output state on discontinuity or a sequence gap. The Opus path starts after about 60 ms in its bounded worklet ring. The PCM fallback schedules about 60 ms before starting and clears the complete scheduled timeline instead of exceeding about 240 ms. One slow client never queues audio for or blocks another client.

The browser sends a JSON `ping` with a non-security-sensitive correlation ID at least every five seconds; the server replies with `pong`. The server closes an audio socket after 15 seconds without inbound traffic.

## Control: `/ws/control`

All messages are UTF-8 JSON objects with `v: 1`. The maximum message is 4 KiB. Coordinates are normalized to the uncropped source image: top-left `(0,0)`, bottom-right `(1,1)`.

### Browser to server

Pointer:

```json
{
  "v": 1,
  "type": "pointer",
  "seq": 17,
  "phase": "down",
  "x": 0.45,
  "y": 0.72,
  "buttons": 1,
  "pointerType": "touch",
  "clientTimeMs": 1787640000123.5
}
```

- `phase`: `down`, `move`, `up`, or `cancel`.
- `buttons`: `1` while pressed, `0` for release/cancel.
- `x` and `y` must be finite and within `[0,1]`; reject rather than clamp invalid input.
- The browser derives these coordinates from the source image's actual `object-fit: contain` rectangle. A press in letterboxing is ignored; an already-active drag moving into letterboxing is clamped to the nearest source edge.
- `seq` is an unsigned 32-bit client sequence.
- The browser limits drag moves to 60 Hz and always sends the final pressed coordinate before `up`.
- On blur, hidden visibility, pointer cancellation, disconnect, or session expiry, both ends release any held pointer.

Keyboard:

```json
{
  "v": 1,
  "type": "key",
  "seq": 18,
  "phase": "down",
  "code": "KeyA",
  "key": "a",
  "modifiers": {"alt":false,"control":false,"meta":false,"shift":false},
  "repeat": false,
  "clientTimeMs": 1787640000130.1
}
```

`phase` is `down` or `up`. The backend maps DOM `key`/`code` to RFB keysyms and releases all held keys on socket close.

Command:

```json
{"v":1,"type":"command","seq":19,"name":"home","clientTimeMs":1787640000140.2}
```

`name` is exactly `home` or `lockWake`.

Liveness:

```json
{"v":1,"type":"ping","id":"<opaque correlation ID>","clientTimeMs":1787640000150.4}
```

### Server to browser

Send state immediately after upgrade and whenever it changes:

```json
{
  "v": 1,
  "type": "state",
  "control": "connected",
  "usbVideo": "connected",
  "deviceName": "iPhone (USB)",
  "width": 1179,
  "height": 2556
}
```

State values are `connected`, `connecting`, or `disconnected`.

Reply to every ping:

```json
{"v":1,"type":"pong","id":"<same correlation ID>","clientTimeMs":1787640000150.4,"serverTimeMs":1787640000166}
```

Recoverable protocol/runtime error:

```json
{"v":1,"type":"error","code":"control_unavailable","message":"...","recoverable":true}
```

Unknown message types, invalid bounds, malformed JSON, or impossible pointer transitions must not reach RFB input. Repeated invalid input closes with `1008`.

## Browser microphone over `/ws/control`

Microphone input is binary on the already-authenticated control WebSocket. It
uses the same 28-byte `IUMC` envelope as the native client; it is not JSON and
does not open another phone or Mac port. Header integers are network byte order
and PCM is mono 48 kHz S16LE.

```text
magic IUMC, version 1
flags START=1, STOP=2, DATA=4
streamID u32, packetSequence u32, captureTimestampUsec u64
sampleCount u16, channels=1, format=1
```

Browser DATA messages contain exactly 960 samples/1,920 PCM bytes, so each
binary WebSocket message is 1,948 bytes. START and STOP contain no samples and
are 28 bytes. The server accepts at most 60 DATA packets per second, validates
wrap-aware sequence increase, and rejects malformed or non-owner messages.

The browser may start only while it holds the one control lease. It creates a
non-zero random stream ID, sends START as a critical message, and waits at most
1.5 seconds for a matching server `microphoneState: active` revision before
enabling the local track and AudioWorklet. The service sends `ready`, `active`,
`busy`, or `unavailable` state; Console and all web clients share one global
microphone owner.

The browser's WebSocket `bufferedAmount` limits are two DATA messages (3,896
bytes) for a normal soft reject and three messages (5,844 bytes) for a critical
hard close. A failed DATA send stops the stream instead of queueing old speech.
STOP is critical; a failed STOP resets the control socket. Blur, `pagehide`, a
hidden document, pointer cancel/up, loss of control, track end, WebSocket close,
or component teardown all stop capture and release ownership.

The server's microphone watchdog is 1.5 seconds. START not followed by valid
PCM, or an active stream without valid PCM, is stopped; removing this failure
closure is not a compatibility fix. The phone relay independently has the same
1.5-second valid-PCM safety boundary.

## Current liveness and rate limits

- control client heartbeat every 2 seconds; browser closes after 8 seconds
  without a matching pong; server checks every 4 seconds and closes after more
  than 12 seconds without valid client traffic;
- pointer state transitions at most 40/s, key events at most 120/s, commands at
  most 10/s, and rendered drag moves at most 60 Hz;
- video decoder queue above four frames resets and waits for an IDR; 2.5 seconds
  without packets or decoded frames requests resync, and 5 seconds reconnects;
- authentication allows 16 sessions. Video sinks allow 16, and Opus plus PCM
  audio sinks share a separate combined limit of 16. Only one web control lease
  and one native-or-web microphone owner exist.
