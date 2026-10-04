package iphoneusb

import (
	"fmt"
	"os"
	"strings"

	"golang.org/x/sys/unix"
)

const (
	trollVNCPort                = 5901
	maximumVNCPasswordFileBytes = 64
)

type directRFBConfig struct {
	targetUDID   string
	passwordFile string
}

func loadDirectRFBConfig() (directRFBConfig, error) {
	targetUDID := strings.TrimSpace(os.Getenv("WEBSCREEN_IPHONE_USB_UDID"))
	if !validUSBMuxUDID(targetUDID) {
		return directRFBConfig{}, fmt.Errorf("WEBSCREEN_IPHONE_USB_UDID is missing or invalid")
	}
	passwordFile := strings.TrimSpace(os.Getenv("WEBSCREEN_IPHONE_USB_VNC_PASSWORD_FILE"))
	if passwordFile == "" || !strings.HasPrefix(passwordFile, "/") {
		return directRFBConfig{}, fmt.Errorf("WEBSCREEN_IPHONE_USB_VNC_PASSWORD_FILE must be an absolute private file")
	}
	return directRFBConfig{targetUDID: targetUDID, passwordFile: passwordFile}, nil
}

func validUSBMuxUDID(value string) bool {
	if len(value) < 8 || len(value) > 64 {
		return false
	}
	for _, character := range value {
		if (character < '0' || character > '9') &&
			(character < 'a' || character > 'z') &&
			(character < 'A' || character > 'Z') && character != '-' {
			return false
		}
	}
	return true
}

// loadVNCPassword opens the credential with O_NOFOLLOW and validates the same
// descriptor that is read. This prevents a symlink or replacement race from
// redirecting the privileged Gateway to an unrelated file. The password is
// reloaded for every RFB connection so rotation needs no process restart.
func loadVNCPassword(path string) ([]byte, error) {
	descriptor, err := unix.Open(path, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, fmt.Errorf("open private VNC password file: %w", err)
	}
	file := os.NewFile(uintptr(descriptor), "iphone-vnc-password")
	if file == nil {
		_ = unix.Close(descriptor)
		return nil, fmt.Errorf("open private VNC password file")
	}
	defer file.Close()

	var stat unix.Stat_t
	if err := unix.Fstat(descriptor, &stat); err != nil {
		return nil, fmt.Errorf("inspect private VNC password file: %w", err)
	}
	if stat.Mode&unix.S_IFMT != unix.S_IFREG || stat.Mode&0o077 != 0 ||
		stat.Size <= 0 || stat.Size > maximumVNCPasswordFileBytes {
		return nil, fmt.Errorf("VNC password file must be a private regular file")
	}
	if os.Geteuid() != 0 && stat.Uid != uint32(os.Geteuid()) {
		return nil, fmt.Errorf("VNC password file must be owned by the Gateway user")
	}

	raw := make([]byte, stat.Size)
	read := 0
	for read < len(raw) {
		count, readErr := file.Read(raw[read:])
		read += count
		if readErr != nil {
			return nil, fmt.Errorf("read private VNC password file: %w", readErr)
		}
	}
	if len(raw) > 0 && raw[len(raw)-1] == '\n' {
		raw = raw[:len(raw)-1]
		if len(raw) > 0 && raw[len(raw)-1] == '\r' {
			raw = raw[:len(raw)-1]
		}
	}
	if len(raw) == 0 || len(raw) > 8 {
		zeroBytes(raw)
		return nil, fmt.Errorf("VNC password must contain 1 to 8 ASCII characters")
	}
	for _, character := range raw {
		if character < 0x20 || character > 0x7e {
			zeroBytes(raw)
			return nil, fmt.Errorf("VNC password must contain printable ASCII only")
		}
	}
	return raw, nil
}

func zeroBytes(bytes []byte) {
	for index := range bytes {
		bytes[index] = 0
	}
}
