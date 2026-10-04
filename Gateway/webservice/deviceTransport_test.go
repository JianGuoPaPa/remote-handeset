package webservice

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"testing/fstest"
	"time"

	sagent "webscreen/streamAgent"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
	"github.com/pion/webrtc/v4"
)

const testBackup = "ZY22HN3ZS4"
const testWhite = "ZY22F68DH8"

func guardBytes(serial string, endpoints ...string) []byte {
	details := make([]transportGuardEndpoint, 0, len(endpoints))
	for _, endpoint := range endpoints {
		details = append(details, transportGuardEndpoint{Serial: endpoint, VerifiedSerial: serial, VerifiedAt: 1})
	}
	data, _ := json.Marshal(transportGuardState{Enabled: true, Serial: serial, Verified: endpoints, WiFiEndpoints: details})
	return data
}

func testSnapshot() transportSnapshot {
	return transportSnapshot{Configured: true, USB: &transportSelection{ID: "4", Kind: "usb"},
		WiFi: &transportSelection{ID: "10", Kind: "wifi"}}
}

func fakeTransportManager() *WebRTCManager {
	return &WebRTCManager{broadcasters: make(map[string]*DeviceBroadcaster),
		transportInspector: func(context.Context, string) (transportSnapshot, error) { return testSnapshot(), nil }}
}

func TestWirelessCandidatesRequirePerDeviceGuardIdentity(t *testing.T) {
	for _, data := range [][]byte{[]byte("bad json"), guardBytes(testBackup, "192.168.1.39:5555"),
		guardBytes(testWhite, "localhost:5555", "127.0.0.1:5555", "192.168.1.47:0", "192.168.1.47:65536")} {
		if got := verifiedWirelessCandidates(data, testWhite); len(got) != 0 {
			t.Fatalf("untrusted candidates accepted: %v", got)
		}
	}
	var state transportGuardState
	_ = json.Unmarshal(guardBytes(testWhite, "192.168.1.47:5555", "192.168.1.47:5555", "192.168.1.47:39775"), &state)
	state.Rejected = []string{"192.168.1.47:5555"}
	data, _ := json.Marshal(state)
	if got := verifiedWirelessCandidates(data, testWhite); len(got) != 1 || got[0] != "192.168.1.47:39775" {
		t.Fatalf("unexpected candidates: %v", got)
	}
}

func TestInspectVerifiesActualHardwareAndDoesNotConnectOrTouchThirdParty(t *testing.T) {
	var calls []string
	run := func(ctx context.Context, args ...string) ([]byte, error) {
		if _, ok := ctx.Deadline(); !ok {
			t.Fatal("probe has no deadline")
		}
		command := strings.Join(args, " ")
		calls = append(calls, command)
		switch command {
		case "devices -l":
			return []byte("List of devices attached\n" + testWhite + " device transport_id:4\n192.168.1.47:5555 device transport_id:10\n192.168.1.47:39775 device transport_id:11\nOTHER device transport_id:99\n"), nil
		case "-t 4 shell getprop ro.serialno", "-t 11 shell getprop ro.serialno":
			return []byte(testWhite + "\n"), nil
		case "-t 10 shell getprop ro.serialno":
			return []byte(testBackup + "\n"), nil
		default:
			t.Fatalf("unexpected command: %s", command)
			return nil, nil
		}
	}
	snapshot, err := inspectDeviceTransports(context.Background(), testWhite,
		guardBytes(testWhite, "192.168.1.47:5555", "192.168.1.47:39775"), run)
	if err != nil || !snapshot.Configured || snapshot.USB.ID != "4" || snapshot.WiFi.ID != "11" {
		t.Fatalf("bad snapshot: %#v, %v", snapshot, err)
	}
	if len(calls) != 4 {
		t.Fatalf("unexpected command count %d", len(calls))
	}
	_, err = inspectDeviceTransports(context.Background(), "OTHER", nil, run)
	if err != nil || len(calls) != 4 {
		t.Fatal("unmanaged phone was probed")
	}
}

func TestTransportPreferenceAndUnavailableFallback(t *testing.T) {
	snapshot := testSnapshot()
	if chooseTransport(snapshot, "auto", false).Kind != "usb" || chooseTransport(snapshot, "wifi", true).Kind != "wifi" {
		t.Fatal("wrong preference")
	}
	snapshot.WiFi = nil
	if chooseTransport(snapshot, "wifi", true) != nil {
		t.Fatal("explicit switch accepted unavailable wireless")
	}
	if chooseTransport(snapshot, "wifi", false).Kind != "usb" {
		t.Fatal("automatic recovery did not fall back")
	}
	snapshot.USB, snapshot.WiFi = nil, &transportSelection{ID: "10", Kind: "wifi"}
	if chooseTransport(snapshot, "auto", false).Kind != "wifi" {
		t.Fatal("USB outage did not fall back")
	}
}

func TestSwitchPreflightProtectsCurrentAgentAndConcurrentRequests(t *testing.T) {
	manager := fakeTransportManager()
	var mu sync.Mutex
	started := []string{}
	manager.transportSwitchStarter = func(serial, preference, previous string, selection transportSelection) {
		mu.Lock()
		defer mu.Unlock()
		started = append(started, serial)
		if preference != "wifi" || previous != "auto" || selection.Kind != "wifi" {
			t.Error("bad switch request")
		}
	}
	var group sync.WaitGroup
	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			_, err := manager.requestTransportSwitch(context.Background(), transportRequest{DeviceID: testWhite, Preference: "wifi"})
			results <- err
		}()
	}
	group.Wait()
	close(results)
	successes := 0
	for err := range results {
		if err == nil {
			successes++
		}
	}
	if successes != 1 || len(started) != 1 {
		t.Fatalf("duplicate transitions: %d %v", successes, started)
	}
	// The other phone is independent, even while white Motorola is switching.
	if _, err := manager.requestTransportSwitch(context.Background(), transportRequest{DeviceID: testBackup, Preference: "wifi"}); err != nil {
		t.Fatal(err)
	}
	if len(started) != 2 {
		t.Fatal("second phone was blocked")
	}
	manager = fakeTransportManager()
	manager.transportInspector = func(context.Context, string) (transportSnapshot, error) {
		value := testSnapshot()
		value.WiFi = nil
		return value, nil
	}
	manager.transportSwitchStarter = func(string, string, string, transportSelection) { t.Fatal("unavailable switch started") }
	status, err := manager.requestTransportSwitch(context.Background(), transportRequest{DeviceID: testWhite, Preference: "wifi"})
	if err == nil || status.Preference != "auto" || status.State != "ready" {
		t.Fatalf("preflight changed state: %#v %v", status, err)
	}
}

func TestGenerationAndUnsupportedDevicesRejected(t *testing.T) {
	manager := fakeTransportManager()
	manager.transportSwitchStarter = func(string, string, string, transportSelection) { t.Fatal("invalid switch started") }
	generation := uint64(99)
	for _, request := range []transportRequest{
		{DeviceID: testWhite, Preference: "wifi", ExpectedGeneration: &generation},
		{DeviceID: "OTHER", Preference: "wifi"}, {DeviceID: testWhite, Preference: "tcp://evil"},
	} {
		if _, err := manager.requestTransportSwitch(context.Background(), request); err == nil {
			t.Fatalf("accepted %#v", request)
		}
	}
}

func TestConnectionRevisionAdvancesOnAcceptAndOldInstanceCannotSwitch(t *testing.T) {
	manager := fakeTransportManager()
	manager.transportInstance = "gateway-after-restart"
	manager.transportSwitchStarter = func(string, string, string, transportSelection) {}
	before := manager.connectionStatus(testWhite, testSnapshot())
	request := transportRequest{DeviceID: testWhite, Preference: "wifi", ExpectedGeneration: &before.Generation,
		ExpectedInstanceID: "gateway-before-restart"}
	status, err := manager.requestTransportSwitch(context.Background(), request)
	if err == nil || err.Error() != "connection_instance_changed" || status.InstanceID != manager.transportInstance {
		t.Fatalf("old instance accepted: %#v %v", status, err)
	}
	request.ExpectedInstanceID = before.InstanceID
	accepted, err := manager.requestTransportSwitch(context.Background(), request)
	if err != nil || accepted.Generation <= before.Generation || accepted.State != "switching" {
		t.Fatalf("accept did not advance revision: %#v %v", accepted, err)
	}
	manager.finishTransportSwitch(testWhite, "wifi", "")
	finished := manager.connectionStatus(testWhite, testSnapshot())
	if finished.Generation <= accepted.Generation || finished.InstanceID != before.InstanceID || finished.State != "ready" {
		t.Fatalf("finish did not advance revision: %#v", finished)
	}
}

func seedTransportAgent(manager *WebRTCManager, serial, id, kind string) (*DeviceBroadcaster, *sagent.Agent) {
	config := prewarmAgentConfig(serial)
	config.DriverConfig["adb_transport_id"], config.DriverConfig["adb_transport_kind"] = id, kind
	agent := sagent.New(config, nil, nil)
	broadcaster := &DeviceBroadcaster{Agent: agent, AgentConfig: config, AgentGeneration: 3,
		Subscribers: make(map[uint32]*Subscriber), FinalCodec: prewarmFinalCodec()}
	manager.broadcasters["android_"+serial+"_0_0"] = broadcaster
	manager.recordTransportActive(config, agent, 3)
	return broadcaster, agent
}

func TestSwitchFailureRestoresOldPolicyAndOnlyRebuildsRequestedPhone(t *testing.T) {
	manager := fakeTransportManager()
	target, old := seedTransportAgent(manager, testWhite, "4", "usb")
	other, untouched := seedTransportAgent(manager, testBackup, "44", "usb")
	manager.transportMu.Lock()
	state := manager.transportStateLocked(testWhite)
	state.Preference, state.Phase = "wifi", "switching"
	manager.transportMu.Unlock()
	var attempts []string
	var failed *sagent.Agent
	start := func(b *DeviceBroadcaster, config sagent.AgentConfig, codec webrtc.RTPCodecParameters, reason string) error {
		if b != target {
			t.Fatal("other phone restarted")
		}
		attempts = append(attempts, reason+":"+config.DriverConfig["adb_transport_id"])
		b.Agent = sagent.New(config, nil, nil)
		b.AgentConfig = config
		b.AgentGeneration++
		manager.recordTransportActive(config, b.Agent, b.AgentGeneration)
		if reason == "transport_switch" {
			failed = b.Agent
		}
		return nil
	}
	wait := func(agent *sagent.Agent) error {
		if agent == failed {
			return fmt.Errorf("no picture")
		}
		return nil
	}
	manager.switchDeviceTransportUsing(testWhite, "wifi", "auto", *testSnapshot().WiFi, start, wait)
	if strings.Join(attempts, ",") != "transport_switch:10,transport_rollback:4" {
		t.Fatalf("bad rollback %v", attempts)
	}
	for _, agent := range []*sagent.Agent{old, failed} {
		select {
		case <-agent.Done():
		default:
			t.Fatal("old generation not cleaned up")
		}
	}
	if other.Agent != untouched || other.AgentGeneration != 3 {
		t.Fatal("other phone changed")
	}
	select {
	case <-untouched.Done():
		t.Fatal("other phone stopped")
	default:
	}
	status := manager.connectionStatus(testWhite, testSnapshot())
	if status.Preference != "auto" || status.ActiveTransport != "usb" || status.State != "failed" || status.LastError != "switch_failed_previous_connection_restored" {
		t.Fatalf("bad restored status %#v", status)
	}
}

func TestLostPreflightLinkPreservesExistingCapture(t *testing.T) {
	manager := fakeTransportManager()
	broadcaster, old := seedTransportAgent(manager, testWhite, "4", "usb")
	manager.transportInspector = func(context.Context, string) (transportSnapshot, error) {
		snapshot := testSnapshot()
		snapshot.WiFi = nil
		return snapshot, nil
	}
	start := func(*DeviceBroadcaster, sagent.AgentConfig, webrtc.RTPCodecParameters, string) error {
		t.Fatal("old capture touched")
		return nil
	}
	manager.switchDeviceTransportUsing(testWhite, "wifi", "auto", *testSnapshot().WiFi, start, func(*sagent.Agent) error { return nil })
	if broadcaster.Agent != old {
		t.Fatal("capture replaced without a viable link")
	}
	select {
	case <-old.Done():
		t.Fatal("old capture closed")
	default:
	}
}

func TestFailedInitializationRollsBackWithoutRetryingTheFailedTransport(t *testing.T) {
	manager := fakeTransportManager()
	target, _ := seedTransportAgent(manager, testWhite, "4", "usb")
	attempts := []string{}
	start := func(b *DeviceBroadcaster, config sagent.AgentConfig, codec webrtc.RTPCodecParameters, reason string) error {
		attempts = append(attempts, reason)
		if reason == "transport_switch" {
			return fmt.Errorf("initialization deadline")
		}
		b.Agent = sagent.New(config, nil, nil)
		b.AgentConfig = config
		b.AgentGeneration++
		manager.recordTransportActive(config, b.Agent, b.AgentGeneration)
		return nil
	}
	manager.switchDeviceTransportUsing(testWhite, "wifi", "auto", *testSnapshot().WiFi,
		start, func(*sagent.Agent) error { return nil })
	if strings.Join(attempts, ",") != "transport_switch,transport_rollback" || target.AgentConfig.DriverConfig["adb_transport_id"] != "4" {
		t.Fatalf("incorrect init rollback: %v %#v", attempts, target.AgentConfig)
	}
}

func TestRecoveryResolvesFreshTransportButOtherDevicesAreUntouched(t *testing.T) {
	manager := fakeTransportManager()
	config := prewarmAgentConfig(testWhite)
	config.DriverConfig["adb_transport_id"] = "stale"
	if err := manager.prepareTransportConfig(&config, "auto_recovery"); err != nil || config.DriverConfig["adb_transport_id"] != "4" {
		t.Fatalf("stale ID retained: %#v %v", config.DriverConfig, err)
	}
	manager.transportInspector = func(context.Context, string) (transportSnapshot, error) {
		t.Fatal("unmanaged phone probed")
		return transportSnapshot{}, nil
	}
	other := prewarmAgentConfig("UNMANAGED-ANDROID")
	if err := manager.prepareTransportConfig(&other, "initial"); err != nil {
		t.Fatal(err)
	}
	if _, exists := other.DriverConfig["adb_transport_id"]; exists {
		t.Fatal("other phone acquired routing override")
	}
	canonical, err := canonicalAndroidDriverConfig(map[string]string{"adb_transport_id": "99", "adb_transport_kind": "wifi"})
	if err != nil || canonical["adb_transport_id"] != "" || canonical["adb_transport_kind"] != "" {
		t.Fatal("client can inject transport IDs")
	}
}

func testTransportWebmaster() *WebMaster {
	gin.SetMode(gin.TestMode)
	wm := &WebMaster{WebRTCManager: fakeTransportManager(), staticFS: fstest.MapFS{"static/test.txt": &fstest.MapFile{Data: []byte("test")}}}
	wm.SetGatewaySecurity("test-only-origin-secret", "https://portal.test", testWhite+","+testBackup+",OTHER")
	wm.setRouter()
	return wm
}

func testGatewayTicket(wm *WebMaster, nonce string) string {
	value := fmt.Sprintf("v1.%d.%s", time.Now().Unix()+30, nonce)
	mac := hmac.New(sha256.New, []byte(wm.originSecret))
	_, _ = mac.Write([]byte(value))
	return value + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func TestManagementWebSocketReusesOneUseTicketAndDoesNotCreateSubscriber(t *testing.T) {
	wm := testTransportWebmaster()
	server := httptest.NewServer(wm.router)
	defer server.Close()
	headers := http.Header{"Origin": []string{"https://portal.test"}}
	base := "ws" + strings.TrimPrefix(server.URL, "http") + "/screen/ws"
	if conn, response, err := websocket.DefaultDialer.Dial(base, headers); err == nil {
		conn.Close()
		t.Fatal("unauthenticated management accepted")
	} else if response.StatusCode != 401 {
		t.Fatal(response.Status)
	}
	ticket := testGatewayTicket(wm, "management-test-nonce-1")
	conn, _, err := websocket.DefaultDialer.Dial(base+"?ticket="+ticket, headers)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := conn.WriteJSON(transportRequest{Type: "transport_status", RequestID: "request-1", DeviceID: testWhite}); err != nil {
		t.Fatal(err)
	}
	var result transportRPCResponse
	if err := conn.ReadJSON(&result); err != nil {
		t.Fatal(err)
	}
	if result.Status != "ok" || result.RequestID != "request-1" || result.Connection == nil || !result.Connection.WirelessConfigured {
		t.Fatalf("bad management response %#v", result)
	}
	if len(wm.WebRTCManager.broadcasters) != 0 {
		t.Fatal("management RPC created media capture")
	}
	if repeated, response, err := websocket.DefaultDialer.Dial(base+"?ticket="+ticket, headers); err == nil {
		repeated.Close()
		t.Fatal("ticket replay accepted")
	} else if response.StatusCode != 401 {
		t.Fatal(response.Status)
	}
}

func TestTransportHTTPAndRPCRespectAllowlistAndUnknownPhonesHideCapability(t *testing.T) {
	wm := testTransportWebmaster()
	status, err := wm.executeTransportRequest(context.Background(), transportRequest{Type: "transport_status", DeviceID: "OTHER"})
	if err != nil || status.WirelessConfigured {
		t.Fatalf("unmanaged capability %#v %v", status, err)
	}
	if _, err := wm.executeTransportRequest(context.Background(), transportRequest{Type: "transport_status", DeviceID: "NOT-ALLOWED"}); err == nil {
		t.Fatal("allowlist bypass")
	}
	request := httptest.NewRequest("GET", "/api/device/connection?device_id="+testWhite, nil)
	recorder := httptest.NewRecorder()
	wm.router.ServeHTTP(recorder, request)
	if recorder.Code != 401 {
		t.Fatal("REST auth bypass")
	}
	request = httptest.NewRequest("GET", "/api/device/connection?device_id="+testWhite, nil)
	request.Header.Set("X-Webscreen-Origin-Secret", wm.originSecret)
	recorder = httptest.NewRecorder()
	wm.router.ServeHTTP(recorder, request)
	if recorder.Code != 200 {
		body, _ := io.ReadAll(recorder.Result().Body)
		t.Fatalf("GET failed %s", body)
	}
}

func TestRollbackRestoresActualConnectionRatherThanOldPreference(t *testing.T) {
	for _, scenario := range []struct{ oldKind, oldID, oldPreference, requested, failedID string }{
		{"usb", "4", "wifi", "wifi", "10"},
		{"wifi", "10", "auto", "auto", "4"},
	} {
		t.Run(scenario.oldKind, func(t *testing.T) {
			manager := fakeTransportManager()
			target, _ := seedTransportAgent(manager, testWhite, scenario.oldID, scenario.oldKind)
			manager.transportStateLocked(testWhite).Preference = scenario.oldPreference
			attempts := []string{}
			start := func(b *DeviceBroadcaster, config sagent.AgentConfig, codec webrtc.RTPCodecParameters, reason string) error {
				attempts = append(attempts, config.DriverConfig["adb_transport_id"])
				if reason == "transport_switch" {
					return fmt.Errorf("capture setup failed")
				}
				b.Agent, b.AgentConfig = sagent.New(config, nil, nil), config
				b.AgentGeneration++
				manager.recordTransportActive(config, b.Agent, b.AgentGeneration)
				return nil
			}
			manager.switchDeviceTransportUsing(testWhite, scenario.requested, scenario.oldPreference,
				transportSelection{}, start, func(*sagent.Agent) error { return nil })
			if len(attempts) != 2 || attempts[0] != scenario.failedID || attempts[1] != scenario.oldID {
				t.Fatalf("retried failed preference rather than restoring actual link: %v", attempts)
			}
			if target.AgentConfig.DriverConfig["adb_transport_kind"] != scenario.oldKind {
				t.Fatal("prior actual transport not restored")
			}
		})
	}
	snapshot := testSnapshot()
	snapshot.USB = nil
	if chooseRollbackTransport(snapshot, *snapshot.WiFi, *snapshot.WiFi, "wifi") != nil {
		t.Fatal("immediate rollback retried the failed transport")
	}
}

func TestAutomaticRecoveryPrefersAlternativeAfterCaptureFailure(t *testing.T) {
	manager := fakeTransportManager()
	config := prewarmAgentConfig(testWhite)
	config.DriverConfig["adb_transport_id"], config.DriverConfig["adb_transport_kind"] = "10", "wifi"
	manager.transportStateLocked(testWhite).Preference = "wifi"
	manager.recordTransportFailure(config, nil)
	if err := manager.prepareTransportConfig(&config, "auto_recovery"); err != nil || config.DriverConfig["adb_transport_id"] != "4" {
		t.Fatalf("failed Wi-Fi preferred over verified USB fallback: %v %#v", err, config)
	}
	// A new ADB transport identity can be tried normally after reconnection.
	manager.transportInspector = func(context.Context, string) (transportSnapshot, error) {
		snapshot := testSnapshot()
		snapshot.WiFi.ID = "12"
		return snapshot, nil
	}
	if err := manager.prepareTransportConfig(&config, "auto_recovery"); err != nil || config.DriverConfig["adb_transport_id"] != "12" {
		t.Fatal("freshly reconnected preferred transport retained stale failure")
	}
}

func TestConnectionStatusWaitsForRealPictureAndAdvancesRevision(t *testing.T) {
	manager := fakeTransportManager()
	_, agent := seedTransportAgent(manager, testWhite, "4", "usb")
	ready := make(chan struct{})
	manager.transportStateLocked(testWhite).VideoReady = ready
	before := manager.connectionStatus(testWhite, testSnapshot())
	if before.State != "switching" {
		t.Fatalf("reported ready before a picture: %#v", before)
	}
	close(ready)
	after := manager.connectionStatus(testWhite, testSnapshot())
	if after.State != "ready" || after.Generation <= before.Generation {
		t.Fatalf("first picture did not advance revision: %#v", after)
	}
	if manager.connectionStatus(testWhite, testSnapshot()).Generation != after.Generation {
		t.Fatal("unchanged readiness repeatedly advanced revision")
	}
	agent.Close()
	stopped := manager.connectionStatus(testWhite, testSnapshot())
	if stopped.ActiveTransport != "none" || stopped.State != "failed" || stopped.Generation <= after.Generation {
		t.Fatalf("closed capture reported live: %#v", stopped)
	}
}

func TestWirelessCapabilityRequiresEnabledVerifiedIdentityHistory(t *testing.T) {
	valid := guardBytes(testWhite, "192.168.1.47:5555")
	cases := []struct {
		name   string
		change func(*transportGuardState)
	}{
		{"disabled", func(s *transportGuardState) { s.Enabled = false }},
		{"wrong guard identity", func(s *transportGuardState) { s.Serial = testBackup }},
		{"address without identity history", func(s *transportGuardState) { s.WiFiEndpoints = nil }},
		{"other phone history", func(s *transportGuardState) { s.WiFiEndpoints[0].VerifiedSerial = testBackup }},
		{"never verified", func(s *transportGuardState) { s.WiFiEndpoints[0].VerifiedAt = 0 }},
		{"history address not in verified candidates", func(s *transportGuardState) { s.WiFiEndpoints[0].Serial = "192.168.1.48:5555" }},
		{"rejected after address reassignment", func(s *transportGuardState) { s.Rejected = append(s.Rejected, "192.168.1.47:5555") }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var state transportGuardState
			if err := json.Unmarshal(valid, &state); err != nil {
				t.Fatal(err)
			}
			c.change(&state)
			data, _ := json.Marshal(state)
			if candidates := verifiedWirelessCandidates(data, testWhite); len(candidates) != 0 {
				t.Fatalf("incomplete or untrusted capability accepted: %v", candidates)
			}
		})
	}
	var legacy map[string]interface{}
	_ = json.Unmarshal(valid, &legacy)
	delete(legacy, "enabled")
	data, _ := json.Marshal(legacy)
	if len(verifiedWirelessCandidates(data, testWhite)) != 0 {
		t.Fatal("missing enabled marker implicitly enabled wireless")
	}
}

func TestAllSevenGuardPathsRequireInstalledGuardAndKeepLegacyLocations(t *testing.T) {
	home := t.TempDir()
	expected := map[string]string{
		testBackup: "backup3-unattended", testWhite: "white-motorola-unattended",
		"ZY22GHBP48": "android-unattended/ZY22GHBP48", "ZY22K2SXMK": "android-unattended/ZY22K2SXMK",
		"31629594940010K": "android-unattended/31629594940010K", "ZY22GDWXSZ": "android-unattended/ZY22GDWXSZ",
		"10AD6F2LSY0017B": "android-unattended/10AD6F2LSY0017B",
	}
	if len(wirelessDeviceDirectories) != len(expected) {
		t.Fatal("unexpected wireless scope")
	}
	for serial, relative := range expected {
		t.Run(serial, func(t *testing.T) {
			if wirelessDeviceDirectories[serial] != relative {
				t.Fatal("guard path changed")
			}
			directory := filepath.Join(home, ".remote-handset", relative)
			if err := os.MkdirAll(directory, 0700); err != nil {
				t.Fatal(err)
			}
			data := guardBytes(serial, "192.168.1.47:5555")
			if err := os.WriteFile(filepath.Join(directory, "status.json"), data, 0600); err != nil {
				t.Fatal(err)
			}
			if got := readTransportGuardStatus(home, serial); got != nil {
				t.Fatal("status alone claimed installed guard")
			}
			if err := os.Mkdir(filepath.Join(directory, "guard.py"), 0700); err != nil {
				t.Fatal(err)
			}
			if got := readTransportGuardStatus(home, serial); got != nil {
				t.Fatal("directory accepted as guard")
			}
			if err := os.Remove(filepath.Join(directory, "guard.py")); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(directory, "guard.py"), []byte("# installed test guard\n"), 0600); err != nil {
				t.Fatal(err)
			}
			if got := verifiedWirelessCandidates(readTransportGuardStatus(home, serial), serial); len(got) != 1 {
				t.Fatalf("installed verified guard not recognized: %v", got)
			}
		})
	}
	for _, unknown := range []string{"OTHER", "../backup3-unattended", ""} {
		if readTransportGuardStatus(home, unknown) != nil || isWirelessManaged(unknown) {
			t.Fatal("unknown device acquired capability")
		}
	}
}

func TestAllSevenPhonesVerifyLiveIdentityAndRetainCapabilityDuringWiFiOutage(t *testing.T) {
	for serial := range wirelessDeviceDirectories {
		t.Run(serial, func(t *testing.T) {
			wirelessOnline, wrongIdentity := false, false
			run := func(_ context.Context, args ...string) ([]byte, error) {
				switch strings.Join(args, " ") {
				case "devices -l":
					listing := "List of devices attached\n" + serial + " device transport_id:4\nOTHER device transport_id:99\n"
					if wirelessOnline {
						listing += "192.168.1.47:5555 device transport_id:10\n"
					}
					return []byte(listing), nil
				case "-t 4 shell getprop ro.serialno":
					return []byte(serial), nil
				case "-t 10 shell getprop ro.serialno":
					if wrongIdentity {
						return []byte("OTHER"), nil
					}
					return []byte(serial), nil
				default:
					t.Fatalf("unexpected phone/action: %v", args)
					return nil, nil
				}
			}
			data := guardBytes(serial, "192.168.1.47:5555")
			offline, err := inspectDeviceTransports(context.Background(), serial, data, run)
			if err != nil || !offline.Configured || offline.WiFi != nil || offline.USB == nil {
				t.Fatalf("temporary outage lost configured capability: %#v %v", offline, err)
			}
			wirelessOnline = true
			online, err := inspectDeviceTransports(context.Background(), serial, data, run)
			if err != nil || !online.Configured || online.WiFi == nil || online.WiFi.ID != "10" {
				t.Fatalf("verified wireless unavailable: %#v %v", online, err)
			}
			wrongIdentity = true
			reassigned, err := inspectDeviceTransports(context.Background(), serial, data, run)
			if err != nil || !reassigned.Configured || reassigned.WiFi != nil || reassigned.USB == nil {
				t.Fatalf("another phone's transport was exposed: %#v %v", reassigned, err)
			}
			unconfigured, err := inspectDeviceTransports(context.Background(), serial, nil, run)
			if err != nil || unconfigured.Configured || unconfigured.WiFi != nil || unconfigured.USB == nil {
				t.Fatalf("allowlist alone enabled wireless or broke USB: %#v %v", unconfigured, err)
			}
		})
	}
}
