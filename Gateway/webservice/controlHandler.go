package webservice

import (
	"encoding/binary"
	"fmt"
	"log"
	"time"
)

func (manager *WebRTCManager) handleControlMessage(
	deviceIdentifier string,
	receiptNo uint32,
	raw []byte,
) error {
	manager.RLock()
	broadcaster, exists := manager.broadcasters[deviceIdentifier]
	manager.RUnlock()
	if !exists {
		return fmt.Errorf("control target broadcaster not found")
	}
	broadcaster.Lock.RLock()
	sub := broadcaster.Subscribers[receiptNo]
	broadcaster.Lock.RUnlock()
	if sub == nil {
		return fmt.Errorf("control subscriber not found")
	}

	envelope, isEnvelope, decodeErr := decodeControlEnvelope(raw)
	if !isEnvelope {
		agent, _, agentExists := manager.currentAgent(deviceIdentifier)
		if !agentExists {
			return fmt.Errorf("shared agent is restarting")
		}
		return agent.HandleEvent(raw)
	}

	sub.telemetry.received.Add(1)
	if decodeErr != nil {
		sub.telemetry.noteStatus(controlAckInvalid)
		if envelope.Sequence != 0 {
			if err := sub.sendFeedback(
				encodeControlAck(envelope, controlAckInvalid, 0),
			); err != nil {
				sub.telemetry.feedbackSendError.Add(1)
			}
		}
		return decodeErr
	}

	sub.telemetry.controlMu.Lock()
	status := validateLegacyControlPacket(envelope.LegacyPayload)
	if status == controlAckWritten {
		status = sub.telemetry.validateTouchSequence(envelope)
	}
	driverWriteAtUs := int64(0)
	if status == controlAckWritten {
		agent, _, agentExists := manager.currentAgent(deviceIdentifier)
		if !agentExists {
			status = controlAckDriverError
		} else if err := agent.HandleEvent(envelope.LegacyPayload); err != nil {
			status = controlAckDriverError
			sub.telemetry.handleTouchWriteFailure(envelope)
			log.Printf(
				"control_driver_error receipt=%d seq=%d type=%d error=%q",
				receiptNo,
				envelope.Sequence,
				envelope.LegacyEventType,
				err,
			)
		} else {
			driverWriteAtUs = time.Now().UnixMicro()
		}
	}
	sub.feedbackMu.Lock()
	if status == controlAckWritten &&
		envelope.Flags&controlFlagFrameFeedback != 0 {
		sub.telemetry.addPendingFrame(pendingFrameFeedback{
			Envelope:        envelope,
			DriverWriteAtUs: driverWriteAtUs,
		})
	}
	sub.telemetry.controlMu.Unlock()

	sub.telemetry.noteStatus(status)
	ackError := sub.sendFeedbackLocked(
		encodeControlAck(envelope, status, driverWriteAtUs),
	)
	sub.feedbackMu.Unlock()
	if ackError != nil {
		sub.telemetry.feedbackSendError.Add(1)
		sub.telemetry.removePendingFrame(envelope.Sequence)
	}
	return nil
}

func validateLegacyControlPacket(raw []byte) controlAckStatus {
	if len(raw) == 0 {
		return controlAckInvalid
	}
	switch raw[0] {
	case 0x00:
		if len(raw) != 4 {
			return controlAckInvalid
		}
	case 0x01:
		if len(raw) != 18 {
			return controlAckInvalid
		}
	case 0x02, 0x03:
		if len(raw) != 10 {
			return controlAckInvalid
		}
	case 0x08:
		if len(raw) != 2 {
			return controlAckInvalid
		}
	case 0x09:
		if len(raw) < 14 {
			return controlAckInvalid
		}
		textLength := int(binary.BigEndian.Uint32(raw[10:14]))
		if textLength > maxControlPayloadSize ||
			len(raw) != 14+textLength {
			return controlAckInvalid
		}
	case 0x0B, 0x10:
		if len(raw) != 1 {
			return controlAckInvalid
		}
	case 0x0C:
		if len(raw) < 10 {
			return controlAckInvalid
		}
		nameLength := int(raw[7])
		descriptionLengthOffset := 8 + nameLength
		if descriptionLengthOffset+2 > len(raw) {
			return controlAckInvalid
		}
		descriptionLength := int(
			binary.BigEndian.Uint16(
				raw[descriptionLengthOffset : descriptionLengthOffset+2],
			),
		)
		if len(raw) != descriptionLengthOffset+2+descriptionLength {
			return controlAckInvalid
		}
	case 0x0D:
		if len(raw) < 5 {
			return controlAckInvalid
		}
		reportLength := int(binary.BigEndian.Uint16(raw[3:5]))
		if len(raw) != 5+reportLength {
			return controlAckInvalid
		}
	case 0x0E:
		if len(raw) != 3 {
			return controlAckInvalid
		}
	default:
		return controlAckUnsupported
	}
	return controlAckWritten
}
