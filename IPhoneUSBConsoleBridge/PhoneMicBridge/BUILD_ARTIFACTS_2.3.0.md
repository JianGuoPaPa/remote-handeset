# Phone microphone bridge 2.3.0 build record

Build date: 2026-08-31 (Asia/Shanghai)

> **Audit-invalidated candidate -- do not install or deploy.** The frozen 2.3.0 /
> 3.2-287 pair has two confirmed direct `AVCaptureAudioDataOutput` delegate
> state-machine P1s. First, nil/error cleanup performed an unconditional
> post-call fail-close without an exact completion token, so an older nil setter
> could retire a later successful delegate binding after Apple's side effect.
> Second, direct bindings were reused by delegate/output identity across setter
> generations with no old callback-queue drain; a queued Q0 callback could find
> the rearmed Q1 generation and acquire demand/fill after the output had been
> inactive. This historical artifact record is retained only for provenance and
> is superseded by the separately recorded 2.4.0 /
> 3.2-288-perf2-mic16-demand14 pair.

This record covers production source closure and clean local packaging of the
paired bridge and TrollVNC packages. It supersedes the audit-invalidated 2.2.0 /
3.2-286-perf2-mic14-demand12 pair. Neither package was installed, uploaded,
deployed, or exercised against a live recording application.

## Frozen artifacts

| Artifact | Package metadata | Bytes | SHA-256 |
|---|---|---:|---|
| `/Users/zhaogongzi/Documents/手机远控/IPhoneUSBConsoleBridge/PhoneMicBridge/packages/local.iphone.usbmic_2.3.0_iphoneos-arm64.deb` | `local.iphone.usbmic` 2.3.0, iphoneos-arm64, Installed-Size 464 KiB | 79,506 | `89b9342c1bca10610943165fa46d270ded34d560af76bbdefe5f3280d2ad2041` |
| `/Users/zhaogongzi/Downloads/iPhone-USB-Console-Source-2026-08-30/trollvnc-perf-fix/packages/com.82flex.trollvnc_3.2-287-perf2-mic15-demand13_iphoneos-arm64.deb` | `com.82flex.trollvnc` 3.2-287-perf2-mic15-demand13, iphoneos-arm64, Installed-Size 5,724 KiB | 1,515,934 | `77f6485c8f3e8fc92da83b75f7286737db605a0b7257778e1fd0a3d560970b20` |

The packaged bridge control member contains this exact dependency:

```text
firmware (>= 15.0), mobilesubstrate,
com.82flex.trollvnc (>= 3.2-287-perf2-mic15-demand13)
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

## 2.3.0 synchronizer publication closure

- A synchronizer sentinel is associated with its synchronizer before any
  per-output marker becomes visible. Each audio output is then handled under
  that output's monitor: the exact-owner conflict check, authoritative active
  read, marker ownership publication, and sentinel output-slot publication are
  one transaction.
- Lifecycle publication performs its marker lookup and exact sentinel update
  under the same output monitor. An edge is therefore ordered before the
  publisher's authoritative snapshot or after the complete marker; it cannot
  be lost in a partially published state.
- The only nested custom lock order is output monitor to synchronizer sentinel.
  Rollback first snapshots and retires the losing sentinel, then enters output
  monitors and removes only its exact marker. Two synchronizers cannot both
  claim one output, and a losing or deallocated sentinel cannot clear the
  winner's state.
- Successful publication finishes with an authoritative lifecycle reread and
  exact per-output convergence, so a lifecycle change during construction
  cannot leave stale marker state.

## 2.3.0 delegate transaction and callback-tail closure

- `AVCaptureDataOutputSynchronizer setDelegate:queue:` is an in-flight,
  completion-ordered transaction. Entry retires the currently published
  bindings before calling AVFoundation without any custom lock. Every normal
  or exceptional return allocates its completion revision in actual return
  order; only the exact latest revision after all setters leave may converge.
- Convergence re-reads the stable actual delegate and callback queue rather
  than publishing requested arguments. Requested delegate classes are hooked
  before AVFoundation can enqueue a synchronous callback, but requested
  identity never becomes authoritative binding state before completion.
- Fresh exact bindings are first published as a retired pending generation.
  Lifecycle updates cannot arm that generation. Activation revalidates the
  exact sentinel, transaction and completion revisions, delegate and queue
  identities, binding generation, output marker, and binding slot before
  applying each output's current active state.
- Every published, requested, pre-call, post-call, and final queue creates an
  asynchronous drain debt in one persistent per-sentinel group. Obsolete
  completion tokens retain their debts but lose publication authority. The
  newest generation therefore waits for all old queues before its final
  callback-queue barrier, covering same-delegate `Q0 -> Q1 -> Q2`, reverse
  completion, exception, and re-entrant setter tails without synchronous
  dispatch or waiting.
- Public libdispatch global/root queues are rejected by exact global-queue
  identity and the `com.apple.root.` label family because their barrier calls
  have ordinary-async semantics. Once such a queue is observed, that
  synchronizer remains permanently fail-closed; pending and activation paths
  independently recheck the permanent unsafe bit, and ordered nil cleanup is
  bounded.
- Nil actual delegates, stale completions, ambiguous delegate/queue pairs, and
  hook, allocation, tracking, or reconciliation failures leave bindings
  retired. Required Apple-delegate cleanup is itself an ordered nil setter
  invoked outside custom locks. Queued callbacks from retired generations can
  therefore resolve only retired binding state.

All earlier AudioUnit generation, Audio Queue lease, synchronized AVCapture,
session/output/connection ownership, configuration/topology revision, critical
delegate-hook, authenticated I/O, daemon work-budget, demand revision, and
bounded TrollVNC Stop/slow-client closures remain present. Their wire and
concurrency invariants are consolidated in `PROTOCOL.md`.

## Critical source SHA-256

| Source | SHA-256 |
|---|---|
| `tweak/Tweak.xm` | `9639ee96795321e47138263d97dc75e7ec133557854e55acf7193c88f82c76fa` |
| `tweak/MicStreamClient.c` | `ade354bbd9ae572e2cca03bba3d456300c8c7ec576193aefdc1ccd68a04545a2` |
| `daemon/main.c` | `3199556d4a99bfd971ecf774c7d5f35d187da6de271a5bdb7ae8f045d4af7169` |
| `include/IUSCMicProtocol.h` | `deb279c120b3e0b4b29b67d273bc64e059ece21f2aafd81b4fb4fa15ddb9bc86` |
| `TrollVNC/IUSCMicRFBIngress.mm` | `bf89d828bb2dcbcd25cd410e7cf8f32c38180e8568d439dac6c9900c69af8e70` |
| `control` | `df74b11e92902743c113417377fa2bcd6abd4083a9a878a0c8433714bcd0f006` |
| `README.md` | `99b05356b857892f190fea7eb89f57928f2b6c4c6187b2888520e0a379005fea` |
| `PROTOCOL.md` | `4973dee0fbb04d73e5c7d83ac108475407505edf185badf5a248be798ca01e26` |
| paired TrollVNC `Makefile` | `b4ae58b08305a174429583f8e86549e8115fa1aeb778604ca4f8eac1b8a6cd29` |
| paired TrollVNC `layout/DEBIAN/control` | `3f3143838b74fc312f08de7707d4873e6d82d76bed13936dca9d29e8bc88cbb7` |

## Packaged payload SHA-256

| Payload | SHA-256 |
|---|---|
| bridge `IPhoneUSBMic.dylib` | `1c6009dc7e92f65baab49e45129d761c6859fb0f15b99b42d01f2aeb29d8296e` |
| bridge `IPhoneUSBMicD` | `3b69600e0672d4ba3a387de07db816b09fb453bad8934c87830e18f343f775bb` |
| paired TrollVNC `trollvncserver` | `34f7bd821d9014d8426618314999a00ba158c1cc32a7b6a7c726f59acd3636c1` |

## Deployment and verification boundary

No package install, upload, daemon restart, respring, UI action, alert, or other
deployment action was performed. The requested clean compilation, package
metadata/archive inspection, architecture inspection, and hash comparison were
performed; no live-device or application runtime test was requested or run.
Build success does not establish live-device behavior. Independent read-only
regression invalidated this pair; it must not be installed or deployed.
