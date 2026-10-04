package webservice

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	sagent "webscreen/streamAgent"

	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	pionSDP "github.com/pion/sdp/v3"
	"github.com/pion/webrtc/v4"
)

const (
	UDP_PORT_START = 51200
	UDP_PORT_END   = 51299
)

const (
	MIN_TURN_CREDENTIAL_TTL_SECONDS = 300
	MAX_TURN_CREDENTIAL_TTL_SECONDS = 3600
	MAX_TURN_URLS                   = 8
)

var turnURLPattern = regexp.MustCompile(`(?i)^(turn|turns):(\[[0-9a-f:.]+\]|[a-z0-9.-]+)(?::([0-9]{1,5}))?(?:\?transport=(udp|tcp))?$`)

var errFeedbackChannelUnavailable = errors.New("feedback data channel is unavailable")

const (
	PAYLOAD_TYPE_AV1_PROFILE_MAIN_5_1            = 100 // 2560x1440 @ 60fps
	PAYLOAD_TYPE_H265_PROFILE_MAIN_TIER_MAIN_5_1 = 102 // 2560x1440 @ 60fps 40Mbps Max
	PAYLOAD_TYPE_H265_PROFILE_MAIN_TIER_MAIN_4_1 = 103 // 1920x1080 @ 60fps 20Mbps Max
	PAYLOAD_TYPE_H264_PROFILE_HIGH_5_1           = 104 // 2560x1440 @ 60fps
	PAYLOAD_TYPE_H264_PROFILE_HIGH_5_1_0C        = 105 // 2560x1440 @ 60fps for iphone safari
	PAYLOAD_TYPE_H264_PROFILE_BASELINE_3_1       = 106 // 720p @ 30fps
	PAYLOAD_TYPE_H264_PROFILE_BASELINE_3_1_0C    = 107 // 720p @ 30fps for iphone safari
)

const (
	MAX_CLIENTS_PER_DEVICE = 4
)

type Subscriber struct {
	PeerConnection       *webrtc.PeerConnection
	dataChannelUnordered *webrtc.DataChannel
	dataChannelOrdered   *webrtc.DataChannel
	dataChannelTransient *webrtc.DataChannel
	microphoneControl    *webrtc.DataChannel
	microphoneData       *webrtc.DataChannel
	// dataChannelReady     bool
	rtpSenderVideo *webrtc.RTPSender
	rtpSenderAudio *webrtc.RTPSender

	// Callback for incoming messages
	onMessageCallback              func([]byte) error
	onMicrophoneControl            func([]byte) error
	onMicrophoneText               func([]byte) error
	onMicrophoneData               func([]byte) error
	onMicrophoneClose              func()
	onMicrophoneDataClose          func()
	latestMicrophoneStatus         []byte
	latestMicrophoneDemand         []byte
	latestMicrophoneDemandRevision uint64
	hasLatestMicrophoneDemand      bool
	callbackMu                     sync.RWMutex
	channelMu                      sync.RWMutex
	microphoneMessageMu            sync.Mutex
	remoteAudioMu                  sync.RWMutex
	remoteAudioReady               bool
	remoteAudioTracks              chan *webrtc.TrackRemote
	remoteAudioStop                chan struct{}
	remoteAudioStopOnce            sync.Once
	remoteAudioReceiveOnce         sync.Once

	receiptNo       uint32
	identity        subscriberIdentity
	deviceID        string
	requestedConfig sagent.AgentConfig
	telemetry       *subscriberTelemetry
	feedbackMu      sync.Mutex
	frameObserverID string
}

type DeviceBroadcaster struct {
	PayloadType   uint8
	VideoMimeType string
	VideoTrack    *webrtc.TrackLocalStaticRTP
	AudioTrack    *webrtc.TrackLocalStaticRTP
	Agent         *sagent.Agent
	Subscribers   map[uint32]*Subscriber
	Lock          sync.RWMutex

	// A broadcaster created by NewSubscriber is provisional until at least one
	// subscriber is committed. PendingSubscriberSetups prevents a failed creator
	// from deleting the shared instance while another setup is still using it.
	pendingSubscriberSetups uint32
	provisional             bool

	AgentLock         sync.Mutex
	AgentConfig       sagent.AgentConfig
	AgentGeneration   uint64
	FinalCodec        webrtc.RTPCodecParameters
	RTPContinuity     *sagent.RTPContinuity
	RecoveryFailures  uint32
	RecoveryNotBefore time.Time
	Prewarmed         bool

	// AgentLock protects the missing-agent recovery job for this capture epoch.
	transportRecoveryScheduled  bool
	transportRecoveryGeneration uint64

	MicrophoneMu sync.Mutex
	Microphone   microphoneSession
	Demand       microphoneDemandState
}

type WebRTCManager struct {
	sync.RWMutex
	broadcasters map[string]*DeviceBroadcaster // deviceIdentifier -> Broadcaster

	currentReceiptNumber map[string]uint32
	turnConfiguration    turnConfiguration

	// adbRecoveryLease is the outermost lock for Android transport setup.
	// Subscriber/agent setup holds a read lease; the narrowly-scoped macOS
	// recovery path takes the write lease before restarting the shared adb
	// server. It must always be acquired before the manager or broadcaster
	// locks.
	adbRecoveryLease sync.RWMutex
	adbRecoveryMu    sync.Mutex
	adbRecovery      adbRecoveryState

	transportMu            sync.Mutex
	transportStates        map[string]*deviceTransportState
	transportInstance      string
	transportInspector     func(context.Context, string) (transportSnapshot, error)
	transportSwitchStarter func(string, string, string, transportSelection)
}

func NewWebRTCManager() *WebRTCManager {
	turnConfig, err := loadTurnConfiguration()
	if err != nil {
		log.Panicf("Invalid WebRTC TURN configuration: %v", err)
	}
	wm := &WebRTCManager{
		broadcasters:         make(map[string]*DeviceBroadcaster),
		currentReceiptNumber: make(map[string]uint32),
		turnConfiguration:    turnConfig,
		adbRecovery: adbRecoveryState{
			managedSerials: make(map[string]struct{}),
			observations:   make(map[string]adbRecoveryObservation),
		},
	}
	// go func() {
	// 	for {
	// 		time.Sleep(30 * time.Second)
	// 		wm.RLock()
	// 		// log.Printf("WebRTCManager status: %d broadcasters\n", len(wm.broadcasters))
	// 		for deviceID, broadcaster := range wm.broadcasters {
	// 			broadcaster.Lock.RLock()
	// 			log.Printf("Device %s has %d subscribers\n", deviceID, len(broadcaster.Subscribers))
	// 			for receiptNo, sub := range broadcaster.Subscribers {
	// 				log.Printf("Device %s, ReceiptNo %d, Subscriber state: %s\n", deviceID, receiptNo, sub.PeerConnection.ConnectionState())
	// 			}
	// 			broadcaster.Lock.RUnlock()
	// 		}
	// 		wm.RUnlock()
	// 	}
	// }()
	return wm
}

func (manager *WebRTCManager) NewSubscriber(deviceIdentifier string, clientSDP string, AgentConfig sagent.AgentConfig) (string, uint32, error) {
	manager.adbRecoveryLease.RLock()
	defer manager.adbRecoveryLease.RUnlock()

	offer := webrtc.SessionDescription{
		Type: webrtc.SDPTypeOffer,
		SDP:  clientSDP,
	}
	// log.Println("Handling SDP Offer", sdp)
	videoMimeType, audioMimeType := getMimeTypeFromConfig(AgentConfig)
	// Create MediaEngine
	mimeTypes := []string{videoMimeType, audioMimeType}
	m := createMediaEngine(mimeTypes)
	if err := m.RegisterHeaderExtension(
		webrtc.RTPHeaderExtensionCapability{URI: pionSDP.TransportCCURI},
		webrtc.RTPCodecTypeVideo,
	); err != nil {
		log.Printf("RegisterHeaderExtension failed: %v", err)
		return "", 0, err
	}
	if err := m.RegisterHeaderExtension(
		webrtc.RTPHeaderExtensionCapability{URI: playoutDelayExtensionURI},
		webrtc.RTPCodecTypeVideo,
	); err != nil {
		log.Printf("Register playout-delay extension failed: %v", err)
		return "", 0, err
	}
	i := &interceptor.Registry{}
	if err := webrtc.RegisterDefaultInterceptors(m, i); err != nil {
		log.Printf("RegisterDefaultInterceptors failed: %v", err)
		return "", 0, err
	}
	i.Add(playoutDelayInterceptorFactory{})
	settingEngine := webrtc.SettingEngine{}
	err := settingEngine.SetEphemeralUDPPortRange(UDP_PORT_START, UDP_PORT_END)
	if err != nil {
		return "", 0, err
	}
	api := webrtc.NewAPI(webrtc.WithMediaEngine(m), webrtc.WithInterceptorRegistry(i), webrtc.WithSettingEngine(settingEngine))
	iceServers, err := manager.createICEServers()
	if err != nil {
		log.Printf("Failed to create TURN credentials: %v", err)
		return "", 0, err
	}
	config := webrtc.Configuration{
		ICEServers: iceServers,
	}
	// Create PeerConnection
	peerConnection, err := api.NewPeerConnection(config)
	if err != nil {
		log.Println("Create PeerConnection failed:", err)
		return "", 0, err
	}
	remoteAudioTracks := make(chan *webrtc.TrackRemote, 1)
	if AgentConfig.DeviceType == sagent.DEVICE_TYPE_IPHONE_USB {
		peerConnection.OnTrack(func(track *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
			if track.Kind() != webrtc.RTPCodecTypeAudio ||
				!strings.EqualFold(track.Codec().MimeType, webrtc.MimeTypeOpus) {
				log.Printf(
					"microphone_remote_track_rejected reason=%q kind=%q codec=%q",
					"unsupported_track",
					track.Kind().String(),
					track.Codec().MimeType,
				)
				go drainRemoteAudioTrack(track)
				return
			}
			select {
			case remoteAudioTracks <- track:
			default:
				log.Printf("microphone_remote_track_rejected reason=%q", "duplicate_track")
				go drainRemoteAudioTrack(track)
			}
		})
	}
	var setupBroadcaster *DeviceBroadcaster
	setupTracked := false
	subscriberCommitted := false
	defer func() {
		if !subscriberCommitted {
			_ = peerConnection.Close()
		}
		if setupTracked {
			manager.finishSubscriberSetup(
				deviceIdentifier,
				setupBroadcaster,
				subscriberCommitted,
			)
		}
	}()

	// 1. Get or Create Broadcaster (and its tracks)
	manager.Lock()
	broadcaster, exists := manager.broadcasters[deviceIdentifier]
	if !exists {
		videoTrack, audioTrack := createAVTrack(videoMimeType, audioMimeType, AgentConfig.AVSync)
		if videoTrack == nil && audioTrack == nil {
			manager.Unlock()
			log.Printf("Failed to create both video and audio tracks")
			return "", 0, fmt.Errorf("failed to create media tracks")
		}

		broadcaster = &DeviceBroadcaster{
			VideoMimeType:           videoMimeType,
			VideoTrack:              videoTrack,
			AudioTrack:              audioTrack,
			Subscribers:             make(map[uint32]*Subscriber),
			RTPContinuity:           sagent.NewRTPContinuity(),
			pendingSubscriberSetups: 1,
			provisional:             true,
		}
		manager.broadcasters[deviceIdentifier] = broadcaster
	} else if broadcaster.VideoMimeType != videoMimeType {
		manager.Unlock()
		return "", 0, fmt.Errorf(
			"active shared stream uses %s; requested %s",
			broadcaster.VideoMimeType,
			videoMimeType,
		)
	} else {
		broadcaster.Lock.Lock()
		broadcaster.pendingSubscriberSetups++
		broadcaster.Lock.Unlock()
	}
	setupBroadcaster = broadcaster
	setupTracked = true
	manager.Unlock()

	// 2. Add SHARED tracks to PeerConnection
	rtpSenderVideo, err := peerConnection.AddTrack(broadcaster.VideoTrack)
	if err != nil {
		log.Printf("Failed to add video track: %v", err)
		return "", 0, err
	}
	rtpSenderAudio, err := peerConnection.AddTrack(broadcaster.AudioTrack)
	if err != nil {
		log.Printf("Failed to add audio track: %v", err)
		return "", 0, err
	}

	// Set Remote Description (Offer from browser)
	if err := peerConnection.SetRemoteDescription(offer); err != nil {
		log.Println("set Remote Description failed:", err)
		return "", 0, err
	}

	// Create Answer
	answer, err := peerConnection.CreateAnswer(nil)
	if err != nil {
		log.Println("Create Answer failed:", err)
		return "", 0, err
	}

	// 设置 Local Description 并等待 ICE 收集完成
	gatherComplete := webrtc.GatheringCompletePromise(peerConnection)

	if err := peerConnection.SetLocalDescription(answer); err != nil {
		log.Println("Set Local Description failed:", err)
		return "", 0, err
	}

	// 阻塞等待 ICE 收集完成 (通常几百毫秒)
	<-gatherComplete
	localDescription := peerConnection.LocalDescription()
	if localDescription == nil {
		return "", 0, fmt.Errorf("local description is unavailable after ICE gathering")
	}
	finalSDP := localDescription.SDP
	subscriberID, err := newSubscriberIdentity()
	if err != nil {
		return "", 0, fmt.Errorf("generate subscriber identity: %w", err)
	}

	manager.Lock()
	currentBroadcaster, stillCurrent := manager.broadcasters[deviceIdentifier]
	if !stillCurrent || currentBroadcaster != broadcaster {
		manager.Unlock()
		return "", 0, fmt.Errorf("broadcaster changed during subscriber setup")
	}
	broadcaster.Lock.Lock()
	receiptNo, available := nextAvailableReceipt(
		broadcaster.Subscribers,
		manager.currentReceiptNumber[deviceIdentifier],
	)
	if !available {
		broadcaster.Lock.Unlock()
		manager.Unlock()
		return "", 0, fmt.Errorf(
			"device already has the maximum of %d subscribers",
			MAX_CLIENTS_PER_DEVICE,
		)
	}
	sub := &Subscriber{
		PeerConnection:    peerConnection,
		rtpSenderVideo:    rtpSenderVideo,
		rtpSenderAudio:    rtpSenderAudio,
		receiptNo:         receiptNo,
		identity:          subscriberID,
		deviceID:          deviceIdentifier,
		requestedConfig:   cloneAgentConfig(AgentConfig),
		telemetry:         newSubscriberTelemetry(),
		frameObserverID:   fmt.Sprintf("subscriber-%d-%x", receiptNo, subscriberID),
		remoteAudioTracks: remoteAudioTracks,
		remoteAudioStop:   make(chan struct{}),
	}
	broadcaster.Subscribers[receiptNo] = sub
	broadcaster.Lock.Unlock()

	manager.currentReceiptNumber[deviceIdentifier] = (receiptNo + 1) % MAX_CLIENTS_PER_DEVICE
	manager.Unlock()

	manager.configureMicrophoneSubscriber(deviceIdentifier, receiptNo, sub, broadcaster)
	sub.setDataChannel()
	manager.setCleanup(peerConnection, deviceIdentifier, receiptNo, subscriberID)
	subscriberCommitted = true

	return finalSDP, receiptNo, nil
}

func (manager *WebRTCManager) finishSubscriberSetup(
	deviceIdentifier string,
	expected *DeviceBroadcaster,
	subscriberCommitted bool,
) {
	manager.Lock()
	broadcaster, exists := manager.broadcasters[deviceIdentifier]
	if !exists || broadcaster != expected {
		manager.Unlock()
		return
	}

	broadcaster.Lock.Lock()
	if broadcaster.pendingSubscriberSetups > 0 {
		broadcaster.pendingSubscriberSetups--
	}
	if subscriberCommitted {
		broadcaster.provisional = false
	}
	remove := broadcaster.provisional &&
		broadcaster.pendingSubscriberSetups == 0 &&
		len(broadcaster.Subscribers) == 0
	if remove {
		delete(manager.broadcasters, deviceIdentifier)
		delete(manager.currentReceiptNumber, deviceIdentifier)
	}
	broadcaster.Lock.Unlock()
	manager.Unlock()

	if remove {
		log.Printf(
			"provisional_broadcaster_removed device=%q reason=%q",
			deviceIdentifier,
			"subscriber_setup_failed",
		)
	}
}

func (manager *WebRTCManager) Start(deviceIdentifier string, receiptNo uint32, agentConfig sagent.AgentConfig) error {
	if agentConfig.DeviceType == sagent.DEVICE_TYPE_ANDROID {
		manager.adbRecoveryLease.RLock()
		defer manager.adbRecoveryLease.RUnlock()
	}

	err := manager.ensureAgent(deviceIdentifier, receiptNo, agentConfig)
	if err != nil {
		log.Printf("Failed to ensure agent for device %s: %v", deviceIdentifier, err)
		return fmt.Errorf("failed to ensure agent: %v", err)
	}
	manager.RLock()
	broadcaster, exists := manager.broadcasters[deviceIdentifier]
	manager.RUnlock()

	if !exists {
		return fmt.Errorf("broadcaster not found")
	}

	broadcaster.Lock.RLock()
	sub := broadcaster.Subscribers[receiptNo]
	broadcaster.Lock.RUnlock()

	if sub == nil {
		return fmt.Errorf("subscriber not found")
	}

	agent, _, agentExists := manager.currentAgent(deviceIdentifier)
	if !agentExists {
		return fmt.Errorf("shared agent not found")
	}
	agent.AddFrameObserver(sub.frameObserverID, sub.handleVideoFrame)

	sub.setDataChannelCallback(func(raw []byte) error {
		return manager.handleControlMessage(
			deviceIdentifier,
			receiptNo,
			raw,
		)
	})
	manager.configureMicrophoneSubscriber(deviceIdentifier, receiptNo, sub, broadcaster)

	// PLI and diagnostics handling resolve the current shared Agent dynamically,
	// so a profile restart does not leave callbacks bound to the stopped Agent.
	go ListenRTPVideo(sub.rtpSenderVideo, func() {
		manager.requestIDR(deviceIdentifier)
	})
	go ListenRTPAudio(sub.rtpSenderAudio)
	sub.startDiagnostics(broadcaster)

	log.Printf(
		"subscriber_started device=%q receipt=%d preview=%t profile=%q",
		deviceIdentifier,
		receiptNo,
		agentConfig.PreviewOnly,
		agentConfig.StreamProfile,
	)

	return nil
}

func (manager *WebRTCManager) configureMicrophoneSubscriber(
	deviceIdentifier string,
	receiptNo uint32,
	sub *Subscriber,
	broadcaster *DeviceBroadcaster,
) {
	sub.setMicrophoneCallbacks(
		func(raw []byte) error {
			return manager.handleMicrophonePacket(deviceIdentifier, receiptNo, sub.identity, microphoneChannelControl, raw)
		},
		func(raw []byte) error {
			return manager.handleMicrophoneControlText(deviceIdentifier, receiptNo, sub.identity, raw)
		},
		func(raw []byte) error {
			return manager.handleMicrophonePacket(deviceIdentifier, receiptNo, sub.identity, microphoneChannelData, raw)
		},
		func() {
			manager.releaseMicrophoneForSubscriber(deviceIdentifier, receiptNo, sub.identity, "data_channel_closed")
		},
		func() {
			manager.releaseLegacyMicrophoneForSubscriber(deviceIdentifier, receiptNo, sub.identity, "legacy_data_channel_closed")
		},
	)
	if sub.requestedConfig.DeviceType != sagent.DEVICE_TYPE_IPHONE_USB ||
		sub.requestedConfig.DeviceID != sagent.IPHONE_USB_LOGICAL_DEVICE_ID {
		return
	}
	broadcaster.MicrophoneMu.Lock()
	demand := broadcaster.Demand
	session := broadcaster.Microphone
	state := "ready"
	streamID := uint32(0)
	stateGeneration := demand.generation
	if session.hasOwner && session.ownerReceipt == receiptNo && session.ownerIdentity == sub.identity &&
		session.agentGeneration == demand.agentGeneration {
		state = "starting"
		if session.active {
			state = "active"
		}
		streamID = session.streamID
		stateGeneration = session.demandGeneration
	}
	sub.sendMicrophoneStatus(microphoneStatePayload(state, streamID, stateGeneration))
	broadcaster.MicrophoneMu.Unlock()
	sub.sendMicrophoneDemand(demand.revision, microphoneDemandPayload(demand))
	sub.remoteAudioReceiveOnce.Do(func() {
		go manager.receiveAutomaticMicrophoneTracks(deviceIdentifier, receiptNo, sub)
	})
}

func (manager *WebRTCManager) GetAgent(deviceIdentifier string) (*sagent.Agent, bool) {
	agent, _, exists := manager.currentAgent(deviceIdentifier)
	return agent, exists
}

func (manager *WebRTCManager) GetSubscriber(deviceIdentifier string, receiptNo uint32) (*Subscriber, bool) {
	manager.RLock()
	defer manager.RUnlock()
	b, exists := manager.broadcasters[deviceIdentifier]
	if !exists {
		return nil, false
	}
	b.Lock.RLock()
	defer b.Lock.RUnlock()
	sub, exists := b.Subscribers[receiptNo]
	return sub, exists
}

func createMediaEngine(mimeTypes []string) *webrtc.MediaEngine {
	m := &webrtc.MediaEngine{}
	for _, mime := range mimeTypes {
		switch mime {
		case webrtc.MimeTypeAV1:
			err := m.RegisterCodec(webrtc.RTPCodecParameters{
				RTPCodecCapability: webrtc.RTPCodecCapability{
					MimeType:  webrtc.MimeTypeAV1,
					ClockRate: 90000,
					Channels:  0,
					// profile=0 (Main Profile), level-idx=13 (Level 5.1), tier=0 (Main Tier)
					SDPFmtpLine: "profile=0;level-idx=13;tier=0",
					RTCPFeedback: []webrtc.RTCPFeedback{
						{Type: "transport-cc", Parameter: ""},
						{Type: "ccm", Parameter: "fir"},
						{Type: "nack", Parameter: ""},
						{Type: "nack", Parameter: "pli"},
					},
				},
				PayloadType: PAYLOAD_TYPE_AV1_PROFILE_MAIN_5_1,
			}, webrtc.RTPCodecTypeVideo)
			if err != nil {
				log.Println("RegisterCodec AV1 failed:", err)
			}
			log.Println("Registered AV1 codec")
		case webrtc.MimeTypeH265:
			batchRegisterCodecH265(m)
		case webrtc.MimeTypeH264:
			batchRegisterCodecH264(m)
		case webrtc.MimeTypeOpus:
			// Register Opus (Audio)
			err := m.RegisterCodec(webrtc.RTPCodecParameters{
				RTPCodecCapability: webrtc.RTPCodecCapability{
					MimeType:  webrtc.MimeTypeOpus,
					ClockRate: 48000,
					Channels:  2,
					// force 10ms low latency, but not working well, so disable it
					// force stereo (spatial audio)
					// enable FEC (forward error correction)
					// disable DTX (discontinuous transmission) (usedtx=0)
					SDPFmtpLine: "minptime=10;maxptime=20;useinbandfec=1;stereo=1;sprop-stereo=1",
				},
				PayloadType: 111,
			}, webrtc.RTPCodecTypeAudio)
			if err != nil {
				log.Println("RegisterCodec Opus failed:", err)
			}
		default:
			log.Printf("Unsupported MIME type: %s", mime)
		}

	}
	return m
}

func batchRegisterCodecH264(m *webrtc.MediaEngine) {
	// profile-level-id :
	// High Profile (0x64) 4d: Main Profile (0x4d) 42: Baseline Profile (0x42)
	// Constraint Set (00) Constrained Baseline (e0)
	// Level 5.1 (5.1 * 10 = 51 = 0x33) Level 4.2 (4.2 * 10 = 42 = 0x2a) Level 3.1 (3.1 * 10 = 31 = 0x1f)
	// packetization-mode=1: 支持非交错模式
	// high profile
	err := m.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:    webrtc.MimeTypeH264,
			ClockRate:   90000,
			Channels:    0,
			SDPFmtpLine: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640033",
			RTCPFeedback: []webrtc.RTCPFeedback{
				{Type: "transport-cc", Parameter: ""},
				{Type: "ccm", Parameter: "fir"},
				{Type: "nack", Parameter: ""},
				{Type: "nack", Parameter: "pli"},
			},
		},
		PayloadType: PAYLOAD_TYPE_H264_PROFILE_HIGH_5_1,
	}, webrtc.RTPCodecTypeVideo)
	// high profile for iphone safari
	err = m.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:    webrtc.MimeTypeH264,
			ClockRate:   90000,
			Channels:    0,
			SDPFmtpLine: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640c33",
			RTCPFeedback: []webrtc.RTCPFeedback{
				{Type: "transport-cc", Parameter: ""},
				{Type: "ccm", Parameter: "fir"},
				{Type: "nack", Parameter: ""},
				{Type: "nack", Parameter: "pli"},
			},
		},
		PayloadType: PAYLOAD_TYPE_H264_PROFILE_HIGH_5_1_0C,
	}, webrtc.RTPCodecTypeVideo)
	if err != nil {
		log.Println("RegisterCodec H264 failed:", err)
	}
	// Baseline Profile
	// err = m.RegisterCodec(webrtc.RTPCodecParameters{
	// 	RTPCodecCapability: webrtc.RTPCodecCapability{
	// 		MimeType:    webrtc.MimeTypeH264,
	// 		ClockRate:   90000,
	// 		Channels:    0,
	// 		SDPFmtpLine: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42001f",
	// 		RTCPFeedback: []webrtc.RTCPFeedback{
	// 			{Type: "transport-cc", Parameter: ""},
	// 			{Type: "ccm", Parameter: "fir"},
	// 			{Type: "nack", Parameter: ""},
	// 			{Type: "nack", Parameter: "pli"},
	// 		},
	// 	},
	// 	PayloadType: PAYLOAD_TYPE_H264_PROFILE_BASELINE_3_1,
	// }, webrtc.RTPCodecTypeVideo)
	// if err != nil {
	// 	log.Println("RegisterCodec H264 failed:", err)
	// }
	// baseline profile for iphone safari
	// err = m.RegisterCodec(webrtc.RTPCodecParameters{
	// 	RTPCodecCapability: webrtc.RTPCodecCapability{
	// 		MimeType:    webrtc.MimeTypeH264,
	// 		ClockRate:   90000,
	// 		Channels:    0,
	// 		SDPFmtpLine: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=420c1f",
	// 		RTCPFeedback: []webrtc.RTCPFeedback{
	// 			{Type: "transport-cc", Parameter: ""},
	// 			{Type: "ccm", Parameter: "fir"},
	// 			{Type: "nack", Parameter: ""},
	// 			{Type: "nack", Parameter: "pli"},
	// 		},
	// 	},
	// 	PayloadType: PAYLOAD_TYPE_H264_PROFILE_BASELINE_3_1_0C,
	// }, webrtc.RTPCodecTypeVideo)
	// if err != nil {
	// 	log.Println("RegisterCodec H264 failed:", err)
	// }
	// log.Println("Registered H264 codec")
}

func batchRegisterCodecH265(m *webrtc.MediaEngine) {
	// Register H.265 (video)
	err := m.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:    webrtc.MimeTypeH265,
			ClockRate:   90000,
			Channels:    0,
			SDPFmtpLine: "profile-id=1;tier-flag=0;level-id=153",
			RTCPFeedback: []webrtc.RTCPFeedback{
				{Type: "transport-cc", Parameter: ""},
				{Type: "ccm", Parameter: "fir"},
				{Type: "nack", Parameter: ""},
				{Type: "nack", Parameter: "pli"},
			},
		},
		PayloadType: PAYLOAD_TYPE_H265_PROFILE_MAIN_TIER_MAIN_5_1,
	}, webrtc.RTPCodecTypeVideo)
	if err != nil {
		log.Println("RegisterCodec H265 failed:", err)
	}
	err = m.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:    webrtc.MimeTypeH265,
			ClockRate:   90000,
			Channels:    0,
			SDPFmtpLine: "profile-id=1;tier-flag=0;level-id=123",
			RTCPFeedback: []webrtc.RTCPFeedback{
				{Type: "transport-cc", Parameter: ""},
				{Type: "ccm", Parameter: "fir"},
				{Type: "nack", Parameter: ""},
				{Type: "nack", Parameter: "pli"},
			},
		},
		PayloadType: PAYLOAD_TYPE_H265_PROFILE_MAIN_TIER_MAIN_4_1,
	}, webrtc.RTPCodecTypeVideo)
	if err != nil {
		log.Println("RegisterCodec H265 failed:", err)
	}
	log.Println("Registered H265 codec")
}

func WaitAndGetFinalCodecParams(pc *webrtc.PeerConnection) (webrtc.RTPCodecParameters, error) {
	startTime := time.Now()
	for {
		if pc.ConnectionState() == webrtc.PeerConnectionStateFailed {
			return webrtc.RTPCodecParameters{}, fmt.Errorf("peer connection failed")
		}
		if pc.ConnectionState() == webrtc.PeerConnectionStateClosed {
			return webrtc.RTPCodecParameters{}, fmt.Errorf("peer connection closed")
		}
		if pc.ConnectionState() == webrtc.PeerConnectionStateConnected {
			for _, sender := range pc.GetSenders() {
				if sender.Track() == nil {
					continue
				}
				if sender.Track().Kind() != webrtc.RTPCodecTypeVideo {
					continue
				}
				params := sender.GetParameters()
				selectedCodec := params.Codecs[0] // 通常只有一个活跃的 codec
				// log.Printf("Negotiation result: %v", selectedCodec)
				// 根据 PayloadType 决定 scrcpy 参数
				return selectedCodec, nil
			}
		}
		if time.Since(startTime) > 10*time.Second {
			return webrtc.RTPCodecParameters{}, fmt.Errorf("timeout waiting for final codec parameters")
		}
		time.Sleep(500 * time.Millisecond)
	}
}

func getMimeTypeFromConfig(config sagent.AgentConfig) (string, string) {
	var videoMimeType, audioMimeType string
	switch config.DriverConfig["video_codec"] {
	case "h264":
		videoMimeType = webrtc.MimeTypeH264
	case "h265":
		videoMimeType = webrtc.MimeTypeH265
	case "av1":
		videoMimeType = webrtc.MimeTypeAV1
	default:
		videoMimeType = webrtc.MimeTypeH264 // 默认使用 H.264
		log.Printf("Unsupported or missing video codec in config, defaulting to H.264")
	}
	audioMimeType = webrtc.MimeTypeOpus // 强制使用 Opus 音频编码，确保兼容性
	log.Printf("Creating tracks with MIME types - Video: %s, Audio: %s", videoMimeType, audioMimeType)
	return videoMimeType, audioMimeType
}

func createAVTrack(videoMimeType, audioMimeType string, AVSync bool) (*webrtc.TrackLocalStaticRTP, *webrtc.TrackLocalStaticRTP) {
	mark := fmt.Sprintf("%d", time.Now().UnixNano())
	trackID := fmt.Sprintf("%s-%s", "webscreen-track", randomString(8))
	trackIDVideo := trackID + "-" + mark + "-video"
	trackIDAudio := trackID + "-" + mark + "-audio"
	streamID := fmt.Sprintf("%s-%s", "webscreen-stream", randomString(8))
	streamIDVideo := streamID + "-" + mark + "-video"
	streamIDAudio := streamID + "-" + mark + "-audio"
	if AVSync {
		streamIDVideo = streamID + "-" + mark
		streamIDAudio = streamID + "-" + mark
	}

	trackVideo, err := webrtc.NewTrackLocalStaticRTP(webrtc.RTPCodecCapability{MimeType: videoMimeType}, trackIDVideo, streamIDVideo)
	if err != nil {
		log.Printf("Failed to create track for MIME type %s: %v", videoMimeType, err)
	}
	trackAudio, err := webrtc.NewTrackLocalStaticRTP(webrtc.RTPCodecCapability{MimeType: audioMimeType}, trackIDAudio, streamIDAudio)
	if err != nil {
		log.Printf("Failed to create audio track for MIME type %s: %v", audioMimeType, err)
	}
	return trackVideo, trackAudio
}

func (sub *Subscriber) setDataChannel() {
	sub.PeerConnection.OnDataChannel(func(d *webrtc.DataChannel) {
		log.Printf("Have DataChannel: Label '%s', ID: %d\n", d.Label(), d.ID())
		switch d.Label() {
		case "control-ordered":
			sub.channelMu.Lock()
			sub.dataChannelOrdered = d
			sub.channelMu.Unlock()
			d.OnMessage(func(msg webrtc.DataChannelMessage) {
				sub.callbackMu.RLock()
				callback := sub.onMessageCallback
				sub.callbackMu.RUnlock()
				if callback != nil {
					if err := callback(msg.Data); err != nil {
						log.Printf("Error handling ordered data channel message: %v", err)
					}
				}
			})
		case "control-unordered":
			sub.channelMu.Lock()
			sub.dataChannelUnordered = d
			sub.channelMu.Unlock()
			d.OnMessage(func(msg webrtc.DataChannelMessage) {
				sub.callbackMu.RLock()
				callback := sub.onMessageCallback
				sub.callbackMu.RUnlock()
				if callback != nil {
					if err := callback(msg.Data); err != nil {
						log.Printf("Error handling unordered data channel message: %v", err)
					}
				}
			})
		case "control-transient":
			sub.channelMu.Lock()
			sub.dataChannelTransient = d
			sub.channelMu.Unlock()
			d.OnMessage(func(msg webrtc.DataChannelMessage) {
				sub.callbackMu.RLock()
				callback := sub.onMessageCallback
				sub.callbackMu.RUnlock()
				if callback != nil {
					if err := callback(msg.Data); err != nil {
						log.Printf("Error handling transient data channel message: %v", err)
					}
				}
			})
		case "microphone-control":
			if !d.Ordered() || d.MaxRetransmits() != nil || d.MaxPacketLifeTime() != nil {
				log.Printf("microphone_control_rejected receipt=%d reason=%q", sub.receiptNo, "invalid_reliability")
				_ = d.Close()
				return
			}
			sub.channelMu.Lock()
			if sub.microphoneControl != nil {
				sub.channelMu.Unlock()
				log.Printf("microphone_control_rejected receipt=%d reason=%q", sub.receiptNo, "duplicate_channel")
				_ = d.Close()
				return
			}
			sub.microphoneControl = d
			sub.channelMu.Unlock()
			d.OnOpen(func() { sub.flushMicrophoneMessages() })
			d.OnClose(func() { sub.notifyMicrophoneClosed() })
			d.OnMessage(func(msg webrtc.DataChannelMessage) {
				if msg.IsString {
					sub.callbackMu.RLock()
					callback := sub.onMicrophoneText
					sub.callbackMu.RUnlock()
					if callback != nil {
						if err := callback(msg.Data); err != nil {
							log.Printf("microphone_control_rejected receipt=%d reason=%q", sub.receiptNo, err)
						}
					}
					return
				}
				sub.callbackMu.RLock()
				callback := sub.onMicrophoneControl
				sub.callbackMu.RUnlock()
				if callback != nil {
					if err := callback(msg.Data); err != nil {
						log.Printf("microphone_control_rejected receipt=%d reason=%q", sub.receiptNo, err)
					}
				}
			})
		case "microphone-data":
			maxRetransmits := d.MaxRetransmits()
			// The controller keeps packets ordered but disables retransmission.
			// This avoids out-of-order IUMC sequence failures while still
			// preventing stale microphone audio from building latency.
			if !d.Ordered() || maxRetransmits == nil || *maxRetransmits != 0 || d.MaxPacketLifeTime() != nil {
				log.Printf("microphone_data_rejected receipt=%d reason=%q", sub.receiptNo, "invalid_reliability")
				_ = d.Close()
				return
			}
			sub.channelMu.Lock()
			if sub.microphoneData != nil {
				sub.channelMu.Unlock()
				log.Printf("microphone_data_rejected receipt=%d reason=%q", sub.receiptNo, "duplicate_channel")
				_ = d.Close()
				return
			}
			sub.microphoneData = d
			sub.channelMu.Unlock()
			d.OnClose(func() { sub.notifyMicrophoneDataClosed() })
			d.OnMessage(func(msg webrtc.DataChannelMessage) {
				if msg.IsString {
					log.Printf("microphone_data_rejected receipt=%d reason=%q", sub.receiptNo, "unexpected_text_frame")
					return
				}
				sub.callbackMu.RLock()
				callback := sub.onMicrophoneData
				sub.callbackMu.RUnlock()
				if callback != nil {
					if err := callback(msg.Data); err != nil {
						log.Printf("microphone_data_rejected receipt=%d reason=%q", sub.receiptNo, err)
					}
				}
			})
		default:
			log.Printf("Unknown DataChannel label: %s\n", d.Label())
			d.OnMessage(func(webrtc.DataChannelMessage) {})
		}
	})
}

func (sub *Subscriber) setMicrophoneCallbacks(
	control func([]byte) error,
	text func([]byte) error,
	data func([]byte) error,
	closed func(),
	dataClosed func(),
) {
	sub.callbackMu.Lock()
	sub.onMicrophoneControl = control
	sub.onMicrophoneText = text
	sub.onMicrophoneData = data
	sub.onMicrophoneClose = closed
	sub.onMicrophoneDataClose = dataClosed
	sub.callbackMu.Unlock()
}

func (sub *Subscriber) notifyMicrophoneDataClosed() {
	sub.callbackMu.RLock()
	callback := sub.onMicrophoneDataClose
	sub.callbackMu.RUnlock()
	if callback != nil {
		callback()
	}
}

func (sub *Subscriber) notifyMicrophoneClosed() {
	sub.callbackMu.RLock()
	callback := sub.onMicrophoneClose
	sub.callbackMu.RUnlock()
	if callback != nil {
		callback()
	}
}

func (sub *Subscriber) sendMicrophoneStatus(payload []byte) {
	sub.microphoneMessageMu.Lock()
	defer sub.microphoneMessageMu.Unlock()
	sub.latestMicrophoneStatus = append(sub.latestMicrophoneStatus[:0], payload...)
	sub.sendMicrophoneMessageLocked(payload, "state")
}

func (sub *Subscriber) sendMicrophoneDemand(revision uint64, payload []byte) {
	sub.microphoneMessageMu.Lock()
	defer sub.microphoneMessageMu.Unlock()
	if sub.hasLatestMicrophoneDemand && revision <= sub.latestMicrophoneDemandRevision {
		return
	}
	sub.hasLatestMicrophoneDemand = true
	sub.latestMicrophoneDemandRevision = revision
	sub.latestMicrophoneDemand = append(sub.latestMicrophoneDemand[:0], payload...)
	sub.sendMicrophoneMessageLocked(payload, "demand")
}

func (sub *Subscriber) sendMicrophoneMessageLocked(payload []byte, messageType string) {
	sub.channelMu.RLock()
	channel := sub.microphoneControl
	sub.channelMu.RUnlock()
	if channel == nil || channel.ReadyState() != webrtc.DataChannelStateOpen {
		return
	}
	if err := channel.SendText(string(payload)); err != nil {
		log.Printf(
			"microphone_control_send_failed receipt=%d message_type=%q error=%q",
			sub.receiptNo,
			messageType,
			err,
		)
	}
}

func (sub *Subscriber) flushMicrophoneMessages() {
	sub.microphoneMessageMu.Lock()
	defer sub.microphoneMessageMu.Unlock()
	payload := append([]byte(nil), sub.latestMicrophoneStatus...)
	demand := append([]byte(nil), sub.latestMicrophoneDemand...)
	if len(payload) != 0 {
		sub.sendMicrophoneMessageLocked(payload, "state")
	}
	if len(demand) != 0 {
		sub.sendMicrophoneMessageLocked(demand, "demand")
	}
}

func (sub *Subscriber) setRemoteAudioReady(ready bool) {
	sub.remoteAudioMu.Lock()
	sub.remoteAudioReady = ready
	sub.remoteAudioMu.Unlock()
}

func (sub *Subscriber) hasRemoteAudioTrack() bool {
	sub.remoteAudioMu.RLock()
	defer sub.remoteAudioMu.RUnlock()
	return sub.remoteAudioReady
}

func (sub *Subscriber) stopRemoteAudio() {
	sub.remoteAudioStopOnce.Do(func() { close(sub.remoteAudioStop) })
}

func (sub *Subscriber) setDataChannelCallback(callback func([]byte) error) {
	sub.callbackMu.Lock()
	defer sub.callbackMu.Unlock()
	sub.onMessageCallback = callback

	// If channels are already open, attach handlers now?
	// Since we set OnMessage in setDataChannel (which sets up the OnDataChannel handler),
	// we just need to update the callback reference, which is what we did above.
	// However, if the channel was ALREADY opened (before setDataChannel ran?? unlikely),
	// or if we want to ensure any buffered logic...

	// Actually, the closure in setDataChannel captures `sub`.
	// So `sub.onMessageCallback` will be read dynamically.
	// No further action needed here unless we want to support changing callbacks on existing open channels that somehow missed the initial setup (which shouldn't happen).
}

func (manager *WebRTCManager) setCleanup(
	pc *webrtc.PeerConnection,
	deviceIdentifier string,
	receiptNo uint32,
	identity subscriberIdentity,
) {
	var cleanupOnce sync.Once
	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		log.Printf("PeerConnection state changed: %s\n", state.String())
		if state == webrtc.PeerConnectionStateFailed || state == webrtc.PeerConnectionStateClosed {
			cleanupOnce.Do(func() {
				log.Printf(
					"PeerConnection is in state %s, cleaning up resources\n",
					state.String(),
				)
				_ = pc.Close()
				manager.removeSubscriber(deviceIdentifier, receiptNo, identity)
			})
		}
	})
}

func (manager *WebRTCManager) removeSubscriber(
	deviceIdentifier string,
	receiptNo uint32,
	identity subscriberIdentity,
) {
	manager.RLock()
	broadcaster, exists := manager.broadcasters[deviceIdentifier]
	manager.RUnlock()
	if !exists {
		return
	}

	broadcaster.Lock.Lock()
	sub := broadcaster.Subscribers[receiptNo]
	if sub == nil || sub.identity != identity {
		broadcaster.Lock.Unlock()
		return
	}
	delete(broadcaster.Subscribers, receiptNo)
	subCount := len(broadcaster.Subscribers)
	broadcaster.Lock.Unlock()
	if sub != nil {
		sub.telemetry.stop()
		sub.stopRemoteAudio()
	}
	manager.releaseMicrophoneForSubscriber(deviceIdentifier, receiptNo, identity, "subscriber_removed")

	broadcaster.AgentLock.Lock()
	if broadcaster.Agent != nil && sub != nil {
		broadcaster.Agent.RemoveFrameObserver(sub.frameObserverID)
	}
	broadcaster.AgentLock.Unlock()

	log.Printf(
		"subscriber_removed device=%q receipt=%d remaining=%d",
		deviceIdentifier,
		receiptNo,
		subCount,
	)
	if subCount == 0 {
		go manager.removeIdleBroadcasterAfterGrace(
			deviceIdentifier,
			broadcaster,
			30*time.Minute,
		)
	}
}

func (manager *WebRTCManager) removeIdleBroadcasterAfterGrace(
	deviceIdentifier string,
	expected *DeviceBroadcaster,
	grace time.Duration,
) {
	timer := time.NewTimer(grace)
	defer timer.Stop()
	<-timer.C

	manager.Lock()
	broadcaster, exists := manager.broadcasters[deviceIdentifier]
	if !exists || broadcaster != expected {
		manager.Unlock()
		return
	}
	broadcaster.Lock.RLock()
	subCount := len(broadcaster.Subscribers)
	pendingSetups := broadcaster.pendingSubscriberSetups
	broadcaster.Lock.RUnlock()
	if subCount != 0 {
		manager.Unlock()
		return
	}
	if pendingSetups != 0 {
		manager.Unlock()
		go manager.removeIdleBroadcasterAfterGrace(
			deviceIdentifier,
			broadcaster,
			grace,
		)
		return
	}
	if broadcaster.Prewarmed {
		manager.Unlock()
		return
	}
	delete(manager.broadcasters, deviceIdentifier)
	delete(manager.currentReceiptNumber, deviceIdentifier)
	manager.Unlock()

	broadcaster.AgentLock.Lock()
	if broadcaster.Agent != nil {
		if broadcaster.AgentConfig.DeviceType == sagent.DEVICE_TYPE_IPHONE_USB {
			manager.transitionMicrophoneAgentLocked(
				broadcaster,
				broadcaster.Agent,
				broadcaster.AgentGeneration+1,
				"agent_stopped",
			)
		}
		broadcaster.Agent.Close()
		broadcaster.Agent = nil
	}
	broadcaster.AgentLock.Unlock()
	log.Printf("shared_agent_stopped device=%q reason=%q", deviceIdentifier, "idle")
}

func ListenRTPVideo(rtpSender *webrtc.RTPSender, requestIDR func()) {
	rtcpBuf := make([]byte, 1500)
	for {
		n, _, err := rtpSender.Read(rtcpBuf)
		if err != nil {
			log.Printf("Error reading RTCP: %v", err)
			return
		}
		packets, err := rtcp.Unmarshal(rtcpBuf[:n])
		if err != nil {
			continue
		}
		for _, p := range packets {
			switch p.(type) {
			case *rtcp.PictureLossIndication:
				// log.Println("IDR requested via RTCP PLI")
				requestIDR()
			}
		}
	}
}

func ListenRTPAudio(rtpSender *webrtc.RTPSender) {
	rtcpBuf := make([]byte, 1500)
	for {
		_, _, err := rtpSender.Read(rtcpBuf)
		if err != nil {
			log.Printf("Error reading RTCP: %v", err)
			return
		}
		// packets, err := rtcp.Unmarshal(rtcpBuf[:n])
		// if err != nil {
		// 	continue
		// }
		// for _, p := range packets {
		// 	log.Printf("Received RTCP packet on audio track: %T\n", p)
		// 	// 目前不处理音频相关的 RTCP 包
		// }
	}
}

type turnConfiguration struct {
	credentialTTLSeconds int64
	sharedSecret         []byte
	stunURLs             []string
	turnURLs             []string
}

func validateTurnHost(host string) bool {
	if strings.HasPrefix(host, "[") && strings.HasSuffix(host, "]") {
		value := strings.TrimSuffix(strings.TrimPrefix(host, "["), "]")
		return strings.Contains(value, ":") && net.ParseIP(value) != nil
	}

	if parsedIP := net.ParseIP(host); parsedIP != nil {
		return !strings.Contains(host, ":")
	}
	if strings.Trim(host, "0123456789.") == "" {
		return false
	}
	if len(host) > 253 {
		return false
	}
	for _, label := range strings.Split(host, ".") {
		if len(label) == 0 || len(label) > 63 {
			return false
		}
		for index, character := range label {
			isLetter := character >= 'a' && character <= 'z' ||
				character >= 'A' && character <= 'Z'
			isDigit := character >= '0' && character <= '9'
			if !isLetter && !isDigit && character != '-' {
				return false
			}
			if character == '-' && (index == 0 || index == len(label)-1) {
				return false
			}
		}
	}
	return true
}

func normalizeTurnURL(rawURL string) (turnURL string, stunURL string, err error) {
	if len(rawURL) == 0 || len(rawURL) > 512 || rawURL != strings.TrimSpace(rawURL) {
		return "", "", fmt.Errorf("WEBSCREEN_TURN_URLS contains an invalid URL")
	}
	match := turnURLPattern.FindStringSubmatch(rawURL)
	if match == nil {
		return "", "", fmt.Errorf("WEBSCREEN_TURN_URLS accepts only turn: or turns: URLs")
	}

	scheme := strings.ToLower(match[1])
	host := strings.ToLower(match[2])
	if !validateTurnHost(host) {
		return "", "", fmt.Errorf("WEBSCREEN_TURN_URLS contains an invalid host")
	}
	portText := match[3]
	if portText != "" {
		port, parseErr := strconv.Atoi(portText)
		if parseErr != nil || port < 1 || port > 65535 {
			return "", "", fmt.Errorf("WEBSCREEN_TURN_URLS contains an invalid port")
		}
		portText = strconv.Itoa(port)
	}
	transport := strings.ToLower(match[4])

	turnURL = scheme + ":" + host
	if portText != "" {
		turnURL += ":" + portText
	}
	if transport != "" {
		turnURL += "?transport=" + transport
	}

	if scheme == "turn" && (transport == "" || transport == "udp") {
		stunPort := portText
		if stunPort == "" {
			stunPort = "3478"
		}
		stunURL = "stun:" + host + ":" + stunPort
	}
	return turnURL, stunURL, nil
}

func loadTurnConfiguration() (turnConfiguration, error) {
	rawURLs, hasURLs := os.LookupEnv("WEBSCREEN_TURN_URLS")
	sharedSecret, hasSecret := os.LookupEnv("WEBSCREEN_TURN_SHARED_SECRET")
	rawTTL, hasTTL := os.LookupEnv("WEBSCREEN_TURN_CREDENTIAL_TTL_SECONDS")
	if !hasURLs || rawURLs == "" || !hasSecret || sharedSecret == "" || !hasTTL || rawTTL == "" {
		return turnConfiguration{}, fmt.Errorf("WEBSCREEN_TURN_URLS, WEBSCREEN_TURN_SHARED_SECRET, and WEBSCREEN_TURN_CREDENTIAL_TTL_SECONDS are required")
	}

	if !utf8.ValidString(sharedSecret) ||
		sharedSecret != strings.TrimSpace(sharedSecret) ||
		strings.IndexFunc(sharedSecret, func(character rune) bool {
			return character < 0x21 || character > 0x7e
		}) >= 0 {
		return turnConfiguration{}, fmt.Errorf("WEBSCREEN_TURN_SHARED_SECRET contains invalid characters")
	}
	secretLength := len([]byte(sharedSecret))
	if secretLength < 32 || secretLength > 256 {
		return turnConfiguration{}, fmt.Errorf("WEBSCREEN_TURN_SHARED_SECRET must contain 32 to 256 bytes")
	}

	if strings.Trim(rawTTL, "0123456789") != "" {
		return turnConfiguration{}, fmt.Errorf("WEBSCREEN_TURN_CREDENTIAL_TTL_SECONDS must be an integer")
	}
	ttlSeconds, err := strconv.ParseInt(rawTTL, 10, 64)
	if err != nil ||
		ttlSeconds < MIN_TURN_CREDENTIAL_TTL_SECONDS ||
		ttlSeconds > MAX_TURN_CREDENTIAL_TTL_SECONDS {
		return turnConfiguration{}, fmt.Errorf(
			"WEBSCREEN_TURN_CREDENTIAL_TTL_SECONDS must be between %d and %d",
			MIN_TURN_CREDENTIAL_TTL_SECONDS,
			MAX_TURN_CREDENTIAL_TTL_SECONDS,
		)
	}

	var configuredURLs []string
	if err := json.Unmarshal([]byte(rawURLs), &configuredURLs); err != nil {
		return turnConfiguration{}, fmt.Errorf("WEBSCREEN_TURN_URLS must be a JSON array of strings")
	}
	if len(configuredURLs) == 0 || len(configuredURLs) > MAX_TURN_URLS {
		return turnConfiguration{}, fmt.Errorf(
			"WEBSCREEN_TURN_URLS must contain between 1 and %d URLs",
			MAX_TURN_URLS,
		)
	}

	turnURLs := make([]string, 0, len(configuredURLs))
	stunURLs := make([]string, 0, len(configuredURLs))
	seenTurnURLs := make(map[string]struct{}, len(configuredURLs))
	seenStunURLs := make(map[string]struct{}, len(configuredURLs))
	for _, rawURL := range configuredURLs {
		turnURL, stunURL, err := normalizeTurnURL(rawURL)
		if err != nil {
			return turnConfiguration{}, err
		}
		if _, exists := seenTurnURLs[turnURL]; exists {
			return turnConfiguration{}, fmt.Errorf("WEBSCREEN_TURN_URLS contains a duplicate URL")
		}
		seenTurnURLs[turnURL] = struct{}{}
		turnURLs = append(turnURLs, turnURL)
		if stunURL != "" {
			if _, exists := seenStunURLs[stunURL]; !exists {
				seenStunURLs[stunURL] = struct{}{}
				stunURLs = append(stunURLs, stunURL)
			}
		}
	}

	return turnConfiguration{
		credentialTTLSeconds: ttlSeconds,
		sharedSecret:         []byte(sharedSecret),
		stunURLs:             stunURLs,
		turnURLs:             turnURLs,
	}, nil
}

var (
	cloudflareICECacheMu  sync.Mutex
	cloudflareICECache    []webrtc.ICEServer
	cloudflareICECacheExp time.Time
)

func fetchCloudflareICEServers() ([]webrtc.ICEServer, error) {
	keyID := strings.TrimSpace(os.Getenv("WEBSCREEN_CF_TURN_KEY_ID"))
	token := strings.TrimSpace(os.Getenv("WEBSCREEN_CF_TURN_API_TOKEN"))
	if keyID == "" || token == "" {
		return nil, nil
	}
	cloudflareICECacheMu.Lock()
	if time.Now().Before(cloudflareICECacheExp) && len(cloudflareICECache) > 0 {
		cached := append([]webrtc.ICEServer(nil), cloudflareICECache...)
		cloudflareICECacheMu.Unlock()
		return cached, nil
	}
	cloudflareICECacheMu.Unlock()

	endpoint := "https://rtc.live.cloudflare.com/v1/turn/keys/" + keyID + "/credentials/generate-ice-servers"
	request, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewBufferString(`{"ttl":86400}`))
	if err != nil {
		return nil, err
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Content-Type", "application/json")
	response, err := (&http.Client{Timeout: 8 * time.Second}).Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("Cloudflare TURN API status %d", response.StatusCode)
	}
	var payload struct {
		ICEServers []struct {
			URLs       []string `json:"urls"`
			Username   string   `json:"username"`
			Credential string   `json:"credential"`
		} `json:"iceServers"`
	}
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		return nil, err
	}
	servers := make([]webrtc.ICEServer, 0, len(payload.ICEServers))
	for _, source := range payload.ICEServers {
		udpURLs := make([]string, 0, len(source.URLs))
		for _, candidate := range source.URLs {
			if strings.HasPrefix(candidate, "stun:") || strings.Contains(candidate, "transport=udp") {
				udpURLs = append(udpURLs, candidate)
			}
		}
		if len(udpURLs) == 0 {
			continue
		}
		server := webrtc.ICEServer{URLs: udpURLs}
		if source.Username != "" {
			server.Username = source.Username
			server.Credential = source.Credential
		}
		servers = append(servers, server)
	}
	cloudflareICECacheMu.Lock()
	cloudflareICECache = append(cloudflareICECache[:0], servers...)
	cloudflareICECacheExp = time.Now().Add(12 * time.Hour)
	cloudflareICECacheMu.Unlock()
	return servers, nil
}

func (manager *WebRTCManager) createICEServers() ([]webrtc.ICEServer, error) {
	if servers, err := fetchCloudflareICEServers(); err != nil {
		log.Printf("Cloudflare ICE fetch failed, falling back to coturn: %v", err)
	} else if len(servers) > 0 {
		log.Printf("Using Cloudflare TURN (%d ICE servers)", len(servers))
		return servers, nil
	}
	nonce := make([]byte, 12)
	if _, err := rand.Read(nonce); err != nil {
		return nil, fmt.Errorf("failed to generate TURN credential nonce: %w", err)
	}
	expiresAt := time.Now().Unix() + manager.turnConfiguration.credentialTTLSeconds
	username := strconv.FormatInt(expiresAt, 10) +
		":remote-handset-" +
		base64.RawURLEncoding.EncodeToString(nonce)
	mac := hmac.New(sha1.New, manager.turnConfiguration.sharedSecret)
	if _, err := mac.Write([]byte(username)); err != nil {
		return nil, fmt.Errorf("failed to sign TURN credential: %w", err)
	}
	credential := base64.StdEncoding.EncodeToString(mac.Sum(nil))

	servers := make([]webrtc.ICEServer, 0, 2)
	if len(manager.turnConfiguration.stunURLs) > 0 {
		servers = append(servers, webrtc.ICEServer{
			URLs: manager.turnConfiguration.stunURLs,
		})
	}
	servers = append(servers, webrtc.ICEServer{
		URLs:       manager.turnConfiguration.turnURLs,
		Username:   username,
		Credential: credential,
	})
	return servers, nil
}
