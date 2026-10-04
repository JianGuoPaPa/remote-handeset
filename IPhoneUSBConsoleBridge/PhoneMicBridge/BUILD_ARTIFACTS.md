# Phone microphone bridge final build and device record

Record date: 2026-08-27 (Asia/Shanghai)

This is the frozen record for the pair actually installed on the iPhone. It
separates file/build evidence, device package evidence, observed end-to-end
behavior, and work that has not been exercised. It intentionally contains no
VNC/web password, Apple credential, device identifier, public IP, or embedded
HMAC secret.

## Final artifacts

| Artifact | Package metadata | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| `packages/local.iphone.usbmic_1.0.2_iphoneos-arm64.deb` | `local.iphone.usbmic` 1.0.2, iphoneos-arm64, Installed-Size 228 KiB | 16,552 | `c76e8ea394af2eec9b548189033a5518c9cdf3b575ff7151643b0b3f98d28d73` |
| `../../trollvnc-perf-fix/packages/com.82flex.trollvnc_3.2-273-perf2-mic2_iphoneos-arm64.deb` | `com.82flex.trollvnc` 3.2-273-perf2-mic2, iphoneos-arm64, Installed-Size 5,724 KiB | 1,514,298 | `ba75b00407c383061d91cf98a97f3eccb8ef51d09132a5169293ac3ed71b7621` |
| `layout/DEBIAN/postinst` | safe bridge maintainer script | 837 | `6af743ade186c5fff8d7d9d182bbfcf1479242dca279c34ed33f011add94808f` |
| `layout/DEBIAN/prerm` | bridge removal maintainer script | — | `7f31d17e9e9b2a82beb74d750d2e9f99efbacc4cd218de5b5551c07e1db413eb` |
| `../../trollvnc-perf-fix/layout/DEBIAN/postinst` | TrollVNC daemon restart script | — | `2296c223c2cb4722aec9c870e083e52d27cbe8e3fc699dd5ea23845df6a61b73` |

The bridge dependency is exactly:

```text
firmware (>= 15.0), mobilesubstrate,
com.82flex.trollvnc (>= 3.2-273-perf2-mic2)
```

Do not deploy `perf2-mic1` or bridge 1.0.0/1.0.1 as the final pair. Historical
packages remain only for diagnosis and must not be selected by filename habit.

The dated recovery copy is
`releases/2026-08-27-final/` relative to the `iphone-usb-console` project root. Its
`SHA256SUMS` fixes the Mac app and both DEBs even if a later build overwrites the
normal `build/Release` or `packages` path. `SOURCE_SHA256SUMS` fixes the critical
audio sources. The archive's read-only `verify-release.zsh` was run successfully
against both lists, app signing/version/size, DEB metadata/dependency/architectures,
the packaged postinst, and TrollVNC protocol markers.

## Toolchain and binary shape

- Xcode 26.5 (17F42), iPhoneOS 26.5 SDK
- Theos commit `5280bd038207e14f8bd76f5417aa2fe641c03228`
- deployment target iOS 15.0
- target device: iOS 16.1.2, arm64e, Dopamine rootless, ElleKit
- `IPhoneUSBMic.dylib`: arm64 + arm64e
- `IPhoneUSBMicD`: arm64
- `trollvncserver`: arm64

Package extraction and binary string inspection confirmed the package control
metadata, architecture slices, `3.2-273-perf2-mic2`, `IUMC`, and the Unix
ingress socket path.

## Package payload

```text
/var/jb/Library/MobileSubstrate/DynamicLibraries/IPhoneUSBMic.dylib
/var/jb/Library/MobileSubstrate/DynamicLibraries/IPhoneUSBMic.plist
/var/jb/usr/libexec/IPhoneUSBMicD
/var/jb/Library/LaunchDaemons/local.iphone.usbmicd.plist
```

ElleKit maps the MobileSubstrate compatibility directory to its rootless tweak
injection directory. The launch daemon runs as `mobile`, listens for tweak
consumers only on `127.0.0.1:29877`, and receives TrollVNC packets through
`/var/mobile/Library/Caches/local.iphone.usbmic/ingress.sock`.

## Build record

Bridge build:

```sh
THEOS=/tmp/iphone-usb-mic-theos make clean package FINALPACKAGE=1
```

The daemon compiled and linked as arm64. The tweak compiled, linked, merged,
and signed as arm64 + arm64e. Packaging completed without compiler errors.

Paired TrollVNC rootless build:

```sh
make clean package FINALPACKAGE=1 \
  THEOS=/tmp/iphone-usb-mic-theos \
  THEOS_PACKAGE_SCHEME=rootless \
  TARGET=iphone:clang:latest:15.0
```

The server and both preference bundles compiled, linked, signed, staged, and
packaged. The active source version is fixed in the TrollVNC Makefile as
`3.2-273-perf2-mic2`.

## Installation behavior

Normal install order is TrollVNC `mic2`, then bridge 1.0.2. The bridge
`postinst` creates its cache directory as `mobile:mobile` mode 0700 and performs
only `bootout`, `bootstrap`, and `kickstart -k` for
`system/local.iphone.usbmicd`. It explicitly does not invoke `sbreload` or kill
SpringBoard. TrollVNC's maintainer script restarts only its own daemon.

After package management has completely returned, close and reopen the target
recording app so ElleKit injects into a fresh app process. A Respring is not a
normal installation step. If a separate UI recovery ever becomes necessary,
do it only after dpkg/Sileo has fully exited.

## Interrupted-dpkg recovery actually used

An older installed bridge maintainer script reloaded SpringBoard while Sileo
was still recording package state. This left the bridge half-configured and a
Sileo trigger pending, so every later install re-entered the same failure.

The confirmed recovery sequence was:

1. Temporarily enable Dopamine iDownload and expose it only through USB with
   Mac `iproxy 31337:1337`. Confirm root on the device; do not expose port 1337
   or 31337 to LAN/WAN.
2. Run `dpkg --audit` to identify the half-configured bridge and pending
   trigger.
3. Back up the installed script to
   `/var/jb/var/lib/dpkg/info/local.iphone.usbmic.postinst.iusc-backup`.
   Its SHA-256 is
   `0af7f7320d17b5dccd2f039663b2e33e4df48524aaa75d9db75c5ed404820dac`.
4. Atomically replace the installed script with a temporary executable no-op
   (`#!/bin/sh` followed by `exit 0`). Its SHA-256 was
   `306c6ca7407560340797866e077e053627ad409277d1b9da58106fce4cf717cb`.
5. A bare rootless `dpkg` failed because `sh`, `rm`, `tar`, `diff`, and
   `dpkg-deb` were outside its inherited PATH. The command that completed the
   interrupted transaction was:

```sh
/var/jb/usr/bin/env PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:/usr/bin:/usr/sbin:/bin:/sbin /var/jb/usr/bin/dpkg --configure -a
```

6. After independently checking the uploaded files' hashes, install both final
   packages in one rootless dpkg transaction:

```sh
/var/jb/usr/bin/env PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:/usr/bin:/usr/sbin:/bin:/sbin /var/jb/usr/bin/dpkg -i /var/mobile/Media/Downloads/IUSCRecovery/trollvnc-mic2.deb /var/mobile/Media/Downloads/IUSCRecovery/usbmic-1.0.2.deb
```

7. Verify the two target packages with `dpkg-query`, verify the installed
   bridge postinst hash is the final safe hash, and verify the three runtime
   processes. The final evidence is not a claim that a fresh whole-database
   `dpkg --audit` was run after installation.
8. Disable iDownload, remove the two uploaded files/directory, stop `iproxy` and
   the temporary LAN HTTP installer, and remove its local temporary directory.

The user disabled iDownload after recovery. `idownloadd` was absent, a later
USB proxy connection returned `Connection refused`, and Mac ports 31337 and
18766 were no longer listening. The device upload directory and local temporary
installer files were removed. The old postinst backup remains on the phone as
recovery evidence.

## Final device evidence

- `dpkg-query` reported both `com.82flex.trollvnc` and
  `local.iphone.usbmic` as `ii` with the final versions.
- The installed bridge postinst matched SHA-256 `6af743...08f`.
- Two spaced process checks showed stable PIDs: SpringBoard 7843,
  `trollvncserver` 8005, and `IPhoneUSBMicD` 8014.
- The user closed/reopened Voice Memos, reconnected iPhone USB Console, held
  push-to-talk for about 8–10 seconds, and confirmed the playback was continuous
  and sourced from the computer microphone.

This proves the tested Console path:

```text
Mac microphone -> 48 kHz mono packetizer -> authenticated USB RFB/IUMC
-> TrollVNC Unix datagram -> IPhoneUSBMicD -> authenticated loopback consumer
-> ElleKit app-process hook -> Voice Memos recording -> playback
```

It does not prove every private recording API, baseband telephony, web PTT,
web audio, 16-viewer pressure, owner contention, the 1.5-second watchdog fault
path, or trusted public HTTPS.

## Final audio-loss fixes represented by these artifacts

1. The Mac requests a valid 100 ms AVAudioEngine tap and emits five 960-sample
   packets per typical 4,800-frame callback. Its RFB writer holds at most 12
   microphone packets (240 ms), rather than treating that normal burst as a
   three-packet overflow.
2. At the already-48-kHz input rate, the Mac uses whole-buffer conversion. The
   former streaming call converted only 4,096 of 4,800 frames, causing an
   approximately 15 ms gap every 100 ms.
3. The phone daemon requires a 65,536-byte Unix datagram receive buffer. The old
   4 KiB default fit only two of five 1,948-byte packets; the remainder failed
   with `ENOBUFS`. TrollVNC now checks `sendto()` and logs its first failure.
4. The tweak's ring is 131,072 samples. Its target is the complete current app
   callback plus 5,760 samples (120 ms), with a further 48,000-sample hard-lag
   margin. It preflights the complete callback, never produces audio followed by
   a zero tail, resumes only forward after rebuffering, preserves fractional
   sample position, and zeros the full callback if START/STOP changes generation
   during a render.

## Security and API boundary

The package covers app-process RemoteIO/VoiceProcessingIO, linear-PCM Audio
Queue input, and `AVCaptureAudioDataOutput`. The original system capture still
runs first, preserving the app's TCC decision and the iOS microphone privacy
indicator. While remote injection is active, unsupported layouts and underflow
produce silence, never the physical microphone.

It does not patch `mediaserverd`, bypass TCC, hide privacy indicators, or claim
coverage of baseband telephony and private capture paths. The relay's HMAC key
must remain embedded and must not be copied into documentation or logs.
