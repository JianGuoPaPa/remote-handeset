package scrcpy

import (
	"context"
	"encoding/binary"
	"net"
	"testing"
	"time"

	"webscreen/sdriver"
	"webscreen/sdriver/comm"
)

func newVideoReadyTestDriver(t *testing.T) *ScrcpyDriver {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	driver := &ScrcpyDriver{
		ctx: ctx, cancel: cancel,
		VideoChan:   make(chan sdriver.AVBox, 10),
		videoBuffer: comm.NewLinearBuffer(0),
		videoReady:  make(chan struct{}), lifecycleDone: make(chan struct{}),
		mediaMeta: sdriver.MediaMeta{VideoCodec: "h264"},
	}
	t.Cleanup(driver.Stop)
	return driver
}

func assertVideoNotReady(t *testing.T, driver *ScrcpyDriver) {
	t.Helper()
	select {
	case <-driver.VideoReady():
		t.Fatal("video ready without a real captured slice")
	default:
	}
}

func TestVideoReadyRequiresRealCapturedSlice(t *testing.T) {
	driver := newVideoReadyTestDriver(t)
	// The log-only identity has no cleanup resources, so it cannot invoke adb.
	driver.adbClient = NewADBClient("offline-test", "", driver.ctx)
	driver.beginVideoEpoch()
	assertVideoNotReady(t, driver)
	driver.sendCachedKeyFrame()
	<-driver.VideoChan
	assertVideoNotReady(t, driver)

	reader, writer := net.Pipe()
	driver.videoConn = reader
	t.Cleanup(func() { _ = writer.Close() })
	go driver.convertVideoFrame()
	writeFrame := func(nal byte, config bool) {
		t.Helper()
		packet := make([]byte, 18)
		binary.BigEndian.PutUint64(packet[:8], 100)
		if config {
			packet[0] |= 0x40
		}
		binary.BigEndian.PutUint32(packet[8:12], 6)
		copy(packet[12:], []byte{0, 0, 0, 1, nal, 0})
		if err := writer.SetWriteDeadline(time.Now().Add(time.Second)); err != nil {
			t.Fatal(err)
		}
		if _, err := writer.Write(packet); err != nil {
			t.Fatal(err)
		}
		select {
		case <-driver.VideoChan:
		case <-time.After(time.Second):
			t.Fatal("frame reader did not process packet")
		}
	}

	writeFrame(6, false) // SEI alone reaches observers, but is not a picture.
	assertVideoNotReady(t, driver)
	writeFrame(1, true) // A config-flagged packet must not signal readiness.
	assertVideoNotReady(t, driver)
	writeFrame(1, false)
	select {
	case <-driver.VideoReady():
	default:
		t.Fatal("real captured slice did not signal video readiness")
	}
	// Subsequent frames and video epochs retain one driver-lifetime signal.
	driver.beginVideoEpoch()
	writeFrame(1, false)
	driver.Stop()
}

func TestStoppingBeforeFirstFrameDoesNotSignalVideoReady(t *testing.T) {
	driver := newVideoReadyTestDriver(t)
	driver.beginVideoEpoch()
	driver.Stop()
	select {
	case <-driver.Done():
	default:
		t.Fatal("driver stop did not complete")
	}
	assertVideoNotReady(t, driver)
}
