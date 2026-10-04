package scrcpy

import (
	"fmt"
	"log"
	"webscreen/sdriver"
)

func (sd *ScrcpyDriver) GetReceivers() (<-chan sdriver.AVBox, <-chan sdriver.AVBox, chan sdriver.Event) {
	return sd.VideoChan, sd.AudioChan, sd.ControlChan
}

func (sd *ScrcpyDriver) Start() {
	log.Println("ScrcpyDriver: Start called")
	if sd.videoConn != nil {
		sd.beginVideoEpoch()
		go sd.convertVideoFrame()
		go sd.watchVideoStartup()
	}
	if sd.audioConn != nil {
		go sd.convertAudioFrame()
	}
	if sd.controlConn != nil {
		go sd.transferControlMsg()
	}
}

func (sd *ScrcpyDriver) UpdateDriverConfig(config map[string]string) error {
	return nil
}

func (sd *ScrcpyDriver) Pause() {
	// sd.stopVideoReader()
}

func (sd *ScrcpyDriver) SendEvent(event sdriver.Event) error {
	switch e := event.(type) {
	case *sdriver.TouchEvent:
		return sd.SendTouchEvent(e)
	case *sdriver.KeyEvent:
		return sd.SendKeyEvent(e)
	case *sdriver.ScrollEvent:
		return sd.SendScrollEvent(e)
	case *sdriver.RotateEvent:
		return sd.RotateDevice()
	case *sdriver.GetClipboardEvent:
		return sd.SendGetClipboardEvent(e)
	case *sdriver.SetClipboardEvent:
		return sd.SendSetClipboardEvent(e)
	case *sdriver.UHIDCreateEvent:
		return sd.SendUHIDCreateEvent(e)
	case *sdriver.UHIDInputEvent:
		return sd.SendUHIDInputEvent(e)
	case *sdriver.UHIDDestroyEvent:
		return sd.SendUHIDDestroyEvent(e)
	case *sdriver.IDRReqEvent:
		return sd.requestIDR(false)
	default:
		return fmt.Errorf("scrcpy driver: unsupported event type %T", event)
	}
}

func (sd *ScrcpyDriver) RequestIDR(firstFrame bool) {
	if err := sd.requestIDR(firstFrame); err != nil {
		log.Printf("Request IDR failed: %v", err)
	}
}

func (sd *ScrcpyDriver) requestIDR(firstFrame bool) error {
	sd.cacheMutex.RLock()
	hasCachedFrame := len(sd.LastSPS) != 0 &&
		len(sd.LastPPS) != 0 && len(sd.LastIDR) != 0
	sd.cacheMutex.RUnlock()

	if firstFrame && hasCachedFrame {
		log.Println("First frame IDR request, sending cached key frame")
		sd.sendCachedKeyFrame()
	}

	// Startup, control messages and concurrent PLI requests share one reset
	// gate. RESET_VIDEO restarts capture; it is not a lightweight IDR request.
	return sd.KeyFrameRequest()
}

func (sd *ScrcpyDriver) Capabilities() sdriver.DriverCaps {
	return sd.capabilities
}

func (sd *ScrcpyDriver) MediaMeta() sdriver.MediaMeta {
	return sd.mediaMeta
}

func (sd *ScrcpyDriver) Stop() {
	sd.stopping.Store(true)
	sd.finish(nil)
}
