#include "MicStreamClient.h"

#include "IUSCMicProtocol.h"
#include "IUSCMicSecret.h"
#include "MicStream.h"

#include <CommonCrypto/CommonHMAC.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

enum {
    IUSC_CLIENT_THREAD_IDLE = 0,
    IUSC_CLIENT_THREAD_RUNNING = 1,
};

#define IUSC_CONNECT_TIMEOUT_MS 500u
#define IUSC_AUTH_TIMEOUT_MS 1000u
#define IUSC_FRAME_TIMEOUT_MS 1000u
#define IUSC_REPORT_TIMEOUT_MS 200u
#define IUSC_STABLE_CONNECTION_NS 5000000000ull

static pthread_once_t gStreamOnce = PTHREAD_ONCE_INIT;
static _Atomic(int) gClientThreadState = IUSC_CLIENT_THREAD_IDLE;

static uint64_t monotonicNowNS(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0 || now.tv_sec < 0) {
        return 0;
    }
    return (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_nsec;
}

static uint64_t deadlineAfterMilliseconds(unsigned milliseconds) {
    const uint64_t now = monotonicNowNS();
    const uint64_t delta = (uint64_t)milliseconds * 1000000ull;
    if (now == 0 || UINT64_MAX - now < delta) return 0;
    return now + delta;
}

static int millisecondsUntil(uint64_t deadlineNS) {
    const uint64_t now = monotonicNowNS();
    if (now == 0 || deadlineNS == 0 || now >= deadlineNS) return 0;
    const uint64_t remaining = deadlineNS - now;
    const uint64_t rounded = (remaining + 999999ull) / 1000000ull;
    return rounded > (uint64_t)INT_MAX ? INT_MAX : (int)rounded;
}

static bool waitForFDUntil(int fd, short events, uint64_t deadlineNS) {
    struct pollfd item = {.fd = fd, .events = events, .revents = 0};
    for (;;) {
        const int timeoutMS = millisecondsUntil(deadlineNS);
        if (timeoutMS <= 0) return false;
        item.revents = 0;
        const int result = poll(&item, 1, timeoutMS);
        if (result > 0) {
            if ((item.revents & events) != 0) return true;
            if ((item.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                return false;
            }
            continue;
        }
        if (result == 0) return false;
        if (errno != EINTR) return false;
    }
}

static bool readExactlyUntil(int fd, uint8_t *bytes, size_t length,
                             uint64_t deadlineNS) {
    size_t offset = 0;
    while (offset < length) {
        if (!waitForFDUntil(fd, POLLIN, deadlineNS)) return false;
        const ssize_t received = recv(fd, bytes + offset, length - offset, 0);
        if (received > 0) {
            offset += (size_t)received;
        } else if (received < 0 && errno == EINTR) {
            continue;
        } else if (received < 0 &&
                   (errno == EAGAIN || errno == EWOULDBLOCK)) {
            continue;
        } else {
            return false;
        }
    }
    return true;
}

static bool writeExactlyUntil(int fd, const uint8_t *bytes, size_t length,
                              uint64_t deadlineNS) {
    size_t offset = 0;
    while (offset < length) {
        if (!waitForFDUntil(fd, POLLOUT, deadlineNS)) return false;
        const ssize_t written = send(fd, bytes + offset, length - offset, 0);
        if (written > 0) {
            offset += (size_t)written;
        } else if (written < 0 && errno == EINTR) {
            continue;
        } else if (written < 0 &&
                   (errno == EAGAIN || errno == EWOULDBLOCK)) {
            continue;
        } else {
            return false;
        }
    }
    return true;
}

static int connectToRelay(void) {
    const int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int noSigPipe = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE,
                     &noSigPipe, sizeof(noSigPipe));
    (void)fcntl(fd, F_SETFD, FD_CLOEXEC);
    const int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) {
        close(fd);
        return -1;
    }

    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(IUSC_MIC_CONSUMER_PORT);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    const int connectResult = connect(
        fd, (const struct sockaddr *)&address, sizeof(address));
    if (connectResult != 0 && errno != EINPROGRESS) {
        close(fd);
        return -1;
    }
    if (connectResult != 0) {
        const uint64_t deadline =
            deadlineAfterMilliseconds(IUSC_CONNECT_TIMEOUT_MS);
        int socketError = 0;
        socklen_t errorLength = sizeof(socketError);
        if (!waitForFDUntil(fd, POLLOUT, deadline) ||
            getsockopt(fd, SOL_SOCKET, SO_ERROR,
                       &socketError, &errorLength) != 0 ||
            socketError != 0) {
            close(fd);
            return -1;
        }
    }
    return fd;
}

static bool constantTimeEqual(const uint8_t *left, const uint8_t *right,
                              size_t length) {
    uint8_t difference = 0;
    for (size_t i = 0; i < length; ++i) {
        difference |= (uint8_t)(left[i] ^ right[i]);
    }
    return difference == 0;
}

static bool authenticateRelay(int fd) {
    const uint64_t deadline =
        deadlineAfterMilliseconds(IUSC_AUTH_TIMEOUT_MS);
    if (deadline == 0) return false;
    uint8_t challenge[IUSC_MIC_AUTH_CHALLENGE_BYTES] = {0};
    if (!readExactlyUntil(fd, challenge, sizeof(challenge), deadline) ||
        memcmp(challenge, IUSC_MIC_AUTH_CHALLENGE_MAGIC, 4) != 0 ||
        challenge[4] != IUSC_MIC_AUTH_VERSION || challenge[5] != 0 ||
        IUSCMicReadBE16(challenge + 6) !=
            IUSC_MIC_AUTH_CHALLENGE_BYTES) {
        return false;
    }

    uint8_t response[IUSC_MIC_AUTH_RESPONSE_BYTES] = {0};
    memcpy(response, IUSC_MIC_AUTH_RESPONSE_MAGIC, 4);
    response[4] = IUSC_MIC_AUTH_VERSION;
    IUSCMicWriteBE16(response + 6, IUSC_MIC_AUTH_RESPONSE_BYTES);
    CCHmac(kCCHmacAlgSHA256,
           kIUSCMicConsumerSecret, sizeof(kIUSCMicConsumerSecret),
           challenge, sizeof(challenge), response + 8);
    if (!writeExactlyUntil(fd, response, sizeof(response), deadline)) {
        return false;
    }

    uint8_t result[IUSC_MIC_AUTH_RESULT_BYTES] = {0};
    if (!readExactlyUntil(fd, result, sizeof(result), deadline) ||
        memcmp(result, IUSC_MIC_AUTH_RESULT_MAGIC, 4) != 0 ||
        result[4] != IUSC_MIC_AUTH_VERSION ||
        IUSCMicReadBE16(result + 6) != IUSC_MIC_AUTH_RESULT_BYTES) {
        return false;
    }
    uint8_t authenticationMaterial[
        IUSC_MIC_AUTH_CHALLENGE_BYTES + IUSC_MIC_AUTH_PREFIX_BYTES] = {0};
    memcpy(authenticationMaterial, challenge, sizeof(challenge));
    memcpy(authenticationMaterial + sizeof(challenge), result,
           IUSC_MIC_AUTH_PREFIX_BYTES);
    uint8_t expectedTag[IUSC_MIC_AUTH_TAG_BYTES] = {0};
    CCHmac(kCCHmacAlgSHA256,
           kIUSCMicConsumerSecret, sizeof(kIUSCMicConsumerSecret),
           authenticationMaterial, sizeof(authenticationMaterial), expectedTag);
    return constantTimeEqual(expectedTag,
                             result + IUSC_MIC_AUTH_PREFIX_BYTES,
                             sizeof(expectedTag)) && result[5] == 0;
}

static bool readAndDispatchPacket(int fd) {
    const uint64_t deadline =
        deadlineAfterMilliseconds(IUSC_FRAME_TIMEOUT_MS);
    if (deadline == 0) return false;
    uint8_t packet[IUSC_MIC_MAX_PACKET_BYTES] = {0};
    if (!readExactlyUntil(fd, packet, IUSC_MIC_HEADER_BYTES, deadline) ||
        !IUSCMicHasMagic(packet, IUSC_MIC_HEADER_BYTES) ||
        packet[4] != IUSC_MIC_VERSION ||
        IUSCMicReadBE16(packet + 6) != IUSC_MIC_HEADER_BYTES) {
        return false;
    }
    const uint16_t sampleCount = IUSCMicReadBE16(packet + 24);
    if (sampleCount > IUSC_MIC_MAX_PACKET_SAMPLES) {
        return false;
    }
    const size_t payloadLength = (size_t)sampleCount * 2u;
    if (payloadLength > 0 &&
        !readExactlyUntil(fd, packet + IUSC_MIC_HEADER_BYTES,
                          payloadLength, deadline)) {
        return false;
    }

    IUSCMicPacketView view = {0};
    if (!IUSCMicParsePacket(packet,
                            IUSC_MIC_HEADER_BYTES + payloadLength,
                            &view)) {
        return false;
    }
    if ((view.flags & IUSC_MIC_FLAG_START) != 0) {
        IUSCMicStreamStart(view.stream_id);
    }
    if ((view.flags & IUSC_MIC_FLAG_DATA) != 0) {
        if (!IUSCMicStreamIsActive() || IUSCMicStreamID() != view.stream_id) {
            IUSCMicStreamStart(view.stream_id);
        }
        IUSCMicStreamPushPCM(view.stream_id, view.pcm, view.sample_count);
    }
    if ((view.flags & IUSC_MIC_FLAG_STOP) != 0) {
        IUSCMicStreamStop(view.stream_id);
    }
    return true;
}

static bool sendDemandSnapshotIfChanged(int fd,
                                        uint32_t *lastSentGeneration) {
    uint32_t activeCount = 0;
    uint32_t generation = 0;
    IUSCMicDemandSnapshot(&activeCount, &generation);
    if (generation == 0 || generation == *lastSentGeneration) {
        return true;
    }

    uint8_t report[IUSC_MIC_DEMAND_REPORT_BYTES] = {0};
    const size_t length = IUSCMicBuildDemandReport(
        report, sizeof(report), generation, activeCount);
    const uint64_t deadline =
        deadlineAfterMilliseconds(IUSC_REPORT_TIMEOUT_MS);
    if (length != sizeof(report) || deadline == 0 ||
        !writeExactlyUntil(fd, report, length, deadline)) {
        return false;
    }
    *lastSentGeneration = generation;
    return true;
}

static bool runAuthenticatedConnection(int fd) {
    uint32_t lastSentGeneration = 0;
    for (;;) {
        if (!sendDemandSnapshotIfChanged(fd, &lastSentGeneration)) {
            return false;
        }

        struct pollfd item = {.fd = fd, .events = POLLIN, .revents = 0};
        const int result = poll(&item, 1, 20);
        if (result < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (result == 0) {
            continue;
        }
        if ((item.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
            return false;
        }
        if ((item.revents & POLLIN) != 0 && !readAndDispatchPacket(fd)) {
            return false;
        }
    }
}

static void sleepMilliseconds(unsigned milliseconds) {
    struct timespec interval = {
        .tv_sec = (time_t)(milliseconds / 1000u),
        .tv_nsec = (long)(milliseconds % 1000u) * 1000000L,
    };
    while (nanosleep(&interval, &interval) != 0 && errno == EINTR) {}
}

static void *clientThread(void *context) {
    (void)context;
    unsigned retryDelayMS = 250;
    for (;;) {
        const uint64_t attemptStartedNS = monotonicNowNS();
        const int fd = connectToRelay();
        if (fd >= 0 && authenticateRelay(fd)) {
            (void)runAuthenticatedConnection(fd);
        }
        if (fd >= 0) close(fd);
        IUSCMicStreamTransportDisconnected();
        const uint64_t attemptEndedNS = monotonicNowNS();
        if (attemptStartedNS != 0 && attemptEndedNS >= attemptStartedNS &&
            attemptEndedNS - attemptStartedNS >= IUSC_STABLE_CONNECTION_NS) {
            retryDelayMS = 250;
        }
        sleepMilliseconds(retryDelayMS);
        if (retryDelayMS < 8000) {
            retryDelayMS = retryDelayMS > 4000 ? 8000 : retryDelayMS * 2;
        }
    }
    atomic_store_explicit(&gClientThreadState, IUSC_CLIENT_THREAD_IDLE,
                          memory_order_release);
    return NULL;
}

static void initializeStreamOnce(void) {
    IUSCMicStreamInitialize();
}

void IUSCMicStreamClientStart(void) {
    (void)pthread_once(&gStreamOnce, initializeStreamOnce);
    int expected = IUSC_CLIENT_THREAD_IDLE;
    if (!atomic_compare_exchange_strong_explicit(
            &gClientThreadState, &expected, IUSC_CLIENT_THREAD_RUNNING,
            memory_order_acq_rel, memory_order_acquire)) {
        return;
    }
    pthread_t thread;
    if (pthread_create(&thread, NULL, clientThread, NULL) == 0) {
        (void)pthread_detach(thread);
    } else {
        atomic_store_explicit(&gClientThreadState, IUSC_CLIENT_THREAD_IDLE,
                              memory_order_release);
    }
}
