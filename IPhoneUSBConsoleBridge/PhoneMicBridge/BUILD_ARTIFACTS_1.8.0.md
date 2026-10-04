# Phone microphone bridge 1.8.0 build record

Build date: 2026-08-31 (Asia/Shanghai)

This record covers production source closure and clean local packaging of the
paired bridge and TrollVNC packages. It supersedes the audit-invalidated 1.7.0 /
3.2-281 pair. Neither new package was installed, uploaded, deployed, or
exercised against a live recording application.

## Frozen artifacts

| Artifact | Package metadata | Bytes | SHA-256 |
|---|---|---:|---|
| `packages/local.iphone.usbmic_1.8.0_iphoneos-arm64.deb` | `local.iphone.usbmic` 1.8.0, iphoneos-arm64, Installed-Size 348 KiB | 43,848 | `274c1c213a90a84024a2649d97037c774738af0d997f0771677af32b276fd16e` |
| `/Users/zhaogongzi/Downloads/iPhone-USB-Console-Source-2026-08-30/trollvnc-perf-fix/packages/com.82flex.trollvnc_3.2-282-perf2-mic10-demand8_iphoneos-arm64.deb` | `com.82flex.trollvnc` 3.2-282-perf2-mic10-demand8, iphoneos-arm64, Installed-Size 5,724 KiB | 1,516,078 | `54cb794596212b1b9a02d2cf2aac55ede0712eed275fa09b805893fa81003cd7` |

The packaged bridge control member contains this exact dependency:

```text
firmware (>= 15.0), mobilesubstrate,
com.82flex.trollvnc (>= 3.2-282-perf2-mic10-demand8)
```

The packaged TrollVNC control member now also requires
`firmware (>= 15.0)`, matching its iOS 15 minimum deployment target.

The final DEB payloads were extracted and inspected. `IPhoneUSBMic.dylib`
contains `arm64` and `arm64e`; `IPhoneUSBMicD` and `trollvncserver` are `arm64`.

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

## 1.8.0 audit closure

- After installing all 15 C hooks, the constructor computes the complete
  original-trampoline gate. A false gate immediately calls `_exit(78)` before
  `%init`; process exclusion still occurs before any hook installation.
- `AVCaptureDataOutputSynchronizer` delegate setup starts `MicStreamClient`
  immediately after the critical gate check, before sentinel replacement,
  binding arming, or any demand acquire.
- Each tracked `AVCaptureAudioDataOutput` now has an associated session owner,
  raw owner/session identities, and a unique nonzero ownership epoch. The raw
  identity remains comparable after ARC clears weak references at deallocation
  entry, while the epoch prevents address reuse or a later claim from matching
  an older retirement snapshot.
- `removeOutput:` untracks before AVFoundation and repeats the untrack in its
  `finally` path. Lifecycle updates are performed under the output monitor only
  if the observer and epoch still own the output. A new session claim replaces
  the marker and removes the old observer's matching slot; later notification,
  exception cleanup, retirement, or deallocation from the old session cannot
  silence the new session's binding.
- TrollVNC package metadata requires firmware 15.0, consistent with the build's
  minimum OS. Bridge dependency/version metadata points only to the matching
  3.2-282 package.

All 1.7-era AudioUnit generation, Audio Queue lease, synchronized AVCapture,
critical delegate-hook, authenticated I/O, daemon work-budget, demand revision,
and bounded TrollVNC Stop/slow-client closures remain present. Their current
wire and concurrency invariants are consolidated in `PROTOCOL.md`.

## Critical source SHA-256

| Source | SHA-256 |
|---|---|
| `tweak/Tweak.xm` | `47a60a44ff8a91740659e29b0ae6c651ef2c439d096b31e5b3639527d0923cfe` |
| `tweak/MicStreamClient.c` | `ade354bbd9ae572e2cca03bba3d456300c8c7ec576193aefdc1ccd68a04545a2` |
| `daemon/main.c` | `3199556d4a99bfd971ecf774c7d5f35d187da6de271a5bdb7ae8f045d4af7169` |
| `include/IUSCMicProtocol.h` | `deb279c120b3e0b4b29b67d273bc64e059ece21f2aafd81b4fb4fa15ddb9bc86` |
| `TrollVNC/IUSCMicRFBIngress.mm` | `bf89d828bb2dcbcd25cd410e7cf8f32c38180e8568d439dac6c9900c69af8e70` |
| `control` | `f49b903e1f4de3b456f81048e85f4dc40ee44d9222b41624e2f150942cd094e2` |
| paired TrollVNC `Makefile` | `3f25239efd76a3ea3939b2104ec69da1249485fbeb9fe5bd8dc4de61d17b2b3f` |
| paired TrollVNC `layout/DEBIAN/control` | `3f3143838b74fc312f08de7707d4873e6d82d76bed13936dca9d29e8bc88cbb7` |

## Deployment boundary

No package install, upload, daemon restart, respring, or other deployment action
was performed. Build and package inspection do not establish live-device
behavior. A separately authorized deployment must install TrollVNC 3.2-282
before bridge 1.8.0 and then validate AudioUnit, Audio Queue, direct and
synchronized AVCapture, session migration, reconnect, and Stop/restart behavior
on the target phone.
