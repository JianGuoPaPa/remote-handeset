# Phone microphone bridge 1.6.0 build record

Build date: 2026-08-31

This record covers source closure and clean local packaging only. Neither
package was installed on a phone, copied to a remote host, nor exercised against
a live recording application.

## Final artifacts

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `packages/local.iphone.usbmic_1.6.0_iphoneos-arm64.deb` | 31,444 | `bc93d018d0ee79d9d83a2ddcb558ea9a7d9a3c66a84046140ffe3fc670a83e58` |
| `trollvnc-perf-fix/packages/com.82flex.trollvnc_3.2-280-perf2-mic8-demand6_iphoneos-arm64.deb` | 1,514,892 | `0e6d418dc740a3e5bf4fabcf74ee07b5b17be588b7a57e9242c7595fa859e6b8` |

The bridge control metadata reports version `1.6.0`, the authenticated direct
remote-control Description, and this exact dependency:

```text
com.82flex.trollvnc (>= 3.2-280-perf2-mic8-demand6)
```

The paired TrollVNC package reports version
`3.2-280-perf2-mic8-demand6`. The `1.5.0` / `3.2-279` pair and all earlier
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

## Cleanup ordering closure

- Before any original nil-delegate cleanup call, the code takes the output
  monitor, retires the requested and currently published bindings, and clears
  `currentBinding`. The monitor is released before calling AVFoundation.
- Consequently, a cleanup call that blocks, re-enters the setter, or drains a
  callback synchronously cannot expose an active published binding. The
  callback's exact delegate/output lookup can resolve only a retired binding and
  therefore leaves the already-cleared sample silent.
- If pre-cleanup fail-closed publication itself throws, the original cleanup
  call is not entered. This avoids executing a possibly synchronous cleanup
  without first proving the binding is unpublished.
- Whether the cleanup returns or throws, a second output-monitor pass again
  retires requested/current bindings and clears publication. No exception path
  reconciles by adopting the delegate still reported by AVFoundation.
- Cleanup exceptions never replace the first operation exception. The first
  operation exception object is rethrown after the final fail-closed attempt.
- The same pre-cleanup and post-cleanup ordering applies to hook failure,
  binding/sentinel failure, reconciliation failure, explicit delegate removal,
  and exception recovery.
- No original AVFoundation setter is invoked while the output monitor is held;
  the application's callback queue remains unwrapped and unmodified.

## Deployment boundary

No package in this record has been installed or deployed. A later authorized
deployment must install the paired TrollVNC package before the bridge package
and separately validate synchronous callback draining, re-entrant delegate
removal, delegate replacement/destruction, session failure recovery, reconnect
recovery, and live AudioUnit/Audio Queue/AVCapture recording.
