package webservice

import (
	"io/fs"
	"log"
	"net"
	"net/http"
	"net/url"
	"strings"

	"github.com/gin-gonic/gin"
)

func (wm *WebMaster) ServePreview(host, port string) {
	if net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
		log.Panic("local preview must bind to a loopback IP address")
	}

	router := gin.New()
	router.Use(gin.Logger(), gin.Recovery(), localPreviewOnly())
	subFS, err := fs.Sub(wm.staticFS, "static")
	if err != nil {
		log.Panicf("prepare local preview static files: %v", err)
	}
	router.StaticFS("/static", http.FS(subFS))
	router.GET("/preview", func(context *gin.Context) {
		context.FileFromFS("preview.html", http.FS(wm.staticFS))
	})
	router.GET("/preview/config", func(context *gin.Context) {
		context.JSON(http.StatusOK, gin.H{
			"device_type":         "android",
			"device_id":           wm.primaryDeviceID(),
			"device_ip":           "0",
			"device_port":         "0",
			"av_sync":             false,
			"use_local_timestamp": false,
			"ice_mode":            "local",
			"stream_profile":      "shared-preview",
			"preview_only":        true,
			"driver_config": gin.H{
				"video_codec":         "h264",
				"video_bit_rate":      "2000000",
				"video_codec_options": "i-frame-interval=1,bitrate-mode=2",
				"max_size":            "1280",
				"max_fps":             "30",
				"audio":               "false",
				"control":             "true",
			},
		})
	})
	router.GET("/preview/ws", func(context *gin.Context) {
		if !localPreviewOriginAllowed(context.GetHeader("Origin")) {
			context.AbortWithStatusJSON(
				http.StatusForbidden,
				gin.H{"error": "local preview origin not allowed"},
			)
			return
		}
		wm.serveScreenWS(context)
	})
	router.GET("/healthz", func(context *gin.Context) {
		context.Status(http.StatusNoContent)
	})
	// Capability handshake for the host watchdog. Android agents recover in
	// place; a returning handset must not cause a process-wide gateway reload.
	router.GET("/healthz/android-recovery", func(context *gin.Context) {
		context.Status(http.StatusNoContent)
	})

	if err := router.Run(host + ":" + port); err != nil {
		log.Fatalf("Failed to start local preview server: %v", err)
	}
}

func localPreviewOnly() gin.HandlerFunc {
	return func(context *gin.Context) {
		host, _, err := net.SplitHostPort(context.Request.RemoteAddr)
		if err != nil {
			context.AbortWithStatus(http.StatusForbidden)
			return
		}
		remoteIP := net.ParseIP(host)
		if remoteIP == nil || !remoteIP.IsLoopback() {
			context.AbortWithStatus(http.StatusForbidden)
			return
		}
		requestHost := context.Request.Host
		hostName := requestHost
		if parsedHost, _, splitErr := net.SplitHostPort(requestHost); splitErr == nil {
			hostName = parsedHost
		}
		if hostName != "localhost" {
			requestIP := net.ParseIP(strings.Trim(hostName, "[]"))
			if requestIP == nil || !requestIP.IsLoopback() {
				context.AbortWithStatus(http.StatusForbidden)
				return
			}
		}
		context.Next()
	}
}

func localPreviewOriginAllowed(origin string) bool {
	parsed, err := url.Parse(origin)
	if err != nil || parsed.Scheme != "http" {
		return false
	}
	host := parsed.Hostname()
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
