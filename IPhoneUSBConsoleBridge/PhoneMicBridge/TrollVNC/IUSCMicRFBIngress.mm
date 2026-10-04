#include "IUSCMicRFBIngress.h"
#include "IUSCMicProtocol.h"

#include <rfb/rfb.h>
#include <rfb/rfbproto.h>

#include <arpa/inet.h>
#include <atomic>
#include <errno.h>
#include <fcntl.h>
#include <os/log.h>
#include <os/lock.h>
#include <poll.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

namespace {

constexpr size_t kMaximumDemandCapabilities = 64;
constexpr uint64_t kDemandBroadcastBudgetNS = 50000000ull;
constexpr int kDemandConnectTimeoutMS = 250;
constexpr int kDemandMonitorPollTimeoutMS = 250;
constexpr long kDemandStopTimeoutNS = 2000000000L;

struct DemandCapability {
    uintptr_t clientCookie;
    uint32_t clientNonce;
};

os_unfair_lock gStateLock = OS_UNFAIR_LOCK_INIT;
pthread_mutex_t gIngressMutex = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_t gNotificationMutex = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_t gMonitorLifecycleMutex = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_t gMonitorExitMutex = PTHREAD_MUTEX_INITIALIZER;
pthread_cond_t gMonitorExitCondition = PTHREAD_COND_INITIALIZER;
uintptr_t gOwner = 0;
uint32_t gStreamID = 0;
uint32_t gLastSequence = 0;
uint64_t gLastTimestampUS = 0;
bool gAcceptingMicIngress = false;
int gDatagramSocket = -1;
std::atomic<bool> gDidLogDatagramFailure{false};

DemandCapability gCapabilities[kMaximumDemandCapabilities] = {};
rfbScreenInfoPtr gDemandScreen = nullptr;
uint32_t gPublishedDemandGeneration = 1;
uint32_t gPublishedDemandCount = 0;
uint64_t gPublishedDemandRevision = 1;
pthread_t gDemandThread = {};
std::atomic<bool> gDemandThreadRunning{false};
std::atomic<int> gDemandConnection{-1};
bool gDemandThreadExited = true;

uint32_t nextNonzeroGeneration(uint32_t generation) {
    generation += 1u;
    return generation == 0 ? 1u : generation;
}

uint64_t monotonicNowNS() {
    timespec now = {};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0 || now.tv_sec < 0) {
        return 0;
    }
    return static_cast<uint64_t>(now.tv_sec) * 1000000000ull +
           static_cast<uint64_t>(now.tv_nsec);
}

timespec realtimeDeadlineAfter(long nanoseconds) {
    timespec deadline = {};
    if (clock_gettime(CLOCK_REALTIME, &deadline) != 0) return deadline;
    deadline.tv_sec += nanoseconds / 1000000000L;
    deadline.tv_nsec += nanoseconds % 1000000000L;
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec += 1;
        deadline.tv_nsec -= 1000000000L;
    }
    return deadline;
}

int relaySocket() {
    os_unfair_lock_lock(&gStateLock);
    if (gDatagramSocket < 0) {
        const int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
        if (fd >= 0) {
            (void)fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
            (void)fcntl(fd, F_SETFD, FD_CLOEXEC);
            int noSigPipe = 1;
            (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE,
                             &noSigPipe, sizeof(noSigPipe));
            gDatagramSocket = fd;
        }
    }
    const int fd = gDatagramSocket;
    os_unfair_lock_unlock(&gStateLock);
    return fd;
}

void forwardDatagram(const uint8_t *bytes, size_t length) {
    const int fd = relaySocket();
    if (fd < 0 || !bytes || length == 0 || length > IUSC_MIC_MAX_PACKET_BYTES) {
        return;
    }

    sockaddr_un address = {};
    address.sun_family = AF_UNIX;
    static_assert(sizeof(IUSC_MIC_INGRESS_SOCKET) <= sizeof(address.sun_path),
                  "mic ingress socket path is too long");
    memcpy(address.sun_path, IUSC_MIC_INGRESS_SOCKET,
           sizeof(IUSC_MIC_INGRESS_SOCKET));
    const ssize_t sent = sendto(
        fd, bytes, length, MSG_DONTWAIT,
        reinterpret_cast<const sockaddr *>(&address), sizeof(address));
    if (sent != static_cast<ssize_t>(length)) {
        const int errorNumber = sent < 0 ? errno : EMSGSIZE;
        bool expected = false;
        if (gDidLogDatagramFailure.compare_exchange_strong(
                expected, true, std::memory_order_relaxed)) {
            os_log_error(OS_LOG_DEFAULT,
                         "IUSCMic relay datagram failed: errno=%{public}d sent=%{public}ld expected=%{public}lu",
                         errorNumber, (long)sent, (unsigned long)length);
        }
    }
}

size_t retireOwnedStreamLocked(
    uintptr_t requiredOwner,
    uint8_t stopPacket[IUSC_MIC_HEADER_BYTES]) {
    if (gOwner == 0 || (requiredOwner != 0 && gOwner != requiredOwner)) {
        return 0;
    }
    const size_t length = IUSCMicBuildControlPacket(
        stopPacket, IUSC_MIC_HEADER_BYTES, IUSC_MIC_FLAG_STOP,
        gStreamID, gLastSequence + 1u, gLastTimestampUS);
    gOwner = 0;
    gStreamID = 0;
    gLastSequence = 0;
    gLastTimestampUS = 0;
    return length;
}

bool clientHasDemandCapability(uintptr_t clientCookie) {
    bool found = false;
    os_unfair_lock_lock(&gStateLock);
    for (const DemandCapability& capability : gCapabilities) {
        if (capability.clientCookie == clientCookie) {
            found = true;
            break;
        }
    }
    os_unfair_lock_unlock(&gStateLock);
    return found;
}

bool registerDemandCapability(uintptr_t clientCookie, uint32_t clientNonce) {
    bool registered = false;
    os_unfair_lock_lock(&gStateLock);
    DemandCapability *empty = nullptr;
    for (DemandCapability& capability : gCapabilities) {
        if (capability.clientCookie == clientCookie) {
            capability.clientNonce = clientNonce;
            registered = true;
            break;
        }
        if (!empty && capability.clientCookie == 0) {
            empty = &capability;
        }
    }
    if (!registered && empty) {
        empty->clientCookie = clientCookie;
        empty->clientNonce = clientNonce;
        registered = true;
    }
    os_unfair_lock_unlock(&gStateLock);
    return registered;
}

void removeDemandCapability(uintptr_t clientCookie) {
    os_unfair_lock_lock(&gStateLock);
    for (DemandCapability& capability : gCapabilities) {
        if (capability.clientCookie == clientCookie) {
            capability = {};
            break;
        }
    }
    os_unfair_lock_unlock(&gStateLock);
}

bool currentDemandNotification(
    uint8_t bytes[IUSC_MIC_DEMAND_NOTIFY_BYTES],
    uint64_t *revisionOut) {
    bool built = false;
    os_unfair_lock_lock(&gStateLock);
    built = IUSCMicBuildDemandNotification(
        bytes, IUSC_MIC_DEMAND_NOTIFY_BYTES,
        gPublishedDemandGeneration, gPublishedDemandCount) ==
        IUSC_MIC_DEMAND_NOTIFY_BYTES;
    if (built && revisionOut) *revisionOut = gPublishedDemandRevision;
    os_unfair_lock_unlock(&gStateLock);
    return built;
}

bool demandRevisionIsCurrent(uint64_t revision) {
    bool current = false;
    os_unfair_lock_lock(&gStateLock);
    current = revision != 0 && revision == gPublishedDemandRevision;
    os_unfair_lock_unlock(&gStateLock);
    return current;
}

bool sendDemandNotificationToClient(
    rfbClientPtr client,
    const uint8_t bytes[IUSC_MIC_DEMAND_NOTIFY_BYTES]) {
    if (!client || client->viewOnly || client->sock < 0 || !bytes) {
        return false;
    }

    rfbServerCutTextMsg header = {};
    header.type = rfbServerCutText;
    header.length = htonl(IUSC_MIC_DEMAND_NOTIFY_BYTES);
    if (pthread_mutex_trylock(&client->sendMutex) != 0) {
        return false;
    }
    bool sent = false;
    if (client->viewOnly || client->sock < 0) {
        sent = false;
    } else {
        iovec vectors[2] = {
            {.iov_base = &header, .iov_len = sz_rfbServerCutTextMsg},
            {.iov_base = const_cast<uint8_t *>(bytes),
             .iov_len = IUSC_MIC_DEMAND_NOTIFY_BYTES},
        };
        msghdr message = {};
        message.msg_iov = vectors;
        message.msg_iovlen = 2;
        const size_t expected =
            sz_rfbServerCutTextMsg + IUSC_MIC_DEMAND_NOTIFY_BYTES;
        const ssize_t written = sendmsg(client->sock, &message, MSG_DONTWAIT);
        if (written == static_cast<ssize_t>(expected)) {
            sent = true;
            rfbStatRecordMessageSent(client, rfbServerCutText,
                                     expected, expected);
        } else if (!(written < 0 &&
                     (errno == EAGAIN || errno == EWOULDBLOCK ||
                      errno == EINTR))) {
            (void)shutdown(client->sock, SHUT_RDWR);
            rfbCloseClient(client);
        }
    }
    pthread_mutex_unlock(&client->sendMutex);
    return sent;
}

void broadcastDemandNotification(
    const uint8_t bytes[IUSC_MIC_DEMAND_NOTIFY_BYTES],
    uint64_t revision) {
    rfbScreenInfoPtr screen = nullptr;
    os_unfair_lock_lock(&gStateLock);
    screen = gDemandScreen;
    os_unfair_lock_unlock(&gStateLock);
    if (!screen) return;
    const uint64_t startedNS = monotonicNowNS();
    if (startedNS == 0 ||
        UINT64_MAX - startedNS < kDemandBroadcastBudgetNS) return;
    const uint64_t deadlineNS = startedNS + kDemandBroadcastBudgetNS;

    rfbClientIteratorPtr iterator = rfbGetClientIterator(screen);
    if (!iterator) return;
    rfbClientPtr client = nullptr;
    while ((client = rfbClientIteratorNext(iterator)) != nullptr) {
        const uint64_t nowNS = monotonicNowNS();
        if (nowNS == 0 || nowNS >= deadlineNS ||
            !demandRevisionIsCurrent(revision)) {
            break;
        }
        const uintptr_t cookie = reinterpret_cast<uintptr_t>(client);
        if (!client->viewOnly && clientHasDemandCapability(cookie)) {
            (void)sendDemandNotificationToClient(client, bytes);
        }
    }
    rfbReleaseClientIterator(iterator);
}

void publishDemandSnapshot(uint32_t activeCount, bool forceNewEpoch) {
    uint8_t bytes[IUSC_MIC_DEMAND_NOTIFY_BYTES] = {};
    bool shouldBroadcast = false;
    uint64_t revision = 0;
    pthread_mutex_lock(&gNotificationMutex);
    os_unfair_lock_lock(&gStateLock);
    const bool wasActive = gPublishedDemandCount != 0;
    const bool isActive = activeCount != 0;
    const bool countChanged = gPublishedDemandCount != activeCount;
    if (forceNewEpoch || wasActive != isActive) {
        gPublishedDemandGeneration =
            nextNonzeroGeneration(gPublishedDemandGeneration);
    }
    gPublishedDemandCount = activeCount;
    shouldBroadcast = forceNewEpoch || countChanged;
    if (shouldBroadcast) {
        ++gPublishedDemandRevision;
        if (gPublishedDemandRevision == 0) ++gPublishedDemandRevision;
        revision = gPublishedDemandRevision;
        (void)IUSCMicBuildDemandNotification(
            bytes, sizeof(bytes), gPublishedDemandGeneration,
            gPublishedDemandCount);
    }
    os_unfair_lock_unlock(&gStateLock);
    if (shouldBroadcast) {
        broadcastDemandNotification(bytes, revision);
    }
    pthread_mutex_unlock(&gNotificationMutex);
}

int connectToDemandDaemon() {
    const int fd = socket(AF_UNIX, SOCK_SEQPACKET, 0);
    if (fd < 0) return -1;
    (void)fcntl(fd, F_SETFD, FD_CLOEXEC);
    const int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) {
        close(fd);
        return -1;
    }
    struct sockaddr_un address = {};
    address.sun_family = AF_UNIX;
    static_assert(sizeof(IUSC_MIC_DEMAND_SOCKET) <= sizeof(address.sun_path),
                  "mic demand socket path is too long");
    memcpy(address.sun_path, IUSC_MIC_DEMAND_SOCKET,
           sizeof(IUSC_MIC_DEMAND_SOCKET));
    const int result = connect(
        fd, reinterpret_cast<const sockaddr *>(&address), sizeof(address));
    if (result != 0 && errno != EINPROGRESS) {
        close(fd);
        return -1;
    }
    if (result != 0) {
        pollfd item = {.fd = fd, .events = POLLOUT, .revents = 0};
        int pollResult = -1;
        do {
            pollResult = poll(&item, 1, kDemandConnectTimeoutMS);
        } while (pollResult < 0 && errno == EINTR &&
                 gDemandThreadRunning.load(std::memory_order_acquire));
        int socketError = 0;
        socklen_t errorLength = sizeof(socketError);
        if (pollResult <= 0 || (item.revents & POLLOUT) == 0 ||
            getsockopt(fd, SOL_SOCKET, SO_ERROR,
                       &socketError, &errorLength) != 0 ||
            socketError != 0) {
            close(fd);
            return -1;
        }
    }
    return fd;
}

void sleepRetryInterval() {
    struct timespec interval = {.tv_sec = 0, .tv_nsec = 250000000L};
    while (gDemandThreadRunning.load(std::memory_order_acquire) &&
           nanosleep(&interval, &interval) != 0 && errno == EINTR) {}
}

void releaseDemandConnectionFromMonitor(int fd) {
    if (fd < 0) return;
    int expected = fd;
    if (gDemandConnection.compare_exchange_strong(
            expected, -1, std::memory_order_acq_rel)) {
        close(fd);
    }
    /*
     * If the compare/exchange failed, Stop has taken descriptor ownership.
     * It first shuts the socket down, then closes it only after this thread
     * has exited, so neither side can act on a recycled descriptor number.
     */
}

void *demandMonitorThread(void *) {
    while (gDemandThreadRunning.load(std::memory_order_acquire)) {
        const int fd = connectToDemandDaemon();
        if (fd < 0) {
            sleepRetryInterval();
            continue;
        }
        gDemandConnection.store(fd, std::memory_order_release);
        if (!gDemandThreadRunning.load(std::memory_order_acquire)) {
            releaseDemandConnectionFromMonitor(fd);
            break;
        }
        bool receivedSnapshot = false;
        uint32_t sourceGeneration = 0;
        bool sourceActive = false;
        while (gDemandThreadRunning.load(std::memory_order_acquire)) {
            pollfd item = {.fd = fd, .events = POLLIN, .revents = 0};
            const int pollResult = poll(
                &item, 1, kDemandMonitorPollTimeoutMS);
            if (pollResult < 0) {
                if (errno == EINTR) continue;
                break;
            }
            if (pollResult == 0) continue;
            if ((item.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                break;
            }
            if ((item.revents & POLLIN) == 0) continue;
            uint8_t bytes[IUSC_MIC_DEMAND_NOTIFY_BYTES] = {};
            const ssize_t received = recv(fd, bytes, sizeof(bytes), 0);
            if (received < 0 &&
                (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) {
                continue;
            }
            if (received != static_cast<ssize_t>(sizeof(bytes))) {
                break;
            }
            IUSCMicDemandView snapshot = {};
            if (!IUSCMicParseDemandNotification(
                    bytes, sizeof(bytes), &snapshot)) {
                break;
            }
            if (receivedSnapshot) {
                if (snapshot.generation == sourceGeneration) {
                    /* Count may change inside one active epoch; state may not. */
                    if (snapshot.active != sourceActive) {
                        break;
                    }
                } else if ((int32_t)(snapshot.generation - sourceGeneration) <= 0) {
                    break;
                }
            }
            sourceGeneration = snapshot.generation;
            sourceActive = snapshot.active;
            if (!gDemandThreadRunning.load(std::memory_order_acquire)) break;
            publishDemandSnapshot(snapshot.active_count, !receivedSnapshot);
            receivedSnapshot = true;
        }

        releaseDemandConnectionFromMonitor(fd);
        if (receivedSnapshot &&
            gDemandThreadRunning.load(std::memory_order_acquire)) {
            /* A lost local source of truth is immediately fail-closed idle. */
            publishDemandSnapshot(0, true);
        }
        if (gDemandThreadRunning.load(std::memory_order_acquire)) {
            sleepRetryInterval();
        }
    }
    pthread_mutex_lock(&gMonitorExitMutex);
    gDemandThreadExited = true;
    pthread_cond_broadcast(&gMonitorExitCondition);
    pthread_mutex_unlock(&gMonitorExitMutex);
    return nullptr;
}

} // namespace

bool IUSCMicHandleRFBEnvelope(const uint8_t *bytes,
                              size_t length,
                              uintptr_t clientCookie,
                              bool viewOnly) {
    if (IUSCMicHasDemandHelloMagic(bytes, length)) {
        uint32_t clientNonce = 0;
        if (!viewOnly && clientCookie != 0 &&
            IUSCMicParseDemandHello(bytes, length, &clientNonce)) {
            pthread_mutex_lock(&gNotificationMutex);
            if (registerDemandCapability(clientCookie, clientNonce)) {
                uint8_t notification[IUSC_MIC_DEMAND_NOTIFY_BYTES] = {};
                uint64_t revision = 0;
                if (currentDemandNotification(notification, &revision) &&
                    demandRevisionIsCurrent(revision)) {
                    (void)sendDemandNotificationToClient(
                        reinterpret_cast<rfbClientPtr>(clientCookie),
                        notification);
                }
            }
            pthread_mutex_unlock(&gNotificationMutex);
        }
        return true;
    }
    if (!IUSCMicHasMagic(bytes, length)) {
        return false;
    }

    IUSCMicPacketView packet = {};
    if (viewOnly || clientCookie == 0 ||
        !IUSCMicParsePacket(bytes, length, &packet)) {
        return true;
    }

    bool accepted = false;
    pthread_mutex_lock(&gIngressMutex);
    os_unfair_lock_lock(&gStateLock);
    if (!gAcceptingMicIngress) {
        accepted = false;
    } else if ((packet.flags & IUSC_MIC_FLAG_START) != 0) {
        if (gOwner == 0 || gOwner == clientCookie) {
            gOwner = clientCookie;
            gStreamID = packet.stream_id;
            gLastSequence = packet.packet_sequence;
            gLastTimestampUS = packet.capture_timestamp_us;
            accepted = true;
        }
    } else if (gOwner == clientCookie && gStreamID == packet.stream_id) {
        accepted = true;
        gLastSequence = packet.packet_sequence;
        gLastTimestampUS = packet.capture_timestamp_us;
    }

    if (accepted && (packet.flags & IUSC_MIC_FLAG_STOP) != 0) {
        gOwner = 0;
        gStreamID = 0;
        gLastSequence = 0;
        gLastTimestampUS = 0;
    }
    os_unfair_lock_unlock(&gStateLock);

    if (accepted) {
        forwardDatagram(bytes, length);
    }
    pthread_mutex_unlock(&gIngressMutex);
    return true;
}

void IUSCMicRFBClientDisconnected(uintptr_t clientCookie) {
    uint8_t stopPacket[IUSC_MIC_HEADER_BYTES] = {};
    size_t stopLength = 0;

    removeDemandCapability(clientCookie);
    pthread_mutex_lock(&gIngressMutex);
    os_unfair_lock_lock(&gStateLock);
    if (clientCookie != 0)
        stopLength = retireOwnedStreamLocked(clientCookie, stopPacket);
    os_unfair_lock_unlock(&gStateLock);

    if (stopLength != 0) {
        forwardDatagram(stopPacket, stopLength);
    }
    pthread_mutex_unlock(&gIngressMutex);
}

bool IUSCMicDemandMonitorStart(void *rfbScreen) {
    if (!rfbScreen) return false;
    pthread_mutex_lock(&gMonitorLifecycleMutex);
    if (gDemandThreadRunning.load(std::memory_order_acquire)) {
        rfbScreenInfoPtr currentScreen = nullptr;
        os_unfair_lock_lock(&gStateLock);
        currentScreen = gDemandScreen;
        os_unfair_lock_unlock(&gStateLock);
        pthread_mutex_unlock(&gMonitorLifecycleMutex);
        /* A second server must explicitly stop before taking monitor ownership. */
        return currentScreen == reinterpret_cast<rfbScreenInfoPtr>(rfbScreen);
    }

    pthread_mutex_lock(&gNotificationMutex);
    os_unfair_lock_lock(&gStateLock);
    gDemandScreen = reinterpret_cast<rfbScreenInfoPtr>(rfbScreen);
    gAcceptingMicIngress = false;
    gPublishedDemandGeneration = arc4random();
    if (gPublishedDemandGeneration == 0) {
        gPublishedDemandGeneration = 1;
    }
    gPublishedDemandCount = 0;
    ++gPublishedDemandRevision;
    if (gPublishedDemandRevision == 0) ++gPublishedDemandRevision;
    memset(gCapabilities, 0, sizeof(gCapabilities));
    os_unfair_lock_unlock(&gStateLock);
    pthread_mutex_unlock(&gNotificationMutex);

    pthread_mutex_lock(&gMonitorExitMutex);
    gDemandThreadExited = false;
    pthread_mutex_unlock(&gMonitorExitMutex);
    gDemandThreadRunning.store(true, std::memory_order_release);

    if (pthread_create(&gDemandThread, nullptr,
                       demandMonitorThread, nullptr) != 0) {
        gDemandThreadRunning.store(false, std::memory_order_release);
        pthread_mutex_lock(&gMonitorExitMutex);
        gDemandThreadExited = true;
        pthread_cond_broadcast(&gMonitorExitCondition);
        pthread_mutex_unlock(&gMonitorExitMutex);
        pthread_mutex_lock(&gNotificationMutex);
        os_unfair_lock_lock(&gStateLock);
        gDemandScreen = nullptr;
        gAcceptingMicIngress = false;
        memset(gCapabilities, 0, sizeof(gCapabilities));
        os_unfair_lock_unlock(&gStateLock);
        pthread_mutex_unlock(&gNotificationMutex);
        pthread_mutex_unlock(&gMonitorLifecycleMutex);
        return false;
    }
    os_unfair_lock_lock(&gStateLock);
    gAcceptingMicIngress = true;
    os_unfair_lock_unlock(&gStateLock);
    pthread_mutex_unlock(&gMonitorLifecycleMutex);
    return true;
}

void IUSCMicDemandMonitorStop(void) {
    pthread_mutex_lock(&gMonitorLifecycleMutex);

    uint8_t stopPacket[IUSC_MIC_HEADER_BYTES] = {};
    size_t stopLength = 0;
    pthread_mutex_lock(&gIngressMutex);
    os_unfair_lock_lock(&gStateLock);
    /* Reject every later RFB packet in the same critical section as retire. */
    gAcceptingMicIngress = false;
    stopLength = retireOwnedStreamLocked(0, stopPacket);
    os_unfair_lock_unlock(&gStateLock);
    if (stopLength != 0) {
        forwardDatagram(stopPacket, stopLength);
    }
    pthread_mutex_unlock(&gIngressMutex);

    const bool wasRunning = gDemandThreadRunning.exchange(
        false, std::memory_order_acq_rel);
    pthread_mutex_lock(&gNotificationMutex);
    os_unfair_lock_lock(&gStateLock);
    gDemandScreen = nullptr;
    gPublishedDemandCount = 0;
    ++gPublishedDemandRevision;
    if (gPublishedDemandRevision == 0) ++gPublishedDemandRevision;
    memset(gCapabilities, 0, sizeof(gCapabilities));
    os_unfair_lock_unlock(&gStateLock);
    pthread_mutex_unlock(&gNotificationMutex);

    const int ownedConnection = gDemandConnection.exchange(
        -1, std::memory_order_acq_rel);
    if (ownedConnection >= 0) {
        (void)shutdown(ownedConnection, SHUT_RDWR);
    }
    if (wasRunning) {
        const timespec deadline = realtimeDeadlineAfter(kDemandStopTimeoutNS);
        pthread_mutex_lock(&gMonitorExitMutex);
        int waitResult = 0;
        while (!gDemandThreadExited && waitResult == 0) {
            waitResult = pthread_cond_timedwait(
                &gMonitorExitCondition, &gMonitorExitMutex, &deadline);
        }
        const bool exited = gDemandThreadExited;
        pthread_mutex_unlock(&gMonitorExitMutex);
        if (!exited) {
            pthread_mutex_unlock(&gMonitorLifecycleMutex);
            _exit(79);
        }
        if (pthread_join(gDemandThread, nullptr) != 0) {
            pthread_mutex_unlock(&gMonitorLifecycleMutex);
            _exit(79);
        }
        gDemandThread = {};
    }
    if (ownedConnection >= 0) {
        close(ownedConnection);
    }
    pthread_mutex_unlock(&gMonitorLifecycleMutex);
}
