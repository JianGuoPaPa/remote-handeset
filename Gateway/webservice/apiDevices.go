package webservice

import (
	"webscreen/sdriver/iphoneusb"
	linuxDriver "webscreen/sdriver/linux"
	"webscreen/sdriver/scrcpy"
	sagent "webscreen/streamAgent"
	"webscreen/webservice/android"
	"webscreen/webservice/linux"

	"github.com/gin-gonic/gin"
)

func (wm *WebMaster) handleListDevices(c *gin.Context) {
	wm.devicesDiscoveredMu.RLock()
	defer wm.devicesDiscoveredMu.RUnlock()

	var devicesInfo []DeviceInfo
	devices, err := android.GetDevices()
	for _, d := range devices {
		if wm.hasDeviceRestriction() && !wm.deviceAllowed(d.GetDeviceID()) {
			continue
		}
		devicesInfo = append(devicesInfo, DeviceInfo{
			Type:     d.GetType(),
			DeviceID: d.GetDeviceID(),
			IP:       d.GetIP(),
			Port:     d.GetPort(),
			Status:   d.GetStatus(),
		})
	}
	if wm.deviceAllowed(sagent.IPHONE_USB_LOGICAL_DEVICE_ID) {
		devicesInfo = append(devicesInfo, DeviceInfo{
			Type:     sagent.DEVICE_TYPE_IPHONE_USB,
			DeviceID: sagent.IPHONE_USB_LOGICAL_DEVICE_ID,
			IP:       "127.0.0.1",
			Port:     18765,
			Status:   "configured",
		})
	}
	if !wm.hasDeviceRestriction() {
		linuxDevices, linuxErr := linux.GetDevices()
		if linuxErr != nil {
			c.JSON(500, gin.H{"error": linuxErr.Error()})
			return
		}
		for _, d := range linuxDevices {
			devicesInfo = append(devicesInfo, DeviceInfo{
				Type:     d.GetType(),
				DeviceID: d.GetDeviceID(),
				IP:       d.GetIP(),
				Port:     d.GetPort(),
				Status:   d.GetStatus(),
			})
		}
	}
	if err != nil {
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}

	c.JSON(200, gin.H{"devices": devicesInfo})
}

func (wm *WebMaster) handleListDevicesDiscoveried(c *gin.Context) {
	wm.devicesDiscoveredMu.RLock()
	defer wm.devicesDiscoveredMu.RUnlock()

	var devices []Device
	for _, v := range wm.devicesDiscovered {
		devices = append(devices, v)
	}

	c.JSON(200, devices)
}

// HandleConnectDevice 处理连接设备的请求
// POST /api/device/connect
func (wm *WebMaster) handleConnectDevice(c *gin.Context) {
	var req struct {
		DeviceType string `json:"device_type"`
		IP         string `json:"ip"`
		Port       string `json:"port"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(400, gin.H{"error": "Invalid request"})
		return
	}
	addr := req.IP
	if req.Port != "" {
		addr = addr + ":" + req.Port
	}
	switch req.DeviceType {
	case sagent.DEVICE_TYPE_ANDROID:
		if err := android.ConnectDevice(addr); err != nil {
			c.JSON(500, gin.H{"error": err.Error()})
			return
		}
	default:
		c.JSON(400, gin.H{"error": "Unsupported device type"})
		return
	}

	c.JSON(200, gin.H{"status": "connected"})
}

func (wm *WebMaster) handlePairDevice(c *gin.Context) {
	var req struct {
		DeviceType string `json:"device_type"`
		IP         string `json:"ip"`
		Port       string `json:"port"`
		Code       string `json:"code"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(400, gin.H{"error": "Invalid request"})
		return
	}
	addr := req.IP + ":" + req.Port
	switch req.DeviceType {
	case sagent.DEVICE_TYPE_ANDROID:
		if err := android.PairDevice(addr, req.Code); err != nil {
			c.JSON(500, gin.H{"error": err.Error()})
			return
		}
	default:
		c.JSON(400, gin.H{"error": "Unsupported device type"})
		return
	}

	c.JSON(200, gin.H{"status": "paired"})
}

func (wm *WebMaster) handleDeviceConfigDescription(c *gin.Context) {
	dtype := c.Query("device_type")
	id := c.Query("device_id")
	if wm.hasDeviceRestriction() && id != "" && !wm.deviceAllowed(id) {
		c.JSON(404, gin.H{"error": "device not found"})
		return
	}
	switch dtype {
	case sagent.DEVICE_TYPE_ANDROID:
		desc := scrcpy.ConfigDescription(id)
		c.JSON(200, desc)
	case sagent.DEVICE_TYPE_IPHONE_USB:
		if id != sagent.IPHONE_USB_LOGICAL_DEVICE_ID {
			c.JSON(404, gin.H{"error": "device not found"})
			return
		}
		c.JSON(200, iphoneusb.ConfigDescription())
	case sagent.DEVICE_TYPE_LINUX:
		desc := linuxDriver.ConfigDescription()
		c.JSON(200, desc)
	case "universal":
		desc := sagent.ConfigDescription()
		c.JSON(200, desc)
	default:
		c.JSON(400, gin.H{"error": "Unsupported device type"})
		return
	}

}
