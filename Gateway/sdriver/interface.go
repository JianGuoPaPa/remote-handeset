package sdriver

type SDriver interface {
	GetReceivers() (<-chan AVBox, <-chan AVBox, chan Event)
	SendEvent(event Event) error

	Start()
	Pause()

	RequestIDR(firstFrame bool)
	Capabilities() DriverCaps
	// CodecInfo() (videoCodec string, audioCodec string)
	MediaMeta() MediaMeta
	Stop()

	// ConfigDescription() map[string]string
}

// DriverLifecycle is implemented by drivers that can report a terminal
// transport/process failure independently of the media channels. Done must
// close exactly once. Err returns nil only for an intentional Stop.
type DriverLifecycle interface {
	Done() <-chan struct{}
	Err() error
}

// MicrophoneInputDriver is implemented by drivers that can inject a remote
// microphone stream. Payloads use the validated IUMC v1 wire format.
type MicrophoneInputDriver interface {
	SendMicrophonePacket(packet []byte) error
	MicrophoneStatus() <-chan []byte
}

// MicrophoneDemand is the authenticated phone-side request for controller
// microphone audio. Generation is supplied by the phone and scopes every
// acceptance and microphone session derived from the snapshot.
type MicrophoneDemand struct {
	Active      bool
	Generation  uint32
	ActiveCount uint32
	// Revision is driver-local ordering metadata. It is not sent over either
	// external protocol and resets when a new driver instance is created.
	Revision uint64
}

// MicrophoneDemandDriver is implemented by drivers that receive automatic
// microphone demand from the controlled device.
type MicrophoneDemandDriver interface {
	MicrophoneDemand() <-chan MicrophoneDemand
	CurrentMicrophoneDemand() MicrophoneDemand
}
