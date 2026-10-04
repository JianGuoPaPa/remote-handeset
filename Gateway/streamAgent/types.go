package sagent

// type deviceType string

const (
	DEVICE_TYPE_SUNSHINE   string = "sunshine"
	DEVICE_TYPE_LINUX      string = "linux"
	DEVICE_TYPE_ANDROID    string = "android"
	DEVICE_TYPE_IPHONE_USB string = "iphone-usb"
	DEVICE_TYPE_DUMMY      string = "dummy"
)

// IPHONE_USB_LOGICAL_DEVICE_ID is the public routing identifier. The physical
// iPhone UDID remains private to the loopback Console and is never sent to a
// controller or relay.
const IPHONE_USB_LOGICAL_DEVICE_ID = "iphone11-usb"

type AgentConfig struct {
	DeviceType        string            `json:"device_type"`
	DeviceID          string            `json:"device_id"`
	DeviceIP          string            `json:"device_ip"`
	DevicePort        string            `json:"device_port"`
	SDP               string            `json:"sdp"`
	AVSync            bool              `json:"av_sync"`
	UseLocalTimestamp bool              `json:"use_local_timestamp"`
	ICEMode           string            `json:"ice_mode,omitempty"`
	StreamProfile     string            `json:"stream_profile,omitempty"`
	PreviewOnly       bool              `json:"preview_only,omitempty"`
	DriverConfig      map[string]string `json:"driver_config"`
}

type ConfigParamDescription struct {
	Name     string   `json:"name"`
	Type     string   `json:"type"`
	Required bool     `json:"required"`
	Default  any      `json:"default,omitempty"`
	Options  []string `json:"options,omitempty"`
	// if true, the frontend can show this config param more prominently, like in a badge or highlight it in the UI, to indicate it's important or commonly used.
	Badge bool `json:"badge,omitempty"`

	Description string `json:"description"`
}
