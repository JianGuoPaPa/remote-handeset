package comm

type SPSInfo struct {
	Width              uint32  // 显示宽度（扣除裁剪后）
	Height             uint32  // 显示高度（扣除裁剪后）
	FrameRate          float64 // 暂不支持 (需要解析 VUI，代价过高)
	Profile            uint8   // General Profile IDC
	ConstraintSetFlags uint8   // H.265 不像 H.264 有单个 byte 的 constraint，这里留空或存 Tier
	Level              string  // Level IDC (e.g. "5.1")
	Tier               string  // "Main" or "High"
	ChromaFormat       uint32  // 1=4:2:0, etc.
}
