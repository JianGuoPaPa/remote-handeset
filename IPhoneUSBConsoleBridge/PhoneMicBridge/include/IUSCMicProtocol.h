#ifndef IUSC_MIC_PROTOCOL_H
#define IUSC_MIC_PROTOCOL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Wire format carried inside a standard RFB ClientCutText (message type 6).
 * All integer fields in the 28-byte control header are big-endian. PCM payload
 * bytes are signed 16-bit little-endian, mono, at a fixed 48 kHz sample rate.
 */
#define IUSC_MIC_MAGIC "IUMC"
#define IUSC_MIC_VERSION 1u
#define IUSC_MIC_HEADER_BYTES 28u
#define IUSC_MIC_SAMPLE_RATE 48000u
#define IUSC_MIC_CHANNELS 1u
#define IUSC_MIC_FORMAT_S16LE 1u
#define IUSC_MIC_MAX_PACKET_SAMPLES 4096u
#define IUSC_MIC_MAX_PACKET_BYTES \
    (IUSC_MIC_HEADER_BYTES + IUSC_MIC_MAX_PACKET_SAMPLES * 2u)

#define IUSC_MIC_FLAG_START 0x01u
#define IUSC_MIC_FLAG_STOP  0x02u
#define IUSC_MIC_FLAG_DATA  0x04u
#define IUSC_MIC_KNOWN_FLAGS \
    (IUSC_MIC_FLAG_START | IUSC_MIC_FLAG_STOP | IUSC_MIC_FLAG_DATA)

#define IUSC_MIC_CONSUMER_PORT 29877u
#define IUSC_MIC_INGRESS_SOCKET \
    "/var/mobile/Library/Caches/local.iphone.usbmic/ingress.sock"
#define IUSC_MIC_DEMAND_SOCKET \
    "/var/mobile/Library/Caches/local.iphone.usbmic/demand.sock"

/*
 * Local consumer-to-daemon demand report. This message never leaves the
 * device. Keeping it fixed-size lets the daemon safely frame reports from
 * multiple injected processes without doing any work on an audio callback.
 */
#define IUSC_MIC_DEMAND_REPORT_MAGIC "IUMQ"
#define IUSC_MIC_DEMAND_REPORT_VERSION 1u
#define IUSC_MIC_DEMAND_REPORT_BYTES 16u

/*
 * RFB capability and notification envelopes. IUMH is sent in ClientCutText;
 * IUMD is returned in a binary ServerCutText only to the authenticated,
 * full-control client that advertised IUMH support.
 */
#define IUSC_MIC_DEMAND_HELLO_MAGIC "IUMH"
#define IUSC_MIC_DEMAND_HELLO_VERSION 1u
#define IUSC_MIC_DEMAND_HELLO_BYTES 16u
#define IUSC_MIC_DEMAND_HELLO_FLAG_AUTO_DEMAND 0x01u

#define IUSC_MIC_DEMAND_NOTIFY_MAGIC "IUMD"
#define IUSC_MIC_DEMAND_NOTIFY_VERSION 1u
#define IUSC_MIC_DEMAND_NOTIFY_BYTES 16u

#define IUSC_MIC_AUTH_CHALLENGE_MAGIC "IUAC"
#define IUSC_MIC_AUTH_RESPONSE_MAGIC  "IUAR"
#define IUSC_MIC_AUTH_RESULT_MAGIC    "IUAO"
#define IUSC_MIC_AUTH_VERSION 2u
#define IUSC_MIC_AUTH_CHALLENGE_BYTES 40u
#define IUSC_MIC_AUTH_RESPONSE_BYTES 40u
#define IUSC_MIC_AUTH_RESULT_BYTES 40u
#define IUSC_MIC_AUTH_PREFIX_BYTES 8u
#define IUSC_MIC_AUTH_NONCE_BYTES 32u
#define IUSC_MIC_AUTH_TAG_BYTES 32u

typedef struct {
    uint8_t flags;
    uint32_t stream_id;
    uint32_t packet_sequence;
    uint64_t capture_timestamp_us;
    uint16_t sample_count;
    uint8_t channels;
    uint8_t format;
    const uint8_t *pcm;
} IUSCMicPacketView;

typedef struct {
    bool active;
    uint32_t generation;
    uint32_t active_count;
} IUSCMicDemandView;

static inline uint16_t IUSCMicReadBE16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | (uint16_t)p[1]);
}

static inline uint32_t IUSCMicReadBE32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static inline uint64_t IUSCMicReadBE64(const uint8_t *p) {
    return ((uint64_t)IUSCMicReadBE32(p) << 32) |
           (uint64_t)IUSCMicReadBE32(p + 4);
}

static inline void IUSCMicWriteBE16(uint8_t *p, uint16_t value) {
    p[0] = (uint8_t)(value >> 8);
    p[1] = (uint8_t)value;
}

static inline void IUSCMicWriteBE32(uint8_t *p, uint32_t value) {
    p[0] = (uint8_t)(value >> 24);
    p[1] = (uint8_t)(value >> 16);
    p[2] = (uint8_t)(value >> 8);
    p[3] = (uint8_t)value;
}

static inline void IUSCMicWriteBE64(uint8_t *p, uint64_t value) {
    IUSCMicWriteBE32(p, (uint32_t)(value >> 32));
    IUSCMicWriteBE32(p + 4, (uint32_t)value);
}

static inline bool IUSCMicHasMagic(const uint8_t *bytes, size_t length) {
    return bytes && length >= 4 && memcmp(bytes, IUSC_MIC_MAGIC, 4) == 0;
}

static inline bool IUSCMicHasDemandHelloMagic(const uint8_t *bytes,
                                               size_t length) {
    return bytes && length >= 4 &&
           memcmp(bytes, IUSC_MIC_DEMAND_HELLO_MAGIC, 4) == 0;
}

static inline bool IUSCMicParseDemandHello(const uint8_t *bytes,
                                            size_t length,
                                            uint32_t *clientNonce) {
    if (!bytes || length != IUSC_MIC_DEMAND_HELLO_BYTES ||
        !IUSCMicHasDemandHelloMagic(bytes, length) ||
        bytes[4] != IUSC_MIC_DEMAND_HELLO_VERSION ||
        bytes[5] != IUSC_MIC_DEMAND_HELLO_FLAG_AUTO_DEMAND ||
        IUSCMicReadBE16(bytes + 6) != IUSC_MIC_DEMAND_HELLO_BYTES ||
        IUSCMicReadBE32(bytes + 8) == 0 ||
        IUSCMicReadBE32(bytes + 12) != 0) {
        return false;
    }
    if (clientNonce) {
        *clientNonce = IUSCMicReadBE32(bytes + 8);
    }
    return true;
}

static inline size_t IUSCMicBuildDemandEnvelope(uint8_t *bytes,
                                                 size_t capacity,
                                                 const char magic[4],
                                                 bool active,
                                                 uint32_t generation,
                                                 uint32_t activeCount) {
    if (!bytes || !magic || capacity < IUSC_MIC_DEMAND_NOTIFY_BYTES ||
        generation == 0 || (active && activeCount == 0) ||
        (!active && activeCount != 0)) {
        return 0;
    }
    memcpy(bytes, magic, 4);
    bytes[4] = IUSC_MIC_DEMAND_NOTIFY_VERSION;
    bytes[5] = active ? 1u : 0u;
    IUSCMicWriteBE16(bytes + 6, IUSC_MIC_DEMAND_NOTIFY_BYTES);
    IUSCMicWriteBE32(bytes + 8, generation);
    IUSCMicWriteBE32(bytes + 12, activeCount);
    return IUSC_MIC_DEMAND_NOTIFY_BYTES;
}

static inline bool IUSCMicParseDemandEnvelope(const uint8_t *bytes,
                                               size_t length,
                                               const char magic[4],
                                               IUSCMicDemandView *out) {
    if (!bytes || !magic || !out || length != IUSC_MIC_DEMAND_NOTIFY_BYTES ||
        memcmp(bytes, magic, 4) != 0 ||
        bytes[4] != IUSC_MIC_DEMAND_NOTIFY_VERSION || bytes[5] > 1u ||
        IUSCMicReadBE16(bytes + 6) != IUSC_MIC_DEMAND_NOTIFY_BYTES) {
        return false;
    }
    const uint32_t generation = IUSCMicReadBE32(bytes + 8);
    const uint32_t activeCount = IUSCMicReadBE32(bytes + 12);
    const bool active = bytes[5] != 0;
    if (generation == 0 || (active && activeCount == 0) ||
        (!active && activeCount != 0)) {
        return false;
    }
    out->active = active;
    out->generation = generation;
    out->active_count = activeCount;
    return true;
}

static inline size_t IUSCMicBuildDemandReport(uint8_t *bytes,
                                               size_t capacity,
                                               uint32_t generation,
                                               uint32_t activeCount) {
    return IUSCMicBuildDemandEnvelope(
        bytes, capacity, IUSC_MIC_DEMAND_REPORT_MAGIC,
        activeCount != 0, generation, activeCount);
}

static inline bool IUSCMicParseDemandReport(const uint8_t *bytes,
                                             size_t length,
                                             IUSCMicDemandView *out) {
    return IUSCMicParseDemandEnvelope(
        bytes, length, IUSC_MIC_DEMAND_REPORT_MAGIC, out);
}

static inline size_t IUSCMicBuildDemandNotification(uint8_t *bytes,
                                                     size_t capacity,
                                                     uint32_t generation,
                                                     uint32_t activeCount) {
    return IUSCMicBuildDemandEnvelope(
        bytes, capacity, IUSC_MIC_DEMAND_NOTIFY_MAGIC,
        activeCount != 0, generation, activeCount);
}

static inline bool IUSCMicParseDemandNotification(const uint8_t *bytes,
                                                   size_t length,
                                                   IUSCMicDemandView *out) {
    return IUSCMicParseDemandEnvelope(
        bytes, length, IUSC_MIC_DEMAND_NOTIFY_MAGIC, out);
}

static inline bool IUSCMicParsePacket(const uint8_t *bytes,
                                      size_t length,
                                      IUSCMicPacketView *out) {
    if (!bytes || !out || length < IUSC_MIC_HEADER_BYTES ||
        !IUSCMicHasMagic(bytes, length) || bytes[4] != IUSC_MIC_VERSION ||
        IUSCMicReadBE16(bytes + 6) != IUSC_MIC_HEADER_BYTES) {
        return false;
    }

    const uint8_t flags = bytes[5];
    if (flags == 0 || (flags & (uint8_t)~IUSC_MIC_KNOWN_FLAGS) != 0) {
        return false;
    }

    const uint16_t samples = IUSCMicReadBE16(bytes + 24);
    const uint8_t channels = bytes[26];
    const uint8_t format = bytes[27];
    if (channels != IUSC_MIC_CHANNELS || format != IUSC_MIC_FORMAT_S16LE ||
        samples > IUSC_MIC_MAX_PACKET_SAMPLES) {
        return false;
    }

    const bool carriesData = (flags & IUSC_MIC_FLAG_DATA) != 0;
    const size_t payloadBytes = (size_t)samples * 2u;
    if ((carriesData && samples == 0) || (!carriesData && samples != 0) ||
        length != IUSC_MIC_HEADER_BYTES + payloadBytes) {
        return false;
    }

    out->flags = flags;
    out->stream_id = IUSCMicReadBE32(bytes + 8);
    out->packet_sequence = IUSCMicReadBE32(bytes + 12);
    out->capture_timestamp_us = IUSCMicReadBE64(bytes + 16);
    out->sample_count = samples;
    out->channels = channels;
    out->format = format;
    out->pcm = bytes + IUSC_MIC_HEADER_BYTES;
    return true;
}

static inline size_t IUSCMicBuildControlPacket(uint8_t *bytes,
                                               size_t capacity,
                                               uint8_t flags,
                                               uint32_t streamID,
                                               uint32_t packetSequence,
                                               uint64_t timestampUS) {
    if (!bytes || capacity < IUSC_MIC_HEADER_BYTES ||
        flags == 0 || (flags & IUSC_MIC_FLAG_DATA) != 0 ||
        (flags & (uint8_t)~IUSC_MIC_KNOWN_FLAGS) != 0) {
        return 0;
    }
    memcpy(bytes, IUSC_MIC_MAGIC, 4);
    bytes[4] = IUSC_MIC_VERSION;
    bytes[5] = flags;
    IUSCMicWriteBE16(bytes + 6, IUSC_MIC_HEADER_BYTES);
    IUSCMicWriteBE32(bytes + 8, streamID);
    IUSCMicWriteBE32(bytes + 12, packetSequence);
    IUSCMicWriteBE64(bytes + 16, timestampUS);
    IUSCMicWriteBE16(bytes + 24, 0);
    bytes[26] = IUSC_MIC_CHANNELS;
    bytes[27] = IUSC_MIC_FORMAT_S16LE;
    return IUSC_MIC_HEADER_BYTES;
}

#ifdef __cplusplus
}
#endif

#endif /* IUSC_MIC_PROTOCOL_H */
