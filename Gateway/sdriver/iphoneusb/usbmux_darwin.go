//go:build darwin && cgo

package iphoneusb

/*
#cgo CFLAGS: -I${SRCDIR}/../../../IPhoneUSBConsoleBridge/Vendor/include
#cgo LDFLAGS: ${SRCDIR}/../../../IPhoneUSBConsoleBridge/Vendor/lib/libusbmuxd-2.0.a ${SRCDIR}/../../../IPhoneUSBConsoleBridge/Vendor/lib/libimobiledevice-glue-1.0.a ${SRCDIR}/../../../IPhoneUSBConsoleBridge/Vendor/lib/libplist-2.0.a

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <usbmuxd.h>

enum {
    DIRECT_USBMUX_OK = 0,
    DIRECT_USBMUX_INVALID_ARGUMENT = -1000,
    DIRECT_USBMUX_DAEMON_UNAVAILABLE = -1001,
    DIRECT_USBMUX_TARGET_NOT_CONNECTED = -1002,
    DIRECT_USBMUX_NOT_USB = -1003,
    DIRECT_USBMUX_CONNECT_FAILED = -1004
};

static int32_t direct_usbmux_connect(
    const char *target_udid,
    uint16_t device_port,
    int32_t *out_fd
) {
    if (target_udid == NULL || target_udid[0] == '\0' ||
        device_port == 0 || out_fd == NULL) {
        return DIRECT_USBMUX_INVALID_ARGUMENT;
    }
    *out_fd = -1;

    usbmuxd_device_info_t device;
    memset(&device, 0, sizeof(device));
    const int result = usbmuxd_get_device(
        target_udid,
        &device,
        DEVICE_LOOKUP_USBMUX
    );
    if (result == 0) {
        return DIRECT_USBMUX_TARGET_NOT_CONNECTED;
    }
    if (result < 0) {
        return DIRECT_USBMUX_DAEMON_UNAVAILABLE;
    }
    if (device.conn_type != CONNECTION_TYPE_USB) {
        memset(&device, 0, sizeof(device));
        return DIRECT_USBMUX_NOT_USB;
    }

    const int fd = usbmuxd_connect(device.handle, device_port);
    memset(&device, 0, sizeof(device));
    if (fd < 0) {
        return DIRECT_USBMUX_CONNECT_FAILED;
    }
    *out_fd = (int32_t)fd;
    return DIRECT_USBMUX_OK;
}
*/
import "C"

import (
	"fmt"
	"net"
	"os"
	"unsafe"
)

// dialUSBMux opens a connection only through the local usbmuxd USB transport.
// The target UDID is mandatory and is passed to libusbmuxd's exact-match
// lookup; this code never falls back to the first attached phone or Wi-Fi.
func dialUSBMux(targetUDID string, devicePort uint16) (net.Conn, error) {
	var descriptor C.int32_t = -1
	target := C.CString(targetUDID)
	defer C.free(unsafe.Pointer(target))
	status := C.direct_usbmux_connect(
		target,
		C.uint16_t(devicePort),
		&descriptor,
	)
	if status != C.DIRECT_USBMUX_OK || descriptor < 0 {
		return nil, fmt.Errorf("usbmuxd USB connection failed (status %d)", int32(status))
	}

	file := os.NewFile(uintptr(descriptor), "iphone-rfb-usbmux")
	if file == nil {
		_ = C.usbmuxd_disconnect(C.int(descriptor))
		return nil, fmt.Errorf("wrap usbmuxd descriptor")
	}
	connection, err := net.FileConn(file)
	_ = file.Close()
	if err != nil {
		return nil, fmt.Errorf("prepare usbmuxd connection: %w", err)
	}
	return connection, nil
}
