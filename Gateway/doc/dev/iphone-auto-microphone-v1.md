# iPhone automatic microphone demand protocol v1

This protocol connects authenticated TrollVNC demand to an authenticated
`iphone-usb` WebRTC subscriber. It does not apply to Android drivers.

## RFB capability (`IUMH`)

After Classic VNCAuth succeeds and the complete RFB `ServerInit` is read, the
Gateway sends one RFB `ClientCutText` whose payload is exactly 16 bytes:

| Offset | Size | Value |
| --- | ---: | --- |
| 0 | 4 | ASCII `IUMH` |
| 4 | 1 | version `1` |
| 5 | 1 | flags `0x01` (`auto-demand`) |
| 6 | 2 | header size, BE16 `16` |
| 8 | 4 | cryptographically random non-zero client nonce, BE32 |
| 12 | 4 | zero (reserved) |

## RFB demand (`IUMD`)

The phone sends an RFB `ServerCutText` whose payload is exactly 16 bytes:

| Offset | Size | Value |
| --- | ---: | --- |
| 0 | 4 | ASCII `IUMD` |
| 4 | 1 | version `1` |
| 5 | 1 | state: `0` idle, `1` active |
| 6 | 2 | header size, BE16 `16` |
| 8 | 4 | non-zero demand generation, BE32 |
| 12 | 4 | active demand count, BE32 |

An `IUMD` magic with any invalid envelope field terminates the RFB control
connection. `state=active` additionally requires `activeCount>0`, and
`state=idle` requires `activeCount=0`; a mismatch is a protocol failure and
also terminates the connection. Non-`IUMD` clipboard messages are consumed and
ignored. RFB loss publishes an idle snapshot for the last known generation;
the independent phone video and downlink-audio transports continue running.

Generation values are opaque epochs. Consumers compare them only for equality;
numeric ordering and wraparound are not meaningful.

## Reliable WebRTC control channel

The `microphone-control` DataChannel must be ordered and reliable. The Gateway
sends UTF-8 JSON text frames:

```json
{"v":1,"type":"microphoneDemand","state":"active","generation":42}
```

The state is `active` or `idle`. A newly authenticated `iphone-usb` subscriber
receives the current snapshot when its channel opens. The controller accepts a
snapshot with a UTF-8 JSON text frame (not a binary frame):

```json
{"v":1,"type":"microphoneDemandAccept","generation":42}
```

The Gateway accepts it only while the current demand is active and the
generation is an exact match. The acceptance remains pending for at most two
seconds while the subscriber's negotiated remote Opus track becomes available.
Only one subscriber owns a microphone session; another subscriber cannot
preempt it.

The Gateway attaches its own monotonically increasing revision to each cached
demand snapshot. This revision is not sent on the wire and is unrelated to the
phone generation. It exists only to prevent an older subscriber snapshot from
overwriting a newer concurrent broadcast.

Gateway state replies are JSON text frames and include the bound generation:

```json
{"v":1,"type":"microphoneState","state":"active","generation":42,"streamID":1234}
```

## Full-duplex media and phone injection

The existing audio m-line is `sendrecv`: Gateway-to-controller Opus downlink is
unchanged, while the controller sends its microphone as WebRTC Opus RTP on the
same m-line. Automatic mode never transports PCM in a DataChannel.

On macOS with cgo, Gateway decodes remote Opus with the system AudioToolbox
`AudioConverter`. It converts 1- or 2-channel, 10/20/40/60 ms Opus packets to
48 kHz, mono, signed 16-bit little-endian PCM, buffers variable frame durations,
and emits exact 960-sample (20 ms)
chunks. No runtime package manager or third-party codec library is required. A
non-macOS/cgo-disabled build contains a rejecting decoder stub.

For an accepted automatic session the Gateway, not the controller, creates the
non-zero stream ID and sends authenticated RFB `ClientCutText` `IUMC` packets:

1. `START` with sequence 0.
2. Strictly increasing `DATA` sequence values, each carrying one 20 ms PCM
   chunk.
3. `STOP` with the next sequence value.

Every `DATA` send revalidates subscriber receipt, single-owner session token,
the subscriber's cryptographically random connection identity, Agent epoch,
stream, current demand state, and exact demand generation. Receipt numbers may
be reused, but connection identities are never reused. Demand idle, a new
generation, an Agent replacement, reliable control-channel loss, subscriber
loss, remote-track end, or the packet watchdog immediately clears ownership and
attempts `STOP` against the old Agent before publishing transport idle. PCM and
pending accepts cannot cross an Agent epoch.

The RFB reader starts only after the newly authenticated client is installed as
the driver's current writable RFB connection. Therefore an initial `IUMD`
cannot make the Gateway send `IUMC START` through a nil or retiring connection.

The legacy binary `IUMC` control/data DataChannels remain supported. Their
`START` must consume a current matching `microphoneDemandAccept`; they cannot
inject data into an automatic WebRTC-Opus session.
