package iphoneusb

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"webscreen/sdriver"
)

const (
	driverHeartbeatInterval = 4 * time.Second
	driverHeartbeatTimeout  = 12 * time.Second
)

type connectionBundle struct {
	video   *privateUnixSocket
	audio   *privateUnixSocket
	control *privateUnixSocket
}

func (bundle *connectionBundle) close() {
	if bundle == nil {
		return
	}
	bundle.video.close()
	bundle.audio.close()
	bundle.control.close()
}

type Driver struct {
	videoChan   chan sdriver.AVBox
	audioChan   chan sdriver.AVBox
	controlChan chan sdriver.Event
	statusChan  chan []byte
	demandChan  chan sdriver.MicrophoneDemand

	ctx    context.Context
	cancel context.CancelFunc

	socketDirectory string
	rfbConfig       directRFBConfig

	connectionMu sync.RWMutex
	connections  *connectionBundle
	initial      *connectionBundle
	rfbMu        sync.RWMutex
	rfb          *rfbClient
	demandMu     sync.RWMutex
	demand       sdriver.MicrophoneDemand

	mediaMu       sync.RWMutex
	mediaMeta     sdriver.MediaMeta
	parameterSets []byte

	started  atomic.Bool
	stopping atomic.Bool

	startOnce   sync.Once
	finishOnce  sync.Once
	workers     sync.WaitGroup
	done        chan struct{}
	errMu       sync.RWMutex
	terminalErr error
}

func New(config map[string]string) (*Driver, error) {
	socketDirectory, err := configuredDriverSocketDirectory(config)
	if err != nil {
		return nil, err
	}
	rfbConfig, err := loadDirectRFBConfig()
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	driver := &Driver{
		videoChan:       make(chan sdriver.AVBox, 8),
		audioChan:       make(chan sdriver.AVBox, 32),
		controlChan:     make(chan sdriver.Event, 8),
		statusChan:      make(chan []byte, 8),
		demandChan:      make(chan sdriver.MicrophoneDemand, 8),
		ctx:             ctx,
		cancel:          cancel,
		socketDirectory: socketDirectory,
		rfbConfig:       rfbConfig,
		done:            make(chan struct{}),
		mediaMeta: sdriver.MediaMeta{
			VideoCodec: "h264",
			AudioCodec: "opus",
			FPS:        30,
		},
	}
	connectCtx, connectCancel := context.WithTimeout(ctx, 10*time.Second)
	defer connectCancel()
	bundle, err := driver.connect(connectCtx)
	if err != nil {
		cancel()
		return nil, fmt.Errorf("connect iPhone USB driver: %w", err)
	}
	driver.initial = bundle
	return driver, nil
}

func (d *Driver) connect(ctx context.Context) (*connectionBundle, error) {
	bundle := &connectionBundle{}
	for _, endpoint := range []struct {
		name   string
		stream byte
		target **privateUnixSocket
	}{
		{name: "video.sock", stream: driverVideoStream, target: &bundle.video},
		{name: "audio.sock", stream: driverAudioStream, target: &bundle.audio},
		{name: "control.sock", stream: driverControlStream, target: &bundle.control},
	} {
		connected, dialErr := connectPrivateUnixSocket(
			ctx,
			d.socketDirectory,
			endpoint.name,
			endpoint.stream,
		)
		if dialErr != nil {
			bundle.close()
			return nil, dialErr
		}
		*endpoint.target = connected
	}
	if err := bundle.control.readAndValidateHello(); err != nil {
		bundle.close()
		return nil, err
	}
	return bundle, nil
}

func (d *Driver) GetReceivers() (<-chan sdriver.AVBox, <-chan sdriver.AVBox, chan sdriver.Event) {
	return d.videoChan, d.audioChan, d.controlChan
}

func (d *Driver) Start() {
	d.startOnce.Do(func() {
		d.started.Store(true)
		initial := d.initial
		d.initial = nil
		d.setConnections(initial)
		d.workers.Add(2)
		go func() {
			defer d.workers.Done()
			d.supervise(initial)
		}()
		go func() {
			defer d.workers.Done()
			d.superviseRFB()
		}()
		go func() {
			d.workers.Wait()
			d.finish(nil)
		}()
	})
}

func (d *Driver) supervise(bundle *connectionBundle) {
	backoff := 250 * time.Millisecond
	for {
		if bundle != nil {
			err := d.runConnection(bundle)
			bundle.close()
			d.setConnections(nil)
			if d.ctx.Err() != nil {
				return
			}
			if err != nil {
				log.Printf("iphone_usb_transport_reconnecting error=%q", err)
			}
		}

		timer := time.NewTimer(backoff)
		select {
		case <-d.ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
		connectCtx, cancel := context.WithTimeout(d.ctx, 10*time.Second)
		next, err := d.connect(connectCtx)
		cancel()
		if err != nil {
			log.Printf("iphone_usb_reconnect_failed error=%q", err)
			if backoff < 5*time.Second {
				backoff *= 2
				if backoff > 5*time.Second {
					backoff = 5 * time.Second
				}
			}
			bundle = nil
			continue
		}
		backoff = 250 * time.Millisecond
		bundle = next
	}
}

func (d *Driver) superviseRFB() {
	backoff := 250 * time.Millisecond
	for {
		if d.ctx.Err() != nil {
			return
		}
		// Reset the previous connection's demand before installing the next RFB
		// transport. The new monitor is started only after replaceRFB commits, so
		// its initial IUMD can never race ahead of the writable client pointer.
		d.publishMicrophoneDemandIdle()
		connectCtx, cancel := context.WithTimeout(d.ctx, 10*time.Second)
		client, err := connectDirectRFB(connectCtx, d.rfbConfig)
		cancel()
		if err != nil {
			if d.ctx.Err() != nil {
				return
			}
			log.Printf("iphone_usb_rfb_reconnect_failed error=%q", err)
			d.publishMicrophoneState("unavailable", 0)
			d.publishMicrophoneDemandIdle()
			if !d.waitForReconnect(backoff) {
				return
			}
			if backoff < 5*time.Second {
				backoff *= 2
				if backoff > 5*time.Second {
					backoff = 5 * time.Second
				}
			}
			continue
		}

		d.replaceRFB(client)
		client.startMonitor(func(demand rfbMicrophoneDemand) {
			// A callback from a retiring connection is transport-stale even when
			// the phone-side generation happens to match the replacement.
			if d.currentRFB() != client {
				return
			}
			d.publishMicrophoneDemand(demand.active, demand.generation, demand.activeCount)
		})
		d.publishMicrophoneState("ready", 0)
		backoff = 250 * time.Millisecond
		select {
		case <-d.ctx.Done():
			d.clearRFB(client)
			client.Close()
			return
		case <-client.Done():
		}
		if err := client.Err(); err != nil {
			log.Printf("iphone_usb_rfb_reconnecting error=%q", err)
		}
		d.clearRFB(client)
		client.Close()
		d.publishMicrophoneState("unavailable", 0)
		d.publishMicrophoneDemandIdle()
		if !d.waitForReconnect(backoff) {
			return
		}
	}
}

func (d *Driver) waitForReconnect(delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-d.ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func (d *Driver) runConnection(bundle *connectionBundle) error {
	d.setConnections(bundle)
	d.requestIDR()
	errCh := make(chan error, 4)
	go d.readVideo(bundle.video, errCh)
	go d.readAudio(bundle.audio, errCh)
	go d.readControl(bundle.control, errCh)
	go d.sendHeartbeat(bundle.control, driverHeartbeatInterval, errCh)
	select {
	case <-d.ctx.Done():
		return nil
	case err := <-errCh:
		return err
	}
}

func (d *Driver) setConnections(bundle *connectionBundle) {
	d.connectionMu.Lock()
	d.connections = bundle
	d.connectionMu.Unlock()
}

func (d *Driver) currentConnections() *connectionBundle {
	d.connectionMu.RLock()
	defer d.connectionMu.RUnlock()
	return d.connections
}

func (d *Driver) replaceRFB(next *rfbClient) {
	d.rfbMu.Lock()
	previous := d.rfb
	d.rfb = next
	d.rfbMu.Unlock()
	if previous != nil && previous != next {
		previous.Close()
	}
}

func (d *Driver) clearRFB(expected *rfbClient) {
	d.rfbMu.Lock()
	if d.rfb == expected {
		d.rfb = nil
	}
	d.rfbMu.Unlock()
}

func (d *Driver) currentRFB() *rfbClient {
	d.rfbMu.RLock()
	defer d.rfbMu.RUnlock()
	return d.rfb
}

func (d *Driver) readVideo(video *privateUnixSocket, errors chan<- error) {
	for {
		frame, err := video.read(maximumVideoAU)
		if err != nil {
			d.reportSessionError(errors, fmt.Errorf("video read: %w", err))
			return
		}
		switch frame.message {
		case driverConfigurationType:
			if frame.flags != 0 || frame.timestamp != 0 || frame.sequence != 0 ||
				frame.auxiliary != 0 || len(frame.payload) > maximumDriverConfiguration {
				d.reportSessionError(errors, fmt.Errorf("invalid driver video configuration frame"))
				return
			}
			config, parameterSets, parseErr := parseDriverVideoConfiguration(frame.payload)
			if parseErr != nil {
				d.reportSessionError(errors, parseErr)
				return
			}
			d.mediaMu.Lock()
			d.mediaMeta.Width = config.CodedWidth
			d.mediaMeta.Height = config.CodedHeight
			d.parameterSets = append(d.parameterSets[:0], parameterSets...)
			d.mediaMu.Unlock()
			if rfb := d.currentRFB(); rfb != nil {
				rfb.MatchVideoOrientation(config.CodedWidth, config.CodedHeight)
			}
		case driverMediaType:
			if frame.flags&^byte(1) != 0 || frame.timestamp == 0 ||
				len(frame.payload) == 0 {
				d.reportSessionError(errors, fmt.Errorf("invalid driver video access unit frame"))
				return
			}
			d.mediaMu.RLock()
			parameterSets := append([]byte(nil), d.parameterSets...)
			d.mediaMu.RUnlock()
			payload, parseErr := convertAVCCAccessUnit(
				frame.payload,
				parameterSets,
				frame.flags&1 != 0,
			)
			if parseErr != nil {
				d.reportSessionError(errors, parseErr)
				return
			}
			frame := sdriver.AVBox{
				Data:                 payload,
				PTS:                  frame.timestamp,
				ReceivedAtUnixMicros: time.Now().UnixMicro(),
			}
			select {
			case <-d.ctx.Done():
				return
			case d.videoChan <- frame:
			}
		default:
			d.reportSessionError(errors, fmt.Errorf("unexpected driver video message type %d", frame.message))
			return
		}
	}
}

func (d *Driver) readAudio(audio *privateUnixSocket, errors chan<- error) {
	configured := false
	for {
		message, err := audio.read(maximumOpus)
		if err != nil {
			d.reportSessionError(errors, fmt.Errorf("audio read: %w", err))
			return
		}
		switch message.message {
		case driverConfigurationType:
			if message.flags != 0 || message.timestamp != 0 || message.sequence != 0 ||
				message.auxiliary != 0 || len(message.payload) > maximumDriverConfiguration {
				d.reportSessionError(errors, fmt.Errorf("invalid driver audio configuration frame"))
				return
			}
			if _, parseErr := parseDriverAudioConfiguration(message.payload); parseErr != nil {
				d.reportSessionError(errors, parseErr)
				return
			}
			configured = true
		case driverMediaType:
			if !configured || message.flags&^byte(1) != 0 || message.timestamp == 0 ||
				len(message.payload) == 0 || message.auxiliary == 0 || message.auxiliary > 5760 {
				d.reportSessionError(errors, fmt.Errorf("invalid driver Opus packet frame"))
				return
			}
			frame := sdriver.AVBox{
				Data:                 append([]byte(nil), message.payload...),
				PTS:                  message.timestamp,
				ReceivedAtUnixMicros: time.Now().UnixMicro(),
			}
			select {
			case <-d.ctx.Done():
				return
			case d.audioChan <- frame:
			}
		default:
			d.reportSessionError(errors, fmt.Errorf("unexpected driver audio message type %d", message.message))
			return
		}
	}
}

func (d *Driver) readControl(control *privateUnixSocket, errors chan<- error) {
	for {
		message, err := control.read(maximumDriverControl)
		if err != nil {
			d.reportSessionError(errors, fmt.Errorf("control read: %w", err))
			return
		}
		switch message.message {
		case driverPongType:
			if message.flags != 0 || len(message.payload) != 0 || message.auxiliary != 0 {
				d.reportSessionError(errors, fmt.Errorf("invalid iPhone USB driver pong"))
				return
			}
			if !control.acceptPong(message.sequence, message.timestamp) {
				d.reportSessionError(errors, fmt.Errorf("unmatched iPhone USB driver pong"))
				return
			}
			control.lastPong.Store(time.Now().UnixNano())
		case driverErrorType:
			if message.flags != 0 || len(message.payload) == 0 {
				d.reportSessionError(errors, fmt.Errorf("invalid iPhone USB driver control error"))
				return
			}
			d.reportSessionError(errors, fmt.Errorf("iPhone USB driver control error: %s", string(message.payload)))
			return
		default:
			d.reportSessionError(errors, fmt.Errorf("unexpected iPhone USB driver control message type %d", message.message))
			return
		}
	}
}

func (d *Driver) sendHeartbeat(target *privateUnixSocket, interval time.Duration, errors chan<- error) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-d.ctx.Done():
			return
		case now := <-ticker.C:
			lastPong := time.Unix(0, target.lastPong.Load())
			if now.Sub(lastPong) > driverHeartbeatTimeout {
				d.reportSessionError(errors, fmt.Errorf("iPhone USB driver heartbeat timed out"))
				return
			}
			sequence := target.pingSeq.Add(1)
			timestamp := uint64(now.UnixMicro())
			target.recordPing(sequence, timestamp)
			if err := target.write(driverPingType, 0, timestamp, sequence, 0, nil); err != nil {
				target.forgetPing(sequence)
				d.reportSessionError(errors, fmt.Errorf("heartbeat write: %w", err))
				return
			}
		}
	}
}

func (d *Driver) reportSessionError(target chan<- error, err error) {
	select {
	case target <- err:
	default:
	}
}

func (d *Driver) SendEvent(event sdriver.Event) error {
	switch typed := event.(type) {
	case *sdriver.TouchEvent:
		return d.sendTouch(typed)
	case *sdriver.KeyEvent:
		return d.sendKey(typed)
	case *sdriver.SetClipboardEvent:
		return d.sendText(typed)
	case *sdriver.IDRReqEvent:
		return d.requestIDR()
	default:
		return fmt.Errorf("iPhone USB driver: unsupported event type %T", event)
	}
}

func (d *Driver) sendText(event *sdriver.SetClipboardEvent) error {
	if !event.Paste {
		return fmt.Errorf("iPhone text injection requires paste intent")
	}
	if len(event.Content) == 0 {
		return nil
	}
	rfb := d.currentRFB()
	if rfb == nil {
		return errors.New("iPhone USB control is reconnecting")
	}
	return rfb.SendText(event.Content)
}

func (d *Driver) sendTouch(event *sdriver.TouchEvent) error {
	if event.Width == 0 || event.Height == 0 || event.PointerID != 0 {
		return fmt.Errorf("invalid iPhone touch geometry")
	}
	// The control wire protocol uses Android MotionEvent action values:
	// 0=down, 1=up, 2=move. Do not use sdriver.TOUCH_ACTION_* here; those
	// legacy constants have a different ordering and would turn every drag into
	// down -> up -> down, leaving the remote pointer stuck.
	var mask byte
	switch event.Action {
	case 0: // down
		mask = 1
	case 2: // move
		mask = 1
	case 1: // up
		mask = 0
	default:
		return fmt.Errorf("unsupported iPhone touch action %d", event.Action)
	}
	rfb := d.currentRFB()
	if rfb == nil {
		return errors.New("iPhone USB control is reconnecting")
	}
	rfbWidth, rfbHeight := rfb.FramebufferSize()
	x := scaleRFBCoordinate(event.PosX, event.Width, rfbWidth)
	y := scaleRFBCoordinate(event.PosY, event.Height, rfbHeight)
	return rfb.SendPointer(mask, x, y)
}

func (d *Driver) sendKey(event *sdriver.KeyEvent) error {
	// Android key action 0 is key-down. The RFB button command is an atomic press,
	// so the matching key-up is intentionally ignored.
	if event.Action != 0 {
		return nil
	}
	var mask byte
	switch event.KeyCode {
	case 3:
		mask = 4 // TrollVNC Home/Menu
	case 26:
		mask = 2 // TrollVNC Power
	default:
		return fmt.Errorf("unsupported iPhone key code %d", event.KeyCode)
	}
	rfb := d.currentRFB()
	if rfb == nil {
		return errors.New("iPhone USB control is reconnecting")
	}
	return rfb.SendButtonPulse(mask)
}

func scaleRFBCoordinate(value uint32, sourceExtent, targetExtent uint16) uint16 {
	if sourceExtent == 0 || targetExtent == 0 {
		return 0
	}
	if sourceExtent == 1 || targetExtent == 1 {
		return 0
	}
	maximumSource := uint32(sourceExtent - 1)
	if value > maximumSource {
		value = maximumSource
	}
	scaled := uint64(value) * uint64(targetExtent-1) / uint64(sourceExtent-1)
	return uint16(scaled)
}

func (d *Driver) requestIDR() error {
	bundle := d.currentConnections()
	if bundle == nil || bundle.control == nil {
		return errors.New("iPhone USB video is reconnecting")
	}
	return bundle.control.write(
		driverRequestIDRType,
		0,
		0,
		0,
		0,
		nil,
	)
}

func (d *Driver) RequestIDR(bool) {
	if err := d.requestIDR(); err != nil && d.ctx.Err() == nil {
		log.Printf("iphone_usb_idr_request_failed error=%q", err)
	}
}

func (d *Driver) SendMicrophonePacket(packet []byte) error {
	rfb := d.currentRFB()
	if rfb == nil {
		return errors.New("iPhone USB microphone is reconnecting")
	}
	streamID := uint32(0)
	if len(packet) >= imumcHeaderSize {
		streamID = binary.BigEndian.Uint32(packet[8:12])
	}
	if err := rfb.SendMicrophonePacket(packet); err != nil {
		// Scope a write failure to the stream that caused it. A delayed status
		// for an old stream must never clear a newly established microphone
		// owner in WebRTCManager.
		d.publishMicrophoneState("unavailable", streamID)
		return err
	}
	if len(packet) >= imumcHeaderSize {
		switch packet[5] {
		case 0x01:
			d.publishMicrophoneState("active", streamID)
		}
	}
	return nil
}

func (d *Driver) MicrophoneStatus() <-chan []byte {
	return d.statusChan
}

func (d *Driver) MicrophoneDemand() <-chan sdriver.MicrophoneDemand {
	return d.demandChan
}

func (d *Driver) CurrentMicrophoneDemand() sdriver.MicrophoneDemand {
	d.demandMu.RLock()
	defer d.demandMu.RUnlock()
	return d.demand
}

func (d *Driver) publishMicrophoneDemand(active bool, generation, activeCount uint32) {
	next := sdriver.MicrophoneDemand{
		Active:      active,
		Generation:  generation,
		ActiveCount: activeCount,
	}
	d.demandMu.Lock()
	if d.demand.Active == next.Active &&
		d.demand.Generation == next.Generation &&
		d.demand.ActiveCount == next.ActiveCount {
		d.demandMu.Unlock()
		return
	}
	next.Revision = d.demand.Revision + 1
	d.demand = next
	d.demandMu.Unlock()
	select {
	case d.demandChan <- next:
	default:
		select {
		case <-d.demandChan:
		default:
		}
		select {
		case d.demandChan <- next:
		default:
		}
	}
}

func (d *Driver) publishMicrophoneDemandIdle() {
	current := d.CurrentMicrophoneDemand()
	d.publishMicrophoneDemand(false, current.Generation, 0)
}

func (d *Driver) publishMicrophoneState(state string, streamID uint32) {
	object := map[string]any{"v": 1, "type": "microphoneState", "state": state}
	if streamID != 0 {
		object["streamID"] = streamID
	}
	payload, _ := json.Marshal(object)
	select {
	case d.statusChan <- payload:
	default:
		select {
		case <-d.statusChan:
		default:
		}
		select {
		case d.statusChan <- payload:
		default:
		}
	}
}

func (d *Driver) Capabilities() sdriver.DriverCaps {
	return sdriver.DriverCaps{CanVideo: true, CanAudio: true, CanControl: true}
}

func (d *Driver) MediaMeta() sdriver.MediaMeta {
	d.mediaMu.RLock()
	defer d.mediaMu.RUnlock()
	return d.mediaMeta
}

func (d *Driver) Pause() {}

func (d *Driver) Stop() {
	d.stopping.Store(true)
	d.cancel()
	if d.initial != nil {
		d.initial.close()
		d.initial = nil
	}
	if bundle := d.currentConnections(); bundle != nil {
		bundle.close()
	}
	if rfb := d.currentRFB(); rfb != nil {
		rfb.Close()
	}
	if !d.started.Load() {
		d.finish(nil)
	}
	// Stop is the DriverLifecycle restart barrier. The shared Agent may reuse the
	// same media driver and RTP tracks immediately after this returns, so wait
	// until supervise has left and published its terminal lifecycle state.
	<-d.done
}

func (d *Driver) Done() <-chan struct{} { return d.done }

func (d *Driver) Err() error {
	d.errMu.RLock()
	defer d.errMu.RUnlock()
	return d.terminalErr
}

func (d *Driver) finish(err error) {
	d.finishOnce.Do(func() {
		d.errMu.Lock()
		d.terminalErr = err
		d.errMu.Unlock()
		close(d.done)
	})
}

func ConfigDescription() []sdriver.ConfigParamDescription {
	return []sdriver.ConfigParamDescription{
		{Name: "video_codec", Type: "string", Required: true, Default: "h264", Options: []string{"h264"}, Description: "video codec"},
		{Name: "audio", Type: "boolean", Required: true, Default: true, Description: "enable phone audio"},
		{Name: "control", Type: "boolean", Required: true, Default: true, Description: "enable device control"},
	}
}
