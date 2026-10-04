package scrcpy

import (
	"errors"
	"fmt"
	"log"
	"time"
)

var ErrVideoStartupTimeout = errors.New("video capture produced no frame")

const videoStartupTimeout = 12 * time.Second

// Codec configuration and SEI packets are not evidence that capture is
// producing pictures. Accept both Annex-B start-code lengths, and inspect
// every NAL since vendors may prefix a picture with SPS/PPS/SEI.
func packetContainsVideoSlice(packet []byte, codec string) bool {
	for i := 0; i+3 < len(packet); i++ {
		if packet[i] != 0 || packet[i+1] != 0 || packet[i+2] != 1 {
			continue
		}
		header := packet[i+3]
		if codec == "h264" {
			typ := header & 0x1f
			if typ >= 1 && typ <= 5 {
				return true
			}
		} else if codec == "h265" && i+4 < len(packet) && (header>>1)&0x3f <= 31 {
			return true
		}
	}
	return false
}

// Only the first real video packet of each encoding session has a deadline.
// Silence after a frame may be a static screen. Metadata, codec config,
// audio and replayed cached frames do not count as captured video frames.
func (sd *ScrcpyDriver) beginVideoEpoch() {
	sd.videoHealthMutex.Lock()
	defer sd.videoHealthMutex.Unlock()
	if sd.videoEpochStarted.IsZero() || sd.videoEpochHasFrame {
		sd.videoEpochStarted = time.Now()
		sd.videoEpochHasFrame = false
	}
}

func (sd *ScrcpyDriver) observeVideoFrame() {
	sd.videoHealthMutex.Lock()
	first := !sd.videoEpochHasFrame
	elapsed := time.Since(sd.videoEpochStarted)
	sd.videoEpochHasFrame = true
	sd.videoHealthMutex.Unlock()
	sd.videoReadyOnce.Do(func() { close(sd.videoReady) })
	if first {
		log.Printf("scrcpy_video_first_frame device=%q scid=%s elapsed_ms=%d",
			sd.adbClient.deviceSerial, sd.scid, elapsed.Milliseconds())
	}
}

func (sd *ScrcpyDriver) watchVideoStartup() {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-sd.ctx.Done():
			return
		case <-ticker.C:
			sd.videoHealthMutex.Lock()
			expired := !sd.videoEpochHasFrame &&
				!sd.videoEpochStarted.IsZero() && time.Since(sd.videoEpochStarted) >= videoStartupTimeout
			sd.videoHealthMutex.Unlock()
			if expired {
				sd.reportFailure("video-startup", fmt.Errorf("%w within %s (device=%s encoder=%s)",
					ErrVideoStartupTimeout, videoStartupTimeout, sd.adbClient.deviceSerial, sd.options["video_encoder"]))
				return
			}
		}
	}
}
