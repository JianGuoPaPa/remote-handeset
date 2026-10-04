package webservice

import (
	"encoding/binary"
	"errors"
	"fmt"
	"time"
)

const (
	controlEnvelopeType      byte = 0x66
	controlAckType           byte = 0x67
	controlFrameFeedbackType byte = 0x68
	diagnosticsFeedbackType  byte = 0x69

	controlProtocolVersion byte = 1

	controlFlagFrameFeedback byte = 1 << 0

	controlEnvelopeHeaderSize = 20
	controlAckPacketSize      = 36
	controlFramePacketSize    = 52
	maxControlPayloadSize     = 1 << 20
)

type controlAckStatus byte

const (
	controlAckWritten controlAckStatus = iota
	controlAckDroppedStale
	controlAckDroppedNoDown
	controlAckInvalid
	controlAckDriverError
	controlAckUnsupported
)

func (status controlAckStatus) String() string {
	switch status {
	case controlAckWritten:
		return "written"
	case controlAckDroppedStale:
		return "dropped_stale"
	case controlAckDroppedNoDown:
		return "dropped_no_down"
	case controlAckInvalid:
		return "invalid"
	case controlAckDriverError:
		return "error"
	case controlAckUnsupported:
		return "unsupported"
	default:
		return "unknown"
	}
}

type controlEnvelope struct {
	Flags               byte
	Sequence            uint64
	ClientMonotonicUs   uint64
	LegacyPayload       []byte
	LegacyEventType     byte
	GatewayReceivedAtUs int64
}

func decodeControlEnvelope(raw []byte) (controlEnvelope, bool, error) {
	if len(raw) == 0 || raw[0] != controlEnvelopeType {
		return controlEnvelope{}, false, nil
	}
	if len(raw) < controlEnvelopeHeaderSize+1 {
		return controlEnvelope{}, true, fmt.Errorf("control envelope is too short: %d", len(raw))
	}
	payload := raw[controlEnvelopeHeaderSize:]
	envelope := controlEnvelope{
		Flags:               raw[2],
		Sequence:            binary.BigEndian.Uint64(raw[4:12]),
		ClientMonotonicUs:   binary.BigEndian.Uint64(raw[12:20]),
		LegacyPayload:       payload,
		LegacyEventType:     payload[0],
		GatewayReceivedAtUs: time.Now().UnixMicro(),
	}
	if raw[1] != controlProtocolVersion {
		return envelope, true, fmt.Errorf("unsupported control envelope version: %d", raw[1])
	}
	if raw[3] != 0 {
		return envelope, true, errors.New("control envelope reserved byte must be zero")
	}
	if len(payload) > maxControlPayloadSize {
		return envelope, true, fmt.Errorf("control payload exceeds %d bytes", maxControlPayloadSize)
	}
	if envelope.Sequence == 0 {
		return envelope, true, errors.New("control sequence must be non-zero")
	}
	return envelope, true, nil
}

func encodeControlAck(
	envelope controlEnvelope,
	status controlAckStatus,
	driverWriteAtUs int64,
) []byte {
	packet := make([]byte, controlAckPacketSize)
	packet[0] = controlAckType
	packet[1] = controlProtocolVersion
	packet[2] = byte(status)
	packet[3] = envelope.LegacyEventType
	binary.BigEndian.PutUint64(packet[4:12], envelope.Sequence)
	binary.BigEndian.PutUint64(packet[12:20], envelope.ClientMonotonicUs)
	binary.BigEndian.PutUint64(packet[20:28], uint64(envelope.GatewayReceivedAtUs))
	binary.BigEndian.PutUint64(packet[28:36], uint64(driverWriteAtUs))
	return packet
}

type pendingFrameFeedback struct {
	Envelope         controlEnvelope
	DriverWriteAtUs  int64
	BaselineFramePTS uint64
	HasBaselineFrame bool
}

type videoFrameObservation struct {
	ReceivedAtUs int64
	ObservedAtUs int64
	PTS          uint64
}

func encodeFrameFeedback(
	pending pendingFrameFeedback,
	frame videoFrameObservation,
) []byte {
	packet := make([]byte, controlFramePacketSize)
	packet[0] = controlFrameFeedbackType
	packet[1] = controlProtocolVersion
	packet[2] = byte(controlAckWritten)
	packet[3] = pending.Envelope.LegacyEventType
	binary.BigEndian.PutUint64(packet[4:12], pending.Envelope.Sequence)
	binary.BigEndian.PutUint64(packet[12:20], pending.Envelope.ClientMonotonicUs)
	binary.BigEndian.PutUint64(packet[20:28], uint64(pending.Envelope.GatewayReceivedAtUs))
	binary.BigEndian.PutUint64(packet[28:36], uint64(pending.DriverWriteAtUs))
	binary.BigEndian.PutUint64(packet[36:44], uint64(frame.ReceivedAtUs))
	binary.BigEndian.PutUint64(packet[44:52], frame.PTS)
	return packet
}
