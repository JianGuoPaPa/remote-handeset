package iphoneusb

import (
	"context"
	"crypto/des"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math/bits"
	"net"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	rfbHandshakeTimeout        = 15 * time.Second
	rfbControlWriteTimeout     = 3 * time.Second
	rfbMicrophoneWriteTimeout  = 5 * time.Millisecond
	rfbServerPayloadTimeout    = 5 * time.Second
	maximumRFBServerName       = 1 << 20
	maximumRFBServerText       = 1 << 20
	maximumRFBFailureReason    = 1 << 16
	imumcHeaderSize            = 28
	iphoneMicrophoneHeaderSize = 16
)

type rfbMicrophoneDemand struct {
	active      bool
	generation  uint32
	activeCount uint32
}

type rfbClient struct {
	connection net.Conn

	geometryMu sync.RWMutex
	width      uint16
	height     uint16

	writeMu     sync.Mutex
	stateMu     sync.Mutex
	closed      bool
	err         error
	done        chan struct{}
	monitorOnce sync.Once

	lastPointerMask byte
	lastPointerX    uint16
	lastPointerY    uint16
	activeMicStream uint32
	activeMicSeq    uint32
	onDemand        func(rfbMicrophoneDemand)
}

func connectDirectRFB(
	ctx context.Context,
	config directRFBConfig,
) (*rfbClient, error) {
	password, err := loadVNCPassword(config.passwordFile)
	if err != nil {
		return nil, err
	}
	defer zeroBytes(password)

	connection, err := dialUSBMux(config.targetUDID, trollVNCPort)
	if err != nil {
		return nil, fmt.Errorf("connect TrollVNC for configured USB device: %w", err)
	}
	client := &rfbClient{
		connection: connection,
		done:       make(chan struct{}),
	}
	if err := client.handshake(ctx, password); err != nil {
		_ = connection.Close()
		return nil, err
	}
	return client, nil
}

func (client *rfbClient) startMonitor(onDemand func(rfbMicrophoneDemand)) {
	client.monitorOnce.Do(func() {
		client.onDemand = onDemand
		go client.monitor()
	})
}

func (client *rfbClient) handshake(ctx context.Context, password []byte) error {
	deadline := time.Now().Add(rfbHandshakeTimeout)
	if contextDeadline, ok := ctx.Deadline(); ok && contextDeadline.Before(deadline) {
		deadline = contextDeadline
	}
	if err := client.connection.SetDeadline(deadline); err != nil {
		return fmt.Errorf("set RFB handshake deadline: %w", err)
	}
	defer client.connection.SetDeadline(time.Time{})

	banner := make([]byte, 12)
	if _, err := io.ReadFull(client.connection, banner); err != nil {
		return fmt.Errorf("read RFB banner: %w", err)
	}
	version, err := negotiateRFBVersion(banner)
	if err != nil {
		return err
	}
	if _, err := client.connection.Write([]byte(version)); err != nil {
		return fmt.Errorf("write RFB version: %w", err)
	}

	if version == "RFB 003.003\n" {
		securityType, err := readRFBUint32(client.connection)
		if err != nil {
			return fmt.Errorf("read RFB security type: %w", err)
		}
		if securityType == 0 {
			_ = discardRFBReason(client.connection)
			return fmt.Errorf("TrollVNC did not offer Classic VNCAuth")
		}
		if securityType != 2 {
			return fmt.Errorf("TrollVNC did not offer Classic VNCAuth")
		}
	} else {
		count := []byte{0}
		if _, err := io.ReadFull(client.connection, count); err != nil {
			return fmt.Errorf("read RFB security type count: %w", err)
		}
		if count[0] == 0 {
			_ = discardRFBReason(client.connection)
			return fmt.Errorf("TrollVNC did not offer Classic VNCAuth")
		}
		securityTypes := make([]byte, int(count[0]))
		if _, err := io.ReadFull(client.connection, securityTypes); err != nil {
			return fmt.Errorf("read RFB security types: %w", err)
		}
		offersVNCAuth := false
		for _, securityType := range securityTypes {
			if securityType == 2 {
				offersVNCAuth = true
				break
			}
		}
		if !offersVNCAuth {
			return fmt.Errorf("TrollVNC did not offer Classic VNCAuth")
		}
		if _, err := client.connection.Write([]byte{2}); err != nil {
			return fmt.Errorf("select Classic VNCAuth: %w", err)
		}
	}

	challenge := make([]byte, 16)
	response := make([]byte, 16)
	defer zeroBytes(challenge)
	defer zeroBytes(response)
	if _, err := io.ReadFull(client.connection, challenge); err != nil {
		return fmt.Errorf("read VNCAuth challenge: %w", err)
	}
	if err := encryptVNCChallenge(response, challenge, password); err != nil {
		return err
	}
	if _, err := client.connection.Write(response); err != nil {
		return fmt.Errorf("write VNCAuth response: %w", err)
	}
	securityResult, err := readRFBUint32(client.connection)
	if err != nil {
		return fmt.Errorf("read VNCAuth result: %w", err)
	}
	if securityResult != 0 {
		if version == "RFB 003.008\n" {
			_ = discardRFBReason(client.connection)
		}
		return fmt.Errorf("VNC password authentication failed")
	}

	// Shared=1 keeps an intentional local viewer connected.
	if _, err := client.connection.Write([]byte{1}); err != nil {
		return fmt.Errorf("write RFB ClientInit: %w", err)
	}
	width, err := readRFBUint16(client.connection)
	if err != nil {
		return fmt.Errorf("read RFB framebuffer width: %w", err)
	}
	height, err := readRFBUint16(client.connection)
	if err != nil {
		return fmt.Errorf("read RFB framebuffer height: %w", err)
	}
	if width == 0 || height == 0 {
		return fmt.Errorf("TrollVNC returned invalid framebuffer geometry")
	}
	serverInit := make([]byte, 16)
	if _, err := io.ReadFull(client.connection, serverInit); err != nil {
		return fmt.Errorf("read RFB pixel format: %w", err)
	}
	nameLength, err := readRFBUint32(client.connection)
	if err != nil || nameLength > maximumRFBServerName {
		return fmt.Errorf("read RFB server name length")
	}
	if _, err := io.CopyN(io.Discard, client.connection, int64(nameLength)); err != nil {
		return fmt.Errorf("read RFB server name: %w", err)
	}
	client.width = width
	client.height = height
	if err := client.sendMicrophoneCapability(); err != nil {
		return fmt.Errorf("send iPhone microphone capability: %w", err)
	}
	return nil
}

func (client *rfbClient) sendMicrophoneCapability() error {
	nonce, err := randomNonzeroUint32()
	if err != nil {
		return err
	}
	payload := make([]byte, iphoneMicrophoneHeaderSize)
	copy(payload[:4], "IUMH")
	payload[4] = 1
	payload[5] = 0x01
	binary.BigEndian.PutUint16(payload[6:8], iphoneMicrophoneHeaderSize)
	binary.BigEndian.PutUint32(payload[8:12], nonce)

	message := make([]byte, 8+len(payload))
	message[0] = 6 // RFB ClientCutText
	binary.BigEndian.PutUint32(message[4:8], uint32(len(payload)))
	copy(message[8:], payload)
	for written := 0; written < len(message); {
		count, writeErr := client.connection.Write(message[written:])
		written += count
		if writeErr != nil {
			return writeErr
		}
		if count == 0 {
			return fmt.Errorf("RFB capability write returned zero bytes")
		}
	}
	return nil
}

func randomNonzeroUint32() (uint32, error) {
	buffer := make([]byte, 4)
	for attempts := 0; attempts < 4; attempts++ {
		if _, err := rand.Read(buffer); err != nil {
			return 0, fmt.Errorf("generate random nonce: %w", err)
		}
		if value := binary.BigEndian.Uint32(buffer); value != 0 {
			return value, nil
		}
	}
	return 0, fmt.Errorf("generate non-zero random nonce")
}

func negotiateRFBVersion(banner []byte) (string, error) {
	if len(banner) != 12 || string(banner[:4]) != "RFB " || banner[7] != '.' || banner[11] != '\n' {
		return "", fmt.Errorf("unsupported RFB protocol banner")
	}
	for _, index := range []int{4, 5, 6, 8, 9, 10} {
		if banner[index] < '0' || banner[index] > '9' {
			return "", fmt.Errorf("unsupported RFB protocol banner")
		}
	}
	major := int(banner[4]-'0')*100 + int(banner[5]-'0')*10 + int(banner[6]-'0')
	minor := int(banner[8]-'0')*100 + int(banner[9]-'0')*10 + int(banner[10]-'0')
	if major != 3 || minor < 3 {
		return "", fmt.Errorf("unsupported RFB protocol version")
	}
	if minor >= 8 {
		return "RFB 003.008\n", nil
	}
	if minor >= 7 {
		return "RFB 003.007\n", nil
	}
	return "RFB 003.003\n", nil
}

func encryptVNCChallenge(response, challenge, password []byte) error {
	if len(response) != 16 || len(challenge) != 16 || len(password) == 0 || len(password) > 8 {
		return fmt.Errorf("invalid VNCAuth challenge material")
	}
	key := make([]byte, 8)
	defer zeroBytes(key)
	for index := range password {
		key[index] = bits.Reverse8(password[index])
	}
	cipher, err := des.NewCipher(key)
	if err != nil {
		return fmt.Errorf("initialize VNCAuth cipher: %w", err)
	}
	cipher.Encrypt(response[:8], challenge[:8])
	cipher.Encrypt(response[8:], challenge[8:])
	return nil
}

func (client *rfbClient) monitor() {
	for {
		if err := client.connection.SetReadDeadline(time.Now().Add(500 * time.Millisecond)); err != nil {
			client.fail(err)
			return
		}
		messageType := []byte{0}
		_, err := io.ReadFull(client.connection, messageType)
		if err != nil {
			var networkError net.Error
			if errors.As(err, &networkError) && networkError.Timeout() {
				if client.isClosed() {
					return
				}
				continue
			}
			if !client.isClosed() {
				client.fail(fmt.Errorf("RFB input connection closed: %w", err))
			}
			return
		}
		if err := client.consumeServerMessage(messageType[0]); err != nil {
			client.fail(err)
			return
		}
	}
}

func (client *rfbClient) consumeServerMessage(messageType byte) error {
	_ = client.connection.SetReadDeadline(time.Now().Add(rfbServerPayloadTimeout))
	switch messageType {
	case 1:
		header := make([]byte, 5)
		if _, err := io.ReadFull(client.connection, header); err != nil {
			return err
		}
		colourCount := binary.BigEndian.Uint16(header[3:5])
		_, err := io.CopyN(io.Discard, client.connection, int64(colourCount)*6)
		return err
	case 2:
		return nil
	case 3:
		header := make([]byte, 7)
		if _, err := io.ReadFull(client.connection, header); err != nil {
			return err
		}
		length := binary.BigEndian.Uint32(header[3:7])
		if length > maximumRFBServerText {
			return fmt.Errorf("RFB ServerCutText is too large")
		}
		return client.consumeServerCutText(length)
	default:
		return fmt.Errorf("unexpected RFB server message type %d", messageType)
	}
}

func (client *rfbClient) consumeServerCutText(length uint32) error {
	if length < 4 {
		_, err := io.CopyN(io.Discard, client.connection, int64(length))
		return err
	}
	prefix := make([]byte, 4)
	if _, err := io.ReadFull(client.connection, prefix); err != nil {
		return err
	}
	if string(prefix) != "IUMD" {
		_, err := io.CopyN(io.Discard, client.connection, int64(length)-4)
		return err
	}
	if length != iphoneMicrophoneHeaderSize {
		_, _ = io.CopyN(io.Discard, client.connection, int64(length)-4)
		return fmt.Errorf("invalid IUMD payload length")
	}
	payload := make([]byte, iphoneMicrophoneHeaderSize)
	copy(payload[:4], prefix)
	if _, err := io.ReadFull(client.connection, payload[4:]); err != nil {
		return err
	}
	if payload[4] != 1 || payload[5] > 1 ||
		binary.BigEndian.Uint16(payload[6:8]) != iphoneMicrophoneHeaderSize {
		return fmt.Errorf("invalid IUMD envelope")
	}
	generation := binary.BigEndian.Uint32(payload[8:12])
	if generation == 0 {
		return fmt.Errorf("invalid IUMD generation")
	}
	active := payload[5] == 1
	activeCount := binary.BigEndian.Uint32(payload[12:16])
	if (active && activeCount == 0) || (!active && activeCount != 0) {
		return fmt.Errorf("invalid IUMD state and active count")
	}
	if client.onDemand != nil {
		client.onDemand(rfbMicrophoneDemand{
			active:      active,
			generation:  generation,
			activeCount: activeCount,
		})
	}
	return nil
}

func (client *rfbClient) SendPointer(mask byte, x, y uint16) error {
	message := []byte{5, mask, byte(x >> 8), byte(x), byte(y >> 8), byte(y)}
	if err := client.write(message, rfbControlWriteTimeout); err != nil {
		return err
	}
	client.stateMu.Lock()
	if !client.closed {
		client.lastPointerMask = mask
		client.lastPointerX = x
		client.lastPointerY = y
	}
	client.stateMu.Unlock()
	return nil
}

func (client *rfbClient) SendKey(down bool, keysym uint32) error {
	message := make([]byte, 8)
	message[0] = 4
	if down {
		message[1] = 1
	}
	binary.BigEndian.PutUint32(message[4:8], keysym)
	return client.write(message, rfbControlWriteTimeout)
}

func (client *rfbClient) SendText(raw []byte) error {
	if len(raw) == 0 || len(raw) > 4096 || !utf8.Valid(raw) {
		return fmt.Errorf("iPhone text input is invalid or exceeds 4096 UTF-8 bytes")
	}
	text := string(raw)
	if utf8.RuneCountInString(text) > 512 {
		return fmt.Errorf("iPhone text input exceeds 512 Unicode scalars")
	}
	for _, scalar := range text {
		var keysym uint32
		switch scalar {
		case '\n', '\r':
			keysym = 0xff0d
		case '\t':
			keysym = 0xff09
		case '\b':
			keysym = 0xff08
		default:
			if unicode.IsControl(scalar) {
				return fmt.Errorf("iPhone text input contains an unsupported control character")
			}
			if scalar <= 0xff {
				keysym = uint32(scalar)
			} else {
				keysym = 0x01000000 | uint32(scalar)
			}
		}
		if err := client.SendKey(true, keysym); err != nil {
			return err
		}
		if err := client.SendKey(false, keysym); err != nil {
			return err
		}
		time.Sleep(22 * time.Millisecond)
	}
	return nil
}

func (client *rfbClient) SendButtonPulse(mask byte) error {
	width, height := client.FramebufferSize()
	x, y := width/2, height/2
	if err := client.SendPointer(mask, x, y); err != nil {
		return err
	}
	return client.SendPointer(0, x, y)
}

// FramebufferSize returns the current input coordinate space. TrollVNC sends
// ServerInit only once, but its OrientationSync path swaps the live framebuffer
// dimensions after a device rotation. The matching video configuration is the
// reliable orientation signal available on this input-only RFB connection.
func (client *rfbClient) FramebufferSize() (uint16, uint16) {
	client.geometryMu.RLock()
	defer client.geometryMu.RUnlock()
	return client.width, client.height
}

func (client *rfbClient) MatchVideoOrientation(codedWidth, codedHeight uint32) {
	if codedWidth == 0 || codedHeight == 0 || codedWidth == codedHeight {
		return
	}
	videoIsLandscape := codedWidth > codedHeight
	client.geometryMu.Lock()
	rfbIsLandscape := client.width > client.height
	if videoIsLandscape != rfbIsLandscape {
		client.width, client.height = client.height, client.width
	}
	client.geometryMu.Unlock()
}

func (client *rfbClient) SendMicrophonePacket(packet []byte) error {
	if len(packet) < imumcHeaderSize || string(packet[:4]) != "IUMC" {
		return fmt.Errorf("invalid IUMC packet")
	}
	message := make([]byte, 8+len(packet))
	message[0] = 6
	binary.BigEndian.PutUint32(message[4:8], uint32(len(packet)))
	copy(message[8:], packet)
	if err := client.write(message, rfbMicrophoneWriteTimeout); err != nil {
		return err
	}
	streamID := binary.BigEndian.Uint32(packet[8:12])
	sequence := binary.BigEndian.Uint32(packet[12:16])
	client.stateMu.Lock()
	if !client.closed {
		switch packet[5] {
		case 0x01:
			client.activeMicStream = streamID
			client.activeMicSeq = sequence
		case 0x04:
			if client.activeMicStream == streamID {
				client.activeMicSeq = sequence
			}
		case 0x02:
			if client.activeMicStream == streamID {
				client.activeMicStream = 0
				client.activeMicSeq = 0
			}
		}
	}
	client.stateMu.Unlock()
	return nil
}

func (client *rfbClient) write(message []byte, timeout time.Duration) error {
	client.writeMu.Lock()
	defer client.writeMu.Unlock()
	if client.isClosed() {
		return fmt.Errorf("RFB control is reconnecting")
	}
	if err := client.connection.SetWriteDeadline(time.Now().Add(timeout)); err != nil {
		client.fail(err)
		return err
	}
	written := 0
	for written < len(message) {
		count, err := client.connection.Write(message[written:])
		written += count
		if err != nil {
			client.fail(fmt.Errorf("write RFB input: %w", err))
			return err
		}
		if count == 0 {
			err := fmt.Errorf("write RFB input returned zero bytes")
			client.fail(err)
			return err
		}
	}
	_ = client.connection.SetWriteDeadline(time.Time{})
	return nil
}

func (client *rfbClient) Done() <-chan struct{} { return client.done }

func (client *rfbClient) Err() error {
	client.stateMu.Lock()
	defer client.stateMu.Unlock()
	return client.err
}

func (client *rfbClient) isClosed() bool {
	client.stateMu.Lock()
	defer client.stateMu.Unlock()
	return client.closed
}

func (client *rfbClient) fail(err error) {
	client.stateMu.Lock()
	if client.closed {
		client.stateMu.Unlock()
		return
	}
	client.closed = true
	client.err = err
	close(client.done)
	client.stateMu.Unlock()
	_ = client.connection.Close()
}

func (client *rfbClient) Close() {
	client.stateMu.Lock()
	if client.closed {
		client.stateMu.Unlock()
		return
	}
	pointerMask := client.lastPointerMask
	pointerX := client.lastPointerX
	pointerY := client.lastPointerY
	micStream := client.activeMicStream
	micSequence := client.activeMicSeq
	client.stateMu.Unlock()

	// Planned restarts release all state on the still-authenticated connection.
	// The matching phone-side clientGoneHook handles an unplanned transport loss.
	if micStream != 0 {
		_ = client.SendMicrophonePacket(directMicrophoneStopPacket(micStream, micSequence+1))
	}
	if pointerMask != 0 {
		_ = client.SendPointer(0, pointerX, pointerY)
	}
	client.fail(nil)
}

func directMicrophoneStopPacket(streamID, sequence uint32) []byte {
	packet := make([]byte, imumcHeaderSize)
	copy(packet[:4], "IUMC")
	packet[4] = 1
	packet[5] = 0x02
	binary.BigEndian.PutUint16(packet[6:8], imumcHeaderSize)
	binary.BigEndian.PutUint32(packet[8:12], streamID)
	binary.BigEndian.PutUint32(packet[12:16], sequence)
	binary.BigEndian.PutUint64(packet[16:24], uint64(time.Now().UnixMicro()))
	packet[26] = 1
	packet[27] = 1
	return packet
}

func readRFBUint16(reader io.Reader) (uint16, error) {
	buffer := make([]byte, 2)
	_, err := io.ReadFull(reader, buffer)
	return binary.BigEndian.Uint16(buffer), err
}

func readRFBUint32(reader io.Reader) (uint32, error) {
	buffer := make([]byte, 4)
	_, err := io.ReadFull(reader, buffer)
	return binary.BigEndian.Uint32(buffer), err
}

func discardRFBReason(reader io.Reader) error {
	length, err := readRFBUint32(reader)
	if err != nil {
		return err
	}
	if length > maximumRFBFailureReason {
		return fmt.Errorf("RFB failure reason is too large")
	}
	_, err = io.CopyN(io.Discard, reader, int64(length))
	return err
}
