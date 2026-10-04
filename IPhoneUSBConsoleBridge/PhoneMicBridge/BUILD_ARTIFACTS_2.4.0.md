# Phone microphone bridge 2.4.0 build record

Build date: 2026-08-31 (Asia/Shanghai)

This record covers production source closure and clean local packaging of the
paired bridge and TrollVNC packages. It supersedes the audit-invalidated 2.3.0 /
3.2-287-perf2-mic15-demand13 pair. Neither package was installed, uploaded,
deployed, or exercised against a live recording application.

## Frozen artifacts

| Artifact | Package metadata | Bytes | SHA-256 |
|---|---|---:|---|
| `/Users/zhaogongzi/Documents/手机远控/IPhoneUSBConsoleBridge/PhoneMicBridge/packages/local.iphone.usbmic_2.4.0_iphoneos-arm64.deb` | `local.iphone.usbmic` 2.4.0, iphoneos-arm64, Installed-Size 500 KiB | 86,132 | `30bc96a5bf3e472ee276a26d7eb72fd65ea1a3a93783e2513f2a842d2ae4df27` |
| `/Users/zhaogongzi/Downloads/iPhone-USB-Console-Source-2026-08-30/trollvnc-perf-fix/packages/com.82flex.trollvnc_3.2-288-perf2-mic16-demand14_iphoneos-arm64.deb` | `com.82flex.trollvnc` 3.2-288-perf2-mic16-demand14, iphoneos-arm64, Installed-Size 5,724 KiB | 1,515,198 | `d1f8d203eaaff744839455876657302aec2d97e66ccaea5dbc019480235e0a15` |

The packaged bridge control member contains this exact dependency:

```text
firmware (>= 15.0), mobilesubstrate,
com.82flex.trollvnc (>= 3.2-288-perf2-mic16-demand14)
```

The packaged TrollVNC control member requires `firmware (>= 15.0)`, matching
its iOS 15 minimum deployment target. No TrollVNC functional source was changed
for this pair; its `Makefile` package version alone was synchronized to the new
pair identifier.

The final staged payloads and the corresponding archive members were compared
byte-for-byte by SHA-256. `IPhoneUSBMic.dylib` contains `arm64` and `arm64e`;
`IPhoneUSBMicD` and `trollvncserver` are `arm64`.

## Clean package builds

Bridge, from
`/Users/zhaogongzi/Documents/手机远控/IPhoneUSBConsoleBridge/PhoneMicBridge`:

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

Both clean package builds completed without compiler errors. TrollVNC's
preference bundle emitted only its existing iOS 15 `SecKeyGeneratePair`
deprecation warning for arm64 and arm64e. The linker also emitted its existing
`-multiply_defined is obsolete` warning. The toolchain was Xcode 26.6 (17F113)
with Theos commit `5280bd038207e14f8bd76f5417aa2fe641c03228`.

## 2.4.0 direct delegate completion closure

- Direct `AVCaptureAudioDataOutput setSampleBufferDelegate:queue:` operations
  now belong to the exact output sentinel. Entry joins its transaction,
  increments the in-flight count, captures and retires the published binding,
  and leaves the Apple call outside every output, sentinel, and delegate lock.
- Requested delegate classes are hooked before AVFoundation can enqueue their
  first callback, but requested identity is never published as authoritative
  binding state. Each Apple return or exception immediately allocates a
  completion revision in actual return order while retaining its in-flight
  registration until all observed queue debts are recorded.
- Only the operation releasing the last in-flight registration converges, using
  the sentinel's newest completion revision and a stable double-read of Apple's
  actual delegate/queue pair. Thus an older nil/error completion cannot perform
  a post-call fail-close against a later successful binding.
- Reconciliation failure may invoke Apple's nil setter only after reserving a
  new exact current cleanup transaction. A newer setter either joins that
  transaction or supersedes the reservation; no unconditional old cleanup can
  clear its result. Apple and cleanup exceptions retain completion/debt effects,
  while the original setter exception remains primary.

## 2.4.0 direct callback-generation closure

- Every authoritative actual delegate/queue pair receives a fresh, non-reused
  direct binding generation. It is published as pending and retired; lifecycle
  events only record desired active state and cannot arm it early.
- Published, requested, pre-call, post-call, alternate, and final callback
  queues add asynchronous debt to one persistent per-output group. Obsolete
  completion tokens lose publication authority but retain their debts, so
  same-delegate `Q0 -> Q1 -> Q2` waits for every old queue tail.
- After all debts clear, one asynchronous barrier on the exact actual queue
  revalidates output/sentinel identity, transaction and completion revisions,
  delegate and queue identities, pending binding generation, and authoritative
  session/output activity before activation. No callback queue is synchronously
  waited.
- Direct callback lookup and callback-side arm each independently require the
  output sentinel's exact active generation and reject pending, unsafe,
  retired, wrong-generation, or lifecycle-inactive boxes. Old queued callbacks
  therefore see only silence and can neither reacquire demand nor fill a new
  generation.
- Delegate sentinels retain old generation boxes until their exact queue debt
  clears, then untrack only that box. Delegate/output deallocation and rollback
  use non-reused box identity, output/sentinel identity, delegate identity, and
  generation checks, so they cannot retire a current replacement.
- Public libdispatch global/root queues are rejected by exact global-queue
  identity and the `com.apple.root.` label family. Observing one permanently
  disables direct activation for that output; ambiguous pairs likewise remain
  fail-closed and use only ordered exact cleanup.
- The nested lock order is output monitor to output sentinel (or synchronizer
  sentinel). Direct delegate retention/untracking occurs only after those locks
  are released; no custom lock spans AVFoundation or a queue barrier.

All earlier AudioUnit generation, Audio Queue lease, synchronized AVCapture,
session/output/connection ownership, configuration/topology revision,
synchronizer publication and delegate transaction, critical delegate-hook,
authenticated I/O, daemon work-budget, demand revision, and bounded TrollVNC
Stop/slow-client closures remain present. Their wire and concurrency invariants
are consolidated in `PROTOCOL.md`.

## Critical source SHA-256

| Source | SHA-256 |
|---|---|
| `tweak/Tweak.xm` | `9b2265bdf205ab04a310678c57502249613916387567056eeb156e1f39f53bc5` |
| `tweak/MicStreamClient.c` | `ade354bbd9ae572e2cca03bba3d456300c8c7ec576193aefdc1ccd68a04545a2` |
| `daemon/main.c` | `3199556d4a99bfd971ecf774c7d5f35d187da6de271a5bdb7ae8f045d4af7169` |
| `include/IUSCMicProtocol.h` | `deb279c120b3e0b4b29b67d273bc64e059ece21f2aafd81b4fb4fa15ddb9bc86` |
| `TrollVNC/IUSCMicRFBIngress.mm` | `bf89d828bb2dcbcd25cd410e7cf8f32c38180e8568d439dac6c9900c69af8e70` |
| `control` | `e2b915c1db891cea92744828b2bc166674266b9604c6f97af8f73241123df31f` |
| `README.md` | `de9275b2fb67583728e2f5a2f47e54c4bc0567df49ae14b2be50cf421d2a376a` |
| `PROTOCOL.md` | `f25dbaf8025205ea3862a0e90f4273b32ac9b741e830c6d81826365a1fde8a96` |
| paired TrollVNC `Makefile` | `06ab35857fcd8a9cb96a827ac9ed71082685f58c667e945347829b5266968813` |
| paired TrollVNC `layout/DEBIAN/control` | `3f3143838b74fc312f08de7707d4873e6d82d76bed13936dca9d29e8bc88cbb7` |

## Packaged payload SHA-256

| Payload | SHA-256 |
|---|---|
| bridge `IPhoneUSBMic.dylib` | `227a9bd1a464b6dc57f7cb8875470b0918fb0d8549cee898b1c167036e23525e` |
| bridge `IPhoneUSBMicD` | `2f3e158fdb0aad24cbed6bbeb0cd7e7ac94c1b24d7a023667c8f3598394a201f` |
| paired TrollVNC `trollvncserver` | `f421b8664d945caee8c21063aa6de2aa01546e58d733f12c7d26b3d54231d61b` |

## Deployment and verification boundary

No package install, upload, daemon restart, respring, UI action, alert, or other
deployment action was performed. The requested clean compilation, package
metadata/archive inspection, architecture inspection, and hash comparison were
performed; no live-device or application runtime test was requested or run.
Build success does not establish live-device behavior. This frozen pair remains
pending independent read-only regression before any separately authorized
deployment.
