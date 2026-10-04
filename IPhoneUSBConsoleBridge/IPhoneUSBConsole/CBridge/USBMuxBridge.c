#define __STDC_WANT_LIB_EXT1__ 1

#include "USBMuxBridge.h"

#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonKeyDerivation.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include <usbmuxd.h>

static uint8_t IUSCReverseBits(uint8_t value) {
    value = (uint8_t)(((value & 0xAAu) >> 1u) | ((value & 0x55u) << 1u));
    value = (uint8_t)(((value & 0xCCu) >> 2u) | ((value & 0x33u) << 2u));
    return (uint8_t)((value >> 4u) | (value << 4u));
}

void IUSCSecureZeroBuffer(void *buffer, size_t length) {
    if (buffer == NULL || length == 0) {
        return;
    }
#if defined(__APPLE__)
    memset_s(buffer, length, 0, length);
#else
    volatile uint8_t *bytes = (volatile uint8_t *)buffer;
    while (length-- > 0) {
        *bytes++ = 0;
    }
#endif
}

int32_t IUSCUSBMuxConnectDevice(
    const char *targetUDID,
    uint16_t devicePort,
    int32_t *outSocketFD
) {
    if (targetUDID == NULL || targetUDID[0] == '\0' ||
        devicePort == 0 || outSocketFD == NULL) {
        return IUSCUSBMuxInvalidArgument;
    }
    *outSocketFD = -1;

    usbmuxd_device_info_t device;
    memset(&device, 0, sizeof(device));

    const int lookupResult = usbmuxd_get_device(
        targetUDID,
        &device,
        DEVICE_LOOKUP_USBMUX
    );
    if (lookupResult == 0) {
        return IUSCUSBMuxTargetNotConnected;
    }
    if (lookupResult < 0) {
        return IUSCUSBMuxDaemonUnavailable;
    }
    if (device.conn_type != CONNECTION_TYPE_USB) {
        IUSCSecureZeroBuffer(&device, sizeof(device));
        return IUSCUSBMuxUnexpectedTransport;
    }

    const int socketFD = usbmuxd_connect(device.handle, devicePort);
    IUSCSecureZeroBuffer(&device, sizeof(device));
    if (socketFD < 0) {
        return IUSCUSBMuxConnectionFailed;
    }

    const int currentFlags = fcntl(socketFD, F_GETFL, 0);
    if (currentFlags < 0 || fcntl(socketFD, F_SETFL, currentFlags | O_NONBLOCK) < 0) {
        usbmuxd_disconnect(socketFD);
        return IUSCUSBMuxSocketSetupFailed;
    }

    int noSigPipe = 1;
    if (setsockopt(
            socketFD,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            (socklen_t)sizeof(noSigPipe)
        ) != 0) {
        usbmuxd_disconnect(socketFD);
        return IUSCUSBMuxSocketSetupFailed;
    }

    *outSocketFD = (int32_t)socketFD;
    return IUSCUSBMuxSuccess;
}

int32_t IUSCUSBMuxInspectUSBDevices(
    const char *targetUDID,
    uint32_t *outUSBDeviceCount,
    int32_t *outTargetConnected
) {
    if (targetUDID == NULL || targetUDID[0] == '\0' ||
        outUSBDeviceCount == NULL || outTargetConnected == NULL) {
        return IUSCUSBMuxInvalidArgument;
    }

    *outUSBDeviceCount = 0;
    *outTargetConnected = 0;

    usbmuxd_device_info_t *deviceList = NULL;
    const int result = usbmuxd_get_device_list(&deviceList);
    if (result < 0) {
        return IUSCUSBMuxDaemonUnavailable;
    }
    if (deviceList == NULL) {
        return IUSCUSBMuxNoUSBDevice;
    }

    uint32_t count = 0;
    int32_t targetConnected = 0;
    for (int index = 0; index < result; index++) {
        const usbmuxd_device_info_t *device = &deviceList[index];
        if (device->conn_type != CONNECTION_TYPE_USB) {
            continue;
        }
        count += 1;
        if (strncmp(device->udid, targetUDID, sizeof(device->udid)) == 0) {
            targetConnected = 1;
        }
    }
    usbmuxd_device_list_free(&deviceList);

    *outUSBDeviceCount = count;
    *outTargetConnected = targetConnected;
    return IUSCUSBMuxSuccess;
}

int32_t IUSCUSBMuxShutdown(int32_t socketFD) {
    if (socketFD < 0) {
        return IUSCUSBMuxInvalidArgument;
    }
    if (shutdown(socketFD, SHUT_RDWR) == 0 || errno == ENOTCONN || errno == EINVAL) {
        return IUSCUSBMuxSuccess;
    }
    return -errno;
}

int32_t IUSCUSBMuxDisconnect(int32_t socketFD) {
    if (socketFD < 0) {
        return IUSCUSBMuxInvalidArgument;
    }
    return (int32_t)usbmuxd_disconnect(socketFD);
}

int32_t IUSCEncryptVNCChallenge(
    const uint8_t challenge[16],
    const uint8_t *passwordBytes,
    size_t passwordLength,
    uint8_t response[16]
) {
    if (challenge == NULL || response == NULL ||
        (passwordLength > 0 && passwordBytes == NULL)) {
        return IUSCUSBMuxInvalidArgument;
    }

    uint8_t key[kCCKeySizeDES] = {0};
    const size_t bytesToUse = passwordLength < sizeof(key) ? passwordLength : sizeof(key);
    for (size_t index = 0; index < bytesToUse; index++) {
        key[index] = IUSCReverseBits(passwordBytes[index]);
    }

    size_t bytesMoved = 0;
    const CCCryptorStatus status = CCCrypt(
        kCCEncrypt,
        kCCAlgorithmDES,
        kCCOptionECBMode,
        key,
        sizeof(key),
        NULL,
        challenge,
        16,
        response,
        16,
        &bytesMoved
    );
    IUSCSecureZeroBuffer(key, sizeof(key));

    if (status != kCCSuccess || bytesMoved != 16) {
        IUSCSecureZeroBuffer(response, 16);
        return IUSCVNCCryptoFailed;
    }
    return IUSCUSBMuxSuccess;
}

int32_t IUSCDerivePBKDF2SHA256(
    const uint8_t *passwordBytes,
    size_t passwordLength,
    const uint8_t *saltBytes,
    size_t saltLength,
    uint32_t rounds,
    uint8_t *derivedBytes,
    size_t derivedLength
) {
    if ((passwordLength > 0 && passwordBytes == NULL) ||
        (saltLength > 0 && saltBytes == NULL) ||
        rounds == 0 || derivedBytes == NULL || derivedLength == 0) {
        return IUSCUSBMuxInvalidArgument;
    }

    const int status = CCKeyDerivationPBKDF(
        kCCPBKDF2,
        (const char *)passwordBytes,
        passwordLength,
        saltBytes,
        saltLength,
        kCCPRFHmacAlgSHA256,
        rounds,
        derivedBytes,
        derivedLength
    );
    if (status != kCCSuccess) {
        IUSCSecureZeroBuffer(derivedBytes, derivedLength);
        return IUSCPasswordDerivationFailed;
    }
    return IUSCUSBMuxSuccess;
}

int32_t IUSCConstantTimeEqual(
    const uint8_t *leftBytes,
    const uint8_t *rightBytes,
    size_t length
) {
    if ((length > 0 && (leftBytes == NULL || rightBytes == NULL))) {
        return 0;
    }

    uint8_t difference = 0;
    for (size_t index = 0; index < length; index++) {
        difference |= (uint8_t)(leftBytes[index] ^ rightBytes[index]);
    }
    return difference == 0 ? 1 : 0;
}
