# Phone microphone bridge 2.1.0 build record

Build date: 2026-08-31 (Asia/Shanghai)

> **Audit-invalidated historical record. Do not install or deploy this pair.**
> Independent frozen regression found three P1 connection-state races: hook-entry
> generation could discard the Apple side effect that completed last; an
> operation from an obsolete session could advance the migrated owner's global
> connection generation; and output mutation did not advance the configuration
> revision, allowing a stale single-output scan failure to force unrelated
> outputs inactive. This pair is superseded by bridge 2.4.0 / TrollVNC
> 3.2-288-perf2-mic16-demand14; bridge 2.2.0 / TrollVNC 3.2-286 and bridge
> 2.3.0 / TrollVNC 3.2-287 were also audit-invalidated.

This record preserves the former clean local packaging evidence of the
paired bridge and TrollVNC packages. It supersedes the audit-invalidated 2.0.0 /
3.2-284-perf2-mic12-demand10 pair. Neither package was installed, uploaded,
deployed, or exercised against a live recording application.

## Frozen artifacts

| Artifact | Package metadata | Bytes | SHA-256 |
|---|---|---:|---|
| `/Users/zhaogongzi/Documents/手机远控/IPhoneUSBConsoleBridge/PhoneMicBridge/packages/local.iphone.usbmic_2.1.0_iphoneos-arm64.deb` | `local.iphone.usbmic` 2.1.0, iphoneos-arm64, Installed-Size 432 KiB | 66,176 | `b10c2019c247cb59d7176d10eb36c0c2ed6c8e7d23329d02930a9f01fd8593ff` |
| `/Users/zhaogongzi/Downloads/iPhone-USB-Console-Source-2026-08-30/trollvnc-perf-fix/packages/com.82flex.trollvnc_3.2-285-perf2-mic13-demand11_iphoneos-arm64.deb` | `com.82flex.trollvnc` 3.2-285-perf2-mic13-demand11, iphoneos-arm64, Installed-Size 5,724 KiB | 1,516,322 | `d9b2243ba9ab13f05aaeb2c6e85ef22188913e86075c2b41b704c81e328e976d` |

The packaged bridge control member contains this exact dependency:

```text
firmware (>= 15.0), mobilesubstrate,
com.82flex.trollvnc (>= 3.2-285-perf2-mic13-demand11)
```

The packaged TrollVNC control member requires `firmware (>= 15.0)`, matching
its iOS 15 minimum deployment target. No TrollVNC functional source was changed
for this pair; its `Makefile` package version alone was synchronized to the new
pair identifier.

The final staged payloads corresponding to the packaged archives were inspected.
`IPhoneUSBMic.dylib` contains `arm64` and `arm64e`; `IPhoneUSBMicD` and
`trollvncserver` are `arm64`.

## Clean package builds

Bridge, from `/Users/zhaogongzi/Documents/手机远控/IPhoneUSBConsoleBridge/PhoneMicBridge`:

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

## 2.1.0 connection-state closure

- `AVCaptureSession beginConfiguration` establishes a nested, revisioned demand
  barrier. Only a successful outermost `commitConfiguration` clears it after an
  authoritative scan of current outputs and every audio output's connections.
  A commit exception preserves AVFoundation's original exception and converges
  the actually visible topology fail-closed.
- `addInput:`, `removeInput:`, and `addInputWithNoConnections:` mark an open
  transaction dirty for the outer commit. Outside a transaction, their
  successful return triggers the same authoritative scan immediately, covering
  automatic connection creation and activity changes without requiring a
  session stop/start edge.
- Each connection operation reserves its completion generation at hook entry,
  before ownership resolution. Association installation and operation capture
  are atomic under the connection monitor. The immutable token contains object
  identity, a globally fresh association epoch, exact session identity, output
  identity, and the output-owner epoch.
- `AVCaptureConnection setEnabled:` pre-silences only its captured exact token.
  A completion may update the observer only while both its operation generation
  and full token remain current. The revision-gated output commit reads actual
  `isEnabled`/`isActive` state at that controlled point; it never uses a cached
  lock-external state to mint a newer revision.
- Explicit add/remove success, exception, removal clear, configuration rescan,
  and association deallocation all validate an exact token and output-owner
  epoch. A later session handoff or ABA replacement makes the old operation's
  success, exception, and cleanup paths no-ops against the new owner.
- No custom connection or configuration monitor is held across AVFoundation.
  Direct bindings and synchronizer markers share the same observer-revision
  commit: enabled/active additions can re-arm them, while disabled/removed last
  connections retire demand immediately.

All earlier AudioUnit generation, Audio Queue lease, synchronized AVCapture,
session/output ownership, critical delegate-hook, authenticated I/O, daemon
work-budget, demand revision, and bounded TrollVNC Stop/slow-client closures
remain present. Their wire and concurrency invariants are consolidated in
`PROTOCOL.md`.

## Critical source SHA-256

| Source | SHA-256 |
|---|---|
| `tweak/Tweak.xm` | `98c9cf4b3bdf4fb282d603f4eb2f341d25ede29cd56625e5997c985d5639127a` |
| `tweak/MicStreamClient.c` | `ade354bbd9ae572e2cca03bba3d456300c8c7ec576193aefdc1ccd68a04545a2` |
| `daemon/main.c` | `3199556d4a99bfd971ecf774c7d5f35d187da6de271a5bdb7ae8f045d4af7169` |
| `include/IUSCMicProtocol.h` | `deb279c120b3e0b4b29b67d273bc64e059ece21f2aafd81b4fb4fa15ddb9bc86` |
| `TrollVNC/IUSCMicRFBIngress.mm` | `bf89d828bb2dcbcd25cd410e7cf8f32c38180e8568d439dac6c9900c69af8e70` |
| `control` | `d86d5762df4621f95f4a09583e35d4b7f64f2a33eba257b7e0858750c485fbb2` |
| paired TrollVNC `Makefile` | `8cce9824044950dde5618624062cd579fb4905882ae12ac6f625c4786403a38b` |
| paired TrollVNC `layout/DEBIAN/control` | `3f3143838b74fc312f08de7707d4873e6d82d76bed13936dca9d29e8bc88cbb7` |

## Deployment boundary

No package install, upload, daemon restart, respring, UI action, alert, or other
deployment action was performed. Build and package inspection do not establish
live-device behavior. A separately authorized deployment must install TrollVNC
3.2-285 before bridge 2.1.0 and then validate AudioUnit, Audio Queue, direct and
synchronized AVCapture, nested/exceptional session configuration, automatic and
explicit connection creation, concurrent enable/disable, connection/session
migration and ABA reuse, reconnect, and Stop/restart behavior on the target
phone.
