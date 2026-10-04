package webservice

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"sync"
	"time"
	"webscreen/sdriver/scrcpy"

	sagent "webscreen/streamAgent"

	"github.com/pion/webrtc/v4"
)

const (
	agentRecoveryMaxBackoff   = 30 * time.Second
	agentRecoveryStableWindow = 2 * time.Minute
)

func nextAvailableReceipt(
	subscribers map[uint32]*Subscriber,
	start uint32,
) (uint32, bool) {
	for offset := uint32(0); offset < MAX_CLIENTS_PER_DEVICE; offset++ {
		candidate := (start + offset) % MAX_CLIENTS_PER_DEVICE
		if subscribers[candidate] == nil {
			return candidate, true
		}
	}
	return 0, false
}

func cloneAgentConfig(config sagent.AgentConfig) sagent.AgentConfig {
	cloned := config
	cloned.DriverConfig = make(map[string]string, len(config.DriverConfig))
	for key, value := range config.DriverConfig {
		cloned.DriverConfig[key] = value
	}
	return cloned
}

func agentConfigsEquivalent(
	current sagent.AgentConfig,
	requested sagent.AgentConfig,
) bool {
	if current.DeviceType != requested.DeviceType ||
		current.DeviceID != requested.DeviceID ||
		current.AVSync != requested.AVSync ||
		current.UseLocalTimestamp != requested.UseLocalTimestamp {
		return false
	}

	keys := []string{
		"video_codec",
		"video_encoder",
		"video_bit_rate",
		"video_codec_options",
		"max_size",
		"max_fps",
		"audio",
		"audio_bit_rate",
		"audio_source",
		"control",
		"console_url",
		"no_video_codec_options",
		"new_display",
		"resolution",
	}
	for _, key := range keys {
		if current.DriverConfig[key] != requested.DriverConfig[key] {
			return false
		}
	}
	return true
}

func (manager *WebRTCManager) ensureAgent(
	deviceIdentifier string,
	receiptNo uint32,
	requestedConfig sagent.AgentConfig,
) error {
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
		return fmt.Errorf("subscriber disconnected before agent initialization")
	}
	finalCodec, err := WaitAndGetFinalCodecParams(sub.PeerConnection)
	if err != nil {
		return fmt.Errorf("negotiate shared video codec: %w", err)
	}

	broadcaster.AgentLock.Lock()
	defer broadcaster.AgentLock.Unlock()

	if broadcaster.Agent == nil {
		return manager.startAgentLocked(
			broadcaster,
			requestedConfig,
			finalCodec,
			"initial",
		)
	}
	if requestedConfig.PreviewOnly {
		return nil
	}
	if agentConfigsEquivalent(broadcaster.AgentConfig, requestedConfig) {
		// A local preview may be the subscriber that initially created the
		// single source. The first real remote session takes ownership of the
		// profile metadata without restarting an equivalent encoder.
		if broadcaster.AgentConfig.PreviewOnly {
			adoptedConfig := cloneAgentConfig(requestedConfig)
			adoptedConfig.DriverConfig["webrtc_codec_level"] =
				broadcaster.AgentConfig.DriverConfig["webrtc_codec_level"]
			adoptedConfig.DriverConfig["deviceID"] =
				broadcaster.AgentConfig.DriverConfig["deviceID"]
			for _, key := range []string{"adb_transport_id", "adb_transport_kind"} {
				adoptedConfig.DriverConfig[key] = broadcaster.AgentConfig.DriverConfig[key]
			}
			broadcaster.AgentConfig = adoptedConfig
			manager.broadcastAgentState(
				broadcaster,
				"agent_profile_adopted",
				broadcaster.AgentGeneration,
				requestedConfig.StreamProfile,
				"",
			)
		}
		return nil
	}
	if broadcaster.AgentConfig.DriverConfig["video_codec"] !=
		requestedConfig.DriverConfig["video_codec"] {
		return fmt.Errorf(
			"cannot change the codec of an active shared track from %s to %s",
			broadcaster.AgentConfig.DriverConfig["video_codec"],
			requestedConfig.DriverConfig["video_codec"],
		)
	}
	return manager.restartAgentLocked(
		broadcaster,
		requestedConfig,
		finalCodec,
	)
}

func (manager *WebRTCManager) startAgentLocked(
	broadcaster *DeviceBroadcaster,
	config sagent.AgentConfig,
	finalCodec webrtc.RTPCodecParameters,
	reason string,
) error {
	config = cloneAgentConfig(config)
	if err := manager.prepareTransportConfig(&config, reason); err != nil {
		return err
	}
	if time.Now().Before(broadcaster.RecoveryNotBefore) {
		return fmt.Errorf("device capture recovery cooling down for %s", time.Until(broadcaster.RecoveryNotBefore).Round(time.Second))
	}
	agent := sagent.NewWithRTPContinuity(
		config,
		broadcaster.VideoTrack,
		broadcaster.AudioTrack,
		broadcaster.RTPContinuity,
	)
	if err := agent.InitDriver(finalCodec); err != nil {
		manager.recordTransportFailure(config, nil)
		return fmt.Errorf("initialize device driver: %w", err)
	}

	nextGeneration := broadcaster.AgentGeneration + 1
	if config.DeviceType == sagent.DEVICE_TYPE_IPHONE_USB {
		manager.transitionMicrophoneAgentLocked(
			broadcaster,
			broadcaster.Agent,
			nextGeneration,
			"agent_started",
		)
	}
	broadcaster.Agent = agent
	broadcaster.AgentConfig = config
	broadcaster.FinalCodec = finalCodec
	broadcaster.AgentGeneration = nextGeneration
	manager.recordTransportActive(config, agent, nextGeneration)
	generation := nextGeneration
	if reason != "auto_recovery" && reason != "prewarm" && reason != "initial" {
		broadcaster.RecoveryFailures = 0
	}
	broadcaster.RecoveryNotBefore = time.Time{}
	manager.attachFrameObserversLocked(broadcaster, agent)

	agent.Start()
	go manager.forwardAgentFeedback(broadcaster, agent, generation)
	go manager.forwardMicrophoneStatus(broadcaster, agent, generation)
	go manager.forwardMicrophoneDemand(broadcaster, agent, generation)
	go manager.watchSharedAgent(
		broadcaster,
		agent,
		generation,
		config.DeviceType,
	)
	log.Printf(
		"shared_agent_started generation=%d profile=%q reason=%q",
		generation,
		config.StreamProfile,
		reason,
	)
	manager.broadcastAgentState(
		broadcaster,
		"agent_active",
		generation,
		config.StreamProfile,
		"",
	)
	return nil
}

func (manager *WebRTCManager) watchSharedAgent(
	broadcaster *DeviceBroadcaster,
	agent *sagent.Agent,
	generation uint64,
	deviceType string,
) {
	<-agent.Done()
	terminalErr := agent.Err()
	if terminalErr == nil {
		return
	}
	manager.recoverSharedAgent(
		broadcaster,
		agent,
		generation,
		deviceType,
		terminalErr,
	)
}

func (manager *WebRTCManager) recoverSharedAgent(
	broadcaster *DeviceBroadcaster,
	failedAgent *sagent.Agent,
	failedGeneration uint64,
	deviceType string,
	terminalErr error,
) {
	if deviceType == sagent.DEVICE_TYPE_ANDROID {
		manager.adbRecoveryLease.RLock()
	}
	broadcaster.AgentLock.Lock()
	if broadcaster.Agent != failedAgent ||
		broadcaster.AgentGeneration != failedGeneration {
		broadcaster.AgentLock.Unlock()
		if deviceType == sagent.DEVICE_TYPE_ANDROID {
			manager.adbRecoveryLease.RUnlock()
		}
		return
	}

	recordAgentRecoveryFailureLocked(broadcaster, failedAgent, terminalErr)
	manager.recordTransportFailure(broadcaster.AgentConfig, failedAgent)
	attempt := broadcaster.RecoveryFailures
	config := cloneAgentConfig(broadcaster.AgentConfig)
	finalCodec := broadcaster.FinalCodec

	// Clear the pointer immediately so controls and new subscribers never
	// mistake a terminated Agent for a healthy shared capture.
	if broadcaster.AgentConfig.DeviceType == sagent.DEVICE_TYPE_IPHONE_USB {
		manager.transitionMicrophoneAgentLocked(
			broadcaster,
			failedAgent,
			failedGeneration+1,
			"agent_failed",
		)
	}
	broadcaster.Agent = nil
	manager.broadcastAgentState(
		broadcaster,
		"agent_failed",
		failedGeneration,
		config.StreamProfile,
		terminalErr.Error(),
	)
	broadcaster.AgentLock.Unlock()
	if deviceType == sagent.DEVICE_TYPE_ANDROID {
		manager.adbRecoveryLease.RUnlock()
	}

	for {
		delay := agentRecoveryBackoff(attempt)
		if errors.Is(terminalErr, scrcpy.ErrVideoStartupTimeout) {
			delay = videoStartupRecoveryBackoff(attempt)
		}
		log.Printf(
			"shared_agent_recovery_scheduled generation=%d attempt=%d delay=%s error=%q",
			failedGeneration,
			attempt,
			delay,
			terminalErr,
		)
		timer := time.NewTimer(delay)
		<-timer.C
		timer.Stop()

		if deviceType == sagent.DEVICE_TYPE_ANDROID {
			manager.adbRecoveryLease.RLock()
		}
		broadcaster.AgentLock.Lock()
		if broadcaster.Agent != nil ||
			broadcaster.AgentGeneration != failedGeneration {
			broadcaster.AgentLock.Unlock()
			if deviceType == sagent.DEVICE_TYPE_ANDROID {
				manager.adbRecoveryLease.RUnlock()
			}
			return
		}
		broadcaster.Lock.RLock()
		subscriberCount := len(broadcaster.Subscribers)
		broadcaster.Lock.RUnlock()
		if subscriberCount == 0 {
			broadcaster.AgentLock.Unlock()
			if deviceType == sagent.DEVICE_TYPE_ANDROID {
				manager.adbRecoveryLease.RUnlock()
			}
			log.Printf(
				"shared_agent_recovery_cancelled generation=%d reason=%q",
				failedGeneration,
				"no_subscribers",
			)
			return
		}

		manager.broadcastAgentState(
			broadcaster,
			"agent_recovering",
			failedGeneration+1,
			config.StreamProfile,
			"",
		)
		restartErr := manager.startAgentLocked(
			broadcaster,
			config,
			finalCodec,
			"auto_recovery",
		)
		if restartErr == nil {
			broadcaster.AgentLock.Unlock()
			if deviceType == sagent.DEVICE_TYPE_ANDROID {
				manager.adbRecoveryLease.RUnlock()
			}
			return
		}

		broadcaster.RecoveryFailures++
		attempt = broadcaster.RecoveryFailures
		manager.broadcastAgentState(
			broadcaster,
			"agent_recovery_failed",
			failedGeneration+1,
			config.StreamProfile,
			restartErr.Error(),
		)
		broadcaster.AgentLock.Unlock()
		if deviceType == sagent.DEVICE_TYPE_ANDROID {
			manager.adbRecoveryLease.RUnlock()
		}
		terminalErr = restartErr
	}
}

// Called with AgentLock held, including when prewarm observes a terminated
// agent before its watcher acquires the lock. The pointer/generation check
// in the watcher makes these two paths mutually exclusive.
func recordAgentRecoveryFailureLocked(broadcaster *DeviceBroadcaster, agent *sagent.Agent, terminalErr error) {
	if startedAt, ok := agent.StartedAt(); ok && time.Since(startedAt) >= agentRecoveryStableWindow {
		broadcaster.RecoveryFailures = 0
	}
	broadcaster.RecoveryFailures++
	if errors.Is(terminalErr, scrcpy.ErrVideoStartupTimeout) {
		broadcaster.RecoveryNotBefore = time.Now().Add(videoStartupRecoveryBackoff(broadcaster.RecoveryFailures))
	}
}

func videoStartupRecoveryBackoff(attempt uint32) time.Duration {
	switch attempt {
	case 0, 1:
		return time.Second
	case 2:
		return 5 * time.Second
	case 3:
		return 30 * time.Second
	default:
		return 2 * time.Minute
	}
}

func agentRecoveryBackoff(attempt uint32) time.Duration {
	if attempt == 0 {
		attempt = 1
	}
	delay := time.Second
	for step := uint32(1); step < attempt; step++ {
		if delay >= agentRecoveryMaxBackoff/2 {
			return agentRecoveryMaxBackoff
		}
		delay *= 2
	}
	if delay > agentRecoveryMaxBackoff {
		return agentRecoveryMaxBackoff
	}
	return delay
}

func (manager *WebRTCManager) restartAgentLocked(
	broadcaster *DeviceBroadcaster,
	requestedConfig sagent.AgentConfig,
	finalCodec webrtc.RTPCodecParameters,
) error {
	oldAgent := broadcaster.Agent
	oldConfig := cloneAgentConfig(broadcaster.AgentConfig)
	oldCodec := broadcaster.FinalCodec
	nextGeneration := broadcaster.AgentGeneration + 1

	manager.broadcastAgentState(
		broadcaster,
		"agent_restarting",
		nextGeneration,
		requestedConfig.StreamProfile,
		"",
	)
	if oldConfig.DeviceType == sagent.DEVICE_TYPE_IPHONE_USB ||
		requestedConfig.DeviceType == sagent.DEVICE_TYPE_IPHONE_USB {
		manager.transitionMicrophoneAgentLocked(
			broadcaster,
			oldAgent,
			nextGeneration,
			"agent_restarting",
		)
	}
	broadcaster.Agent = nil
	if oldAgent != nil {
		oldAgent.Close()
	}

	if err := manager.startAgentLocked(
		broadcaster,
		requestedConfig,
		finalCodec,
		"profile_change",
	); err == nil {
		return nil
	} else {
		restartErr := err
		log.Printf(
			"shared_agent_restart_failed requested_profile=%q error=%q",
			requestedConfig.StreamProfile,
			restartErr,
		)
		manager.broadcastAgentState(
			broadcaster,
			"agent_restart_failed",
			nextGeneration,
			requestedConfig.StreamProfile,
			restartErr.Error(),
		)
		if rollbackErr := manager.startAgentLocked(
			broadcaster,
			oldConfig,
			oldCodec,
			"rollback",
		); rollbackErr != nil {
			return fmt.Errorf(
				"restart shared agent: %v; rollback failed: %v",
				restartErr,
				rollbackErr,
			)
		}
		return fmt.Errorf(
			"restart shared agent with requested profile: %w; previous profile restored",
			restartErr,
		)
	}
}

func (manager *WebRTCManager) attachFrameObserversLocked(
	broadcaster *DeviceBroadcaster,
	agent *sagent.Agent,
) {
	broadcaster.Lock.RLock()
	subscribers := make([]*Subscriber, 0, len(broadcaster.Subscribers))
	for _, sub := range broadcaster.Subscribers {
		subscribers = append(subscribers, sub)
	}
	broadcaster.Lock.RUnlock()
	for _, sub := range subscribers {
		agent.AddFrameObserver(sub.frameObserverID, sub.handleVideoFrame)
	}
}

func (manager *WebRTCManager) forwardAgentFeedback(
	broadcaster *DeviceBroadcaster,
	agent *sagent.Agent,
	generation uint64,
) {
	for event := range agent.FeedbackEvents() {
		broadcaster.AgentLock.Lock()
		isCurrent := broadcaster.Agent == agent &&
			broadcaster.AgentGeneration == generation
		broadcaster.AgentLock.Unlock()
		if !isCurrent {
			return
		}
		broadcaster.Lock.RLock()
		subscribers := make([]*Subscriber, 0, len(broadcaster.Subscribers))
		for _, sub := range broadcaster.Subscribers {
			subscribers = append(subscribers, sub)
		}
		broadcaster.Lock.RUnlock()
		for _, sub := range subscribers {
			if err := sub.sendFeedback(event); err != nil {
				sub.telemetry.feedbackSendError.Add(1)
			}
		}
	}
}

func (manager *WebRTCManager) broadcastAgentState(
	broadcaster *DeviceBroadcaster,
	event string,
	generation uint64,
	profile string,
	errorMessage string,
) {
	payload := map[string]any{
		"event":           event,
		"generation":      generation,
		"streamProfile":   profile,
		"timestampUnixMs": time.Now().UnixMilli(),
	}
	if errorMessage != "" {
		payload["error"] = errorMessage
	}
	body, _ := json.Marshal(payload)
	log.Printf("agent_state payload=%s", body)

	broadcaster.Lock.RLock()
	subscribers := make([]*Subscriber, 0, len(broadcaster.Subscribers))
	for _, sub := range broadcaster.Subscribers {
		subscribers = append(subscribers, sub)
	}
	broadcaster.Lock.RUnlock()
	for _, sub := range subscribers {
		sub.sendJSONDiagnostics(payload)
	}
}

func (manager *WebRTCManager) currentAgent(
	deviceIdentifier string,
) (*sagent.Agent, *DeviceBroadcaster, bool) {
	agent, broadcaster, _, exists := manager.currentAgentEpoch(deviceIdentifier)
	return agent, broadcaster, exists
}

func (manager *WebRTCManager) currentAgentEpoch(
	deviceIdentifier string,
) (*sagent.Agent, *DeviceBroadcaster, uint64, bool) {
	manager.RLock()
	broadcaster, exists := manager.broadcasters[deviceIdentifier]
	manager.RUnlock()
	if !exists {
		return nil, nil, 0, false
	}
	broadcaster.AgentLock.Lock()
	agent := broadcaster.Agent
	generation := broadcaster.AgentGeneration
	broadcaster.AgentLock.Unlock()
	return agent, broadcaster, generation, agent != nil
}

const idrThrottleInterval = 3 * time.Second

var (
	idrThrottleMu   sync.Mutex
	idrThrottleLast = map[string]time.Time{}
)

func (manager *WebRTCManager) requestIDR(deviceIdentifier string) {
	now := time.Now()
	idrThrottleMu.Lock()
	last, seen := idrThrottleLast[deviceIdentifier]
	if seen && now.Sub(last) < idrThrottleInterval {
		idrThrottleMu.Unlock()
		return
	}
	idrThrottleLast[deviceIdentifier] = now
	idrThrottleMu.Unlock()
	agent, _, exists := manager.currentAgent(deviceIdentifier)
	if exists {
		agent.PLIRequest()
	}
}

func (manager *WebRTCManager) agentRuntimeInfo(
	deviceIdentifier string,
) (string, uint64, bool) {
	manager.RLock()
	broadcaster, exists := manager.broadcasters[deviceIdentifier]
	manager.RUnlock()
	if !exists {
		return "", 0, false
	}
	broadcaster.AgentLock.Lock()
	defer broadcaster.AgentLock.Unlock()
	return broadcaster.AgentConfig.StreamProfile,
		broadcaster.AgentGeneration,
		broadcaster.Agent != nil
}
