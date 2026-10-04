#ifndef IUSC_MIC_SECRET_H
#define IUSC_MIC_SECRET_H

#include <stdint.h>

/* Per-deployment consumer authentication key. Never transmit it on RFB. */
static const uint8_t kIUSCMicConsumerSecret[32] = {0};

#endif /* IUSC_MIC_SECRET_H */
