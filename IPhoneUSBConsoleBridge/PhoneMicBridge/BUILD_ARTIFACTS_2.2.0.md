# Phone microphone bridge 2.2.0 build record

Build date: 2026-08-31 (Asia/Shanghai)

> **Audit-invalidated candidate -- do not install or deploy.** The frozen 2.2.0 /
> 3.2-286 pair has two confirmed synchronizer state-machine P1s. First, the
> synchronizer sentinel was associated only after per-output marker creation;
> marker conflict checking, active-state sampling, and owner publication were
> not one output-monitor transaction, so a lifecycle edge could be lost in the
> publication gap and two concurrent synchronizers could overwrite ownership.
> Second, `setDelegate:queue:` published the requested delegate and fresh binding
> before AVFoundation completed, with no in-flight/completion transaction; nil or
> reverse-order D1/D2 completions could leave Apple's actual delegate different
> from the sentinel binding. This historical artifact record is retained only for
> provenance and is superseded by the separately recorded 2.4.0 /
> 3.2-288-perf2-mic16-demand14 pair; the intermediate 2.3.0 / 3.2-287 pair
> was also audit-invalidated.

This record covers production source closure and clean local packaging of the
paired bridge and TrollVNC packages. It supersedes the audit-invalidated 2.1.0 /
3.2-285-perf2-mic13-demand11 pair. Neither package was installed, uploaded,
deployed, or exercised against a live recording application.

## Frozen artifacts

| Artifact | Package metadata | Bytes | SHA-256 |
|---|---|---:|---|
| `/Users/zhaogongzi/Documents/手机远控/IPhoneUSBConsoleBridge/PhoneMicBridge/packages/local.iphone.usbmic_2.2.0_iphoneos-arm64.deb` | `local.iphone.usbmic` 2.2.0, iphoneos-arm64, Installed-Size 432 KiB | 68,536 | `1f2d13b9f868102d1a26b51bfb078cb217ae3c0eb5f8ace10380866fcae59903` |
| `/Users/zhaogongzi/Downloads/iPhone-USB-Console-Source-2026-08-30/trollvnc-perf-fix/packages/com.82flex.trollvnc_3.2-286-perf2-mic14-demand12_iphoneos-arm64.deb` | `com.82flex.trollvnc` 3.2-286-perf2-mic14-demand12, iphoneos-arm64, Installed-Size 5,724 KiB | 1,517,520 | `a884cd294564b15b07838a7a2b1a7556e338c16ca5b7ec73c43a1b413b61ad25` |

The packaged bridge control member contains this exact dependency:

```text
firmware (>= 15.0), mobilesubstrate,
com.82flex.trollvnc (>= 3.2-286-perf2-mic14-demand12)
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

## 2.2.0 connection/topology closure

- A `setEnabled:` entry atomically captures only the currently associated exact
  token, increments that token's in-flight count, and pre-silences its exact
  output. It does not reserve completion ordering at hook entry.
- Each normal or exceptional AVFoundation return allocates a completion revision
  inside the still-current association token's own revision domain. Submission
  revalidates that token and revision and reads current `isEnabled`/`isActive`;
  no cached lock-external state can create a later observer update.
- The in-flight count keeps direct and synchronized bindings silent while any
  captured operation is outstanding. When the final operation completes, its
  commit re-reads the final Apple-visible state. Delayed post-call work therefore
  cannot discard the Apple side effect that completed last.
- Association handoff creates a fresh token and completion-revision domain. An
  operation from a wrong or obsolete session that captured no exact token cannot
  advance, clear, or complete the migrated owner's domain. Old-token completion
  is a no-op against the new token and may only request a fresh authoritative
  convergence from the current exact owner.
- `addOutput:`, `addOutputWithNoConnections:`, and `removeOutput:` now advance
  the same session topology revision before and after AVFoundation, alongside
  input, explicit connection, and configuration mutations. Any in-flight rescan
  holding the prior revision aborts and retries from a fresh snapshot, or defers
  to the successful outer commit/current mutation completion.
- A stable inability to confirm one audio output's connection topology retires
  only that exact output. Other confirmed outputs converge normally, and a
  later authoritative rescan can recover the output. One unconfirmed or
  in-flight connection keeps its entire exact output silent, preventing another
  active connection from undoing that fail-closed state.
- All removal, rescan, exception, deallocation, and migration cleanup remains
  gated by the immutable association token and exact output-owner epoch. No
  custom connection or configuration monitor is held across AVFoundation.

All earlier AudioUnit generation, Audio Queue lease, synchronized AVCapture,
session/output ownership, critical delegate-hook, authenticated I/O, daemon
work-budget, demand revision, and bounded TrollVNC Stop/slow-client closures
remain present. Their wire and concurrency invariants are consolidated in
`PROTOCOL.md`.

## Critical source SHA-256

| Source | SHA-256 |
|---|---|
| `tweak/Tweak.xm` | `5863e54cc785cc845e2a511ef36738366c22a0c1f207fabff5e00fc765b37d44` |
| `tweak/MicStreamClient.c` | `ade354bbd9ae572e2cca03bba3d456300c8c7ec576193aefdc1ccd68a04545a2` |
| `daemon/main.c` | `3199556d4a99bfd971ecf774c7d5f35d187da6de271a5bdb7ae8f045d4af7169` |
| `include/IUSCMicProtocol.h` | `deb279c120b3e0b4b29b67d273bc64e059ece21f2aafd81b4fb4fa15ddb9bc86` |
| `TrollVNC/IUSCMicRFBIngress.mm` | `bf89d828bb2dcbcd25cd410e7cf8f32c38180e8568d439dac6c9900c69af8e70` |
| `control` | `7f7c1d1479cd0efdeacc34bbccd65f97559de4a71e80f9ff79a7422a847983d8` |
| `README.md` | `88f6289a3788ad09ebc91753f2051957239c1dc1bdd48ac34d12b358320ac95b` |
| `PROTOCOL.md` | `f83009fcc49d5f1e3f38f04606af703c22c7cd4b3285ad3ffcf925138094456a` |
| paired TrollVNC `Makefile` | `914b143bf0c6105051b6ff295cabd48ac399fbfa9b4bfa2e9d180e1b1468f01e` |
| paired TrollVNC `layout/DEBIAN/control` | `3f3143838b74fc312f08de7707d4873e6d82d76bed13936dca9d29e8bc88cbb7` |

## Packaged payload SHA-256

| Payload | SHA-256 |
|---|---|
| bridge `IPhoneUSBMic.dylib` | `746f8704078875a515b3de21a00390f25620bd224ccd05c617df5c215fb8aa48` |
| bridge `IPhoneUSBMicD` | `d6fa31e8a62a18639f1964a584423e51ae718d6719dcac430cf6332eb139a623` |
| paired TrollVNC `trollvncserver` | `0fa09e4b920b4b22a229678334d3a8254a96b373b691fdad084338de893164f4` |

## Deployment and verification boundary

No package install, upload, daemon restart, respring, UI action, alert, or other
deployment action was performed. The requested clean compilation, package
metadata/archive inspection, architecture inspection, and hash comparison were
performed; no live-device or application runtime test was requested or run.
Build success does not establish live-device behavior. This frozen pair remains
pending independent read-only regression before any separately authorized
deployment.
