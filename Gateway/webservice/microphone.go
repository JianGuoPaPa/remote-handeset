package webservice

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"time"
	"unicode/utf8"

	"github.com/pion/webrtc/v4"

	"webscreen/sdriver"
	sagent "webscreen/streamAgent"
)

const (
	microphoneHeaderSize          = 28
	microphoneSamplesPerPacket    = 960
	microphonePCMBytesPerPacket   = microphoneSamplesPerPacket * 2
	microphoneDataPacketSize      = microphoneHeaderSize + microphonePCMBytesPerPacket
	microphoneWatchdogDuration    = 1500 * time.Millisecond
	microphoneAcceptWindow        = 2 * time.Second
	microphoneMaximumPacketsPS    = 60
	microphoneMaximumControlBytes = 256
)

type microphoneChannel uint8

const (
	microphoneChannelControl microphoneChannel = iota
	microphoneChannelData
)

type microphonePacket struct {
	flags       byte
	streamID    uint32
	sequence    uint32
	timestamp   uint64
	sampleCount uint16
	raw         []byte
}

type subscriberIdentity [16]byte

type microphonePendingAccept struct {
	identity        subscriberIdentity
	generation      uint32
	agentGeneration uint64
	expiresAt       time.Time
}

type microphoneDemandState struct {
	active          bool
	generation      uint32
	activeCount     uint32
	agentGeneration uint64
	revision        uint64
	pending         map[uint32]microphonePendingAccept
}

type microphoneSession struct {
	ownerReceipt     uint32
	ownerIdentity    subscriberIdentity
	hasOwner         bool
	active           bool
	automatic        bool
	streamID         uint32
	lastSequence     uint32
	demandGeneration uint32
	agentGeneration  uint64
	generation       uint64
	watchdog         *time.Timer
	windowStart      time.Time
	windowCount      int
}

type microphoneSessionToken struct {
	sessionGeneration uint64
	agentGeneration   uint64
	ownerIdentity     subscriberIdentity
}

type microphoneOpusDecoder interface {
	Decode(packet []byte) ([]byte, error)
	Close()
}

func parseMicrophonePacket(raw []byte) (microphonePacket, error) {
	packet := microphonePacket{}
	if len(raw) < microphoneHeaderSize || len(raw) > microphoneDataPacketSize ||
		string(raw[:4]) != "IUMC" || raw[4] != 1 || binary.BigEndian.Uint16(raw[6:8]) != microphoneHeaderSize ||
		raw[26] != 1 || raw[27] != 1 {
		return packet, fmt.Errorf("invalid_envelope")
	}
	packet.flags = raw[5]
	packet.streamID = binary.BigEndian.Uint32(raw[8:12])
	packet.sequence = binary.BigEndian.Uint32(raw[12:16])
	packet.timestamp = binary.BigEndian.Uint64(raw[16:24])
	packet.sampleCount = binary.BigEndian.Uint16(raw[24:26])
	packet.raw = raw
	if packet.streamID == 0 {
		return microphonePacket{}, fmt.Errorf("zero_stream_id")
	}
	switch packet.flags {
	case 0x01, 0x02:
		if len(raw) != microphoneHeaderSize || packet.sampleCount != 0 {
			return microphonePacket{}, fmt.Errorf("invalid_control_packet")
		}
	case 0x04:
		if len(raw) != microphoneDataPacketSize || packet.sampleCount != microphoneSamplesPerPacket {
			return microphonePacket{}, fmt.Errorf("invalid_data_packet")
		}
	default:
		return microphonePacket{}, fmt.Errorf("unsupported_flags")
	}
	return packet, nil
}

func newSubscriberIdentity() (subscriberIdentity, error) {
	var identity subscriberIdentity
	for attempts := 0; attempts < 4; attempts++ {
		if _, err := rand.Read(identity[:]); err != nil {
			return subscriberIdentity{}, err
		}
		if identity != (subscriberIdentity{}) {
			return identity, nil
		}
	}
	return subscriberIdentity{}, fmt.Errorf("random subscriber identity remained zero")
}

func (manager *WebRTCManager) microphoneTarget(
	deviceIdentifier string,
	receiptNo uint32,
	identity subscriberIdentity,
) (
	*DeviceBroadcaster,
	*Subscriber,
	*sagent.Agent,
	uint64,
	error,
) {
	manager.RLock()
	broadcaster := manager.broadcasters[deviceIdentifier]
	manager.RUnlock()
	if broadcaster == nil {
		return nil, nil, nil, 0, fmt.Errorf("target_unavailable")
	}
	broadcaster.Lock.RLock()
	subscriber := broadcaster.Subscribers[receiptNo]
	broadcaster.Lock.RUnlock()
	if subscriber == nil || subscriber.identity != identity ||
		subscriber.requestedConfig.DeviceType != sagent.DEVICE_TYPE_IPHONE_USB ||
		subscriber.requestedConfig.DeviceID != sagent.IPHONE_USB_LOGICAL_DEVICE_ID {
		return nil, nil, nil, 0, fmt.Errorf("subscriber_not_authorized")
	}
	agent, currentBroadcaster, agentGeneration, exists := manager.currentAgentEpoch(deviceIdentifier)
	if !exists || currentBroadcaster != broadcaster {
		return nil, nil, nil, 0, fmt.Errorf("driver_unavailable")
	}
	return broadcaster, subscriber, agent, agentGeneration, nil
}

func microphoneSubscriberCurrent(
	broadcaster *DeviceBroadcaster,
	receiptNo uint32,
	identity subscriberIdentity,
	subscriber *Subscriber,
) bool {
	broadcaster.Lock.RLock()
	current := broadcaster.Subscribers[receiptNo] == subscriber && subscriber.identity == identity
	broadcaster.Lock.RUnlock()
	return current
}

func (manager *WebRTCManager) handleMicrophoneControlText(
	deviceIdentifier string,
	receiptNo uint32,
	identity subscriberIdentity,
	raw []byte,
) error {
	if len(raw) == 0 || len(raw) > microphoneMaximumControlBytes || !utf8.Valid(raw) {
		return fmt.Errorf("invalid_accept_json")
	}
	var message struct {
		V          int    `json:"v"`
		Type       string `json:"type"`
		Generation uint32 `json:"generation"`
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&message); err != nil {
		return fmt.Errorf("invalid_accept_json")
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return fmt.Errorf("invalid_accept_json")
	}
	if message.V != 1 || message.Type != "microphoneDemandAccept" || message.Generation == 0 {
		return fmt.Errorf("invalid_accept_message")
	}

	broadcaster, subscriber, agent, agentGeneration, err := manager.microphoneTarget(
		deviceIdentifier,
		receiptNo,
		identity,
	)
	if err != nil {
		return err
	}
	now := time.Now()
	broadcaster.MicrophoneMu.Lock()
	defer broadcaster.MicrophoneMu.Unlock()
	if !microphoneSubscriberCurrent(broadcaster, receiptNo, identity, subscriber) {
		return fmt.Errorf("subscriber_disconnected")
	}
	demand := &broadcaster.Demand
	if demand.agentGeneration != agentGeneration {
		return fmt.Errorf("agent_generation_mismatch")
	}
	if !demand.active {
		return fmt.Errorf("demand_idle")
	}
	if demand.generation != message.Generation {
		return fmt.Errorf("demand_generation_mismatch")
	}
	if broadcaster.Microphone.hasOwner {
		session := broadcaster.Microphone
		if session.ownerReceipt == receiptNo && session.ownerIdentity == identity &&
			session.agentGeneration == agentGeneration && session.demandGeneration == message.Generation {
			state := "starting"
			if session.active {
				state = "active"
			}
			subscriber.sendMicrophoneStatus(
				microphoneStatePayload(state, session.streamID, session.demandGeneration),
			)
			return nil
		}
		subscriber.sendMicrophoneStatus(microphoneStatePayload("busy", 0, message.Generation))
		return fmt.Errorf("owner_busy")
	}
	if demand.pending == nil {
		demand.pending = make(map[uint32]microphonePendingAccept)
	}
	pending := microphonePendingAccept{
		identity:        identity,
		generation:      message.Generation,
		agentGeneration: agentGeneration,
		expiresAt:       now.Add(microphoneAcceptWindow),
	}
	demand.pending[receiptNo] = pending
	if subscriber.hasRemoteAudioTrack() {
		return manager.activateAutomaticMicrophoneLocked(
			deviceIdentifier,
			broadcaster,
			subscriber,
			agent,
			receiptNo,
			pending,
		)
	}
	subscriber.sendMicrophoneStatus(microphoneStatePayload("starting", 0, message.Generation))
	time.AfterFunc(microphoneAcceptWindow, func() {
		manager.expireMicrophoneAccept(deviceIdentifier, broadcaster, receiptNo, pending)
	})
	return nil
}

func (manager *WebRTCManager) expireMicrophoneAccept(
	deviceIdentifier string,
	broadcaster *DeviceBroadcaster,
	receiptNo uint32,
	expected microphonePendingAccept,
) {
	manager.RLock()
	current := manager.broadcasters[deviceIdentifier]
	manager.RUnlock()
	if current != broadcaster {
		return
	}
	broadcaster.MicrophoneMu.Lock()
	pending, exists := broadcaster.Demand.pending[receiptNo]
	expired := exists && pending == expected && !time.Now().Before(pending.expiresAt)
	if expired {
		delete(broadcaster.Demand.pending, receiptNo)
	}
	broadcaster.MicrophoneMu.Unlock()
	if expired {
		broadcaster.Lock.RLock()
		subscriber := broadcaster.Subscribers[receiptNo]
		broadcaster.Lock.RUnlock()
		if subscriber != nil && subscriber.identity == expected.identity {
			subscriber.sendMicrophoneStatus(
				microphoneStatePayload("unavailable", 0, expected.generation),
			)
		}
		log.Printf(
			"microphone_accept_expired receipt=%d generation=%d reason=%q",
			receiptNo,
			expected.generation,
			"remote_track_not_ready",
		)
	}
}

func (manager *WebRTCManager) activateAutomaticMicrophoneLocked(
	deviceIdentifier string,
	broadcaster *DeviceBroadcaster,
	subscriber *Subscriber,
	agent *sagent.Agent,
	receiptNo uint32,
	expected microphonePendingAccept,
) error {
	if !microphoneSubscriberCurrent(broadcaster, receiptNo, expected.identity, subscriber) {
		return fmt.Errorf("subscriber_disconnected")
	}
	pending, exists := broadcaster.Demand.pending[receiptNo]
	if !exists || pending != expected {
		return fmt.Errorf("accept_not_pending")
	}
	delete(broadcaster.Demand.pending, receiptNo)
	if !time.Now().Before(pending.expiresAt) {
		return fmt.Errorf("accept_expired")
	}
	if !broadcaster.Demand.active {
		return fmt.Errorf("demand_idle")
	}
	if broadcaster.Demand.generation != pending.generation {
		return fmt.Errorf("demand_generation_mismatch")
	}
	if broadcaster.Demand.agentGeneration != pending.agentGeneration {
		return fmt.Errorf("agent_generation_mismatch")
	}
	if broadcaster.Microphone.hasOwner {
		subscriber.sendMicrophoneStatus(
			microphoneStatePayload("busy", 0, pending.generation),
		)
		return fmt.Errorf("owner_busy")
	}
	streamID, err := randomNonzeroMicrophoneStreamID()
	if err != nil {
		subscriber.sendMicrophoneStatus(
			microphoneStatePayload("unavailable", 0, pending.generation),
		)
		return fmt.Errorf("stream_id_generation_failed")
	}
	internalGeneration := broadcaster.Microphone.generation + 1
	broadcaster.Microphone = microphoneSession{
		ownerReceipt:     receiptNo,
		ownerIdentity:    pending.identity,
		hasOwner:         true,
		automatic:        true,
		streamID:         streamID,
		demandGeneration: pending.generation,
		agentGeneration:  pending.agentGeneration,
		generation:       internalGeneration,
		windowStart:      time.Now(),
	}
	if err := agent.SendMicrophonePacket(microphoneStartPacket(streamID, 0)); err != nil {
		manager.clearMicrophoneLocked(broadcaster)
		subscriber.sendMicrophoneStatus(
			microphoneStatePayload("unavailable", streamID, pending.generation),
		)
		return fmt.Errorf("forward_start_failed")
	}
	broadcaster.Microphone.active = true
	manager.armMicrophoneWatchdogLocked(deviceIdentifier, broadcaster)
	subscriber.sendMicrophoneStatus(
		microphoneStatePayload("active", streamID, pending.generation),
	)
	log.Printf(
		"microphone_session_started receipt=%d generation=%d mode=%q",
		receiptNo,
		pending.generation,
		"webrtc_opus",
	)
	return nil
}

func (manager *WebRTCManager) handleMicrophonePacket(
	deviceIdentifier string,
	receiptNo uint32,
	identity subscriberIdentity,
	channel microphoneChannel,
	raw []byte,
) error {
	packet, err := parseMicrophonePacket(raw)
	if err != nil {
		return err
	}
	broadcaster, subscriber, agent, agentGeneration, err := manager.microphoneTarget(
		deviceIdentifier,
		receiptNo,
		identity,
	)
	if err != nil {
		return err
	}

	broadcaster.MicrophoneMu.Lock()
	defer broadcaster.MicrophoneMu.Unlock()
	if !microphoneSubscriberCurrent(broadcaster, receiptNo, identity, subscriber) {
		return fmt.Errorf("subscriber_disconnected")
	}
	if broadcaster.Demand.agentGeneration != agentGeneration {
		return fmt.Errorf("agent_generation_mismatch")
	}
	session := &broadcaster.Microphone
	switch packet.flags {
	case 0x01:
		if channel != microphoneChannelControl {
			return fmt.Errorf("start_wrong_channel")
		}
		if !broadcaster.Demand.active {
			return fmt.Errorf("demand_idle")
		}
		if session.hasOwner {
			if session.ownerReceipt == receiptNo && session.ownerIdentity == identity &&
				session.agentGeneration == agentGeneration && session.streamID == packet.streamID &&
				session.demandGeneration == broadcaster.Demand.generation && !session.automatic {
				subscriber.sendMicrophoneStatus(
					microphoneStatePayload("active", packet.streamID, session.demandGeneration),
				)
				manager.armMicrophoneWatchdogLocked(deviceIdentifier, broadcaster)
				return nil
			}
			subscriber.sendMicrophoneStatus(
				microphoneStatePayload("busy", packet.streamID, broadcaster.Demand.generation),
			)
			return fmt.Errorf("owner_busy")
		}
		pending, exists := broadcaster.Demand.pending[receiptNo]
		if !exists || pending.identity != identity {
			return fmt.Errorf("accept_not_pending")
		}
		delete(broadcaster.Demand.pending, receiptNo)
		if !time.Now().Before(pending.expiresAt) {
			return fmt.Errorf("accept_expired")
		}
		if pending.generation != broadcaster.Demand.generation {
			return fmt.Errorf("demand_generation_mismatch")
		}
		if pending.agentGeneration != agentGeneration {
			return fmt.Errorf("agent_generation_mismatch")
		}
		internalGeneration := session.generation + 1
		*session = microphoneSession{
			ownerReceipt:     receiptNo,
			ownerIdentity:    identity,
			hasOwner:         true,
			streamID:         packet.streamID,
			lastSequence:     packet.sequence,
			demandGeneration: pending.generation,
			agentGeneration:  agentGeneration,
			generation:       internalGeneration,
			windowStart:      time.Now(),
		}
		if err := agent.SendMicrophonePacket(packet.raw); err != nil {
			manager.clearMicrophoneLocked(broadcaster)
			subscriber.sendMicrophoneStatus(
				microphoneStatePayload("unavailable", packet.streamID, pending.generation),
			)
			return fmt.Errorf("forward_start_failed")
		}
		session.active = true
		manager.armMicrophoneWatchdogLocked(deviceIdentifier, broadcaster)
		subscriber.sendMicrophoneStatus(
			microphoneStatePayload("active", packet.streamID, pending.generation),
		)
	case 0x04:
		if channel != microphoneChannelData {
			return fmt.Errorf("data_wrong_channel")
		}
		if !broadcaster.Demand.active {
			return fmt.Errorf("demand_idle")
		}
		if !session.hasOwner {
			return fmt.Errorf("no_owner")
		}
		if session.ownerReceipt != receiptNo || session.ownerIdentity != identity {
			return fmt.Errorf("owner_mismatch")
		}
		if session.agentGeneration != agentGeneration {
			return fmt.Errorf("agent_generation_mismatch")
		}
		if session.automatic {
			return fmt.Errorf("data_channel_not_used_by_auto_session")
		}
		if !session.active {
			return fmt.Errorf("session_inactive")
		}
		if session.demandGeneration != broadcaster.Demand.generation {
			return fmt.Errorf("demand_generation_mismatch")
		}
		if session.streamID != packet.streamID {
			return fmt.Errorf("stream_mismatch")
		}
		if !microphoneSequenceAfter(packet.sequence, session.lastSequence) {
			return fmt.Errorf("sequence_not_after")
		}
		if !manager.acceptMicrophoneRateLocked(session, time.Now()) {
			return fmt.Errorf("data_rate_exceeded")
		}
		if err := agent.SendMicrophonePacket(packet.raw); err != nil {
			manager.stopAndClearMicrophoneLocked(broadcaster, agent, "unavailable")
			return fmt.Errorf("forward_data_failed")
		}
		session.lastSequence = packet.sequence
		manager.armMicrophoneWatchdogLocked(deviceIdentifier, broadcaster)
	case 0x02:
		if channel != microphoneChannelControl {
			return fmt.Errorf("stop_wrong_channel")
		}
		if !session.hasOwner {
			return fmt.Errorf("no_owner")
		}
		if session.ownerReceipt != receiptNo || session.ownerIdentity != identity {
			return fmt.Errorf("owner_mismatch")
		}
		if session.agentGeneration != agentGeneration {
			return fmt.Errorf("agent_generation_mismatch")
		}
		if session.automatic {
			return fmt.Errorf("binary_stop_not_used_by_auto_session")
		}
		if session.streamID != packet.streamID {
			return fmt.Errorf("stream_mismatch")
		}
		if !microphoneSequenceAfter(packet.sequence, session.lastSequence) {
			return fmt.Errorf("sequence_not_after")
		}
		generation := session.demandGeneration
		manager.clearMicrophoneLocked(broadcaster)
		if err := agent.SendMicrophonePacket(packet.raw); err != nil {
			subscriber.sendMicrophoneStatus(
				microphoneStatePayload("unavailable", packet.streamID, generation),
			)
			return fmt.Errorf("forward_stop_failed")
		}
		subscriber.sendMicrophoneStatus(microphoneStatePayload("ready", 0, generation))
	}
	return nil
}

func (manager *WebRTCManager) acceptMicrophoneRateLocked(session *microphoneSession, now time.Time) bool {
	if session.windowStart.IsZero() || now.Sub(session.windowStart) >= time.Second {
		session.windowStart = now
		session.windowCount = 0
	}
	if session.windowCount >= microphoneMaximumPacketsPS {
		return false
	}
	session.windowCount++
	return true
}

func microphoneSequenceAfter(candidate, previous uint32) bool {
	distance := candidate - previous
	return distance != 0 && distance < 0x8000_0000
}

func rtpSequenceAfter(candidate, previous uint16) bool {
	distance := candidate - previous
	return distance != 0 && distance < 0x8000
}

func (manager *WebRTCManager) armMicrophoneWatchdogLocked(deviceIdentifier string, broadcaster *DeviceBroadcaster) {
	session := &broadcaster.Microphone
	if session.watchdog != nil {
		session.watchdog.Stop()
	}
	generation := session.generation
	owner := session.ownerReceipt
	ownerIdentity := session.ownerIdentity
	agentGeneration := session.agentGeneration
	streamID := session.streamID
	session.watchdog = time.AfterFunc(microphoneWatchdogDuration, func() {
		manager.expireMicrophone(
			deviceIdentifier,
			broadcaster,
			generation,
			owner,
			ownerIdentity,
			agentGeneration,
			streamID,
		)
	})
}

func (manager *WebRTCManager) expireMicrophone(
	deviceIdentifier string,
	broadcaster *DeviceBroadcaster,
	generation uint64,
	owner uint32,
	ownerIdentity subscriberIdentity,
	agentGeneration uint64,
	streamID uint32,
) {
	agent, currentBroadcaster, currentAgentGeneration, exists := manager.currentAgentEpoch(deviceIdentifier)
	if !exists || currentBroadcaster != broadcaster || currentAgentGeneration != agentGeneration {
		return
	}
	broadcaster.MicrophoneMu.Lock()
	defer broadcaster.MicrophoneMu.Unlock()
	session := &broadcaster.Microphone
	if !session.hasOwner || session.generation != generation || session.ownerReceipt != owner ||
		session.ownerIdentity != ownerIdentity || session.agentGeneration != agentGeneration ||
		session.streamID != streamID {
		return
	}
	manager.stopAndClearMicrophoneLocked(broadcaster, agent, "ready")
	log.Printf("microphone_session_stopped receipt=%d reason=%q", owner, "watchdog_timeout")
}

func (manager *WebRTCManager) stopAndClearMicrophoneLocked(
	broadcaster *DeviceBroadcaster,
	agent *sagent.Agent,
	state string,
) {
	session := broadcaster.Microphone
	if !session.hasOwner {
		return
	}
	if err := agent.SendMicrophonePacket(
		microphoneStopPacket(session.streamID, session.lastSequence+1),
	); err != nil {
		log.Printf("microphone_stop_forward_failed receipt=%d reason=%q", session.ownerReceipt, "driver_write_failed")
	}
	manager.clearMicrophoneLocked(broadcaster)
	broadcaster.Lock.RLock()
	subscriber := broadcaster.Subscribers[session.ownerReceipt]
	broadcaster.Lock.RUnlock()
	if subscriber != nil && subscriber.identity == session.ownerIdentity {
		subscriber.sendMicrophoneStatus(
			microphoneStatePayload(state, session.streamID, session.demandGeneration),
		)
	}
}

func (manager *WebRTCManager) clearMicrophoneLocked(broadcaster *DeviceBroadcaster) {
	if broadcaster.Microphone.watchdog != nil {
		broadcaster.Microphone.watchdog.Stop()
	}
	broadcaster.Microphone = microphoneSession{generation: broadcaster.Microphone.generation + 1}
}

func (manager *WebRTCManager) releaseMicrophoneForSubscriber(
	deviceIdentifier string,
	receiptNo uint32,
	identity subscriberIdentity,
	reason string,
) {
	agent, broadcaster, agentGeneration, exists := manager.currentAgentEpoch(deviceIdentifier)
	if !exists {
		manager.RLock()
		broadcaster = manager.broadcasters[deviceIdentifier]
		manager.RUnlock()
	}
	if broadcaster == nil {
		return
	}
	broadcaster.MicrophoneMu.Lock()
	defer broadcaster.MicrophoneMu.Unlock()
	if pending, ok := broadcaster.Demand.pending[receiptNo]; ok && pending.identity == identity {
		delete(broadcaster.Demand.pending, receiptNo)
	}
	if !broadcaster.Microphone.hasOwner || broadcaster.Microphone.ownerReceipt != receiptNo ||
		broadcaster.Microphone.ownerIdentity != identity {
		return
	}
	if exists && broadcaster.Microphone.agentGeneration == agentGeneration {
		manager.stopAndClearMicrophoneLocked(broadcaster, agent, "ready")
	} else {
		manager.clearMicrophoneLocked(broadcaster)
	}
	log.Printf("microphone_session_stopped receipt=%d reason=%q", receiptNo, reason)
}

func (manager *WebRTCManager) releaseLegacyMicrophoneForSubscriber(
	deviceIdentifier string,
	receiptNo uint32,
	identity subscriberIdentity,
	reason string,
) {
	agent, broadcaster, agentGeneration, exists := manager.currentAgentEpoch(deviceIdentifier)
	if !exists || broadcaster == nil {
		return
	}
	broadcaster.MicrophoneMu.Lock()
	defer broadcaster.MicrophoneMu.Unlock()
	session := broadcaster.Microphone
	if !session.hasOwner || session.ownerReceipt != receiptNo || session.ownerIdentity != identity ||
		session.agentGeneration != agentGeneration || session.automatic {
		return
	}
	manager.stopAndClearMicrophoneLocked(broadcaster, agent, "ready")
	log.Printf("microphone_session_stopped receipt=%d reason=%q", receiptNo, reason)
}

func microphoneStartPacket(streamID, sequence uint32) []byte {
	return microphonePacketWithPCM(0x01, streamID, sequence, nil)
}

func microphoneStopPacket(streamID, sequence uint32) []byte {
	return microphonePacketWithPCM(0x02, streamID, sequence, nil)
}

func microphoneDataPacket(streamID, sequence uint32, pcm []byte) []byte {
	return microphonePacketWithPCM(0x04, streamID, sequence, pcm)
}

func microphonePacketWithPCM(flags byte, streamID, sequence uint32, pcm []byte) []byte {
	packet := make([]byte, microphoneHeaderSize+len(pcm))
	copy(packet[:4], "IUMC")
	packet[4] = 1
	packet[5] = flags
	binary.BigEndian.PutUint16(packet[6:8], microphoneHeaderSize)
	binary.BigEndian.PutUint32(packet[8:12], streamID)
	binary.BigEndian.PutUint32(packet[12:16], sequence)
	binary.BigEndian.PutUint64(packet[16:24], uint64(time.Now().UnixMicro()))
	if len(pcm) != 0 {
		binary.BigEndian.PutUint16(packet[24:26], uint16(len(pcm)/2))
		copy(packet[microphoneHeaderSize:], pcm)
	}
	packet[26] = 1
	packet[27] = 1
	return packet
}

func randomNonzeroMicrophoneStreamID() (uint32, error) {
	buffer := make([]byte, 4)
	for attempts := 0; attempts < 4; attempts++ {
		if _, err := rand.Read(buffer); err != nil {
			return 0, err
		}
		if value := binary.BigEndian.Uint32(buffer); value != 0 {
			return value, nil
		}
	}
	return 0, fmt.Errorf("random stream ID remained zero")
}

func microphoneStatePayload(state string, streamID, generation uint32) []byte {
	payload := map[string]any{
		"v":          1,
		"type":       "microphoneState",
		"state":      state,
		"generation": generation,
	}
	if streamID != 0 {
		payload["streamID"] = streamID
	}
	encoded, _ := json.Marshal(payload)
	return encoded
}

func microphoneDemandPayload(demand microphoneDemandState) []byte {
	state := "idle"
	if demand.active {
		state = "active"
	}
	encoded, _ := json.Marshal(map[string]any{
		"v":          1,
		"type":       "microphoneDemand",
		"state":      state,
		"generation": demand.generation,
	})
	return encoded
}

func (manager *WebRTCManager) forwardMicrophoneDemand(
	broadcaster *DeviceBroadcaster,
	agent *sagent.Agent,
	agentGeneration uint64,
) {
	latestRevision := uint64(0)
	if demand, ok := agent.CurrentMicrophoneDemand(); ok {
		manager.applyMicrophoneDemandFromAgent(broadcaster, agent, agentGeneration, demand)
		latestRevision = demand.Revision
	}
	demands, ok := agent.MicrophoneDemand()
	if !ok {
		return
	}
	for {
		select {
		case <-agent.Done():
			current := sdriver.MicrophoneDemand{}
			if snapshot, exists := agent.CurrentMicrophoneDemand(); exists {
				current.Generation = snapshot.Generation
			}
			manager.applyMicrophoneDemandFromAgent(broadcaster, agent, agentGeneration, current)
			return
		case demand, open := <-demands:
			if !open {
				return
			}
			if demand.Revision != 0 && demand.Revision <= latestRevision {
				continue
			}
			latestRevision = demand.Revision
			manager.applyMicrophoneDemandFromAgent(broadcaster, agent, agentGeneration, demand)
		}
	}
}

func (manager *WebRTCManager) applyMicrophoneDemandFromAgent(
	broadcaster *DeviceBroadcaster,
	agent *sagent.Agent,
	agentGeneration uint64,
	demand sdriver.MicrophoneDemand,
) {
	broadcaster.AgentLock.Lock()
	if broadcaster.Agent != agent || broadcaster.AgentGeneration != agentGeneration ||
		(demand.Active && demand.Generation == 0) {
		broadcaster.AgentLock.Unlock()
		return
	}

	next := microphoneDemandState{
		active:          demand.Active,
		generation:      demand.Generation,
		activeCount:     demand.ActiveCount,
		agentGeneration: agentGeneration,
	}
	broadcaster.MicrophoneMu.Lock()
	previous := broadcaster.Demand
	stateChanged := previous.active != next.active || previous.generation != next.generation ||
		previous.activeCount != next.activeCount || previous.agentGeneration != next.agentGeneration
	next.revision = previous.revision
	if stateChanged {
		next.revision++
	}
	visibleChanged := previous.active != next.active || previous.generation != next.generation
	invalidatesSession := !next.active || previous.generation != next.generation ||
		previous.agentGeneration != next.agentGeneration
	if invalidatesSession {
		if broadcaster.Microphone.hasOwner {
			if broadcaster.Microphone.agentGeneration == agentGeneration {
				manager.stopAndClearMicrophoneLocked(broadcaster, agent, "ready")
			} else {
				manager.clearMicrophoneLocked(broadcaster)
			}
		}
		next.pending = make(map[uint32]microphonePendingAccept)
	} else {
		next.pending = previous.pending
	}
	broadcaster.Demand = next
	payload := microphoneDemandPayload(next)
	broadcaster.MicrophoneMu.Unlock()
	broadcaster.AgentLock.Unlock()

	if visibleChanged {
		manager.broadcastMicrophoneDemand(broadcaster, next.revision, payload)
		state := "idle"
		if next.active {
			state = "active"
		}
		log.Printf(
			"microphone_demand_updated generation=%d state=%q active_count=%d revision=%d agent_generation=%d",
			next.generation,
			state,
			next.activeCount,
			next.revision,
			next.agentGeneration,
		)
	}
}

// transitionMicrophoneAgentLocked atomically retires microphone ownership from
// one Agent epoch and installs an ordered transport-idle snapshot for the next.
// The caller must hold broadcaster.AgentLock so an old Agent goroutine cannot
// publish after this transition commits.
func (manager *WebRTCManager) transitionMicrophoneAgentLocked(
	broadcaster *DeviceBroadcaster,
	oldAgent *sagent.Agent,
	nextAgentGeneration uint64,
	reason string,
) {
	broadcaster.MicrophoneMu.Lock()
	previous := broadcaster.Demand
	if previous.agentGeneration == nextAgentGeneration {
		broadcaster.MicrophoneMu.Unlock()
		return
	}
	if broadcaster.Microphone.hasOwner {
		if oldAgent != nil && broadcaster.Microphone.agentGeneration == broadcaster.AgentGeneration {
			manager.stopAndClearMicrophoneLocked(broadcaster, oldAgent, "ready")
		} else {
			manager.clearMicrophoneLocked(broadcaster)
		}
	}
	next := microphoneDemandState{
		active:          false,
		generation:      previous.generation,
		activeCount:     0,
		agentGeneration: nextAgentGeneration,
		revision:        previous.revision + 1,
		pending:         make(map[uint32]microphonePendingAccept),
	}
	broadcaster.Demand = next
	payload := microphoneDemandPayload(next)
	broadcaster.MicrophoneMu.Unlock()

	manager.broadcastMicrophoneDemand(broadcaster, next.revision, payload)
	log.Printf(
		"microphone_transport_idle reason=%q revision=%d agent_generation=%d",
		reason,
		next.revision,
		next.agentGeneration,
	)
}

func (manager *WebRTCManager) broadcastMicrophoneDemand(
	broadcaster *DeviceBroadcaster,
	revision uint64,
	payload []byte,
) {
	broadcaster.Lock.RLock()
	subscribers := make([]*Subscriber, 0, len(broadcaster.Subscribers))
	for _, subscriber := range broadcaster.Subscribers {
		if subscriber.requestedConfig.DeviceType == sagent.DEVICE_TYPE_IPHONE_USB &&
			subscriber.requestedConfig.DeviceID == sagent.IPHONE_USB_LOGICAL_DEVICE_ID {
			subscribers = append(subscribers, subscriber)
		}
	}
	broadcaster.Lock.RUnlock()
	for _, subscriber := range subscribers {
		subscriber.sendMicrophoneDemand(revision, payload)
	}
}

func (manager *WebRTCManager) forwardMicrophoneStatus(
	broadcaster *DeviceBroadcaster,
	agent *sagent.Agent,
	generation uint64,
) {
	statuses, ok := agent.MicrophoneStatus()
	if !ok {
		return
	}
	for {
		var raw []byte
		select {
		case <-agent.Done():
			return
		case next, open := <-statuses:
			if !open {
				return
			}
			raw = next
		}
		var status struct {
			V        int    `json:"v"`
			Type     string `json:"type"`
			State    string `json:"state"`
			StreamID uint32 `json:"streamID"`
		}
		if json.Unmarshal(raw, &status) != nil || status.V != 1 || status.Type != "microphoneState" {
			continue
		}
		broadcaster.AgentLock.Lock()
		if broadcaster.Agent != agent || broadcaster.AgentGeneration != generation {
			broadcaster.AgentLock.Unlock()
			return
		}
		broadcaster.MicrophoneMu.Lock()
		session := broadcaster.Microphone
		if session.hasOwner && session.agentGeneration == generation {
			broadcaster.Lock.RLock()
			subscriber := broadcaster.Subscribers[session.ownerReceipt]
			broadcaster.Lock.RUnlock()
			if subscriber != nil && subscriber.identity != session.ownerIdentity {
				subscriber = nil
			}
			if status.State == "active" && status.StreamID == session.streamID {
				broadcaster.Microphone.active = true
				if subscriber != nil {
					subscriber.sendMicrophoneStatus(
						microphoneStatePayload("active", session.streamID, session.demandGeneration),
					)
				}
			} else if (status.State == "busy" || status.State == "unavailable" || status.State == "ready") &&
				status.StreamID == session.streamID {
				// Transport-wide streamID=0 statuses deliberately do not clear an
				// owner here: status and demand have independent delivery queues, so
				// a delayed old disconnect could otherwise stop a newer session.
				// The ordered/revisioned demand-idle path owns transport teardown.
				manager.clearMicrophoneLocked(broadcaster)
				if subscriber != nil {
					subscriber.sendMicrophoneStatus(
						microphoneStatePayload(status.State, session.streamID, session.demandGeneration),
					)
				}
			}
		}
		broadcaster.MicrophoneMu.Unlock()
		broadcaster.AgentLock.Unlock()
	}
}

func (manager *WebRTCManager) receiveAutomaticMicrophoneTracks(
	deviceIdentifier string,
	receiptNo uint32,
	subscriber *Subscriber,
) {
	for {
		select {
		case <-subscriber.remoteAudioStop:
			return
		case track := <-subscriber.remoteAudioTracks:
			if track == nil {
				return
			}
			manager.receiveAutomaticMicrophoneTrack(deviceIdentifier, receiptNo, subscriber, track)
		}
	}
}

func (manager *WebRTCManager) receiveAutomaticMicrophoneTrack(
	deviceIdentifier string,
	receiptNo uint32,
	subscriber *Subscriber,
	track *webrtc.TrackRemote,
) {
	codec := track.Codec()
	channels := int(codec.Channels)
	if channels == 0 {
		channels = 2
	}
	if codec.ClockRate != 48000 || (channels != 1 && channels != 2) {
		log.Printf("microphone_remote_track_rejected receipt=%d reason=%q", receiptNo, "unsupported_opus_format")
		drainRemoteAudioTrack(track)
		return
	}
	decoder, err := newMicrophoneOpusDecoder(channels)
	if err != nil {
		log.Printf("microphone_remote_track_rejected receipt=%d reason=%q", receiptNo, "decoder_unavailable")
		drainRemoteAudioTrack(track)
		return
	}
	defer func() {
		if decoder != nil {
			decoder.Close()
		}
	}()
	subscriber.setRemoteAudioReady(true)
	defer func() {
		subscriber.setRemoteAudioReady(false)
		manager.releaseAutomaticMicrophoneForSubscriber(
			deviceIdentifier,
			receiptNo,
			subscriber.identity,
			"remote_track_ended",
		)
	}()
	manager.activatePendingAutomaticMicrophone(deviceIdentifier, receiptNo, subscriber)

	var lastRTPSequence uint16
	hasRTPSequence := false
	var sessionToken microphoneSessionToken
	pcmBuffer := make([]byte, 0, microphonePCMBytesPerPacket*2)
	for {
		packet, _, readErr := track.ReadRTP()
		if readErr != nil {
			return
		}
		if hasRTPSequence {
			distance := packet.SequenceNumber - lastRTPSequence
			if !rtpSequenceAfter(packet.SequenceNumber, lastRTPSequence) {
				log.Printf("microphone_rtp_rejected receipt=%d reason=%q", receiptNo, "sequence_not_after")
				continue
			}
			if distance > 1 {
				// Gaps are non-terminal. Discard only an incomplete 20 ms PCM
				// chunk so samples on opposite sides of the loss are not joined.
				pcmBuffer = pcmBuffer[:0]
			}
		}
		hasRTPSequence = true
		lastRTPSequence = packet.SequenceNumber
		if len(packet.Payload) == 0 {
			continue
		}
		if decoder == nil {
			decoder, err = newMicrophoneOpusDecoder(channels)
			if err != nil {
				log.Printf("microphone_rtp_dropped receipt=%d reason=%q", receiptNo, "decoder_rebuild_failed")
				continue
			}
		}
		pcm, decodeErr := decoder.Decode(packet.Payload)
		if decodeErr != nil {
			// A damaged or unsupported RTP payload is packet-scoped. Reset the
			// stateful converter and drop only this packet; the existing session
			// remains eligible for the following packet. If valid PCM does not
			// resume, the normal session watchdog performs the eventual STOP.
			log.Printf("microphone_rtp_dropped receipt=%d reason=%q", receiptNo, "opus_decode_failed")
			decoder.Close()
			decoder = nil
			pcmBuffer = pcmBuffer[:0]
			continue
		}
		if len(pcm) == 0 {
			continue
		}
		token, active := manager.automaticMicrophoneSessionToken(
			deviceIdentifier,
			receiptNo,
			subscriber.identity,
		)
		if !active {
			pcmBuffer = pcmBuffer[:0]
			sessionToken = microphoneSessionToken{}
			continue
		}
		if token != sessionToken {
			pcmBuffer = pcmBuffer[:0]
			sessionToken = token
		}
		pcmBuffer = append(pcmBuffer, pcm...)
		for len(pcmBuffer) >= microphonePCMBytesPerPacket {
			chunk := append([]byte(nil), pcmBuffer[:microphonePCMBytesPerPacket]...)
			pcmBuffer = pcmBuffer[microphonePCMBytesPerPacket:]
			if err := manager.forwardAutomaticMicrophonePCM(
				deviceIdentifier,
				receiptNo,
				subscriber.identity,
				sessionToken,
				chunk,
			); err != nil {
				log.Printf("microphone_rtp_rejected receipt=%d reason=%q", receiptNo, err)
				pcmBuffer = pcmBuffer[:0]
				sessionToken = microphoneSessionToken{}
				break
			}
		}
	}
}

func drainRemoteAudioTrack(track *webrtc.TrackRemote) {
	for {
		if _, _, err := track.ReadRTP(); err != nil {
			return
		}
	}
}

func (manager *WebRTCManager) activatePendingAutomaticMicrophone(
	deviceIdentifier string,
	receiptNo uint32,
	subscriber *Subscriber,
) {
	broadcaster, currentSubscriber, agent, agentGeneration, err := manager.microphoneTarget(
		deviceIdentifier,
		receiptNo,
		subscriber.identity,
	)
	if err != nil || currentSubscriber != subscriber {
		return
	}
	broadcaster.MicrophoneMu.Lock()
	defer broadcaster.MicrophoneMu.Unlock()
	pending, exists := broadcaster.Demand.pending[receiptNo]
	if !exists || pending.identity != subscriber.identity || pending.agentGeneration != agentGeneration {
		return
	}
	if err := manager.activateAutomaticMicrophoneLocked(
		deviceIdentifier,
		broadcaster,
		subscriber,
		agent,
		receiptNo,
		pending,
	); err != nil {
		log.Printf("microphone_accept_rejected receipt=%d reason=%q", receiptNo, err)
	}
}

func (manager *WebRTCManager) automaticMicrophoneSessionToken(
	deviceIdentifier string,
	receiptNo uint32,
	identity subscriberIdentity,
) (microphoneSessionToken, bool) {
	manager.RLock()
	broadcaster := manager.broadcasters[deviceIdentifier]
	manager.RUnlock()
	if broadcaster == nil {
		return microphoneSessionToken{}, false
	}
	broadcaster.Lock.RLock()
	subscriber := broadcaster.Subscribers[receiptNo]
	currentSubscriber := subscriber != nil && subscriber.identity == identity
	broadcaster.Lock.RUnlock()
	if !currentSubscriber {
		return microphoneSessionToken{}, false
	}
	broadcaster.MicrophoneMu.Lock()
	defer broadcaster.MicrophoneMu.Unlock()
	session := broadcaster.Microphone
	if !broadcaster.Demand.active || !session.hasOwner || !session.active || !session.automatic ||
		session.ownerReceipt != receiptNo || session.ownerIdentity != identity ||
		session.demandGeneration != broadcaster.Demand.generation ||
		session.agentGeneration != broadcaster.Demand.agentGeneration {
		return microphoneSessionToken{}, false
	}
	return microphoneSessionToken{
		sessionGeneration: session.generation,
		agentGeneration:   session.agentGeneration,
		ownerIdentity:     session.ownerIdentity,
	}, true
}

func (manager *WebRTCManager) forwardAutomaticMicrophonePCM(
	deviceIdentifier string,
	receiptNo uint32,
	identity subscriberIdentity,
	sessionToken microphoneSessionToken,
	pcm []byte,
) error {
	if len(pcm) != microphonePCMBytesPerPacket {
		return fmt.Errorf("invalid_pcm_size")
	}
	broadcaster, subscriber, agent, agentGeneration, err := manager.microphoneTarget(
		deviceIdentifier,
		receiptNo,
		identity,
	)
	if err != nil {
		return err
	}
	broadcaster.MicrophoneMu.Lock()
	defer broadcaster.MicrophoneMu.Unlock()
	if !microphoneSubscriberCurrent(broadcaster, receiptNo, identity, subscriber) {
		return fmt.Errorf("subscriber_disconnected")
	}
	session := &broadcaster.Microphone
	if !broadcaster.Demand.active {
		return fmt.Errorf("demand_idle")
	}
	if !session.hasOwner || !session.active || !session.automatic {
		return fmt.Errorf("auto_session_inactive")
	}
	if session.ownerReceipt != receiptNo || session.ownerIdentity != identity {
		return fmt.Errorf("owner_mismatch")
	}
	if session.generation != sessionToken.sessionGeneration ||
		session.ownerIdentity != sessionToken.ownerIdentity {
		return fmt.Errorf("session_generation_mismatch")
	}
	if session.agentGeneration != agentGeneration || session.agentGeneration != sessionToken.agentGeneration ||
		broadcaster.Demand.agentGeneration != agentGeneration {
		return fmt.Errorf("agent_generation_mismatch")
	}
	if session.demandGeneration != broadcaster.Demand.generation {
		return fmt.Errorf("demand_generation_mismatch")
	}
	if !manager.acceptMicrophoneRateLocked(session, time.Now()) {
		return fmt.Errorf("data_rate_exceeded")
	}
	sequence := session.lastSequence + 1
	if err := agent.SendMicrophonePacket(microphoneDataPacket(session.streamID, sequence, pcm)); err != nil {
		manager.stopAndClearMicrophoneLocked(broadcaster, agent, "unavailable")
		return fmt.Errorf("forward_data_failed")
	}
	session.lastSequence = sequence
	manager.armMicrophoneWatchdogLocked(deviceIdentifier, broadcaster)
	return nil
}

func (manager *WebRTCManager) releaseAutomaticMicrophoneForSubscriber(
	deviceIdentifier string,
	receiptNo uint32,
	identity subscriberIdentity,
	reason string,
) {
	agent, broadcaster, agentGeneration, exists := manager.currentAgentEpoch(deviceIdentifier)
	if !exists || broadcaster == nil {
		return
	}
	broadcaster.MicrophoneMu.Lock()
	defer broadcaster.MicrophoneMu.Unlock()
	if pending, ok := broadcaster.Demand.pending[receiptNo]; ok && pending.identity == identity {
		delete(broadcaster.Demand.pending, receiptNo)
	}
	session := broadcaster.Microphone
	if !session.hasOwner || session.ownerReceipt != receiptNo || session.ownerIdentity != identity ||
		session.agentGeneration != agentGeneration || !session.automatic {
		return
	}
	manager.stopAndClearMicrophoneLocked(broadcaster, agent, "ready")
	log.Printf("microphone_session_stopped receipt=%d reason=%q", receiptNo, reason)
}
