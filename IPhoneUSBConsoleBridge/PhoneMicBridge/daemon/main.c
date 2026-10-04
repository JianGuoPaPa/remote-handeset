#include "IUSCMicProtocol.h"
#include "IUSCMicSecret.h"

#include <CommonCrypto/CommonHMAC.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define IUSC_MAX_CONSUMERS 32
#define IUSC_MAX_DEMAND_SUBSCRIBERS 1
#define IUSC_OUTPUT_CAPACITY 65536u
#define IUSC_INGRESS_RECEIVE_BUFFER_BYTES 65536
#define IUSC_AUTH_TIMEOUT_MS 300
#define IUSC_MAX_INGRESS_BATCH 128u
#define IUSC_MAX_CONSUMER_REPORT_READS_PER_PASS 8u
#define IUSC_MAX_CONSUMER_FLUSH_WRITES_PER_PASS 16u
#define IUSC_PCM_IDLE_WATCHDOG_NS 1500000000ull

extern int proc_name(int pid, void *buffer, uint32_t buffersize);

typedef enum {
    IUSC_CONSUMER_AUTH_WRITE_CHALLENGE = 0,
    IUSC_CONSUMER_AUTH_READ_RESPONSE = 1,
    IUSC_CONSUMER_AUTH_WRITE_RESULT = 2,
    IUSC_CONSUMER_AUTHENTICATED = 3,
} ConsumerAuthPhase;

typedef struct {
    int fd;
    ConsumerAuthPhase auth_phase;
    bool auth_allowed;
    uint64_t auth_deadline_ns;
    uint8_t auth_challenge[IUSC_MIC_AUTH_CHALLENGE_BYTES];
    uint8_t auth_response[IUSC_MIC_AUTH_RESPONSE_BYTES];
    uint8_t auth_result[IUSC_MIC_AUTH_RESULT_BYTES];
    size_t auth_offset;
    uint8_t output[IUSC_OUTPUT_CAPACITY];
    size_t head;
    size_t count;
    uint8_t input[IUSC_MIC_DEMAND_REPORT_BYTES];
    size_t input_count;
    uint32_t demand_generation;
    uint32_t demand_count;
} Consumer;

typedef struct {
    int fd;
    bool has_pending;
    uint8_t pending[IUSC_MIC_DEMAND_NOTIFY_BYTES];
} DemandSubscriber;

static volatile sig_atomic_t gShouldExit = 0;
static Consumer gConsumers[IUSC_MAX_CONSUMERS];
static DemandSubscriber gDemandSubscribers[IUSC_MAX_DEMAND_SUBSCRIBERS];
static uint32_t gAggregateDemandCount = 0;
static uint32_t gAggregateDemandGeneration = 1;
static bool gStreamActive = false;
static bool gHasSequence = false;
static uint32_t gStreamID = 0;
static uint32_t gLastSequence = 0;
static uint64_t gLastTimestampUS = 0;
static uint64_t gStreamStartMonotonicNS = 0;
static uint64_t gLastPCMMonotonicNS = 0;

static void publishAggregateDemandIfChanged(void);
static bool enqueueBytes(Consumer *consumer,
                         const uint8_t *bytes,
                         size_t length);
static bool queueCurrentStreamStart(Consumer *consumer);
static void expireIdleStreamIfNeeded(void);

static void signalHandler(int signalNumber) {
    (void)signalNumber;
    gShouldExit = 1;
}

static bool configureNonblockingSocket(int fd) {
    if (fd < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) != 0) return false;
    const int flags = fcntl(fd, F_GETFL, 0);
    return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

static void closeConsumer(Consumer *consumer) {
    if (!consumer || consumer->fd < 0) {
        return;
    }
    const bool hadDemand = consumer->demand_count != 0;
    close(consumer->fd);
    consumer->fd = -1;
    consumer->auth_phase = IUSC_CONSUMER_AUTH_WRITE_CHALLENGE;
    consumer->auth_allowed = false;
    consumer->auth_deadline_ns = 0;
    consumer->auth_offset = 0;
    memset(consumer->auth_challenge, 0, sizeof(consumer->auth_challenge));
    memset(consumer->auth_response, 0, sizeof(consumer->auth_response));
    memset(consumer->auth_result, 0, sizeof(consumer->auth_result));
    consumer->head = 0;
    consumer->count = 0;
    consumer->input_count = 0;
    consumer->demand_generation = 0;
    consumer->demand_count = 0;
    if (hadDemand) {
        publishAggregateDemandIfChanged();
    }
}

static void closeDemandSubscriber(DemandSubscriber *subscriber) {
    if (!subscriber || subscriber->fd < 0) {
        return;
    }
    close(subscriber->fd);
    subscriber->fd = -1;
    subscriber->has_pending = false;
    memset(subscriber->pending, 0, sizeof(subscriber->pending));
}

static uint32_t nextNonzeroGeneration(uint32_t generation) {
    generation += 1u;
    return generation == 0 ? 1u : generation;
}

static void queueDemandSnapshot(DemandSubscriber *subscriber) {
    if (!subscriber || subscriber->fd < 0) return;
    const size_t length = IUSCMicBuildDemandNotification(
        subscriber->pending, sizeof(subscriber->pending),
        gAggregateDemandGeneration, gAggregateDemandCount);
    subscriber->has_pending = length == sizeof(subscriber->pending);
}

static void publishAggregateDemandIfChanged(void) {
    uint64_t aggregate = 0;
    for (size_t i = 0; i < IUSC_MAX_CONSUMERS; ++i) {
        if (gConsumers[i].fd < 0 ||
            gConsumers[i].auth_phase != IUSC_CONSUMER_AUTHENTICATED) continue;
        aggregate += gConsumers[i].demand_count;
        if (aggregate >= UINT32_MAX) {
            aggregate = UINT32_MAX;
            break;
        }
    }
    const uint32_t nextCount = (uint32_t)aggregate;
    if (nextCount == gAggregateDemandCount) {
        return;
    }
    const bool wasActive = gAggregateDemandCount != 0;
    const bool isActive = nextCount != 0;
    gAggregateDemandCount = nextCount;
    /*
     * Generation identifies the aggregate active/idle epoch. Count changes
     * inside one active epoch are published with the same generation so the
     * remote controller never interprets another local capture source as a
     * new microphone session.
     */
    if (wasActive != isActive) {
        gAggregateDemandGeneration =
            nextNonzeroGeneration(gAggregateDemandGeneration);
    }
    for (size_t i = 0; i < IUSC_MAX_DEMAND_SUBSCRIBERS; ++i) {
        queueDemandSnapshot(&gDemandSubscribers[i]);
    }
}

static bool flushDemandSubscriber(DemandSubscriber *subscriber) {
    if (!subscriber || subscriber->fd < 0 || !subscriber->has_pending) {
        return true;
    }
    const ssize_t written = send(
        subscriber->fd, subscriber->pending, sizeof(subscriber->pending), 0);
    if (written == (ssize_t)sizeof(subscriber->pending)) {
        subscriber->has_pending = false;
        return true;
    }
    if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK ||
                        errno == EINTR)) {
        return true;
    }
    return false;
}

static uint64_t monotonicNowNS(void) {
    struct timespec time = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &time) != 0 || time.tv_sec < 0) {
        return 0;
    }
    return (uint64_t)time.tv_sec * 1000000000ull + (uint64_t)time.tv_nsec;
}

static bool constantTimeEqual(const uint8_t *left,
                              const uint8_t *right,
                              size_t length) {
    uint8_t difference = 0;
    for (size_t i = 0; i < length; ++i) {
        difference |= (uint8_t)(left[i] ^ right[i]);
    }
    return difference == 0;
}

static bool beginConsumerAuthentication(Consumer *consumer, int fd) {
    if (!consumer || fd < 0) return false;
    consumer->fd = fd;
    const uint64_t nowNS = monotonicNowNS();
    if (nowNS == 0 ||
        UINT64_MAX - nowNS <
            (uint64_t)IUSC_AUTH_TIMEOUT_MS * 1000000ull) return false;
    consumer->auth_phase = IUSC_CONSUMER_AUTH_WRITE_CHALLENGE;
    consumer->auth_allowed = false;
    consumer->auth_deadline_ns =
        nowNS + (uint64_t)IUSC_AUTH_TIMEOUT_MS * 1000000ull;
    consumer->auth_offset = 0;
    memset(consumer->auth_challenge, 0, sizeof(consumer->auth_challenge));
    memset(consumer->auth_response, 0, sizeof(consumer->auth_response));
    memset(consumer->auth_result, 0, sizeof(consumer->auth_result));
    memcpy(consumer->auth_challenge, IUSC_MIC_AUTH_CHALLENGE_MAGIC, 4);
    consumer->auth_challenge[4] = IUSC_MIC_AUTH_VERSION;
    IUSCMicWriteBE16(consumer->auth_challenge + 6,
                     IUSC_MIC_AUTH_CHALLENGE_BYTES);
    arc4random_buf(consumer->auth_challenge + IUSC_MIC_AUTH_PREFIX_BYTES,
                   IUSC_MIC_AUTH_NONCE_BYTES);
    return true;
}

static bool validateConsumerResponse(const Consumer *consumer) {
    if (!consumer ||
        memcmp(consumer->auth_response,
               IUSC_MIC_AUTH_RESPONSE_MAGIC, 4) != 0 ||
        consumer->auth_response[4] != IUSC_MIC_AUTH_VERSION ||
        consumer->auth_response[5] != 0 ||
        IUSCMicReadBE16(consumer->auth_response + 6) !=
            IUSC_MIC_AUTH_RESPONSE_BYTES) {
        return false;
    }

    uint8_t expected[IUSC_MIC_AUTH_TAG_BYTES] = {0};
    CCHmac(kCCHmacAlgSHA256,
           kIUSCMicConsumerSecret, sizeof(kIUSCMicConsumerSecret),
           consumer->auth_challenge, sizeof(consumer->auth_challenge), expected);
    return constantTimeEqual(
        expected,
        consumer->auth_response + IUSC_MIC_AUTH_PREFIX_BYTES,
        IUSC_MIC_AUTH_TAG_BYTES);
}

static void buildConsumerAuthenticationResult(Consumer *consumer,
                                              bool allowed) {
    memset(consumer->auth_result, 0, sizeof(consumer->auth_result));
    memcpy(consumer->auth_result, IUSC_MIC_AUTH_RESULT_MAGIC, 4);
    consumer->auth_result[4] = IUSC_MIC_AUTH_VERSION;
    consumer->auth_result[5] = allowed ? 0u : 1u;
    IUSCMicWriteBE16(consumer->auth_result + 6,
                     IUSC_MIC_AUTH_RESULT_BYTES);
    uint8_t material[
        IUSC_MIC_AUTH_CHALLENGE_BYTES + IUSC_MIC_AUTH_PREFIX_BYTES] = {0};
    memcpy(material, consumer->auth_challenge,
           sizeof(consumer->auth_challenge));
    memcpy(material + sizeof(consumer->auth_challenge),
           consumer->auth_result, IUSC_MIC_AUTH_PREFIX_BYTES);
    CCHmac(kCCHmacAlgSHA256,
           kIUSCMicConsumerSecret, sizeof(kIUSCMicConsumerSecret),
           material, sizeof(material),
           consumer->auth_result + IUSC_MIC_AUTH_PREFIX_BYTES);
}

static bool serviceConsumerAuthentication(Consumer *consumer,
                                          short revents) {
    if (!consumer || consumer->fd < 0 ||
        consumer->auth_phase == IUSC_CONSUMER_AUTHENTICATED) return false;
    const uint64_t nowNS = monotonicNowNS();
    if (nowNS == 0 || nowNS >= consumer->auth_deadline_ns) return false;

    if (consumer->auth_phase == IUSC_CONSUMER_AUTH_WRITE_CHALLENGE) {
        if ((revents & POLLOUT) == 0) return true;
        const ssize_t written = send(
            consumer->fd,
            consumer->auth_challenge + consumer->auth_offset,
            sizeof(consumer->auth_challenge) - consumer->auth_offset, 0);
        if (written > 0) {
            consumer->auth_offset += (size_t)written;
            if (consumer->auth_offset == sizeof(consumer->auth_challenge)) {
                consumer->auth_phase = IUSC_CONSUMER_AUTH_READ_RESPONSE;
                consumer->auth_offset = 0;
            }
            return true;
        }
        return written < 0 &&
            (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK);
    }

    if (consumer->auth_phase == IUSC_CONSUMER_AUTH_READ_RESPONSE) {
        if ((revents & POLLIN) == 0) return true;
        const ssize_t received = recv(
            consumer->fd,
            consumer->auth_response + consumer->auth_offset,
            sizeof(consumer->auth_response) - consumer->auth_offset, 0);
        if (received > 0) {
            consumer->auth_offset += (size_t)received;
            if (consumer->auth_offset == sizeof(consumer->auth_response)) {
                consumer->auth_allowed = validateConsumerResponse(consumer);
                buildConsumerAuthenticationResult(
                    consumer, consumer->auth_allowed);
                consumer->auth_phase = IUSC_CONSUMER_AUTH_WRITE_RESULT;
                consumer->auth_offset = 0;
            }
            return true;
        }
        if (received == 0) return false;
        return errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK;
    }

    if ((revents & POLLOUT) == 0) return true;
    const ssize_t written = send(
        consumer->fd, consumer->auth_result + consumer->auth_offset,
        sizeof(consumer->auth_result) - consumer->auth_offset, 0);
    if (written > 0) {
        consumer->auth_offset += (size_t)written;
        if (consumer->auth_offset == sizeof(consumer->auth_result)) {
            if (!consumer->auth_allowed) return false;
            consumer->auth_phase = IUSC_CONSUMER_AUTHENTICATED;
            consumer->auth_offset = 0;
            consumer->auth_deadline_ns = 0;
            return queueCurrentStreamStart(consumer);
        }
        return true;
    }
    return written < 0 &&
        (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK);
}

static bool demandGenerationIsNewer(uint32_t candidate, uint32_t previous) {
    return previous == 0 || (int32_t)(candidate - previous) > 0;
}

static bool consumeDemandReport(Consumer *consumer) {
    IUSCMicDemandView report = {0};
    if (!IUSCMicParseDemandReport(
            consumer->input, sizeof(consumer->input), &report)) {
        return false;
    }
    if (report.generation == consumer->demand_generation) {
        return report.active_count == consumer->demand_count;
    }
    if (!demandGenerationIsNewer(
            report.generation, consumer->demand_generation)) {
        return false;
    }
    consumer->demand_generation = report.generation;
    consumer->demand_count = report.active_count;
    publishAggregateDemandIfChanged();
    return true;
}

static bool readConsumerReports(Consumer *consumer) {
    if (!consumer || consumer->fd < 0 ||
        consumer->auth_phase != IUSC_CONSUMER_AUTHENTICATED) return false;
    for (unsigned attempt = 0;
         attempt < IUSC_MAX_CONSUMER_REPORT_READS_PER_PASS;
         ++attempt) {
        const ssize_t received = recv(
            consumer->fd,
            consumer->input + consumer->input_count,
            sizeof(consumer->input) - consumer->input_count, 0);
        if (received > 0) {
            consumer->input_count += (size_t)received;
            if (consumer->input_count == sizeof(consumer->input)) {
                if (!consumeDemandReport(consumer)) {
                    return false;
                }
                consumer->input_count = 0;
            }
            continue;
        }
        if (received == 0) {
            return false;
        }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            return true;
        }
        return false;
    }
    return true;
}

static bool enqueueBytes(Consumer *consumer,
                         const uint8_t *bytes,
                         size_t length) {
    if (!consumer || consumer->fd < 0 || !bytes || length == 0 ||
        length > IUSC_OUTPUT_CAPACITY - consumer->count) {
        return false;
    }
    size_t tail = (consumer->head + consumer->count) % IUSC_OUTPUT_CAPACITY;
    const size_t first = (length < IUSC_OUTPUT_CAPACITY - tail)
        ? length : IUSC_OUTPUT_CAPACITY - tail;
    memcpy(consumer->output + tail, bytes, first);
    if (first < length) {
        memcpy(consumer->output, bytes + first, length - first);
    }
    consumer->count += length;
    return true;
}

static bool queueCurrentStreamStart(Consumer *consumer) {
    if (!consumer || consumer->fd < 0 ||
        consumer->auth_phase != IUSC_CONSUMER_AUTHENTICATED) return false;
    expireIdleStreamIfNeeded();
    if (!gStreamActive) return true;
    uint8_t start[IUSC_MIC_HEADER_BYTES] = {0};
    const size_t startLength = IUSCMicBuildControlPacket(
        start, sizeof(start), IUSC_MIC_FLAG_START,
        gStreamID, gLastSequence, gLastTimestampUS);
    return startLength != 0 && enqueueBytes(consumer, start, startLength);
}

static void broadcastBytes(const uint8_t *bytes, size_t length) {
    for (size_t i = 0; i < IUSC_MAX_CONSUMERS; ++i) {
        Consumer *consumer = &gConsumers[i];
        if (consumer->fd >= 0 &&
            consumer->auth_phase == IUSC_CONSUMER_AUTHENTICATED &&
            !enqueueBytes(consumer, bytes, length)) {
            /* A slow local process is detached instead of corrupting framing. */
            closeConsumer(consumer);
        }
    }
}

static bool flushConsumer(Consumer *consumer) {
    for (unsigned attempt = 0;
         consumer->count > 0 &&
         attempt < IUSC_MAX_CONSUMER_FLUSH_WRITES_PER_PASS;
         ++attempt) {
        const size_t contiguous =
            (consumer->count < IUSC_OUTPUT_CAPACITY - consumer->head)
            ? consumer->count : IUSC_OUTPUT_CAPACITY - consumer->head;
        const ssize_t written = send(consumer->fd,
                                     consumer->output + consumer->head,
                                     contiguous, 0);
        if (written > 0) {
            consumer->head = (consumer->head + (size_t)written) %
                             IUSC_OUTPUT_CAPACITY;
            consumer->count -= (size_t)written;
            continue;
        }
        if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            return true;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        return false;
    }
    return true;
}

static void broadcastSyntheticStop(void) {
    if (!gStreamActive) {
        return;
    }
    uint8_t packet[IUSC_MIC_HEADER_BYTES] = {0};
    const size_t length = IUSCMicBuildControlPacket(
        packet, sizeof(packet), IUSC_MIC_FLAG_STOP,
        gStreamID, gLastSequence + 1u, gLastTimestampUS);
    if (length != 0) {
        broadcastBytes(packet, length);
    }
}

static void clearStreamState(void) {
    gStreamActive = false;
    gHasSequence = false;
    gStreamID = 0;
    gLastSequence = 0;
    gLastTimestampUS = 0;
    gStreamStartMonotonicNS = 0;
    gLastPCMMonotonicNS = 0;
}

static void expireIdleStreamIfNeeded(void) {
    if (!gStreamActive) {
        return;
    }
    const uint64_t nowNS = monotonicNowNS();
    if (nowNS == 0) {
        return;
    }
    uint64_t referenceNS = gLastPCMMonotonicNS != 0
        ? gLastPCMMonotonicNS : gStreamStartMonotonicNS;
    if (referenceNS == 0) {
        /* A transient clock read failure at START still gets one bounded grace. */
        gStreamStartMonotonicNS = nowNS;
        return;
    }
    if (nowNS >= referenceNS &&
        nowNS - referenceNS >= IUSC_PCM_IDLE_WATCHDOG_NS) {
        broadcastSyntheticStop();
        clearStreamState();
    }
}

static bool isNewerSequence(uint32_t candidate, uint32_t previous) {
    return (int32_t)(candidate - previous) > 0;
}

static void processIngressPacket(const uint8_t *bytes, size_t length) {
    IUSCMicPacketView packet = {0};
    if (!IUSCMicParsePacket(bytes, length, &packet)) {
        return;
    }

    uint8_t normalized[IUSC_MIC_MAX_PACKET_BYTES];
    const uint8_t *outBytes = bytes;

    if ((packet.flags & IUSC_MIC_FLAG_START) != 0) {
        if (gStreamActive && gStreamID != packet.stream_id) {
            broadcastSyntheticStop();
        }
        gStreamActive = true;
        gStreamID = packet.stream_id;
        gHasSequence = false;
        gStreamStartMonotonicNS = monotonicNowNS();
        gLastPCMMonotonicNS = 0;
    } else if ((packet.flags & IUSC_MIC_FLAG_DATA) != 0 &&
               (!gStreamActive || gStreamID != packet.stream_id)) {
        /* Recover cleanly if the relay restarted during a held PTT session. */
        memcpy(normalized, bytes, length);
        normalized[5] |= IUSC_MIC_FLAG_START;
        outBytes = normalized;
        gStreamActive = true;
        gStreamID = packet.stream_id;
        gHasSequence = false;
        gStreamStartMonotonicNS = monotonicNowNS();
        gLastPCMMonotonicNS = 0;
    }

    if (!gStreamActive || gStreamID != packet.stream_id) {
        return;
    }
    if ((packet.flags & IUSC_MIC_FLAG_DATA) != 0 && gHasSequence &&
        !isNewerSequence(packet.packet_sequence, gLastSequence)) {
        return;
    }

    gLastSequence = packet.packet_sequence;
    gLastTimestampUS = packet.capture_timestamp_us;
    gHasSequence = true;
    if ((packet.flags & IUSC_MIC_FLAG_DATA) != 0) {
        const uint64_t nowNS = monotonicNowNS();
        if (nowNS != 0) {
            gLastPCMMonotonicNS = nowNS;
        }
    }
    broadcastBytes(outBytes, length);

    if ((packet.flags & IUSC_MIC_FLAG_STOP) != 0) {
        clearStreamState();
    }
}

static int makeIngressSocket(void) {
    const char *directory = "/var/mobile/Library/Caches/local.iphone.usbmic";
    if (mkdir(directory, 0700) != 0 && errno != EEXIST) {
        return -1;
    }
    (void)unlink(IUSC_MIC_INGRESS_SOCKET);

    const int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (fd < 0) {
        return -1;
    }

    /*
     * The Mac capture tap forwards five 1,948-byte datagrams in each 100 ms
     * batch. Darwin's default local-datagram receive space is only 4 KiB, so
     * leaving the default here silently drops most of every batch before the
     * relay can poll it. Make the queue large enough for the bounded 12-packet
     * upstream burst, including mbuf overhead, and fail closed if the kernel
     * cannot honor the requested capacity.
     */
    int receiveBufferBytes = IUSC_INGRESS_RECEIVE_BUFFER_BYTES;
    if (setsockopt(fd, SOL_SOCKET, SO_RCVBUF,
                   &receiveBufferBytes, sizeof(receiveBufferBytes)) != 0) {
        close(fd);
        return -1;
    }
    socklen_t receiveBufferLength = sizeof(receiveBufferBytes);
    receiveBufferBytes = 0;
    if (getsockopt(fd, SOL_SOCKET, SO_RCVBUF,
                   &receiveBufferBytes, &receiveBufferLength) != 0 ||
        receiveBufferBytes < IUSC_INGRESS_RECEIVE_BUFFER_BYTES) {
        close(fd);
        return -1;
    }
    if (!configureNonblockingSocket(fd)) {
        close(fd);
        return -1;
    }

    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    if (sizeof(IUSC_MIC_INGRESS_SOCKET) > sizeof(address.sun_path)) {
        close(fd);
        return -1;
    }
    memcpy(address.sun_path, IUSC_MIC_INGRESS_SOCKET,
           sizeof(IUSC_MIC_INGRESS_SOCKET));
    if (bind(fd, (const struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        return -1;
    }
    (void)chmod(IUSC_MIC_INGRESS_SOCKET, 0620);
    return fd;
}

static int makeConsumerListener(void) {
    const int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    int one = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0) {
        close(fd);
        return -1;
    }

    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(IUSC_MIC_CONSUMER_PORT);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (const struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(fd, IUSC_MAX_CONSUMERS) != 0) {
        close(fd);
        return -1;
    }
    if (!configureNonblockingSocket(fd)) {
        close(fd);
        return -1;
    }
    return fd;
}

static int makeDemandListener(void) {
    const char *directory = "/var/mobile/Library/Caches/local.iphone.usbmic";
    if (mkdir(directory, 0700) != 0 && errno != EEXIST) {
        return -1;
    }
    (void)unlink(IUSC_MIC_DEMAND_SOCKET);

    const int fd = socket(AF_UNIX, SOCK_SEQPACKET, 0);
    if (fd < 0) return -1;
    int one = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0) {
        close(fd);
        return -1;
    }

    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    if (sizeof(IUSC_MIC_DEMAND_SOCKET) > sizeof(address.sun_path)) {
        close(fd);
        return -1;
    }
    memcpy(address.sun_path, IUSC_MIC_DEMAND_SOCKET,
           sizeof(IUSC_MIC_DEMAND_SOCKET));
    if (bind(fd, (const struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(fd, IUSC_MAX_DEMAND_SUBSCRIBERS) != 0) {
        close(fd);
        (void)unlink(IUSC_MIC_DEMAND_SOCKET);
        return -1;
    }
    (void)chmod(IUSC_MIC_DEMAND_SOCKET, 0620);
    if (!configureNonblockingSocket(fd)) {
        close(fd);
        (void)unlink(IUSC_MIC_DEMAND_SOCKET);
        return -1;
    }
    return fd;
}

static bool isTrustedDemandMonitor(int fd) {
    uid_t peerUID = (uid_t)-1;
    gid_t peerGID = (gid_t)-1;
    if (fd < 0 || getpeereid(fd, &peerUID, &peerGID) != 0 ||
        peerUID != geteuid() || peerGID != getegid()) {
        return false;
    }
    pid_t peerPID = 0;
    socklen_t peerPIDLength = sizeof(peerPID);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID,
                   &peerPID, &peerPIDLength) != 0 || peerPID <= 0) {
        return false;
    }
    char processName[64] = {0};
    const int nameLength = proc_name(
        peerPID, processName, (uint32_t)sizeof(processName));
    return nameLength > 0 && strcmp(processName, "trollvncserver") == 0;
}

static void acceptOneDemandSubscriber(int listener) {
    const int fd = accept(listener, NULL, NULL);
    if (fd < 0) return;
    if (!isTrustedDemandMonitor(fd)) {
        close(fd);
        return;
    }
    int noSigPipe = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE,
                     &noSigPipe, sizeof(noSigPipe));
    if (!configureNonblockingSocket(fd)) {
        close(fd);
        return;
    }

    /* One trusted monitor owns the role; a restart atomically replaces it. */
    for (size_t i = 0; i < IUSC_MAX_DEMAND_SUBSCRIBERS; ++i) {
        closeDemandSubscriber(&gDemandSubscribers[i]);
    }
    DemandSubscriber *slot = &gDemandSubscribers[0];
    slot->fd = fd;
    slot->has_pending = false;
    queueDemandSnapshot(slot);
    if (!flushDemandSubscriber(slot)) {
        closeDemandSubscriber(slot);
    }
}

static void acceptOneConsumer(int listener) {
    const int fd = accept(listener, NULL, NULL);
    if (fd < 0) {
        return;
    }

    int noSigPipe = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE,
                     &noSigPipe, sizeof(noSigPipe));
    if (!configureNonblockingSocket(fd)) {
        close(fd);
        return;
    }

    Consumer *slot = NULL;
    for (size_t i = 0; i < IUSC_MAX_CONSUMERS; ++i) {
        if (gConsumers[i].fd < 0) {
            slot = &gConsumers[i];
            break;
        }
    }
    if (!slot) {
        close(fd);
        return;
    }
    slot->fd = fd;
    slot->head = 0;
    slot->count = 0;
    slot->input_count = 0;
    slot->demand_generation = 0;
    slot->demand_count = 0;
    if (!beginConsumerAuthentication(slot, fd)) {
        closeConsumer(slot);
    }
}

int main(void) {
    for (size_t i = 0; i < IUSC_MAX_CONSUMERS; ++i) {
        gConsumers[i].fd = -1;
    }
    for (size_t i = 0; i < IUSC_MAX_DEMAND_SUBSCRIBERS; ++i) {
        gDemandSubscribers[i].fd = -1;
    }
    gAggregateDemandGeneration = arc4random();
    if (gAggregateDemandGeneration == 0) {
        gAggregateDemandGeneration = 1;
    }
    signal(SIGTERM, signalHandler);
    signal(SIGINT, signalHandler);
    signal(SIGPIPE, SIG_IGN);

    const int ingress = makeIngressSocket();
    const int listener = makeConsumerListener();
    const int demandListener = makeDemandListener();
    if (ingress < 0 || listener < 0 || demandListener < 0) {
        if (ingress >= 0) close(ingress);
        if (listener >= 0) close(listener);
        if (demandListener >= 0) close(demandListener);
        (void)unlink(IUSC_MIC_INGRESS_SOCKET);
        (void)unlink(IUSC_MIC_DEMAND_SOCKET);
        return EXIT_FAILURE;
    }

    while (!gShouldExit) {
        expireIdleStreamIfNeeded();
        const uint64_t authNowNS = monotonicNowNS();
        bool hasPendingAuthentication = false;
        for (size_t i = 0; i < IUSC_MAX_CONSUMERS; ++i) {
            Consumer *consumer = &gConsumers[i];
            if (consumer->fd < 0 ||
                consumer->auth_phase == IUSC_CONSUMER_AUTHENTICATED) {
                continue;
            }
            if (authNowNS == 0 ||
                authNowNS >= consumer->auth_deadline_ns) {
                closeConsumer(consumer);
            } else {
                hasPendingAuthentication = true;
            }
        }
        struct pollfd items[3 + IUSC_MAX_CONSUMERS +
                            IUSC_MAX_DEMAND_SUBSCRIBERS];
        nfds_t count = 0;
        items[count++] = (struct pollfd){.fd = ingress, .events = POLLIN};
        items[count++] = (struct pollfd){.fd = listener, .events = POLLIN};
        items[count++] = (struct pollfd){.fd = demandListener,
                                         .events = POLLIN};
        for (size_t i = 0; i < IUSC_MAX_CONSUMERS; ++i) {
            if (gConsumers[i].fd >= 0) {
                short events = 0;
                if (gConsumers[i].auth_phase ==
                    IUSC_CONSUMER_AUTHENTICATED) {
                    events = POLLIN;
                    if (gConsumers[i].count > 0) events |= POLLOUT;
                } else if (gConsumers[i].auth_phase ==
                           IUSC_CONSUMER_AUTH_READ_RESPONSE) {
                    events = POLLIN;
                } else {
                    events = POLLOUT;
                }
                items[count++] = (struct pollfd){.fd = gConsumers[i].fd,
                                                  .events = events};
            }
        }
        for (size_t i = 0; i < IUSC_MAX_DEMAND_SUBSCRIBERS; ++i) {
            if (gDemandSubscribers[i].fd >= 0) {
                short events = POLLIN;
                if (gDemandSubscribers[i].has_pending) events |= POLLOUT;
                items[count++] = (struct pollfd){
                    .fd = gDemandSubscribers[i].fd, .events = events};
            }
        }

        const int result = poll(
            items, count, hasPendingAuthentication ? 25 : 250);
        expireIdleStreamIfNeeded();
        if (result < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (result == 0) continue;

        if ((items[0].revents & POLLIN) != 0) {
            for (size_t attempt = 0;
                 attempt < IUSC_MAX_INGRESS_BATCH;
                 ++attempt) {
                uint8_t packet[IUSC_MIC_MAX_PACKET_BYTES];
                const ssize_t received = recv(ingress, packet, sizeof(packet), 0);
                if (received > 0) {
                    processIngressPacket(packet, (size_t)received);
                    continue;
                }
                if (received < 0 && errno == EINTR) continue;
                break;
            }
            expireIdleStreamIfNeeded();
        }
        if ((items[1].revents & POLLIN) != 0) {
            acceptOneConsumer(listener);
            expireIdleStreamIfNeeded();
        }
        if ((items[2].revents & POLLIN) != 0) {
            acceptOneDemandSubscriber(demandListener);
        }

        for (nfds_t i = 3; i < count; ++i) {
            Consumer *consumer = NULL;
            for (size_t j = 0; j < IUSC_MAX_CONSUMERS; ++j) {
                if (gConsumers[j].fd == items[i].fd) {
                    consumer = &gConsumers[j];
                    break;
                }
            }
            if (consumer) {
                if ((items[i].revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                    closeConsumer(consumer);
                    continue;
                }
                if (consumer->auth_phase !=
                    IUSC_CONSUMER_AUTHENTICATED) {
                    if (!serviceConsumerAuthentication(
                            consumer, items[i].revents)) {
                        closeConsumer(consumer);
                    }
                    continue;
                }
                if ((items[i].revents & POLLIN) != 0 &&
                    !readConsumerReports(consumer)) {
                    closeConsumer(consumer);
                    continue;
                }
                if ((items[i].revents & POLLOUT) != 0 &&
                    !flushConsumer(consumer)) {
                    closeConsumer(consumer);
                }
                continue;
            }

            DemandSubscriber *subscriber = NULL;
            for (size_t j = 0; j < IUSC_MAX_DEMAND_SUBSCRIBERS; ++j) {
                if (gDemandSubscribers[j].fd == items[i].fd) {
                    subscriber = &gDemandSubscribers[j];
                    break;
                }
            }
            if (!subscriber) continue;
            if ((items[i].revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                closeDemandSubscriber(subscriber);
                continue;
            }
            if ((items[i].revents & POLLIN) != 0) {
                uint8_t unexpected[1];
                const ssize_t received = recv(
                    subscriber->fd, unexpected, sizeof(unexpected), 0);
                if (received >= 0 ||
                    (errno != EAGAIN && errno != EWOULDBLOCK &&
                     errno != EINTR)) {
                    closeDemandSubscriber(subscriber);
                    continue;
                }
            }
            if ((items[i].revents & POLLOUT) != 0 &&
                !flushDemandSubscriber(subscriber)) {
                closeDemandSubscriber(subscriber);
            }
        }
        expireIdleStreamIfNeeded();
    }

    broadcastSyntheticStop();
    for (size_t i = 0; i < IUSC_MAX_CONSUMERS; ++i) {
        closeConsumer(&gConsumers[i]);
    }
    for (size_t i = 0; i < IUSC_MAX_DEMAND_SUBSCRIBERS; ++i) {
        closeDemandSubscriber(&gDemandSubscribers[i]);
    }
    close(demandListener);
    close(listener);
    close(ingress);
    (void)unlink(IUSC_MIC_INGRESS_SOCKET);
    (void)unlink(IUSC_MIC_DEMAND_SOCKET);
    return EXIT_SUCCESS;
}
