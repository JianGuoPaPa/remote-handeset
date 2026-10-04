package webservice

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	sagent "webscreen/streamAgent"
)

const tripathPilotDevice = "ZY22HN3ZS4"

var tripathPilotSubscribers atomic.Int64

type tripathPilotConfig struct {
	Enabled    bool   `json:"enabled"`
	Device     string `json:"device"`
	URL        string `json:"url"`
	Token      string `json:"token"`
	CertSHA256 string `json:"cert_sha256"`
}

func readTripathPilotConfig() (tripathPilotConfig, error) {
	var c tripathPilotConfig
	home, err := os.UserHomeDir()
	if err != nil {
		return c, err
	}
	path := filepath.Join(home, ".remote-handset", "tripath-pilot", "gateway.json")
	info, err := os.Stat(path)
	if err != nil {
		return c, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 8192 {
		return c, errors.New("invalid pilot config file")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	if json.Unmarshal(b, &c) != nil {
		return c, errors.New("invalid pilot config")
	}
	if !c.Enabled {
		return c, errors.New("pilot disabled")
	}
	if err := validateTripathPilotConfig(c); err != nil {
		return c, err
	}
	return c, nil
}

func validateTripathPilotConfig(c tripathPilotConfig) error {
	u, err := url.Parse(c.URL)
	if c.Device != tripathPilotDevice || len(c.Token) < 32 || err != nil || u.Scheme != "wss" || u.Host != "70.39.202.192:19444" || u.Path != "/screen/ws" || u.RawQuery != "" || u.User != nil || u.Fragment != "" {
		return errors.New("invalid pilot destination")
	}
	pin, err := hex.DecodeString(c.CertSHA256)
	if err != nil || len(pin) != sha256.Size {
		return errors.New("invalid pilot certificate pin")
	}
	return nil
}

// Called only after normal device authorization and canonical config validation.
// The existing signaling reader owns the client socket; all subsequent protocol
// data flows server-to-client. Failure before an SDP answer falls through to the
// established capture driver. No route is taken from controller-supplied fields.
func (wm *WebMaster) tryTripathPilot(conn *websocket.Conn, readError <-chan error, config sagent.AgentConfig) bool {
	if config.DeviceType != sagent.DEVICE_TYPE_ANDROID || config.DeviceID != tripathPilotDevice {
		return false
	}
	c, err := readTripathPilotConfig()
	if err != nil {
		return false
	}
	pin, _ := hex.DecodeString(c.CertSHA256)
	dialer := websocket.Dialer{HandshakeTimeout: 4 * time.Second, TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS13, InsecureSkipVerify: true, VerifyConnection: func(cs tls.ConnectionState) error {
		if len(cs.PeerCertificates) == 0 {
			return errors.New("missing pilot certificate")
		}
		leaf := cs.PeerCertificates[0]
		hash := sha256.Sum256(leaf.Raw)
		if subtle.ConstantTimeCompare(hash[:], pin) != 1 {
			return errors.New("pilot certificate pin mismatch")
		}
		if time.Now().Before(leaf.NotBefore) || time.Now().After(leaf.NotAfter) {
			return errors.New("pilot certificate expired")
		}
		return leaf.VerifyHostname("70.39.202.192")
	}}}
	headers := http.Header{"Authorization": []string{"Bearer " + c.Token}}
	// App 33 allows 15 seconds for the answer. Bound the entire pilot probe,
	// leaving time for the established local capture/ICE fallback.
	attemptDeadline := time.Now().Add(5 * time.Second)
	attemptContext, cancelAttempt := context.WithDeadline(context.Background(), attemptDeadline)
	defer cancelAttempt()
	upstream, _, err := dialer.DialContext(attemptContext, c.URL, headers)
	if err != nil {
		log.Printf("tripath_pilot_fallback reason=dial_failed")
		return false
	}
	defer upstream.Close()
	upstream.SetReadLimit(2 << 20)
	_ = upstream.SetWriteDeadline(attemptDeadline)
	if upstream.WriteJSON(config) != nil {
		return false
	}
	_ = upstream.SetReadDeadline(attemptDeadline)
	messageType, first, err := upstream.ReadMessage()
	if err != nil {
		log.Printf("tripath_pilot_fallback reason=init_unavailable")
		return false
	}
	var initial struct{ Status, Stage, SDP string }
	if json.Unmarshal(first, &initial) != nil || initial.Status != "ok" || initial.Stage != "webrtc_init" || initial.SDP == "" {
		log.Printf("tripath_pilot_fallback reason=capture_not_ready")
		return false
	}
	select {
	case <-readError:
		return true
	default:
	}
	_ = upstream.SetReadDeadline(time.Time{})
	_ = conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	if conn.WriteMessage(messageType, first) != nil {
		return true
	}
	tripathPilotSubscribers.Add(1)
	defer tripathPilotSubscribers.Add(-1)
	log.Printf("tripath_pilot_session_started device=%q", tripathPilotDevice)
	defer log.Printf("tripath_pilot_session_closed device=%q", tripathPilotDevice)
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-readError:
			_ = upstream.Close()
		case <-done:
		}
	}()
	for {
		kind, data, err := upstream.ReadMessage()
		if err != nil {
			return true
		}
		_ = conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
		if conn.WriteMessage(kind, data) != nil {
			return true
		}
	}
}
