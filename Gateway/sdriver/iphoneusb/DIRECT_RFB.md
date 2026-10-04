# iPhone USB direct RFB control

The Gateway owns the TrollVNC input connection. The Console remains the local
USB video/system-audio producer only; control and microphone input never use
the Console `/ws/control` endpoint.

## Required service environment

```text
WEBSCREEN_IPHONE_USB_UDID=<exact physical USB device UDID>
WEBSCREEN_IPHONE_USB_VNC_PASSWORD_FILE=<absolute path to a mode-0600 password file>
```

The password file contains the existing TrollVNC full-control password: one to
eight printable ASCII bytes, optionally followed by one newline. The Gateway
opens it with `O_NOFOLLOW`, validates the opened descriptor, never logs the
value, clears its temporary byte buffers, and reloads it on every reconnect.
Provision or rotate this file locally and atomically; do not put the password in
the LaunchDaemon environment, a command argument, source code, or the Console.

Classic VNCAuth is a TrollVNC protocol requirement and cannot be skipped. This
design removes the Console password-entry step, not authentication itself.

## Compatibility and exposure

- Direct control currently builds on macOS arm64 with cgo and the vendored
  arm64 `libusbmuxd`, `libimobiledevice-glue`, and `libplist` archives.
- The usbmux lookup requires the exact UDID and `DEVICE_LOOKUP_USBMUX`; it never
  selects the first phone or a network-discovered phone.
- Port 5901 is the phone-side usbmux destination. The Gateway opens no local or
  public TCP listener for 5901.
- The existing loopback Console bridge is still required for H.264 video and
  Opus system audio until those capture producers are moved into another native
  background process.
