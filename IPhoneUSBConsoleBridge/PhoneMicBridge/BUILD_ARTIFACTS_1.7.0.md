# Phone microphone bridge 1.7.0 build record

> Superseded and audit-invalidated on 2026-08-31. Do not install or deploy this
> pair. Use the 1.8.0 / 3.2-282 pair and `BUILD_ARTIFACTS_1.8.0.md` instead.

Build date: 2026-08-31 (Asia/Shanghai)

This record covers the production source closure and clean local packaging of
the paired bridge and TrollVNC packages. Neither package was installed on a
phone, copied to a remote host, nor exercised against a live recording app.

## Frozen artifacts

| Artifact | Package metadata | Bytes | SHA-256 |
|---|---|---:|---|
| `packages/local.iphone.usbmic_1.7.0_iphoneos-arm64.deb` | `local.iphone.usbmic` 1.7.0, iphoneos-arm64, Installed-Size 316 KiB | 41,122 | `4c27ec9f64ae70aaff0e675586901ba559ec903aba380cc9bfcc5a6dc4c1134a` |
| `/Users/zhaogongzi/Downloads/iPhone-USB-Console-Source-2026-08-30/trollvnc-perf-fix/packages/com.82flex.trollvnc_3.2-281-perf2-mic9-demand7_iphoneos-arm64.deb` | `com.82flex.trollvnc` 3.2-281-perf2-mic9-demand7, iphoneos-arm64, Installed-Size 5,724 KiB | 1,515,690 | `b77a4427f289a23bb37c750d83ea8db18f380666ca9cd541219cd90bbd527701` |

The packaged bridge control member contains this exact dependency:

```text
firmware (>= 15.0), mobilesubstrate,
com.82flex.trollvnc (>= 3.2-281-perf2-mic9-demand7)
```

The extracted packaged payloads were inspected, not inferred only from build
settings. `IPhoneUSBMic.dylib` contains `arm64` and `arm64e`; `IPhoneUSBMicD`
and `trollvncserver` are `arm64`.

## Clean package builds

Bridge, from `IPhoneUSBConsoleBridge/PhoneMicBridge`:

```sh
make clean package FINALPACKAGE=1 \
  THEOS=/tmp/iphone-usb-mic-theos
```

Paired TrollVNC, from
`/Users/zhaogongzi/Downloads/iPhone-USB-Console-Source-2026-08-30/trollvnc-perf-fix`:

```sh
make clean package FINALPACKAGE=1 \
  THEOS=/tmp/iphone-usb-mic-theos \
  THEOS_PACKAGE_SCHEME=rootless \
  TARGET=iphone:clang:latest:15.0 \
  PHONE_MIC_BRIDGE_DIR=/Users/zhaogongzi/Documents/手机远控/IPhoneUSBConsoleBridge/PhoneMicBridge
```

Both clean package builds completed successfully without compiler errors. The
TrollVNC preference bundle emitted its existing iOS 15
`SecKeyGeneratePair` deprecation warning for arm64 and arm64e. The toolchain was
Xcode 26.6 (17F113) with Theos commit
`5280bd038207e14f8bd76f5417aa2fe641c03228`.

## Critical source closure

- Every tracked AudioUnit Start, Stop, Dispose, and input EnableIO operation
  reserves a generation before calling Apple. Only the latest generation can
  commit. A latest successful Start publishes demand and clears fail-closed
  state together under render exclusion; all other outcomes stay silent.
  Render clears its target on Apple error, untracked bus-1 input, or a
  configuration/retirement race.
- The classic Audio Queue wrapper copies its application callback and user data,
  replaces or silences physical input, then releases its slot lease before
  entering application code. The dispatch wrapper has the same ordering.
- AVCapture session lifecycle work is exception-isolated per output. Observer,
  output, delegate, and synchronizer lifetimes retire their exact bindings.
  `AVCaptureDataOutputSynchronizer` callbacks touch only audio entities and use
  the exact synchronizer/output/delegate binding; each real sample block is
  cleared before lookup/fill. MovieFile, LivePhoto, video, metadata, and depth
  entities are not changed.
- Delegate-hook registry or replacement-IMP allocation failure is fail-closed.
  All 15 AudioUnit/Audio Queue original trampolines must be present before the
  readiness gate opens; a capture entry fail-stops the target process if the
  gate is incomplete. The bridge daemon and TrollVNC service/manager processes
  are explicitly excluded before hook initialization.
- The injected consumer uses bounded monotonic deadlines for nonblocking
  connect, authentication, demand reports, and framed reads. Every EOF/failure
  follows the same 250 ms through 8 s exponential backoff, and authentication
  success alone does not reset it. Thread-creation failure restores a retryable
  idle state; real-time callbacks never wait for networking.
- Daemon consumer authentication is a nonblocking poll state machine with one
  total deadline. It quickly rejects a connection when all 32 slots are full,
  and fixes report reads and output writes to per-consumer, per-pass budgets.
- TrollVNC serializes capable-client initial demand snapshots and monitor
  broadcasts by an internal revision, re-reading the current snapshot inside
  that serialization point. Broadcast has a 50 ms total budget and never waits
  for a client send mutex or blocking socket write. Monitor Stop independently
  retires owner/stream/sequence/timestamp state, sends best-effort STOP, and has
  a two-second fail-stop convergence bound. Demand-socket descriptor ownership
  transfers atomically to Stop and is closed only after monitor exit, avoiding
  close/shutdown against a recycled descriptor. Ingress acceptance, state
  retirement, and final STOP forwarding share one ordering gate, preventing a
  trailing accepted packet from recreating the retired stream.

## Phone-local protocol closure

- External `IUMC`, `IUMH`, `IUMD`, and `IUMQ` envelopes remain version 1.
- Phone-local `IUAC`/`IUAR`/`IUAO` authentication is explicitly version 2.
  The 40-byte `IUAO` tag authenticates the exact challenge/nonce plus the result
  header and allow/deny status; the consumer verifies it before accepting PCM.
- `demand.sock` accepts only the daemon's own mobile UID/GID and the
  `trollvncserver` process role. One trusted monitor owns the subscription; a
  new trusted instance replaces the old one.
- The daemon limits each authenticated consumer to eight demand-report reads
  and sixteen queued-output writes in one event-loop pass. Ingress is separately
  limited to 128 datagrams per pass.
- Initial RFB demand snapshots and monitor broadcasts share one revision
  serialization path, so an old idle snapshot cannot follow and overwrite a
  newer active notification.

The complete framing, deadlines, budgets, hook coverage, and failure semantics
are frozen in `PROTOCOL.md`.

## Critical source SHA-256

| Source | SHA-256 |
|---|---|
| `tweak/Tweak.xm` | `c7cb2a559c60bac69d1ec2cda7e699a95a03b48d4a2c1cdb2684d1721768af82` |
| `tweak/MicStreamClient.c` | `ade354bbd9ae572e2cca03bba3d456300c8c7ec576193aefdc1ccd68a04545a2` |
| `daemon/main.c` | `3199556d4a99bfd971ecf774c7d5f35d187da6de271a5bdb7ae8f045d4af7169` |
| `include/IUSCMicProtocol.h` | `deb279c120b3e0b4b29b67d273bc64e059ece21f2aafd81b4fb4fa15ddb9bc86` |
| `TrollVNC/IUSCMicRFBIngress.mm` | `bf89d828bb2dcbcd25cd410e7cf8f32c38180e8568d439dac6c9900c69af8e70` |
| `control` | `c88ae9de66e7ea2558effd1b282ba08fd05c873779a104c0b8bb58226a1cba74` |
| paired TrollVNC `Makefile` | `6f3367df9cb3b3f135a6e407d4d561de9d43aae7e454da6f3f6a2e60ff18f392` |

## Deployment boundary

No install, package upload, daemon restart, respring, or other deployment action
was performed. These clean-build and package-inspection results do not claim a
live-device recording outcome. A separately authorized deployment must install
the paired TrollVNC package before bridge 1.7.0 and then validate the target
AudioUnit, Audio Queue, direct AVCapture, synchronized AVCapture, reconnect, and
Stop/restart paths on the phone.
