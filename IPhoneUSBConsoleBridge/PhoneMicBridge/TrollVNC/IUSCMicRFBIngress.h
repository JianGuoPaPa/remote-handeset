#ifndef IUSC_MIC_RFB_INGRESS_H
#define IUSC_MIC_RFB_INGRESS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Returns true for every reserved IUMC or IUMH envelope, including malformed
 * or unauthorized ones, so binary protocol data can never reach UIPasteboard.
 */
bool IUSCMicHandleRFBEnvelope(const uint8_t *bytes,
                              size_t length,
                              uintptr_t clientCookie,
                              bool viewOnly);

/* Emits STOP if the disconnected RFB client owns the active mic stream. */
void IUSCMicRFBClientDisconnected(uintptr_t clientCookie);

/*
 * Subscribe to the local daemon's persistent demand snapshot channel. The
 * opaque pointer must be the live rfbScreenInfoPtr and remains owned by
 * TrollVNC. Stop must complete before rfbScreenCleanup.
 */
bool IUSCMicDemandMonitorStart(void *rfbScreen);
void IUSCMicDemandMonitorStop(void);

#ifdef __cplusplus
}
#endif

#endif /* IUSC_MIC_RFB_INGRESS_H */
