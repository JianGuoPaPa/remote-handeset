package sagent

import (
	"context"
	"fmt"
	"log"
	"sync"
	"sync/atomic"
	"time"
	"webscreen/sdriver"
	"webscreen/sdriver/iphoneusb"
	linuxDriver "webscreen/sdriver/linux"
	"webscreen/sdriver/scrcpy"
	"webscreen/sdriver/sunshine"

	"github.com/pion/webrtc/v4"
)

type Agent struct {
	driver     sdriver.SDriver
	driverCaps sdriver.DriverCaps
	config     AgentConfig
	// chan
	videoCh   <-chan sdriver.AVBox
	audioCh   <-chan sdriver.AVBox
	controlCh chan sdriver.Event

	// WebRTC 相关
	videoTrack        *webrtc.TrackLocalStaticRTP
	audioTrack        *webrtc.TrackLocalStaticRTP
	startTime         time.Time
	useLocalTimestamp bool
	ctx               context.Context
	cancel            context.CancelFunc
	finishOnce        sync.Once
	terminalErrMu     sync.RWMutex
	terminalErr       error
	startedAtUnixNano atomic.Int64

	frameObserversMu sync.RWMutex
	frameObservers   map[string]func(FrameObservation)
	rtpContinuity    *RTPContinuity
	lastVideoPTS     uint64
	hasVideoPTS      bool

	// WebSocket 回调
	OnVideoFrame func([]byte)
	OnAudioFrame func([]byte)
}

// ========================
// SAgent 负责初始化driver并接受来自sdriver的数据，并处理来自前端的控制命令。
// 提供一系列Hook
// ========================
func New(config AgentConfig, videoTrack *webrtc.TrackLocalStaticRTP, audioTrack *webrtc.TrackLocalStaticRTP) *Agent {
	return NewWithRTPContinuity(
		config,
		videoTrack,
		audioTrack,
		NewRTPContinuity(),
	)
}

func NewWithRTPContinuity(
	config AgentConfig,
	videoTrack *webrtc.TrackLocalStaticRTP,
	audioTrack *webrtc.TrackLocalStaticRTP,
	rtpContinuity *RTPContinuity,
) *Agent {
	ctx, cancel := context.WithCancel(context.Background())
	if rtpContinuity == nil {
		rtpContinuity = NewRTPContinuity()
	}
	sa := &Agent{
		config:            config,
		videoTrack:        videoTrack,
		audioTrack:        audioTrack,
		useLocalTimestamp: config.UseLocalTimestamp,
		ctx:               ctx,
		cancel:            cancel,
		frameObservers:    make(map[string]func(FrameObservation)),
		rtpContinuity:     rtpContinuity,
	}
	log.Printf("AVSync: %v, UseLocalTimestamp: %v", config.AVSync, config.UseLocalTimestamp)
	log.Printf("Driver config: %+v", config.DriverConfig)
	return sa
}

func (sa *Agent) nextVideoTimestamp(frame sdriver.AVBox) uint32 {
	now := time.Now()
	samePresentationTime := sa.hasVideoPTS && frame.PTS == sa.lastVideoPTS
	requestedDeltaTicks := uint64(0)
	if sa.hasVideoPTS && frame.PTS > sa.lastVideoPTS {
		requestedDeltaTicks = (frame.PTS - sa.lastVideoPTS) * 90 / 1_000
	}
	if sa.useLocalTimestamp {
		requestedDeltaTicks = 0
		samePresentationTime = frame.NoDuration && samePresentationTime
	}
	sa.lastVideoPTS = frame.PTS
	sa.hasVideoPTS = true
	return sa.rtpContinuity.AdvanceVideoTimestamp(
		requestedDeltaTicks,
		samePresentationTime,
		now,
	)
}

func (sa *Agent) InitDriver(finalCodec webrtc.RTPCodecParameters) error {
	sa.config.DriverConfig["webrtc_codec_level"] = fmt.Sprintf("%d||%s||%s", finalCodec.PayloadType, finalCodec.MimeType, finalCodec.SDPFmtpLine)
	switch sa.config.DeviceType {
	// case DEVICE_TYPE_DUMMY:
	// 	// 初始化 Dummy Driver
	// 	dummyDriver, err := dummy.New(sa.config.DriverConfig)
	// 	if err != nil {
	// 		log.Printf("Failed to initialize dummy driver: %v", err)
	// 		return err
	// 	}
	// 	sa.driver = dummyDriver
	case DEVICE_TYPE_ANDROID:
		// 初始化 Android Driver
		sa.config.DriverConfig["deviceID"] = sa.config.DeviceID
		androidDriver, err := scrcpy.New(sa.config.DriverConfig)
		if err != nil {
			log.Printf("Failed to initialize Android driver: %v", err)
			return err
		}
		sa.driver = androidDriver
	case DEVICE_TYPE_IPHONE_USB:
		iphoneDriver, err := iphoneusb.New(sa.config.DriverConfig)
		if err != nil {
			log.Printf("Failed to initialize iPhone USB driver: %v", err)
			return err
		}
		sa.driver = iphoneDriver
	case DEVICE_TYPE_LINUX, "xvfb":
		// 初始化 Linux Driver
		driver, err := linuxDriver.New(sa.config.DriverConfig)
		if err != nil {
			log.Printf("Failed to initialize Linux driver: %v", err)
			return err
		}
		sa.driver = driver
	case DEVICE_TYPE_SUNSHINE:
		sunshine.SSTest()
	default:
		log.Printf("Unsupported device type: %s", sa.config.DeviceType)
		return fmt.Errorf("unsupported device type: %s", sa.config.DeviceType)
	}
	sa.driverCaps = sa.driver.Capabilities()
	sa.videoCh, sa.audioCh, sa.controlCh = sa.driver.GetReceivers()
	return nil
}

func (sa *Agent) SendMicrophonePacket(packet []byte) error {
	driver, ok := sa.driver.(sdriver.MicrophoneInputDriver)
	if !ok {
		return fmt.Errorf("driver does not support microphone input")
	}
	return driver.SendMicrophonePacket(packet)
}

func (sa *Agent) MicrophoneStatus() (<-chan []byte, bool) {
	driver, ok := sa.driver.(sdriver.MicrophoneInputDriver)
	if !ok {
		return nil, false
	}
	return driver.MicrophoneStatus(), true
}

func (sa *Agent) MicrophoneDemand() (<-chan sdriver.MicrophoneDemand, bool) {
	driver, ok := sa.driver.(sdriver.MicrophoneDemandDriver)
	if !ok {
		return nil, false
	}
	return driver.MicrophoneDemand(), true
}

func (sa *Agent) CurrentMicrophoneDemand() (sdriver.MicrophoneDemand, bool) {
	driver, ok := sa.driver.(sdriver.MicrophoneDemandDriver)
	if !ok {
		return sdriver.MicrophoneDemand{}, false
	}
	return driver.CurrentMicrophoneDemand(), true
}

func (sa *Agent) Close() {
	sa.finish(nil)
}

func (sa *Agent) Done() <-chan struct{} {
	return sa.ctx.Done()
}

// VideoReady reports the current driver's first real captured picture. A nil
// channel means the driver has no readiness signal. Callers must also observe
// Done and a deadline; successful InitDriver/Start alone does not prove video.
func (sa *Agent) VideoReady() <-chan struct{} {
	if driver, ok := sa.driver.(interface{ VideoReady() <-chan struct{} }); ok {
		return driver.VideoReady()
	}
	return nil
}

func (sa *Agent) Err() error {
	sa.terminalErrMu.RLock()
	defer sa.terminalErrMu.RUnlock()
	return sa.terminalErr
}

func (sa *Agent) StartedAt() (time.Time, bool) {
	value := sa.startedAtUnixNano.Load()
	if value == 0 {
		return time.Time{}, false
	}
	return time.Unix(0, value), true
}

func (sa *Agent) GetCodecInfo() (string, string) {
	m := sa.driver.MediaMeta()
	return m.VideoCodec, m.AudioCodec
}

func (sa *Agent) GetMediaMeta() sdriver.MediaMeta {
	return sa.driver.MediaMeta()
}

func (sa *Agent) Capabilities() sdriver.DriverCaps {
	return sa.driver.Capabilities()
}

func (sa *Agent) Start() {
	sa.startTime = time.Now() // 服务器基准时间线
	sa.startedAtUnixNano.Store(sa.startTime.UnixNano())
	sa.driver.Start()
	go sa.monitorDriverLifecycle()
	go sa.ServeVideoStream()
	go sa.ServeAudioStream()

	if sa.ctx.Err() != nil {
		return
	}
	sa.driver.RequestIDR(true)
}

func (sa *Agent) PLIRequest() {
	sa.driver.RequestIDR(false)
}

func (sa *Agent) HandleEvent(raw []byte) error {
	if !sa.driverCaps.CanControl {
		return fmt.Errorf("driver does not support control events")
	}
	event, err := sa.parseEvent(raw)
	if err != nil {
		log.Printf("[agent] Failed to parse control event: %v", err)
		return err
	}
	// log.Printf("Parsed control event: %+v", event)
	return sa.driver.SendEvent(event)
}

type FrameObservation struct {
	ReceivedAtUnixMicros int64
	ObservedAtUnixMicros int64
	PTS                  uint64
}

func (sa *Agent) AddFrameObserver(
	identifier string,
	observer func(FrameObservation),
) {
	sa.frameObserversMu.Lock()
	defer sa.frameObserversMu.Unlock()
	sa.frameObservers[identifier] = observer
}

func (sa *Agent) RemoveFrameObserver(identifier string) {
	sa.frameObserversMu.Lock()
	defer sa.frameObserversMu.Unlock()
	delete(sa.frameObservers, identifier)
}

func (sa *Agent) notifyFrameObservers(frame sdriver.AVBox) {
	if frame.NoDuration {
		return
	}
	observation := FrameObservation{
		ReceivedAtUnixMicros: frame.ReceivedAtUnixMicros,
		ObservedAtUnixMicros: time.Now().UnixMicro(),
		PTS:                  frame.PTS,
	}
	sa.frameObserversMu.RLock()
	observers := make([]func(FrameObservation), 0, len(sa.frameObservers))
	for _, observer := range sa.frameObservers {
		observers = append(observers, observer)
	}
	sa.frameObserversMu.RUnlock()
	for _, observer := range observers {
		observer(observation)
	}
}

func (sa *Agent) monitorDriverLifecycle() {
	lifecycle, ok := sa.driver.(sdriver.DriverLifecycle)
	if !ok {
		return
	}
	select {
	case <-sa.ctx.Done():
		return
	case <-lifecycle.Done():
		if sa.ctx.Err() != nil {
			return
		}
		driverErr := lifecycle.Err()
		if driverErr == nil {
			driverErr = fmt.Errorf("driver stopped unexpectedly")
		}
		sa.finish(driverErr)
	}
}

func (sa *Agent) finish(terminalErr error) {
	sa.finishOnce.Do(func() {
		sa.terminalErrMu.Lock()
		sa.terminalErr = terminalErr
		sa.terminalErrMu.Unlock()
		if terminalErr != nil {
			log.Printf(
				"agent_failed device=%q error=%q",
				sa.config.DeviceID,
				terminalErr,
			)
		} else {
			log.Printf("Closing agent for device %s", sa.config.DeviceID)
		}
		if sa.driver != nil {
			sa.driver.Stop()
			if lifecycle, ok := sa.driver.(sdriver.DriverLifecycle); ok {
				<-lifecycle.Done()
			}
		}
		// Agent.Done is the manager's restart barrier: do not close it until
		// the old driver's sockets, adb shell, and reverse mapping are gone.
		sa.cancel()
	})
}
