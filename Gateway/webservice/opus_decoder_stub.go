//go:build !darwin || !cgo

package webservice

import "fmt"

func newMicrophoneOpusDecoder(int) (microphoneOpusDecoder, error) {
	return nil, fmt.Errorf("native Opus decoder is unavailable on this platform")
}
