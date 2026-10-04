//go:build !darwin || !cgo

package iphoneusb

import (
	"fmt"
	"net"
)

func dialUSBMux(string, uint16) (net.Conn, error) {
	return nil, fmt.Errorf("direct iPhone USB control requires macOS with cgo")
}
