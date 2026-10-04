# Phone microphone bridge 1.4.0 build record

Build date: 2026-08-31

This record covers source closure and clean local packaging only. Neither
package was installed on a phone, copied to a remote host, nor exercised against
a live recording application.

## Final artifacts

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `packages/local.iphone.usbmic_1.4.0_iphoneos-arm64.deb` | 30,178 | `9817f74e4dea40d5d8a56522ec1a690c6f64b4f092b295f6b50665d71097be9f` |
| `trollvnc-perf-fix/packages/com.82flex.trollvnc_3.2-278-perf2-mic6-demand4_iphoneos-arm64.deb` | 1,514,572 | `9322b1376deecfc894b1d555f0a3e25b537006f007c6df6ca8d435c5e4a353a9` |

The bridge control metadata reports version `1.4.0`, the authenticated direct
remote-control Description, and this exact dependency:

```text
com.82flex.trollvnc (>= 3.2-278-perf2-mic6-demand4)
```

The paired TrollVNC package reports version
`3.2-278-perf2-mic6-demand4`. The `1.3.0` / `3.2-277` pair and all earlier
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

Both clean package builds completed successfully. The bridge tweak is a fat
Mach-O containing `arm64` and `arm64e`; its daemon and the TrollVNC server are
`arm64`. TrollVNC emitted the existing `SecKeyGeneratePair` deprecation warning
from its preference bundle; neither build emitted a compilation error.

## Final safety closure

- Audio Queue admission and lease count share one atomic word. Reclamation
  verifies the slot generation under the writer lock, closes admission first,
  then waits asynchronously until the existing lease count is zero before
  clearing any non-atomic field or permitting reuse.
- Real-time Audio Queue callbacks use at most four compare/exchange attempts;
  gate contention or closure takes the already-cleared silent path without a
  lock, wait, allocation, or socket operation.
- Every Audio Queue acquisition path uses the same closed-gate lease operation.
- Each AVCapture delegate instance owns a weak-output/strong-binding map and a
  lifetime sentinel. Callback lookup requires the exact callback object and
  output; a replaced delegate therefore resolves only its own retired binding.
- An identical delegate/output pair deliberately reuses one stable binding,
  avoiding a second indistinguishable generation. Different delegates never
  share a binding.
- Delegate-class hook installation is serialized and published ready only after
  `MSHookMessageEx` returns a usable original implementation. A hook or binding
  failure installs no requested delegate, so an unhooked callback cannot receive
  physical microphone samples.
- The implementation does not wrap, replace, or annotate the application's
  callback queue. Queue identity, queue-specific values, ordering, and the
  observable `sampleBufferDelegate` remain AVFoundation-native.
- Original delegate installation occurs outside the output state lock. Binding
  state is armed before the call and reconciled afterward, avoiding a lock cycle
  if AVFoundation waits for an in-flight delegate callback.
- Session restart checks the current delegate identity against the output's
  current binding; a nil or replaced delegate cannot be rearmed.
- Package removal stops the daemon and deletes both `ingress.sock` and
  `demand.sock`.

## Deployment boundary

No package in this record has been installed or deployed. A later authorized
deployment must install the paired TrollVNC package before the bridge package
and separately validate delegate replacement, delegate destruction, queue
Dispose tails, reconnect recovery, and live AudioUnit/Audio Queue/AVCapture
recording behavior.
