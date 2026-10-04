package webservice

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"io/fs"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

type WebMasterConfig struct {
	EnableAndroidDiscover bool
}

type WebMaster struct {
	// WSConns []*websocket.Conn

	WebRTCManager *WebRTCManager
	// ScreenSessions map[string]ScreenSession

	pin                  string
	UnlockAttemptRecords map[string]UnlockAttemptRecord
	jwtSecret            []byte
	originSecret         string
	allowedOrigins       map[string]struct{}
	fixedDeviceID        string
	allowedDeviceIDs     map[string]struct{}
	usedTicketNonces     map[string]int64
	usedTicketNoncesMu   sync.Mutex

	config              WebMasterConfig
	router              *gin.Engine
	devicesConnected    map[string]Device
	devicesDiscovered   map[string]Device
	devicesDiscoveredMu sync.RWMutex
	pauseDiscovery      bool
	staticFS            fs.FS
}

func New(config WebMasterConfig, staticFS fs.FS) *WebMaster {
	wm := &WebMaster{
		// ScreenSessions:       make(map[string]ScreenSession),
		config:               config,
		devicesDiscovered:    make(map[string]Device),
		staticFS:             staticFS,
		UnlockAttemptRecords: make(map[string]UnlockAttemptRecord),
		usedTicketNonces:     make(map[string]int64),
		WebRTCManager:        NewWebRTCManager(),
	}
	wm.jwtSecret = []byte(time.Now().String())
	return wm
}

func Default(staticFS fs.FS) *WebMaster {
	wm := New(WebMasterConfig{
		EnableAndroidDiscover: true,
	}, staticFS)
	return wm
}

func (wm *WebMaster) setRouter() {
	if strings.TrimSpace(wm.originSecret) == "" {
		log.Panic("WEBSCREEN_ORIGIN_SECRET is required")
	}
	if len(wm.allowedOrigins) == 0 {
		log.Panic("WEBSCREEN_ALLOWED_ORIGIN is required")
	}
	if len(wm.allowedDeviceIDs) == 0 {
		log.Panic("WEBSCREEN_DEVICE_ID is required")
	}

	// gin.SetMode(gin.ReleaseMode)
	r := gin.Default()
	r.Use(wm.originSecretMiddleware())
	subFS, _ := fs.Sub(wm.staticFS, "static")
	r.StaticFS("/static", http.FS(subFS))

	r.GET("/unlock", func(ctx *gin.Context) {
		ctx.FileFromFS("unlock.html", http.FS(wm.staticFS))
	})
	r.POST("/api/unlock", wm.handleUnlock)

	r.GET("/", func(ctx *gin.Context) {
		ctx.Redirect(302, "/console")
	})
	if wm.pin != "" {
		log.Println("Enable PIN middleware")
		r.Use(wm.HybridAuthMiddleware())
	}
	screen := r.Group("/screen")
	{
		screen.GET("/:id", func(ctx *gin.Context) {
			ctx.FileFromFS("screen.html", http.FS(wm.staticFS))
		})
		screen.GET("/ws", wm.handleScreenWS)
	}

	r.GET("/console", func(c *gin.Context) {
		c.FileFromFS("console.html", http.FS(wm.staticFS))
	})
	api := r.Group("/api")
	{
		api.GET("/device/list", wm.handleListDevices)
		api.GET("/device/connection", wm.handleGetDeviceConnection)
		api.POST("/device/connection", wm.handleSetDeviceConnection)
		api.GET("/device/configDescription", wm.handleDeviceConfigDescription)
		// api.GET("/generalConfigDescription", wm.handleGeneralConfigDescription)

		// api.POST("/device/discovery", wm.handleListDevicesDiscoveried)
		// api.POST("/setPIN", wm.handleSetPIN)
	}

	wm.router = r
}

func (wm *WebMaster) SetPIN(pin string) {
	wm.pin = pin
}

func (wm *WebMaster) SetGatewaySecurity(originSecret, allowedOrigins, fixedDeviceID string) {
	wm.originSecret = originSecret
	wm.fixedDeviceID = strings.TrimSpace(fixedDeviceID)
	wm.allowedDeviceIDs = make(map[string]struct{})
	for _, deviceID := range strings.Split(fixedDeviceID, ",") {
		deviceID = strings.TrimSpace(deviceID)
		if deviceID != "" {
			wm.allowedDeviceIDs[deviceID] = struct{}{}
		}
	}
	wm.allowedOrigins = make(map[string]struct{})
	for _, origin := range strings.Split(allowedOrigins, ",") {
		origin = strings.TrimSpace(origin)
		if origin != "" {
			wm.allowedOrigins[origin] = struct{}{}
		}
	}
}

func (wm *WebMaster) originSecretMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		provided := c.GetHeader("X-Webscreen-Origin-Secret")
		headerAllowed := len(provided) == len(wm.originSecret) &&
			subtle.ConstantTimeCompare([]byte(provided), []byte(wm.originSecret)) == 1
		if headerAllowed {
			c.Next()
			return
		}

		if c.Request.URL.Path == "/screen/ws" &&
			wm.originAllowed(c.GetHeader("Origin")) &&
			wm.consumeGatewayTicket(c.Query("ticket")) {
			// Avoid retaining the short-lived credential in request logs after
			// it has been validated.
			c.Request.URL.RawQuery = ""
			c.Next()
			return
		}

		c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
	}
}

func (wm *WebMaster) consumeGatewayTicket(ticket string) bool {
	parts := strings.Split(ticket, ".")
	if len(parts) != 4 || parts[0] != "v1" {
		return false
	}
	expires, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return false
	}
	now := time.Now().Unix()
	if expires < now || expires > now+90 {
		return false
	}
	if len(parts[2]) < 16 || len(parts[2]) > 64 {
		return false
	}
	providedSignature, err := base64.RawURLEncoding.DecodeString(parts[3])
	if err != nil {
		return false
	}
	payload := strings.Join(parts[:3], ".")
	mac := hmac.New(sha256.New, []byte(wm.originSecret))
	_, _ = mac.Write([]byte(payload))
	if !hmac.Equal(providedSignature, mac.Sum(nil)) {
		return false
	}

	wm.usedTicketNoncesMu.Lock()
	defer wm.usedTicketNoncesMu.Unlock()
	if wm.usedTicketNonces == nil {
		wm.usedTicketNonces = make(map[string]int64)
	}
	for nonce, nonceExpiry := range wm.usedTicketNonces {
		if nonceExpiry < now {
			delete(wm.usedTicketNonces, nonce)
		}
	}
	nonce := parts[2]
	if _, alreadyUsed := wm.usedTicketNonces[nonce]; alreadyUsed {
		return false
	}
	wm.usedTicketNonces[nonce] = expires
	return true
}

func (wm *WebMaster) originAllowed(origin string) bool {
	if len(wm.allowedOrigins) == 0 {
		return true
	}
	_, ok := wm.allowedOrigins[origin]
	return ok
}

func (wm *WebMaster) Serve(host, port string) {
	// if wm.config.EnableAndroidDiscover {
	// 	go wm.AndroidDevicesDiscovery()
	// }
	wm.setRouter()
	err := wm.router.Run(host + ":" + port)
	if err != nil {
		log.Fatalf("Failed to start server: %v", err)
	}
}

func (wm *WebMaster) Close() {
	// for k, v := range maps.All(wm.ScreenSessions) {
	// 	log.Printf("closing session %v", k)
	// 	v.Close()
	// }
}

func (wm *WebMaster) hasDeviceRestriction() bool {
	return len(wm.allowedDeviceIDs) > 0
}

func (wm *WebMaster) deviceAllowed(id string) bool {
	_, ok := wm.allowedDeviceIDs[id]
	return ok
}

func (wm *WebMaster) primaryDeviceID() string {
	for _, deviceID := range strings.Split(wm.fixedDeviceID, ",") {
		deviceID = strings.TrimSpace(deviceID)
		if deviceID != "" {
			return deviceID
		}
	}
	return ""
}
