package iphoneusb

import (
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
)

const (
	videoHeaderSize = 20
	audioHeaderSize = 24
	maximumVideoAU  = 8 * 1024 * 1024
	maximumOpus     = 64 * 1024
)

type videoConfiguration struct {
	V           int    `json:"v"`
	Type        string `json:"type"`
	Codec       string `json:"codec"`
	CodedWidth  uint32 `json:"codedWidth"`
	CodedHeight uint32 `json:"codedHeight"`
	Description string `json:"description"`
}

type driverAudioConfiguration struct {
	Codec           string `json:"codec"`
	SampleRate      uint32 `json:"sampleRate"`
	Channels        uint16 `json:"channels"`
	FrameDurationUS uint32 `json:"frameDurationUs"`
}

func parseVideoConfiguration(raw []byte) (videoConfiguration, []byte, error) {
	var config videoConfiguration
	if err := json.Unmarshal(raw, &config); err != nil {
		return config, nil, fmt.Errorf("decode video configuration: %w", err)
	}
	if config.V != 1 || config.Type != "config" || config.CodedWidth == 0 ||
		config.CodedHeight == 0 || config.CodedWidth > 8192 || config.CodedHeight > 8192 {
		return config, nil, fmt.Errorf("invalid video configuration")
	}
	if len(config.Codec) < 5 || len(config.Codec) > 64 {
		return config, nil, fmt.Errorf("invalid video codec descriptor")
	}
	avcc, err := base64.StdEncoding.DecodeString(config.Description)
	if err != nil {
		return config, nil, fmt.Errorf("decode AVC configuration: %w", err)
	}
	parameterSets, err := parseAVCDecoderConfigurationRecord(avcc)
	if err != nil {
		return config, nil, err
	}
	return config, parameterSets, nil
}

func parseDriverVideoConfiguration(raw []byte) (videoConfiguration, []byte, error) {
	var config videoConfiguration
	if err := json.Unmarshal(raw, &config); err != nil {
		return config, nil, fmt.Errorf("decode driver video configuration: %w", err)
	}
	if config.V != 0 || config.Type != "" || config.CodedWidth == 0 ||
		config.CodedHeight == 0 || config.CodedWidth > 8192 || config.CodedHeight > 8192 {
		return config, nil, fmt.Errorf("invalid driver video configuration")
	}
	if len(config.Codec) < 5 || len(config.Codec) > 64 {
		return config, nil, fmt.Errorf("invalid driver video codec descriptor")
	}
	avcc, err := base64.StdEncoding.DecodeString(config.Description)
	if err != nil {
		return config, nil, fmt.Errorf("decode driver AVC configuration: %w", err)
	}
	parameterSets, err := parseAVCDecoderConfigurationRecord(avcc)
	if err != nil {
		return config, nil, err
	}
	return config, parameterSets, nil
}

func parseDriverAudioConfiguration(raw []byte) (driverAudioConfiguration, error) {
	var config driverAudioConfiguration
	if err := json.Unmarshal(raw, &config); err != nil {
		return config, fmt.Errorf("decode driver audio configuration: %w", err)
	}
	if config.Codec != "opus" || config.SampleRate != 48000 ||
		config.Channels == 0 || config.Channels > 2 ||
		config.FrameDurationUS == 0 || config.FrameDurationUS > 120000 {
		return config, fmt.Errorf("invalid driver audio configuration")
	}
	return config, nil
}

func parseAVCDecoderConfigurationRecord(avcc []byte) ([]byte, error) {
	if len(avcc) < 7 || avcc[0] != 1 || avcc[4]&0x03 != 3 {
		return nil, fmt.Errorf("invalid AVCDecoderConfigurationRecord")
	}
	offset := 6
	numSPS := int(avcc[5] & 0x1f)
	if numSPS == 0 {
		return nil, fmt.Errorf("AVC configuration has no SPS")
	}
	parameterSets := make([]byte, 0, len(avcc)+32)
	readSet := func() error {
		if offset+2 > len(avcc) {
			return fmt.Errorf("truncated AVC parameter set length")
		}
		length := int(binary.BigEndian.Uint16(avcc[offset : offset+2]))
		offset += 2
		if length == 0 || offset+length > len(avcc) {
			return fmt.Errorf("invalid AVC parameter set length")
		}
		parameterSets = append(parameterSets, 0, 0, 0, 1)
		parameterSets = append(parameterSets, avcc[offset:offset+length]...)
		offset += length
		return nil
	}
	for index := 0; index < numSPS; index++ {
		if err := readSet(); err != nil {
			return nil, err
		}
	}
	if offset >= len(avcc) {
		return nil, fmt.Errorf("AVC configuration has no PPS count")
	}
	numPPS := int(avcc[offset])
	offset++
	if numPPS == 0 {
		return nil, fmt.Errorf("AVC configuration has no PPS")
	}
	for index := 0; index < numPPS; index++ {
		if err := readSet(); err != nil {
			return nil, err
		}
	}
	return parameterSets, nil
}

func parseVideoAccessUnit(raw []byte, parameterSets []byte) (data []byte, pts uint64, sequence uint32, keyFrame bool, err error) {
	if len(raw) < videoHeaderSize || len(raw) > videoHeaderSize+maximumVideoAU ||
		string(raw[:4]) != "IUVC" || raw[4] != 1 || binary.BigEndian.Uint16(raw[6:8]) != videoHeaderSize ||
		raw[5]&^byte(1) != 0 {
		return nil, 0, 0, false, fmt.Errorf("invalid IUVC access unit")
	}
	keyFrame = raw[5]&1 != 0
	pts = binary.BigEndian.Uint64(raw[8:16])
	sequence = binary.BigEndian.Uint32(raw[16:20])
	avcc := raw[videoHeaderSize:]
	annexB, err := convertAVCCAccessUnit(avcc, parameterSets, keyFrame)
	if err != nil {
		return nil, 0, 0, false, err
	}
	return annexB, pts, sequence, keyFrame, nil
}

func convertAVCCAccessUnit(avcc []byte, parameterSets []byte, keyFrame bool) ([]byte, error) {
	if len(avcc) == 0 {
		return nil, fmt.Errorf("empty AVCC access unit")
	}
	capacity := len(avcc) + 32
	if keyFrame {
		capacity += len(parameterSets)
	}
	annexB := make([]byte, 0, capacity)
	if keyFrame {
		if len(parameterSets) == 0 {
			return nil, fmt.Errorf("key frame arrived before AVC configuration")
		}
		annexB = append(annexB, parameterSets...)
	}
	for offset := 0; offset < len(avcc); {
		if offset+4 > len(avcc) {
			return nil, fmt.Errorf("truncated AVCC NAL length")
		}
		nalLength := int(binary.BigEndian.Uint32(avcc[offset : offset+4]))
		offset += 4
		if nalLength <= 0 || offset+nalLength > len(avcc) {
			return nil, fmt.Errorf("invalid AVCC NAL length")
		}
		annexB = append(annexB, 0, 0, 0, 1)
		annexB = append(annexB, avcc[offset:offset+nalLength]...)
		offset += nalLength
	}
	return annexB, nil
}

func parseOpusPacket(raw []byte) (payload []byte, pts uint64, err error) {
	if len(raw) < audioHeaderSize || len(raw) > audioHeaderSize+maximumOpus ||
		string(raw[:4]) != "IUAC" || raw[4] != 1 || binary.BigEndian.Uint16(raw[6:8]) != audioHeaderSize ||
		raw[5]&^byte(1) != 0 {
		return nil, 0, fmt.Errorf("invalid IUAC packet")
	}
	payloadLength := int(binary.BigEndian.Uint16(raw[22:24]))
	frameCount := binary.BigEndian.Uint16(raw[20:22])
	if payloadLength == 0 || len(raw) != audioHeaderSize+payloadLength || frameCount == 0 || frameCount > 5760 {
		return nil, 0, fmt.Errorf("invalid IUAC payload length")
	}
	return raw[audioHeaderSize:], binary.BigEndian.Uint64(raw[8:16]), nil
}
