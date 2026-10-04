package webservice

import (
	"github.com/pion/interceptor"
	"github.com/pion/rtp"
)

const (
	playoutDelayExtensionURI = "http://www.webrtc.org/experiments/rtp-hdrext/playout-delay"
	// Values are expressed in 10 ms units. A 0–100 ms window keeps the
	// receiver on WebRTC's real-time path while leaving room for WAN jitter.
	playoutDelayMinimum = 0
	playoutDelayMaximum = 50
)

type playoutDelayInterceptorFactory struct{}

func (playoutDelayInterceptorFactory) NewInterceptor(
	_ string,
) (interceptor.Interceptor, error) {
	return &playoutDelayInterceptor{}, nil
}

type playoutDelayInterceptor struct {
	interceptor.NoOp
}

func (*playoutDelayInterceptor) BindLocalStream(
	info *interceptor.StreamInfo,
	writer interceptor.RTPWriter,
) interceptor.RTPWriter {
	var extensionID uint8
	for _, extension := range info.RTPHeaderExtensions {
		if extension.URI == playoutDelayExtensionURI &&
			extension.ID > 0 &&
			extension.ID <= 255 {
			extensionID = uint8(extension.ID)
			break
		}
	}
	if extensionID == 0 {
		return writer
	}

	payload, err := (rtp.PlayoutDelayExtension{
		MinDelay: playoutDelayMinimum,
		MaxDelay: playoutDelayMaximum,
	}).Marshal()
	if err != nil {
		return writer
	}

	return interceptor.RTPWriterFunc(
		func(
			header *rtp.Header,
			packetPayload []byte,
			attributes interceptor.Attributes,
		) (int, error) {
			clonedHeader := header.Clone()
			if err := setPlayoutDelayExtension(
				&clonedHeader,
				extensionID,
				payload,
			); err != nil {
				fallbackHeader := header.Clone()
				return writer.Write(&fallbackHeader, packetPayload, attributes)
			}
			return writer.Write(&clonedHeader, packetPayload, attributes)
		},
	)
}

func setPlayoutDelayExtension(
	header *rtp.Header,
	extensionID uint8,
	payload []byte,
) error {
	if extensionID > 14 {
		if !header.Extension {
			header.Extension = true
			header.ExtensionProfile = rtp.ExtensionProfileTwoByte
		} else if header.ExtensionProfile == rtp.ExtensionProfileOneByte {
			return header.SetExtensionWithProfile(
				extensionID,
				payload,
				rtp.ExtensionProfileTwoByte,
			)
		}
	}
	return header.SetExtension(extensionID, payload)
}
