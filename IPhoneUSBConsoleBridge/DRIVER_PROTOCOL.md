# iPhone USB Driver Unix Socket Protocol

The signed macOS process is a headless AVFoundation/VideoToolbox media driver.
It creates no window, Dock item, password field, local microphone UI, HTTP
listener, or WebSocket listener. The existing bundle identifier and Keychain
service remain unchanged so the installed capture permissions and the stored
DAL device binding continue to apply.

## Endpoints and ownership

The default state directory is `~/.remote-handset/iphone-console` and is mode
`0700`. On a successful start the driver creates these stream sockets, each
mode `0600` and owned by the logged-in user:

| Path | Direction | Payload |
| --- | --- | --- |
| `video.sock` | Driver to Gateway | H.264 configuration and AVCC access units |
| `audio.sock` | Driver to Gateway | Opus configuration and packets |
| `control.sock` | Bidirectional | Driver hello, ping/pong, request-key-frame |

The control socket does not proxy touch, keyboard, power, or microphone input.
Those operations belong to the Gateway's direct usbmux/RFB connection. This
keeps the media driver free of VNC credentials and removes the Console from the
runtime control path.

The driver refuses to remove an existing endpoint unless it is a Unix socket
owned by the current user. It also verifies the final socket type, owner, and
`0600` mode after each bind.

## Common frame

Every message starts with a 32-byte big-endian header followed by exactly
`payloadLength` bytes.

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | ASCII magic `IUSD` |
| 4 | 1 | protocol version, currently `1` |
| 5 | 1 | stream: video `1`, audio `2`, control `3` |
| 6 | 1 | message type |
| 7 | 1 | flags |
| 8 | 2 | header length, currently `32` |
| 10 | 2 | reserved, zero |
| 12 | 4 | payload length |
| 16 | 8 | host-clock timestamp in microseconds, or zero |
| 24 | 4 | sequence number, or zero |
| 28 | 4 | auxiliary value, or zero |

A receiver must reject the connection if the magic, version, stream, header
length, or declared payload length is invalid. Messages are framed over a
stream socket, so a receiver must not assume one `read(2)` call equals one
message.

## Video stream

Type `1` is UTF-8 JSON configuration:

```json
{
  "codec": "avc1.640028",
  "codedWidth": 720,
  "codedHeight": 1280,
  "description": "base64 AVCDecoderConfigurationRecord"
}
```

Type `2` is one AVCC access unit. Flag bit 0 means key frame. Timestamp and
sequence are populated. Clients receive the current configuration when they
connect and the driver requests a fresh key frame. Under backpressure the
driver bounds retained video to one access unit and forces resynchronization
instead of building latency.

## Audio stream

Type `1` is UTF-8 JSON configuration:

```json
{
  "codec": "opus",
  "sampleRate": 48000,
  "channels": 2,
  "frameDurationUs": 20000
}
```

Type `2` is one raw Opus packet. Flag bit 0 marks a discontinuity. Timestamp
and sequence are populated; the auxiliary field contains the PCM frame count.
If backpressure drops audio, the retained packet is marked discontinuous so
the downstream jitter buffer can reset explicitly.

## Control stream

The Driver sends type `0x81` immediately after accept. Its payload is UTF-8
JSON describing protocol version and confirming that device input is handled
by Gateway direct RFB.

Gateway may send:

- Type `1`: request an immediate H.264 key frame. Payload must be empty.
- Type `2`: ping. The Driver returns type `0x82`, preserving timestamp and
  sequence.

Unsupported commands receive type `0xff` with `unsupported_command` as the
payload. Control payloads larger than 64 KiB close the connection.

## Capture binding

The Driver uses `IUSC_CAPTURE_DEVICE_UNIQUE_ID` when explicitly configured;
otherwise it reads the previously paired DAL unique ID from the existing
Keychain item. It never selects the first available iPhone. If the exact DAL
source is absent or no binding exists, capture remains stopped and the status
file reports the corresponding pairing error.

## Status compatibility

The existing status file remains in place. Existing keys are retained and the
Driver adds:

- `driver_running`
- `video_socket_running`
- `audio_socket_running`
- `control_socket_running`

`web_running` remains present but is `0` because the headless process no longer
starts the legacy HTTP/WebSocket Console.
