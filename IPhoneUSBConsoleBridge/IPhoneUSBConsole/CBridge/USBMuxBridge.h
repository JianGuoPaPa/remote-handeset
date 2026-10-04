#ifndef IPhoneUSBConsole_USBMuxBridge_h
#define IPhoneUSBConsole_USBMuxBridge_h

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    IUSCUSBMuxSuccess = 0,
    IUSCUSBMuxInvalidArgument = -1000,
    IUSCUSBMuxNoUSBDevice = -1001,
    IUSCUSBMuxDaemonUnavailable = -1002,
    IUSCUSBMuxConnectionFailed = -1003,
    IUSCUSBMuxUnexpectedTransport = -1004,
    IUSCUSBMuxSocketSetupFailed = -1005,
    IUSCUSBMuxTargetNotConnected = -1006,
    IUSCVNCCryptoFailed = -1100,
    IUSCPasswordDerivationFailed = -1101
};

/// Opens a usbmuxd proxy socket to `devicePort` on the USB device whose UDID
/// exactly matches `targetUDID`. Network-discovered devices are excluded.
int32_t IUSCUSBMuxConnectDevice(
    const char *targetUDID,
    uint16_t devicePort,
    int32_t *outSocketFD
);

/// Reports the number of physically attached USB devices and whether the
/// configured target is among them. No device identifiers are copied out.
int32_t IUSCUSBMuxInspectUSBDevices(
    const char *targetUDID,
    uint32_t *outUSBDeviceCount,
    int32_t *outTargetConnected
);

/// Half-closes both directions without releasing the descriptor. This is used
/// to wake a thread blocked in poll/read/write before the owner closes it.
int32_t IUSCUSBMuxShutdown(int32_t socketFD);

/// Releases a descriptor returned by IUSCUSBMuxConnectDevice.
int32_t IUSCUSBMuxDisconnect(int32_t socketFD);

/// Clears sensitive temporary storage using a non-optimizable system routine.
void IUSCSecureZeroBuffer(void *buffer, size_t length);

/// Computes the 16-byte Classic VNCAuth challenge response. VNCAuth uses the
/// first eight password bytes as a DES key after reversing each byte's bits.
int32_t IUSCEncryptVNCChallenge(
    const uint8_t challenge[16],
    const uint8_t *passwordBytes,
    size_t passwordLength,
    uint8_t response[16]
);

/// Derives key material using PBKDF2-HMAC-SHA256. All lengths are explicit so
/// passwords are never treated as NUL-terminated strings.
int32_t IUSCDerivePBKDF2SHA256(
    const uint8_t *passwordBytes,
    size_t passwordLength,
    const uint8_t *saltBytes,
    size_t saltLength,
    uint32_t rounds,
    uint8_t *derivedBytes,
    size_t derivedLength
);

/// Constant-time byte comparison for password-verifier material.
int32_t IUSCConstantTimeEqual(
    const uint8_t *leftBytes,
    const uint8_t *rightBytes,
    size_t length
);

#ifdef __cplusplus
}
#endif

#endif /* IPhoneUSBConsole_USBMuxBridge_h */
