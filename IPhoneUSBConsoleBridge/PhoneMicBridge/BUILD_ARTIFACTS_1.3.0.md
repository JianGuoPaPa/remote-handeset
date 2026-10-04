# Phone microphone bridge 1.3.0 build record

Build date: 2026-08-31

This record covers the production source build only. Neither package was
installed on a phone, copied to a remote host, nor exercised against a live
recording application in this build pass.

## Final artifacts

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `packages/local.iphone.usbmic_1.3.0_iphoneos-arm64.deb` | 26,366 | `d183ef11f4872b5566eb00dcb188cf7374f2b4995f48167d7167b2d7f52f9d2a` |
| `trollvnc-perf-fix/packages/com.82flex.trollvnc_3.2-277-perf2-mic5-demand3_iphoneos-arm64.deb` | 1,514,848 | `c45e75ccaf78426e90e146fb44c1e07b16132a98bb94f326973b0ca1cad0b51c` |

The bridge package control metadata reports version `1.3.0`, the direct remote
control Description, and the exact dependency:

```text
com.82flex.trollvnc (>= 3.2-277-perf2-mic5-demand3)
```

The paired TrollVNC package reports version
`3.2-277-perf2-mic5-demand3`. The superseded `1.2.0` / `3.2-276` and
`1.1.0` / `3.2-275` artifacts are not valid deployment candidates.

## Clean build commands

Bridge:

```sh
make clean package FINALPACKAGE=1 \
  THEOS=/tmp/iphone-usb-mic-theos
```

TrollVNC:

```sh
make clean package FINALPACKAGE=1 \
  THEOS=/tmp/iphone-usb-mic-theos \
  THEOS_PACKAGE_SCHEME=rootless \
  TARGET=iphone:clang:latest:15.0 \
  PHONE_MIC_BRIDGE_DIR=/Users/zhaogongzi/Documents/手机远控/IPhoneUSBConsoleBridge/PhoneMicBridge
```

Both clean package builds completed successfully. The bridge tweak is a fat
Mach-O containing `arm64` and `arm64e`; its daemon and TrollVNC server are
`arm64`. TrollVNC emitted the existing `SecKeyGeneratePair` deprecation warning
from its preference bundle; neither build emitted a compilation error.

## Static safety closure

- Audio Queue classic and dispatch callbacks clear the real input buffer before
  reading context or demand state. Stale tokens therefore remain silent.
- Queue contexts use a bounded 256-slot generation pool. Dispose retires a slot;
  a background reaper recycles it only after callback leases reach zero.
- `AudioQueueReset` clears cursor state but preserves running/demand ownership
  unless `kAudioQueueProperty_IsRunning` reports a real stop.
- AudioUnit stop/dispose stays fail-closed for tail renders. Static slots can be
  safely recycled, and input creation/configuration fails closed on exhaustion.
- AVCapture clears the original sample's `CMBlockBuffer` before reading capture
  lifecycle state. Non-addressable samples are dropped instead of forwarded.
- AVCapture cursor ownership is nonblocking; contention stays silent. Exact
  session start/stop/runtime-error/interruption/recovery and output/delegate
  edges update demand without rearming an output that has no delegate.
- The previously defined IUMC microphone injection and IUMH/IUMD automatic
  demand protocols remain unchanged, including authenticated full-control RFB
  gating.

## Deployment boundary

No package in this record has been installed or deployed. A later authorized
deployment must install the paired TrollVNC package before the bridge package
and must separately validate live AudioUnit, Audio Queue, and AVCapture clients,
including start/stop tails and reconnect recovery.
