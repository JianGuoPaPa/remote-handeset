# Phone microphone bridge 1.2.0 build record

Record date: 2026-08-31 (Asia/Shanghai)

This record covers the locally built, uninstalled callback-lifecycle release.
It contains no authentication secret, device identifier, public address, or
account credential.

## Artifacts

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `packages/local.iphone.usbmic_1.2.0_iphoneos-arm64.deb` | 22,038 | `156e9f7344be6060d74431afc83bcdfc49462c4a2ac22ace25e6775ae9c227fd` |
| `trollvnc-perf-fix/packages/com.82flex.trollvnc_3.2-276-perf2-mic4-demand2_iphoneos-arm64.deb` | 1,515,426 | `3149de8c6ecfeb46e4bdf5662a897fb55fd69c6199b58c81fcae67457510b834` |

The bridge package declares the exact minimum paired dependency:

```text
com.82flex.trollvnc (>= 3.2-276-perf2-mic4-demand2)
```

The intermediate bridge 1.1.0 and TrollVNC
3.2-275-perf2-mic3-demand1 packages are superseded and are not deployment
candidates.

## Build evidence

- Theos commit: `5280bd038207e14f8bd76f5417aa2fe641c03228`
- Xcode iPhoneOS 26.5 SDK
- rootless deployment target: iOS 15.0
- bridge daemon: arm64
- bridge tweak: arm64 + arm64e
- TrollVNC server: arm64
- both packages completed clean local package builds
- package-control extraction confirmed package names, versions, architectures,
  and the paired dependency
- binary inspection confirmed the Audio Queue Pause/Reset/Prime/Flush and
  IsRunning-listener imports, original-CMBlockBuffer mutation imports, IUMH /
  IUMD markers, and the paired TrollVNC version marker

Build commands:

```sh
THEOS=/tmp/iphone-usb-mic-theos make clean package FINALPACKAGE=1

make clean package FINALPACKAGE=1 \
  THEOS=/tmp/iphone-usb-mic-theos \
  THEOS_PACKAGE_SCHEME=rootless \
  TARGET=iphone:clang:latest:15.0 \
  PHONE_MIC_BRIDGE_DIR=/Users/zhaogongzi/Documents/手机远控/IPhoneUSBConsoleBridge/PhoneMicBridge
```

## Lifecycle guarantees represented by this build

- AudioUnit Stop and Dispose enter fail-closed state before calling Apple, and
  retired instance tombstones keep any tail render silent.
- `AudioQueueStop(false)` retains demand until the authoritative
  `kAudioQueueProperty_IsRunning=0` edge. Pause and Reset release demand while
  retaining a silent retired state until a successful Start.
- Audio Queue callbacks take an atomic context lease. Successfully created
  queue contexts remain small process-lifetime tombstones after Dispose because
  Apple documents further callbacks when Stop, Reset, or Dispose is invoked
  from a callback; no callback can dereference a freed context.
- AVCapture clears the sample buffer's original `CMBlockBuffer` first. Remote
  PCM is written only into safely addressable contiguous interleaved original
  storage; unsupported layouts remain silent, and storage that cannot be
  cleared is dropped rather than forwarded.

## Deployment boundary

No package in this record was installed on the iPhone. No device process was
restarted, no respring was performed, and no live microphone or reconnect test
was run. The record proves source compilation and package structure only;
real-device behavior remains a separate explicitly approved deployment step.
