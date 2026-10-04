package scrcpy

import (
	"encoding/binary"
	"errors"
	"fmt"
	"log"
	"time"
	"webscreen/sdriver"
)

var errControlConnectionUnavailable = errors.New("scrcpy control connection is unavailable")

func (da *ScrcpyDriver) writeControlPacket(packet []byte) error {
	if da.controlConn == nil {
		return errControlConnectionUnavailable
	}
	da.controlWriteMutex.Lock()
	defer da.controlWriteMutex.Unlock()

	if err := da.controlConn.SetWriteDeadline(time.Now().Add(2 * time.Second)); err != nil {
		writeErr := fmt.Errorf("set scrcpy control write deadline: %w", err)
		da.reportFailure("control-write-deadline", writeErr)
		return writeErr
	}
	defer da.controlConn.SetWriteDeadline(time.Time{})

	for len(packet) > 0 {
		written, err := da.controlConn.Write(packet)
		if err != nil {
			writeErr := fmt.Errorf("write scrcpy control packet: %w", err)
			da.reportFailure("control-write", writeErr)
			return writeErr
		}
		if written == 0 {
			writeErr := errors.New("write scrcpy control packet: zero-byte write")
			da.reportFailure("control-write", writeErr)
			return writeErr
		}
		packet = packet[written:]
	}
	return nil
}

func (da *ScrcpyDriver) SendTouchEvent(e *sdriver.TouchEvent) error {
	// log.Printf("sending touch event: %v\n", e)
	// log.Printf("current video width height: %vx%v", da.VideoMeta.Width, da.VideoMeta.Height)
	// 1. 预分配一个固定大小的字节切片 (Scrcpy 协议触摸包固定 28 字节)
	// 这里的 buf 可以在对象池(sync.Pool)里复用，进一步减少 GC
	buf := make([]byte, 32)
	if uint8(e.Type()) != TYPE_INJECT_TOUCH_EVENT {
		return fmt.Errorf("mismatch event type: %d", e.Type())
	}
	// 2. 使用 Put 系列函数直接填充内存，速度极快
	buf[0] = byte(e.Type())                            // Type
	buf[1] = e.Action                                  // Action
	binary.BigEndian.PutUint64(buf[2:10], e.PointerID) // PointerID (8 bytes)
	binary.BigEndian.PutUint32(buf[10:14], e.PosX)     // PosX (4 bytes)
	binary.BigEndian.PutUint32(buf[14:18], e.PosY)     // PosY (4 bytes)
	binary.BigEndian.PutUint16(buf[18:20], e.Width)    // Width (2 bytes)
	binary.BigEndian.PutUint16(buf[20:22], e.Height)   // Height (2 bytes)
	binary.BigEndian.PutUint16(buf[22:24], e.Pressure) // Pressure (2 bytes)
	binary.BigEndian.PutUint32(buf[24:28], e.Buttons)  // Buttons (4 bytes)
	binary.BigEndian.PutUint32(buf[28:32], e.Buttons)  // Buttons (4 bytes)

	// 3. 一次性发送
	return da.writeControlPacket(buf)
}

func (da *ScrcpyDriver) SendKeyEvent(e *sdriver.KeyEvent) error {
	buf := make([]byte, 14)

	buf[0] = TYPE_INJECT_KEYCODE                    // Type
	buf[1] = e.Action                               // Action
	binary.BigEndian.PutUint32(buf[2:6], e.KeyCode) // KeyCode (4 bytes)
	binary.BigEndian.PutUint32(buf[6:10], 0)        // Repeat (4 bytes)
	binary.BigEndian.PutUint32(buf[10:14], 0)       // Meta (4 bytes)

	return da.writeControlPacket(buf)
}

// 	_, err := da.controlConn.Write(buf)
// 	if err != nil {
// 		log.Printf("Error sending key event: %v\n", err)
// 	}
// }

func (da *ScrcpyDriver) RotateDevice() error {
	log.Println("Sending Rotate Device command...")
	msg := []byte{TYPE_ROTATE_DEVICE}
	return da.writeControlPacket(msg)
	// da.mediaMeta.Width, da.mediaMeta.Height = da.mediaMeta.Height, da.mediaMeta.Width
}

func (da *ScrcpyDriver) SendScrollEvent(e *sdriver.ScrollEvent) error {
	// Scroll Event Structure (21 bytes):
	// 0: Type (1 byte)
	// 1-4: PosX (4 bytes)
	// 5-8: PosY (4 bytes)
	// 9-10: Width (2 bytes)
	// 11-12: Height (2 bytes)
	// 13-14: HScroll (2 bytes)
	// 15-16: VScroll (2 bytes)
	// 17-20: Buttons (4 bytes)

	buf := make([]byte, 21)
	buf[0] = TYPE_INJECT_SCROLL_EVENT
	binary.BigEndian.PutUint32(buf[1:5], e.PosX)
	binary.BigEndian.PutUint32(buf[5:9], e.PosY)
	binary.BigEndian.PutUint16(buf[9:11], e.Width)
	binary.BigEndian.PutUint16(buf[11:13], e.Height)
	binary.BigEndian.PutUint16(buf[13:15], e.HScroll)
	binary.BigEndian.PutUint16(buf[15:17], e.VScroll)
	binary.BigEndian.PutUint32(buf[17:21], e.Buttons)

	return da.writeControlPacket(buf)
}

func (da *ScrcpyDriver) SendSetClipboardEvent(e *sdriver.SetClipboardEvent) error {
	data := e.Content
	length := len(data)

	// Structure:
	// Type (1)
	// Sequence (8)
	// Paste (1)
	// Length (4)
	// Content (length)

	buf := make([]byte, 1+8+1+4+length)

	buf[0] = byte(e.Type())
	binary.BigEndian.PutUint64(buf[1:9], e.Sequence) // Sequence
	if e.Paste {
		buf[9] = 1
	} else {
		buf[9] = 0
	}
	binary.BigEndian.PutUint32(buf[10:14], uint32(length))
	copy(buf[14:], data)

	return da.writeControlPacket(buf)
}

func (da *ScrcpyDriver) SendGetClipboardEvent(e *sdriver.GetClipboardEvent) error {
	// Structure:
	// Type (1)
	// CopyKey (1)
	buf := make([]byte, 2)
	buf[0] = byte(e.Type())
	buf[1] = e.CopyKey

	return da.writeControlPacket(buf)
}

func (da *ScrcpyDriver) SendUHIDCreateEvent(e *sdriver.UHIDCreateEvent) error {
	nameSize := uint8(len(e.Name)) // 强转为 uint8

	// 包总大小:
	// 1(Type) + 2(ID) + 2(Vendor) + 2(Product) + 1(NameSize) + N(Name) + 2(DescSize) + N(Desc)
	totalSize := 1 + 2 + 2 + 2 + 1 + int(nameSize) + 2 + int(e.ReportDescSize)

	buf := make([]byte, totalSize)
	offset := 0

	// 1. Type
	buf[offset] = byte(e.Type())
	offset++

	// 2. ID
	binary.BigEndian.PutUint16(buf[offset:], e.ID)
	offset += 2

	// 3. Vendor
	binary.BigEndian.PutUint16(buf[offset:], e.VendorID)
	offset += 2

	// 4. Product
	binary.BigEndian.PutUint16(buf[offset:], e.ProductID)
	offset += 2

	// 5. Name Size (关键修改：只写 1 个字节)
	buf[offset] = nameSize
	offset++

	// 6. Name Data
	if nameSize > 0 {
		copy(buf[offset:], e.Name)
		offset += int(nameSize)
	}

	// 7. Desc Size (这里依然是 2 字节，因为 Java 里是 parseByteArray(2))
	binary.BigEndian.PutUint16(buf[offset:], e.ReportDescSize)
	offset += 2

	// 8. Desc Data
	copy(buf[offset:], e.ReportDesc)

	// log.Printf("Sending UHID_CREATE (Final Fix): ID=%d NameLen=%d", e.ID, nameSize)

	return da.writeControlPacket(buf)
}

func (da *ScrcpyDriver) SendUHIDInputEvent(e *sdriver.UHIDInputEvent) error {
	// Scrcpy UHID Input Protocol:
	// [1] Type
	// [2] ID (uint16)
	// [2] Size (uint16)
	// [N] Data

	totalSize := 1 + 2 + 2 + int(e.Size)
	buf := make([]byte, totalSize)

	offset := 0
	buf[offset] = byte(e.Type())
	offset++
	binary.BigEndian.PutUint16(buf[offset:], e.ID)
	offset += 2
	binary.BigEndian.PutUint16(buf[offset:], e.Size)
	offset += 2
	copy(buf[offset:], e.Data)

	return da.writeControlPacket(buf)
}

func (da *ScrcpyDriver) SendUHIDDestroyEvent(e *sdriver.UHIDDestroyEvent) error {
	// Scrcpy UHID Destroy Protocol:
	// [1] Type
	// [2] ID (uint16)

	buf := make([]byte, 3)
	buf[0] = byte(e.Type())
	binary.BigEndian.PutUint16(buf[1:], e.ID)

	return da.writeControlPacket(buf)
}

func (da *ScrcpyDriver) KeyFrameRequest() error {
	da.videoResetMutex.Lock()
	defer da.videoResetMutex.Unlock()
	if da.ctx.Err() != nil {
		return da.ctx.Err()
	}
	now := time.Now()
	da.videoHealthMutex.Lock()
	ready := da.videoEpochHasFrame
	da.videoHealthMutex.Unlock()
	if !ready {
		// Each encoder session already begins with an IDR. Resetting before
		// that frame arrives can indefinitely starve some vendor encoders.
		return nil
	}
	da.cacheMutex.Lock()
	if now.Sub(da.LastIDRRequestTime) < 3*time.Second {
		da.cacheMutex.Unlock()
		return nil
	}
	da.LastIDRRequestTime = now
	da.cacheMutex.Unlock()
	da.beginVideoEpoch()
	log.Printf("scrcpy_video_reset device=%q scid=%s", da.adbClient.deviceSerial, da.scid)
	return da.writeControlPacket([]byte{TYPE_RESET_VIDEO})
}
