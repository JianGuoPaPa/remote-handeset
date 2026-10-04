#include "MicStream.h"

#include "IUSCMicProtocol.h"

#include <math.h>
#include <stdatomic.h>
#include <stddef.h>
#include <string.h>

#define IUSC_RING_CAPACITY 131072u
#define IUSC_RING_MASK (IUSC_RING_CAPACITY - 1u)
/* Retain 120 ms after satisfying the complete current capture callback. */
#define IUSC_HEADROOM_SAMPLES 5760u
/* Allow a 1 second producer burst above the callback-dependent target. */
#define IUSC_HARD_RESYNC_EXTRA_SAMPLES 48000u

static _Atomic(int16_t) gSamples[IUSC_RING_CAPACITY];
static _Atomic(uint64_t) gWriteIndex;
static _Atomic(uint32_t) gGeneration;
static _Atomic(uint32_t) gStreamID;
static _Atomic(bool) gActive;
/* High 32 bits: nonzero demand generation; low 32 bits: active source count. */
static _Atomic(uint64_t) gDemandState;

static uint32_t nextNonzeroGeneration(uint32_t generation) {
    generation += 1u;
    return generation == 0 ? 1u : generation;
}

void IUSCMicStreamInitialize(void) {
    atomic_store_explicit(&gWriteIndex, 0, memory_order_relaxed);
    atomic_store_explicit(&gGeneration, 1, memory_order_relaxed);
    atomic_store_explicit(&gStreamID, 0, memory_order_relaxed);
    atomic_store_explicit(&gActive, false, memory_order_release);
    atomic_store_explicit(&gDemandState, (uint64_t)1u << 32,
                          memory_order_release);
}

void IUSCMicStreamStart(uint32_t streamID) {
    atomic_store_explicit(&gActive, false, memory_order_release);
    atomic_store_explicit(&gWriteIndex, 0, memory_order_relaxed);
    atomic_store_explicit(&gStreamID, streamID, memory_order_relaxed);
    (void)atomic_fetch_add_explicit(&gGeneration, 1, memory_order_acq_rel);
    atomic_store_explicit(&gActive, true, memory_order_release);
}

void IUSCMicStreamStop(uint32_t streamID) {
    const uint32_t current = atomic_load_explicit(&gStreamID, memory_order_acquire);
    if (streamID != 0 && current != streamID) {
        return;
    }
    atomic_store_explicit(&gActive, false, memory_order_release);
    atomic_store_explicit(&gStreamID, 0, memory_order_relaxed);
    atomic_store_explicit(&gWriteIndex, 0, memory_order_relaxed);
    (void)atomic_fetch_add_explicit(&gGeneration, 1, memory_order_acq_rel);
}

void IUSCMicStreamTransportDisconnected(void) {
    IUSCMicStreamStop(0);
}

void IUSCMicStreamPushPCM(uint32_t streamID,
                          const uint8_t *littleEndianPCM,
                          uint16_t sampleCount) {
    if (!littleEndianPCM || sampleCount == 0 ||
        !atomic_load_explicit(&gActive, memory_order_acquire) ||
        atomic_load_explicit(&gStreamID, memory_order_relaxed) != streamID) {
        return;
    }

    uint64_t write = atomic_load_explicit(&gWriteIndex, memory_order_relaxed);
    for (uint16_t i = 0; i < sampleCount; ++i) {
        const uint16_t raw = (uint16_t)littleEndianPCM[(size_t)i * 2u] |
                             ((uint16_t)littleEndianPCM[(size_t)i * 2u + 1u] << 8);
        atomic_store_explicit(&gSamples[(write + i) & IUSC_RING_MASK],
                              (int16_t)raw, memory_order_relaxed);
    }
    atomic_store_explicit(&gWriteIndex, write + sampleCount, memory_order_release);
}

bool IUSCMicStreamIsActive(void) {
    return atomic_load_explicit(&gActive, memory_order_acquire);
}

uint32_t IUSCMicStreamID(void) {
    return atomic_load_explicit(&gStreamID, memory_order_acquire);
}

void IUSCMicDemandAcquire(void) {
    uint64_t current = atomic_load_explicit(&gDemandState,
                                            memory_order_acquire);
    for (;;) {
        const uint32_t generation = (uint32_t)(current >> 32);
        const uint32_t count = (uint32_t)current;
        const uint32_t nextCount = count == UINT32_MAX ? UINT32_MAX
                                                       : count + 1u;
        if (nextCount == count) {
            return;
        }
        const uint64_t desired =
            ((uint64_t)nextNonzeroGeneration(generation) << 32) | nextCount;
        if (atomic_compare_exchange_weak_explicit(
                &gDemandState, &current, desired,
                memory_order_acq_rel, memory_order_acquire)) {
            return;
        }
    }
}

void IUSCMicDemandRelease(void) {
    uint64_t current = atomic_load_explicit(&gDemandState,
                                            memory_order_acquire);
    for (;;) {
        const uint32_t generation = (uint32_t)(current >> 32);
        const uint32_t count = (uint32_t)current;
        if (count == 0) {
            return;
        }
        const uint64_t desired =
            ((uint64_t)nextNonzeroGeneration(generation) << 32) |
            (uint64_t)(count - 1u);
        if (atomic_compare_exchange_weak_explicit(
                &gDemandState, &current, desired,
                memory_order_acq_rel, memory_order_acquire)) {
            return;
        }
    }
}

bool IUSCMicDemandIsActive(void) {
    return (uint32_t)atomic_load_explicit(&gDemandState,
                                          memory_order_acquire) != 0;
}

void IUSCMicDemandSnapshot(uint32_t *activeCount, uint32_t *generation) {
    const uint64_t snapshot = atomic_load_explicit(&gDemandState,
                                                   memory_order_acquire);
    if (activeCount) {
        *activeCount = (uint32_t)snapshot;
    }
    if (generation) {
        *generation = (uint32_t)(snapshot >> 32);
    }
}

void IUSCMicCursorReset(IUSCMicReadCursor *cursor) {
    if (!cursor) return;
    cursor->generation = 0;
    cursor->source_position = 0;
    cursor->primed = false;
    cursor->has_position = false;
}

static void writeIntegerSample(uint8_t *destination,
                               UInt32 bits,
                               float sample) {
    if (sample > 1.0f) sample = 1.0f;
    if (sample < -1.0f) sample = -1.0f;
    if (bits == 8) {
        const int8_t value = (int8_t)lrintf(sample * 127.0f);
        memcpy(destination, &value, sizeof(value));
    } else if (bits == 16) {
        const int16_t value = (int16_t)lrintf(sample * 32767.0f);
        memcpy(destination, &value, sizeof(value));
    } else if (bits == 24) {
        const int32_t value = (int32_t)lrintf(sample * 8388607.0f);
        destination[0] = (uint8_t)value;
        destination[1] = (uint8_t)(value >> 8);
        destination[2] = (uint8_t)(value >> 16);
    } else if (bits == 32) {
        const int32_t value = (int32_t)llrint((double)sample * 2147483647.0);
        memcpy(destination, &value, sizeof(value));
    }
}

static void storeSampleInBuffer(AudioBuffer *buffer,
                                UInt32 frame,
                                UInt32 channelsInBuffer,
                                UInt32 bytesPerSample,
                                UInt32 frameStride,
                                UInt32 bits,
                                bool isFloat,
                                float sample) {
    if (!buffer || !buffer->mData || channelsInBuffer == 0 ||
        bytesPerSample == 0 || frameStride == 0) {
        return;
    }
    const uint64_t frameOffset = (uint64_t)frame * frameStride;
    const uint64_t required = frameOffset +
        (uint64_t)channelsInBuffer * bytesPerSample;
    if (required > buffer->mDataByteSize) {
        return;
    }
    uint8_t *frameBytes = (uint8_t *)buffer->mData + frameOffset;
    for (UInt32 channel = 0; channel < channelsInBuffer; ++channel) {
        uint8_t *destination = frameBytes + (size_t)channel * bytesPerSample;
        if (isFloat && bits == 32) {
            memcpy(destination, &sample, sizeof(float));
        } else if (isFloat && bits == 64) {
            const double value = sample;
            memcpy(destination, &value, sizeof(double));
        } else {
            writeIntegerSample(destination, bits, sample);
        }
    }
}

static void zeroBuffers(AudioBufferList *buffers) {
    if (!buffers) return;
    for (UInt32 i = 0; i < buffers->mNumberBuffers; ++i) {
        AudioBuffer *buffer = &buffers->mBuffers[i];
        if (buffer->mData && buffer->mDataByteSize > 0) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
}

bool IUSCMicFillAudioBufferList(AudioBufferList *buffers,
                                UInt32 frameCount,
                                const AudioStreamBasicDescription *format,
                                IUSCMicReadCursor *cursor) {
    if (!IUSCMicDemandIsActive()) {
        return false;
    }
    /*
     * Fail closed for the complete callback before interpreting its layout.
     * A short buffer, an unusual ASBD, or an underflow must never leave any
     * bytes from the physical microphone behind.
     */
    zeroBuffers(buffers);
    if (!IUSCMicStreamIsActive()) {
        return true;
    }
    if (!buffers || !format || !cursor || frameCount == 0) {
        return true;
    }

    const double targetRate = format->mSampleRate > 0
        ? format->mSampleRate : (double)IUSC_MIC_SAMPLE_RATE;
    const UInt32 bits = format->mBitsPerChannel;
    const bool isFloat = (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    const bool isSignedInteger =
        (format->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    const bool nonInterleaved =
        (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const bool bigEndian =
        (format->mFormatFlags & kAudioFormatFlagIsBigEndian) != 0;
    const bool alignedHigh =
        (format->mFormatFlags & kAudioFormatFlagIsAlignedHigh) != 0;
    const UInt32 bytesPerSample = (bits + 7u) / 8u;
    if (format->mFormatID != kAudioFormatLinearPCM ||
        format->mChannelsPerFrame == 0 || format->mChannelsPerFrame > 32 ||
        bigEndian || alignedHigh ||
        targetRate < 8000.0 || targetRate > 192000.0 ||
        ((!isFloat && !isSignedInteger) ||
         (isFloat && bits != 32 && bits != 64) ||
         (!isFloat && bits != 8 && bits != 16 && bits != 24 && bits != 32))) {
        return true;
    }

    const double sourceStep = (double)IUSC_MIC_SAMPLE_RATE / targetRate;
    const double requiredDouble =
        ceil((double)frameCount * sourceStep) + 2.0;
    if (!isfinite(sourceStep) || sourceStep <= 0.0 ||
        !isfinite(requiredDouble) || requiredDouble <= 0.0 ||
        requiredDouble >= (double)(IUSC_RING_CAPACITY - 2u)) {
        cursor->primed = false;
        return true;
    }
    const uint64_t requiredSamples = (uint64_t)requiredDouble;
    if (requiredSamples >
        (uint64_t)(IUSC_RING_CAPACITY - 2u) - IUSC_HEADROOM_SAMPLES) {
        cursor->primed = false;
        return true;
    }
    const uint64_t targetBufferedSamples =
        requiredSamples + IUSC_HEADROOM_SAMPLES;

    const uint32_t generation =
        atomic_load_explicit(&gGeneration, memory_order_acquire);
    const uint64_t write =
        atomic_load_explicit(&gWriteIndex, memory_order_acquire);
    if (cursor->generation != generation) {
        cursor->generation = generation;
        cursor->source_position = 0;
        cursor->primed = false;
        cursor->has_position = false;
    }

    if (!cursor->primed) {
        if (cursor->has_position) {
            if (!isfinite(cursor->source_position) ||
                cursor->source_position < 0.0) {
                cursor->has_position = false;
            } else {
                const uint64_t resumeFloor =
                    (uint64_t)cursor->source_position;
                if (resumeFloor <= write &&
                    write - resumeFloor >= targetBufferedSamples) {
                    /*
                     * Resume at the bounded live position. This only moves
                     * forward, so stale audio accumulated during a dropout is
                     * discarded instead of being played late in a call.
                     */
                    const double livePosition =
                        (double)(write - targetBufferedSamples);
                    if (livePosition > cursor->source_position) {
                        cursor->source_position = livePosition;
                    }
                    cursor->primed = true;
                } else {
                    return true;
                }
            }
        }
        if (!cursor->has_position) {
            if (write < targetBufferedSamples) {
                return true;
            }
            cursor->source_position =
                (double)(write - targetBufferedSamples);
            cursor->primed = true;
            cursor->has_position = true;
        }
    }

    const uint64_t oldest = write > IUSC_RING_CAPACITY
        ? write - IUSC_RING_CAPACITY : 0;
    if (!isfinite(cursor->source_position) ||
        cursor->source_position < 0.0) {
        cursor->primed = false;
        cursor->has_position = false;
        return true;
    }
    uint64_t cursorFloor = (uint64_t)cursor->source_position;
    const uint64_t maximumLag = targetBufferedSamples >
            (uint64_t)(IUSC_RING_CAPACITY - 2u) -
                IUSC_HARD_RESYNC_EXTRA_SAMPLES
        ? (uint64_t)(IUSC_RING_CAPACITY - 2u)
        : targetBufferedSamples + IUSC_HARD_RESYNC_EXTRA_SAMPLES;
    if (cursorFloor < oldest || cursorFloor > write ||
        write - cursorFloor > maximumLag) {
        if (write < targetBufferedSamples) {
            cursor->primed = false;
            cursor->has_position = false;
            return true;
        }
        cursor->source_position =
            (double)(write - targetBufferedSamples);
        cursorFloor = (uint64_t)cursor->source_position;
    }

    const uint64_t availableSamples = write - cursorFloor;
    const double finalSourcePosition = cursor->source_position +
        (double)(frameCount - 1u) * sourceStep;
    if (availableSamples < requiredSamples ||
        !isfinite(finalSourcePosition) || finalSourcePosition < 0.0 ||
        finalSourcePosition >= (double)(UINT64_MAX - 1u) ||
        (uint64_t)finalSourcePosition + 1u >= write) {
        /*
         * Never mix valid audio and a zero-filled tail in one capture buffer.
         * Preserve the read position only as the rebuffer watermark. Once a
         * complete callback plus headroom exists, resume at a bounded live
         * position so stale audio is neither replayed nor delivered late.
         */
        cursor->primed = false;
        return true;
    }

    for (UInt32 frame = 0; frame < frameCount; ++frame) {
        const uint64_t lower = (uint64_t)cursor->source_position;
        const double fraction = cursor->source_position - (double)lower;
        const int16_t first = atomic_load_explicit(
            &gSamples[lower & IUSC_RING_MASK], memory_order_relaxed);
        const int16_t second = atomic_load_explicit(
            &gSamples[(lower + 1u) & IUSC_RING_MASK], memory_order_relaxed);
        const double interpolated = (double)first +
            ((double)second - (double)first) * fraction;
        const float sample =
            (float)(interpolated * (1.0 / 32768.0));

        for (UInt32 index = 0; index < buffers->mNumberBuffers; ++index) {
            AudioBuffer *buffer = &buffers->mBuffers[index];
            const UInt32 channelsInBuffer = buffer->mNumberChannels > 0
                ? buffer->mNumberChannels
                : (nonInterleaved ? 1u : format->mChannelsPerFrame);
            const UInt32 minimumStride = channelsInBuffer * bytesPerSample;
            const UInt32 frameStride = nonInterleaved
                ? (format->mBytesPerFrame > 0
                    ? format->mBytesPerFrame : minimumStride)
                : (format->mBytesPerFrame > 0
                    ? format->mBytesPerFrame : minimumStride);
            storeSampleInBuffer(buffer, frame, channelsInBuffer,
                                bytesPerSample, frameStride, bits,
                                isFloat, sample);
        }
        cursor->source_position += sourceStep;
    }

    /*
     * START/STOP is driven by the relay thread. If the stream generation
     * changed while this real-time callback was copying atomically stored
     * samples, discard the entire callback instead of exposing a boundary
     * buffer containing audio from two different streams.
     */
    if (!atomic_load_explicit(&gActive, memory_order_acquire) ||
        atomic_load_explicit(&gGeneration, memory_order_acquire) != generation) {
        zeroBuffers(buffers);
        IUSCMicCursorReset(cursor);
    }
    return true;
}
