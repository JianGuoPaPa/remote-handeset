package utils

import "sync"

// adbServerMaintenanceGate coordinates the short cleanup commands issued by
// terminating scrcpy drivers with a process-wide adb server restart. Long-lived
// adb shell transports intentionally do not hold this gate.
var adbServerMaintenanceGate sync.RWMutex

// BeginADBServerMaintenance waits for bounded cleanup commands already in
// flight and prevents new cleanup commands from running until the returned
// function is called.
func BeginADBServerMaintenance() func() {
	adbServerMaintenanceGate.Lock()
	return adbServerMaintenanceGate.Unlock
}

// BeginADBServerCleanup protects a bounded adb cleanup sequence from a
// concurrent kill-server/start-server cycle.
func BeginADBServerCleanup() func() {
	adbServerMaintenanceGate.RLock()
	return adbServerMaintenanceGate.RUnlock
}
