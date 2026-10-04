package sagent

import (
	"log"
	"time"
	"webscreen/sdriver"

	"github.com/pion/rtp"
	"github.com/pion/rtp/codecs"
)

func (sa *Agent) ServeVideoStream() {
	if sa.videoCh == nil {
		log.Println("[Agent] Video channel is nil, skipping video streaming")
		sa.controlCh <- sdriver.TextMsgEvent{Msg: "Video channel is nil, cannot stream video."}
		return
	}

	// 如果没有 WebRTC 轨道，但有 WebSocket 回调，则走纯 WS 线路
	if sa.videoTrack == nil {
		if sa.OnVideoFrame != nil {
			for vBox := range sa.videoCh {
				sa.OnVideoFrame(vBox.Data)
			}
		} else {
			log.Println("[Agent] videoTrack and OnVideoFrame both nil, skipping video streaming")
		}
		return
	}

	// 初始化打包器 (Pion 内部自带的工具)
	codec := sa.videoTrack.Codec().MimeType
	var payloader rtp.Payloader
	switch codec {
	case "video/H264":
		payloader = &codecs.H264Payloader{}
	case "video/H265":
		payloader = &codecs.H265Payloader{}
	default:
		log.Printf("Unsupported video codec: %s", codec)
		sa.controlCh <- sdriver.TextMsgEvent{Msg: "The video codec is not H264 neither H265, cannot stream video."}
		return
	}
	packetizer := rtp.NewPacketizer(
		1200, // MTU 大小，通常 1200 左右很安全
		0,    // Payload Type，Pion 会自动覆盖它，填 0 即可
		0,    // SSRC (TrackLocalStaticRTP 会自动覆盖它，填 0 即可)
		payloader,
		sa.rtpContinuity.VideoSequencer(),
		90000, // 视频的基准时钟频率 (WebRTC 规定视频固定为 90kHz)
	)
	for {
		var vBox sdriver.AVBox
		var ok bool
		select {
		case <-sa.ctx.Done():
			return
		case vBox, ok = <-sa.videoCh:
			if !ok {
				return
			}
		}
		sa.notifyFrameObservers(vBox)
		exactRtpTimestamp := sa.nextVideoTimestamp(vBox)

		packets := packetizer.Packetize(vBox.Data, 1)
		for _, p := range packets {
			p.Timestamp = exactRtpTimestamp
			if err := sa.videoTrack.WriteRTP(p); err != nil {
				log.Printf("Failed to write video RTP packet: %v", err)
				sa.controlCh <- sdriver.TextMsgEvent{Msg: "Failed to write video RTP packet."}
				return
			}
		}
	}
}

func (sa *Agent) ServeAudioStream() {
	if sa.audioCh == nil {
		sa.controlCh <- sdriver.TextMsgEvent{Msg: "Audio channel is nil, cannot stream audio."}
		return
	}

	if sa.audioTrack == nil {
		if sa.OnAudioFrame != nil {
			for aBox := range sa.audioCh {
				sa.OnAudioFrame(aBox.Data)
			}
		} else {
			log.Println("[Agent] audioTrack and OnAudioFrame both nil, skipping audio streaming")
		}
		return
	}

	packetizer := rtp.NewPacketizer(
		1200,
		0,
		0,
		&codecs.OpusPayloader{},
		sa.rtpContinuity.AudioSequencer(),
		48000,
	)

	for {
		var aBox sdriver.AVBox
		var ok bool
		select {
		case <-sa.ctx.Done():
			return
		case aBox, ok = <-sa.audioCh:
			if !ok {
				return
			}
		}
		currentAudioRTP := sa.rtpContinuity.AdvanceAudioTimestamp(960, time.Now())

		packets := packetizer.Packetize(aBox.Data, 1)
		for _, p := range packets {
			p.Timestamp = currentAudioRTP
			if err := sa.audioTrack.WriteRTP(p); err != nil {
				log.Printf("Failed to write audio RTP packet: %v", err)
				sa.controlCh <- sdriver.TextMsgEvent{Msg: "Failed to write audio RTP packet."}
				return
			}
		}
	}
}
