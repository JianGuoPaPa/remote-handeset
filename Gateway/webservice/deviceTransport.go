package webservice

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	sagent "webscreen/streamAgent"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
	"github.com/pion/webrtc/v4"
)

// These are hardware identities, never addresses supplied by a controller.
// Inclusion permits discovery; capability still requires an installed, enabled
// guard and its per-device verified history. Existing guard paths remain stable.
var wirelessDeviceDirectories = map[string]string{
	"ZY22HN3ZS4":      "backup3-unattended",
	"ZY22F68DH8":      "white-motorola-unattended",
	"ZY22GHBP48":      "android-unattended/ZY22GHBP48",
	"ZY22K2SXMK":      "android-unattended/ZY22K2SXMK",
	"31629594940010K": "android-unattended/31629594940010K",
	"ZY22GDWXSZ":      "android-unattended/ZY22GDWXSZ",
	"10AD6F2LSY0017B": "android-unattended/10AD6F2LSY0017B",
}

const realTransportADB = "/opt/homebrew/bin/adb"

var transportProcessInstance = func() string {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		panic("cannot create gateway connection instance")
	}
	return hex.EncodeToString(value[:])
}()

type transportSelection struct {
	ID   string
	Kind string
}

type transportSnapshot struct {
	Configured bool
	USB        *transportSelection
	WiFi       *transportSelection
}

type deviceTransportState struct {
	Preference        string
	Phase             string
	LastError         string
	Active            *sagent.Agent
	Selection         transportSelection
	Generation        uint64
	FailedTransportID string
	VideoReady        <-chan struct{}
	ReadyObserved     bool
}

type DeviceConnectionStatus struct {
	InstanceID         string `json:"instance_id"`
	DeviceID           string `json:"device_id"`
	WirelessConfigured bool   `json:"wireless_configured"`
	USBAvailable       bool   `json:"usb_available"`
	WiFiAvailable      bool   `json:"wifi_available"`
	Preference         string `json:"preference"`
	ActiveTransport    string `json:"active_transport"`
	State              string `json:"state"`
	Generation         uint64 `json:"generation"`
	LastError          string `json:"last_error,omitempty"`
}

type transportRequest struct {
	Type               string  `json:"type"`
	RequestID          string  `json:"request_id"`
	DeviceID           string  `json:"device_id"`
	Preference         string  `json:"preference"`
	ExpectedGeneration *uint64 `json:"expected_generation,omitempty"`
	ExpectedInstanceID string  `json:"expected_instance_id,omitempty"`
}

type transportRPCResponse struct {
	Type       string                  `json:"type"`
	RequestID  string                  `json:"request_id"`
	Status     string                  `json:"status"`
	Message    string                  `json:"message,omitempty"`
	Connection *DeviceConnectionStatus `json:"connection,omitempty"`
}

type transportError struct {
	code    int
	message string
}

func (err *transportError) Error() string { return err.message }

func newTransportError(code int, message string) error {
	return &transportError{code: code, message: message}
}

func isWirelessManaged(serial string) bool {
	_, ok := wirelessDeviceDirectories[serial]
	return ok
}

type transportGuardEndpoint struct {
	Serial         string `json:"serial"`
	VerifiedSerial string `json:"verified_serial"`
	VerifiedAt     int64  `json:"verified_at"`
}

type transportGuardState struct {
	Enabled       bool                     `json:"enabled"`
	Serial        string                   `json:"serial"`
	Verified      []string                 `json:"verified_endpoints"`
	Rejected      []string                 `json:"rejected_endpoints"`
	WiFiEndpoints []transportGuardEndpoint `json:"wifi_endpoints"`
}

// A status file alone is not installation or enablement. The marker is emitted
// by the guard only after installation; stopping it must also disable the marker.
func readTransportGuardStatus(home, serial string) []byte {
	relative, known := wirelessDeviceDirectories[serial]
	if !known {
		return nil
	}
	directory := filepath.Join(home, ".remote-handset", relative)
	guard, err := os.Stat(filepath.Join(directory, "guard.py"))
	if err != nil || !guard.Mode().IsRegular() {
		return nil
	}
	data, _ := os.ReadFile(filepath.Join(directory, "status.json"))
	return data
}

func verifiedWirelessCandidates(data []byte, serial string) []string {
	var state transportGuardState
	if json.Unmarshal(data, &state) != nil || !state.Enabled || state.Serial != serial {
		return nil
	}
	// Preserve capability through a temporary outage, while requiring actual
	// historical Wi-Fi identity evidence rather than a guessed/cached address.
	verifiedIdentity := make(map[string]bool)
	for _, endpoint := range state.WiFiEndpoints {
		if endpoint.VerifiedSerial == serial && endpoint.VerifiedAt > 0 {
			verifiedIdentity[endpoint.Serial] = true
		}
	}
	rejected := make(map[string]bool)
	for _, endpoint := range state.Rejected {
		rejected[endpoint] = true
	}
	result := []string{}
	for index, endpoint := range state.Verified {
		if index >= 8 {
			break
		}
		host, port, err := net.SplitHostPort(endpoint)
		address := net.ParseIP(host)
		number, parseErr := strconv.Atoi(port)
		if err != nil || parseErr != nil || number <= 0 || number > 65535 ||
			address == nil || address.To4() == nil || address.IsLoopback() ||
			address.IsMulticast() || address.IsUnspecified() || rejected[endpoint] || !verifiedIdentity[endpoint] {
			continue
		}
		rejected[endpoint] = true // Also suppress duplicate cached candidates.
		result = append(result, endpoint)
	}
	return result
}

type transportADBRun func(context.Context, ...string) ([]byte, error)

func runTransportADB(ctx context.Context, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, realTransportADB, args...).Output()
}

// Reads transport identity only. It never connects to an address, changes phone
// settings, or invokes the CLI alias (whose devices output hides real links).
func inspectDeviceTransports(ctx context.Context, serial string, stateData []byte, run transportADBRun) (transportSnapshot, error) {
	result := transportSnapshot{}
	if !isWirelessManaged(serial) {
		return result, nil
	}
	candidates := verifiedWirelessCandidates(stateData, serial)
	result.Configured = len(candidates) != 0
	ctx, cancel := context.WithTimeout(ctx, 4500*time.Millisecond)
	defer cancel()
	command := func(args ...string) ([]byte, error) {
		child, stop := context.WithTimeout(ctx, 900*time.Millisecond)
		defer stop()
		return run(child, args...)
	}
	listing, err := command("devices", "-l")
	if err != nil {
		return result, fmt.Errorf("device connection status unavailable")
	}
	rows := make(map[string]string)
	for _, line := range strings.Split(string(listing), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 || fields[1] != "device" {
			continue
		}
		for _, field := range fields[2:] {
			if strings.HasPrefix(field, "transport_id:") {
				id := strings.TrimPrefix(field, "transport_id:")
				if number, err := strconv.ParseUint(id, 10, 64); err == nil && number > 0 {
					rows[fields[0]] = id
				}
			}
		}
	}
	verify := func(name, kind string) *transportSelection {
		id := rows[name]
		if id == "" || ctx.Err() != nil {
			return nil
		}
		identity, err := command("-t", id, "shell", "getprop", "ro.serialno")
		if err != nil || strings.TrimSpace(string(identity)) != serial {
			return nil
		}
		return &transportSelection{ID: id, Kind: kind}
	}
	result.USB = verify(serial, "usb")
	for _, endpoint := range candidates {
		if result.WiFi = verify(endpoint, "wifi"); result.WiFi != nil {
			break
		}
	}
	return result, nil
}

func (manager *WebRTCManager) inspectTransports(ctx context.Context, serial string) (transportSnapshot, error) {
	if !isWirelessManaged(serial) {
		return transportSnapshot{}, nil
	}
	if manager.transportInspector != nil {
		return manager.transportInspector(ctx, serial)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return transportSnapshot{}, fmt.Errorf("wireless configuration unavailable")
	}
	data := readTransportGuardStatus(home, serial)
	return inspectDeviceTransports(ctx, serial, data, runTransportADB)
}

func chooseTransport(snapshot transportSnapshot, preference string, requireWireless bool) *transportSelection {
	if preference == "wifi" {
		if snapshot.WiFi != nil || requireWireless {
			return snapshot.WiFi
		}
	}
	if snapshot.USB != nil {
		return snapshot.USB
	}
	return snapshot.WiFi
}

// Restore the old actual link before considering the old preference. A phone
// may already have fallen back from its preferred link before this request.
// Never immediately repeat the same capture transport that just failed.
func chooseRollbackTransport(snapshot transportSnapshot, previous, failed transportSelection, preference string) *transportSelection {
	choices := []*transportSelection{snapshot.USB, snapshot.WiFi}
	if previous.Kind == "wifi" {
		choices = []*transportSelection{snapshot.WiFi, snapshot.USB}
	} else if previous.Kind == "" && preference == "wifi" {
		choices = []*transportSelection{snapshot.WiFi, snapshot.USB}
	}
	for _, choice := range choices {
		if choice != nil && choice.ID != failed.ID {
			return choice
		}
	}
	return nil
}

// transportMu is never held while acquiring an AgentLock or running ADB.
func (manager *WebRTCManager) transportStateLocked(serial string) *deviceTransportState {
	if manager.transportStates == nil {
		manager.transportStates = make(map[string]*deviceTransportState)
	}
	state := manager.transportStates[serial]
	if state == nil {
		state = &deviceTransportState{Preference: "auto", Phase: "ready"}
		manager.transportStates[serial] = state
	}
	return state
}

func (manager *WebRTCManager) connectionStatus(serial string, snapshot transportSnapshot) DeviceConnectionStatus {
	manager.transportMu.Lock()
	defer manager.transportMu.Unlock()
	state := manager.transportStateLocked(serial)
	active := "none"
	phase := state.Phase
	if state.Active != nil {
		select {
		case <-state.Active.Done():
			state.Active = nil
			state.Generation++
			if state.Phase != "switching" {
				state.Phase = "failed"
				if state.LastError == "" {
					state.LastError = "connection_recovering"
				}
			}
		default:
			active = state.Selection.Kind
			if state.VideoReady != nil {
				select {
				case <-state.VideoReady:
					if !state.ReadyObserved {
						state.ReadyObserved = true
						state.Generation++
					}
				default:
					if phase == "ready" {
						phase = "switching"
					}
				}
			}
		}
	}
	if state.Active == nil {
		phase = state.Phase
	}
	return DeviceConnectionStatus{InstanceID: manager.connectionInstance(), DeviceID: serial, WirelessConfigured: snapshot.Configured,
		USBAvailable: snapshot.USB != nil, WiFiAvailable: snapshot.WiFi != nil,
		Preference: state.Preference, ActiveTransport: active, State: phase,
		Generation: state.Generation, LastError: state.LastError}
}

func (manager *WebRTCManager) connectionInstance() string {
	if manager.transportInstance != "" {
		return manager.transportInstance
	}
	return transportProcessInstance
}

func (manager *WebRTCManager) getDeviceConnection(ctx context.Context, serial string) (DeviceConnectionStatus, error) {
	snapshot, err := manager.inspectTransports(ctx, serial)
	status := manager.connectionStatus(serial, snapshot)
	if err != nil {
		status.LastError = err.Error()
	}
	return status, err
}

func (manager *WebRTCManager) prepareTransportConfig(config *sagent.AgentConfig, reason string) error {
	if config.DeviceType != sagent.DEVICE_TYPE_ANDROID || !isWirelessManaged(config.DeviceID) {
		return nil
	}
	// Switch and rollback selections were freshly checked by their transaction.
	// Every other generation resolves again, so a dead transport ID is never
	// retained by the normal prewarm/recovery path after USB/Wi-Fi reconnects.
	if (reason == "transport_switch" || reason == "transport_rollback") && config.DriverConfig["adb_transport_id"] != "" {
		return nil
	}
	manager.transportMu.Lock()
	state := manager.transportStateLocked(config.DeviceID)
	preference, failedID := state.Preference, state.FailedTransportID
	manager.transportMu.Unlock()
	snapshot, err := manager.inspectTransports(context.Background(), config.DeviceID)
	if err != nil {
		return err
	}
	selection := chooseTransport(snapshot, preference, false)
	if selection != nil && selection.ID == failedID {
		if fallback := chooseRollbackTransport(snapshot, transportSelection{}, *selection, preference); fallback != nil {
			selection = fallback
		}
	}
	if selection == nil {
		return fmt.Errorf("no verified connection for device")
	}
	config.DriverConfig["adb_transport_id"] = selection.ID
	config.DriverConfig["adb_transport_kind"] = selection.Kind
	return nil
}

func (manager *WebRTCManager) recordTransportActive(config sagent.AgentConfig, agent *sagent.Agent, generation uint64) {
	if config.DeviceType != sagent.DEVICE_TYPE_ANDROID || !isWirelessManaged(config.DeviceID) {
		return
	}
	manager.transportMu.Lock()
	defer manager.transportMu.Unlock()
	state := manager.transportStateLocked(config.DeviceID)
	state.Active = agent
	state.VideoReady, state.ReadyObserved = agent.VideoReady(), false
	// Public generation is a monotonic connection-state revision, independent
	// of the internal capture epoch. Accept/finish also advance it so an older
	// status response cannot overwrite a newly accepted switch in the client.
	state.Generation++
	state.Selection = transportSelection{ID: config.DriverConfig["adb_transport_id"], Kind: config.DriverConfig["adb_transport_kind"]}
	if state.Phase != "switching" {
		state.Phase = "ready"
		state.LastError = ""
		if state.Preference == "wifi" && state.Selection.Kind != "wifi" {
			state.LastError = "wireless_unavailable_using_usb"
		}
	}
}

func (manager *WebRTCManager) recordTransportFailure(config sagent.AgentConfig, agent *sagent.Agent) {
	if config.DeviceType != sagent.DEVICE_TYPE_ANDROID || !isWirelessManaged(config.DeviceID) {
		return
	}
	manager.transportMu.Lock()
	defer manager.transportMu.Unlock()
	state := manager.transportStateLocked(config.DeviceID)
	state.FailedTransportID = config.DriverConfig["adb_transport_id"]
	if agent != nil && state.Active == agent {
		state.Active = nil
		state.Generation++
		if state.Phase != "switching" {
			state.Phase, state.LastError = "failed", "connection_recovering"
		}
	}
}

func (manager *WebRTCManager) requestTransportSwitch(ctx context.Context, request transportRequest) (DeviceConnectionStatus, error) {
	if request.Preference != "auto" && request.Preference != "wifi" {
		return DeviceConnectionStatus{}, newTransportError(400, "invalid_connection_preference")
	}
	if !isWirelessManaged(request.DeviceID) {
		return DeviceConnectionStatus{}, newTransportError(404, "wireless_not_configured")
	}
	snapshot, err := manager.inspectTransports(ctx, request.DeviceID)
	status := manager.connectionStatus(request.DeviceID, snapshot)
	if request.ExpectedInstanceID != "" && request.ExpectedInstanceID != manager.connectionInstance() {
		return status, newTransportError(409, "connection_instance_changed")
	}
	if err != nil {
		return status, newTransportError(503, "connection_check_failed")
	}
	if !snapshot.Configured {
		return status, newTransportError(404, "wireless_not_configured")
	}
	selection := chooseTransport(snapshot, request.Preference, request.Preference == "wifi")
	if selection == nil {
		return status, newTransportError(409, "requested_connection_unavailable")
	}
	manager.transportMu.Lock()
	state := manager.transportStateLocked(request.DeviceID)
	if state.Phase == "switching" {
		manager.transportMu.Unlock()
		return status, newTransportError(409, "connection_switch_in_progress")
	}
	if request.ExpectedGeneration != nil && *request.ExpectedGeneration != state.Generation {
		manager.transportMu.Unlock()
		return status, newTransportError(409, "connection_generation_changed")
	}
	previousPreference := state.Preference
	state.Preference, state.Phase, state.LastError = request.Preference, "switching", ""
	state.FailedTransportID = ""
	state.Generation++
	manager.transportMu.Unlock()
	status = manager.connectionStatus(request.DeviceID, snapshot)
	if manager.transportSwitchStarter != nil {
		manager.transportSwitchStarter(request.DeviceID, request.Preference, previousPreference, *selection)
	} else {
		go manager.switchDeviceTransport(request.DeviceID, request.Preference, previousPreference, *selection)
	}
	return status, nil
}

func (manager *WebRTCManager) finishTransportSwitch(serial, preference, failure string) {
	manager.transportMu.Lock()
	defer manager.transportMu.Unlock()
	state := manager.transportStateLocked(serial)
	state.Preference, state.LastError = preference, failure
	state.Generation++
	state.Phase = "ready"
	if failure != "" {
		state.Phase = "failed"
	}
}

func waitTransportVideo(agent *sagent.Agent) error {
	timer := time.NewTimer(15 * time.Second)
	defer timer.Stop()
	select {
	case <-agent.VideoReady():
		select {
		case <-agent.Done():
			return fmt.Errorf("capture stopped before connection confirmation")
		default:
			return nil
		}
	case <-agent.Done():
		return fmt.Errorf("capture failed before its first frame")
	case <-timer.C:
		return fmt.Errorf("capture first-frame timeout")
	}
}

func (manager *WebRTCManager) switchDeviceTransport(serial, preference, previousPreference string, selection transportSelection) {
	manager.switchDeviceTransportUsing(serial, preference, previousPreference, selection,
		manager.startAgentLocked, waitTransportVideo)
}

// Dependencies are explicit so failure/rollback ordering can be tested without
// starting an Android process, touching USB, or needing a live encoder.
func (manager *WebRTCManager) switchDeviceTransportUsing(serial, preference, previousPreference string,
	selection transportSelection,
	start func(*DeviceBroadcaster, sagent.AgentConfig, webrtc.RTPCodecParameters, string) error,
	waitVideo func(*sagent.Agent) error,
) {
	// Same order as prewarm, normal starts, and recovery. No global restart or
	// other phone's broadcaster is involved in this transaction.
	manager.adbRecoveryLease.RLock()
	defer manager.adbRecoveryLease.RUnlock()
	key := sagent.DEVICE_TYPE_ANDROID + "_" + serial + "_0_0"
	manager.Lock()
	broadcaster := manager.broadcasters[key]
	if broadcaster == nil {
		video, audio := createAVTrack("video/H264", "audio/opus", false)
		if video == nil {
			manager.Unlock()
			manager.finishTransportSwitch(serial, previousPreference, "connection_setup_failed")
			return
		}
		broadcaster = &DeviceBroadcaster{VideoMimeType: "video/H264", VideoTrack: video, AudioTrack: audio,
			Subscribers: make(map[uint32]*Subscriber), RTPContinuity: sagent.NewRTPContinuity(), Prewarmed: true}
		manager.broadcasters[key] = broadcaster
	}
	manager.Unlock()
	broadcaster.AgentLock.Lock()
	defer broadcaster.AgentLock.Unlock()

	// The preflight transport may have disappeared while waiting for AgentLock.
	// Resolve and verify again before touching a working capture.
	snapshot, err := manager.inspectTransports(context.Background(), serial)
	chosen := chooseTransport(snapshot, preference, preference == "wifi")
	if err != nil || chosen == nil {
		manager.finishTransportSwitch(serial, previousPreference, "requested_connection_unavailable")
		return
	}
	selection = *chosen
	oldConfig, codec := cloneAgentConfig(broadcaster.AgentConfig), broadcaster.FinalCodec
	if oldConfig.DeviceID == "" {
		oldConfig, codec = prewarmAgentConfig(serial), prewarmFinalCodec()
	}
	if broadcaster.Agent != nil && broadcaster.AgentConfig.DriverConfig["adb_transport_id"] == selection.ID {
		if waitVideo(broadcaster.Agent) == nil {
			manager.finishTransportSwitch(serial, preference, "")
			return
		}
	}
	newConfig := cloneAgentConfig(oldConfig)
	newConfig.DriverConfig["adb_transport_id"], newConfig.DriverConfig["adb_transport_kind"] = selection.ID, selection.Kind
	manager.broadcastAgentState(broadcaster, "agent_restarting", broadcaster.AgentGeneration+1, newConfig.StreamProfile, "connection_switch")
	if old := broadcaster.Agent; old != nil {
		broadcaster.Agent = nil
		old.Close() // Cleans up using the old generation's pinned transport.
	}
	broadcaster.RecoveryNotBefore = time.Time{}
	err = start(broadcaster, newConfig, codec, "transport_switch")
	if err == nil {
		err = waitVideo(broadcaster.Agent)
	}
	if err == nil {
		manager.finishTransportSwitch(serial, preference, "")
		return
	}
	if failed := broadcaster.Agent; failed != nil {
		broadcaster.Agent = nil
		failed.Close()
	}
	manager.recordTransportFailure(newConfig, nil)
	// Do not replay input. Restore the old actual connection with a fresh
	// identity check, excluding the capture transport that just failed.
	previous := transportSelection{ID: oldConfig.DriverConfig["adb_transport_id"], Kind: oldConfig.DriverConfig["adb_transport_kind"]}
	snapshot, resolveErr := manager.inspectTransports(context.Background(), serial)
	rollback := chooseRollbackTransport(snapshot, previous, selection, previousPreference)
	if resolveErr != nil || rollback == nil {
		broadcaster.AgentConfig, broadcaster.FinalCodec = cloneAgentConfig(oldConfig), codec
		manager.finishTransportSwitch(serial, previousPreference, "switch_failed_no_recovery_connection")
		manager.scheduleMissingTransportRecovery(serial, broadcaster)
		return
	}
	oldConfig.DriverConfig["adb_transport_id"], oldConfig.DriverConfig["adb_transport_kind"] = rollback.ID, rollback.Kind
	broadcaster.RecoveryNotBefore = time.Time{}
	if restoreErr := start(broadcaster, oldConfig, codec, "transport_rollback"); restoreErr == nil {
		if waitVideo(broadcaster.Agent) == nil {
			manager.finishTransportSwitch(serial, previousPreference, "switch_failed_previous_connection_restored")
			return
		}
	}
	if failed := broadcaster.Agent; failed != nil {
		broadcaster.Agent = nil
		failed.Close()
	}
	manager.recordTransportFailure(oldConfig, nil)
	broadcaster.AgentConfig, broadcaster.FinalCodec = cloneAgentConfig(oldConfig), codec
	manager.finishTransportSwitch(serial, previousPreference, "switch_failed_recovery_pending")
	manager.scheduleMissingTransportRecovery(serial, broadcaster)
}

func (wm *WebMaster) transportRequestAllowed(request transportRequest) error {
	if request.DeviceID == "" || !wm.deviceAllowed(request.DeviceID) {
		return newTransportError(404, "device_not_found")
	}
	if len(request.RequestID) > 128 {
		return newTransportError(400, "invalid_request_id")
	}
	return nil
}

func (wm *WebMaster) executeTransportRequest(ctx context.Context, request transportRequest) (DeviceConnectionStatus, error) {
	if err := wm.transportRequestAllowed(request); err != nil {
		return DeviceConnectionStatus{}, err
	}
	if request.DeviceID == tripathPilotDevice && tripathPilotSubscribers.Load() > 0 {
		status := DeviceConnectionStatus{InstanceID: wm.WebRTCManager.connectionInstance() + "-tripath", DeviceID: tripathPilotDevice,
			Preference: "auto", ActiveTransport: "tripath", State: "ready", Generation: 1}
		// The experiment combines the lanes automatically. Hide the single-lane
		// selector in existing clients while it is active, without claiming USB
		// or Wi-Fi is the sole media path or changing the normal preference.
		if request.Type == "transport_switch" {
			return status, newTransportError(409, "tripath_pilot_uses_all_available_lanes")
		}
		return status, nil
	}
	if request.Type == "transport_switch" {
		return wm.WebRTCManager.requestTransportSwitch(ctx, request)
	}
	return wm.WebRTCManager.getDeviceConnection(ctx, request.DeviceID)
}

// This branch runs only after the existing origin-secret or one-use gateway
// ticket middleware authorized /screen/ws. It creates no WebRTC subscriber.
func (wm *WebMaster) handleTransportRPC(conn *websocket.Conn, request transportRequest) {
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	status, err := wm.executeTransportRequest(ctx, request)
	response := transportRPCResponse{Type: "transport_status", RequestID: request.RequestID, Status: "ok"}
	if status.DeviceID != "" {
		response.Connection = &status
	}
	if err != nil {
		response.Status, response.Message = "error", err.Error()
	}
	_ = conn.SetWriteDeadline(time.Now().Add(3 * time.Second))
	_ = conn.WriteJSON(response)
}

func (wm *WebMaster) handleGetDeviceConnection(c *gin.Context) {
	wm.serveTransportHTTP(c, transportRequest{Type: "transport_status", DeviceID: c.Query("device_id")})
}

func (wm *WebMaster) handleSetDeviceConnection(c *gin.Context) {
	var request transportRequest
	if err := c.ShouldBindJSON(&request); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid_request"})
		return
	}
	request.Type = "transport_switch"
	wm.serveTransportHTTP(c, request)
}

func (wm *WebMaster) serveTransportHTTP(c *gin.Context, request transportRequest) {
	status, err := wm.executeTransportRequest(c.Request.Context(), request)
	code := http.StatusOK
	if err != nil {
		code = http.StatusServiceUnavailable
		var typed *transportError
		if errors.As(err, &typed) {
			code = typed.code
		}
		c.JSON(code, gin.H{"error": err.Error(), "connection": status})
		return
	}
	if request.Type == "transport_switch" {
		code = http.StatusAccepted
	}
	c.JSON(code, status)
}
