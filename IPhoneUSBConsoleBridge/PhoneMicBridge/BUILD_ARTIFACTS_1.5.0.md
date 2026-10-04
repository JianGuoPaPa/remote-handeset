# Phone microphone bridge 1.5.0 build record

Build date: 2026-08-31

This record covers source closure and clean local packaging only. Neither
package was installed on a phone, copied to a remote host, nor exercised against
a live recording application.

## Final artifacts

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `packages/local.iphone.usbmic_1.5.0_iphoneos-arm64.deb` | 31,126 | `133d8ce1621e9f8038921e204c49396226623694f2088202f6d5861594d34ff8` |
| `trollvnc-perf-fix/packages/com.82flex.trollvnc_3.2-279-perf2-mic7-demand5_iphoneos-arm64.deb` | 1,514,872 | `bf70f61c849e71cb7538df1bc18c9c839c22db520d9e5c566bad696b843e3485` |

The bridge control metadata reports version `1.5.0`, the authenticated direct
remote-control Description, and this exact dependency:

```text
com.82flex.trollvnc (>= 3.2-279-perf2-mic7-demand5)
```

The paired TrollVNC package reports version
`3.2-279-perf2-mic7-demand5`. The `1.4.0` / `3.2-278` pair and all earlier
intermediate pairs are superseded and must not be installed.

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

Both clean package builds completed successfully. After the final source edit,
the bridge was cleaned and rebuilt again before its hash was recorded. The
bridge tweak is a fat Mach-O containing `arm64` and `arm64e`; its daemon and the
TrollVNC server are `arm64`. TrollVNC emitted the existing
`SecKeyGeneratePair` deprecation warning from its preference bundle; neither
build emitted a compilation error.

## Final exception and lifecycle closure

- `setCaptureOutputLifecycle` reads the published binding, reads the current
  delegate, verifies identity, and applies the lifecycle edge inside the same
  output monitor used by reconciliation. The original AVFoundation setter is
  never called under that monitor.
- Every original delegate-setter call is covered by one exception boundary.
  The requested binding is retired before cleanup. A partially installed
  delegate is removed with a nil-delegate original call when possible; a
  cleanup exception is ignored only so that it cannot replace the original
  application exception.
- Exception cleanup never reconciles by adopting the still-reported delegate.
  It retires both requested and published bindings and clears
  `currentBinding` under the output monitor. A queued callback can still find
  only its retired per-delegate binding and therefore receives silence; later
  session notifications have no published binding to re-arm.
- A missing output lifetime sentinel is a hard fail-closed condition. The
  requested and observed delegate bindings are retired, and the requested
  delegate is not left installed.
- Session start pre-arm and stop pre-silence are within the operation exception
  boundary. A `finally` path always converges from authoritative
  `isRunning`/`isInterrupted` state. If both AVFoundation and convergence throw,
  the first operation exception is rethrown unchanged after a fail-closed
  convergence attempt.
- Callback queues remain untouched: no proxy queue, queue wrapper,
  queue-specific value, or queue-target mutation is used.
- Package removal stops the daemon and deletes both `ingress.sock` and
  `demand.sock`.

## Deployment boundary

No package in this record has been installed or deployed. A later authorized
deployment must install the paired TrollVNC package before the bridge package
and separately validate delegate-setter exception behavior, delegate
replacement/destruction, session start/stop failure recovery, queue Dispose
tails, reconnect recovery, and live AudioUnit/Audio Queue/AVCapture recording.
