package webservice

import (
	"log"
	"strings"
	"time"

	"webscreen/sdriver/scrcpy"
	sagent "webscreen/streamAgent"

	"github.com/pion/webrtc/v4"
)

// prewarmAgentConfig mirrors the default app profile after the gateway relay
// bitrate cap. It must remain equivalent to a real Android subscriber profile,
// otherwise the first connection would restart scrcpy and lose the warm start.
func prewarmAgentConfig(deviceID string) sagent.AgentConfig {
	return sagent.AgentConfig{
		DeviceType:        sagent.DEVICE_TYPE_ANDROID,
		DeviceID:          deviceID,
		DeviceIP:          "0",
		DevicePort:        "0",
		AVSync:            false,
		UseLocalTimestamp: false,
		StreamProfile:     "prewarm",
		DriverConfig: map[string]string{
			"video_codec":         "h264",
			"video_encoder":       "c2.qti.avc.encoder",
			"video_bit_rate":      "800000",
			"video_codec_options": "i-frame-interval=4,bitrate-mode=2",
			"max_size":            "1280",
			"max_fps":             "30",
			"audio":               "true",
			"audio_bit_rate":      "64000",
			"control":             "true",
		},
	}
}

func prewarmFinalCodec() webrtc.RTPCodecParameters {
	return webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:    webrtc.MimeTypeH264,
			ClockRate:   90_000,
			SDPFmtpLine: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640c33",
		},
		PayloadType: 96,
	}
}

// ensurePrewarmedDevice creates the shared Android broadcaster when necessary
// and keeps its resident Agent alive while the device has no subscribers.
//
// A failed Agent deliberately remains represented by its broadcaster: the
// shared tracks and RTP continuity belong to that broadcaster, and replacing it
// behind an in-flight subscriber would orphan the subscriber. The prewarm loop
// therefore repairs a nil or terminal Agent in place. AgentLock serializes that
// repair with subscriber-driven starts/restarts, while the subscriber counters
// prevent prewarm from choosing a codec/profile on behalf of a setup already in
// progress.
func (manager *WebRTCManager) ensurePrewarmedDevice(deviceIdentifier, deviceID string) {
	manager.adbRecoveryLease.RLock()
	defer manager.adbRecoveryLease.RUnlock()
	manager.ensurePrewarmedDeviceWithRecoveryLease(deviceIdentifier, deviceID)
}

// ensurePrewarmedDeviceWithRecoveryLease requires adbRecoveryLease to be held
// for reading. Keeping the transport lease outermost prevents the recovery
// writer from overlapping any AgentLock-protected adb setup.
func (manager *WebRTCManager) ensurePrewarmedDeviceWithRecoveryLease(deviceIdentifier, deviceID string) {
	manager.Lock()
	broadcaster, exists := manager.broadcasters[deviceIdentifier]
	if !exists {
		videoTrack, audioTrack := createAVTrack(webrtc.MimeTypeH264, webrtc.MimeTypeOpus, false)
		if videoTrack == nil && audioTrack == nil {
			manager.Unlock()
			log.Printf("prewarm: failed to create tracks for %s", deviceIdentifier)
			return
		}
		broadcaster = &DeviceBroadcaster{
			VideoMimeType: webrtc.MimeTypeH264,
			VideoTrack:    videoTrack,
			AudioTrack:    audioTrack,
			Subscribers:   make(map[uint32]*Subscriber),
			RTPContinuity: sagent.NewRTPContinuity(),
			Prewarmed:     true,
		}
		manager.broadcasters[deviceIdentifier] = broadcaster
	} else {
		// An allowed Android device remains a prewarm target even if this
		// broadcaster was originally created by a subscriber during a device
		// outage. This also protects a successfully repaired resident Agent from
		// the ordinary idle-broadcaster reaper.
		broadcaster.Prewarmed = true
	}
	manager.Unlock()

	broadcaster.AgentLock.Lock()
	if time.Now().Before(broadcaster.RecoveryNotBefore) {
		broadcaster.AgentLock.Unlock()
		return
	}
	broadcaster.Lock.RLock()
	hasSubscribers := len(broadcaster.Subscribers) != 0
	hasPendingSetups := broadcaster.pendingSubscriberSetups != 0
	broadcaster.Lock.RUnlock()
	if hasSubscribers || hasPendingSetups {
		broadcaster.AgentLock.Unlock()
		return
	}

	if current := broadcaster.Agent; current != nil {
		select {
		case <-current.Done():
			// watchSharedAgent normally clears this pointer. Handle the small
			// scheduling window where the terminal Agent is still installed so a
			// prewarm tick cannot mistake it for a healthy resident capture.
			if current.Err() != nil {
				recordAgentRecoveryFailureLocked(broadcaster, current, current.Err())
				manager.recordTransportFailure(broadcaster.AgentConfig, current)
			}
			broadcaster.Agent = nil
			log.Printf(
				"prewarm: replacing terminal agent for %s generation=%d error=%v",
				deviceIdentifier,
				broadcaster.AgentGeneration,
				current.Err(),
			)
			if time.Now().Before(broadcaster.RecoveryNotBefore) {
				broadcaster.AgentLock.Unlock()
				return
			}
		default:
			broadcaster.AgentLock.Unlock()
			return
		}
	}

	err := manager.startAgentLocked(
		broadcaster,
		prewarmAgentConfig(deviceID),
		prewarmFinalCodec(),
		"prewarm",
	)
	broadcaster.AgentLock.Unlock()
	if err != nil {
		// Keep the broadcaster so the next online prewarm tick can retry in
		// place. Deleting it here can race a NewSubscriber that has already
		// attached to these shared tracks.
		log.Printf("prewarm: start agent for %s failed, will retry: %v", deviceIdentifier, err)
		return
	}
	log.Printf("prewarm: agent resident for %s", deviceIdentifier)
}

// PrewarmDevices keeps a resident scrcpy agent running for each allowed
// Android serial. Non-Android logical IDs are intentionally ignored.
func (manager *WebRTCManager) PrewarmDevices(serials []string) {
	managedSerials := make([]string, 0, len(serials))
	seen := make(map[string]struct{}, len(serials))
	for _, serial := range serials {
		serial = strings.TrimSpace(serial)
		if serial == "" || serial == sagent.IPHONE_USB_LOGICAL_DEVICE_ID {
			continue
		}
		if _, exists := seen[serial]; exists {
			continue
		}
		seen[serial] = struct{}{}
		managedSerials = append(managedSerials, serial)
	}
	manager.registerManagedAndroidSerials(managedSerials)
	for _, serial := range managedSerials {
		go manager.prewarmLoop(serial)
	}
}

func (manager *WebRTCManager) prewarmLoop(serial string) {
	deviceIdentifier := sagent.DEVICE_TYPE_ANDROID + "_" + serial + "_0_0"
	for {
		if serial == tripathPilotDevice {
			if _, err := readTripathPilotConfig(); err == nil {
				// The pilot owns a single phone encoder shared by its three lanes.
				// Normal fallback capture remains available on subscriber demand.
				time.Sleep(15 * time.Second)
				continue
			}
		}
		manager.adbRecoveryLease.RLock()
		online := manager.deviceOnline(serial)
		if online {
			manager.clearADBRecoveryObservation(serial)
			// Existence alone is insufficient: a zero-subscriber Agent can
			// terminate after a USB/ADB interruption while its prewarmed
			// broadcaster intentionally remains resident.
			manager.ensurePrewarmedDeviceWithRecoveryLease(deviceIdentifier, serial)
		}
		manager.adbRecoveryLease.RUnlock()
		if !online {
			manager.observeUnclaimedADBInterface(serial)
		}
		time.Sleep(15 * time.Second)
	}
}

func (manager *WebRTCManager) deviceOnline(serial string) bool {
	devices, err := scrcpy.GetConnectedDevices()
	if err != nil {
		return false
	}
	for _, device := range devices {
		if device == serial {
			return true
		}
	}
	return false
}
