package main

import (
	"context"
	"embed"
	"flag"
	"io/fs"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"webscreen/webservice"
)

//go:embed public
var publicFS embed.FS

func main() {
	host := flag.String("host", "0.0.0.0", "host to bind the server to")
	port := flag.String("port", "8081", "server port")
	pin := flag.String("pin", "123456", "initial PIN for web access")
	originSecret := flag.String("origin-secret", os.Getenv("WEBSCREEN_ORIGIN_SECRET"), "shared secret required from the trusted web frontend")
	allowedOrigin := flag.String("allowed-origin", os.Getenv("WEBSCREEN_ALLOWED_ORIGIN"), "comma-separated browser origins allowed to open WebSockets")
	fixedDeviceID := flag.String("device-id", os.Getenv("WEBSCREEN_DEVICE_ID"), "comma-separated Android serials and iPhone logical IDs allowed by the gateway")
	previewHost := flag.String("preview-host", "127.0.0.1", "loopback host for the shared local preview")
	previewPort := flag.String("preview-port", "8080", "port for the shared local preview; empty disables it")
	flag.Parse()
	// pin should be 6 digits and only digits
	if *pin == "DISABLED" {
		*pin = ""
	} else {
		if len(*pin) != 6 {
			log.Fatal("PIN must be exactly 6 digits")
		}
		for _, ch := range *pin {
			if ch < '0' || ch > '9' {
				log.Fatal("PIN must contain only digits")
			}
		}
	}

	ctx, stop := signal.NotifyContext(
		context.Background(),
		os.Interrupt,
		syscall.SIGTERM,
	)
	defer stop()

	pub, _ := fs.Sub(publicFS, "public")
	webMaster := webservice.Default(pub)
	webMaster.SetPIN(*pin)
	webMaster.SetGatewaySecurity(*originSecret, *allowedOrigin, *fixedDeviceID)

	go webMaster.Serve(*host, *port)
	if *previewPort != "" {
		go webMaster.ServePreview(*previewHost, *previewPort)
	}
	// Keep a resident scrcpy agent for each allowed Android device so every
	// connection attaches to the existing encoder instead of cold-starting it.
	if *fixedDeviceID != "" {
		webMaster.WebRTCManager.PrewarmDevices(strings.Split(*fixedDeviceID, ","))
	}

	<-ctx.Done()
	log.Println("Gracefully closing")
	webMaster.Close()

}
