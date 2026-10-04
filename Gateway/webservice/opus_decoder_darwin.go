//go:build darwin && cgo

package webservice

/*
#cgo LDFLAGS: -framework AudioToolbox -framework CoreAudio
#include <AudioToolbox/AudioToolbox.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
	const uint8_t *data;
	UInt32 size;
	UInt32 channels;
	Boolean supplied;
	AudioStreamPacketDescription description;
} IUMOpusInput;

static OSStatus IUMOpusInputProc(
	AudioConverterRef converter,
	UInt32 *ioNumberDataPackets,
	AudioBufferList *ioData,
	AudioStreamPacketDescription **outDataPacketDescription,
	void *userData
) {
	(void)converter;
	IUMOpusInput *input = (IUMOpusInput *)userData;
	if (input->supplied) {
		*ioNumberDataPackets = 0;
		return noErr;
	}
	input->supplied = true;
	*ioNumberDataPackets = 1;
	ioData->mNumberBuffers = 1;
	ioData->mBuffers[0].mNumberChannels = input->channels;
	ioData->mBuffers[0].mDataByteSize = input->size;
	ioData->mBuffers[0].mData = (void *)input->data;
	input->description.mStartOffset = 0;
	input->description.mVariableFramesInPacket = 0;
	input->description.mDataByteSize = input->size;
	if (outDataPacketDescription != NULL) {
		*outDataPacketDescription = &input->description;
	}
	return noErr;
}

static OSStatus IUMCreateOpusDecoder(UInt32 channels, AudioConverterRef *outConverter) {
	AudioStreamBasicDescription source;
	memset(&source, 0, sizeof(source));
	source.mSampleRate = 48000.0;
	source.mFormatID = kAudioFormatOpus;
	source.mChannelsPerFrame = channels;
	UInt32 sourceSize = sizeof(source);
	OSStatus status = AudioFormatGetProperty(
		kAudioFormatProperty_FormatInfo,
		0,
		NULL,
		&sourceSize,
		&source
	);
	if (status != noErr) {
		return status;
	}

	AudioStreamBasicDescription destination;
	memset(&destination, 0, sizeof(destination));
	destination.mSampleRate = 48000.0;
	destination.mFormatID = kAudioFormatLinearPCM;
	destination.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
	destination.mBytesPerPacket = 2;
	destination.mFramesPerPacket = 1;
	destination.mBytesPerFrame = 2;
	destination.mChannelsPerFrame = 1;
	destination.mBitsPerChannel = 16;

	status = AudioConverterNew(&source, &destination, outConverter);
	if (status != noErr) {
		return status;
	}
	UInt32 primeMethod = kConverterPrimeMethod_None;
	status = AudioConverterSetProperty(
		*outConverter,
		kAudioConverterPrimeMethod,
		sizeof(primeMethod),
		&primeMethod
	);
	if (status != noErr) {
		AudioConverterDispose(*outConverter);
		*outConverter = NULL;
		return status;
	}
	return noErr;
}

static OSStatus IUMDecodeOpus(
	AudioConverterRef converter,
	UInt32 channels,
	const uint8_t *inputBytes,
	UInt32 inputSize,
	uint8_t *outputBytes,
	UInt32 outputCapacity,
	UInt32 *outputSize
) {
	IUMOpusInput input;
	memset(&input, 0, sizeof(input));
	input.data = inputBytes;
	input.size = inputSize;
	input.channels = channels;

	AudioBufferList output;
	memset(&output, 0, sizeof(output));
	output.mNumberBuffers = 1;
	output.mBuffers[0].mNumberChannels = 1;
	output.mBuffers[0].mDataByteSize = outputCapacity;
	output.mBuffers[0].mData = outputBytes;
	UInt32 outputPackets = outputCapacity / 2;
	OSStatus status = AudioConverterFillComplexBuffer(
		converter,
		IUMOpusInputProc,
		&input,
		&outputPackets,
		&output,
		NULL
	);
	*outputSize = output.mBuffers[0].mDataByteSize;
	return status;
}
*/
import "C"

import (
	"fmt"
	"sync"
	"unsafe"
)

const maximumOpusDecodedSamples = 5760

type audioToolboxOpusDecoder struct {
	mu        sync.Mutex
	converter C.AudioConverterRef
	channels  C.UInt32
	closed    bool
}

func newMicrophoneOpusDecoder(channels int) (microphoneOpusDecoder, error) {
	if channels != 1 && channels != 2 {
		return nil, fmt.Errorf("unsupported Opus channel count")
	}
	decoder := &audioToolboxOpusDecoder{channels: C.UInt32(channels)}
	status := C.IUMCreateOpusDecoder(decoder.channels, &decoder.converter)
	if status != C.noErr || decoder.converter == nil {
		return nil, fmt.Errorf("AudioConverterNew Opus failed with OSStatus %d", int32(status))
	}
	return decoder, nil
}

func (decoder *audioToolboxOpusDecoder) Decode(packet []byte) ([]byte, error) {
	if len(packet) == 0 {
		return nil, fmt.Errorf("empty Opus packet")
	}
	decoder.mu.Lock()
	defer decoder.mu.Unlock()
	if decoder.closed || decoder.converter == nil {
		return nil, fmt.Errorf("Opus decoder is closed")
	}
	output := make([]byte, maximumOpusDecodedSamples*2)
	var outputSize C.UInt32
	status := C.IUMDecodeOpus(
		decoder.converter,
		decoder.channels,
		(*C.uint8_t)(unsafe.Pointer(&packet[0])),
		C.UInt32(len(packet)),
		(*C.uint8_t)(unsafe.Pointer(&output[0])),
		C.UInt32(len(output)),
		&outputSize,
	)
	if status != C.noErr {
		return nil, fmt.Errorf("AudioConverter Opus decode failed with OSStatus %d", int32(status))
	}
	if outputSize > C.UInt32(len(output)) || outputSize%2 != 0 {
		return nil, fmt.Errorf("AudioConverter returned invalid PCM size")
	}
	if outputSize == 0 {
		return nil, nil
	}
	return output[:int(outputSize)], nil
}

func (decoder *audioToolboxOpusDecoder) Close() {
	decoder.mu.Lock()
	defer decoder.mu.Unlock()
	if decoder.closed {
		return
	}
	decoder.closed = true
	if decoder.converter != nil {
		C.AudioConverterDispose(decoder.converter)
		decoder.converter = nil
	}
}
