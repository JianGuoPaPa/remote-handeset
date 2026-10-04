//go:build !darwin

package webservice

// macOS is the only supported host for IORegistry-based ADB USB interface
// recovery. Other platforms retain their existing prewarm behavior.
func (manager *WebRTCManager) observeUnclaimedADBInterface(serial string) {}
