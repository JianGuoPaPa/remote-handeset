#ifndef IUSC_MIC_STREAM_H
#define IUSC_MIC_STREAM_H

#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t generation;
    double source_position;
    bool primed;
    bool has_position;
} IUSCMicReadCursor;

void IUSCMicStreamInitialize(void);
void IUSCMicStreamStart(uint32_t streamID);
void IUSCMicStreamStop(uint32_t streamID);
void IUSCMicStreamTransportDisconnected(void);
void IUSCMicStreamPushPCM(uint32_t streamID,
                          const uint8_t *littleEndianPCM,
                          uint16_t sampleCount);
bool IUSCMicStreamIsActive(void);
uint32_t IUSCMicStreamID(void);

/*
 * Capture-source lifecycle. The count and generation are stored in one atomic
 * snapshot so the reporter thread cannot observe a mismatched edge. These
 * functions perform no allocation, locking, dispatch, or socket I/O.
 */
void IUSCMicDemandAcquire(void);
void IUSCMicDemandRelease(void);
bool IUSCMicDemandIsActive(void);
void IUSCMicDemandSnapshot(uint32_t *activeCount, uint32_t *generation);

void IUSCMicCursorReset(IUSCMicReadCursor *cursor);

/*
 * Returns false only while no local capture source needs microphone input.
 * From the first local demand edge until the last source goes idle, it always
 * replaces the physical microphone: buffered remote PCM when present,
 * otherwise silence. No allocation, locks, ObjC dispatch, or socket I/O occurs.
 */
bool IUSCMicFillAudioBufferList(AudioBufferList *buffers,
                                UInt32 frameCount,
                                const AudioStreamBasicDescription *format,
                                IUSCMicReadCursor *cursor);

#ifdef __cplusplus
}
#endif

#endif /* IUSC_MIC_STREAM_H */
