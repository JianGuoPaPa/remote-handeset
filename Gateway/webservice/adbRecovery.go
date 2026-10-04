package webservice

import (
	"log"
	"strings"
	"time"

	sagent "webscreen/streamAgent"
)

const (
	adbRecoveryRequiredObservations = 3
	adbRecoveryGlobalCooldown       = 30 * time.Minute
	adbRecoveryRestoreAttempts      = 10
	adbRecoveryRestoreInterval      = 2 * time.Second
)

type adbRecoveryObservation struct {
	entryID              uint64
	consecutive          uint8
	lastAttemptedEntryID uint64
}

type adbRecoveryState struct {
	managedSerials map[string]struct{}
	observations   map[string]adbRecoveryObservation
	lastRestartAt  time.Time
	budgetLoaded   bool
	budgetError    error
	lastAttempts   map[string]time.Time
}

func (manager *WebRTCManager) registerManagedAndroidSerials(serials []string) {
	manager.adbRecoveryMu.Lock()
	defer manager.adbRecoveryMu.Unlock()
	for _, serial := range serials {
		serial = strings.TrimSpace(serial)
		if serial == "" {
			continue
		}
		manager.adbRecovery.managedSerials[serial] = struct{}{}
	}
	manager.loadADBRecoveryBudgetLocked()
}

func (manager *WebRTCManager) managedAndroidSerials() []string {
	manager.adbRecoveryMu.Lock()
	defer manager.adbRecoveryMu.Unlock()
	serials := make([]string, 0, len(manager.adbRecovery.managedSerials))
	for serial := range manager.adbRecovery.managedSerials {
		serials = append(serials, serial)
	}
	return serials
}

func (manager *WebRTCManager) clearADBRecoveryObservation(serial string) {
	manager.adbRecoveryMu.Lock()
	observation := manager.adbRecovery.observations[serial]
	observation.entryID = 0
	observation.consecutive = 0
	manager.adbRecovery.observations[serial] = observation
	manager.adbRecoveryMu.Unlock()
}

// adbRecoverySafe is called only while the write side of adbRecoveryLease is
// held. NewSubscriber cannot add pending work or subscribers during this scan.
// Conservatively protect every real session, including iPhone sessions. The
// matching host watchdog also delegates returned-device repair to this manager
// instead of reloading the whole gateway after the maintenance lease is freed.
// Local preview-only sessions are deliberately allowed to self-recover.
func (manager *WebRTCManager) adbRecoverySafe() (bool, string) {
	manager.RLock()
	defer manager.RUnlock()
	for _, broadcaster := range manager.broadcasters {
		broadcaster.Lock.RLock()
		pending := broadcaster.pendingSubscriberSetups
		hasRealSubscriber := false
		for _, subscriber := range broadcaster.Subscribers {
			if subscriber != nil && !subscriber.requestedConfig.PreviewOnly {
				hasRealSubscriber = true
				break
			}
		}
		broadcaster.Lock.RUnlock()
		if pending != 0 {
			return false, "pending_subscriber_setup"
		}
		if hasRealSubscriber {
			return false, "active_remote_subscriber"
		}
	}
	return true, ""
}

// restorePrewarmedAfterADBRestart repairs resident Android capture agents on
// their existing broadcaster/tracks after adb is restarted. AgentLock is never
// taken by the recovery writer; restoration starts only after the write lease
// has been released and uses the normal read-side setup path.
func (manager *WebRTCManager) restorePrewarmedAfterADBRestart(entryID uint64) {
	serials := manager.managedAndroidSerials()
	if len(serials) == 0 {
		return
	}
	go func() {
		for attempt := 1; attempt <= adbRecoveryRestoreAttempts; attempt++ {
			for _, serial := range serials {
				manager.adbRecoveryLease.RLock()
				if manager.deviceOnline(serial) {
					deviceIdentifier := sagent.DEVICE_TYPE_ANDROID + "_" + serial + "_0_0"
					manager.ensurePrewarmedDeviceWithRecoveryLease(deviceIdentifier, serial)
				}
				manager.adbRecoveryLease.RUnlock()
			}
			if attempt < adbRecoveryRestoreAttempts {
				time.Sleep(adbRecoveryRestoreInterval)
			}
		}
		log.Printf("adb_recovery_prewarm_restore_sweep_finished entry_id=%d", entryID)
	}()
}
