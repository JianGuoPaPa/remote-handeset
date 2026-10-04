# Phone microphone bridge 1.9.0 build record

Build date: 2026-08-31 (Asia/Shanghai)

> **Audit-invalidated:** this pair does not observe
> `AVCaptureConnection` add/remove/enabled lifecycle changes and must not be
> installed or deployed. It is retained only as a historical build record and
> is superseded by bridge 2.0.0 / TrollVNC
> 3.2-284-perf2-mic12-demand10.

This record covers production source closure and clean local packaging of the
paired bridge and TrollVNC packages. It supersedes the audit-invalidated 1.8.0 /
3.2-282 pair. Neither new package was installed, uploaded, deployed, or
exercised against a live recording application.

## Frozen artifacts

| Artifact | Package metadata | Bytes | SHA-256 |
|---|---|---:|---|
| `packages/local.iphone.usbmic_1.9.0_iphoneos-arm64.deb` | `local.iphone.usbmic` 1.9.0, iphoneos-arm64, Installed-Size 348 KiB | 47,458 | `8473b2d1edf2b36196720d801b0893e7db709795595baa4a9cdef2493692c50d` |
| `/Users/zhaogongzi/Downloads/iPhone-USB-Console-Source-2026-08-30/trollvnc-perf-fix/packages/com.82flex.trollvnc_3.2-283-perf2-mic11-demand9_iphoneos-arm64.deb` | `com.82flex.trollvnc` 3.2-283-perf2-mic11-demand9, iphoneos-arm64, Installed-Size 5,724 KiB | 1,515,568 | `e5ab34750d5059fcfa6affef2b2a4700db406920055af97c842485ab58b02bab` |

The packaged bridge control member contains this exact dependency:

```text
firmware (>= 15.0), mobilesubstrate,
com.82flex.trollvnc (>= 3.2-283-perf2-mic11-demand9)
```

The packaged TrollVNC control member requires `firmware (>= 15.0)`, matching
its iOS 15 minimum deployment target. No TrollVNC functional source was changed
for this pair; its `Makefile` package version alone was synchronized to the new
pair identifier.

The final staged payloads corresponding to the packaged archives were inspected.
`IPhoneUSBMic.dylib` contains `arm64` and `arm64e`; `IPhoneUSBMicD` and
`trollvncserver` are `arm64`.

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

Both clean package builds completed without compiler errors. The TrollVNC
preference bundle emitted only its existing iOS 15 `SecKeyGeneratePair`
deprecation warning for arm64 and arm64e. The toolchain was Xcode 26.6 (17F113)
with Theos commit `5280bd038207e14f8bd76f5417aa2fe641c03228`.

## 1.9.0 ownership-state closure

- Stop, runtime-error, interruption, start, and recovery notifications now run
  only through their originating current session observer. Each event reserves
  an observer revision, snapshots `session.outputs`, and never claims an output.
- Before each snapshot item publishes a lifecycle edge, it rechecks the exact
  revision, current session membership, associated observer/session identities,
  and the tracked ownership epoch. A stale event cannot update a later claim.
- `addOutput:` and `addOutputWithNoConnections:` call AVFoundation first. Only a
  successful original return may enter authoritative claim; the claim checks
  membership again, creates a fresh epoch, returns revision/current activity,
  and commits through the revision-aware setter. Each bounded retry repeats the
  membership check, so a re-entrant migration cannot be reclaimed by the old
  session.
- `removeOutput:` invalidates the prior revision and removes only the exact
  observer/session/epoch before AVFoundation. After a successful return it uses
  current membership to either claim a fresh epoch or conditionally converge the
  remaining outputs. If AVFoundation throws, the original exception is retained
  while exact cleanup remains fail-closed; cleanup failures never replace it.
- Observer retirement and deallocation clear and silence an output only when the
  snapshotted epoch still matches the associated observer and raw session
  identity. A later owner is unaffected even after ARC clears old weak pointers.
- The interrupted legacy `trackOutput:`, `untrackOutput:`, and old setter calls
  were removed. The Objective-C++ tweak compiles for both arm64 and arm64e.

All earlier AudioUnit generation, Audio Queue lease, synchronized AVCapture,
critical delegate-hook, authenticated I/O, daemon work-budget, demand revision,
and bounded TrollVNC Stop/slow-client closures remain present. Their wire and
concurrency invariants are consolidated in `PROTOCOL.md`.

## Critical source SHA-256

| Source | SHA-256 |
|---|---|
| `tweak/Tweak.xm` | `2b1047bb01d3fa5fe3a196c82b43f571b8eda49003f2249abffef1ba7987c849` |
| `tweak/MicStreamClient.c` | `ade354bbd9ae572e2cca03bba3d456300c8c7ec576193aefdc1ccd68a04545a2` |
| `daemon/main.c` | `3199556d4a99bfd971ecf774c7d5f35d187da6de271a5bdb7ae8f045d4af7169` |
| `include/IUSCMicProtocol.h` | `deb279c120b3e0b4b29b67d273bc64e059ece21f2aafd81b4fb4fa15ddb9bc86` |
| `TrollVNC/IUSCMicRFBIngress.mm` | `bf89d828bb2dcbcd25cd410e7cf8f32c38180e8568d439dac6c9900c69af8e70` |
| `control` | `0b871851f31731741f3186eedac118a121e126d01dd1ad943d1c6965b7a35624` |
| paired TrollVNC `Makefile` | `6889e1cb6aab4577fe4e149128ef09631d4373214556d2d377f24ca5f5aa33a3` |
| paired TrollVNC `layout/DEBIAN/control` | `3f3143838b74fc312f08de7707d4873e6d82d76bed13936dca9d29e8bc88cbb7` |

## Deployment boundary

No package install, upload, daemon restart, respring, or other deployment action
was performed. Build and package inspection do not establish live-device
behavior. A separately authorized deployment must install TrollVNC 3.2-283
before bridge 1.9.0 and then validate AudioUnit, Audio Queue, direct and
synchronized AVCapture, both output-add APIs, session migration, remove
exception recovery, reconnect, and Stop/restart behavior on the target phone.
