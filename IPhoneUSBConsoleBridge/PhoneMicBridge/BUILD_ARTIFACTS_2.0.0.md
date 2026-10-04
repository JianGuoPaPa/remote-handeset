# Phone microphone bridge 2.0.0 build record

Build date: 2026-08-31 (Asia/Shanghai)

> **Audit-invalidated:** this pair misses outermost configuration/input
> convergence, permits an older `setEnabled:` completion to mint a newer
> observer revision from cached state, and does not atomically bind association
> handoff to the originating connection operation. It must not be installed or
> deployed. This historical record is superseded by bridge 2.4.0 / TrollVNC
> 3.2-288-perf2-mic16-demand14; the intermediate 2.1.0 / 3.2-285, 2.2.0 /
> 3.2-286, and 2.3.0 / 3.2-287 pairs were also audit-invalidated.

This record covers production source closure and clean local packaging of the
paired bridge and TrollVNC packages. It supersedes the audit-invalidated 1.9.0 /
3.2-283-perf2-mic11-demand9 pair. Neither package was installed, uploaded,
deployed, or exercised against a live recording application.

## Frozen artifacts

| Artifact | Package metadata | Bytes | SHA-256 |
|---|---|---:|---|
| `/Users/zhaogongzi/Documents/手机远控/IPhoneUSBConsoleBridge/PhoneMicBridge/packages/local.iphone.usbmic_2.0.0_iphoneos-arm64.deb` | `local.iphone.usbmic` 2.0.0, iphoneos-arm64, Installed-Size 380 KiB | 56,898 | `ad52e3aaced815388b871ba016598be8337bb3361c2857c4723780e80769ada2` |
| `/Users/zhaogongzi/Downloads/iPhone-USB-Console-Source-2026-08-30/trollvnc-perf-fix/packages/com.82flex.trollvnc_3.2-284-perf2-mic12-demand10_iphoneos-arm64.deb` | `com.82flex.trollvnc` 3.2-284-perf2-mic12-demand10, iphoneos-arm64, Installed-Size 5,724 KiB | 1,515,840 | `359e259cf7a3bee6ed9c2b164b970ea2522a5bebdd849380b1d691787d0221a8` |

The packaged bridge control member contains this exact dependency:

```text
firmware (>= 15.0), mobilesubstrate,
com.82flex.trollvnc (>= 3.2-284-perf2-mic12-demand10)
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

Both clean package builds completed without compiler errors. The TrollVNC
preference bundle emitted only its existing iOS 15 `SecKeyGeneratePair`
deprecation warning for arm64 and arm64e. The toolchain was Xcode 26.6 (17F113)
with Theos commit `5280bd038207e14f8bd76f5417aa2fe641c03228`.

## 2.0.0 connection-lifecycle closure

- `AVCaptureSession addConnection:` and `removeConnection:` now resolve audio
  connections before and after AVFoundation, invalidate the exact owner's prior
  observer revision before mutation, and converge from current output/connection
  membership after mutation. Cleanup never replaces AVFoundation's original
  exception and remains fail-closed.
- `AVCaptureConnection setEnabled:` first silences the exact associated owner
  and advances its revision. After the original setter, it uses actual
  `isEnabled`/`isActive` state together with the output's complete connection
  state, current session membership, and exact ownership epoch. Direct and
  synchronizer lifecycle markers are updated by the same revision-checked path.
- Weak connection associations are established for automatic connections after
  both output-add APIs, for synchronizer outputs during sentinel initialization,
  and by a post-`addConnection:` scan of current session outputs. A missing
  association can also be recovered from `connection.output` only while the
  connection remains in that output's current connection collection.
- Association replacement recomputes the previous exact owner. Removal clears
  only the exact association object and invalidated output epoch observed by the
  operation; a re-entrant migration or same-object reclaim cannot be erased by a
  stale hook. Association deallocation similarly converges only through the
  still-current observer/session/output epoch.
- Disabling/removing the last live audio connection immediately releases demand
  and retires both direct and synchronizer bindings. Enabling/adding a live
  connection can re-arm them. Later activity changes caused by session
  configuration continue to converge through the session lifecycle observer.
- The previous session ownership invariants remain intact: notifications never
  claim outputs, every item validates revision/membership/exact epoch, output
  addition claims only after successful AVFoundation return, and output removal
  invalidates and untracks its exact epoch before AVFoundation.

All earlier AudioUnit generation, Audio Queue lease, synchronized AVCapture,
critical delegate-hook, authenticated I/O, daemon work-budget, demand revision,
and bounded TrollVNC Stop/slow-client closures remain present. Their wire and
concurrency invariants are consolidated in `PROTOCOL.md`.

## Critical source SHA-256

| Source | SHA-256 |
|---|---|
| `tweak/Tweak.xm` | `1aa1c9e64402f2c38c081428815b7890ca1a645883b9bded41f62463d24b920c` |
| `tweak/MicStreamClient.c` | `ade354bbd9ae572e2cca03bba3d456300c8c7ec576193aefdc1ccd68a04545a2` |
| `daemon/main.c` | `3199556d4a99bfd971ecf774c7d5f35d187da6de271a5bdb7ae8f045d4af7169` |
| `include/IUSCMicProtocol.h` | `deb279c120b3e0b4b29b67d273bc64e059ece21f2aafd81b4fb4fa15ddb9bc86` |
| `TrollVNC/IUSCMicRFBIngress.mm` | `bf89d828bb2dcbcd25cd410e7cf8f32c38180e8568d439dac6c9900c69af8e70` |
| `control` | `364d8fc40fcedb6204e1a32979e37f5cdcd25cfe0b452faf0242e7bcdea26fb6` |
| paired TrollVNC `Makefile` | `792c9880fab96afed92e3bd6c5b7d2b1f640ad203ebd01e2291c4fc29e798fbc` |
| paired TrollVNC `layout/DEBIAN/control` | `3f3143838b74fc312f08de7707d4873e6d82d76bed13936dca9d29e8bc88cbb7` |

## Deployment boundary

No package install, upload, daemon restart, respring, UI action, alert, or other
deployment action was performed. Build and package inspection do not establish
live-device behavior. A separately authorized deployment must use the
superseding pair; the frozen 3.2-284 / bridge 2.0.0 artifacts in this record must
not be installed. Validation for a later authorized deployment must cover
AudioUnit, Audio Queue, direct and
synchronized AVCapture, both output-add APIs, automatic and explicit connection
creation, connection enable/disable/removal, session migration, exception
recovery, reconnect, and Stop/restart behavior on the target phone.
