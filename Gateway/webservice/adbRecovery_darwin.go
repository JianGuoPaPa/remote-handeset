//go:build darwin

package webservice

import (
	"bytes"
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"webscreen/utils"
)

const (
	adbRecoveryProbeTimeout   = 5 * time.Second
	adbRecoveryCommandTimeout = 12 * time.Second
	adbRecoveryAttemptTimeout = 45 * time.Second
	adbInterfaceName          = "ADB Interface"
	adbUnclaimedOwner         = "none"
)

type adbInterfaceProbe struct {
	found   bool
	entryID uint64
	owner   string
}

func (probe adbInterfaceProbe) recoverable() bool {
	// macOS omits UsbExclusiveOwner on some never-claimed/stalled interfaces.
	// A present but invalid owner is rejected by inspectADBInterface; an actual
	// named owner always blocks recovery. The helper checks the live interface
	// generation/ownership again immediately before a non-seizing device open.
	return probe.found && probe.entryID != 0 &&
		(probe.owner == "" || strings.EqualFold(strings.TrimSpace(probe.owner), adbUnclaimedOwner))
}

func (manager *WebRTCManager) observeUnclaimedADBInterface(serial string) {
	manager.adbRecoveryLease.RLock()
	adbPath, probe, eligible := manager.probeUnclaimedADBInterface(serial)
	manager.adbRecoveryLease.RUnlock()
	if !eligible {
		return
	}

	consecutive, ready, wait := manager.recordADBRecoveryObservation(serial, probe.entryID)
	if consecutive == 1 || consecutive == adbRecoveryRequiredObservations {
		log.Printf(
			"adb_recovery_unclaimed_observed serial=%q entry_id=%d consecutive=%d",
			serial,
			probe.entryID,
			consecutive,
		)
	}
	if !ready {
		if wait > 0 && consecutive == adbRecoveryRequiredObservations {
			log.Printf(
				"adb_recovery_deferred serial=%q entry_id=%d reason=%q retry_after=%s",
				serial,
				probe.entryID,
				"device_cooldown",
				wait.Round(time.Second),
			)
		}
		return
	}
	manager.recoverUnclaimedADBInterface(serial, probe.entryID, adbPath)
}

func (manager *WebRTCManager) probeUnclaimedADBInterface(
	serial string,
) (string, adbInterfaceProbe, bool) {
	adbPath, err := absoluteADBPath()
	if err != nil {
		manager.clearADBRecoveryObservation(serial)
		log.Printf("adb_recovery_probe_skipped serial=%q reason=%q", serial, err)
		return "", adbInterfaceProbe{}, false
	}

	ctx, cancel := context.WithTimeout(context.Background(), adbRecoveryProbeTimeout)
	devices, err := adbDeviceSet(ctx, adbPath)
	cancel()
	if err != nil {
		manager.clearADBRecoveryObservation(serial)
		log.Printf("adb_recovery_probe_skipped serial=%q reason=%q", serial, err)
		return "", adbInterfaceProbe{}, false
	}
	if _, present := devices[serial]; present {
		// In particular, do not reset a phone awaiting the user's RSA approval.
		manager.clearADBRecoveryObservation(serial)
		return "", adbInterfaceProbe{}, false
	}
	if !manager.hasOtherManagedADBDevice(serial, devices) {
		// A process-wide adb outage belongs to the host watchdog. The embedded
		// recovery path only repairs one unclaimed USB interface while another
		// managed device proves that the current adb server is alive.
		manager.clearADBRecoveryObservation(serial)
		return "", adbInterfaceProbe{}, false
	}

	ctx, cancel = context.WithTimeout(context.Background(), adbRecoveryProbeTimeout)
	probe, err := inspectADBInterface(ctx, serial)
	cancel()
	if err != nil {
		manager.clearADBRecoveryObservation(serial)
		log.Printf("adb_recovery_ioreg_rejected serial=%q reason=%q", serial, err)
		return "", adbInterfaceProbe{}, false
	}
	if !probe.recoverable() {
		manager.clearADBRecoveryObservation(serial)
		return "", adbInterfaceProbe{}, false
	}
	return adbPath, probe, true
}

func (manager *WebRTCManager) recordADBRecoveryObservation(
	serial string,
	entryID uint64,
) (uint8, bool, time.Duration) {
	manager.adbRecoveryMu.Lock()
	defer manager.adbRecoveryMu.Unlock()

	observation := manager.adbRecovery.observations[serial]
	if observation.entryID != entryID {
		observation.entryID = entryID
		observation.consecutive = 1
	} else if observation.consecutive < adbRecoveryRequiredObservations {
		observation.consecutive++
	}
	manager.adbRecovery.observations[serial] = observation
	if manager.adbRecovery.budgetError != nil {
		return observation.consecutive, false, 0
	}

	if observation.consecutive < adbRecoveryRequiredObservations ||
		observation.lastAttemptedEntryID == entryID {
		return observation.consecutive, false, 0
	}
	if last := manager.adbRecovery.lastAttempts[serial]; !last.IsZero() {
		remaining := adbRecoveryGlobalCooldown - time.Since(last)
		if remaining > 0 {
			return observation.consecutive, false, remaining
		}
	}
	return observation.consecutive, true, 0
}

func (manager *WebRTCManager) hasOtherManagedADBDevice(
	failedSerial string,
	devices map[string]string,
) bool {
	manager.adbRecoveryMu.Lock()
	defer manager.adbRecoveryMu.Unlock()
	for serial := range manager.adbRecovery.managedSerials {
		if serial == failedSerial {
			continue
		}
		if devices[serial] == "device" {
			return true
		}
	}
	return false
}

func (manager *WebRTCManager) recoverUnclaimedADBInterface(
	serial string,
	entryID uint64,
	adbPath string,
) {
	// Do not queue a disruptive restart behind live setup work. A later probe
	// will retry this generation after the current read-side lease is released.
	if !manager.adbRecoveryLease.TryLock() {
		log.Printf(
			"adb_recovery_deferred serial=%q entry_id=%d reason=%q",
			serial,
			entryID,
			"transport_busy",
		)
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), adbRecoveryAttemptTimeout)
	restore := false
	defer func() {
		cancel()
		manager.adbRecoveryLease.Unlock()
		if restore {
			manager.restorePrewarmedAfterADBRestart(entryID)
		}
	}()

	if safe, reason := manager.adbRecoverySafe(); !safe {
		log.Printf(
			"adb_recovery_deferred serial=%q entry_id=%d reason=%q",
			serial,
			entryID,
			reason,
		)
		return
	}

	// Re-check every destructive precondition under the write lease. This is
	// deliberately independent of the three observations made before TryLock.
	devices, err := adbDeviceSet(ctx, adbPath)
	if err != nil {
		log.Printf("adb_recovery_aborted serial=%q entry_id=%d reason=%q", serial, entryID, err)
		return
	}
	if _, present := devices[serial]; present {
		manager.clearADBRecoveryObservation(serial)
		return
	}
	if !manager.hasOtherManagedADBDevice(serial, devices) {
		log.Printf(
			"adb_recovery_aborted serial=%q entry_id=%d reason=%q",
			serial,
			entryID,
			"no_other_managed_device_online",
		)
		return
	}
	probe, err := inspectADBInterface(ctx, serial)
	if err != nil {
		log.Printf("adb_recovery_aborted serial=%q entry_id=%d reason=%q", serial, entryID, err)
		return
	}
	if !probe.recoverable() || probe.entryID != entryID {
		log.Printf(
			"adb_recovery_aborted serial=%q entry_id=%d reason=%q current_entry_id=%d owner=%q",
			serial,
			entryID,
			"ioreg_generation_changed",
			probe.entryID,
			probe.owner,
		)
		return
	}

	now := time.Now()
	manager.adbRecoveryMu.Lock()
	observation := manager.adbRecovery.observations[serial]
	if observation.entryID != entryID ||
		observation.consecutive < adbRecoveryRequiredObservations ||
		observation.lastAttemptedEntryID == entryID {
		manager.adbRecoveryMu.Unlock()
		return
	}
	if manager.adbRecovery.budgetError != nil ||
		now.Sub(manager.adbRecovery.lastAttempts[serial]) < adbRecoveryGlobalCooldown {
		manager.adbRecoveryMu.Unlock()
		return
	}
	// Persist before acting: neither a new USB generation nor a gateway restart
	// can cause an unbounded recovery loop on a damaged cable/device.
	observation.lastAttemptedEntryID = entryID
	manager.adbRecovery.observations[serial] = observation
	manager.adbRecovery.lastAttempts[serial] = now
	persistErr := manager.persistADBRecoveryBudgetLocked()
	manager.adbRecoveryMu.Unlock()
	if persistErr != nil {
		log.Printf("adb_recovery_disabled serial=%q reason=%q", serial, persistErr)
		return
	}

	log.Printf("adb_recovery_started serial=%q entry_id=%d owner=%q", serial, entryID, probe.owner)
	resetErr := reenumerateADBUSBDevice(ctx, serial, entryID)
	if resetErr != nil {
		log.Printf("adb_recovery_usb_failed serial=%q entry_id=%d error=%q", serial, entryID, resetErr)
	} else {
		restore = true
	}
	deviceState, err := waitForRecoveredADBDevice(ctx, adbPath, serial)
	if err != nil {
		log.Printf("adb_recovery_aborted serial=%q reason=%q", serial, err)
		return
	}
	if deviceState != "missing" {
		log.Printf("adb_recovery_result serial=%q stage=%q state=%q", serial, "usb_reenumerate", deviceState)
		return
	}

	// A single-device re-enumeration is preferred. Restart shared ADB only if
	// the interface still exists, remains unowned, and another device is online.
	devices, err = adbDeviceSet(ctx, adbPath)
	if err != nil || !manager.hasOtherManagedADBDevice(serial, devices) {
		log.Printf("adb_recovery_aborted serial=%q reason=%q", serial, "ADB health changed before restart")
		return
	}
	if _, present := devices[serial]; present {
		return
	}
	probe, err = inspectADBInterface(ctx, serial)
	if err != nil || !probe.recoverable() {
		log.Printf("adb_recovery_aborted serial=%q reason=%q", serial, "USB state changed before restart")
		return
	}
	manager.adbRecoveryMu.Lock()
	if time.Since(manager.adbRecovery.lastRestartAt) < adbRecoveryGlobalCooldown {
		manager.adbRecoveryMu.Unlock()
		log.Printf("adb_recovery_deferred serial=%q reason=%q", serial, "global_restart_cooldown")
		return
	}
	manager.adbRecovery.lastRestartAt = time.Now()
	persistErr = manager.persistADBRecoveryBudgetLocked()
	manager.adbRecoveryMu.Unlock()
	if persistErr != nil {
		log.Printf("adb_recovery_disabled serial=%q reason=%q", serial, persistErr)
		return
	}

	// A terminating scrcpy transport can issue bounded reverse/rm cleanup. The
	// maintenance lease drains any cleanup already running and prevents cleanup
	// from auto-starting adb between kill-server and start-server.
	releaseMaintenance := utils.BeginADBServerMaintenance()
	killErr := runADBRecoveryCommand(ctx, adbPath, "kill-server")
	startErr := runADBRecoveryCommand(ctx, adbPath, "start-server")
	releaseMaintenance()
	restore = true

	if err := errors.Join(killErr, startErr); err != nil {
		log.Printf(
			"adb_recovery_failed serial=%q entry_id=%d adb=%q error=%q",
			serial,
			entryID,
			adbPath,
			err,
		)
		return
	}
	deviceState, err = waitForRecoveredADBDevice(ctx, adbPath, serial)
	if err != nil {
		log.Printf("adb_recovery_aborted serial=%q reason=%q", serial, err)
		return
	}
	if deviceState == "missing" {
		// Native ADB can retain a stale IOKit handle. After the old server has
		// exited, re-enumerate the freshly inspected target once more, not every
		// USB generation indefinitely. This is the sequence used on moto g53.
		fresh, probeErr := inspectADBInterface(ctx, serial)
		if probeErr == nil && fresh.recoverable() {
			if resetErr := reenumerateADBUSBDevice(ctx, serial, fresh.entryID); resetErr != nil {
				log.Printf("adb_recovery_usb_failed serial=%q entry_id=%d error=%q", serial, fresh.entryID, resetErr)
			} else {
				deviceState, err = waitForRecoveredADBDevice(ctx, adbPath, serial)
			}
		}
	}
	log.Printf("adb_recovery_result serial=%q stage=%q state=%q error=%v", serial, "adb_restart_and_usb", deviceState, err)
}

func reenumerateADBUSBDevice(ctx context.Context, serial string, entryID uint64) error {
	helper := strings.TrimSpace(os.Getenv("WEBSCREEN_USB_RECOVERY_HELPER"))
	if helper == "" || !filepath.IsAbs(helper) {
		return fmt.Errorf("USB recovery helper is not configured with an absolute path")
	}
	commandCtx, cancel := context.WithTimeout(ctx, 6*time.Second)
	defer cancel()
	output, err := exec.CommandContext(commandCtx, helper, serial, strconv.FormatUint(entryID, 10)).CombinedOutput()
	if err != nil {
		return fmt.Errorf("USB re-enumeration: %w (%s)", err, strings.TrimSpace(string(output)))
	}
	log.Printf("adb_recovery_usb_requested serial=%q entry_id=%d", serial, entryID)
	return nil
}

func waitForRecoveredADBDevice(ctx context.Context, adbPath, serial string) (string, error) {
	deadline := time.NewTimer(4 * time.Second)
	defer deadline.Stop()
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for {
		devices, err := adbDeviceSet(ctx, adbPath)
		if err != nil {
			return "unknown", err
		}
		if state, present := devices[serial]; present {
			return state, nil
		}
		select {
		case <-ctx.Done():
			return "unknown", ctx.Err()
		case <-deadline.C:
			return "missing", nil
		case <-ticker.C:
		}
	}
}

func absoluteADBPath() (string, error) {
	adbPath, err := utils.GetADBPath()
	if err != nil {
		return "", err
	}
	if filepath.IsAbs(adbPath) {
		return filepath.Clean(adbPath), nil
	}
	absolute, err := filepath.Abs(adbPath)
	if err != nil {
		return "", fmt.Errorf("resolve absolute adb path: %w", err)
	}
	return absolute, nil
}

func adbDeviceSet(ctx context.Context, adbPath string) (map[string]string, error) {
	commandCtx, cancel := context.WithTimeout(ctx, adbRecoveryProbeTimeout)
	defer cancel()
	output, err := exec.CommandContext(commandCtx, adbPath, "devices").CombinedOutput()
	if err != nil {
		if commandCtx.Err() != nil {
			return nil, fmt.Errorf("adb devices timed out: %w", commandCtx.Err())
		}
		return nil, fmt.Errorf("adb devices: %w (%s)", err, strings.TrimSpace(string(output)))
	}
	devices := make(map[string]string)
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && fields[0] != "List" && fields[0] != "*" {
			devices[fields[0]] = fields[1]
		}
	}
	return devices, nil
}

func runADBRecoveryCommand(ctx context.Context, adbPath string, args ...string) error {
	commandCtx, cancel := context.WithTimeout(ctx, adbRecoveryCommandTimeout)
	defer cancel()
	output, err := exec.CommandContext(commandCtx, adbPath, args...).CombinedOutput()
	if err == nil {
		return nil
	}
	if commandCtx.Err() != nil {
		return fmt.Errorf("adb %s timed out: %w", strings.Join(args, " "), commandCtx.Err())
	}
	return fmt.Errorf(
		"adb %s: %w (%s)",
		strings.Join(args, " "),
		err,
		strings.TrimSpace(string(output)),
	)
}

func inspectADBInterface(ctx context.Context, serial string) (adbInterfaceProbe, error) {
	commandCtx, cancel := context.WithTimeout(ctx, adbRecoveryProbeTimeout)
	defer cancel()
	output, err := exec.CommandContext(
		commandCtx,
		"/usr/sbin/ioreg",
		"-a",
		"-r",
		"-c",
		"IOUSBHostInterface",
		"-l",
		"-w",
		"0",
	).Output()
	if err != nil {
		if commandCtx.Err() != nil {
			return adbInterfaceProbe{}, fmt.Errorf("ioreg timed out: %w", commandCtx.Err())
		}
		return adbInterfaceProbe{}, fmt.Errorf("ioreg: %w", err)
	}

	entries, err := decodeIORegEntries(output)
	if err != nil {
		return adbInterfaceProbe{}, fmt.Errorf("parse ioreg plist: %w", err)
	}
	matches := make([]map[string]any, 0, 1)
	for _, entry := range entries {
		interfaceName, _ := entry["kUSBString"].(string)
		entrySerial, _ := entry["USB Serial Number"].(string)
		if strings.TrimSpace(interfaceName) == adbInterfaceName &&
			strings.TrimSpace(entrySerial) == serial &&
			entry["bInterfaceClass"] == uint64(255) &&
			entry["bInterfaceSubClass"] == uint64(66) &&
			entry["bInterfaceProtocol"] == uint64(1) {
			matches = append(matches, entry)
		}
	}
	if len(matches) == 0 {
		return adbInterfaceProbe{}, nil
	}
	if len(matches) != 1 {
		return adbInterfaceProbe{}, fmt.Errorf(
			"ambiguous ADB interface match for serial %q: %d entries",
			serial,
			len(matches),
		)
	}

	entryID, ok := matches[0]["IORegistryEntryID"].(uint64)
	if !ok || entryID == 0 {
		return adbInterfaceProbe{}, fmt.Errorf("ADB interface for serial %q has no valid IORegistryEntryID", serial)
	}
	owner := ""
	if raw, present := matches[0]["UsbExclusiveOwner"]; present {
		var valid bool
		owner, valid = raw.(string)
		if !valid || strings.TrimSpace(owner) == "" {
			return adbInterfaceProbe{}, fmt.Errorf("invalid USB owner property for serial %q", serial)
		}
	}
	return adbInterfaceProbe{found: true, entryID: entryID, owner: owner}, nil
}

func decodeIORegEntries(data []byte) ([]map[string]any, error) {
	decoder := xml.NewDecoder(bytes.NewReader(data))
	for {
		token, err := decoder.Token()
		if err != nil {
			return nil, err
		}
		start, ok := token.(xml.StartElement)
		if !ok || start.Name.Local != "array" {
			continue
		}
		value, err := decodePlistElement(decoder, start)
		if err != nil {
			return nil, err
		}
		items, ok := value.([]any)
		if !ok {
			return nil, fmt.Errorf("top-level plist value is not an array")
		}
		entries := make([]map[string]any, 0, len(items))
		for _, item := range items {
			entry, ok := item.(map[string]any)
			if !ok {
				return nil, fmt.Errorf("top-level plist array contains a non-dictionary value")
			}
			entries = append(entries, entry)
		}
		return entries, nil
	}
}

func decodePlistElement(decoder *xml.Decoder, start xml.StartElement) (any, error) {
	switch start.Name.Local {
	case "array":
		values := make([]any, 0)
		for {
			token, err := decoder.Token()
			if err != nil {
				return nil, err
			}
			switch value := token.(type) {
			case xml.StartElement:
				decoded, err := decodePlistElement(decoder, value)
				if err != nil {
					return nil, err
				}
				values = append(values, decoded)
			case xml.EndElement:
				if value.Name.Local == start.Name.Local {
					return values, nil
				}
			}
		}
	case "dict":
		values := make(map[string]any)
		key := ""
		for {
			token, err := decoder.Token()
			if err != nil {
				return nil, err
			}
			switch value := token.(type) {
			case xml.StartElement:
				decoded, err := decodePlistElement(decoder, value)
				if err != nil {
					return nil, err
				}
				if value.Name.Local == "key" {
					key, _ = decoded.(string)
					continue
				}
				if key == "" {
					return nil, fmt.Errorf("dictionary value has no key")
				}
				values[key] = decoded
				key = ""
			case xml.EndElement:
				if value.Name.Local == start.Name.Local {
					if key != "" {
						return nil, fmt.Errorf("dictionary key %q has no value", key)
					}
					return values, nil
				}
			}
		}
	case "key", "string", "data", "date", "real":
		var value string
		if err := decoder.DecodeElement(&value, &start); err != nil {
			return nil, err
		}
		return value, nil
	case "integer":
		var value string
		if err := decoder.DecodeElement(&value, &start); err != nil {
			return nil, err
		}
		integer, err := strconv.ParseUint(strings.TrimSpace(value), 10, 64)
		if err != nil {
			return nil, fmt.Errorf("invalid plist integer %q: %w", value, err)
		}
		return integer, nil
	case "true":
		if err := decoder.Skip(); err != nil {
			return nil, err
		}
		return true, nil
	case "false":
		if err := decoder.Skip(); err != nil {
			return nil, err
		}
		return false, nil
	default:
		if err := decoder.Skip(); err != nil {
			return nil, err
		}
		return nil, nil
	}
}
