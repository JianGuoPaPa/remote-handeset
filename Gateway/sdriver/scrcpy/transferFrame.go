package scrcpy

import (
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"time"

	// "bytes"
	"webscreen/sdriver"
)

func (da *ScrcpyDriver) convertVideoFrame() {
	var headerBuf [12]byte
	header := ScrcpyFrameHeader{}
	var nalTypeF func(byte) byte
	var nalType byte

	for {
		// read frame header
		if _, err := io.ReadFull(da.videoConn, headerBuf[:]); err != nil {
			log.Println("Failed to read scrcpy frame header:", err)
			da.reportFailure("video-read-header", err)
			return
		}

		// check if it's a session packet (MSB == 1)
		if (headerBuf[0] & 0x80) != 0 {
			da.beginVideoEpoch()
			width := binary.BigEndian.Uint32(headerBuf[4:8])
			height := binary.BigEndian.Uint32(headerBuf[8:12])
			log.Printf("Received session packet, new size: %dx%d", width, height)
			da.updateSize(width, height)
			continue
		}

		if err := readScrcpyFrameHeader(headerBuf[:], &header); err != nil {
			log.Println("Failed to read scrcpy frame header:", err)
			da.reportFailure("video-frame-header", err)
			return
		}
		// log.Println("header:", string(headerBuf[:]))

		da.cacheMutex.Lock()
		da.LastPTS = header.PTS
		da.cacheMutex.Unlock()
		// showFrameHeaderInfo(frame.Header)
		frameSize := int(header.Size)

		// 从 LinearBuffer 获取内存
		payloadBuf := da.videoBuffer.Get(frameSize)

		if _, err := io.ReadFull(da.videoConn, payloadBuf); err != nil {
			log.Println("Failed to read video frame payload:", err)
			da.reportFailure("video-read-payload", err)
			return
		}
		receivedAtUnixMicros := time.Now().UnixMicro()

		switch da.mediaMeta.VideoCodec {
		case "h265":
			nalTypeF = func(payloadBuf byte) byte { return (payloadBuf >> 1) & 0x3F }
		case "h264":
			nalTypeF = func(payloadBuf byte) byte { return payloadBuf & 0x1F }
		default:
			log.Println("Unknown codec type for NALU parsing:", da.mediaMeta.VideoCodec)
			da.reportFailure(
				"video-codec",
				fmt.Errorf("unknown codec %q", da.mediaMeta.VideoCodec),
			)
			return
		}
		if len(payloadBuf) < 5 {
			da.reportFailure(
				"video-frame",
				fmt.Errorf("invalid payload length %d", len(payloadBuf)),
			)
			return
		}
		nalType = nalTypeF(payloadBuf[4]) // 注意：payloadBuf 前 4 字节是起始码
		if !header.IsConfig && packetContainsVideoSlice(payloadBuf, da.mediaMeta.VideoCodec) {
			da.observeVideoFrame()
		}
		// log.Printf("ScrcpyDriver: isKeyFrame=%v, nal Type=%v, Size=%d bytes\n", header.IsKeyFrame, nalType, len(payloadBuf))
		// parts := bytes.Split(payloadBuf, []byte{0x00, 0x00, 0x00, 0x01})
		// for _, part := range parts {
		// 	if len(part) == 0 {
		// 		continue
		// 	}
		// 	log.Printf("NALU Part: nalType=%v, Size=%d bytes\n", nalTypeF(part[0]), len(part))
		// }
		if header.IsKeyFrame {
			switch nalType {
			case 5, 19, 20, 21: // H.264 IDR / H.265 IDR_W_RADL
				da.sendWithCachedConfigFrame(
					header.PTS,
					receivedAtUnixMicros,
					payloadBuf,
				)
				da.cacheMutex.Lock()
				da.LastIDR = createCopy(payloadBuf[4:]) // 去掉起始码
				da.cacheMutex.Unlock()
				// log.Printf("Cached new IDR frame, size=%d bytes\n", len(da.LastIDR))
				continue
			case 6, 39, 40: // H.264 SEI / H.265 Prefix/Suffix SEI
				payloadBuf = PruneSEI(payloadBuf, da.mediaMeta.VideoCodec)
				da.sendWithCachedConfigFrame(
					header.PTS,
					receivedAtUnixMicros,
					payloadBuf,
				)
				continue
			case 7, 32: // H.264 SPS / H.265 VPS
				da.updateCache(payloadBuf, da.mediaMeta.VideoCodec)
				if !da.emitVideoFrame(sdriver.AVBox{
					Data:                 payloadBuf,
					PTS:                  header.PTS,
					NoDuration:           true,
					ReceivedAtUnixMicros: receivedAtUnixMicros,
				}) {
					return
				}
				continue
			default:
				continue
			}
		}
		switch nalType {
		case 7, 32: // H.264 SPS / H.265 VPS
			da.updateCache(payloadBuf, da.mediaMeta.VideoCodec)
			continue
		}

		if !da.emitVideoFrame(sdriver.AVBox{
			Data:                 payloadBuf[4:],
			PTS:                  header.PTS,
			NoDuration:           false,
			ReceivedAtUnixMicros: receivedAtUnixMicros,
		}) {
			return
		}
	}
}

func (da *ScrcpyDriver) convertAudioFrame() {
	var headerBuf [12]byte
	header := ScrcpyFrameHeader{}
	for {
		// read frame header
		if _, err := io.ReadFull(da.audioConn, headerBuf[:]); err != nil {
			log.Println("Failed to read scrcpy frame header:", err)
			da.reportFailure("audio-read-header", err)
			return
		}
		if err := readScrcpyFrameHeader(headerBuf[:], &header); err != nil {
			log.Println("Failed to read scrcpy audio frame header:", err)
			da.reportFailure("audio-frame-header", err)
			return
		}
		frameSize := int(header.Size)
		payloadBuf := da.audioBuffer.Get(frameSize)

		// read frame payload
		if _, err := io.ReadFull(da.audioConn, payloadBuf); err != nil {
			log.Println("Failed to read scrcpy audio frame payload:", err)
			da.reportFailure("audio-read-payload", err)
			return
		}
		// if header.IsConfig {
		// 	log.Println("[scrcpy driver]Received audio config frame, skipping...")
		// 	continue
		// }

		if !da.emitAudioFrame(sdriver.AVBox{
			Data:       payloadBuf,
			PTS:        header.PTS,
			NoDuration: false,
		}) {
			return
		}

	}
}

func (da *ScrcpyDriver) transferControlMsg() {
	header := make([]byte, 5) // Type (1) + Length (4)
	for {
		_, err := io.ReadFull(da.controlConn, header)
		if err != nil {
			log.Println("Control connection read error:", err)
			da.reportFailure("control-read-header", err)
			return
		}

		msgType := header[0]
		length := binary.BigEndian.Uint32(header[1:])

		switch msgType {
		case DEVICE_MSG_TYPE_CLIPBOARD:
			content := make([]byte, length)
			_, err := io.ReadFull(da.controlConn, content)
			if err != nil {
				log.Println("Control connection read content error:", err)
				da.reportFailure("control-read-payload", err)
				return
			}
			select {
			case <-da.ctx.Done():
				return
			case da.ControlChan <- sdriver.ReceiveClipboardEvent{
				Content: content,
			}:
			}
		default:
			// Skip unknown message
			if length > 0 {
				if _, err := io.CopyN(
					io.Discard,
					da.controlConn,
					int64(length),
				); err != nil {
					da.reportFailure("control-skip-payload", err)
					return
				}
			}
		}
	}
}
