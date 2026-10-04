package webservice

import (
	"encoding/json"
	"log"
	"sync"
	"sync/atomic"
	"time"

	sagent "webscreen/streamAgent"

	"github.com/pion/webrtc/v4"
)

const (
	maxPendingFrameFeedback = 128
	diagnosticsInterval     = 30 * time.Second
	iceDiagnosticsInterval  = 5 * time.Second
)

type pointerSequenceState struct {
	active       bool
	lastSequence uint64
}

type subscriberTelemetry struct {
	controlMu sync.Mutex
	pointers  map[byte]pointerSequenceState

	pendingMu    sync.Mutex
	pendingFrame map[uint64]pendingFrameFeedback
	lastFramePTS uint64
	hasLastFrame bool

	received          atomic.Uint64
	written           atomic.Uint64
	droppedStale      atomic.Uint64
	droppedNoDown     atomic.Uint64
	invalid           atomic.Uint64
	driverErrors      atomic.Uint64
	feedbackSendError atomic.Uint64
	frameFeedbackSent atomic.Uint64
	pendingEvicted    atomic.Uint64

	stopOnce sync.Once
	stopCh   chan struct{}
}

func newSubscriberTelemetry() *subscriberTelemetry {
	return &subscriberTelemetry{
		pointers:     make(map[byte]pointerSequenceState),
		pendingFrame: make(map[uint64]pendingFrameFeedback),
		stopCh:       make(chan struct{}),
	}
}

func (telemetry *subscriberTelemetry) stop() {
	telemetry.stopOnce.Do(func() {
		close(telemetry.stopCh)
	})
}

func (telemetry *subscriberTelemetry) validateTouchSequence(
	envelope controlEnvelope,
) controlAckStatus {
	if envelope.LegacyEventType != 0x02 || len(envelope.LegacyPayload) != 10 {
		return controlAckWritten
	}

	action := envelope.LegacyPayload[1]
	pointerID := envelope.LegacyPayload[2]
	state := telemetry.pointers[pointerID]

	switch action {
	case 0: // Android MotionEvent ACTION_DOWN
		if envelope.Sequence <= state.lastSequence {
			return controlAckDroppedStale
		}
		state.active = true
		state.lastSequence = envelope.Sequence
		telemetry.pointers[pointerID] = state
		return controlAckWritten
	case 1, 3: // ACTION_UP or ACTION_CANCEL
		if !state.active {
			return controlAckDroppedNoDown
		}
		if envelope.Sequence <= state.lastSequence {
			return controlAckDroppedStale
		}
		state.active = false
		state.lastSequence = envelope.Sequence
		telemetry.pointers[pointerID] = state
		return controlAckWritten
	case 2: // ACTION_MOVE
		if !state.active {
			return controlAckDroppedNoDown
		}
		if envelope.Sequence <= state.lastSequence {
			return controlAckDroppedStale
		}
		state.lastSequence = envelope.Sequence
		telemetry.pointers[pointerID] = state
		return controlAckWritten
	default:
		return controlAckInvalid
	}
}

func (telemetry *subscriberTelemetry) handleTouchWriteFailure(
	envelope controlEnvelope,
) {
	if envelope.LegacyEventType != 0x02 || len(envelope.LegacyPayload) != 10 {
		return
	}
	action := envelope.LegacyPayload[1]
	if action != 0 && action != 1 && action != 3 {
		return
	}
	pointerID := envelope.LegacyPayload[2]
	state := telemetry.pointers[pointerID]
	state.active = false
	telemetry.pointers[pointerID] = state
}

func (telemetry *subscriberTelemetry) noteStatus(status controlAckStatus) {
	switch status {
	case controlAckWritten:
		telemetry.written.Add(1)
	case controlAckDroppedStale:
		telemetry.droppedStale.Add(1)
	case controlAckDroppedNoDown:
		telemetry.droppedNoDown.Add(1)
	case controlAckInvalid, controlAckUnsupported:
		telemetry.invalid.Add(1)
	case controlAckDriverError:
		telemetry.driverErrors.Add(1)
	}
}

func (telemetry *subscriberTelemetry) addPendingFrame(pending pendingFrameFeedback) {
	telemetry.pendingMu.Lock()
	defer telemetry.pendingMu.Unlock()
	pending.BaselineFramePTS = telemetry.lastFramePTS
	pending.HasBaselineFrame = telemetry.hasLastFrame

	if len(telemetry.pendingFrame) >= maxPendingFrameFeedback {
		var oldestSequence uint64
		for sequence := range telemetry.pendingFrame {
			if oldestSequence == 0 || sequence < oldestSequence {
				oldestSequence = sequence
			}
		}
		if oldestSequence != 0 {
			delete(telemetry.pendingFrame, oldestSequence)
			telemetry.pendingEvicted.Add(1)
		}
	}
	telemetry.pendingFrame[pending.Envelope.Sequence] = pending
}

func (telemetry *subscriberTelemetry) takePendingForFrame(
	frame videoFrameObservation,
) []pendingFrameFeedback {
	telemetry.pendingMu.Lock()
	defer telemetry.pendingMu.Unlock()
	telemetry.lastFramePTS = frame.PTS
	telemetry.hasLastFrame = true

	if len(telemetry.pendingFrame) == 0 {
		return nil
	}
	ready := make([]pendingFrameFeedback, 0, len(telemetry.pendingFrame))
	for sequence, pending := range telemetry.pendingFrame {
		isNewPresentation := !pending.HasBaselineFrame ||
			pending.BaselineFramePTS != frame.PTS
		if pending.DriverWriteAtUs <= frame.ReceivedAtUs &&
			isNewPresentation {
			ready = append(ready, pending)
			delete(telemetry.pendingFrame, sequence)
		}
	}
	return ready
}

func (telemetry *subscriberTelemetry) pendingCount() int {
	telemetry.pendingMu.Lock()
	defer telemetry.pendingMu.Unlock()
	return len(telemetry.pendingFrame)
}

func (telemetry *subscriberTelemetry) removePendingFrame(sequence uint64) {
	telemetry.pendingMu.Lock()
	defer telemetry.pendingMu.Unlock()
	delete(telemetry.pendingFrame, sequence)
}

type controlDiagnostics struct {
	Event             string  `json:"event"`
	TimestampUnixMs   int64   `json:"timestampUnixMs"`
	Received          uint64  `json:"received"`
	Written           uint64  `json:"written"`
	DroppedStale      uint64  `json:"droppedStale"`
	DroppedNoDown     uint64  `json:"droppedNoDown"`
	Invalid           uint64  `json:"invalid"`
	DriverErrors      uint64  `json:"driverErrors"`
	FeedbackErrors    uint64  `json:"feedbackErrors"`
	FrameFeedbackSent uint64  `json:"frameFeedbackSent"`
	PendingFrame      int     `json:"pendingFrame"`
	PendingEvicted    uint64  `json:"pendingEvicted"`
	Subscribers       int     `json:"subscribers"`
	AgentGeneration   uint64  `json:"agentGeneration"`
	StreamProfile     string  `json:"streamProfile,omitempty"`
	Route             string  `json:"route,omitempty"`
	LocalType         string  `json:"localCandidateType,omitempty"`
	RemoteType        string  `json:"remoteCandidateType,omitempty"`
	Protocol          string  `json:"protocol,omitempty"`
	RelayProtocol     string  `json:"relayProtocol,omitempty"`
	RTTMilliseconds   float64 `json:"rttMs,omitempty"`
}

type iceRouteDiagnostics struct {
	Event           string  `json:"event"`
	Route           string  `json:"route"`
	LocalType       string  `json:"localCandidateType"`
	RemoteType      string  `json:"remoteCandidateType"`
	Protocol        string  `json:"protocol"`
	RelayProtocol   string  `json:"relayProtocol"`
	RTTMilliseconds float64 `json:"rttMs"`
}

func (sub *Subscriber) sendFeedback(payload []byte) error {
	sub.feedbackMu.Lock()
	defer sub.feedbackMu.Unlock()
	return sub.sendFeedbackLocked(payload)
}

func (sub *Subscriber) sendFeedbackLocked(payload []byte) error {
	sub.channelMu.RLock()
	channel := sub.dataChannelUnordered
	sub.channelMu.RUnlock()
	if channel == nil ||
		channel.ReadyState() != webrtc.DataChannelStateOpen {
		return errFeedbackChannelUnavailable
	}
	return channel.Send(payload)
}

func (sub *Subscriber) sendJSONDiagnostics(value any) {
	body, err := json.Marshal(value)
	if err != nil {
		log.Printf("diagnostics_marshal_error receipt=%d error=%q", sub.receiptNo, err)
		return
	}
	packet := make([]byte, 1+len(body))
	packet[0] = diagnosticsFeedbackType
	copy(packet[1:], body)
	if err := sub.sendFeedback(packet); err != nil {
		sub.telemetry.feedbackSendError.Add(1)
	}
}

func (sub *Subscriber) startDiagnostics(
	broadcaster *DeviceBroadcaster,
) {
	go func() {
		controlTicker := time.NewTicker(diagnosticsInterval)
		defer controlTicker.Stop()
		iceTicker := time.NewTicker(iceDiagnosticsInterval)
		defer iceTicker.Stop()

		var lastICEFingerprint string
		var lastICE iceRouteDiagnostics
		var haveICE bool
		sendControl := func() {
			snapshot := controlDiagnostics{
				Event:             "control_diagnostics",
				TimestampUnixMs:   time.Now().UnixMilli(),
				Received:          sub.telemetry.received.Load(),
				Written:           sub.telemetry.written.Load(),
				DroppedStale:      sub.telemetry.droppedStale.Load(),
				DroppedNoDown:     sub.telemetry.droppedNoDown.Load(),
				Invalid:           sub.telemetry.invalid.Load(),
				DriverErrors:      sub.telemetry.driverErrors.Load(),
				FeedbackErrors:    sub.telemetry.feedbackSendError.Load(),
				FrameFeedbackSent: sub.telemetry.frameFeedbackSent.Load(),
				PendingFrame:      sub.telemetry.pendingCount(),
				PendingEvicted:    sub.telemetry.pendingEvicted.Load(),
			}
			broadcaster.Lock.RLock()
			snapshot.Subscribers = len(broadcaster.Subscribers)
			broadcaster.Lock.RUnlock()
			broadcaster.AgentLock.Lock()
			snapshot.AgentGeneration = broadcaster.AgentGeneration
			snapshot.StreamProfile = broadcaster.AgentConfig.StreamProfile
			broadcaster.AgentLock.Unlock()
			if haveICE {
				snapshot.Route = lastICE.Route
				snapshot.LocalType = lastICE.LocalType
				snapshot.RemoteType = lastICE.RemoteType
				snapshot.Protocol = lastICE.Protocol
				snapshot.RelayProtocol = lastICE.RelayProtocol
				snapshot.RTTMilliseconds = lastICE.RTTMilliseconds
			}
			body, _ := json.Marshal(snapshot)
			log.Printf("control_diagnostics receipt=%d payload=%s", sub.receiptNo, body)
			sub.sendJSONDiagnostics(snapshot)
		}

		for {
			select {
			case <-sub.telemetry.stopCh:
				sendControl()
				return
			case <-iceTicker.C:
				ice, fingerprint, ok := selectedICEDiagnostics(sub.PeerConnection)
				if !ok {
					continue
				}
				lastICE = ice
				haveICE = true
				if fingerprint != lastICEFingerprint {
					lastICEFingerprint = fingerprint
					body, _ := json.Marshal(ice)
					log.Printf("ice_route receipt=%d payload=%s", sub.receiptNo, body)
					sub.sendJSONDiagnostics(ice)
				}
			case <-controlTicker.C:
				sendControl()
			}
		}
	}()
}

func selectedICEDiagnostics(
	peerConnection *webrtc.PeerConnection,
) (iceRouteDiagnostics, string, bool) {
	if peerConnection == nil ||
		peerConnection.SCTP() == nil ||
		peerConnection.SCTP().Transport() == nil ||
		peerConnection.SCTP().Transport().ICETransport() == nil {
		return iceRouteDiagnostics{}, "", false
	}
	iceTransport := peerConnection.SCTP().Transport().ICETransport()
	pair, err := iceTransport.GetSelectedCandidatePair()
	if err != nil || pair == nil || pair.Local == nil || pair.Remote == nil {
		return iceRouteDiagnostics{}, "", false
	}

	stats, statsAvailable := iceTransport.GetSelectedCandidatePairStats()
	rttMilliseconds := float64(0)
	if statsAvailable {
		rttMilliseconds = stats.CurrentRoundTripTime * 1_000
	}

	relayProtocol := ""
	report := peerConnection.GetStats()
	for _, item := range report {
		candidate, ok := item.(webrtc.ICECandidateStats)
		if !ok {
			continue
		}
		if candidate.Type != webrtc.StatsTypeLocalCandidate {
			continue
		}
		if candidate.IP == pair.Local.Address &&
			candidate.Port == int32(pair.Local.Port) {
			relayProtocol = candidate.RelayProtocol
			break
		}
	}

	localType := pair.Local.Typ.String()
	remoteType := pair.Remote.Typ.String()
	route := "direct"
	if pair.Local.Typ == webrtc.ICECandidateTypeRelay ||
		pair.Remote.Typ == webrtc.ICECandidateTypeRelay {
		route = "relay"
	}
	protocol := pair.Local.Protocol.String()
	diagnostics := iceRouteDiagnostics{
		Event:           "ice_route",
		Route:           route,
		LocalType:       localType,
		RemoteType:      remoteType,
		Protocol:        protocol,
		RelayProtocol:   relayProtocol,
		RTTMilliseconds: rttMilliseconds,
	}
	fingerprint := route + "|" + localType + "|" + remoteType + "|" +
		protocol + "|" + relayProtocol
	return diagnostics, fingerprint, true
}

func (sub *Subscriber) handleVideoFrame(frame sagent.FrameObservation) {
	observation := videoFrameObservation{
		ReceivedAtUs: frame.ReceivedAtUnixMicros,
		ObservedAtUs: frame.ObservedAtUnixMicros,
		PTS:          frame.PTS,
	}
	for _, pending := range sub.telemetry.takePendingForFrame(observation) {
		if err := sub.sendFeedback(encodeFrameFeedback(pending, observation)); err != nil {
			sub.telemetry.feedbackSendError.Add(1)
			continue
		}
		sub.telemetry.frameFeedbackSent.Add(1)
	}
}
