package webservice

import (
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"strings"
	"time"
	sagent "webscreen/streamAgent"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
	"github.com/pion/webrtc/v4"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool {
		return true // Allow all origins for development
	},
}

var androidVideoEncoders = map[string]struct{}{
	"c2.qti.avc.encoder":     {},
	"c2.android.avc.encoder": {},
}

var androidVideoCodecOptions = map[string]struct{}{
	"profile=1":                         {},
	"i-frame-interval=1,bitrate-mode=2": {},
	"i-frame-interval=4,bitrate-mode=2": {},
}

var androidMaximumFrameRates = map[string]struct{}{
	"20": {},
	"24": {},
	"30": {},
}

func canonicalAndroidDriverConfig(source map[string]string) (map[string]string, error) {
	canonical := map[string]string{
		"video_codec":         "h264",
		"video_bit_rate":      "800000",
		"video_codec_options": "i-frame-interval=4,bitrate-mode=2",
		"max_size":            "1280",
		"max_fps":             "30",
		"audio":               "true",
		"audio_bit_rate":      "64000",
		"control":             "true",
	}

	for key, value := range source {
		switch key {
		case "video_codec":
			if value != "h264" {
				return nil, fmt.Errorf("unsupported Android video codec")
			}
		case "video_encoder":
			if value == "" {
				continue
			}
			if _, allowed := androidVideoEncoders[value]; !allowed {
				return nil, fmt.Errorf("unsupported Android video encoder")
			}
			canonical[key] = value
		case "video_bit_rate":
			// The relay cap is a server policy. Never pass the client value on.
			canonical[key] = "800000"
		case "video_codec_options":
			if _, allowed := androidVideoCodecOptions[value]; !allowed {
				return nil, fmt.Errorf("unsupported Android video codec options")
			}
			canonical[key] = value
		case "max_size":
			if value != "1280" {
				return nil, fmt.Errorf("unsupported Android video size")
			}
		case "max_fps":
			if _, allowed := androidMaximumFrameRates[value]; !allowed {
				return nil, fmt.Errorf("unsupported Android frame rate")
			}
			canonical[key] = value
		case "audio", "control":
			if value != "true" && value != "false" {
				return nil, fmt.Errorf("invalid Android %s setting", key)
			}
			canonical[key] = value
		case "audio_bit_rate":
			// Audio bitrate is fixed below whenever audio is enabled.
		default:
			// Rebuild rather than mutate the client map. Unknown scrcpy options,
			// including deviceID and shell-sensitive values, never reach the driver.
		}
	}

	if canonical["audio"] == "true" {
		canonical["audio_bit_rate"] = "64000"
	} else {
		delete(canonical, "audio_bit_rate")
	}
	return canonical, nil
}

func randomString(length int) string {
	const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	b := make([]byte, length)
	for i := range b {
		b[i] = charset[rand.Intn(len(charset))]
	}
	return string(b)
}

// /:id/ws
func (wm *WebMaster) handleScreenWS(c *gin.Context) {
	if !wm.originAllowed(c.GetHeader("Origin")) {
		c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"error": "origin not allowed"})
		return
	}
	wm.serveScreenWS(c)
}

func (wm *WebMaster) serveScreenWS(c *gin.Context) {
	// Implement WebSocket handling for screen here
	// Parse URL parameters
	conn, err := upgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		log.Println("Failed to upgrade to websocket:", err)
		return
	}
	defer conn.Close()
	conn.SetReadLimit(2 << 20)
	_ = conn.SetReadDeadline(time.Now().Add(20 * time.Second))

	var initial json.RawMessage
	err = conn.ReadJSON(&initial)
	if err != nil {
		log.Println("Failed to read connection options:", err)
		conn.WriteJSON(map[string]any{"status": "error", "message": err.Error(), "stage": "webrtc_init"})
		conn.Close()
		return
	}
	_ = conn.SetReadDeadline(time.Time{})
	var management transportRequest
	if json.Unmarshal(initial, &management) == nil &&
		(management.Type == "transport_status" || management.Type == "transport_switch") {
		wm.handleTransportRPC(conn, management)
		return
	}
	config := sagent.AgentConfig{}
	if err := json.Unmarshal(initial, &config); err != nil {
		_ = conn.WriteJSON(map[string]any{"status": "error", "message": "invalid connection options", "stage": "webrtc_init"})
		return
	}

	// Gorilla only processes WebSocket control frames while a reader is active.
	// Start the one and only signaling reader immediately after consuming the
	// initial JSON offer so client Ping frames are answered even while ICE and
	// the shared Android agent are still being initialized.
	signalingSessionID := randomString(12)
	signalingStartedAt := time.Now()
	readError := make(chan error, 1)
	conn.SetPingHandler(func(appData string) error {
		log.Printf(
			"signaling_client_ping session=%q age_ms=%d",
			signalingSessionID,
			time.Since(signalingStartedAt).Milliseconds(),
		)
		return conn.WriteControl(
			websocket.PongMessage,
			[]byte(appData),
			time.Now().Add(5*time.Second),
		)
	})
	conn.SetPongHandler(func(string) error {
		log.Printf(
			"signaling_client_pong session=%q age_ms=%d",
			signalingSessionID,
			time.Since(signalingStartedAt).Milliseconds(),
		)
		return nil
	})
	go func() {
		for {
			if _, _, readErr := conn.ReadMessage(); readErr != nil {
				select {
				case readError <- readErr:
				default:
				}
				return
			}
		}
	}()
	log.Printf("signaling_reader_started session=%q", signalingSessionID)

	deviceTypeAllowed := config.DeviceType == sagent.DEVICE_TYPE_ANDROID ||
		config.DeviceType == sagent.DEVICE_TYPE_IPHONE_USB
	if !deviceTypeAllowed || !wm.deviceAllowed(config.DeviceID) ||
		(config.DeviceType == sagent.DEVICE_TYPE_IPHONE_USB && config.DeviceID != sagent.IPHONE_USB_LOGICAL_DEVICE_ID) ||
		(config.DeviceType == sagent.DEVICE_TYPE_ANDROID && config.DeviceID == sagent.IPHONE_USB_LOGICAL_DEVICE_ID) {
		log.Printf(
			"Rejected screen request for unauthorized device type=%q id=%q",
			config.DeviceType,
			config.DeviceID,
		)
		conn.WriteJSON(map[string]any{
			"status":  "error",
			"message": "Device is not authorized",
			"stage":   "webrtc_init",
		})
		return
	}
	if config.DriverConfig == nil {
		conn.WriteJSON(map[string]any{
			"status":  "error",
			"message": "Driver configuration is required",
			"stage":   "webrtc_init",
		})
		return
	}
	if config.DeviceType == sagent.DEVICE_TYPE_IPHONE_USB {
		// The iPhone adapter is a single fixed loopback service. Never let a
		// remote controller influence its address, token file, or broadcaster
		// identity through driver_config/device_ip/device_port values.
		config.DeviceIP = "0"
		config.DevicePort = "0"
		config.AVSync = false
		config.UseLocalTimestamp = false
		config.PreviewOnly = false
		config.DriverConfig = map[string]string{
			"video_codec": "h264",
			"audio":       "true",
			"control":     "true",
			"microphone":  "true",
		}
	} else {
		// Every authorized Android ID is a fixed USB serial. IP and port are not
		// routing inputs and must not create parallel broadcaster/agent identities.
		config.DeviceIP = "0"
		config.DevicePort = "0"
		config.AVSync = false
		config.UseLocalTimestamp = false
		canonicalDriverConfig, configErr := canonicalAndroidDriverConfig(config.DriverConfig)
		if configErr != nil {
			log.Printf(
				"Rejected Android driver config for id=%q: %v",
				config.DeviceID,
				configErr,
			)
			conn.WriteJSON(map[string]any{
				"status":  "error",
				"message": "Android driver configuration is not authorized",
				"stage":   "webrtc_init",
			})
			return
		}
		config.DriverConfig = canonicalDriverConfig
	}
	log.Printf("Received connection driver config for type=%q id=%q", config.DeviceType, config.DeviceID)
	if wm.tryTripathPilot(conn, readError, config) {
		return
	}

	// Create a unique ID for one abstract device
	deviceIdentifier := config.DeviceType + "_" + config.DeviceID + "_" + config.DeviceIP + "_" + config.DevicePort
	// Hash the identifier to ensure it's a valid filename and not too long
	// h := sha256.New()
	// h.Write([]byte(deviceIdentifier))
	// deviceIdentifier = fmt.Sprintf("%x", h.Sum(nil))

	log.Printf("SDP offer has audio m-line: %v", strings.Contains(config.SDP, "m=audio"))
	finalSDP, receiptNo, err := wm.WebRTCManager.NewSubscriber(deviceIdentifier, config.SDP, config)
	if err != nil {
		log.Println("Failed to handle new connection:", err)
		conn.WriteJSON(map[string]any{"status": "error", "message": err.Error(), "stage": "webrtc_init"})
		conn.Close()
		return
	}
	sub, exists := wm.WebRTCManager.GetSubscriber(deviceIdentifier, receiptNo)
	if !exists {
		log.Printf("Failed to get subscriber for device %s", deviceIdentifier)
		conn.WriteJSON(map[string]any{"status": "error", "message": "Failed to get subscriber", "stage": "webrtc_init"})
		conn.Close()
		return
	}
	defer sub.PeerConnection.Close()
	if finalSDP == "" {
		log.Println("Failed to create WebRTC connection")
		conn.WriteJSON(map[string]any{"status": "error", "message": "Failed to create WebRTC connection", "stage": "webrtc_init"})
		conn.Close()
		return
	}
	select {
	case readErr := <-readError:
		log.Printf(
			"signaling_closed_during_init session=%q device=%q error=%q",
			signalingSessionID,
			deviceIdentifier,
			readErr,
		)
		if sub, exists := wm.WebRTCManager.GetSubscriber(deviceIdentifier, receiptNo); exists {
			sub.PeerConnection.Close()
		}
		return
	default:
	}
	log.Println("deviceIdentifier:", deviceIdentifier, "receiptNo:", receiptNo)
	conn.WriteJSON(map[string]any{"status": "ok", "sdp": finalSDP, "stage": "webrtc_init"})
	connectionDeadline := time.Now().Add(20 * time.Second)
	connectionTicker := time.NewTicker(250 * time.Millisecond)
	defer connectionTicker.Stop()
Loop:
	for {
		switch sub.PeerConnection.ConnectionState() {
		case webrtc.PeerConnectionStateFailed, webrtc.PeerConnectionStateClosed:
			log.Printf("Peer connection for device %s is in state %s, closing WebSocket", deviceIdentifier, sub.PeerConnection.ConnectionState())
			conn.WriteJSON(map[string]any{"status": "error", "message": "Peer connection failed or closed", "stage": "webrtc_connection"})
			conn.Close()
			return
		case webrtc.PeerConnectionStateConnected:
			break Loop
		default:
			if time.Now().After(connectionDeadline) {
				log.Printf(
					"Peer connection for device %s timed out before connected",
					deviceIdentifier,
				)
				conn.WriteJSON(map[string]any{
					"status":  "error",
					"message": "Peer connection timed out",
					"stage":   "webrtc_connection",
				})
				sub.PeerConnection.Close()
				return
			}
			select {
			case readErr := <-readError:
				log.Printf(
					"signaling_closed_during_peer_connect session=%q device=%q receipt=%d error=%q",
					signalingSessionID,
					deviceIdentifier,
					receiptNo,
					readErr,
				)
				sub.PeerConnection.Close()
				return
			case <-connectionTicker.C:
			}
		}
	}

	err = wm.WebRTCManager.Start(deviceIdentifier, receiptNo, config)
	if err != nil {
		log.Printf("Failed to start WebRTC session for device %s: %v", deviceIdentifier, err)
		conn.WriteJSON(map[string]any{"status": "error", "message": err.Error(), "stage": "webrtc_start"})
		conn.Close()
		return
	}
	select {
	case readErr := <-readError:
		log.Printf(
			"signaling_closed_during_agent_start session=%q device=%q receipt=%d error=%q",
			signalingSessionID,
			deviceIdentifier,
			receiptNo,
			readErr,
		)
		sub.PeerConnection.Close()
		return
	default:
	}
	agent, exists := wm.WebRTCManager.GetAgent(deviceIdentifier)
	if !exists {
		log.Printf("Failed to get agent for device %s", deviceIdentifier)
		conn.WriteJSON(map[string]any{"status": "error", "message": "Failed to get agent", "stage": "webrtc_metainfo"})
		conn.Close()
		return
	}
	capabilities := agent.Capabilities()
	log.Printf("Driver Capabilities: %+v", capabilities)
	media_meta := agent.GetMediaMeta()
	activeProfile, agentGeneration, sharedCapture :=
		wm.WebRTCManager.agentRuntimeInfo(deviceIdentifier)
	conn.WriteJSON(map[string]interface{}{
		"status":                   "ok",
		"capabilities":             capabilities,
		"media_meta":               media_meta,
		"stage":                    "webrtc_metainfo",
		"stream_profile":           activeProfile,
		"agent_generation":         agentGeneration,
		"shared_capture":           sharedCapture,
		"control_protocol_version": 1,
	})

	// Keep signaling alive so the client can distinguish a healthy session from
	// an orphaned PeerConnection. Browsers and URLSession answer WebSocket ping
	// frames at the protocol layer.
	pingTicker := time.NewTicker(15 * time.Second)
	defer pingTicker.Stop()
	for {
		select {
		case err := <-readError:
			log.Printf(
				"signaling_closed session=%q device=%q receipt=%d error=%q",
				signalingSessionID,
				deviceIdentifier,
				receiptNo,
				err,
			)
			sub.PeerConnection.Close()
			return
		case <-pingTicker.C:
			state := sub.PeerConnection.ConnectionState()
			if state == webrtc.PeerConnectionStateFailed ||
				state == webrtc.PeerConnectionStateClosed {
				return
			}
			if err := conn.WriteControl(
				websocket.PingMessage,
				nil,
				time.Now().Add(5*time.Second),
			); err != nil {
				log.Printf(
					"signaling_ping_failed device=%q receipt=%d error=%q",
					deviceIdentifier,
					receiptNo,
					err,
				)
				sub.PeerConnection.Close()
				return
			}
		}
	}
}

// func (wm *WebMaster) removeScreenSession(deviceIdentifier string) {
// 	log.Printf("Removing screen session: %s", deviceIdentifier)
// 	if session, exists := wm.ScreenSessions[deviceIdentifier]; exists {
// 		if session.WSConn != nil {
// 			session.WSConn.Close()
// 		}
// 	}
// 	delete(wm.ScreenSessions, deviceIdentifier)
// }
