# iPhone USB microphone protocol

The upstream is not a new phone TCP service. It reuses the existing USB-only,
Classic-VNC-authenticated RFB input connection. Each microphone packet is the
payload of a standard RFB `ClientCutText` message (type `6`, three padding bytes,
big-endian 32-bit payload length). TrollVNC consumes the reserved payload before
clipboard decoding.

## `IUMC` envelope

The header is exactly 28 bytes. Integer fields are big-endian. PCM is mono,
48,000 Hz, signed 16-bit little-endian.

| Offset | Bytes | Field |
|---:|---:|---|
| 0 | 4 | ASCII `IUMC` |
| 4 | 1 | version `1` |
| 5 | 1 | flags: START `1`, STOP `2`, DATA `4` |
| 6 | 2 | header length `28` |
| 8 | 4 | stream ID |
| 12 | 4 | packet sequence |
| 16 | 8 | capture timestamp, microseconds |
| 24 | 2 | mono sample count |
| 26 | 1 | channels `1` |
| 27 | 1 | format `1` (S16LE) |
| 28 | N | `sampleCount * 2` PCM bytes when DATA is set |

START may be combined with the first DATA packet. STOP has no PCM. A malformed
reserved packet is consumed and rejected; it is never interpreted as clipboard
text. A view-only RFB session may not own a microphone stream. One full-control
RFB client owns the stream until STOP or disconnect.

## Automatic microphone-demand envelopes

An authenticated full-control RFB client opts in by sending one exact 16-byte
`IUMH` payload through `ClientCutText`: magic `IUMH`, version `1`, flags `0x01`,
big-endian header size `16`, a random nonzero 32-bit client nonce, and four zero
reserved bytes. Malformed or view-only `IUMH` is consumed but never registered.

TrollVNC sends `IUMD` only to clients that completed that opt-in. `IUMD` is an
exact 16-byte binary `ServerCutText` payload:

| Offset | Bytes | Field |
|---:|---:|---|
| 0 | 4 | ASCII `IUMD` |
| 4 | 1 | version `1` |
| 5 | 1 | aggregate state: idle `0`, active `1` |
| 6 | 2 | header length `16` |
| 8 | 4 | nonzero aggregate generation |
| 12 | 4 | active local capture-source count |

Idle always carries count `0`; active always carries a positive count. The
generation changes only on an idle/active edge or a local daemon epoch change.
Count changes inside one active epoch retain the same generation. A newly
capable RFB client receives the current snapshot immediately, not only future
edges.

## Phone-local relay

TrollVNC forwards validated envelopes as nonblocking Unix datagrams to
`/var/mobile/Library/Caches/local.iphone.usbmic/ingress.sock`. The launch daemon
runs as `mobile`, validates stream ordering, and fans out a framed byte stream to
authenticated tweak consumers on `127.0.0.1:29877`. This loopback listener is
not the upstream and cannot inject audio.

Each consumer also sends fixed 16-byte `IUMQ` reports on that authenticated
connection. `IUMQ` has the same state/generation/count layout as `IUMD`, with
magic `IUMQ`; its generation changes on each per-process count change. The
daemon aggregates all live consumer connections and automatically removes a
process's demand when its connection closes.

TrollVNC subscribes to the daemon through one persistent local Unix
`SOCK_SEQPACKET` channel at
`/var/mobile/Library/Caches/local.iphone.usbmic/demand.sock`. Every connection
receives the current `IUMD` snapshot before later updates. Disconnect is
published as a fresh idle epoch; reconnect receives another current snapshot.
The daemon accepts only a peer with its own rootless `mobile` UID/GID and the
`trollvncserver` process role. A new trusted monitor replaces the previous one,
so idle local connections cannot fill a subscriber pool.

Consumers use a 32-byte HMAC-SHA256 challenge-response with the per-deployment
key embedded in the daemon and tweak. The external `IUMC`/`IUMD` protocol stays
at version 1; the phone-local authentication exchange is explicitly version 2.
Its 40-byte `IUAO` result carries an HMAC over the exact challenge (including
its nonce) and the result header/status, so a consumer verifies the daemon before
accepting any PCM. Slow consumers are disconnected at a bounded 64 KiB backlog
rather than allowing unbounded memory or corrupting packet framing. A complete
authentication exchange has a 300 ms monotonic deadline and advances as a
nonblocking state machine in the main poll loop. A full consumer table rejects a
new socket before authentication. Each authenticated consumer gets at most eight
report reads and sixteen output writes per event-loop pass; ingress is separately
drained in bounded batches.

The three authentication records are fixed at 40 bytes. Bytes 0–3 are `IUAC`,
`IUAR`, or `IUAO`; byte 4 is local-auth version `2`; byte 5 is zero for challenge
and response and is the allow/deny status for result; bytes 6–7 are big-endian
length `40`. `IUAC` bytes 8–39 are the random nonce. `IUAR` bytes 8–39 are
`HMAC(secret, complete IUAC)`. `IUAO` bytes 8–39 are
`HMAC(secret, complete IUAC || IUAO[0..7])`. All reserved fields, lengths, tags,
and the result status are validated before the connection becomes a PCM source.

The relay records monotonic time only for accepted, sequence-valid PCM. If an
active stream receives no valid PCM for 1.5 seconds (or START is never followed
by PCM), it broadcasts a synthetic STOP and clears the active stream. A later
START or DATA packet begins a fresh stream, so a dropped STOP cannot leave app
microphones permanently silenced.

## Injection behavior

- local demand idle: original physical microphone bytes pass through unchanged;
- local demand active before IUMC START/DATA: immediate silence, never the
  physical microphone;
- demand active with remote PCM: 48 kHz mono is converted to the app's PCM
  layout and sample rate;
- demand active with underflow, disconnect, or unsupported layout: silence;
- only the final local demand-idle edge restores physical-microphone passthrough.

Hook coverage is `RemoteIO` / `VoiceProcessingIO` (`AudioUnitRender` bus 1),
classic and dispatch-block Audio Queue input, direct
`AVCaptureAudioDataOutput` delegates, and audio entities delivered through
`AVCaptureDataOutputSynchronizer`. MovieFile, LivePhoto, video, metadata, and
depth entities are not modified. AudioUnit Start/Stop/Dispose and Audio
Queue Start/Stop/Pause/Reset/Dispose drive source lifecycle; Prime and Flush are
intercepted without creating microphone demand. Audio Queue Stop(false) retains
demand until the actual `kAudioQueueProperty_IsRunning=0` edge. Reset clears the
PCM cursor but preserves demand and running state unless that same property
reports a real stop. Queue callbacks use a fixed 256-slot generation-tagged
pool: the real input buffer is cleared before slot lookup, Dispose retires the
slot, and a single atomic gate closes new lease admission before the nonblocking
reaper waits for all existing leases to leave. Only then are non-atomic fields
cleared and the slot recycled; stale-generation callbacks stay silent. The
classic wrapper copies its callback/user-data pair and releases the slot lease
before entering application code, allowing synchronous Dispose without pinning
reclamation. AudioUnit slots are fixed and reusable; Start, Stop, Dispose, and
input EnableIO operations each reserve a new generation before calling Apple.
Only the newest generation may commit. Successful Start publishes demand and
clears fail-closed state together under the render exclusion gate; every other
completion stays silent. A Render error, untracked/unknown bus-1 input unit, or
configuration race clears the target buffer before returning.
Confirmed input creation/configuration fails rather than falling back to an
untracked physical-microphone path when capacity is exhausted. AVCapture
session start/stop, exact-session stop/runtime-error/interruption/recovery
notifications, output add/remove, delegate removal/deallocation, and the first
audio callback cover its lifecycle and binding races. Session output work is
exception-isolated per output. Each lifecycle event owns a monotonically
increasing observer revision and may update only outputs already carrying that
observer's exact session/epoch marker. Before every snapshot item publishes an
edge, it rechecks the revision, current `session.outputs` membership, and the
tracked epoch against the associated ownership marker. Notifications never
claim membership. `addOutput:` and `addOutputWithNoConnections:` claim only
after the original method succeeds, with a second membership check at claim and
again at commit. Remove invalidates the prior revision and untracks the exact
epoch before AVFoundation; afterward it either reclaims a still-present member
from a fresh epoch or conditionally converges the remaining outputs. An original
remove exception is preserved while cleanup remains fail-closed. Retirement and
observer deallocation affect a binding only while that exact epoch remains
current, so migration to another session cannot be reclaimed or retired by the
old observer. Each audio `AVCaptureConnection` carries a weak association token
containing its object identity, a globally fresh association epoch, the exact
session and observer, and the output-owner epoch. The token is installed and
captured atomically under the connection monitor. Its in-flight count and
completion revision belong to that immutable association epoch, not to the
connection object globally. A wrong-session add/remove that captures no exact
token cannot advance, clear, or complete the current owner's revision domain.
A later handoff creates a fresh token/revision domain, making old-token cleanup
a no-op; an old completion may only request a new authoritative convergence by
the currently installed exact owner.

Automatic connections are discovered after both output-add APIs and during
synchronizer sentinel initialization. Session `beginConfiguration` increments a
nested configuration depth and establishes a demand barrier. Every output,
input, and explicit connection mutation advances that same topology revision
before and after AVFoundation; inside a configuration transaction it remains
dirty for the outer commit. Only a successful outermost `commitConfiguration`
clears the barrier after an authoritative scan of `session.outputs` and every
audio output's current connections. The scan checks the revision before each
snapshot item and before committing. A changed revision aborts and performs a
bounded fresh-snapshot retry, or defers while a mutation/outer configuration is
still open. A stale single connection can therefore never turn into a
session-wide inactive commit. On a stable revision, an output whose connections
cannot be confirmed remains individually fail-closed while other confirmed
outputs converge normally; a later authoritative scan can clear dirty state.
The scan establishes missing exact associations, clears only still-current
absent tokens, and uses a fresh current-owner observer revision to update direct
and synchronizer lifecycle markers. `addInput:`, `removeInput:`, and
`addInputWithNoConnections:` use the same barrier and scan immediately when
outside a transaction. A commit or input exception preserves AVFoundation's
exception and converges the actually visible topology fail-closed. No custom
association/configuration monitor is held across AVFoundation.

Before an add, remove, or `setEnabled:` transition enters AVFoundation, its
atomically captured exact token increments that token's in-flight count and is
made fail-closed. Hook-entry order does not decide completion order. Each return
or exception from AVFoundation allocates a completion revision only in the
still-current exact token's domain, validates that revision/token at submission,
and reads every connection's actual `isEnabled`/`isActive` state at the observer
commit. While another operation remains in flight, the whole exact output stays
silent; the final completion then converges the final Apple-visible state. An
unconfirmed connection likewise keeps only its exact output fail-closed, so a
second active connection cannot undo pre-silence or per-output scan failure. A
successful enable/add can re-arm a previously retired direct binding and
synchronizer marker; disable/removal retires demand immediately when no live
audio connection remains. Removal and rescan clear only their captured exact
token, so re-entrant migration and ABA reuse cannot lose a new association.
Association deallocation revalidates the exact owner epoch and cannot affect a
migrated output. Session lifecycle events remain responsible for later
`isActive` changes caused by session configuration; the iOS 11+ audio-active
default is not used in place of the explicit enabled-state hook.

A data-output synchronizer publishes its sentinel association before exposing
any audio-output marker. For each output, the live-owner conflict check, exact
current-owner lifecycle snapshot, marker owner/active initialization, sentinel
slot installation, and marker association are one output-monitor transaction.
Lifecycle publication performs its marker lookup and exact sentinel update under
that same monitor, so it is ordered either before the publisher's snapshot or
after the complete exact marker. Nested locking is always
`output monitor -> synchronizer sentinel`; rollback snapshots and retires
sentinel state before taking output monitors and clears only exact markers. Two
concurrent synchronizers can therefore never both own the same output, and a
loser cannot clear the winner. A completed publication rereads and converges
each exact output once more under the same order.

`AVCaptureDataOutputSynchronizer setDelegate:queue:` is a completion-ordered
transaction. Entry increments the sentinel's setter-in-flight count and retires
all published bindings, then calls AVFoundation without holding any custom lock.
Every normal or exceptional return allocates the next completion revision in
return order and decrements the count. Only a still-latest revision with no
setter in flight may double-read one stable actual Apple delegate/queue pair,
confirm its class hook, start the client, allocate fresh exact per-output boxes,
and publish them as a retired pending generation. The requested delegate class
is defensively hooked before AVFoundation may synchronously enqueue its first
callback, but requested identity never becomes authoritative binding state.

Every published, requested, pre-call, post-call, and final callback queue adds
an asynchronous drain debt to one persistent per-sentinel group after the Apple
setter returns or throws. Obsolete completion tokens lose publication authority
but retain their queue debts, so `D0/Q0 -> D0/Q1 -> D0/Q2` cannot discard the Q0
or Q1 tail. Once all debts have crossed their queue FIFO/barrier, an asynchronous
barrier on the exact final queue revalidates the sentinel transaction,
completion revision, delegate and queue identities, pending binding generation,
and every output slot before arming from current lifecycle state. No path waits
synchronously on a callback queue. Libdispatch global root queues are rejected:
their barriers have ordinary-async semantics, so observing one permanently
disables activation for that synchronizer and triggers ordered nil cleanup.
Main and application-private serial queues have FIFO ordering; private
concurrent queues use real barrier ordering. A newer entry or completion makes
an older activation block a no-op, while its drain debts still complete. Actual
nil remains retired. Hook, allocation, tracking, getter, queue-pair, or
reconciliation failure reserves a new ordered cleanup operation, calls Apple's
nil setter outside custom locks, and converges again; the original setter
exception remains primary. Callbacks queued for the superseded delegate can run
only before the pending generation is armed and therefore resolve retired state.

Synchronizer callbacks resolve each audio entity by its exact
synchronizer/output/delegate binding, clear that entity's real block, then fill
only that entity from its own cursor. Synchronizer delegate setup starts the
transport before replacement bindings can arm or acquire demand. Delegate classes publish hook readiness
only after hook installation completes. Replacement IMP allocation failure and
registry allocation failure are fail-closed. The 15 critical C trampolines form
one gate: if any original trampoline is absent, the target process fail-stops in
the constructor before `%init` rather than running partial interception. The bridge
daemon and TrollVNC service/manager are excluded before hook initialization.

Direct `AVCaptureAudioDataOutput setSampleBufferDelegate:queue:` state belongs
to the exact output sentinel. Setter entry joins a per-output transaction,
retires the published binding, and increments the in-flight count before calling
AVFoundation without an output, sentinel, or delegate lock. Requested delegate
classes are hooked before that call but do not become authoritative binding
state. Immediately after every normal or exceptional Apple return, the operation
allocates its completion revision in actual return order. It records published,
requested, pre-call, post-call, alternate, and final queue debts before releasing
its in-flight registration. The operation that releases the last registration
converges from the newest completion revision and a stable double-read of Apple's
actual delegate/queue pair, regardless of hook-entry order.

Each successful convergence allocates a fresh, non-reusable direct binding box
and publishes it as a retired pending generation. The delegate sentinel retains
all retired generations until their exact persistent group debt crosses every
old callback queue. Obsolete completion tokens lose publication authority but
never remove Q0/Q1 debt, so same-delegate `Q0 -> Q1 -> Q2` cannot expose a new
box to an old queued callback. After all debts clear, an asynchronous barrier on
the exact actual queue revalidates output/sentinel identity, transaction and
completion revisions, delegate and queue identities, binding generation, and
authoritative session/output lifecycle before activating. Direct callback lookup
uses the output sentinel and accepts only that exact active generation; pending,
unsafe, wrong-generation, and retired boxes remain silent. Lifecycle edges only
record desired state while pending and cannot arm it early. Global/root queues
and ambiguous queue pairs permanently fail-close the output because their
barriers cannot prove tail drainage.

Nil, hook, allocation, getter, queue, or reconciliation failure first reserves a
new cleanup transaction only if the failing completion token is still exact,
then calls Apple's nil setter outside all custom locks. A later successful setter
therefore joins or supersedes that cleanup instead of being unconditionally
cleared by an old post-call fail-close. Apple and cleanup exceptions still record
their queue debts and completion order, and the original setter exception remains
primary. Delegate deallocation, output deallocation, rollback, callback lookup,
and debt release all target a non-reused exact binding generation. The nested
lock order is output monitor to output sentinel; delegate retention is changed
only after releasing both, and no callback-queue barrier is waited synchronously.
Session start and
stop converge in `finally` from authoritative `isRunning`/`isInterrupted`
state, including when AVFoundation throws, while preserving the first operation
exception. Failure to allocate the output lifetime sentinel is always
fail-closed.
Each AVCapture cursor has a nonblocking owner flag; concurrent callbacks remain
silent. The original
system capture call always
runs first, so app microphone permission and the iOS microphone privacy indicator
remain intact. Transport startup and socket work occur only off the real-time
callback. Client connect, authentication, demand-report writes, and framed reads
have monotonic deadlines. Every EOF or failure uses the same exponential
reconnect path; a connection must remain stable before the delay resets, and
thread-creation failure returns to a retryable idle state. Real-time paths
perform bounded atomic demand/stream operations and
zero/copy PCM; `AudioUnitRender` never performs first-time `pthread_once`,
thread creation, allocation, locks, dispatch, or socket I/O. AVCapture clears
the original sample's own `CMBlockBuffer` before injection and only writes
remote PCM into a safely addressable contiguous interleaved block. Unsupported
layouts remain silent; an immutable/non-addressable original sample is dropped
instead of forwarding physical microphone bytes.

## Final bounded-buffer invariants

- The wire parser permits at most 4,096 mono samples in one envelope. The
  current Mac sender deliberately emits exactly 960 samples (20 ms), so a DATA
  envelope is 1,948 bytes inside `ClientCutText` and 1,956 bytes including the
  outer RFB message header. START/STOP are 28 and 36 bytes respectively.
- A macOS input tap arrives in roughly 100 ms batches. One normal 48 kHz batch
  therefore becomes five adjacent DATA envelopes. The Mac RFB writer permits at
  most 12 pending microphone packets (240 ms); this is separate from the native
  capture handoff, which retains at most three input buffers and changes epoch
  when it drops stale work.
- The Unix datagram receiver requires `SO_RCVBUF >= 65,536` bytes before bind,
  drains no more than 128 ingress datagrams per event-loop pass, and fails
  closed if the kernel does not honor the requested buffer. TrollVNC checks
  every nonblocking `sendto()` result and records the first failure. This fixes
  the old 4 KiB queue behavior where only two of five 1,948-byte datagrams fit
  and the remainder failed with `ENOBUFS`.
- The relay accepts at most 32 authenticated local consumers. Each has a
  65,536-byte ring; a slow consumer is detached without blocking other app
  processes. Authentication is bounded to 300 ms and never exposes the embedded
  HMAC key in logs or documentation.

## App callback buffering and resampling

The injection ring contains 131,072 mono samples (about 2.731 seconds at
48 kHz). Priming is callback-size-aware:

```text
required = ceil(frameCount * 48000 / targetSampleRate) + 2
targetBuffered = required + 5760
hardResyncLag = targetBuffered + 48000 (capped by ring capacity)
```

The extra 5,760 samples are 120 ms of reserve after satisfying the complete
current callback; the extra 48,000 samples are a one-second hard-resync margin.
The implementation supports 8–192 kHz, 1–32 channel linear PCM in float32,
float64, or signed 8/16/24/32-bit layouts. It linearly resamples the mono source
and copies it into each requested channel.

Before reading any remote sample, the complete app callback buffer is zeroed.
If the ring cannot satisfy the whole callback, the format is unsupported, the
cursor is stale, or START/STOP changes generation while copying, the complete
callback remains silent. A rebuffer resumes only forward at a bounded live
position while preserving its fractional resampling position; it never emits a
valid prefix followed by a zero tail and never falls back to the physical mic
while a remote stream is active.

The local consumer reconnect schedule is 250, 500, 1,000, 2,000, 4,000, then
8,000 ms, holding at 8 seconds. Authentication success alone never resets that
delay or permits an immediate EOF reconnect; a connection must survive five
seconds to reset it. This reconnect behavior does not change the 1.5-second
valid-PCM watchdog in the relay.

TrollVNC serializes IUMH registration/initial snapshot sends and monitor-driven
broadcasts under an internal monotonically increasing revision. The current
snapshot is re-read inside that serialization point before an initial send, and
a stale revision cannot be sent after a newer one. Broadcast uses a 50 ms total
budget, never waits for an RFB client's send mutex, and uses one nonblocking
vectored write; a busy socket is skipped and a partial/corrupting write closes
that client. Monitor Start rejects a different live screen. Stop first retires
owner/stream/sequence/timestamp state and emits a best-effort STOP, then wakes the
local socket and waits at most two seconds for monitor-thread exit; failure to
converge is process fail-stop rather than an unbounded join before screen cleanup.
Ingress acceptance, state retirement, and the final datagram share one ordering
gate, so no already-accepted RFB packet can be forwarded after Stop's STOP and
no later packet can recreate ownership until a successful monitor Start.
Stop atomically takes ownership of the published demand-socket descriptor,
shuts it down, and closes it only after the monitor exits; the monitor closes a
descriptor only when that ownership transfer did not occur, preventing either
side from acting on a recycled descriptor number.
