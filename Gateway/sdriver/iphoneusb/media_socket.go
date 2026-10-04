package iphoneusb

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/sys/unix"
)

const (
	driverWireMagic         = "IUSD"
	driverWireVersion       = 1
	driverWireHeaderLength  = 32
	driverVideoStream       = 1
	driverAudioStream       = 2
	driverControlStream     = 3
	driverConfigurationType = 1
	driverMediaType         = 2
	driverRequestIDRType    = 1
	driverPingType          = 2
	driverHelloType         = 0x81
	driverPongType          = 0x82
	driverErrorType         = 0xff

	maximumDriverConfiguration = 64 * 1024
	maximumDriverControl       = 64 * 1024
	driverControlWriteTimeout  = 2 * time.Second
	driverHelloTimeout         = 4 * time.Second
)

type driverWireMessage struct {
	stream    byte
	message   byte
	flags     byte
	timestamp uint64
	sequence  uint32
	auxiliary uint32
	payload   []byte
}

type privateUnixSocket struct {
	connection   net.Conn
	stream       byte
	writeMu      sync.Mutex
	closeOnce    sync.Once
	pingSeq      atomic.Uint32
	lastPong     atomic.Int64
	heartbeatMu  sync.Mutex
	pendingPings map[uint32]uint64
}

type unixSocketIdentity struct {
	device uint64
	inode  uint64
	uid    uint32
	mode   uint32
}

type driverHello struct {
	Role    string `json:"role"`
	Version int    `json:"version"`
	Input   string `json:"input"`
}

func configuredDriverSocketDirectory(config map[string]string) (string, error) {
	raw := strings.TrimSpace(config["driver_socket_dir"])
	if raw == "" {
		raw = strings.TrimSpace(os.Getenv("WEBSCREEN_IPHONE_USB_DRIVER_SOCKET_DIR"))
	}
	if raw == "" {
		home, err := os.UserHomeDir()
		if err != nil || home == "" {
			return "", fmt.Errorf("resolve iPhone USB driver state directory")
		}
		raw = filepath.Join(home, ".remote-handset", "iphone-console")
	}
	if !filepath.IsAbs(raw) {
		return "", fmt.Errorf("iPhone USB driver socket directory must be absolute")
	}
	cleaned := filepath.Clean(raw)
	if cleaned == string(filepath.Separator) {
		return "", fmt.Errorf("iPhone USB driver socket directory is invalid")
	}
	return cleaned, nil
}

func connectPrivateUnixSocket(
	ctx context.Context,
	directory string,
	name string,
	stream byte,
) (*privateUnixSocket, error) {
	if stream < driverVideoStream || stream > driverControlStream {
		return nil, fmt.Errorf("invalid iPhone USB driver stream %d", stream)
	}
	if err := validatePrivateSocketDirectory(directory); err != nil {
		return nil, err
	}
	path := filepath.Join(directory, name)
	if filepath.Dir(path) != directory || len([]byte(path)) > 103 {
		return nil, fmt.Errorf("iPhone USB driver socket path is invalid")
	}
	before, err := inspectPrivateSocket(path)
	if err != nil {
		return nil, err
	}

	dialer := net.Dialer{}
	connection, err := dialer.DialContext(ctx, "unix", path)
	if err != nil {
		return nil, fmt.Errorf("connect iPhone USB driver %s: %w", name, err)
	}
	keep := false
	defer func() {
		if !keep {
			_ = connection.Close()
		}
	}()

	after, err := inspectPrivateSocket(path)
	if err != nil {
		return nil, err
	}
	if before != after {
		return nil, fmt.Errorf("iPhone USB driver %s changed during connection", name)
	}
	if remote, ok := connection.RemoteAddr().(*net.UnixAddr); !ok || remote.Name != path {
		return nil, fmt.Errorf("iPhone USB driver %s peer path mismatch", name)
	}

	socket := &privateUnixSocket{
		connection:   connection,
		stream:       stream,
		pendingPings: make(map[uint32]uint64, 4),
	}
	socket.lastPong.Store(time.Now().UnixNano())
	keep = true
	return socket, nil
}

func (socket *privateUnixSocket) recordPing(sequence uint32, timestamp uint64) {
	socket.heartbeatMu.Lock()
	socket.pendingPings[sequence] = timestamp
	socket.heartbeatMu.Unlock()
}

func (socket *privateUnixSocket) forgetPing(sequence uint32) {
	socket.heartbeatMu.Lock()
	delete(socket.pendingPings, sequence)
	socket.heartbeatMu.Unlock()
}

func (socket *privateUnixSocket) acceptPong(sequence uint32, timestamp uint64) bool {
	socket.heartbeatMu.Lock()
	expected, exists := socket.pendingPings[sequence]
	if exists && expected == timestamp {
		delete(socket.pendingPings, sequence)
	}
	socket.heartbeatMu.Unlock()
	return exists && expected == timestamp
}

func validatePrivateSocketDirectory(path string) error {
	var metadata unix.Stat_t
	if err := unix.Lstat(path, &metadata); err != nil {
		return fmt.Errorf("inspect iPhone USB driver socket directory: %w", err)
	}
	if uint32(metadata.Mode)&unix.S_IFMT != unix.S_IFDIR {
		return fmt.Errorf("iPhone USB driver socket directory is not a directory")
	}
	if metadata.Uid != uint32(os.Geteuid()) {
		return fmt.Errorf("iPhone USB driver socket directory has the wrong owner")
	}
	if uint32(metadata.Mode)&0o777 != 0o700 {
		return fmt.Errorf("iPhone USB driver socket directory permissions must be 0700")
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return fmt.Errorf("resolve iPhone USB driver socket directory: %w", err)
	}
	if filepath.Clean(resolved) != filepath.Clean(path) {
		return fmt.Errorf("iPhone USB driver socket directory must not be a symlink")
	}
	return nil
}

func inspectPrivateSocket(path string) (unixSocketIdentity, error) {
	var metadata unix.Stat_t
	if err := unix.Lstat(path, &metadata); err != nil {
		return unixSocketIdentity{}, fmt.Errorf("inspect iPhone USB driver socket %s: %w", filepath.Base(path), err)
	}
	mode := uint32(metadata.Mode)
	if mode&unix.S_IFMT != unix.S_IFSOCK {
		return unixSocketIdentity{}, fmt.Errorf("iPhone USB driver endpoint %s is not a Unix socket", filepath.Base(path))
	}
	if metadata.Uid != uint32(os.Geteuid()) {
		return unixSocketIdentity{}, fmt.Errorf("iPhone USB driver endpoint %s has the wrong owner", filepath.Base(path))
	}
	if mode&0o777 != 0o600 {
		return unixSocketIdentity{}, fmt.Errorf("iPhone USB driver endpoint %s permissions must be 0600", filepath.Base(path))
	}
	return unixSocketIdentity{
		device: uint64(metadata.Dev),
		inode:  uint64(metadata.Ino),
		uid:    metadata.Uid,
		mode:   mode,
	}, nil
}

func (socket *privateUnixSocket) read(maximumPayload uint32) (driverWireMessage, error) {
	if socket == nil || socket.connection == nil {
		return driverWireMessage{}, errors.New("iPhone USB driver socket is unavailable")
	}
	header := make([]byte, driverWireHeaderLength)
	if _, err := io.ReadFull(socket.connection, header); err != nil {
		return driverWireMessage{}, err
	}
	payloadLength := binary.BigEndian.Uint32(header[12:16])
	if string(header[0:4]) != driverWireMagic ||
		header[4] != driverWireVersion ||
		header[5] != socket.stream ||
		binary.BigEndian.Uint16(header[8:10]) != driverWireHeaderLength ||
		binary.BigEndian.Uint16(header[10:12]) != 0 ||
		payloadLength > maximumPayload {
		return driverWireMessage{}, fmt.Errorf("invalid iPhone USB driver stream %d header", socket.stream)
	}
	payload := make([]byte, int(payloadLength))
	if _, err := io.ReadFull(socket.connection, payload); err != nil {
		return driverWireMessage{}, err
	}
	return driverWireMessage{
		stream:    header[5],
		message:   header[6],
		flags:     header[7],
		timestamp: binary.BigEndian.Uint64(header[16:24]),
		sequence:  binary.BigEndian.Uint32(header[24:28]),
		auxiliary: binary.BigEndian.Uint32(header[28:32]),
		payload:   payload,
	}, nil
}

func (socket *privateUnixSocket) write(
	message byte,
	flags byte,
	timestamp uint64,
	sequence uint32,
	auxiliary uint32,
	payload []byte,
) error {
	if socket == nil || socket.connection == nil {
		return errors.New("iPhone USB driver socket is unavailable")
	}
	if socket.stream != driverControlStream || len(payload) > maximumDriverControl {
		return fmt.Errorf("invalid iPhone USB driver control message")
	}
	header := make([]byte, driverWireHeaderLength)
	copy(header[0:4], driverWireMagic)
	header[4] = driverWireVersion
	header[5] = socket.stream
	header[6] = message
	header[7] = flags
	binary.BigEndian.PutUint16(header[8:10], driverWireHeaderLength)
	binary.BigEndian.PutUint32(header[12:16], uint32(len(payload)))
	binary.BigEndian.PutUint64(header[16:24], timestamp)
	binary.BigEndian.PutUint32(header[24:28], sequence)
	binary.BigEndian.PutUint32(header[28:32], auxiliary)

	socket.writeMu.Lock()
	defer socket.writeMu.Unlock()
	if err := socket.connection.SetWriteDeadline(time.Now().Add(driverControlWriteTimeout)); err != nil {
		return err
	}
	defer socket.connection.SetWriteDeadline(time.Time{})
	if err := writeAll(socket.connection, header); err != nil {
		return err
	}
	if len(payload) > 0 {
		return writeAll(socket.connection, payload)
	}
	return nil
}

func writeAll(writer io.Writer, payload []byte) error {
	for len(payload) > 0 {
		written, err := writer.Write(payload)
		if err != nil {
			return err
		}
		if written <= 0 {
			return io.ErrShortWrite
		}
		payload = payload[written:]
	}
	return nil
}

func (socket *privateUnixSocket) readAndValidateHello() error {
	if err := socket.connection.SetReadDeadline(time.Now().Add(driverHelloTimeout)); err != nil {
		return err
	}
	message, err := socket.read(maximumDriverControl)
	_ = socket.connection.SetReadDeadline(time.Time{})
	if err != nil {
		return fmt.Errorf("read iPhone USB driver hello: %w", err)
	}
	if message.message != driverHelloType || message.flags != 0 ||
		message.timestamp != 0 || message.sequence != 0 || message.auxiliary != 0 {
		return fmt.Errorf("invalid iPhone USB driver hello")
	}
	var hello driverHello
	if err := json.Unmarshal(message.payload, &hello); err != nil {
		return fmt.Errorf("decode iPhone USB driver hello: %w", err)
	}
	if hello.Role != "iphone-usb-media-driver" || hello.Version != driverWireVersion ||
		hello.Input != "gateway-direct-rfb" {
		return fmt.Errorf("incompatible iPhone USB driver hello")
	}
	return nil
}

func (socket *privateUnixSocket) close() {
	if socket == nil {
		return
	}
	socket.closeOnce.Do(func() {
		if socket.connection != nil {
			_ = socket.connection.Close()
		}
	})
}
