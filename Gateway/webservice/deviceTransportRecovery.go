package webservice

import (
	"log"
	"time"

	sagent "webscreen/streamAgent"

	"github.com/pion/webrtc/v4"
)

// scheduleMissingTransportRecovery is called with broadcaster.AgentLock held.
// A failed InitDriver has no live Agent/watcher, and ordinary prewarm skips
// broadcasters that still have viewers. Explicitly keep that capture eligible
// for recovery without rebuilding its subscribers or touching another phone.
func (manager *WebRTCManager) scheduleMissingTransportRecovery(serial string, broadcaster *DeviceBroadcaster) {
	if !isWirelessManaged(serial) || broadcaster.Agent != nil {
		return
	}
	generation := broadcaster.AgentGeneration
	if broadcaster.transportRecoveryScheduled && broadcaster.transportRecoveryGeneration == generation {
		return
	}
	config := cloneAgentConfig(broadcaster.AgentConfig)
	codec := broadcaster.FinalCodec
	if config.DeviceID == "" {
		config, codec = prewarmAgentConfig(serial), prewarmFinalCodec()
	}
	broadcaster.transportRecoveryScheduled = true
	broadcaster.transportRecoveryGeneration = generation
	go manager.retryMissingTransportRecovery(serial, broadcaster, generation, config, codec,
		manager.startAgentLocked, func(delay time.Duration) bool {
			timer := time.NewTimer(delay)
			defer timer.Stop()
			<-timer.C
			return true
		})
}

func missingTransportRecoveryDelay(attempt uint64) time.Duration {
	switch attempt {
	case 0:
		return time.Second
	case 1:
		return 5 * time.Second
	case 2:
		return 15 * time.Second
	default:
		return 30 * time.Second
	}
}

// The injected wait/start operations make retry ordering testable without real
// time delays or any Android commands. start is called with the ordinary ADB
// read lease and AgentLock held. Successful starts resume the normal watcher.
func (manager *WebRTCManager) retryMissingTransportRecovery(
	serial string,
	expected *DeviceBroadcaster,
	generation uint64,
	config sagent.AgentConfig,
	codec webrtc.RTPCodecParameters,
	start func(*DeviceBroadcaster, sagent.AgentConfig, webrtc.RTPCodecParameters, string) error,
	wait func(time.Duration) bool,
) {
	defer func() {
		expected.AgentLock.Lock()
		if expected.transportRecoveryGeneration == generation {
			expected.transportRecoveryScheduled = false
		}
		expected.AgentLock.Unlock()
	}()
	key := sagent.DEVICE_TYPE_ANDROID + "_" + serial + "_0_0"
	for attempt := uint64(0); ; attempt++ {
		if !wait(missingTransportRecoveryDelay(attempt)) {
			return
		}
		manager.adbRecoveryLease.RLock()
		manager.RLock()
		if manager.broadcasters[key] != expected {
			manager.RUnlock()
			manager.adbRecoveryLease.RUnlock()
			return
		}
		// A switch may hold this device lock while waiting for a picture. Do
		// not retain the manager read lock across that wait and stall setup
		// for other devices; a later retry will inspect this capture again.
		if !expected.AgentLock.TryLock() {
			manager.RUnlock()
			manager.adbRecoveryLease.RUnlock()
			continue
		}
		manager.RUnlock()
		if expected.Agent != nil || expected.AgentGeneration != generation ||
			!expected.transportRecoveryScheduled || expected.transportRecoveryGeneration != generation {
			expected.AgentLock.Unlock()
			manager.adbRecoveryLease.RUnlock()
			return
		}
		// Do not skip active or pending subscribers: they are precisely the
		// sessions that the idle-only prewarm loop cannot repair. Each retry
		// resolves a fresh transport using the restored preference.
		err := start(expected, cloneAgentConfig(config), codec, "auto_recovery")
		if err != nil {
			expected.RecoveryFailures++
		}
		expected.AgentLock.Unlock()
		manager.adbRecoveryLease.RUnlock()
		if err == nil {
			log.Printf("transport_missing_agent_recovered device=%q previous_generation=%d attempt=%d", serial, generation, attempt+1)
			return
		}
		log.Printf("transport_missing_agent_retry device=%q generation=%d attempt=%d error=%q", serial, generation, attempt+1, err)
	}
}
