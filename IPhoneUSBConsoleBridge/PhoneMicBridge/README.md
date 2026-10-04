# iPhone USB Microphone Bridge

This directory is the phone-side component for demand-aware microphone input in
the authenticated direct remote-control path. It targets the current device class: iOS 16.1.2, arm64e,
Dopamine rootless, and ElleKit.

It is deliberately microphone-only. It does not hook `mediaserverd`, bypass TCC,
hide the iOS microphone indicator, capture the physical microphone, or play audio
through the phone speaker as a substitute for true app-visible mic input.

## Build

Use current Theos on macOS with Xcode's iPhoneOS SDK:

```sh
THEOS=/absolute/path/to/theos make clean package FINALPACKAGE=1
```

The result is a rootless `iphoneos-arm64.deb` in `packages/`. Building alone
does not change the phone. Installation must be separately approved because it
adds an ElleKit dylib and a `mobile` launch daemon. Version `1.0.2` deliberately
does not respring, reload, or kill SpringBoard from `postinst`: it restarts only
`IPhoneUSBMicD`. Close and reopen the target recording app after installation so
ElleKit injects the new dylib into a fresh process.

Version `2.4.0` retains that non-respring installation behavior and closes the
remaining concurrent capture and recovery boundaries. Every AudioUnit lifecycle
operation is generation-linearized; only the newest successful Start can
atomically publish demand and leave fail-closed silence. Audio Queue callbacks
release their slot lease before entering application code. AVCapture tracks and
retires exact output/delegate bindings across session exceptions and observer
deallocation, including each audio entity in
`AVCaptureDataOutputSynchronizer` collections; MovieFile and LivePhoto outputs
are untouched. Every physical Audio Queue or `CMBlockBuffer` payload is cleared
before lookup or remote fill.

Session output ownership is generation-tagged and lifecycle events are
revision-linearized. Notifications may update only outputs already owned by the
exact observer/session/epoch; every item rechecks the event revision, current
session membership, and exact ownership epoch immediately before publishing its
lifecycle edge. Both output-add APIs claim only after AVFoundation returns
successfully and recheck membership before committing. Removing an output
invalidates the previous revision and untracks its exact epoch before entering
AVFoundation, then converges from authoritative post-call membership. A failed
remove preserves AVFoundation's original exception and leaves the old binding
fail-closed. Moving an output to another session therefore cannot be reclaimed,
retired, or rearmed by the old observer's later callback or deallocation.
`AVCaptureConnection` ownership is also weakly associated with a non-reusable
token containing the connection object, association epoch, exact session, and
output-owner epoch. Explicit connection add/remove, both output-add APIs,
synchronizer creation, and authoritative session-configuration rescans cover
automatic connections. Nested `beginConfiguration`/`commitConfiguration`
transactions remain demand-blocked until the successful outer commit scans all
current audio outputs and connections; every output, input, connection, and
configuration mutation advances the same pre/post topology barrier. A stale
scan aborts and retries from a fresh revision, while a stable failure to confirm
one output leaves only that exact output fail-closed and preserves confirmed
outputs. `setEnabled:` captures and pre-silences only its atomically associated
token at entry. After AVFoundation returns or throws, it allocates ordering in
that token owner's completion domain, revalidates the exact token, and reads
actual `isEnabled`/`isActive` at the observer-revision commit. In-flight
operations keep the output silent; the last Apple side effect to finish is
therefore converged from current state rather than suppressed by hook-entry
order. A wrong or migrated session cannot advance, clear, or complete the new
owner's revision domain. Connection removal and association teardown retire
demand immediately, while enabling or adding a live connection may re-arm both
direct and synchronizer bindings. Re-entrant migration, ABA reuse,
configuration exceptions, and an obsolete connection sentinel cannot update or
clear a newer owner. A synchronizer sentinel is associated with its
synchronizer before any output marker becomes visible. Each audio-output owner
conflict check, current lifecycle read, exact marker publication, and active
state publication is linearized under that output's monitor, with the only
nested order `output -> synchronizer sentinel`; lifecycle updates use the same
monitor and cannot fall into a publication gap. A losing concurrent
synchronizer removes only its own exact marker/sentinel state, and successful
publication finishes with authoritative per-output convergence. Synchronizer
delegate setters are completion-ordered transactions: entry retires the current
bindings and increments the in-flight count, AVFoundation runs without a custom
lock, and only the latest completion after all setters leave may read the actual
delegate, confirm its authoritative callback queue, start the local transport,
and publish fresh exact bindings in a retired pending generation. Every queue
observed or requested by an obsolete generation retains an asynchronous drain
debt. Only after all old queues have crossed their FIFO/barrier does a final
barrier on the exact current queue revalidate the sentinel, completion revision,
delegate/queue identities, and binding generation before arming. This covers
same-delegate `Q0 -> Q1 -> Q2`, reverse completion, exception, and re-entrant
setter tails without synchronously waiting on a callback queue. Global root
queues, whose barrier calls have no drain semantics, permanently keep this
synchronizer fail-closed. Nil, stale completions, and failed
hook/allocation/reconciliation paths remain retired; required Apple-delegate
cleanup is itself an ordered, lock-free `nil` setter. A requested delegate class
is defensively hooked before AVFoundation can synchronously enqueue its first
callback, but it never becomes authoritative binding state before completion.
The direct `AVCaptureAudioDataOutput` delegate setter now uses the same
completion-ordered discipline in the exact output sentinel. Entry retires the
published binding and records every published, requested, pre-call, post-call,
and final callback queue as persistent asynchronous drain debt, while the Apple
setter runs outside custom locks. Completion revision is allocated immediately
after each Apple return or exception; only the latest actual completion after
all in-flight setters leave may reconcile. Nil/error cleanup first reserves an
exact current transaction token, so an older cleanup cannot clear a later
successful binding. Every authoritative actual delegate/queue pair receives a
fresh, non-reused binding generation that stays pending and retired until all
Q0/Q1/Q2 debts and the final exact-queue barrier complete. Callback lookup,
lifecycle edges, delegate deallocation, and rollback all require the exact
active generation; an old callback can never find or arm a new generation.
Global/root or ambiguous queues permanently keep that output fail-closed, and
delegate sentinels retain retired generation boxes only until their exact drain
debt is paid.

The 15 critical AudioUnit/Audio Queue trampolines form one readiness gate;
failure of any trampoline terminates the target process in the constructor
before Objective-C capture hooks are initialized. Delegate replacement IMP
allocation failure is immediately fail-closed. The
tweak does not initialize its hooks in the bridge daemon, TrollVNC server, or
manager processes. Consumer authentication, frame I/O, and reconnects have
monotonic deadlines and exponential backoff; a failed client-thread creation is
retryable and real-time callbacks never wait for networking. The daemon uses a
nonblocking authentication state machine, challenge-bound authenticated server
results, fixed per-consumer work budgets, and one UID/process-validated demand
monitor. TrollVNC serializes initial snapshots with later revisions, skips or
closes slow RFB clients without waiting on their send mutex/socket, and gives
monitor Stop a bounded fail-stop convergence path after retiring stream owner,
ID, sequence, and timestamp state.

The paired TrollVNC source change lives in
`PhoneMicBridge/TrollVNC/IUSCMicRFBIngress.mm` and is compiled by the local
`trollvnc-perf-fix` fork identified in the current build record. That build must
be installed together with this
package; unmodified TrollVNC treats `ClientCutText` only as clipboard data.
Install the versioned TrollVNC package first, then this bridge package. The
bridge declares
`com.82flex.trollvnc (>= 3.2-288-perf2-mic16-demand14)` so a partial or
same-version installation cannot silently leave microphone input inoperative.
Both packages require iOS 15 or newer, matching the compiled minimum OS.

The current build pair is:

- `com.82flex.trollvnc_3.2-288-perf2-mic16-demand14_iphoneos-arm64.deb`
- `local.iphone.usbmic_2.4.0_iphoneos-arm64.deb`

The exact clean-build evidence, package metadata, sizes, hashes, and deployment
boundary for this pair are recorded in `BUILD_ARTIFACTS_2.4.0.md`.

The audit-invalidated `3.2-287-perf2-mic15-demand13` / `2.3.0`,
`3.2-286-perf2-mic14-demand12` / `2.2.0`,
`3.2-285-perf2-mic13-demand11` / `2.1.0`,
`3.2-284-perf2-mic12-demand10` / `2.0.0`,
`3.2-283-perf2-mic11-demand9` / `1.9.0`,
`3.2-282-perf2-mic10-demand8` / `1.8.0`, and
`3.2-281-perf2-mic9-demand7` / `1.7.0` pairs, and the
intermediate `3.2-280-perf2-mic8-demand6` / `1.6.0`,
`3.2-279-perf2-mic7-demand5` / `1.5.0`,
`3.2-278-perf2-mic6-demand4` / `1.4.0`,
`3.2-277-perf2-mic5-demand3` / `1.3.0`,
`3.2-276-perf2-mic4-demand2` / `1.2.0`, and
`3.2-275-perf2-mic3-demand1` / `1.1.0` pairs are superseded and must not be
installed: they do not provide all callback-tail lifetime, reclamation, and
original-`CMBlockBuffer` guarantees documented below.

The earlier frozen, device-installed pair was:

- `com.82flex.trollvnc_3.2-273-perf2-mic2_iphoneos-arm64.deb`
- `local.iphone.usbmic_1.0.2_iphoneos-arm64.deb`

Their exact sizes, hashes, device recovery record, and evidence boundary are in
`BUILD_ARTIFACTS.md`. Do not substitute `mic1`, bridge `1.0.0`/`1.0.1`, or an
older same-named package.

See `PROTOCOL.md` for framing, ownership, authentication, buffering, and failure
semantics, including the 1.5-second valid-PCM watchdog and the no-thread-start
real-time render invariant.
