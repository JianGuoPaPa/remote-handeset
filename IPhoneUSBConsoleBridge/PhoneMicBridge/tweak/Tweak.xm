#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <substrate.h>

#include <atomic>
#include <algorithm>
#include <climits>
#include <cstdlib>
#include <cstring>
#include <sched.h>
#include <string.h>
#include <unistd.h>

#include "MicStream.h"
#include "MicStreamClient.h"

@class IUSCMicSynchronizerSentinel;
@class IUSCMicCaptureSessionObserver;
@class IUSCMicCaptureConnectionAssociation;
@class IUSCMicCaptureSessionConfigurationSentinel;
@class IUSCMicCaptureConnectionOperation;
@class IUSCMicCaptureOutputSentinel;
@class IUSCMicCaptureDelegateSentinel;

@interface IUSCMicCaptureCursorBox : NSObject {
@public
    IUSCMicReadCursor cursor;
    std::atomic<bool> demandActive;
    std::atomic<bool> retired;
    std::atomic_flag cursorBusy;
    uint64_t synchronizerBindingGeneration;
    uint64_t directBindingGeneration;
    uintptr_t directOutputSentinelIdentity;
    uintptr_t callbackIdentity;
    uintptr_t outputIdentity;
    __weak id _callbackObject;
    __weak id _output;
    __weak IUSCMicCaptureDelegateSentinel *_delegateSentinel;
}
@property(nonatomic, weak) id callbackObject;
@property(nonatomic, weak) id output;
@property(nonatomic, weak) IUSCMicCaptureDelegateSentinel *delegateSentinel;
@end

@interface IUSCMicCaptureDelegateSentinel : NSObject {
@public
    os_unfair_lock bindingLock;
    uintptr_t callbackIdentity;
    __weak IUSCMicSynchronizerSentinel *synchronizerSentinels[64];
}
@property(nonatomic, strong) NSMutableSet *directBindings;
- (BOOL)trackDirectBinding:(IUSCMicCaptureCursorBox *)binding
             callbackObject:(id)callbackObject;
- (void)untrackDirectBinding:(IUSCMicCaptureCursorBox *)binding;
- (BOOL)trackSynchronizerSentinel:(IUSCMicSynchronizerSentinel *)sentinel;
@end

@interface IUSCMicCaptureOutputSentinel : NSObject {
@public
    os_unfair_lock stateLock;
    bool lifecycleKnown;
    bool lifecycleActive;
    uint64_t lifecycleRevision;
    uintptr_t lifecycleSessionIdentity;
    uintptr_t lifecycleObserverIdentity;
    uint64_t lifecycleOutputEpoch;
    uintptr_t outputIdentity;
    uint32_t delegateSetterInFlight;
    uint64_t delegateCompletionRevision;
    uint64_t delegateTransactionGeneration;
    uint64_t delegateBindingGenerationCounter;
    uint64_t pendingBindingGeneration;
    uint64_t activeBindingGeneration;
    uintptr_t delegateIdentity;
    uintptr_t delegateQueueIdentity;
    bool delegateTransactionUnsafe;
    std::atomic<bool> delegateDrainPermanentlyUnsafe;
    __strong dispatch_group_t delegateDrainGroup;
    __strong dispatch_queue_t delegateQueue;
}
@property(nonatomic, weak) AVCaptureAudioDataOutput *output;
@property(nonatomic, weak) id delegate;
@property(nonatomic, strong) IUSCMicCaptureCursorBox *currentBinding;
@end

@interface IUSCMicCaptureSessionOutputOwnership : NSObject
@property(nonatomic, weak) IUSCMicCaptureSessionObserver *observer;
@property(nonatomic, weak) AVCaptureSession *session;
@property(nonatomic, assign) uintptr_t observerIdentity;
@property(nonatomic, assign) uintptr_t sessionIdentity;
@property(nonatomic, assign) uint64_t epoch;
@end

@interface IUSCMicCaptureConnectionAssociation : NSObject {
@public
    std::atomic<bool> retired;
    std::atomic<uint32_t> inFlightOperations;
    uint64_t completionRevision;
}
@property(nonatomic, weak) AVCaptureConnection *connection;
@property(nonatomic, weak) AVCaptureSession *session;
@property(nonatomic, weak) AVCaptureAudioDataOutput *output;
@property(nonatomic, weak) IUSCMicCaptureSessionObserver *observer;
@property(nonatomic, assign) uintptr_t connectionIdentity;
@property(nonatomic, assign) uintptr_t sessionIdentity;
@property(nonatomic, assign) uintptr_t outputIdentity;
@property(nonatomic, assign) uintptr_t observerIdentity;
@property(nonatomic, assign) uint64_t outputOwnershipEpoch;
@property(nonatomic, assign) uint64_t associationEpoch;
@end

@interface IUSCMicCaptureConnectionOperation : NSObject
@property(nonatomic, weak) AVCaptureConnection *connection;
@property(nonatomic, weak) AVCaptureSession *expectedSession;
@property(nonatomic, strong) IUSCMicCaptureConnectionAssociation *association;
@property(nonatomic, assign) uintptr_t connectionIdentity;
@property(nonatomic, assign) uintptr_t expectedSessionIdentity;
@property(nonatomic, assign) uintptr_t associationIdentity;
@property(nonatomic, assign) uintptr_t outputIdentity;
@property(nonatomic, assign) uint64_t associationEpoch;
@property(nonatomic, assign) uint64_t outputOwnershipEpoch;
@property(nonatomic, assign) uint64_t completionRevision;
@property(nonatomic, assign) BOOL inFlightRegistered;
@property(nonatomic, assign) BOOL completed;
@end

@interface IUSCMicCaptureSessionConfigurationSentinel : NSObject {
@public
    NSUInteger depth;
    NSUInteger mutationDepth;
    uint64_t revision;
    bool dirty;
}
@property(nonatomic, weak) AVCaptureSession *session;
@property(nonatomic, assign) uintptr_t sessionIdentity;
@property(nonatomic, strong) NSHashTable *associations;
@end

@interface IUSCMicCaptureSessionObserver : NSObject
{
@public
    os_unfair_lock outputLock;
    __weak AVCaptureOutput *trackedOutputs[64];
    uint64_t trackedOutputEpochs[64];
    uint64_t stateRevision;
    uintptr_t ownerSessionIdentity;
}
@property(nonatomic, weak) AVCaptureSession *session;
@property(nonatomic, strong) NSArray *tokens;
- (instancetype)initWithSession:(AVCaptureSession *)session;
- (BOOL)authoritativelyClaimOutput:(AVCaptureOutput *)output
                       revisionOut:(uint64_t *)revisionOut
                         activeOut:(BOOL *)activeOut;
- (uint64_t)beginLifecycleUpdate;
- (uint64_t)beginAuthoritativeLifecycleUpdate:(BOOL *)activeOut;
- (uint64_t)beginAuthoritativeConnectionUpdateForOutput:
                (AVCaptureAudioDataOutput *)output
                                          expectedEpoch:(uint64_t)expectedEpoch
                                               activeOut:(BOOL *)activeOut;
- (uint64_t)beginAuthoritativeConvergenceIfCurrent:(uint64_t)expectedRevision
                                          activeOut:(BOOL *)activeOut;
- (uint64_t)invalidateAndUntrackOutput:(AVCaptureOutput *)output
                              activeOut:(BOOL *)activeOut
                               epochOut:(uint64_t *)epochOut;
- (BOOL)setOutput:(AVCaptureOutput *)output
    activeIfOwned:(BOOL)active
          revision:(uint64_t)revision;
- (BOOL)setOutput:(AVCaptureOutput *)output
    activeIfOwned:(BOOL)active
          revision:(uint64_t)revision
     expectedEpoch:(uint64_t)expectedEpoch;
- (void)failCloseOutputIfOwned:(AVCaptureOutput *)output
                       revision:(uint64_t)revision;
- (void)forgetTrackedOutput:(AVCaptureOutput *)output epoch:(uint64_t)epoch;
- (void)retireTrackedOutputsForRevision:(uint64_t)revision;
- (void)retireTrackedOutputs;
@end

@interface IUSCMicSynchronizerOutputMarker : NSObject {
@public
    std::atomic<bool> active;
}
@property(nonatomic, weak) AVCaptureDataOutputSynchronizer *synchronizer;
@property(nonatomic, weak) IUSCMicSynchronizerSentinel *sentinel;
@property(nonatomic, weak) AVCaptureAudioDataOutput *output;
@property(nonatomic, assign) uintptr_t synchronizerIdentity;
@property(nonatomic, assign) uintptr_t sentinelIdentity;
@property(nonatomic, assign) uintptr_t outputIdentity;
@property(nonatomic, assign) NSUInteger outputIndex;
@end

@interface IUSCMicSynchronizerSentinel : NSObject {
@public
    os_unfair_lock outputLock;
    __weak AVCaptureAudioDataOutput *audioOutputs[64];
    __weak IUSCMicSynchronizerOutputMarker *outputMarkers[64];
    __strong IUSCMicCaptureCursorBox *bindings[64];
    bool outputActive[64];
    size_t outputCount;
    uintptr_t delegateIdentity;
    uintptr_t synchronizerIdentity;
    uint32_t delegateSetterInFlight;
    uint64_t delegateCompletionRevision;
    uint64_t delegateTransactionGeneration;
    uint64_t delegateBindingGenerationCounter;
    uint64_t pendingBindingGeneration;
    uint64_t activeBindingGeneration;
    uintptr_t delegateQueueIdentity;
    bool delegateTransactionUnsafe;
    std::atomic<bool> delegateDrainPermanentlyUnsafe;
    __strong dispatch_group_t delegateDrainGroup;
    __strong dispatch_queue_t delegateQueue;
    std::atomic<uint32_t> publicationState;
}
@property(nonatomic, weak) AVCaptureDataOutputSynchronizer *synchronizer;
@property(nonatomic, weak) id delegate;
- (instancetype)initWithSynchronizer:(AVCaptureDataOutputSynchronizer *)synchronizer
                         dataOutputs:(NSArray<AVCaptureOutput *> *)dataOutputs;
- (BOOL)publishOutputMarkersForDataOutputs:
            (NSArray<AVCaptureOutput *> *)dataOutputs;
- (BOOL)isPublishedForSynchronizer:
            (AVCaptureDataOutputSynchronizer *)synchronizer;
- (BOOL)ownsOutput:(AVCaptureAudioDataOutput *)output
            marker:(IUSCMicSynchronizerOutputMarker *)marker
             index:(NSUInteger)index;
- (void)unpublishOutputMarkers;
- (void)retireAllBindings;
- (void)setOutput:(AVCaptureAudioDataOutput *)output
            marker:(IUSCMicSynchronizerOutputMarker *)marker
             index:(NSUInteger)index
            active:(BOOL)active;
- (void)retireOutputAtIndex:(NSUInteger)index
                     marker:(IUSCMicSynchronizerOutputMarker *)marker;
- (void)retireDelegateIdentity:(uintptr_t)identity;
- (IUSCMicCaptureCursorBox *)tryBindingForOutput:(AVCaptureAudioDataOutput *)output
                                  callbackObject:(id)callbackObject;
@end

@implementation IUSCMicCaptureCursorBox
@synthesize callbackObject = _callbackObject;
@synthesize output = _output;
@synthesize delegateSentinel = _delegateSentinel;

- (instancetype)init {
    self = [super init];
    if (self) {
        IUSCMicCursorReset(&cursor);
        demandActive.store(false, std::memory_order_relaxed);
        retired.store(false, std::memory_order_relaxed);
        cursorBusy.clear(std::memory_order_relaxed);
        synchronizerBindingGeneration = 0;
        directBindingGeneration = 0;
        directOutputSentinelIdentity = 0;
        callbackIdentity = 0;
        outputIdentity = 0;
    }
    return self;
}
- (void)dealloc {
    if (demandActive.exchange(false, std::memory_order_acq_rel)) {
        IUSCMicDemandRelease();
    }
}
@end

namespace {

constexpr size_t kMaximumTrackedAudioUnits = 128;
constexpr uint32_t kAudioUnitWriterBit = 0x80000000u;
constexpr uint32_t kAudioUnitReaderMask = ~kAudioUnitWriterBit;
char gCaptureSessionObserverAssociationKey;
char gCaptureDelegateSentinelAssociationKey;
char gCaptureOutputSentinelAssociationKey;
char gCaptureSessionOutputOwnershipAssociationKey;
char gCaptureConnectionAssociationKey;
char gCaptureSessionConfigurationAssociationKey;
char gCaptureSynchronizerSentinelAssociationKey;
char gCaptureSynchronizerMarkerAssociationKey;

constexpr uint32_t kSynchronizerPublicationConstructing = 0;
constexpr uint32_t kSynchronizerPublicationReady = 1;
constexpr uint32_t kSynchronizerPublicationFailed = 2;

std::atomic<bool> gCriticalCHooksReady{false};
std::atomic<uint64_t> gCaptureSessionOutputEpoch{1};
std::atomic<uint64_t> gCaptureConnectionAssociationEpoch{1};

[[noreturn]] void failStopForCriticalHookFailure() {
    _exit(78);
}

inline void requireCriticalCHooksReady() {
    if (!gCriticalCHooksReady.load(std::memory_order_acquire)) {
        failStopForCriticalHookFailure();
    }
}

uint64_t nextCaptureSessionOutputEpoch() {
    uint64_t epoch = gCaptureSessionOutputEpoch.fetch_add(
        1, std::memory_order_acq_rel);
    if (epoch == 0) {
        epoch = gCaptureSessionOutputEpoch.fetch_add(
            1, std::memory_order_acq_rel);
    }
    return epoch == 0 ? 1 : epoch;
}

uint64_t nextCaptureConnectionAssociationEpoch() {
    uint64_t epoch = gCaptureConnectionAssociationEpoch.fetch_add(
        1, std::memory_order_acq_rel);
    if (epoch == 0) {
        epoch = gCaptureConnectionAssociationEpoch.fetch_add(
            1, std::memory_order_acq_rel);
    }
    return epoch == 0 ? 1 : epoch;
}

uint64_t nextCaptureSessionStateRevision(uint64_t revision) {
    ++revision;
    return revision == 0 ? 1 : revision;
}

uintptr_t captureObjectIdentity(id object) {
    return object
        ? reinterpret_cast<uintptr_t>((__bridge void *)object) : 0;
}

struct AudioUnitContext {
    std::atomic<uintptr_t> unit;
    std::atomic<uint32_t> access;
    std::atomic<bool> inputEnabled;
    std::atomic<bool> demandActive;
    std::atomic<bool> failClosed;
    std::atomic<bool> retired;
    uint64_t operationGeneration;
    AudioStreamBasicDescription format;
    IUSCMicReadCursor cursor;
};

AudioUnitContext gAudioUnits[kMaximumTrackedAudioUnits];
os_unfair_lock gAudioUnitWriterLock = OS_UNFAIR_LOCK_INIT;

bool hasTrackedInputUnit(AudioUnit unit) {
    const uintptr_t value = reinterpret_cast<uintptr_t>(unit);
    for (size_t i = 0; i < kMaximumTrackedAudioUnits; ++i) {
        if (gAudioUnits[i].unit.load(std::memory_order_acquire) == value) {
            return true;
        }
    }
    return false;
}

/* Only configuration calls take this writer path. The render hook never waits. */
void beginContextWrite(AudioUnitContext& context) {
    (void)context.access.fetch_or(kAudioUnitWriterBit,
                                  std::memory_order_acq_rel);
    while ((context.access.load(std::memory_order_acquire) &
            kAudioUnitReaderMask) != 0) {
        sched_yield();
    }
}

void endContextWrite(AudioUnitContext& context) {
    context.access.store(0, std::memory_order_release);
}

uint64_t nextAudioUnitOperationGeneration(AudioUnitContext& context) {
    ++context.operationGeneration;
    if (context.operationGeneration == 0) {
        ++context.operationGeneration;
    }
    return context.operationGeneration;
}

void setAudioUnitDemandLocked(AudioUnitContext& context, bool active) {
    const bool previous = context.demandActive.exchange(
        active, std::memory_order_acq_rel);
    if (active && !previous) {
        IUSCMicDemandAcquire();
    } else if (!active && previous) {
        IUSCMicDemandRelease();
    }
}

bool trackInputUnit(AudioUnit unit) {
    if (!unit) return false;
    const uintptr_t value = reinterpret_cast<uintptr_t>(unit);
    os_unfair_lock_lock(&gAudioUnitWriterLock);
    AudioUnitContext *slot = nullptr;
    for (size_t i = 0; i < kMaximumTrackedAudioUnits; ++i) {
        AudioUnitContext& context = gAudioUnits[i];
        if (context.unit.load(std::memory_order_acquire) != value) continue;
        if (!context.retired.load(std::memory_order_acquire)) {
            os_unfair_lock_unlock(&gAudioUnitWriterLock);
            return true;
        }
        /* A newly-created AudioUnit may reuse a disposed instance address. */
        slot = &context;
        break;
    }
    if (!slot) {
        for (size_t i = 0; i < kMaximumTrackedAudioUnits; ++i) {
            AudioUnitContext& context = gAudioUnits[i];
            if (context.unit.load(std::memory_order_acquire) == 0) {
                slot = &context;
                break;
            }
        }
    }
    if (!slot) {
        /*
         * Retired tombstones are safe to recycle: the slot itself is static,
         * the writer path waits for its last render reader, and an old unit
         * address no longer matches after publication of the replacement.
         */
        for (size_t i = 0; i < kMaximumTrackedAudioUnits; ++i) {
            AudioUnitContext& context = gAudioUnits[i];
            if (context.retired.load(std::memory_order_acquire)) {
                slot = &context;
                break;
            }
        }
    }
    if (slot) {
        beginContextWrite(*slot);
        setAudioUnitDemandLocked(*slot, false);
        memset(&slot->format, 0, sizeof(slot->format));
        IUSCMicCursorReset(&slot->cursor);
        slot->inputEnabled.store(false, std::memory_order_relaxed);
        /* Start must succeed before physical input is ever released again. */
        slot->failClosed.store(true, std::memory_order_relaxed);
        slot->retired.store(false, std::memory_order_relaxed);
        (void)nextAudioUnitOperationGeneration(*slot);
        slot->unit.store(value, std::memory_order_release);
        endContextWrite(*slot);
    }
    os_unfair_lock_unlock(&gAudioUnitWriterLock);
    return slot != nullptr;
}

bool isConfirmedInputAudioUnit(AudioUnit unit) {
    if (!unit) return false;
    AudioComponent component = AudioComponentInstanceGetComponent(unit);
    if (!component) return false;
    AudioComponentDescription description = {};
    return AudioComponentGetDescription(component, &description) == noErr &&
        description.componentType == kAudioUnitType_Output &&
        (description.componentSubType == kAudioUnitSubType_RemoteIO ||
         description.componentSubType == kAudioUnitSubType_VoiceProcessingIO);
}

enum class AudioUnitOperationCompletion {
    StartSucceeded,
    SafeStopped,
    DisposeSucceeded,
    DisposeFailed,
    InputEnabled,
    InputDisabled,
    InputChangeFailed,
};

bool beginAudioUnitOperation(AudioUnit unit,
                             bool retiring,
                             uint64_t *generationOut) {
    const uintptr_t value = reinterpret_cast<uintptr_t>(unit);
    bool found = false;
    os_unfair_lock_lock(&gAudioUnitWriterLock);
    for (size_t i = 0; i < kMaximumTrackedAudioUnits; ++i) {
        AudioUnitContext& context = gAudioUnits[i];
        if (context.unit.load(std::memory_order_acquire) != value) continue;
        beginContextWrite(context);
        if (context.unit.load(std::memory_order_relaxed) == value &&
            !context.retired.load(std::memory_order_relaxed)) {
            const uint64_t generation =
                nextAudioUnitOperationGeneration(context);
            context.failClosed.store(true, std::memory_order_release);
            setAudioUnitDemandLocked(context, false);
            if (retiring) {
                context.retired.store(true, std::memory_order_release);
            }
            if (generationOut) *generationOut = generation;
            found = true;
        }
        endContextWrite(context);
        break;
    }
    os_unfair_lock_unlock(&gAudioUnitWriterLock);
    return found;
}

bool commitAudioUnitOperation(AudioUnit unit,
                              uint64_t generation,
                              AudioUnitOperationCompletion completion) {
    const uintptr_t value = reinterpret_cast<uintptr_t>(unit);
    bool committed = false;
    os_unfair_lock_lock(&gAudioUnitWriterLock);
    for (size_t i = 0; i < kMaximumTrackedAudioUnits; ++i) {
        AudioUnitContext& context = gAudioUnits[i];
        if (context.unit.load(std::memory_order_acquire) != value) continue;
        beginContextWrite(context);
        if (context.unit.load(std::memory_order_relaxed) == value &&
            context.operationGeneration == generation) {
            switch (completion) {
                case AudioUnitOperationCompletion::StartSucceeded:
                    if (context.inputEnabled.load(std::memory_order_relaxed) &&
                        !context.retired.load(std::memory_order_relaxed)) {
                        setAudioUnitDemandLocked(context, true);
                        context.failClosed.store(
                            false, std::memory_order_release);
                    } else {
                        setAudioUnitDemandLocked(context, false);
                        context.failClosed.store(
                            true, std::memory_order_release);
                    }
                    break;
                case AudioUnitOperationCompletion::DisposeSucceeded:
                    setAudioUnitDemandLocked(context, false);
                    context.inputEnabled.store(
                        false, std::memory_order_relaxed);
                    context.failClosed.store(true, std::memory_order_release);
                    context.retired.store(true, std::memory_order_release);
                    break;
                case AudioUnitOperationCompletion::DisposeFailed:
                    setAudioUnitDemandLocked(context, false);
                    context.failClosed.store(true, std::memory_order_release);
                    context.retired.store(false, std::memory_order_release);
                    break;
                case AudioUnitOperationCompletion::InputEnabled:
                    setAudioUnitDemandLocked(context, false);
                    context.inputEnabled.store(true, std::memory_order_relaxed);
                    context.failClosed.store(true, std::memory_order_release);
                    context.retired.store(false, std::memory_order_release);
                    break;
                case AudioUnitOperationCompletion::InputDisabled:
                    setAudioUnitDemandLocked(context, false);
                    context.inputEnabled.store(false, std::memory_order_relaxed);
                    context.failClosed.store(true, std::memory_order_release);
                    break;
                case AudioUnitOperationCompletion::InputChangeFailed:
                case AudioUnitOperationCompletion::SafeStopped:
                    setAudioUnitDemandLocked(context, false);
                    context.failClosed.store(true, std::memory_order_release);
                    break;
            }
            committed = true;
        }
        endContextWrite(context);
        break;
    }
    os_unfair_lock_unlock(&gAudioUnitWriterLock);
    return committed;
}

void recordFormat(AudioUnit unit, const AudioStreamBasicDescription& format) {
    if (!unit || format.mFormatID != kAudioFormatLinearPCM ||
        !hasTrackedInputUnit(unit)) return;
    IUSCMicStreamClientStart();
    const uintptr_t value = reinterpret_cast<uintptr_t>(unit);
    os_unfair_lock_lock(&gAudioUnitWriterLock);
    for (size_t i = 0; i < kMaximumTrackedAudioUnits; ++i) {
        AudioUnitContext& context = gAudioUnits[i];
        if (context.unit.load(std::memory_order_acquire) != value) continue;
        beginContextWrite(context);
        if (context.unit.load(std::memory_order_relaxed) == value) {
            context.format = format;
        }
        endContextWrite(context);
        break;
    }
    os_unfair_lock_unlock(&gAudioUnitWriterLock);
}

AudioUnitContext *acquireAudioUnitContext(AudioUnit unit) {
    const uintptr_t value = reinterpret_cast<uintptr_t>(unit);
    for (size_t i = 0; i < kMaximumTrackedAudioUnits; ++i) {
        AudioUnitContext& context = gAudioUnits[i];
        if (context.unit.load(std::memory_order_acquire) != value) continue;
        uint32_t access = 0;
        /*
         * One render callback owns a context cursor at a time. This is a
         * nonblocking try-acquire; a concurrent callback takes the fail-closed
         * fallback path instead of racing or waiting on the real-time thread.
         */
        if (context.access.compare_exchange_strong(
                access, 1u, std::memory_order_acquire,
                std::memory_order_relaxed)) {
            if (context.unit.load(std::memory_order_acquire) == value) {
                return &context;
            }
            (void)context.access.fetch_sub(1u, std::memory_order_release);
        }
    }
    return nullptr;
}

void releaseAudioUnitContext(AudioUnitContext *context) {
    if (context) {
        (void)context->access.fetch_sub(1u, std::memory_order_release);
    }
}

void zeroAudioBufferList(AudioBufferList *buffers) {
    if (!buffers) return;
    for (UInt32 i = 0; i < buffers->mNumberBuffers; ++i) {
        AudioBuffer& buffer = buffers->mBuffers[i];
        if (buffer.mData && buffer.mDataByteSize > 0) {
            memset(buffer.mData, 0, buffer.mDataByteSize);
        }
    }
}

OSStatus (*originalAudioComponentInstanceNew)(AudioComponent, AudioComponentInstance *) = nullptr;
OSStatus (*originalAudioComponentInstanceDispose)(AudioComponentInstance) = nullptr;
OSStatus (*originalAudioUnitSetProperty)(AudioUnit, AudioUnitPropertyID,
                                         AudioUnitScope, AudioUnitElement,
                                         const void *, UInt32) = nullptr;
OSStatus (*originalAudioUnitRender)(AudioUnit, AudioUnitRenderActionFlags *,
                                    const AudioTimeStamp *, UInt32, UInt32,
                                    AudioBufferList *) = nullptr;
OSStatus (*originalAudioOutputUnitStart)(AudioUnit) = nullptr;
OSStatus (*originalAudioOutputUnitStop)(AudioUnit) = nullptr;

OSStatus replacementAudioComponentInstanceNew(AudioComponent component,
                                               AudioComponentInstance *instance) {
    requireCriticalCHooksReady();
    const OSStatus status = originalAudioComponentInstanceNew(component, instance);
    if (status == noErr && instance && *instance) {
        AudioComponentDescription description = {};
        if (AudioComponentGetDescription(component, &description) == noErr &&
            description.componentType == kAudioUnitType_Output &&
            (description.componentSubType == kAudioUnitSubType_RemoteIO ||
             description.componentSubType == kAudioUnitSubType_VoiceProcessingIO)) {
            if (!trackInputUnit(*instance)) {
                (void)originalAudioComponentInstanceDispose(*instance);
                *instance = nullptr;
                return kAudio_MemFullError;
            }
        }
    }
    return status;
}

OSStatus replacementAudioComponentInstanceDispose(AudioComponentInstance instance) {
    requireCriticalCHooksReady();
    uint64_t generation = 0;
    const bool tracked = beginAudioUnitOperation(
        instance, true, &generation);
    const OSStatus status = originalAudioComponentInstanceDispose(instance);
    if (tracked) {
        (void)commitAudioUnitOperation(
            instance, generation,
            status == noErr
                ? AudioUnitOperationCompletion::DisposeSucceeded
                : AudioUnitOperationCompletion::DisposeFailed);
    }
    return status;
}

OSStatus replacementAudioOutputUnitStart(AudioUnit unit) {
    requireCriticalCHooksReady();
    IUSCMicStreamClientStart();
    uint64_t generation = 0;
    const bool tracked = beginAudioUnitOperation(unit, false, &generation);
    if (!tracked && hasTrackedInputUnit(unit)) {
        return kAudioUnitErr_Uninitialized;
    }
    const OSStatus status = originalAudioOutputUnitStart(unit);
    if (tracked) {
        (void)commitAudioUnitOperation(
            unit, generation,
            status == noErr
                ? AudioUnitOperationCompletion::StartSucceeded
                : AudioUnitOperationCompletion::SafeStopped);
    }
    return status;
}

OSStatus replacementAudioOutputUnitStop(AudioUnit unit) {
    requireCriticalCHooksReady();
    uint64_t generation = 0;
    const bool tracked = beginAudioUnitOperation(unit, false, &generation);
    const OSStatus status = originalAudioOutputUnitStop(unit);
    if (tracked) {
        (void)commitAudioUnitOperation(
            unit, generation, AudioUnitOperationCompletion::SafeStopped);
    }
    return status;
}

OSStatus replacementAudioUnitSetProperty(AudioUnit unit,
                                         AudioUnitPropertyID property,
                                         AudioUnitScope scope,
                                         AudioUnitElement element,
                                         const void *data,
                                         UInt32 dataSize) {
    requireCriticalCHooksReady();
    const bool changesInputEnable =
        property == kAudioOutputUnitProperty_EnableIO &&
        scope == kAudioUnitScope_Input && element == 1;
    const bool hasInputEnableValue = changesInputEnable && data &&
        dataSize >= sizeof(UInt32);
    const bool requestedEnabled = hasInputEnableValue &&
        *(const UInt32 *)data != 0;
    if (changesInputEnable && requestedEnabled &&
        !hasTrackedInputUnit(unit) && isConfirmedInputAudioUnit(unit) &&
        !trackInputUnit(unit)) {
        return kAudio_MemFullError;
    }
    uint64_t operationGeneration = 0;
    const bool trackedOperation = changesInputEnable &&
        beginAudioUnitOperation(unit, false, &operationGeneration);
    const OSStatus status = originalAudioUnitSetProperty(
        unit, property, scope, element, data, dataSize);
    if (changesInputEnable && trackedOperation) {
        (void)commitAudioUnitOperation(
            unit, operationGeneration,
            status != noErr || !hasInputEnableValue
                ? AudioUnitOperationCompletion::InputChangeFailed
                : (requestedEnabled
                    ? AudioUnitOperationCompletion::InputEnabled
                    : AudioUnitOperationCompletion::InputDisabled));
    }
    if (status != noErr || !data) return status;

    if (changesInputEnable) {
        if (requestedEnabled) {
            IUSCMicStreamClientStart();
        }
    }
    if (property == kAudioUnitProperty_StreamFormat &&
        scope == kAudioUnitScope_Output && element == 1 &&
        dataSize >= sizeof(AudioStreamBasicDescription)) {
        recordFormat(unit, *(const AudioStreamBasicDescription *)data);
    }
    return status;
}

OSStatus replacementAudioUnitRender(AudioUnit unit,
                                    AudioUnitRenderActionFlags *flags,
                                    const AudioTimeStamp *timestamp,
                                    UInt32 outputBus,
                                    UInt32 frameCount,
                                    AudioBufferList *buffers) {
    requireCriticalCHooksReady();
    const OSStatus status = originalAudioUnitRender(
        unit, flags, timestamp, outputBus, frameCount, buffers);
    if (status != noErr) {
        /* An error may leave a partially filled target; never expose it. */
        zeroAudioBufferList(buffers);
        return status;
    }
    if (outputBus != 1 || frameCount == 0 || !buffers) {
        return status;
    }
    if (!hasTrackedInputUnit(unit)) {
        /* Bus 1 may be microphone input even when introspection fails. */
        zeroAudioBufferList(buffers);
        return status;
    }
    if (AudioUnitContext *context = acquireAudioUnitContext(unit)) {
        if (context->retired.load(std::memory_order_acquire) ||
            context->failClosed.load(std::memory_order_acquire)) {
            zeroAudioBufferList(buffers);
        } else if (context->demandActive.load(std::memory_order_acquire)) {
            (void)IUSCMicFillAudioBufferList(
                buffers, frameCount, &context->format, &context->cursor);
        }
        releaseAudioUnitContext(context);
    } else {
        /* A configuration/retirement race must fail closed, never pass mic. */
        zeroAudioBufferList(buffers);
    }
    return status;
}

struct AudioQueueContext {
    AudioQueueInputCallback callback;
    void *userData;
    AudioStreamBasicDescription format;
    IUSCMicReadCursor cursor;
    AudioQueueRef queue;
    std::atomic<uint32_t> generation;
    /* High bit closes the gate; low bits are live callback/lifecycle leases. */
    std::atomic<uint32_t> leaseGate;
    std::atomic<bool> allocated;
    std::atomic<bool> demandActive;
    std::atomic<bool> running;
    std::atomic<bool> retired;
    std::atomic<bool> disposed;
    std::atomic<bool> resetting;
    std::atomic<bool> cursorResetPending;
    std::atomic_flag cursorBusy = ATOMIC_FLAG_INIT;
};

constexpr size_t kMaximumTrackedAudioQueues = 256;
constexpr uint32_t kAudioQueueLeaseGateClosed = 0x80000000u;
constexpr uint32_t kAudioQueueLeaseCountMask =
    ~kAudioQueueLeaseGateClosed;
constexpr unsigned kAudioQueueTokenIndexBits = 8;
constexpr uintptr_t kAudioQueueTokenIndexMask =
    (1u << kAudioQueueTokenIndexBits) - 1u;
constexpr uint64_t kAudioQueueInitialReclaimDelayNS = 1000000000ull;
constexpr uint64_t kAudioQueueReclaimRetryDelayNS = 100000000ull;
os_unfair_lock gAudioQueueLock = OS_UNFAIR_LOCK_INIT;
AudioQueueContext gAudioQueues[kMaximumTrackedAudioQueues];

OSStatus (*originalAudioQueueNewInput)(const AudioStreamBasicDescription *,
                                      AudioQueueInputCallback, void *,
                                      CFRunLoopRef, CFStringRef, UInt32,
                                      AudioQueueRef *) = nullptr;
OSStatus (*originalAudioQueueDispose)(AudioQueueRef, Boolean) = nullptr;
OSStatus (*originalAudioQueueStart)(AudioQueueRef, const AudioTimeStamp *) = nullptr;
OSStatus (*originalAudioQueueStop)(AudioQueueRef, Boolean) = nullptr;
OSStatus (*originalAudioQueuePause)(AudioQueueRef) = nullptr;
OSStatus (*originalAudioQueueFlush)(AudioQueueRef) = nullptr;
OSStatus (*originalAudioQueueReset)(AudioQueueRef) = nullptr;
OSStatus (*originalAudioQueuePrime)(AudioQueueRef, UInt32, UInt32 *) = nullptr;
OSStatus (*originalAudioQueueNewInputWithDispatchQueue)(
    AudioQueueRef *, const AudioStreamBasicDescription *, UInt32,
    dispatch_queue_t, AudioQueueInputCallbackBlock) = nullptr;

void zeroAudioQueueBuffer(AudioQueueBufferRef buffer) {
    if (buffer && buffer->mAudioData && buffer->mAudioDataByteSize > 0) {
        memset(buffer->mAudioData, 0, buffer->mAudioDataByteSize);
    }
}

void fillAudioQueueBuffer(AudioQueueBufferRef buffer,
                          UInt32 packetCount,
                          const AudioStreamBasicDescription& format,
                          IUSCMicReadCursor *cursor) {
    if (!buffer || !buffer->mAudioData || !cursor) {
        return;
    }
    UInt32 frameCount = 0;
    if (packetCount > 0 && format.mFramesPerPacket > 0) {
        const uint64_t frames = (uint64_t)packetCount * format.mFramesPerPacket;
        frameCount = frames > UINT32_MAX ? UINT32_MAX : (UInt32)frames;
    } else if (format.mBytesPerFrame > 0) {
        frameCount = buffer->mAudioDataByteSize / format.mBytesPerFrame;
    }
    AudioBufferList list = {};
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels =
        std::max<UInt32>(format.mChannelsPerFrame, 1u);
    list.mBuffers[0].mDataByteSize = buffer->mAudioDataByteSize;
    list.mBuffers[0].mData = buffer->mAudioData;
    (void)IUSCMicFillAudioBufferList(
        &list, frameCount, &format, cursor);
}

uint32_t nextAudioQueueGeneration(uint32_t generation) {
    generation += 1u;
    return generation == 0 ? 1u : generation;
}

void *makeAudioQueueToken(size_t index, uint32_t generation) {
    const uintptr_t raw = ((uintptr_t)generation <<
                           kAudioQueueTokenIndexBits) |
                          (uintptr_t)index;
    return reinterpret_cast<void *>(raw + 1u);
}

bool decodeAudioQueueToken(void *token,
                           size_t *indexOut,
                           uint32_t *generationOut) {
    uintptr_t raw = reinterpret_cast<uintptr_t>(token);
    if (raw == 0) return false;
    raw -= 1u;
    const size_t index = (size_t)(raw & kAudioQueueTokenIndexMask);
    const uint32_t generation =
        (uint32_t)(raw >> kAudioQueueTokenIndexBits);
    if (index >= kMaximumTrackedAudioQueues || generation == 0) return false;
    if (indexOut) *indexOut = index;
    if (generationOut) *generationOut = generation;
    return true;
}

AudioQueueContext *allocateAudioQueueContext(
    const AudioStreamBasicDescription& format,
    AudioQueueInputCallback callback,
    void *userData,
    size_t *indexOut,
    uint32_t *generationOut) {
    AudioQueueContext *result = nullptr;
    os_unfair_lock_lock(&gAudioQueueLock);
    for (size_t i = 0; i < kMaximumTrackedAudioQueues; ++i) {
        AudioQueueContext& context = gAudioQueues[i];
        if (context.allocated.load(std::memory_order_acquire)) continue;
        /* Keep stale acquirers out while the non-atomic fields are rebuilt. */
        context.leaseGate.store(kAudioQueueLeaseGateClosed,
                                std::memory_order_release);
        const uint32_t generation = nextAudioQueueGeneration(
            context.generation.load(std::memory_order_relaxed));
        context.callback = callback;
        context.userData = userData;
        context.format = format;
        context.queue = nullptr;
        IUSCMicCursorReset(&context.cursor);
        context.cursorBusy.clear(std::memory_order_relaxed);
        context.demandActive.store(false, std::memory_order_relaxed);
        context.running.store(false, std::memory_order_relaxed);
        context.retired.store(true, std::memory_order_relaxed);
        context.disposed.store(false, std::memory_order_relaxed);
        context.resetting.store(false, std::memory_order_relaxed);
        context.cursorResetPending.store(false, std::memory_order_relaxed);
        context.generation.store(generation, std::memory_order_relaxed);
        context.allocated.store(true, std::memory_order_release);
        /* Publication is complete; only now may a lease enter the slot. */
        context.leaseGate.store(0, std::memory_order_release);
        if (indexOut) *indexOut = i;
        if (generationOut) *generationOut = generation;
        result = &context;
        break;
    }
    os_unfair_lock_unlock(&gAudioQueueLock);
    return result;
}

bool releaseUnstartedAudioQueueContext(size_t index, uint32_t generation) {
    if (index >= kMaximumTrackedAudioQueues) return false;
    bool released = false;
    os_unfair_lock_lock(&gAudioQueueLock);
    AudioQueueContext& context = gAudioQueues[index];
    if (context.allocated.load(std::memory_order_acquire) &&
        context.generation.load(std::memory_order_acquire) == generation) {
        const uint32_t gate = context.leaseGate.fetch_or(
            kAudioQueueLeaseGateClosed, std::memory_order_acq_rel);
        if ((gate & kAudioQueueLeaseCountMask) == 0) {
            context.queue = nullptr;
            context.callback = nullptr;
            context.userData = nullptr;
            context.allocated.store(false, std::memory_order_release);
            released = true;
        }
    }
    os_unfair_lock_unlock(&gAudioQueueLock);
    return released;
}

bool acquireAudioQueueLease(AudioQueueContext& context, bool realTime) {
    uint32_t gate = context.leaseGate.load(std::memory_order_acquire);
    unsigned attempts = 0;
    for (;;) {
        if ((gate & kAudioQueueLeaseGateClosed) != 0 ||
            (gate & kAudioQueueLeaseCountMask) == kAudioQueueLeaseCountMask) {
            return false;
        }
        if (context.leaseGate.compare_exchange_weak(
                gate, gate + 1u, std::memory_order_acq_rel,
                std::memory_order_acquire)) {
            return true;
        }
        if (realTime && ++attempts >= 4) {
            /* Bounded silent fallback; a real-time callback never waits. */
            return false;
        }
        if (!realTime && ++attempts % 64 == 0) {
            sched_yield();
        }
    }
}

AudioQueueContext *acquireAudioQueueContext(size_t index,
                                            uint32_t generation,
                                            bool realTime) {
    if (index >= kMaximumTrackedAudioQueues || generation == 0) return nullptr;
    AudioQueueContext& context = gAudioQueues[index];
    if (!context.allocated.load(std::memory_order_acquire) ||
        context.generation.load(std::memory_order_acquire) != generation) {
        return nullptr;
    }
    if (!acquireAudioQueueLease(context, realTime)) return nullptr;
    if (!context.allocated.load(std::memory_order_acquire) ||
        context.generation.load(std::memory_order_acquire) != generation) {
        (void)context.leaseGate.fetch_sub(1u, std::memory_order_acq_rel);
        return nullptr;
    }
    return &context;
}

AudioQueueContext *acquireAudioQueueContext(void *token,
                                            bool realTime,
                                            size_t *indexOut = nullptr,
                                            uint32_t *generationOut = nullptr) {
    size_t index = 0;
    uint32_t generation = 0;
    if (!decodeAudioQueueToken(token, &index, &generation)) return nullptr;
    AudioQueueContext *context = acquireAudioQueueContext(
        index, generation, realTime);
    if (context) {
        if (indexOut) *indexOut = index;
        if (generationOut) *generationOut = generation;
    }
    return context;
}

AudioQueueContext *acquireAudioQueueContext(AudioQueueRef queue,
                                            size_t *indexOut = nullptr,
                                            uint32_t *generationOut = nullptr) {
    AudioQueueContext *result = nullptr;
    os_unfair_lock_lock(&gAudioQueueLock);
    for (size_t i = 0; i < kMaximumTrackedAudioQueues; ++i) {
        AudioQueueContext& context = gAudioQueues[i];
        if (!context.allocated.load(std::memory_order_acquire) ||
            context.queue != queue ||
            context.disposed.load(std::memory_order_acquire)) continue;
        if (!acquireAudioQueueLease(context, false)) continue;
        if (indexOut) *indexOut = i;
        if (generationOut) {
            *generationOut = context.generation.load(
                std::memory_order_acquire);
        }
        result = &context;
        break;
    }
    os_unfair_lock_unlock(&gAudioQueueLock);
    return result;
}

void releaseAudioQueueContext(AudioQueueContext *context) {
    if (context) {
        (void)context->leaseGate.fetch_sub(1u, std::memory_order_acq_rel);
    }
}

void setAudioQueueContextDemand(AudioQueueContext *context, bool active) {
    if (!context) return;
    const bool previous = context->demandActive.exchange(
        active, std::memory_order_acq_rel);
    if (active && !previous) {
        IUSCMicDemandAcquire();
    } else if (!active && previous) {
        IUSCMicDemandRelease();
    }
}

void requestAudioQueueCursorReset(AudioQueueContext *context) {
    if (!context) return;
    context->cursorResetPending.store(true, std::memory_order_release);
    if (context->cursorBusy.test_and_set(std::memory_order_acquire)) return;
    IUSCMicCursorReset(&context->cursor);
    context->cursorResetPending.store(false, std::memory_order_release);
    context->cursorBusy.clear(std::memory_order_release);
}

void scheduleAudioQueueContextReclaim(size_t index,
                                      uint32_t generation,
                                      uint64_t delayNS);

void reclaimAudioQueueContext(size_t index, uint32_t generation) {
    if (index >= kMaximumTrackedAudioQueues || generation == 0) return;
    bool retry = false;
    os_unfair_lock_lock(&gAudioQueueLock);
    AudioQueueContext& context = gAudioQueues[index];
    if (context.allocated.load(std::memory_order_acquire) &&
        context.generation.load(std::memory_order_acquire) == generation &&
        context.disposed.load(std::memory_order_acquire)) {
        /* Close admission first; callbacks already inside retain their lease. */
        const uint32_t gate = context.leaseGate.fetch_or(
            kAudioQueueLeaseGateClosed, std::memory_order_acq_rel);
        if ((gate & kAudioQueueLeaseCountMask) == 0) {
            context.queue = nullptr;
            context.callback = nullptr;
            context.userData = nullptr;
            context.allocated.store(false, std::memory_order_release);
        } else {
            retry = true;
        }
    }
    os_unfair_lock_unlock(&gAudioQueueLock);
    if (retry) {
        scheduleAudioQueueContextReclaim(
            index, generation, kAudioQueueReclaimRetryDelayNS);
    }
}

void scheduleAudioQueueContextReclaim(size_t index,
                                      uint32_t generation,
                                      uint64_t delayNS) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayNS),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            reclaimAudioQueueContext(index, generation);
        });
}

void replaceOrSilenceAudioQueueBuffer(AudioQueueContext *context,
                                      AudioQueueBufferRef buffer,
                                      UInt32 packetCount) {
    if (!context || !buffer) return;
    /* Physical input is cleared before any lifecycle state is observed. */
    zeroAudioQueueBuffer(buffer);
    if (context->retired.load(std::memory_order_acquire) ||
        context->resetting.load(std::memory_order_acquire) ||
        !context->demandActive.load(std::memory_order_acquire)) {
        return;
    }

    /* A cursor is single-owner. Contention takes a bounded silent fallback. */
    if (context->cursorBusy.test_and_set(std::memory_order_acquire)) {
        return;
    }
    if (context->cursorResetPending.exchange(
            false, std::memory_order_acq_rel)) {
        IUSCMicCursorReset(&context->cursor);
    }
    if (!context->retired.load(std::memory_order_acquire) &&
        !context->resetting.load(std::memory_order_acquire) &&
        context->demandActive.load(std::memory_order_acquire)) {
        fillAudioQueueBuffer(buffer, packetCount,
                             context->format, &context->cursor);
    }
    context->cursorBusy.clear(std::memory_order_release);
}

bool audioQueueIsRunning(AudioQueueRef queue, bool *runningOut) {
    UInt32 running = 0;
    UInt32 size = sizeof(running);
    const OSStatus status = AudioQueueGetProperty(
        queue, kAudioQueueProperty_IsRunning, &running, &size);
    if (status != noErr || size != sizeof(running)) return false;
    if (runningOut) *runningOut = running != 0;
    return true;
}

void audioQueueRunningPropertyChanged(void *userData,
                                      AudioQueueRef queue,
                                      AudioQueuePropertyID property) {
    if (property != kAudioQueueProperty_IsRunning) return;
    AudioQueueContext *context = acquireAudioQueueContext(userData, false);
    if (!context) return;
    if (!context->disposed.load(std::memory_order_acquire)) {
        bool running = false;
        if (audioQueueIsRunning(queue, &running)) {
            context->running.store(running, std::memory_order_release);
            if (!running) {
                /*
                 * This is the authoritative completion edge for
                 * AudioQueueStop(false). Until it arrives, demand remains
                 * active and every tail callback is retired/fail-closed.
                 */
                context->retired.store(true, std::memory_order_release);
                context->resetting.store(false, std::memory_order_release);
                setAudioQueueContextDemand(context, false);
                requestAudioQueueCursorReset(context);
            }
        }
    }
    releaseAudioQueueContext(context);
}

void replacementAudioQueueCallback(void *userData,
                                   AudioQueueRef queue,
                                   AudioQueueBufferRef buffer,
                                   const AudioTimeStamp *startTime,
                                   UInt32 packetCount,
                                   const AudioStreamPacketDescription *packetDescriptions) {
    requireCriticalCHooksReady();
    /* A stale/reclaimed token still clears physical bytes before being dropped. */
    zeroAudioQueueBuffer(buffer);
    AudioQueueContext *context = acquireAudioQueueContext(userData, true);
    if (!context) return;
    AudioQueueInputCallback callback = context->callback;
    void *callbackUserData = context->userData;
    replaceOrSilenceAudioQueueBuffer(context, buffer, packetCount);
    /* The application may synchronously dispose the queue from its callback. */
    releaseAudioQueueContext(context);
    if (callback) {
        callback(callbackUserData, queue, buffer, startTime,
                 packetCount, packetDescriptions);
    }
}

OSStatus replacementAudioQueueNewInput(
    const AudioStreamBasicDescription *format,
    AudioQueueInputCallback callback,
    void *userData,
    CFRunLoopRef callbackRunLoop,
    CFStringRef callbackRunLoopMode,
    UInt32 flags,
    AudioQueueRef *outQueue) {
    requireCriticalCHooksReady();
    if (!format || !callback || !outQueue) {
        return originalAudioQueueNewInput(format, callback, userData,
                                          callbackRunLoop, callbackRunLoopMode,
                                          flags, outQueue);
    }
    IUSCMicStreamClientStart();
    size_t index = 0;
    uint32_t generation = 0;
    AudioQueueContext *context = allocateAudioQueueContext(
        *format, callback, userData, &index, &generation);
    if (!context) {
        *outQueue = nullptr;
        return kAudio_MemFullError;
    }
    void *token = makeAudioQueueToken(index, generation);

    const OSStatus status = originalAudioQueueNewInput(
        format, replacementAudioQueueCallback, token,
        callbackRunLoop, callbackRunLoopMode, flags, outQueue);
    if (status != noErr || !*outQueue) {
        context->disposed.store(true, std::memory_order_release);
        if (!releaseUnstartedAudioQueueContext(index, generation)) {
            scheduleAudioQueueContextReclaim(
                index, generation, kAudioQueueReclaimRetryDelayNS);
        }
        return status != noErr ? status : kAudioQueueErr_InvalidBuffer;
    }
    context->queue = *outQueue;
    const OSStatus listenerStatus = AudioQueueAddPropertyListener(
        *outQueue, kAudioQueueProperty_IsRunning,
        audioQueueRunningPropertyChanged, token);
    if (listenerStatus != noErr) {
        context->retired.store(true, std::memory_order_release);
        context->disposed.store(true, std::memory_order_release);
        (void)originalAudioQueueDispose(*outQueue, true);
        *outQueue = nullptr;
        if (!releaseUnstartedAudioQueueContext(index, generation)) {
            scheduleAudioQueueContextReclaim(
                index, generation, kAudioQueueReclaimRetryDelayNS);
        }
        return listenerStatus;
    }
    return status;
}

OSStatus replacementAudioQueueNewInputWithDispatchQueue(
    AudioQueueRef *outQueue,
    const AudioStreamBasicDescription *format,
    UInt32 flags,
    dispatch_queue_t callbackQueue,
    AudioQueueInputCallbackBlock callback) {
    requireCriticalCHooksReady();
    if (!outQueue || !format || !callback) {
        return originalAudioQueueNewInputWithDispatchQueue(
            outQueue, format, flags, callbackQueue, callback);
    }
    IUSCMicStreamClientStart();
    size_t index = 0;
    uint32_t generation = 0;
    AudioQueueContext *context = allocateAudioQueueContext(
        *format, nullptr, nullptr, &index, &generation);
    if (!context) {
        *outQueue = nullptr;
        return kAudio_MemFullError;
    }
    AudioQueueInputCallbackBlock wrapped = ^(
        AudioQueueRef queue,
        AudioQueueBufferRef buffer,
        const AudioTimeStamp *startTime,
            UInt32 packetCount,
            const AudioStreamPacketDescription *packetDescriptions) {
            requireCriticalCHooksReady();
            /* Always clear the real AudioQueue buffer before slot lookup. */
            zeroAudioQueueBuffer(buffer);
            AudioQueueContext *callbackContext = acquireAudioQueueContext(
                index, generation, true);
            if (callbackContext) {
                replaceOrSilenceAudioQueueBuffer(
                    callbackContext, buffer, packetCount);
                releaseAudioQueueContext(callbackContext);
            }
            callback(queue, buffer, startTime, packetCount, packetDescriptions);
        };
    const OSStatus status = originalAudioQueueNewInputWithDispatchQueue(
        outQueue, format, flags, callbackQueue, wrapped);
    if (status != noErr || !outQueue || !*outQueue) {
        context->disposed.store(true, std::memory_order_release);
        if (!releaseUnstartedAudioQueueContext(index, generation)) {
            scheduleAudioQueueContextReclaim(
                index, generation, kAudioQueueReclaimRetryDelayNS);
        }
        return status != noErr ? status : kAudioQueueErr_InvalidBuffer;
    }
    context->queue = *outQueue;
    void *token = makeAudioQueueToken(index, generation);
    const OSStatus listenerStatus = AudioQueueAddPropertyListener(
        *outQueue, kAudioQueueProperty_IsRunning,
        audioQueueRunningPropertyChanged, token);
    if (listenerStatus != noErr) {
        context->retired.store(true, std::memory_order_release);
        context->disposed.store(true, std::memory_order_release);
        (void)originalAudioQueueDispose(*outQueue, true);
        *outQueue = nullptr;
        if (!releaseUnstartedAudioQueueContext(index, generation)) {
            scheduleAudioQueueContextReclaim(
                index, generation, kAudioQueueReclaimRetryDelayNS);
        }
        return listenerStatus;
    }
    return status;
}

OSStatus replacementAudioQueueDispose(AudioQueueRef queue, Boolean immediate) {
    requireCriticalCHooksReady();
    size_t index = 0;
    uint32_t generation = 0;
    AudioQueueContext *context = acquireAudioQueueContext(
        queue, &index, &generation);
    bool previousRetired = true;
    bool previousResetting = false;
    if (context) {
        previousRetired = context->retired.exchange(
            true, std::memory_order_acq_rel);
        previousResetting = context->resetting.exchange(
            true, std::memory_order_acq_rel);
    }
    const OSStatus status = originalAudioQueueDispose(queue, immediate);
    bool scheduleReclaim = false;
    if (context) {
        if (status == noErr) {
            context->running.store(false, std::memory_order_release);
            context->disposed.store(true, std::memory_order_release);
            context->resetting.store(false, std::memory_order_release);
            setAudioQueueContextDemand(context, false);
            requestAudioQueueCursorReset(context);
            scheduleReclaim = true;
        } else {
            context->retired.store(previousRetired,
                                   std::memory_order_release);
            context->resetting.store(previousResetting,
                                     std::memory_order_release);
        }
        releaseAudioQueueContext(context);
    }
    if (scheduleReclaim) {
        /*
         * The generation token makes post-quarantine callbacks stale and
         * fail-closed; the reaper never waits on an Audio Queue callback.
         */
        scheduleAudioQueueContextReclaim(
            index, generation, kAudioQueueInitialReclaimDelayNS);
    }
    return status;
}

OSStatus replacementAudioQueueStart(AudioQueueRef queue,
                                    const AudioTimeStamp *startTime) {
    requireCriticalCHooksReady();
    IUSCMicStreamClientStart();
    AudioQueueContext *context = acquireAudioQueueContext(queue);
    bool previousDemand = false;
    bool previousRetired = true;
    bool previousRunning = false;
    bool previousResetting = false;
    if (context) {
        previousDemand = context->demandActive.load(std::memory_order_acquire);
        previousRunning = context->running.load(std::memory_order_acquire);
        previousRetired = context->retired.exchange(
            true, std::memory_order_acq_rel);
        previousResetting = context->resetting.exchange(
            false, std::memory_order_acq_rel);
        requestAudioQueueCursorReset(context);
        setAudioQueueContextDemand(context, true);
    }
    const OSStatus status = originalAudioQueueStart(queue, startTime);
    if (context) {
        if (status == noErr) {
            context->running.store(true, std::memory_order_release);
            setAudioQueueContextDemand(context, true);
            context->retired.store(false, std::memory_order_release);
        } else {
            setAudioQueueContextDemand(context, previousDemand);
            context->running.store(previousRunning,
                                   std::memory_order_release);
            context->retired.store(previousRetired,
                                   std::memory_order_release);
            context->resetting.store(previousResetting,
                                     std::memory_order_release);
        }
        releaseAudioQueueContext(context);
    }
    return status;
}

OSStatus replacementAudioQueueStop(AudioQueueRef queue, Boolean immediate) {
    requireCriticalCHooksReady();
    AudioQueueContext *context = acquireAudioQueueContext(queue);
    bool previousRetired = true;
    bool previousResetting = false;
    if (context) {
        previousRetired = context->retired.exchange(
            true, std::memory_order_acq_rel);
        previousResetting = context->resetting.exchange(
            false, std::memory_order_acq_rel);
    }
    const OSStatus status = originalAudioQueueStop(queue, immediate);
    if (context) {
        if (status == noErr) {
            bool actualRunning = context->running.load(
                std::memory_order_acquire);
            const bool hasActualState = immediate ||
                audioQueueIsRunning(queue, &actualRunning);
            if (immediate || (hasActualState && !actualRunning) ||
                (!hasActualState &&
                 !context->running.load(std::memory_order_acquire))) {
                context->running.store(false, std::memory_order_release);
                setAudioQueueContextDemand(context, false);
                requestAudioQueueCursorReset(context);
            }
            /* For Stop(false), IsRunning=0 releases demand asynchronously. */
        } else {
            context->retired.store(previousRetired,
                                   std::memory_order_release);
            context->resetting.store(previousResetting,
                                     std::memory_order_release);
        }
        releaseAudioQueueContext(context);
    }
    return status;
}

OSStatus replacementAudioQueuePause(AudioQueueRef queue) {
    requireCriticalCHooksReady();
    AudioQueueContext *context = acquireAudioQueueContext(queue);
    bool previousRetired = true;
    bool previousResetting = false;
    if (context) {
        previousRetired = context->retired.exchange(
            true, std::memory_order_acq_rel);
        previousResetting = context->resetting.exchange(
            false, std::memory_order_acq_rel);
    }
    const OSStatus status = originalAudioQueuePause(queue);
    if (context) {
        if (status == noErr) {
            context->running.store(false, std::memory_order_release);
            setAudioQueueContextDemand(context, false);
            requestAudioQueueCursorReset(context);
        } else {
            context->retired.store(previousRetired,
                                   std::memory_order_release);
            context->resetting.store(previousResetting,
                                     std::memory_order_release);
        }
        releaseAudioQueueContext(context);
    }
    return status;
}

OSStatus replacementAudioQueueReset(AudioQueueRef queue) {
    requireCriticalCHooksReady();
    AudioQueueContext *context = acquireAudioQueueContext(queue);
    bool previousRetired = true;
    bool previousDemand = false;
    bool previousRunning = false;
    bool previousResetting = false;
    if (context) {
        previousRetired = context->retired.load(std::memory_order_acquire);
        previousDemand = context->demandActive.load(std::memory_order_acquire);
        previousRunning = context->running.load(std::memory_order_acquire);
        previousResetting = context->resetting.exchange(
            true, std::memory_order_acq_rel);
    }
    const OSStatus status = originalAudioQueueReset(queue);
    if (context) {
        requestAudioQueueCursorReset(context);
        if (status == noErr) {
            bool actualRunning = previousRunning;
            const bool hasActualState = audioQueueIsRunning(
                queue, &actualRunning);
            if (hasActualState && !actualRunning) {
                /* Only an actual IsRunning=0 edge has stop semantics. */
                context->running.store(false, std::memory_order_release);
                context->retired.store(true, std::memory_order_release);
                setAudioQueueContextDemand(context, false);
            } else {
                context->running.store(
                    hasActualState ? actualRunning : previousRunning,
                    std::memory_order_release);
                context->retired.store(previousRetired,
                                       std::memory_order_release);
                setAudioQueueContextDemand(context, previousDemand);
            }
        } else {
            context->running.store(previousRunning,
                                   std::memory_order_release);
            context->retired.store(previousRetired,
                                   std::memory_order_release);
            setAudioQueueContextDemand(context, previousDemand);
        }
        context->resetting.store(previousResetting,
                                 std::memory_order_release);
        releaseAudioQueueContext(context);
    }
    return status;
}

OSStatus replacementAudioQueuePrime(AudioQueueRef queue,
                                    UInt32 framesToPrepare,
                                    UInt32 *framesPrepared) {
    requireCriticalCHooksReady();
    /* Prime is playback-only and must never create microphone demand. */
    return originalAudioQueuePrime(queue, framesToPrepare, framesPrepared);
}

OSStatus replacementAudioQueueFlush(AudioQueueRef queue) {
    requireCriticalCHooksReady();
    /* Flush preserves the running/paused state; callbacks remain guarded. */
    return originalAudioQueueFlush(queue);
}

NSMutableSet *gHookedDelegateClasses;
NSMutableSet *gHookedSynchronizerDelegateClasses;

IUSCMicCaptureDelegateSentinel *ensureCaptureDelegateSentinel(id object) {
    if (!object) return nil;
    IUSCMicCaptureDelegateSentinel *sentinel = objc_getAssociatedObject(
        object, &gCaptureDelegateSentinelAssociationKey);
    if (sentinel) return sentinel;
    @synchronized(object) {
        sentinel = objc_getAssociatedObject(
            object, &gCaptureDelegateSentinelAssociationKey);
        if (!sentinel) {
            sentinel = [IUSCMicCaptureDelegateSentinel new];
            sentinel->callbackIdentity =
                reinterpret_cast<uintptr_t>((__bridge void *)object);
            objc_setAssociatedObject(
                object, &gCaptureDelegateSentinelAssociationKey, sentinel,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return sentinel;
}

IUSCMicCaptureOutputSentinel *ensureCaptureOutputSentinel(
    AVCaptureAudioDataOutput *output) {
    if (!output) return nil;
    IUSCMicCaptureOutputSentinel *sentinel = objc_getAssociatedObject(
        output, &gCaptureOutputSentinelAssociationKey);
    if (sentinel) return sentinel;
    @synchronized(output) {
        sentinel = objc_getAssociatedObject(
            output, &gCaptureOutputSentinelAssociationKey);
        if (!sentinel) {
            sentinel = [IUSCMicCaptureOutputSentinel new];
            sentinel.output = output;
            sentinel->outputIdentity = captureObjectIdentity(output);
            objc_setAssociatedObject(
                output, &gCaptureOutputSentinelAssociationKey, sentinel,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return sentinel;
}

IUSCMicCaptureCursorBox *tryCaptureBindingForCallback(
    id callbackObject, AVCaptureAudioDataOutput *output) {
    if (!callbackObject || !output) return nil;
    IUSCMicCaptureOutputSentinel *sentinel = objc_getAssociatedObject(
        output, &gCaptureOutputSentinelAssociationKey);
    if (!sentinel || !os_unfair_lock_trylock(&sentinel->stateLock)) {
        return nil;
    }
    IUSCMicCaptureCursorBox *binding = nil;
    IUSCMicCaptureCursorBox *candidate = sentinel.currentBinding;
    if (sentinel.output == output &&
        sentinel->outputIdentity == captureObjectIdentity(output) &&
        objc_getAssociatedObject(
            output, &gCaptureOutputSentinelAssociationKey) == sentinel &&
        sentinel->delegateSetterInFlight == 0 &&
        sentinel->pendingBindingGeneration == 0 &&
        sentinel->activeBindingGeneration != 0 &&
        !sentinel->delegateTransactionUnsafe &&
        !sentinel->delegateDrainPermanentlyUnsafe.load(
            std::memory_order_acquire) &&
        sentinel.delegate == callbackObject &&
        sentinel->delegateIdentity == captureObjectIdentity(callbackObject) &&
        candidate && candidate.callbackObject == callbackObject &&
        candidate.output == output &&
        candidate->callbackIdentity == captureObjectIdentity(callbackObject) &&
        candidate->outputIdentity == captureObjectIdentity(output) &&
        candidate->directOutputSentinelIdentity ==
            captureObjectIdentity(sentinel) &&
        candidate->directBindingGeneration ==
            sentinel->activeBindingGeneration &&
        sentinel->lifecycleKnown && sentinel->lifecycleActive) {
        binding = candidate;
    }
    os_unfair_lock_unlock(&sentinel->stateLock);
    return binding;
}

void setCaptureBoxDemand(IUSCMicCaptureCursorBox *box, bool active) {
    if (!box) return;
    const bool previous = box->demandActive.exchange(
        active, std::memory_order_acq_rel);
    if (active && !previous) {
        IUSCMicDemandAcquire();
    } else if (!active && previous) {
        IUSCMicDemandRelease();
    }
}

void setCaptureBoxLifecycle(IUSCMicCaptureCursorBox *box, bool active) {
    if (!box) return;
    box->retired.store(!active, std::memory_order_release);
    setCaptureBoxDemand(box, active);
}

bool armCaptureBoxFromCallback(IUSCMicCaptureCursorBox *box) {
    if (!box || box->retired.load(std::memory_order_acquire)) {
        return false;
    }
    if (box->directBindingGeneration != 0) {
        AVCaptureAudioDataOutput *output = box.output;
        IUSCMicCaptureOutputSentinel *sentinel = output
            ? objc_getAssociatedObject(
                output, &gCaptureOutputSentinelAssociationKey)
            : nil;
        if (!output || !sentinel ||
            !os_unfair_lock_trylock(&sentinel->stateLock)) {
            return false;
        }
        id callbackObject = box.callbackObject;
        const BOOL exactActive =
            sentinel.output == output &&
            sentinel->outputIdentity == captureObjectIdentity(output) &&
            objc_getAssociatedObject(
                output, &gCaptureOutputSentinelAssociationKey) == sentinel &&
            sentinel->delegateSetterInFlight == 0 &&
            sentinel->pendingBindingGeneration == 0 &&
            sentinel->activeBindingGeneration ==
                box->directBindingGeneration &&
            !sentinel->delegateTransactionUnsafe &&
            !sentinel->delegateDrainPermanentlyUnsafe.load(
                std::memory_order_acquire) &&
            sentinel.currentBinding == box && callbackObject &&
            sentinel.delegate == callbackObject &&
            sentinel->delegateIdentity ==
                captureObjectIdentity(callbackObject) &&
            box->directOutputSentinelIdentity ==
                captureObjectIdentity(sentinel) &&
            box->callbackIdentity == captureObjectIdentity(callbackObject) &&
            box->outputIdentity == captureObjectIdentity(output) &&
            sentinel->lifecycleKnown && sentinel->lifecycleActive;
        os_unfair_lock_unlock(&sentinel->stateLock);
        if (!exactActive) return false;
    }
    setCaptureBoxDemand(box, true);
    if (box->retired.load(std::memory_order_acquire)) {
        /* stop/remove won the race; never let this trailing callback re-arm. */
        setCaptureBoxDemand(box, false);
        return false;
    }
    return true;
}

bool captureOutputIsActive(AVCaptureAudioDataOutput *output) {
    if (!output) return false;
    IUSCMicCaptureSessionOutputOwnership *ownership =
        objc_getAssociatedObject(
            output, &gCaptureSessionOutputOwnershipAssociationKey);
    AVCaptureSession *session = ownership.session;
    IUSCMicCaptureSessionObserver *observer = ownership.observer;
    const uint64_t outputEpoch = ownership.epoch;
    if (!ownership || !session || !observer || outputEpoch == 0 ||
        ownership.sessionIdentity != captureObjectIdentity(session) ||
        ownership.observerIdentity != captureObjectIdentity(observer)) {
        return false;
    }
    bool hasActiveConnection = false;
    for (AVCaptureConnection *connection in output.connections) {
        IUSCMicCaptureConnectionAssociation *association =
            objc_getAssociatedObject(
                connection, &gCaptureConnectionAssociationKey);
        if (!association ||
            association->retired.load(std::memory_order_acquire) ||
            association->inFlightOperations.load(
                std::memory_order_acquire) != 0 ||
            association.connection != connection ||
            association.output != output || association.session != session ||
            association.observer != observer ||
            association.connectionIdentity != captureObjectIdentity(connection) ||
            association.outputIdentity != captureObjectIdentity(output) ||
            association.sessionIdentity != captureObjectIdentity(session) ||
            association.observerIdentity != captureObjectIdentity(observer) ||
            association.outputOwnershipEpoch != outputEpoch ||
            association.associationEpoch == 0 ||
            objc_getAssociatedObject(
                connection, &gCaptureConnectionAssociationKey) != association) {
            /*
             * One unconfirmed or in-flight connection makes this exact output
             * unconfirmed as a whole.  In particular, a lifecycle notification
             * must not use a second active connection to undo setEnabled:'s
             * pre-silence or a rescan's per-output fail-closed decision.
             */
            return false;
        }
        if (connection.isActive && connection.isEnabled &&
            association->inFlightOperations.load(
                std::memory_order_acquire) == 0) {
            hasActiveConnection = true;
        }
    }
    return hasActiveConnection;
}

void setCaptureOutputLifecycle(AVCaptureOutput *output, bool active) {
    if (![output isKindOfClass:[AVCaptureAudioDataOutput class]]) return;
    AVCaptureAudioDataOutput *audioOutput =
        (AVCaptureAudioDataOutput *)output;
    @synchronized(audioOutput) {
        /*
         * Keep the published binding, delegate identity check, and lifecycle
         * edge in the same critical section used by reconciliation. Session
         * notifications can otherwise re-arm a binding after a concurrent
         * delegate replacement has retired it.
         */
        IUSCMicCaptureOutputSentinel *sentinel =
            ensureCaptureOutputSentinel(audioOutput);
        if (sentinel) {
            IUSCMicCaptureSessionOutputOwnership *ownership =
                objc_getAssociatedObject(
                    audioOutput,
                    &gCaptureSessionOutputOwnershipAssociationKey);
            const BOOL exactOwner = ownership && ownership.session &&
                ownership.observer && ownership.epoch != 0 &&
                ownership.sessionIdentity ==
                    captureObjectIdentity(ownership.session) &&
                ownership.observerIdentity ==
                    captureObjectIdentity(ownership.observer);
            os_unfair_lock_lock(&sentinel->stateLock);
            sentinel->lifecycleKnown = exactOwner;
            sentinel->lifecycleActive = active;
            sentinel->lifecycleRevision = nextCaptureSessionStateRevision(
                sentinel->lifecycleRevision);
            sentinel->lifecycleSessionIdentity = exactOwner
                ? ownership.sessionIdentity : 0;
            sentinel->lifecycleObserverIdentity = exactOwner
                ? ownership.observerIdentity : 0;
            sentinel->lifecycleOutputEpoch = exactOwner
                ? ownership.epoch : 0;
            IUSCMicCaptureCursorBox *box = sentinel.currentBinding;
            const BOOL bindingIsExactActive =
                sentinel.output == audioOutput &&
                sentinel->outputIdentity == captureObjectIdentity(audioOutput) &&
                objc_getAssociatedObject(
                    audioOutput, &gCaptureOutputSentinelAssociationKey) ==
                        sentinel &&
                sentinel->delegateSetterInFlight == 0 &&
                sentinel->pendingBindingGeneration == 0 &&
                sentinel->activeBindingGeneration != 0 &&
                !sentinel->delegateTransactionUnsafe &&
                !sentinel->delegateDrainPermanentlyUnsafe.load(
                    std::memory_order_acquire) &&
                sentinel.delegate &&
                sentinel->delegateIdentity ==
                    captureObjectIdentity(sentinel.delegate) &&
                box && box.callbackObject == sentinel.delegate &&
                box.output == audioOutput &&
                box->directOutputSentinelIdentity ==
                    captureObjectIdentity(sentinel) &&
                box->directBindingGeneration ==
                    sentinel->activeBindingGeneration;
            /* Pending generations only record desired lifecycle and stay silent. */
            setCaptureBoxLifecycle(
                box, exactOwner && active && bindingIsExactActive);
            os_unfair_lock_unlock(&sentinel->stateLock);
        }

        /*
         * Marker lookup and sentinel publication share the output monitor with
         * marker claiming.  A lifecycle edge is therefore either observed by
         * the publisher's authoritative snapshot or applied to the fully
         * published exact marker; it cannot fall into the former publication
         * gap.  The only nested custom lock order is output -> sentinel.
         */
        IUSCMicSynchronizerOutputMarker *marker = objc_getAssociatedObject(
            audioOutput, &gCaptureSynchronizerMarkerAssociationKey);
        IUSCMicSynchronizerSentinel *synchronizerSentinel = marker.sentinel;
        AVCaptureDataOutputSynchronizer *synchronizer = marker.synchronizer;
        if (marker && synchronizerSentinel && synchronizer &&
            marker.output == audioOutput &&
            marker.outputIdentity == captureObjectIdentity(audioOutput) &&
            marker.sentinelIdentity ==
                captureObjectIdentity(synchronizerSentinel) &&
            marker.synchronizerIdentity ==
                captureObjectIdentity(synchronizer) &&
            objc_getAssociatedObject(
                synchronizer,
                &gCaptureSynchronizerSentinelAssociationKey) ==
                    synchronizerSentinel &&
            [synchronizerSentinel ownsOutput:audioOutput
                                      marker:marker
                                       index:marker.outputIndex]) {
            [synchronizerSentinel setOutput:audioOutput
                                     marker:marker
                                      index:marker.outputIndex
                                     active:active];
        }
    }
}

void failCloseCaptureOutputForSession(
    AVCaptureOutput *output,
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer) {
    if (![output isKindOfClass:[AVCaptureAudioDataOutput class]]) return;
    @synchronized(output) {
        IUSCMicCaptureSessionOutputOwnership *ownership =
            objc_getAssociatedObject(
                output, &gCaptureSessionOutputOwnershipAssociationKey);
        const uintptr_t sessionIdentity = captureObjectIdentity(session);
        const uintptr_t observerIdentity = captureObjectIdentity(observer);
        /* Never let an obsolete session snapshot retire a newer session owner. */
        if (!ownership || ownership.epoch == 0 ||
            (sessionIdentity != 0 && observerIdentity != 0 &&
             ownership.session == session &&
             ownership.observer == observer &&
             ownership.sessionIdentity == sessionIdentity &&
             ownership.observerIdentity == observerIdentity)) {
            setCaptureOutputLifecycle(output, false);
        }
    }
}

void applyCaptureSessionDemandForExactOutput(
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer,
    uint64_t revision,
    bool active,
    AVCaptureAudioDataOutput *exactOutput,
    uint64_t expectedEpoch,
    bool forceExactOutputInactive) {
    if (!session || !observer || revision == 0) return;
    NSArray<AVCaptureOutput *> *outputs = nil;
    @try {
        outputs = session.outputs;
    } @catch (__unused NSException *exception) {
        [observer retireTrackedOutputsForRevision:revision];
        return;
    }
    for (AVCaptureOutput *output in outputs) {
        @try {
            /* Lifecycle notifications may update, but never claim, membership. */
            if (output == exactOutput && expectedEpoch != 0) {
                (void)[observer setOutput:output
                             activeIfOwned:
                                 (active && !forceExactOutputInactive)
                                   revision:revision
                              expectedEpoch:expectedEpoch];
            } else {
                (void)[observer setOutput:output
                             activeIfOwned:active
                                   revision:revision];
            }
        } @catch (__unused NSException *exception) {
            /* One malformed output must not prevent the others from converging. */
            @try {
                [observer failCloseOutputIfOwned:output revision:revision];
            } @catch (__unused NSException *failClosedException) {
            }
        }
    }
}

void applyCaptureSessionDemand(AVCaptureSession *session,
                               IUSCMicCaptureSessionObserver *observer,
                               uint64_t revision,
                               bool active) {
    applyCaptureSessionDemandForExactOutput(
        session, observer, revision, active, nil, 0, false);
}

uint64_t setCaptureSessionDemand(AVCaptureSession *session, bool active) {
    if (!session) return 0;
    IUSCMicCaptureSessionObserver *observer = objc_getAssociatedObject(
        session, &gCaptureSessionObserverAssociationKey);
    if (!observer) return 0;
    const uint64_t revision = [observer beginLifecycleUpdate];
    applyCaptureSessionDemand(session, observer, revision, active);
    return revision;
}

uint64_t setCaptureSessionDemandForObserver(
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer,
    bool active) {
    if (!session || !observer ||
        objc_getAssociatedObject(
            session, &gCaptureSessionObserverAssociationKey) != observer) {
        return 0;
    }
    const uint64_t revision = [observer beginLifecycleUpdate];
    applyCaptureSessionDemand(session, observer, revision, active);
    return revision;
}

void convergeCaptureSessionDemand(AVCaptureSession *session) {
    if (!session) return;
    IUSCMicCaptureSessionObserver *observer = objc_getAssociatedObject(
        session, &gCaptureSessionObserverAssociationKey);
    if (!observer) return;
    BOOL active = NO;
    const uint64_t revision =
        [observer beginAuthoritativeLifecycleUpdate:&active];
    applyCaptureSessionDemand(session, observer, revision, active);
}

void convergeCaptureSessionDemandForObserver(
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer) {
    if (!session || !observer ||
        objc_getAssociatedObject(
            session, &gCaptureSessionObserverAssociationKey) != observer) {
        return;
    }
    BOOL active = NO;
    const uint64_t revision =
        [observer beginAuthoritativeLifecycleUpdate:&active];
    applyCaptureSessionDemand(session, observer, revision, active);
}

void convergeCaptureSessionDemandIfCurrent(
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer,
    uint64_t expectedRevision) {
    if (!session || !observer || expectedRevision == 0 ||
        objc_getAssociatedObject(
            session, &gCaptureSessionObserverAssociationKey) != observer) {
        return;
    }
    BOOL active = NO;
    const uint64_t revision =
        [observer beginAuthoritativeConvergenceIfCurrent:expectedRevision
                                                activeOut:&active];
    applyCaptureSessionDemand(session, observer, revision, active);
}

uint64_t invalidateCaptureOutputAndApply(
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer,
    AVCaptureOutput *output,
    uint64_t *invalidatedEpochOut) {
    if (invalidatedEpochOut) *invalidatedEpochOut = 0;
    if (!session || !observer) return 0;
    BOOL active = NO;
    const uint64_t revision =
        [observer invalidateAndUntrackOutput:output
                                  activeOut:&active
                                   epochOut:invalidatedEpochOut];
    applyCaptureSessionDemand(session, observer, revision, active);
    return revision;
}

void failCloseCaptureOutputAfterStateFailure(
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer,
    AVCaptureOutput *output) {
    @try {
        (void)invalidateCaptureOutputAndApply(
            session, observer, output, nullptr);
    } @catch (__unused NSException *exception) {
    }
    @try {
        failCloseCaptureOutputForSession(output, session, observer);
    } @catch (__unused NSException *exception) {
    }
}

BOOL authoritativelyCommitAddedCaptureOutput(
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer,
    AVCaptureOutput *output) {
    if (!session || !observer || !output) return NO;
    /*
     * A lifecycle notification may win between claim and commit. Retry only
     * from a fresh authoritative membership check; a migrated output can
     * therefore never be reclaimed from its new session by this old hook.
     */
    for (unsigned attempt = 0; attempt < 3; ++attempt) {
        uint64_t revision = 0;
        BOOL active = NO;
        if (![observer authoritativelyClaimOutput:output
                                      revisionOut:&revision
                                        activeOut:&active]) {
            return NO;
        }
        if ([observer setOutput:output
                   activeIfOwned:active
                         revision:revision]) {
            /* The claim revision supersedes any partially applied old event. */
            applyCaptureSessionDemand(session, observer, revision, active);
            return YES;
        }
    }
    return NO;
}

BOOL snapshotExactCaptureOutputOwnership(
    AVCaptureAudioDataOutput *output,
    AVCaptureSession **sessionOut,
    IUSCMicCaptureSessionObserver **observerOut,
    uint64_t *epochOut) {
    if (sessionOut) *sessionOut = nil;
    if (observerOut) *observerOut = nil;
    if (epochOut) *epochOut = 0;
    if (!output) return NO;
    AVCaptureSession *session = nil;
    IUSCMicCaptureSessionObserver *observer = nil;
    uint64_t epoch = 0;
    @synchronized(output) {
        IUSCMicCaptureSessionOutputOwnership *ownership =
            objc_getAssociatedObject(
                output, &gCaptureSessionOutputOwnershipAssociationKey);
        session = ownership.session;
        observer = ownership.observer;
        epoch = ownership.epoch;
        BOOL remainsMember = NO;
        @try {
            remainsMember = session &&
                [session.outputs containsObject:output];
        } @catch (__unused NSException *exception) {
            remainsMember = NO;
        }
        if (!session || !observer || epoch == 0 || !remainsMember ||
            ownership.sessionIdentity != captureObjectIdentity(session) ||
            ownership.observerIdentity != captureObjectIdentity(observer) ||
            observer->ownerSessionIdentity != captureObjectIdentity(session) ||
            objc_getAssociatedObject(
                session, &gCaptureSessionObserverAssociationKey) != observer) {
            session = nil;
            observer = nil;
            epoch = 0;
        }
    }
    if (!session || !observer || epoch == 0) return NO;
    if (sessionOut) *sessionOut = session;
    if (observerOut) *observerOut = observer;
    if (epochOut) *epochOut = epoch;
    return YES;
}

BOOL convergeExactCaptureConnectionOutput(
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer,
    AVCaptureAudioDataOutput *output,
    uint64_t expectedEpoch,
    bool forceInactive) {
    if (!session || !observer || !output || expectedEpoch == 0) return NO;
    BOOL sessionActive = NO;
    const uint64_t revision =
        [observer beginAuthoritativeConnectionUpdateForOutput:output
                                                 expectedEpoch:expectedEpoch
                                                      activeOut:&sessionActive];
    if (revision == 0) return NO;
    applyCaptureSessionDemandForExactOutput(
        session, observer, revision, sessionActive, output, expectedEpoch,
        forceInactive);
    return YES;
}

BOOL captureConnectionAssociationMatches(
    IUSCMicCaptureConnectionAssociation *association,
    AVCaptureConnection *connection,
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer,
    AVCaptureAudioDataOutput *output,
    uint64_t expectedEpoch) {
    return association &&
        !association->retired.load(std::memory_order_acquire) &&
        association.connection == connection &&
        association.session == session &&
        association.observer == observer &&
        association.output == output &&
        association.connectionIdentity == captureObjectIdentity(connection) &&
        association.sessionIdentity == captureObjectIdentity(session) &&
        association.observerIdentity == captureObjectIdentity(observer) &&
        association.outputIdentity == captureObjectIdentity(output) &&
        association.outputOwnershipEpoch == expectedEpoch &&
        association.associationEpoch != 0 &&
        expectedEpoch != 0;
}

BOOL captureConnectionAssociationHasExactCurrentOwner(
    IUSCMicCaptureConnectionAssociation *association,
    BOOL requireConnectionMembership) {
    if (!association ||
        association->retired.load(std::memory_order_acquire)) return NO;
    AVCaptureConnection *connection = association.connection;
    AVCaptureSession *session = association.session;
    IUSCMicCaptureSessionObserver *observer = association.observer;
    AVCaptureAudioDataOutput *output = association.output;
    const uint64_t epoch = association.outputOwnershipEpoch;
    if (!connection || !session || !observer || !output || epoch == 0 ||
        association.associationEpoch == 0 ||
        association.connectionIdentity != captureObjectIdentity(connection) ||
        association.sessionIdentity != captureObjectIdentity(session) ||
        association.observerIdentity != captureObjectIdentity(observer) ||
        association.outputIdentity != captureObjectIdentity(output)) {
        return NO;
    }
    @synchronized(output) {
        IUSCMicCaptureSessionOutputOwnership *ownership =
            objc_getAssociatedObject(
                output, &gCaptureSessionOutputOwnershipAssociationKey);
        BOOL outputMember = NO;
        BOOL connectionMember = NO;
        BOOL declaredForOutput = NO;
        @try {
            outputMember = [session.outputs containsObject:output];
            connectionMember =
                [output.connections containsObject:connection];
            declaredForOutput = connection.output == output;
        } @catch (__unused NSException *exception) {
            return NO;
        }
        return outputMember &&
            (connectionMember ||
             (!requireConnectionMembership && declaredForOutput)) &&
            ownership.session == session && ownership.observer == observer &&
            ownership.sessionIdentity == captureObjectIdentity(session) &&
            ownership.observerIdentity == captureObjectIdentity(observer) &&
            ownership.epoch == epoch &&
            observer->ownerSessionIdentity == captureObjectIdentity(session) &&
            objc_getAssociatedObject(
                session, &gCaptureSessionObserverAssociationKey) == observer;
    }
}

BOOL convergeCaptureConnectionAssociationOwnerSnapshot(
    IUSCMicCaptureConnectionAssociation *association,
    bool forceInactive) {
    if (!association) return NO;
    AVCaptureSession *session = association.session;
    IUSCMicCaptureSessionObserver *observer = association.observer;
    AVCaptureAudioDataOutput *output = association.output;
    const uint64_t epoch = association.outputOwnershipEpoch;
    if (!session || !observer || !output || epoch == 0 ||
        association.sessionIdentity != captureObjectIdentity(session) ||
        association.observerIdentity != captureObjectIdentity(observer) ||
        association.outputIdentity != captureObjectIdentity(output)) {
        return NO;
    }
    @try {
        /* The observer revalidates current membership and this exact epoch. */
        return convergeExactCaptureConnectionOutput(
            session, observer, output, epoch, forceInactive);
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

IUSCMicCaptureConnectionAssociation *currentCaptureConnectionAssociation(
    AVCaptureConnection *connection) {
    if (!connection) return nil;
    IUSCMicCaptureConnectionAssociation *association = nil;
    @synchronized(connection) {
        association = objc_getAssociatedObject(
            connection, &gCaptureConnectionAssociationKey);
        if (!association ||
            association->retired.load(std::memory_order_acquire) ||
            association.connectionIdentity != captureObjectIdentity(connection)) {
            association = nil;
        }
    }
    return association;
}

BOOL captureConnectionOperationCanCaptureLocked(
    IUSCMicCaptureConnectionOperation *operation,
    AVCaptureConnection *connection,
    AVCaptureSession *expectedSession) {
    if (!operation) return YES;
    AVCaptureSession *operationSession = operation.expectedSession;
    return !operation.completed &&
        operation.connection == connection &&
        operation.connectionIdentity == captureObjectIdentity(connection) &&
        (!operationSession || operationSession == expectedSession) &&
        (operation.expectedSessionIdentity == 0 ||
         operation.expectedSessionIdentity ==
             captureObjectIdentity(expectedSession));
}

void captureConnectionAssociationForOperationLocked(
    IUSCMicCaptureConnectionOperation *operation,
    AVCaptureSession *session,
    IUSCMicCaptureConnectionAssociation *association) {
    if (!operation || !session || !association) return;
    if (operation.association) return;
    operation.expectedSession = session;
    operation.expectedSessionIdentity = captureObjectIdentity(session);
    operation.association = association;
    operation.associationIdentity = captureObjectIdentity(association);
    operation.outputIdentity = association.outputIdentity;
    operation.associationEpoch = association.associationEpoch;
    operation.outputOwnershipEpoch = association.outputOwnershipEpoch;
    operation.inFlightRegistered = YES;
    (void)association->inFlightOperations.fetch_add(
        1, std::memory_order_acq_rel);
}

IUSCMicCaptureConnectionAssociation *associateCaptureConnection(
    AVCaptureConnection *connection,
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer,
    AVCaptureAudioDataOutput *output,
    BOOL requireConnectionMembership,
    IUSCMicCaptureConnectionOperation *operation) {
    if (!connection || !session || !observer || !output) return nil;
    IUSCMicCaptureConnectionAssociation *newAssociation =
        [IUSCMicCaptureConnectionAssociation new];
    if (newAssociation) {
        newAssociation.associationEpoch =
            nextCaptureConnectionAssociationEpoch();
    }

    IUSCMicCaptureConnectionAssociation *result = nil;
    @synchronized(connection) {
        if (!captureConnectionOperationCanCaptureLocked(
                operation, connection, session)) {
            return nil;
        }
        AVCaptureSession *exactSession = nil;
        IUSCMicCaptureSessionObserver *exactObserver = nil;
        uint64_t epoch = 0;
        if (!snapshotExactCaptureOutputOwnership(
                output, &exactSession, &exactObserver, &epoch) ||
            exactSession != session || exactObserver != observer) {
            return nil;
        }
        BOOL connectionMatchesTarget = NO;
        @try {
            connectionMatchesTarget =
                [output.connections containsObject:connection] ||
                (!requireConnectionMembership && connection.output == output);
        } @catch (__unused NSException *exception) {
            connectionMatchesTarget = NO;
        }
        if (!connectionMatchesTarget) return nil;

        IUSCMicCaptureConnectionAssociation *existing =
            objc_getAssociatedObject(
                connection, &gCaptureConnectionAssociationKey);
        if (captureConnectionAssociationMatches(
                existing, connection, session, observer, output, epoch)) {
            if (!captureConnectionOperationCanCaptureLocked(
                    operation, connection, session)) return nil;
            if (operation && operation.association &&
                operation.association != existing) return nil;
            captureConnectionAssociationForOperationLocked(
                operation, session, existing);
            return existing;
        }
        /* Never let a stale caller displace another still-current handoff. */
        if (existing &&
            captureConnectionAssociationHasExactCurrentOwner(existing, YES)) {
            return nil;
        }
        if (!captureConnectionOperationCanCaptureLocked(
                operation, connection, session)) return nil;
        if (operation && operation.association) return nil;
        if (!newAssociation) return nil;
        if (!snapshotExactCaptureOutputOwnership(
                output, &exactSession, &exactObserver, &epoch) ||
            exactSession != session || exactObserver != observer) {
            return nil;
        }
        @try {
            connectionMatchesTarget =
                [output.connections containsObject:connection] ||
                (!requireConnectionMembership && connection.output == output);
        } @catch (__unused NSException *exception) {
            connectionMatchesTarget = NO;
        }
        if (!connectionMatchesTarget) return nil;
        existing = objc_getAssociatedObject(
            connection, &gCaptureConnectionAssociationKey);
        if (existing &&
            captureConnectionAssociationHasExactCurrentOwner(existing, YES)) {
            return nil;
        }
        if (!captureConnectionOperationCanCaptureLocked(
                operation, connection, session)) return nil;
        if (operation && operation.association) return nil;
        if (existing) {
            existing->retired.store(true, std::memory_order_release);
        }
        newAssociation.connection = connection;
        newAssociation.session = session;
        newAssociation.output = output;
        newAssociation.observer = observer;
        newAssociation.connectionIdentity = captureObjectIdentity(connection);
        newAssociation.sessionIdentity = captureObjectIdentity(session);
        newAssociation.outputIdentity = captureObjectIdentity(output);
        newAssociation.observerIdentity = captureObjectIdentity(observer);
        newAssociation.outputOwnershipEpoch = epoch;
        objc_setAssociatedObject(
            connection, &gCaptureConnectionAssociationKey, newAssociation,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        captureConnectionAssociationForOperationLocked(
            operation, session, newAssociation);
        result = newAssociation;
    }
    return result;
}

void failCloseUnassociatedCaptureConnectionOutput(
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer,
    AVCaptureAudioDataOutput *output) {
    AVCaptureSession *exactSession = nil;
    IUSCMicCaptureSessionObserver *exactObserver = nil;
    uint64_t epoch = 0;
    if (snapshotExactCaptureOutputOwnership(
            output, &exactSession, &exactObserver, &epoch) &&
        exactSession == session && exactObserver == observer) {
        (void)convergeExactCaptureConnectionOutput(
            session, observer, output, epoch, true);
    }
}

void registerCaptureConnectionAssociation(
    IUSCMicCaptureConnectionAssociation *association);

void associateCaptureConnectionsForOutput(
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer,
    AVCaptureOutput *output) {
    if (![output isKindOfClass:[AVCaptureAudioDataOutput class]] ||
        !session || !observer) return;
    AVCaptureAudioDataOutput *audioOutput =
        (AVCaptureAudioDataOutput *)output;
    NSArray<AVCaptureConnection *> *connections = nil;
    @try {
        connections = audioOutput.connections;
    } @catch (__unused NSException *exception) {
        failCloseUnassociatedCaptureConnectionOutput(
            session, observer, audioOutput);
        return;
    }
    for (AVCaptureConnection *connection in connections) {
        IUSCMicCaptureConnectionAssociation *association =
            associateCaptureConnection(
                connection, session, observer, audioOutput, YES, nil);
        if (!association) {
            failCloseUnassociatedCaptureConnectionOutput(
                session, observer, audioOutput);
        } else {
            registerCaptureConnectionAssociation(association);
        }
    }
}

void associateCaptureConnectionsForOutputFromCurrentOwner(
    AVCaptureOutput *output) {
    if (![output isKindOfClass:[AVCaptureAudioDataOutput class]]) return;
    AVCaptureSession *session = nil;
    IUSCMicCaptureSessionObserver *observer = nil;
    uint64_t epoch = 0;
    AVCaptureAudioDataOutput *audioOutput =
        (AVCaptureAudioDataOutput *)output;
    if (snapshotExactCaptureOutputOwnership(
            audioOutput, &session, &observer, &epoch)) {
        (void)epoch;
        associateCaptureConnectionsForOutput(
            session, observer, audioOutput);
    }
}

AVCaptureAudioDataOutput *audioOutputForCaptureConnectionInSession(
    AVCaptureSession *session,
    AVCaptureConnection *connection,
    bool allowDeclaredOutput) {
    if (!session || !connection) return nil;
    NSArray<AVCaptureOutput *> *outputs = nil;
    @try {
        outputs = session.outputs;
    } @catch (__unused NSException *exception) {
        return nil;
    }
    for (AVCaptureOutput *output in outputs) {
        if (![output isKindOfClass:[AVCaptureAudioDataOutput class]]) continue;
        @try {
            for (AVCaptureConnection *candidate in output.connections) {
                if (candidate == connection) {
                    return (AVCaptureAudioDataOutput *)output;
                }
            }
        } @catch (__unused NSException *exception) {
        }
    }
    if (allowDeclaredOutput) {
        AVCaptureOutput *declaredOutput = nil;
        @try {
            declaredOutput = connection.output;
        } @catch (__unused NSException *exception) {
            declaredOutput = nil;
        }
        if ([declaredOutput isKindOfClass:[AVCaptureAudioDataOutput class]] &&
            [outputs containsObject:declaredOutput]) {
            return (AVCaptureAudioDataOutput *)declaredOutput;
        }
    }
    return nil;
}

IUSCMicCaptureConnectionAssociation *
associateCaptureConnectionFromCurrentOutputOwner(
    AVCaptureConnection *connection,
    IUSCMicCaptureConnectionOperation *operation) {
    if (!connection) return nil;
    AVCaptureOutput *candidate = nil;
    @try {
        candidate = connection.output;
    } @catch (__unused NSException *exception) {
        candidate = nil;
    }
    if (![candidate isKindOfClass:[AVCaptureAudioDataOutput class]]) return nil;
    AVCaptureSession *session = nil;
    IUSCMicCaptureSessionObserver *observer = nil;
    uint64_t epoch = 0;
    AVCaptureAudioDataOutput *output =
        (AVCaptureAudioDataOutput *)candidate;
    BOOL isCurrentMember = NO;
    @try {
        isCurrentMember = [output.connections containsObject:connection];
    } @catch (__unused NSException *exception) {
        isCurrentMember = NO;
    }
    if (!isCurrentMember) return nil;
    if (!snapshotExactCaptureOutputOwnership(
            output, &session, &observer, &epoch)) return nil;
    IUSCMicCaptureConnectionAssociation *association =
        associateCaptureConnection(
            connection, session, observer, output, YES, operation);
    (void)epoch;
    return association;
}

void clearCaptureConnectionAssociationIfExact(
    AVCaptureConnection *connection,
    IUSCMicCaptureConnectionAssociation *expectedAssociation) {
    if (!connection || !expectedAssociation) return;
    @synchronized(connection) {
        IUSCMicCaptureConnectionAssociation *association =
            objc_getAssociatedObject(
                connection, &gCaptureConnectionAssociationKey);
        if (association == expectedAssociation &&
            !association->retired.load(std::memory_order_acquire) &&
            association.connection == connection &&
            association.connectionIdentity == captureObjectIdentity(connection) &&
            association.outputOwnershipEpoch != 0) {
            association->retired.store(true, std::memory_order_release);
            objc_setAssociatedObject(
                connection, &gCaptureConnectionAssociationKey, nil,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

void clearCaptureConnectionAssociationsForOutput(
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer,
    AVCaptureOutput *output,
    uint64_t expectedEpoch) {
    if (![output isKindOfClass:[AVCaptureAudioDataOutput class]] ||
        expectedEpoch == 0) return;
    NSArray<AVCaptureConnection *> *connections = nil;
    @try {
        connections = output.connections;
    } @catch (__unused NSException *exception) {
        return;
    }
    for (AVCaptureConnection *connection in connections) {
        IUSCMicCaptureConnectionAssociation *association =
            currentCaptureConnectionAssociation(connection);
        if (association && association.session == session &&
            association.observer == observer && association.output == output &&
            association.sessionIdentity == captureObjectIdentity(session) &&
            association.observerIdentity == captureObjectIdentity(observer) &&
            association.outputIdentity == captureObjectIdentity(output) &&
            association.outputOwnershipEpoch == expectedEpoch) {
            clearCaptureConnectionAssociationIfExact(
                connection, association);
        }
    }
}

void retireCaptureConnectionAssociationOnDealloc(
    IUSCMicCaptureConnectionAssociation *association) {
    if (!association || association->retired.exchange(
            true, std::memory_order_acq_rel)) return;
    /* Exact epoch validation prevents an old connection from touching migration. */
    (void)convergeCaptureConnectionAssociationOwnerSnapshot(
        association, false);
}

IUSCMicCaptureSessionConfigurationSentinel *
ensureCaptureSessionConfigurationSentinel(AVCaptureSession *session) {
    if (!session) return nil;
    IUSCMicCaptureSessionConfigurationSentinel *sentinel =
        objc_getAssociatedObject(
            session, &gCaptureSessionConfigurationAssociationKey);
    if (sentinel && sentinel.session == session &&
        sentinel.sessionIdentity == captureObjectIdentity(session)) {
        return sentinel;
    }
    @synchronized(session) {
        sentinel = objc_getAssociatedObject(
            session, &gCaptureSessionConfigurationAssociationKey);
        if (!sentinel || sentinel.session != session ||
            sentinel.sessionIdentity != captureObjectIdentity(session)) {
            sentinel = [IUSCMicCaptureSessionConfigurationSentinel new];
            if (!sentinel) return nil;
            sentinel.session = session;
            sentinel.sessionIdentity = captureObjectIdentity(session);
            objc_setAssociatedObject(
                session, &gCaptureSessionConfigurationAssociationKey,
                sentinel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return sentinel;
}

BOOL captureSessionConfigurationIsOpen(AVCaptureSession *session) {
    IUSCMicCaptureSessionConfigurationSentinel *sentinel =
        objc_getAssociatedObject(
            session, &gCaptureSessionConfigurationAssociationKey);
    if (!sentinel || sentinel.session != session ||
        sentinel.sessionIdentity != captureObjectIdentity(session)) {
        return NO;
    }
    BOOL open = NO;
    @synchronized(sentinel) {
        open = sentinel.session == session &&
            sentinel.sessionIdentity == captureObjectIdentity(session) &&
            (sentinel->depth != 0 || sentinel->mutationDepth != 0 ||
             sentinel->dirty);
    }
    return open;
}

void registerCaptureConnectionAssociation(
    IUSCMicCaptureConnectionAssociation *association) {
    AVCaptureSession *session = association.session;
    if (!association || !session || association.associationEpoch == 0 ||
        association.sessionIdentity != captureObjectIdentity(session)) return;
    IUSCMicCaptureSessionConfigurationSentinel *sentinel =
        ensureCaptureSessionConfigurationSentinel(session);
    if (!sentinel) return;
    @synchronized(sentinel) {
        if (sentinel.session == session &&
            sentinel.sessionIdentity == association.sessionIdentity) {
            [sentinel.associations addObject:association];
        }
    }
}

BOOL captureConnectionAssociationHasExactOutputOwner(
    IUSCMicCaptureConnectionAssociation *association) {
    if (!association) return NO;
    AVCaptureSession *session = nil;
    IUSCMicCaptureSessionObserver *observer = nil;
    uint64_t epoch = 0;
    if (!snapshotExactCaptureOutputOwnership(
            association.output, &session, &observer, &epoch)) return NO;
    return session == association.session && observer == association.observer &&
        epoch == association.outputOwnershipEpoch &&
        association.sessionIdentity == captureObjectIdentity(session) &&
        association.observerIdentity == captureObjectIdentity(observer) &&
        association.outputIdentity == captureObjectIdentity(association.output);
}

BOOL captureConnectionAssociationTokenIsCurrentLocked(
    AVCaptureConnection *connection,
    IUSCMicCaptureConnectionAssociation *association,
    AVCaptureSession *expectedSession) {
    if (!connection || !association || !expectedSession ||
        association->retired.load(std::memory_order_acquire) ||
        objc_getAssociatedObject(
            connection, &gCaptureConnectionAssociationKey) != association ||
        association.connection != connection ||
        association.session != expectedSession ||
        association.connectionIdentity != captureObjectIdentity(connection) ||
        association.sessionIdentity != captureObjectIdentity(expectedSession) ||
        association.associationEpoch == 0 ||
        association.outputOwnershipEpoch == 0) {
        return NO;
    }
    return YES;
}

BOOL captureConnectionOperationTokenMatches(
    IUSCMicCaptureConnectionOperation *operation,
    IUSCMicCaptureConnectionAssociation *association) {
    return operation && association &&
        operation.association == association &&
        operation.associationIdentity == captureObjectIdentity(association) &&
        operation.outputIdentity == association.outputIdentity &&
        operation.associationEpoch != 0 &&
        operation.associationEpoch == association.associationEpoch &&
        operation.outputOwnershipEpoch != 0 &&
        operation.outputOwnershipEpoch == association.outputOwnershipEpoch;
}

void finishCaptureConnectionOperationInFlightLocked(
    IUSCMicCaptureConnectionOperation *operation,
    IUSCMicCaptureConnectionAssociation *association) {
    if (!operation || !association || !operation.inFlightRegistered ||
        !captureConnectionOperationTokenMatches(operation, association)) return;
    operation.inFlightRegistered = NO;
    const uint32_t count = association->inFlightOperations.load(
        std::memory_order_acquire);
    if (count != 0) {
        (void)association->inFlightOperations.fetch_sub(
            1, std::memory_order_acq_rel);
    }
}

IUSCMicCaptureConnectionOperation *beginCaptureConnectionOperation(
    AVCaptureConnection *connection,
    AVCaptureSession *expectedSession) {
    if (!connection) return nil;
    IUSCMicCaptureConnectionOperation *operation =
        [IUSCMicCaptureConnectionOperation new];
    if (operation) {
        operation.connection = connection;
        operation.expectedSession = expectedSession;
        operation.connectionIdentity = captureObjectIdentity(connection);
        operation.expectedSessionIdentity =
            captureObjectIdentity(expectedSession);
    }
    @synchronized(connection) {
        IUSCMicCaptureConnectionAssociation *association =
            objc_getAssociatedObject(
                connection, &gCaptureConnectionAssociationKey);
        AVCaptureSession *operationSession = expectedSession;
        if (!operationSession && association &&
            !association->retired.load(std::memory_order_acquire)) {
            operationSession = association.session;
        }
        if (operation && operationSession &&
            captureConnectionAssociationTokenIsCurrentLocked(
                connection, association, operationSession) &&
            captureConnectionAssociationHasExactCurrentOwner(
                association, NO)) {
            captureConnectionAssociationForOperationLocked(
                operation, operationSession, association);
        }
        if (operation && !operation.association) {
            operation.expectedSession = operationSession;
            operation.expectedSessionIdentity =
                captureObjectIdentity(operationSession);
        } else if (!operation && association &&
                   (!expectedSession || association.session == expectedSession) &&
                   captureConnectionAssociationHasExactCurrentOwner(
                       association, NO)) {
            /* Allocation failure closes only the exact current owner token. */
            (void)convergeCaptureConnectionAssociationOwnerSnapshot(
                association, true);
        }
    }
    return operation;
}

BOOL preSilenceCaptureConnectionOperation(
    IUSCMicCaptureConnectionOperation *operation,
    BOOL requireConnectionMembership) {
    AVCaptureConnection *connection = operation.connection;
    AVCaptureSession *expectedSession = operation.expectedSession;
    IUSCMicCaptureConnectionAssociation *association = operation.association;
    if (!operation || !connection || !expectedSession || !association ||
        !captureConnectionOperationTokenMatches(operation, association) ||
        operation.connectionIdentity != captureObjectIdentity(connection) ||
        operation.expectedSessionIdentity != captureObjectIdentity(expectedSession)) {
        return NO;
    }
    BOOL submitted = NO;
    @synchronized(connection) {
        if (operation.completed ||
            !captureConnectionAssociationTokenIsCurrentLocked(
                connection, association, expectedSession) ||
            !captureConnectionAssociationHasExactCurrentOwner(
                association, requireConnectionMembership)) {
            return NO;
        }
        submitted = convergeCaptureConnectionAssociationOwnerSnapshot(
            association, true);
    }
    return submitted;
}

BOOL authoritativeConvergeCurrentCaptureConnectionOwner(
    AVCaptureConnection *connection) {
    if (!connection) return NO;
    BOOL submitted = NO;
    @synchronized(connection) {
        IUSCMicCaptureConnectionAssociation *association =
            objc_getAssociatedObject(
                connection, &gCaptureConnectionAssociationKey);
        AVCaptureSession *session = association.session;
        if (!captureConnectionAssociationTokenIsCurrentLocked(
                connection, association, session) ||
            !captureConnectionAssociationHasExactCurrentOwner(
                association, YES)) return NO;
        association->completionRevision =
            nextCaptureSessionStateRevision(
                association->completionRevision);
        const uint64_t completionRevision =
            association->completionRevision;
        if (objc_getAssociatedObject(
                connection, &gCaptureConnectionAssociationKey) != association ||
            association->completionRevision != completionRevision) return NO;
        submitted = convergeCaptureConnectionAssociationOwnerSnapshot(
            association, false);
    }
    return submitted;
}

BOOL completeCaptureConnectionOperation(
    IUSCMicCaptureConnectionOperation *operation,
    BOOL requireConnectionMembership) {
    AVCaptureConnection *connection = operation.connection;
    AVCaptureSession *expectedSession = operation.expectedSession;
    IUSCMicCaptureConnectionAssociation *association = operation.association;
    if (!operation || !connection || !expectedSession || !association ||
        !captureConnectionOperationTokenMatches(operation, association)) return NO;
    BOOL submitted = NO;
    BOOL rescanCurrentOwner = NO;
    @synchronized(connection) {
        if (operation.completed) return NO;
        operation.completed = YES;
        finishCaptureConnectionOperationInFlightLocked(
            operation, association);
        if (!captureConnectionAssociationTokenIsCurrentLocked(
                connection, association, expectedSession) ||
            !captureConnectionAssociationHasExactCurrentOwner(
                association, requireConnectionMembership)) {
            rescanCurrentOwner = YES;
        } else {
            association->completionRevision =
                nextCaptureSessionStateRevision(
                    association->completionRevision);
            operation.completionRevision = association->completionRevision;
            if (objc_getAssociatedObject(
                    connection,
                    &gCaptureConnectionAssociationKey) != association ||
                association->completionRevision !=
                    operation.completionRevision ||
                !captureConnectionOperationTokenMatches(
                    operation, association)) {
                rescanCurrentOwner = YES;
            } else {
                /* Allocate ordering only after Apple returns. The exact owner
                 * commit then re-reads isEnabled/isActive; entry order cannot
                 * suppress the Apple side effect that completed last. */
                submitted = convergeCaptureConnectionAssociationOwnerSnapshot(
                    association, false);
            }
        }
    }
    if (rescanCurrentOwner) {
        (void)authoritativeConvergeCurrentCaptureConnectionOwner(
            connection);
    }
    return submitted;
}

BOOL completeCaptureConnectionRemoval(
    IUSCMicCaptureConnectionOperation *operation) {
    AVCaptureConnection *connection = operation.connection;
    AVCaptureSession *expectedSession = operation.expectedSession;
    IUSCMicCaptureConnectionAssociation *association = operation.association;
    if (!operation || !connection || !expectedSession || !association ||
        !captureConnectionOperationTokenMatches(operation, association)) return NO;
    BOOL completed = NO;
    BOOL rescanCurrentOwner = NO;
    @synchronized(connection) {
        if (operation.completed) return NO;
        operation.completed = YES;
        finishCaptureConnectionOperationInFlightLocked(
            operation, association);
        if (!captureConnectionAssociationTokenIsCurrentLocked(
                connection, association, expectedSession) ||
            !captureConnectionAssociationHasExactOutputOwner(association)) {
            rescanCurrentOwner = YES;
        } else {
            BOOL remainsMember = YES;
            @try {
                remainsMember =
                    [association.output.connections containsObject:connection];
            } @catch (__unused NSException *exception) {
                remainsMember = YES;
            }
            association->completionRevision =
                nextCaptureSessionStateRevision(
                    association->completionRevision);
            operation.completionRevision = association->completionRevision;
            if (remainsMember) {
                completed = convergeCaptureConnectionAssociationOwnerSnapshot(
                    association, false);
            } else {
                association->retired.store(true, std::memory_order_release);
                objc_setAssociatedObject(
                    connection, &gCaptureConnectionAssociationKey, nil,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                (void)convergeCaptureConnectionAssociationOwnerSnapshot(
                    association, false);
                completed = YES;
            }
        }
    }
    if (rescanCurrentOwner) {
        (void)authoritativeConvergeCurrentCaptureConnectionOwner(
            connection);
    }
    return completed;
}

BOOL clearCaptureConnectionAssociationTokenForRescan(
    IUSCMicCaptureConnectionAssociation *association,
    AVCaptureSession *expectedSession) {
    AVCaptureConnection *connection = association.connection;
    if (!association || !connection || !expectedSession) return NO;
    BOOL cleared = NO;
    @synchronized(connection) {
        if (!captureConnectionAssociationTokenIsCurrentLocked(
                connection, association, expectedSession) ||
            !captureConnectionAssociationHasExactOutputOwner(association)) {
            return NO;
        }
        BOOL remainsMember = YES;
        @try {
            remainsMember =
                [association.output.connections containsObject:connection];
        } @catch (__unused NSException *exception) {
            remainsMember = YES;
        }
        if (remainsMember) return NO;
        association->retired.store(true, std::memory_order_release);
        objc_setAssociatedObject(
            connection, &gCaptureConnectionAssociationKey, nil,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        (void)convergeCaptureConnectionAssociationOwnerSnapshot(
            association, false);
        cleared = YES;
    }
    return cleared;
}

void applyCaptureSessionConfigurationDemand(
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer,
    BOOL forceInactive,
    NSSet *unconfirmedOutputs) {
    if (!session || !observer || objc_getAssociatedObject(
            session, &gCaptureSessionObserverAssociationKey) != observer) return;
    BOOL active = NO;
    const uint64_t revision =
        [observer beginAuthoritativeLifecycleUpdate:&active];
    if (revision == 0) return;
    NSArray<AVCaptureOutput *> *outputs = nil;
    @try {
        outputs = session.outputs;
    } @catch (__unused NSException *exception) {
        [observer retireTrackedOutputsForRevision:revision];
        return;
    }
    for (AVCaptureOutput *output in outputs) {
        @try {
            (void)[observer setOutput:output
                       activeIfOwned:
                           (active && !forceInactive &&
                            ![unconfirmedOutputs containsObject:output])
                             revision:revision];
        } @catch (__unused NSException *exception) {
            @try {
                [observer failCloseOutputIfOwned:output revision:revision];
            } @catch (__unused NSException *failClosedException) {
            }
        }
    }
}

enum class CaptureSessionRescanResult {
    Committed,
    Stale,
    Deferred,
};

BOOL captureSessionRescanRevisionIsCurrent(
    IUSCMicCaptureSessionConfigurationSentinel *sentinel,
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer,
    uint64_t expectedConfigurationRevision,
    BOOL allowWhileConfigurationOpen) {
    if (!sentinel || !session || !observer ||
        expectedConfigurationRevision == 0) return NO;
    BOOL current = NO;
    @synchronized(sentinel) {
        current = sentinel.session == session &&
            sentinel.sessionIdentity == captureObjectIdentity(session) &&
            sentinel->revision == expectedConfigurationRevision &&
            sentinel->mutationDepth == 0 &&
            (allowWhileConfigurationOpen || sentinel->depth == 0) &&
            objc_getAssociatedObject(
                session, &gCaptureSessionObserverAssociationKey) == observer;
    }
    return current;
}

CaptureSessionRescanResult authoritativeRescanCaptureSessionConnectionsOnce(
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer,
    uint64_t expectedConfigurationRevision,
    BOOL forceInactive,
    BOOL allowWhileConfigurationOpen) {
    IUSCMicCaptureSessionConfigurationSentinel *sentinel =
        ensureCaptureSessionConfigurationSentinel(session);
    if (!session || !observer || !sentinel ||
        expectedConfigurationRevision == 0) {
        return CaptureSessionRescanResult::Deferred;
    }
    if (!captureSessionRescanRevisionIsCurrent(
            sentinel, session, observer, expectedConfigurationRevision,
            allowWhileConfigurationOpen)) {
        return CaptureSessionRescanResult::Stale;
    }

    NSArray<AVCaptureOutput *> *outputs = nil;
    @try {
        outputs = session.outputs;
    } @catch (__unused NSException *exception) {
        applyCaptureSessionConfigurationDemand(
            session, observer, YES, nil);
        return CaptureSessionRescanResult::Deferred;
    }
    NSMutableSet *seenAssociations = [NSMutableSet set];
    NSMutableSet *unconfirmedOutputs = [NSMutableSet set];
    if (!seenAssociations || !unconfirmedOutputs) {
        applyCaptureSessionConfigurationDemand(
            session, observer, YES, nil);
        return CaptureSessionRescanResult::Deferred;
    }
    for (AVCaptureOutput *candidate in outputs) {
        if (!captureSessionRescanRevisionIsCurrent(
                sentinel, session, observer, expectedConfigurationRevision,
                allowWhileConfigurationOpen)) {
            return CaptureSessionRescanResult::Stale;
        }
        if (![candidate isKindOfClass:[AVCaptureAudioDataOutput class]]) {
            continue;
        }
        AVCaptureAudioDataOutput *output =
            (AVCaptureAudioDataOutput *)candidate;
        AVCaptureSession *exactSession = nil;
        IUSCMicCaptureSessionObserver *exactObserver = nil;
        uint64_t outputEpoch = 0;
        if (!snapshotExactCaptureOutputOwnership(
                output, &exactSession, &exactObserver, &outputEpoch) ||
            exactSession != session || exactObserver != observer) {
            if (!captureSessionRescanRevisionIsCurrent(
                    sentinel, session, observer,
                    expectedConfigurationRevision,
                    allowWhileConfigurationOpen)) {
                return CaptureSessionRescanResult::Stale;
            }
            @try {
                failCloseCaptureOutputForSession(output, session, observer);
            } @catch (__unused NSException *exception) {
            }
            continue;
        }
        NSArray<AVCaptureConnection *> *connections = nil;
        @try {
            connections = output.connections;
        } @catch (__unused NSException *exception) {
            [unconfirmedOutputs addObject:output];
            continue;
        }
        for (AVCaptureConnection *connection in connections) {
            if (!captureSessionRescanRevisionIsCurrent(
                    sentinel, session, observer,
                    expectedConfigurationRevision,
                    allowWhileConfigurationOpen)) {
                return CaptureSessionRescanResult::Stale;
            }
            IUSCMicCaptureConnectionAssociation *association =
                associateCaptureConnection(
                    connection, session, observer, output, YES, nil);
            if (!association || association.session != session ||
                association.output != output ||
                association.outputOwnershipEpoch != outputEpoch) {
                if (!captureSessionRescanRevisionIsCurrent(
                        sentinel, session, observer,
                        expectedConfigurationRevision,
                        allowWhileConfigurationOpen)) {
                    return CaptureSessionRescanResult::Stale;
                }
                [unconfirmedOutputs addObject:output];
                continue;
            }
            registerCaptureConnectionAssociation(association);
            [seenAssociations addObject:association];
        }
    }

    NSArray *registeredAssociations = nil;
    @synchronized(sentinel) {
        if (sentinel.session != session ||
            sentinel.sessionIdentity != captureObjectIdentity(session) ||
            sentinel->revision != expectedConfigurationRevision ||
            sentinel->mutationDepth != 0 ||
            (!allowWhileConfigurationOpen && sentinel->depth != 0) ||
            objc_getAssociatedObject(
                session, &gCaptureSessionObserverAssociationKey) != observer) {
            return CaptureSessionRescanResult::Stale;
        }
        registeredAssociations = sentinel.associations.allObjects;
    }
    for (IUSCMicCaptureConnectionAssociation *association in
            registeredAssociations) {
        if (!captureSessionRescanRevisionIsCurrent(
                sentinel, session, observer, expectedConfigurationRevision,
                allowWhileConfigurationOpen)) {
            return CaptureSessionRescanResult::Stale;
        }
        if (association.session == session &&
            association.sessionIdentity == captureObjectIdentity(session) &&
            ![seenAssociations containsObject:association]) {
            (void)clearCaptureConnectionAssociationTokenForRescan(
                association, session);
        }
    }

    @synchronized(sentinel) {
        if (sentinel.session != session ||
            sentinel.sessionIdentity != captureObjectIdentity(session) ||
            sentinel->revision != expectedConfigurationRevision ||
            sentinel->mutationDepth != 0 ||
            (!allowWhileConfigurationOpen && sentinel->depth != 0) ||
            objc_getAssociatedObject(
                session, &gCaptureSessionObserverAssociationKey) != observer) {
            return CaptureSessionRescanResult::Stale;
        }
        /* Clear the demand barrier before recomputing. A newer mutation either
         * makes the barrier dirty again before the observer reads it, or wins
         * with a later observer revision, so an old rescan cannot re-arm it. */
        if (sentinel->revision == expectedConfigurationRevision &&
            sentinel->depth == 0 && sentinel->mutationDepth == 0 &&
            !forceInactive) {
            sentinel->dirty = false;
        }
    }
    applyCaptureSessionConfigurationDemand(
        session, observer, forceInactive, unconfirmedOutputs);
    return CaptureSessionRescanResult::Committed;
}

BOOL authoritativeRescanCaptureSessionConnections(
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer,
    uint64_t expectedConfigurationRevision,
    BOOL forceInactive,
    BOOL allowWhileConfigurationOpen) {
    IUSCMicCaptureSessionConfigurationSentinel *sentinel =
        ensureCaptureSessionConfigurationSentinel(session);
    uint64_t revision = expectedConfigurationRevision;
    for (unsigned attempt = 0; attempt < 3; ++attempt) {
        const CaptureSessionRescanResult result =
            authoritativeRescanCaptureSessionConnectionsOnce(
                session, observer, revision, forceInactive,
                allowWhileConfigurationOpen);
        if (result == CaptureSessionRescanResult::Committed) return YES;
        if (result == CaptureSessionRescanResult::Deferred || !sentinel) {
            return NO;
        }
        @synchronized(sentinel) {
            if (sentinel.session != session ||
                sentinel.sessionIdentity != captureObjectIdentity(session) ||
                sentinel->mutationDepth != 0 ||
                (!allowWhileConfigurationOpen && sentinel->depth != 0) ||
                objc_getAssociatedObject(
                    session, &gCaptureSessionObserverAssociationKey) != observer) {
                return NO;
            }
            revision = sentinel->revision;
        }
    }
    return NO;
}

uint64_t markCaptureSessionConfigurationDirty(
    AVCaptureSession *session,
    BOOL incrementConfigurationDepth,
    BOOL incrementMutationDepth) {
    IUSCMicCaptureSessionConfigurationSentinel *sentinel =
        ensureCaptureSessionConfigurationSentinel(session);
    if (!sentinel) return 0;
    uint64_t result = 0;
    @synchronized(sentinel) {
        if (sentinel.session != session ||
            sentinel.sessionIdentity != captureObjectIdentity(session)) return 0;
        if (incrementConfigurationDepth) ++sentinel->depth;
        if (incrementMutationDepth) ++sentinel->mutationDepth;
        sentinel->dirty = true;
        sentinel->revision =
            nextCaptureSessionStateRevision(sentinel->revision);
        result = sentinel->revision;
    }
    return result;
}

void beginCaptureSessionConfigurationScope(
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer) {
    (void)markCaptureSessionConfigurationDirty(session, YES, NO);
    @try {
        (void)setCaptureSessionDemandForObserver(session, observer, false);
    } @catch (__unused NSException *exception) {
    }
}

void finishCaptureSessionConfigurationScope(
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer,
    BOOL operationSucceeded,
    BOOL wasBeginOperation) {
    IUSCMicCaptureSessionConfigurationSentinel *sentinel =
        ensureCaptureSessionConfigurationSentinel(session);
    if (!sentinel) return;
    uint64_t scanRevision = 0;
    BOOL shouldScan = NO;
    BOOL allowOpen = NO;
    @synchronized(sentinel) {
        if (sentinel.session != session ||
            sentinel.sessionIdentity != captureObjectIdentity(session)) return;
        if (wasBeginOperation && operationSucceeded) return;
        if (sentinel->depth != 0) --sentinel->depth;
        sentinel->dirty = true;
        sentinel->revision =
            nextCaptureSessionStateRevision(sentinel->revision);
        scanRevision = sentinel->revision;
        shouldScan = sentinel->mutationDepth == 0 &&
            (sentinel->depth == 0 || !operationSucceeded);
        allowOpen = !operationSucceeded;
    }
    if (shouldScan) {
        (void)authoritativeRescanCaptureSessionConnections(
            session, observer, scanRevision, !operationSucceeded, allowOpen);
    }
}

void beginCaptureSessionTopologyMutation(
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer) {
    (void)markCaptureSessionConfigurationDirty(session, NO, YES);
    @try {
        (void)setCaptureSessionDemandForObserver(session, observer, false);
    } @catch (__unused NSException *exception) {
    }
}

void finishCaptureSessionTopologyMutation(
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer,
    BOOL operationSucceeded) {
    IUSCMicCaptureSessionConfigurationSentinel *sentinel =
        ensureCaptureSessionConfigurationSentinel(session);
    if (!sentinel) return;
    uint64_t scanRevision = 0;
    BOOL shouldScan = NO;
    @synchronized(sentinel) {
        if (sentinel.session != session ||
            sentinel.sessionIdentity != captureObjectIdentity(session)) return;
        if (sentinel->mutationDepth != 0) --sentinel->mutationDepth;
        sentinel->dirty = true;
        sentinel->revision =
            nextCaptureSessionStateRevision(sentinel->revision);
        scanRevision = sentinel->revision;
        shouldScan = sentinel->depth == 0 && sentinel->mutationDepth == 0;
    }
    if (shouldScan) {
        (void)authoritativeRescanCaptureSessionConnections(
            session, observer, scanRevision, NO, NO);
    }
    (void)operationSucceeded;
}

void markCaptureSessionConnectionOperationDirty(
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer) {
    beginCaptureSessionTopologyMutation(session, observer);
}

void finishCaptureSessionConnectionOperation(
    AVCaptureSession *session,
    IUSCMicCaptureSessionObserver *observer,
    BOOL operationSucceeded) {
    finishCaptureSessionTopologyMutation(
        session, observer, operationSucceeded);
}

bool zeroSampleBufferPayload(CMSampleBufferRef sampleBuffer) {
    if (!sampleBuffer) return false;
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!block) return false;
    const size_t length = CMBlockBufferGetDataLength(block);
    if (length == 0) return true;
    return CMBlockBufferFillDataBytes(0, block, 0, length) == kCMBlockBufferNoErr;
}

bool fillRemoteSampleBufferPayload(CMSampleBufferRef sampleBuffer,
                                   IUSCMicReadCursor *cursor) {
    if (!sampleBuffer || !cursor) return false;
    if (!IUSCMicDemandIsActive()) return true;
    if (!IUSCMicStreamIsActive()) return true;

    CMFormatDescriptionRef description =
        CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!description ||
        CMFormatDescriptionGetMediaType(description) != kCMMediaType_Audio) {
        return true;
    }
    const AudioStreamBasicDescription *format =
        CMAudioFormatDescriptionGetStreamBasicDescription(
            (CMAudioFormatDescriptionRef)description);
    if (!format || format->mFormatID != kAudioFormatLinearPCM ||
        (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0 ||
        format->mBytesPerFrame == 0 || format->mChannelsPerFrame == 0) {
        return true;
    }

    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
    const size_t blockLength = CMBlockBufferGetDataLength(block);
    const CMItemCount sampleCount = CMSampleBufferGetNumSamples(sampleBuffer);
    if (sampleCount <= 0 || sampleCount > UINT32_MAX) return true;
    const uint64_t required64 =
        (uint64_t)sampleCount * (uint64_t)format->mBytesPerFrame;
    if (required64 == 0 || required64 > blockLength || required64 > UINT32_MAX ||
        !CMBlockBufferIsRangeContiguous(block, 0, (size_t)required64)) {
        return true;
    }

    size_t lengthAtOffset = 0;
    size_t totalLength = 0;
    char *bytes = nullptr;
    if (CMBlockBufferGetDataPointer(block, 0, &lengthAtOffset,
                                    &totalLength, &bytes) != kCMBlockBufferNoErr ||
        !bytes || lengthAtOffset < required64 || totalLength < required64) {
        return true;
    }

    AudioBufferList list = {};
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = format->mChannelsPerFrame;
    list.mBuffers[0].mDataByteSize = (UInt32)required64;
    list.mBuffers[0].mData = bytes;
    (void)IUSCMicFillAudioBufferList(
        &list, (UInt32)sampleCount, format, cursor);
    return true;
}

Class classDeclaringSelector(Class cls, SEL selector) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        unsigned methodCount = 0;
        Method *methods = class_copyMethodList(current, &methodCount);
        bool found = false;
        for (unsigned i = 0; i < methodCount; ++i) {
            if (method_getName(methods[i]) == selector) {
                found = true;
                break;
            }
        }
        free(methods);
        if (found) return current;
    }
    return Nil;
}

bool hookAudioDelegateClass(Class cls) {
    if (!cls) return false;
    SEL callbackSelector =
        @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    Class hookClass = classDeclaringSelector(cls, callbackSelector);
    if (!hookClass) return false;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gHookedDelegateClasses = [NSMutableSet new]; });
    if (!gHookedDelegateClasses) return false;
    @synchronized(gHookedDelegateClasses) {
        if ([gHookedDelegateClasses containsObject:hookClass]) return true;

        __block void (*original)(id, SEL, AVCaptureOutput *,
                                 CMSampleBufferRef,
                                 AVCaptureConnection *) = nullptr;
        IMP replacement = imp_implementationWithBlock(
            ^(id object, AVCaptureOutput *output,
              CMSampleBufferRef sampleBuffer,
              AVCaptureConnection *connection) {
                requireCriticalCHooksReady();
                bool deliverSample = true;
                if ([output isKindOfClass:
                        [AVCaptureAudioDataOutput class]]) {
                    /* Clear original storage before any binding lookup. */
                    deliverSample = zeroSampleBufferPayload(sampleBuffer);
                    IUSCMicCaptureCursorBox *box =
                        tryCaptureBindingForCallback(
                            object,
                            (AVCaptureAudioDataOutput *)output);
                    /*
                     * Lookup succeeds only for the output sentinel's exact
                     * active generation. Pending generations and callbacks
                     * from every retired queue/generation remain silent.
                     */
                    const bool captureActive = deliverSample &&
                        armCaptureBoxFromCallback(box);
                    if (captureActive && box &&
                        !box->cursorBusy.test_and_set(
                            std::memory_order_acquire)) {
                        if (!box->retired.load(
                                std::memory_order_acquire) &&
                            box->demandActive.load(
                                std::memory_order_acquire)) {
                            deliverSample = fillRemoteSampleBufferPayload(
                                sampleBuffer, &box->cursor);
                        }
                        box->cursorBusy.clear(
                            std::memory_order_release);
                    }
                }
                if (!deliverSample) {
                    return;
                }
                if (original) {
                    original(object, callbackSelector,
                             output, sampleBuffer, connection);
                }
            });
        if (!replacement) {
            return false;
        }
        MSHookMessageEx(
            hookClass,
            callbackSelector,
            replacement,
            reinterpret_cast<IMP *>(&original));
        if (!original) {
            return false;
        }
        /* Publish readiness only after MSHookMessageEx and original IMP finish. */
        [gHookedDelegateClasses addObject:hookClass];
        return true;
    }
}

bool replaceSynchronizedAudioCollection(
    id callbackObject,
    AVCaptureDataOutputSynchronizer *synchronizer,
    AVCaptureSynchronizedDataCollection *collection) {
    if (!synchronizer || !collection) return false;
    IUSCMicSynchronizerSentinel *sentinel = objc_getAssociatedObject(
        synchronizer, &gCaptureSynchronizerSentinelAssociationKey);
    bool deliverCollection = true;
    NSArray<AVCaptureOutput *> *outputs = nil;
    @try {
        outputs = synchronizer.dataOutputs;
    } @catch (__unused NSException *exception) {
        return false;
    }

    for (AVCaptureOutput *candidate in outputs) {
        if (![candidate isKindOfClass:[AVCaptureAudioDataOutput class]]) {
            /* MovieFile/LivePhoto/video/metadata entities are never modified. */
            continue;
        }
        AVCaptureAudioDataOutput *output =
            (AVCaptureAudioDataOutput *)candidate;
        CMSampleBufferRef sampleBuffer = nullptr;
        @try {
            AVCaptureSynchronizedData *data =
                [collection synchronizedDataForCaptureOutput:output];
            if (![data isKindOfClass:
                    [AVCaptureSynchronizedSampleBufferData class]]) {
                continue;
            }
            AVCaptureSynchronizedSampleBufferData *sampleData =
                (AVCaptureSynchronizedSampleBufferData *)data;
            if (sampleData.sampleBufferWasDropped) {
                continue;
            }
            sampleBuffer = sampleData.sampleBuffer;
        } @catch (__unused NSException *exception) {
            deliverCollection = false;
            continue;
        }

        /* The collection owns the real entity; clear it before any lookup. */
        if (!sampleBuffer || !zeroSampleBufferPayload(sampleBuffer)) {
            deliverCollection = false;
            continue;
        }
        IUSCMicCaptureCursorBox *box =
            [sentinel tryBindingForOutput:output
                           callbackObject:callbackObject];
        const bool captureActive = armCaptureBoxFromCallback(box);
        if (captureActive && box &&
            !box->cursorBusy.test_and_set(std::memory_order_acquire)) {
            if (!box->retired.load(std::memory_order_acquire) &&
                box->demandActive.load(std::memory_order_acquire)) {
                if (!fillRemoteSampleBufferPayload(
                        sampleBuffer, &box->cursor)) {
                    deliverCollection = false;
                }
            }
            box->cursorBusy.clear(std::memory_order_release);
        }
    }
    return deliverCollection;
}

bool hookSynchronizerDelegateClass(Class cls) {
    if (!cls) return false;
    SEL callbackSelector = @selector(
        dataOutputSynchronizer:didOutputSynchronizedDataCollection:);
    Class hookClass = classDeclaringSelector(cls, callbackSelector);
    if (!hookClass) return false;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gHookedSynchronizerDelegateClasses = [NSMutableSet new];
    });
    if (!gHookedSynchronizerDelegateClasses) return false;
    @synchronized(gHookedSynchronizerDelegateClasses) {
        if ([gHookedSynchronizerDelegateClasses containsObject:hookClass]) {
            return true;
        }
        __block void (*original)(
            id, SEL, AVCaptureDataOutputSynchronizer *,
            AVCaptureSynchronizedDataCollection *) = nullptr;
        IMP replacement = imp_implementationWithBlock(
            ^(id object, AVCaptureDataOutputSynchronizer *synchronizer,
              AVCaptureSynchronizedDataCollection *collection) {
                requireCriticalCHooksReady();
                const bool deliverCollection =
                    replaceSynchronizedAudioCollection(
                        object, synchronizer, collection);
                if (deliverCollection && original) {
                    original(object, callbackSelector,
                             synchronizer, collection);
                }
            });
        if (!replacement) return false;
        MSHookMessageEx(hookClass, callbackSelector, replacement,
                        reinterpret_cast<IMP *>(&original));
        if (!original) return false;
        [gHookedSynchronizerDelegateClasses addObject:hookClass];
        return true;
    }
}

bool captureSessionCanDemand(AVCaptureSession *session) {
    return session && session.isRunning && !session.isInterrupted &&
        !captureSessionConfigurationIsOpen(session);
}

void ensureCaptureSessionObserver(AVCaptureSession *session) {
    if (!session) return;
    if (objc_getAssociatedObject(
            session, &gCaptureSessionObserverAssociationKey)) {
        (void)ensureCaptureSessionConfigurationSentinel(session);
        return;
    }
    @synchronized(session) {
        if (!objc_getAssociatedObject(
                session, &gCaptureSessionObserverAssociationKey)) {
            IUSCMicCaptureSessionObserver *observer =
                [[IUSCMicCaptureSessionObserver alloc] initWithSession:session];
            objc_setAssociatedObject(
                session, &gCaptureSessionObserverAssociationKey, observer,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    (void)ensureCaptureSessionConfigurationSentinel(session);
}

IUSCMicSynchronizerSentinel *ensureSynchronizerSentinel(
    AVCaptureDataOutputSynchronizer *synchronizer) {
    if (!synchronizer) return nil;
    IUSCMicSynchronizerSentinel *sentinel = objc_getAssociatedObject(
        synchronizer, &gCaptureSynchronizerSentinelAssociationKey);
    if ([sentinel isPublishedForSynchronizer:synchronizer]) return sentinel;
    @synchronized(synchronizer) {
        sentinel = objc_getAssociatedObject(
            synchronizer, &gCaptureSynchronizerSentinelAssociationKey);
        if ([sentinel isPublishedForSynchronizer:synchronizer]) {
            return sentinel;
        }
        if (sentinel) {
            /* A recursive observer may see construction, but must not use it. */
            if (sentinel->publicationState.load(
                    std::memory_order_acquire) ==
                    kSynchronizerPublicationConstructing) {
                return nil;
            }
            if (objc_getAssociatedObject(
                    synchronizer,
                    &gCaptureSynchronizerSentinelAssociationKey) == sentinel) {
                objc_setAssociatedObject(
                    synchronizer,
                    &gCaptureSynchronizerSentinelAssociationKey,
                    nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            sentinel = nil;
        }

        NSArray<AVCaptureOutput *> *outputs = nil;
        @try {
            outputs = synchronizer.dataOutputs;
        } @catch (__unused NSException *exception) {
            return nil;
        }
        IUSCMicSynchronizerSentinel *candidate =
            [[IUSCMicSynchronizerSentinel alloc]
                initWithSynchronizer:synchronizer dataOutputs:outputs];
        if (!candidate) return nil;

        /* Publish the sentinel first. Marker publication validates this exact
         * association under each output monitor before exposing any owner. */
        objc_setAssociatedObject(
            synchronizer, &gCaptureSynchronizerSentinelAssociationKey,
            candidate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        BOOL published = NO;
        @try {
            published = [candidate publishOutputMarkersForDataOutputs:outputs];
        } @catch (NSException *exception) {
            [candidate unpublishOutputMarkers];
            if (objc_getAssociatedObject(
                    synchronizer,
                    &gCaptureSynchronizerSentinelAssociationKey) == candidate) {
                objc_setAssociatedObject(
                    synchronizer,
                    &gCaptureSynchronizerSentinelAssociationKey,
                    nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            @throw exception;
        }
        if (!published) {
            [candidate unpublishOutputMarkers];
            if (objc_getAssociatedObject(
                    synchronizer,
                    &gCaptureSynchronizerSentinelAssociationKey) == candidate) {
                objc_setAssociatedObject(
                    synchronizer,
                    &gCaptureSynchronizerSentinelAssociationKey,
                    nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            return nil;
        }
        sentinel = candidate;
    }
    return sentinel;
}

} // namespace

static void retireDirectCaptureBindingForDelegateDealloc(
    IUSCMicCaptureCursorBox *binding,
    uintptr_t expectedCallbackIdentity) {
    if (!binding || expectedCallbackIdentity == 0 ||
        binding->callbackIdentity != expectedCallbackIdentity) {
        return;
    }
    setCaptureBoxLifecycle(binding, false);
    AVCaptureAudioDataOutput *output = binding.output;
    if (!output || binding->outputIdentity != captureObjectIdentity(output)) {
        return;
    }
    IUSCMicCaptureOutputSentinel *sentinel = objc_getAssociatedObject(
        output, &gCaptureOutputSentinelAssociationKey);
    if (!sentinel ||
        binding->directOutputSentinelIdentity != captureObjectIdentity(sentinel)) {
        return;
    }
    os_unfair_lock_lock(&sentinel->stateLock);
    if (sentinel.output == output &&
        sentinel->outputIdentity == captureObjectIdentity(output) &&
        objc_getAssociatedObject(
            output, &gCaptureOutputSentinelAssociationKey) == sentinel &&
        sentinel.currentBinding == binding &&
        sentinel->delegateIdentity == expectedCallbackIdentity &&
        binding->directBindingGeneration != 0 &&
        (sentinel->pendingBindingGeneration ==
             binding->directBindingGeneration ||
         sentinel->activeBindingGeneration ==
             binding->directBindingGeneration)) {
        setCaptureBoxLifecycle(binding, false);
        sentinel.currentBinding = nil;
        sentinel.delegate = nil;
        sentinel->delegateIdentity = 0;
        sentinel->delegateQueue = nil;
        sentinel->delegateQueueIdentity = 0;
        sentinel->pendingBindingGeneration = 0;
        sentinel->activeBindingGeneration = 0;
    }
    os_unfair_lock_unlock(&sentinel->stateLock);
}

@implementation IUSCMicCaptureDelegateSentinel

- (instancetype)init {
    self = [super init];
    if (self) {
        bindingLock = OS_UNFAIR_LOCK_INIT;
        self.directBindings = [NSMutableSet new];
    }
    return self;
}

- (BOOL)trackDirectBinding:(IUSCMicCaptureCursorBox *)binding
             callbackObject:(id)callbackObject {
    if (!binding || !callbackObject ||
        callbackIdentity != captureObjectIdentity(callbackObject) ||
        binding.callbackObject != callbackObject ||
        binding->callbackIdentity != callbackIdentity) {
        return NO;
    }
    os_unfair_lock_lock(&bindingLock);
    [self.directBindings addObject:binding];
    os_unfair_lock_unlock(&bindingLock);
    binding.delegateSentinel = self;
    return YES;
}

- (void)untrackDirectBinding:(IUSCMicCaptureCursorBox *)binding {
    if (!binding) return;
    os_unfair_lock_lock(&bindingLock);
    [self.directBindings removeObject:binding];
    os_unfair_lock_unlock(&bindingLock);
    if (binding.delegateSentinel == self) {
        binding.delegateSentinel = nil;
    }
}

- (BOOL)trackSynchronizerSentinel:(IUSCMicSynchronizerSentinel *)sentinel {
    if (!sentinel) return NO;
    BOOL tracked = NO;
    os_unfair_lock_lock(&bindingLock);
    size_t emptyIndex = 64;
    for (size_t i = 0; i < 64; ++i) {
        IUSCMicSynchronizerSentinel *candidate = synchronizerSentinels[i];
        if (candidate == sentinel) {
            tracked = YES;
            break;
        }
        if (!candidate && emptyIndex == 64) emptyIndex = i;
    }
    if (!tracked && emptyIndex < 64) {
        synchronizerSentinels[emptyIndex] = sentinel;
        tracked = YES;
    }
    os_unfair_lock_unlock(&bindingLock);
    return tracked;
}

- (void)dealloc {
    __strong IUSCMicSynchronizerSentinel *synchronizerSnapshot[64] = {};
    os_unfair_lock_lock(&bindingLock);
    NSArray *liveBindings = self.directBindings.allObjects;
    [self.directBindings removeAllObjects];
    for (size_t i = 0; i < 64; ++i) {
        synchronizerSnapshot[i] = synchronizerSentinels[i];
        synchronizerSentinels[i] = nil;
    }
    os_unfair_lock_unlock(&bindingLock);
    for (IUSCMicCaptureCursorBox *binding in liveBindings) {
        binding.delegateSentinel = nil;
        retireDirectCaptureBindingForDelegateDealloc(
            binding, callbackIdentity);
    }
    for (size_t i = 0; i < 64; ++i) {
        [synchronizerSnapshot[i] retireDelegateIdentity:callbackIdentity];
    }
}

@end

@implementation IUSCMicCaptureOutputSentinel

- (instancetype)init {
    self = [super init];
    if (self) {
        stateLock = OS_UNFAIR_LOCK_INIT;
        lifecycleKnown = false;
        lifecycleActive = false;
        lifecycleRevision = 1;
        lifecycleSessionIdentity = 0;
        lifecycleObserverIdentity = 0;
        lifecycleOutputEpoch = 0;
        outputIdentity = 0;
        delegateSetterInFlight = 0;
        delegateCompletionRevision = 1;
        delegateTransactionGeneration = 1;
        delegateBindingGenerationCounter = 1;
        pendingBindingGeneration = 0;
        activeBindingGeneration = 0;
        delegateIdentity = 0;
        delegateQueueIdentity = 0;
        delegateTransactionUnsafe = false;
        delegateDrainPermanentlyUnsafe.store(
            false, std::memory_order_relaxed);
        delegateDrainGroup = dispatch_group_create();
    }
    return self;
}

- (void)dealloc {
    os_unfair_lock_lock(&stateLock);
    IUSCMicCaptureCursorBox *binding = self.currentBinding;
    setCaptureBoxLifecycle(binding, false);
    self.currentBinding = nil;
    self.delegate = nil;
    delegateQueue = nil;
    pendingBindingGeneration = 0;
    activeBindingGeneration = 0;
    os_unfair_lock_unlock(&stateLock);
    IUSCMicCaptureDelegateSentinel *delegateSentinel =
        binding.delegateSentinel;
    [delegateSentinel untrackDirectBinding:binding];
}

@end

@implementation IUSCMicCaptureSessionOutputOwnership
@end

@implementation IUSCMicCaptureConnectionOperation

- (void)dealloc {
    (void)completeCaptureConnectionOperation(self, NO);
}

@end

@implementation IUSCMicCaptureSessionConfigurationSentinel

- (instancetype)init {
    self = [super init];
    if (self) {
        depth = 0;
        mutationDepth = 0;
        revision = 1;
        dirty = false;
        self.associations = [NSHashTable weakObjectsHashTable];
    }
    return self;
}

@end

@implementation IUSCMicCaptureConnectionAssociation

- (instancetype)init {
    self = [super init];
    if (self) {
        retired.store(false, std::memory_order_relaxed);
        inFlightOperations.store(0, std::memory_order_relaxed);
        completionRevision = 1;
    }
    return self;
}

- (void)dealloc {
    retireCaptureConnectionAssociationOnDealloc(self);
}

@end

static BOOL synchronizerOutputIsAuthoritativelyActiveLocked(
    AVCaptureAudioDataOutput *output) {
    if (!output) return NO;
    AVCaptureSession *session = nil;
    IUSCMicCaptureSessionObserver *observer = nil;
    uint64_t epoch = 0;
    if (!snapshotExactCaptureOutputOwnership(
            output, &session, &observer, &epoch) || epoch == 0) {
        return NO;
    }
    IUSCMicCaptureOutputSentinel *outputSentinel =
        ensureCaptureOutputSentinel(output);
    /* Activation barriers require a current topology read, not a cached edge. */
    BOOL activeState = NO;
    @try {
        activeState = captureSessionCanDemand(session) &&
            captureOutputIsActive(output);
    } @catch (__unused NSException *exception) {
        activeState = NO;
    }
    if (outputSentinel) {
        os_unfair_lock_lock(&outputSentinel->stateLock);
        if (outputSentinel.output == output &&
            outputSentinel->outputIdentity == captureObjectIdentity(output) &&
            objc_getAssociatedObject(
                output, &gCaptureOutputSentinelAssociationKey) ==
                    outputSentinel) {
            outputSentinel->lifecycleKnown = true;
            outputSentinel->lifecycleActive = activeState;
            outputSentinel->lifecycleRevision =
                nextCaptureSessionStateRevision(
                    outputSentinel->lifecycleRevision);
            outputSentinel->lifecycleSessionIdentity =
                captureObjectIdentity(session);
            outputSentinel->lifecycleObserverIdentity =
                captureObjectIdentity(observer);
            outputSentinel->lifecycleOutputEpoch = epoch;
        } else {
            activeState = NO;
        }
        os_unfair_lock_unlock(&outputSentinel->stateLock);
    }
    return activeState;
}

static BOOL synchronizerMarkerHasLiveExactOwnerLocked(
    IUSCMicSynchronizerOutputMarker *marker,
    AVCaptureAudioDataOutput *output) {
    if (!marker || !output || marker.output != output ||
        marker.outputIdentity != captureObjectIdentity(output)) return NO;
    IUSCMicSynchronizerSentinel *sentinel = marker.sentinel;
    AVCaptureDataOutputSynchronizer *synchronizer = marker.synchronizer;
    if (!sentinel || !synchronizer ||
        marker.sentinelIdentity != captureObjectIdentity(sentinel) ||
        marker.synchronizerIdentity != captureObjectIdentity(synchronizer) ||
        objc_getAssociatedObject(
            synchronizer, &gCaptureSynchronizerSentinelAssociationKey) !=
                sentinel) {
        return NO;
    }
    return [sentinel ownsOutput:output
                         marker:marker
                          index:marker.outputIndex];
}

@implementation IUSCMicSynchronizerOutputMarker

- (instancetype)init {
    self = [super init];
    if (self) {
        active.store(false, std::memory_order_relaxed);
    }
    return self;
}

- (void)dealloc {
    IUSCMicSynchronizerSentinel *exactSentinel = self.sentinel;
    [exactSentinel retireOutputAtIndex:self.outputIndex marker:self];
}

@end

@implementation IUSCMicSynchronizerSentinel

- (instancetype)initWithSynchronizer:(AVCaptureDataOutputSynchronizer *)synchronizer
                         dataOutputs:(NSArray<AVCaptureOutput *> *)dataOutputs {
    self = [super init];
    if (!self || !synchronizer || !dataOutputs) return nil;
    outputLock = OS_UNFAIR_LOCK_INIT;
    publicationState.store(
        kSynchronizerPublicationConstructing, std::memory_order_relaxed);
    delegateSetterInFlight = 0;
    delegateCompletionRevision = 1;
    delegateTransactionGeneration = 1;
    delegateBindingGenerationCounter = 1;
    pendingBindingGeneration = 0;
    activeBindingGeneration = 0;
    delegateQueueIdentity = 0;
    delegateTransactionUnsafe = false;
    delegateDrainPermanentlyUnsafe.store(
        false, std::memory_order_relaxed);
    delegateDrainGroup = dispatch_group_create();
    delegateQueue = nil;
    if (!delegateDrainGroup) return nil;
    synchronizerIdentity = captureObjectIdentity(synchronizer);
    self.synchronizer = synchronizer;

    NSMutableSet *seenAudioOutputs = [NSMutableSet set];
    if (!seenAudioOutputs) return nil;
    size_t audioCount = 0;
    for (AVCaptureOutput *candidate in dataOutputs) {
        if (![candidate isKindOfClass:[AVCaptureAudioDataOutput class]]) {
            continue;
        }
        if (++audioCount > 64 ||
            [seenAudioOutputs containsObject:candidate]) {
            return nil;
        }
        [seenAudioOutputs addObject:candidate];
    }
    outputCount = audioCount;
    return self;
}

- (BOOL)isPublishedForSynchronizer:
            (AVCaptureDataOutputSynchronizer *)synchronizer {
    return synchronizer && self.synchronizer == synchronizer &&
        synchronizerIdentity == captureObjectIdentity(synchronizer) &&
        publicationState.load(std::memory_order_acquire) ==
            kSynchronizerPublicationReady &&
        objc_getAssociatedObject(
            synchronizer, &gCaptureSynchronizerSentinelAssociationKey) == self;
}

- (BOOL)ownsOutput:(AVCaptureAudioDataOutput *)output
            marker:(IUSCMicSynchronizerOutputMarker *)marker
             index:(NSUInteger)index {
    if (!output || !marker || index >= 64) return NO;
    BOOL owns = NO;
    os_unfair_lock_lock(&outputLock);
    owns = publicationState.load(std::memory_order_acquire) !=
            kSynchronizerPublicationFailed &&
        index < outputCount && audioOutputs[index] == output &&
        outputMarkers[index] == marker && marker.sentinel == self &&
        marker.sentinelIdentity == captureObjectIdentity(self) &&
        marker.output == output &&
        marker.outputIdentity == captureObjectIdentity(output);
    os_unfair_lock_unlock(&outputLock);
    return owns;
}

- (BOOL)publishOutputMarkersForDataOutputs:
            (NSArray<AVCaptureOutput *> *)dataOutputs {
    AVCaptureDataOutputSynchronizer *owner = self.synchronizer;
    if (!owner || synchronizerIdentity != captureObjectIdentity(owner) ||
        objc_getAssociatedObject(
            owner, &gCaptureSynchronizerSentinelAssociationKey) != self ||
        publicationState.load(std::memory_order_acquire) !=
            kSynchronizerPublicationConstructing) {
        publicationState.store(
            kSynchronizerPublicationFailed, std::memory_order_release);
        return NO;
    }

    __strong AVCaptureAudioDataOutput *publishedOutputs[64] = {};
    __strong IUSCMicSynchronizerOutputMarker *publishedMarkers[64] = {};
    size_t publishedCount = 0;
    BOOL succeeded = YES;
    NSMutableArray<AVCaptureAudioDataOutput *> *audioOutputsToPublish =
        [NSMutableArray arrayWithCapacity:outputCount];
    if (!audioOutputsToPublish) {
        publicationState.store(
            kSynchronizerPublicationFailed, std::memory_order_release);
        return NO;
    }
    for (AVCaptureOutput *candidate in dataOutputs) {
        if ([candidate isKindOfClass:[AVCaptureAudioDataOutput class]]) {
            [audioOutputsToPublish addObject:
                (AVCaptureAudioDataOutput *)candidate];
        }
    }
    [audioOutputsToPublish sortUsingComparator:
        ^NSComparisonResult(AVCaptureAudioDataOutput *left,
                            AVCaptureAudioDataOutput *right) {
        const uintptr_t leftIdentity = captureObjectIdentity(left);
        const uintptr_t rightIdentity = captureObjectIdentity(right);
        if (leftIdentity < rightIdentity) return NSOrderedAscending;
        if (leftIdentity > rightIdentity) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    /* Resolve weak connection associations before the linearized active read.
     * This runs lock-free with respect to output/sentinel publication. */
    for (AVCaptureAudioDataOutput *output in audioOutputsToPublish) {
        associateCaptureConnectionsForOutputFromCurrentOwner(output);
    }
    for (AVCaptureAudioDataOutput *output in audioOutputsToPublish) {
        const NSUInteger index = publishedCount;
        IUSCMicSynchronizerOutputMarker *newMarker =
            [IUSCMicSynchronizerOutputMarker new];
        if (!newMarker || index >= outputCount || index >= 64) {
            succeeded = NO;
            break;
        }

        BOOL claimed = NO;
        @synchronized(output) {
            IUSCMicSynchronizerOutputMarker *existing =
                objc_getAssociatedObject(
                    output, &gCaptureSynchronizerMarkerAssociationKey);
            if (synchronizerMarkerHasLiveExactOwnerLocked(existing, output) ||
                objc_getAssociatedObject(
                    owner, &gCaptureSynchronizerSentinelAssociationKey) != self ||
                publicationState.load(std::memory_order_acquire) !=
                    kSynchronizerPublicationConstructing) {
                claimed = NO;
            } else {
                const BOOL activeState =
                    synchronizerOutputIsAuthoritativelyActiveLocked(output);
                newMarker.synchronizer = owner;
                newMarker.sentinel = self;
                newMarker.output = output;
                newMarker.synchronizerIdentity =
                    captureObjectIdentity(owner);
                newMarker.sentinelIdentity = captureObjectIdentity(self);
                newMarker.outputIdentity = captureObjectIdentity(output);
                newMarker.outputIndex = index;
                newMarker->active.store(
                    activeState, std::memory_order_release);

                os_unfair_lock_lock(&outputLock);
                if (index < outputCount && !audioOutputs[index] &&
                    !outputMarkers[index] &&
                    publicationState.load(std::memory_order_acquire) ==
                        kSynchronizerPublicationConstructing) {
                    audioOutputs[index] = output;
                    outputMarkers[index] = newMarker;
                    outputActive[index] = activeState;
                    claimed = YES;
                }
                os_unfair_lock_unlock(&outputLock);
                if (claimed) {
                    objc_setAssociatedObject(
                        output, &gCaptureSynchronizerMarkerAssociationKey,
                        newMarker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            }
        }
        if (!claimed) {
            succeeded = NO;
            break;
        }
        publishedOutputs[publishedCount] = output;
        publishedMarkers[publishedCount] = newMarker;
        ++publishedCount;
    }

    if (!succeeded || publishedCount != outputCount) {
        publicationState.store(
            kSynchronizerPublicationFailed, std::memory_order_release);
        return NO;
    }

    /* Converge every published marker from the latest lifecycle state under
     * the output -> sentinel order. */
    for (size_t i = 0; i < publishedCount; ++i) {
        AVCaptureAudioDataOutput *output = publishedOutputs[i];
        IUSCMicSynchronizerOutputMarker *marker = publishedMarkers[i];
        @synchronized(output) {
            if (objc_getAssociatedObject(
                    output, &gCaptureSynchronizerMarkerAssociationKey) != marker ||
                !synchronizerMarkerHasLiveExactOwnerLocked(marker, output)) {
                succeeded = NO;
                continue;
            }
            const BOOL activeState =
                synchronizerOutputIsAuthoritativelyActiveLocked(output);
            [self setOutput:output
                     marker:marker
                      index:i
                     active:activeState];
        }
    }
    if (!succeeded) {
        publicationState.store(
            kSynchronizerPublicationFailed, std::memory_order_release);
        return NO;
    }

    os_unfair_lock_lock(&outputLock);
    BOOL complete = outputCount == publishedCount;
    for (size_t i = 0; complete && i < outputCount; ++i) {
        complete = audioOutputs[i] == publishedOutputs[i] &&
            outputMarkers[i] == publishedMarkers[i];
    }
    if (complete) {
        publicationState.store(
            kSynchronizerPublicationReady, std::memory_order_release);
    }
    os_unfair_lock_unlock(&outputLock);
    if (!complete) {
        publicationState.store(
            kSynchronizerPublicationFailed, std::memory_order_release);
    }
    return complete;
}

- (void)unpublishOutputMarkers {
    __strong AVCaptureAudioDataOutput *outputs[64] = {};
    __strong IUSCMicSynchronizerOutputMarker *markers[64] = {};
    size_t count = 0;
    os_unfair_lock_lock(&outputLock);
    publicationState.store(
        kSynchronizerPublicationFailed, std::memory_order_release);
    count = outputCount;
    for (size_t i = 0; i < count; ++i) {
        outputs[i] = audioOutputs[i];
        markers[i] = outputMarkers[i];
        outputActive[i] = false;
        setCaptureBoxLifecycle(bindings[i], false);
        bindings[i] = nil;
        audioOutputs[i] = nil;
        outputMarkers[i] = nil;
    }
    self.delegate = nil;
    delegateIdentity = 0;
    delegateQueue = nil;
    delegateQueueIdentity = 0;
    pendingBindingGeneration = 0;
    activeBindingGeneration = 0;
    os_unfair_lock_unlock(&outputLock);

    /* No sentinel lock is held while acquiring an output monitor. */
    for (size_t i = 0; i < count; ++i) {
        AVCaptureAudioDataOutput *output = outputs[i];
        IUSCMicSynchronizerOutputMarker *marker = markers[i];
        if (!output || !marker) continue;
        @synchronized(output) {
            if (objc_getAssociatedObject(
                    output, &gCaptureSynchronizerMarkerAssociationKey) == marker &&
                marker.sentinelIdentity == captureObjectIdentity(self) &&
                marker.outputIdentity == captureObjectIdentity(output) &&
                marker.outputIndex == i) {
                objc_setAssociatedObject(
                    output, &gCaptureSynchronizerMarkerAssociationKey,
                    nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
}

- (void)retireAllBindings {
    os_unfair_lock_lock(&outputLock);
    for (size_t i = 0; i < outputCount; ++i) {
        setCaptureBoxLifecycle(bindings[i], false);
        bindings[i] = nil;
    }
    self.delegate = nil;
    delegateIdentity = 0;
    delegateQueue = nil;
    delegateQueueIdentity = 0;
    pendingBindingGeneration = 0;
    activeBindingGeneration = 0;
    os_unfair_lock_unlock(&outputLock);
}

- (void)setOutput:(AVCaptureAudioDataOutput *)output
            marker:(IUSCMicSynchronizerOutputMarker *)marker
             index:(NSUInteger)index
            active:(BOOL)activeState {
    if (!output || !marker || index >= 64) return;
    os_unfair_lock_lock(&outputLock);
    if (publicationState.load(std::memory_order_acquire) !=
            kSynchronizerPublicationFailed &&
        index < outputCount && audioOutputs[index] == output &&
        outputMarkers[index] == marker && marker.sentinel == self &&
        marker.output == output) {
        outputActive[index] = activeState;
        marker->active.store(activeState, std::memory_order_release);
        IUSCMicCaptureCursorBox *binding = bindings[index];
        const BOOL bindingGenerationIsActive = binding &&
            activeBindingGeneration != 0 &&
            binding->synchronizerBindingGeneration == activeBindingGeneration;
        setCaptureBoxLifecycle(
            binding, bindingGenerationIsActive && activeState);
    }
    os_unfair_lock_unlock(&outputLock);
}

- (void)retireOutputAtIndex:(NSUInteger)index
                     marker:(IUSCMicSynchronizerOutputMarker *)marker {
    if (!marker || index >= 64) return;
    os_unfair_lock_lock(&outputLock);
    if (index < outputCount && outputMarkers[index] == marker) {
        outputActive[index] = false;
        setCaptureBoxLifecycle(bindings[index], false);
        bindings[index] = nil;
        audioOutputs[index] = nil;
        outputMarkers[index] = nil;
    }
    os_unfair_lock_unlock(&outputLock);
}

- (void)retireDelegateIdentity:(uintptr_t)identity {
    if (identity == 0) return;
    os_unfair_lock_lock(&outputLock);
    if (delegateIdentity == identity) {
        for (size_t i = 0; i < outputCount; ++i) {
            setCaptureBoxLifecycle(bindings[i], false);
            bindings[i] = nil;
        }
        self.delegate = nil;
        delegateIdentity = 0;
        delegateQueue = nil;
        delegateQueueIdentity = 0;
        pendingBindingGeneration = 0;
        activeBindingGeneration = 0;
    }
    os_unfair_lock_unlock(&outputLock);
}

- (IUSCMicCaptureCursorBox *)tryBindingForOutput:(AVCaptureAudioDataOutput *)output
                                  callbackObject:(id)callbackObject {
    if (!output || !callbackObject ||
        !os_unfair_lock_trylock(&outputLock)) {
        return nil;
    }
    IUSCMicCaptureCursorBox *result = nil;
    if (publicationState.load(std::memory_order_acquire) ==
            kSynchronizerPublicationReady &&
        activeBindingGeneration != 0 && self.delegate == callbackObject) {
        for (size_t i = 0; i < outputCount; ++i) {
            IUSCMicCaptureCursorBox *candidate = bindings[i];
            if (audioOutputs[i] == output && outputMarkers[i] &&
                candidate.callbackObject == callbackObject &&
                candidate.output == output &&
                candidate->synchronizerBindingGeneration ==
                    activeBindingGeneration) {
                result = candidate;
                break;
            }
        }
    }
    os_unfair_lock_unlock(&outputLock);
    return result;
}

- (void)dealloc {
    [self unpublishOutputMarkers];
}

@end

enum class SynchronizerDelegateConvergenceResult {
    Committed,
    Superseded,
    NeedsClear,
};

static BOOL synchronizerSentinelIsExactCurrent(
    AVCaptureDataOutputSynchronizer *synchronizer,
    IUSCMicSynchronizerSentinel *sentinel,
    BOOL requirePublished) {
    if (!synchronizer || !sentinel ||
        sentinel.synchronizer != synchronizer ||
        sentinel->synchronizerIdentity != captureObjectIdentity(synchronizer) ||
        objc_getAssociatedObject(
            synchronizer, &gCaptureSynchronizerSentinelAssociationKey) !=
                sentinel) {
        return NO;
    }
    return !requirePublished ||
        sentinel->publicationState.load(std::memory_order_acquire) ==
            kSynchronizerPublicationReady;
}

static void retireSynchronizerDelegateBindingsLocked(
    IUSCMicSynchronizerSentinel *sentinel) {
    if (!sentinel) return;
    for (size_t i = 0; i < sentinel->outputCount; ++i) {
        setCaptureBoxLifecycle(sentinel->bindings[i], false);
        sentinel->bindings[i] = nil;
    }
    sentinel.delegate = nil;
    sentinel->delegateIdentity = 0;
    sentinel->delegateQueue = nil;
    sentinel->delegateQueueIdentity = 0;
    sentinel->pendingBindingGeneration = 0;
    sentinel->activeBindingGeneration = 0;
}

static uintptr_t synchronizerDelegateQueueIdentity(dispatch_queue_t queue) {
    return queue
        ? reinterpret_cast<uintptr_t>((__bridge void *)queue)
        : 0;
}

static BOOL synchronizerDelegateQueueSupportsDrainBarrier(
    dispatch_queue_t queue);

/*
 * Apple exposes delegate and queue as separate nonatomic getters.  Two equal
 * reads, bracketed by the exact in-flight transaction checks at the caller,
 * are the minimum state that can be treated as one authoritative pair.  Both
 * observed queues are returned so even a torn read contributes a drain debt.
 */
static BOOL snapshotSynchronizerDelegateAndQueue(
    AVCaptureDataOutputSynchronizer *synchronizer,
    id __strong *delegateOut,
    dispatch_queue_t __strong *queueOut,
    dispatch_queue_t __strong *alternateQueueOut) {
    if (delegateOut) *delegateOut = nil;
    if (queueOut) *queueOut = nil;
    if (alternateQueueOut) *alternateQueueOut = nil;
    if (!synchronizer) return NO;

    id firstDelegate = nil;
    id secondDelegate = nil;
    dispatch_queue_t firstQueue = nil;
    dispatch_queue_t secondQueue = nil;
    @try {
        firstDelegate = synchronizer.delegate;
        firstQueue = synchronizer.delegateCallbackQueue;
        secondDelegate = synchronizer.delegate;
        secondQueue = synchronizer.delegateCallbackQueue;
    } @catch (__unused NSException *exception) {
        if (queueOut) *queueOut = firstQueue;
        if (alternateQueueOut && secondQueue != firstQueue) {
            *alternateQueueOut = secondQueue;
        }
        return NO;
    }
    if (queueOut) *queueOut = firstQueue;
    if (alternateQueueOut && secondQueue != firstQueue) {
        *alternateQueueOut = secondQueue;
    }
    const BOOL stable = firstDelegate == secondDelegate &&
        firstQueue == secondQueue &&
        ((!secondDelegate && !secondQueue) ||
         (secondDelegate && secondQueue &&
          synchronizerDelegateQueueSupportsDrainBarrier(secondQueue)));
    if (stable && delegateOut) *delegateOut = secondDelegate;
    return stable;
}

static BOOL synchronizerDelegateQueueSupportsDrainBarrier(
    dispatch_queue_t queue) {
    if (!queue) return NO;
    /* Barriers are not ordering barriers on libdispatch global root queues. */
    const long globalIdentifiers[] = {
        QOS_CLASS_USER_INTERACTIVE,
        QOS_CLASS_USER_INITIATED,
        QOS_CLASS_DEFAULT,
        QOS_CLASS_UTILITY,
        QOS_CLASS_BACKGROUND,
        DISPATCH_QUEUE_PRIORITY_HIGH,
        DISPATCH_QUEUE_PRIORITY_DEFAULT,
        DISPATCH_QUEUE_PRIORITY_LOW,
        DISPATCH_QUEUE_PRIORITY_BACKGROUND,
    };
    for (long identifier : globalIdentifiers) {
        if (queue == dispatch_get_global_queue(identifier, 0)) return NO;
    }
    const char *label = dispatch_queue_get_label(queue);
    return !label || strncmp(label, "com.apple.root.", 15) != 0;
}

/*
 * Debt is global to the sentinel, not to a completion token.  Therefore an
 * obsolete Q0->Q1 operation can lose publication authority while its Q0/Q1
 * FIFO barriers still delay a later Q2 generation.  No setter synchronously
 * waits for a callback queue, including when invoked re-entrantly on that queue.
 */
static void recordSynchronizerDelegateQueueDebt(
    IUSCMicSynchronizerSentinel *sentinel,
    dispatch_group_t drainGroup,
    dispatch_queue_t queue) {
    if (!sentinel || !drainGroup || !queue) return;
    if (!synchronizerDelegateQueueSupportsDrainBarrier(queue)) {
        /* An unordered queue permanently disables activation for this owner. */
        sentinel->delegateDrainPermanentlyUnsafe.store(
            true, std::memory_order_release);
        return;
    }
    dispatch_group_enter(drainGroup);
    dispatch_barrier_async(queue, ^{
        dispatch_group_leave(drainGroup);
    });
}

static BOOL beginSynchronizerDelegateSetterOperation(
    AVCaptureDataOutputSynchronizer *synchronizer,
    IUSCMicSynchronizerSentinel *sentinel,
    uint64_t *transactionGenerationOut,
    dispatch_group_t __strong *drainGroupOut,
    dispatch_queue_t __strong *publishedQueueOut) {
    if (transactionGenerationOut) *transactionGenerationOut = 0;
    if (drainGroupOut) *drainGroupOut = nil;
    if (publishedQueueOut) *publishedQueueOut = nil;
    if (!synchronizerSentinelIsExactCurrent(
            synchronizer, sentinel, YES)) return NO;
    BOOL registered = NO;
    os_unfair_lock_lock(&sentinel->outputLock);
    if (synchronizerSentinelIsExactCurrent(
            synchronizer, sentinel, YES) &&
        sentinel->delegateSetterInFlight != UINT32_MAX) {
        if (sentinel->delegateSetterInFlight == 0) {
            sentinel->delegateTransactionGeneration =
                nextCaptureSessionStateRevision(
                    sentinel->delegateTransactionGeneration);
            sentinel->delegateTransactionUnsafe = false;
        }
        if (transactionGenerationOut) {
            *transactionGenerationOut =
                sentinel->delegateTransactionGeneration;
        }
        if (drainGroupOut) {
            *drainGroupOut = sentinel->delegateDrainGroup;
        }
        if (publishedQueueOut) {
            *publishedQueueOut = sentinel->delegateQueue;
        }
        ++sentinel->delegateSetterInFlight;
        /* Every old callback now resolves only a retired old generation. */
        retireSynchronizerDelegateBindingsLocked(sentinel);
        registered = YES;
    } else {
        retireSynchronizerDelegateBindingsLocked(sentinel);
    }
    os_unfair_lock_unlock(&sentinel->outputLock);
    return registered;
}

static uint64_t completeSynchronizerDelegateSetterOperation(
    AVCaptureDataOutputSynchronizer *synchronizer,
    IUSCMicSynchronizerSentinel *sentinel,
    BOOL registered,
    uint64_t expectedTransactionGeneration,
    BOOL queueSnapshotsSafe,
    BOOL *shouldConvergeOut) {
    if (shouldConvergeOut) *shouldConvergeOut = NO;
    if (!registered || !synchronizer || !sentinel) return 0;
    uint64_t revision = 0;
    os_unfair_lock_lock(&sentinel->outputLock);
    if (synchronizerSentinelIsExactCurrent(
            synchronizer, sentinel, YES) &&
        sentinel->delegateTransactionGeneration ==
            expectedTransactionGeneration &&
        sentinel->delegateSetterInFlight != 0) {
        if (!queueSnapshotsSafe) {
            sentinel->delegateTransactionUnsafe = true;
        }
        --sentinel->delegateSetterInFlight;
        sentinel->delegateCompletionRevision =
            nextCaptureSessionStateRevision(
                sentinel->delegateCompletionRevision);
        revision = sentinel->delegateCompletionRevision;
        if (shouldConvergeOut) {
            *shouldConvergeOut =
                sentinel->delegateSetterInFlight == 0;
        }
    }
    os_unfair_lock_unlock(&sentinel->outputLock);
    return revision;
}

static BOOL synchronizerDelegateCompletionIsCurrent(
    AVCaptureDataOutputSynchronizer *synchronizer,
    IUSCMicSynchronizerSentinel *sentinel,
    uint64_t expectedTransactionGeneration,
    uint64_t expectedCompletionRevision) {
    if (!synchronizer || !sentinel ||
        expectedTransactionGeneration == 0 ||
        expectedCompletionRevision == 0) {
        return NO;
    }
    BOOL current = NO;
    os_unfair_lock_lock(&sentinel->outputLock);
    current = synchronizerSentinelIsExactCurrent(
            synchronizer, sentinel, YES) &&
        sentinel->delegateTransactionGeneration ==
            expectedTransactionGeneration &&
        sentinel->delegateSetterInFlight == 0 &&
        sentinel->delegateCompletionRevision == expectedCompletionRevision;
    os_unfair_lock_unlock(&sentinel->outputLock);
    return current;
}

static BOOL beginSynchronizerDelegateCleanupIfCurrent(
    AVCaptureDataOutputSynchronizer *synchronizer,
    IUSCMicSynchronizerSentinel *sentinel,
    uint64_t expectedTransactionGeneration,
    uint64_t expectedCompletionRevision,
    uint64_t *cleanupTransactionGenerationOut,
    dispatch_group_t __strong *drainGroupOut,
    dispatch_queue_t __strong *publishedQueueOut) {
    if (cleanupTransactionGenerationOut) {
        *cleanupTransactionGenerationOut = 0;
    }
    if (drainGroupOut) *drainGroupOut = nil;
    if (publishedQueueOut) *publishedQueueOut = nil;
    if (!synchronizer || !sentinel ||
        expectedTransactionGeneration == 0 ||
        expectedCompletionRevision == 0) {
        return NO;
    }
    BOOL registered = NO;
    os_unfair_lock_lock(&sentinel->outputLock);
    if (synchronizerSentinelIsExactCurrent(
            synchronizer, sentinel, YES) &&
        sentinel->delegateTransactionGeneration ==
            expectedTransactionGeneration &&
        sentinel->delegateSetterInFlight == 0 &&
        sentinel->delegateCompletionRevision == expectedCompletionRevision &&
        sentinel->delegateSetterInFlight != UINT32_MAX) {
        sentinel->delegateTransactionGeneration =
            nextCaptureSessionStateRevision(
                sentinel->delegateTransactionGeneration);
        sentinel->delegateTransactionUnsafe = false;
        if (cleanupTransactionGenerationOut) {
            *cleanupTransactionGenerationOut =
                sentinel->delegateTransactionGeneration;
        }
        if (drainGroupOut) {
            *drainGroupOut = sentinel->delegateDrainGroup;
        }
        if (publishedQueueOut) {
            *publishedQueueOut = sentinel->delegateQueue;
        }
        ++sentinel->delegateSetterInFlight;
        retireSynchronizerDelegateBindingsLocked(sentinel);
        registered = YES;
    }
    os_unfair_lock_unlock(&sentinel->outputLock);
    return registered;
}

static SynchronizerDelegateConvergenceResult
convergeSynchronizerDelegateCompletion(
    AVCaptureDataOutputSynchronizer *synchronizer,
    IUSCMicSynchronizerSentinel *sentinel,
    uint64_t expectedTransactionGeneration,
    uint64_t expectedCompletionRevision) {
    if (!synchronizerDelegateCompletionIsCurrent(
            synchronizer, sentinel, expectedTransactionGeneration,
            expectedCompletionRevision)) {
        return SynchronizerDelegateConvergenceResult::Superseded;
    }

    BOOL transactionUnsafe = NO;
    os_unfair_lock_lock(&sentinel->outputLock);
    if (synchronizerSentinelIsExactCurrent(
            synchronizer, sentinel, YES) &&
        sentinel->delegateTransactionGeneration ==
            expectedTransactionGeneration &&
        sentinel->delegateSetterInFlight == 0 &&
        sentinel->delegateCompletionRevision == expectedCompletionRevision) {
        transactionUnsafe = sentinel->delegateTransactionUnsafe;
    }
    os_unfair_lock_unlock(&sentinel->outputLock);
    if (transactionUnsafe ||
        sentinel->delegateDrainPermanentlyUnsafe.load(
            std::memory_order_acquire)) {
        return SynchronizerDelegateConvergenceResult::NeedsClear;
    }

    for (unsigned snapshotAttempt = 0; snapshotAttempt < 3;
            ++snapshotAttempt) {
        id actualDelegate = nil;
        dispatch_queue_t actualQueue = nil;
        dispatch_queue_t alternateQueue = nil;
        const BOOL actualPairStable = snapshotSynchronizerDelegateAndQueue(
            synchronizer, &actualDelegate, &actualQueue, &alternateQueue);
        recordSynchronizerDelegateQueueDebt(
            sentinel, sentinel->delegateDrainGroup, actualQueue);
        recordSynchronizerDelegateQueueDebt(
            sentinel, sentinel->delegateDrainGroup, alternateQueue);
        if (!actualPairStable) {
            return synchronizerDelegateCompletionIsCurrent(
                       synchronizer, sentinel,
                       expectedTransactionGeneration,
                       expectedCompletionRevision)
                ? SynchronizerDelegateConvergenceResult::NeedsClear
                : SynchronizerDelegateConvergenceResult::Superseded;
        }

        if (!actualDelegate) {
            BOOL committed = NO;
            os_unfair_lock_lock(&sentinel->outputLock);
            if (synchronizerSentinelIsExactCurrent(
                    synchronizer, sentinel, YES) &&
                sentinel->delegateTransactionGeneration ==
                    expectedTransactionGeneration &&
                sentinel->delegateSetterInFlight == 0 &&
                sentinel->delegateCompletionRevision ==
                    expectedCompletionRevision &&
                !sentinel->delegateTransactionUnsafe) {
                retireSynchronizerDelegateBindingsLocked(sentinel);
                committed = YES;
            }
            os_unfair_lock_unlock(&sentinel->outputLock);
            return committed
                ? SynchronizerDelegateConvergenceResult::Committed
                : SynchronizerDelegateConvergenceResult::Superseded;
        }

        IUSCMicCaptureDelegateSentinel *delegateLifetime = nil;
        BOOL prepared = NO;
        @try {
            delegateLifetime = ensureCaptureDelegateSentinel(actualDelegate);
            prepared = delegateLifetime &&
                hookSynchronizerDelegateClass([actualDelegate class]);
            if (prepared) {
                IUSCMicStreamClientStart();
                prepared = [delegateLifetime
                    trackSynchronizerSentinel:sentinel];
            }
        } @catch (__unused NSException *exception) {
            prepared = NO;
        }
        if (!prepared) {
            return synchronizerDelegateCompletionIsCurrent(
                       synchronizer, sentinel,
                       expectedTransactionGeneration,
                       expectedCompletionRevision)
                ? SynchronizerDelegateConvergenceResult::NeedsClear
                : SynchronizerDelegateConvergenceResult::Superseded;
        }

        __strong AVCaptureAudioDataOutput *outputs[64] = {};
        __strong IUSCMicSynchronizerOutputMarker *markers[64] = {};
        __strong IUSCMicCaptureCursorBox *newBindings[64] = {};
        size_t count = 0;
        BOOL snapshotCurrent = NO;
        os_unfair_lock_lock(&sentinel->outputLock);
        if (synchronizerSentinelIsExactCurrent(
                synchronizer, sentinel, YES) &&
            sentinel->delegateTransactionGeneration ==
                expectedTransactionGeneration &&
            sentinel->delegateSetterInFlight == 0 &&
            sentinel->delegateCompletionRevision ==
                expectedCompletionRevision &&
            !sentinel->delegateTransactionUnsafe) {
            count = sentinel->outputCount;
            snapshotCurrent = count <= 64;
            for (size_t i = 0; snapshotCurrent && i < count; ++i) {
                outputs[i] = sentinel->audioOutputs[i];
                markers[i] = sentinel->outputMarkers[i];
                snapshotCurrent = outputs[i] && markers[i];
            }
        }
        os_unfair_lock_unlock(&sentinel->outputLock);
        if (!snapshotCurrent) {
            return synchronizerDelegateCompletionIsCurrent(
                       synchronizer, sentinel,
                       expectedTransactionGeneration,
                       expectedCompletionRevision)
                ? SynchronizerDelegateConvergenceResult::NeedsClear
                : SynchronizerDelegateConvergenceResult::Superseded;
        }

        BOOL allocated = YES;
        for (size_t i = 0; i < count; ++i) {
            IUSCMicCaptureCursorBox *binding =
                [IUSCMicCaptureCursorBox new];
            if (!binding) {
                allocated = NO;
                break;
            }
            binding.callbackObject = actualDelegate;
            binding.output = outputs[i];
            setCaptureBoxLifecycle(binding, false);
            newBindings[i] = binding;
        }
        if (!allocated) {
            return synchronizerDelegateCompletionIsCurrent(
                       synchronizer, sentinel,
                       expectedTransactionGeneration,
                       expectedCompletionRevision)
                ? SynchronizerDelegateConvergenceResult::NeedsClear
                : SynchronizerDelegateConvergenceResult::Superseded;
        }

        id finalDelegate = nil;
        dispatch_queue_t finalQueue = nil;
        dispatch_queue_t alternateFinalQueue = nil;
        const BOOL finalPairStable = snapshotSynchronizerDelegateAndQueue(
            synchronizer, &finalDelegate, &finalQueue,
            &alternateFinalQueue);
        recordSynchronizerDelegateQueueDebt(
            sentinel, sentinel->delegateDrainGroup, finalQueue);
        recordSynchronizerDelegateQueueDebt(
            sentinel, sentinel->delegateDrainGroup, alternateFinalQueue);
        if (!finalPairStable) {
            return synchronizerDelegateCompletionIsCurrent(
                       synchronizer, sentinel,
                       expectedTransactionGeneration,
                       expectedCompletionRevision)
                ? SynchronizerDelegateConvergenceResult::NeedsClear
                : SynchronizerDelegateConvergenceResult::Superseded;
        }
        if (finalDelegate != actualDelegate || finalQueue != actualQueue) {
            if (!synchronizerDelegateCompletionIsCurrent(
                    synchronizer, sentinel,
                    expectedTransactionGeneration,
                    expectedCompletionRevision)) {
                return SynchronizerDelegateConvergenceResult::Superseded;
            }
            continue;
        }

        BOOL committed = NO;
        uint64_t bindingGeneration = 0;
        dispatch_group_t drainGroup = nil;
        os_unfair_lock_lock(&sentinel->outputLock);
        if (synchronizerSentinelIsExactCurrent(
                synchronizer, sentinel, YES) &&
            sentinel->delegateTransactionGeneration ==
                expectedTransactionGeneration &&
            sentinel->delegateSetterInFlight == 0 &&
            sentinel->delegateCompletionRevision ==
                expectedCompletionRevision &&
            !sentinel->delegateTransactionUnsafe &&
            !sentinel->delegateDrainPermanentlyUnsafe.load(
                std::memory_order_acquire) &&
            sentinel->outputCount == count) {
            committed = YES;
            for (size_t i = 0; i < count; ++i) {
                if (sentinel->audioOutputs[i] != outputs[i] ||
                    sentinel->outputMarkers[i] != markers[i]) {
                    committed = NO;
                    break;
                }
            }
            if (committed) {
                retireSynchronizerDelegateBindingsLocked(sentinel);
                sentinel->delegateBindingGenerationCounter =
                    nextCaptureSessionStateRevision(
                        sentinel->delegateBindingGenerationCounter);
                bindingGeneration =
                    sentinel->delegateBindingGenerationCounter;
                for (size_t i = 0; i < count; ++i) {
                    newBindings[i]->synchronizerBindingGeneration =
                        bindingGeneration;
                    sentinel->bindings[i] = newBindings[i];
                    /* Lifecycle edges cannot arm a pending queue generation. */
                    setCaptureBoxLifecycle(sentinel->bindings[i], false);
                }
                sentinel.delegate = actualDelegate;
                sentinel->delegateIdentity =
                    captureObjectIdentity(actualDelegate);
                sentinel->delegateQueue = actualQueue;
                sentinel->delegateQueueIdentity =
                    synchronizerDelegateQueueIdentity(actualQueue);
                sentinel->pendingBindingGeneration = bindingGeneration;
                sentinel->activeBindingGeneration = 0;
                drainGroup = sentinel->delegateDrainGroup;
            }
        }
        os_unfair_lock_unlock(&sentinel->outputLock);
        if (!committed) {
            return SynchronizerDelegateConvergenceResult::Superseded;
        }

        /*
         * Obsolete tokens lose publication authority but retain their drain
         * debts in the shared group.  Once every old queue is drained, enqueue
         * one more asynchronous barrier on the authoritative final queue and
         * activate only the full exact token carried by this completion.
         */
        __weak AVCaptureDataOutputSynchronizer *weakSynchronizer = synchronizer;
        __weak IUSCMicSynchronizerSentinel *weakSentinel = sentinel;
        __weak id weakDelegate = actualDelegate;
        const uintptr_t expectedSynchronizerIdentity =
            captureObjectIdentity(synchronizer);
        const uintptr_t expectedSentinelIdentity =
            captureObjectIdentity(sentinel);
        const uintptr_t expectedDelegateIdentity =
            captureObjectIdentity(actualDelegate);
        const uintptr_t expectedQueueIdentity =
            synchronizerDelegateQueueIdentity(actualQueue);
        dispatch_group_notify(
            drainGroup,
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            dispatch_barrier_async(actualQueue, ^{
                AVCaptureDataOutputSynchronizer *strongSynchronizer =
                    weakSynchronizer;
                IUSCMicSynchronizerSentinel *strongSentinel = weakSentinel;
                id strongDelegate = weakDelegate;
                if (!strongSynchronizer || !strongSentinel ||
                    !strongDelegate ||
                    captureObjectIdentity(strongSynchronizer) !=
                        expectedSynchronizerIdentity ||
                    captureObjectIdentity(strongSentinel) !=
                        expectedSentinelIdentity ||
                    captureObjectIdentity(strongDelegate) !=
                        expectedDelegateIdentity) {
                    return;
                }

                id queueDelegate = nil;
                dispatch_queue_t queueSnapshot = nil;
                dispatch_queue_t alternateQueueSnapshot = nil;
                const BOOL actualStillExact =
                    snapshotSynchronizerDelegateAndQueue(
                        strongSynchronizer, &queueDelegate,
                        &queueSnapshot, &alternateQueueSnapshot) &&
                    queueDelegate == strongDelegate &&
                    queueSnapshot == actualQueue &&
                    !alternateQueueSnapshot &&
                    synchronizerDelegateQueueIdentity(queueSnapshot) ==
                        expectedQueueIdentity;

                os_unfair_lock_lock(&strongSentinel->outputLock);
                const BOOL tokenStillExact =
                    synchronizerSentinelIsExactCurrent(
                        strongSynchronizer, strongSentinel, YES) &&
                    strongSentinel->delegateTransactionGeneration ==
                        expectedTransactionGeneration &&
                    strongSentinel->delegateSetterInFlight == 0 &&
                    strongSentinel->delegateCompletionRevision ==
                        expectedCompletionRevision &&
                    !strongSentinel->delegateTransactionUnsafe &&
                    !strongSentinel->delegateDrainPermanentlyUnsafe.load(
                        std::memory_order_acquire) &&
                    strongSentinel.delegate == strongDelegate &&
                    strongSentinel->delegateIdentity ==
                        expectedDelegateIdentity &&
                    strongSentinel->delegateQueue == actualQueue &&
                    strongSentinel->delegateQueueIdentity ==
                        expectedQueueIdentity &&
                    strongSentinel->pendingBindingGeneration ==
                        bindingGeneration &&
                    strongSentinel->activeBindingGeneration == 0;
                BOOL boxesStillExact = tokenStillExact;
                for (size_t i = 0;
                        boxesStillExact && i < strongSentinel->outputCount;
                        ++i) {
                    IUSCMicCaptureCursorBox *binding =
                        strongSentinel->bindings[i];
                    boxesStillExact = binding &&
                        binding->synchronizerBindingGeneration ==
                            bindingGeneration &&
                        binding.callbackObject == strongDelegate &&
                        binding.output == strongSentinel->audioOutputs[i] &&
                        strongSentinel->outputMarkers[i];
                }
                BOOL needsOrderedClear = NO;
                if (boxesStillExact && actualStillExact) {
                    strongSentinel->pendingBindingGeneration = 0;
                    strongSentinel->activeBindingGeneration =
                        bindingGeneration;
                    for (size_t i = 0;
                            i < strongSentinel->outputCount; ++i) {
                        setCaptureBoxLifecycle(
                            strongSentinel->bindings[i],
                            strongSentinel->outputActive[i]);
                    }
                } else if (tokenStillExact) {
                    /* An ambiguous final pair stays fail-closed; never guess. */
                    retireSynchronizerDelegateBindingsLocked(strongSentinel);
                    needsOrderedClear = YES;
                }
                os_unfair_lock_unlock(&strongSentinel->outputLock);
                if (needsOrderedClear) {
                    /* Re-enter the ordered transaction outside every custom lock. */
                    @try {
                        [strongSynchronizer setDelegate:nil queue:nil];
                    } @catch (__unused NSException *exception) {
                    }
                }
            });
        });
        return SynchronizerDelegateConvergenceResult::Committed;
    }

    return synchronizerDelegateCompletionIsCurrent(
               synchronizer, sentinel, expectedTransactionGeneration,
               expectedCompletionRevision)
        ? SynchronizerDelegateConvergenceResult::NeedsClear
        : SynchronizerDelegateConvergenceResult::Superseded;
}

enum class DirectCaptureDelegateConvergenceResult {
    Committed,
    Superseded,
    NeedsClear,
};

static BOOL directCaptureOutputSentinelIsExactCurrent(
    AVCaptureAudioDataOutput *output,
    IUSCMicCaptureOutputSentinel *sentinel) {
    return output && sentinel && sentinel.output == output &&
        sentinel->outputIdentity == captureObjectIdentity(output) &&
        objc_getAssociatedObject(
            output, &gCaptureOutputSentinelAssociationKey) == sentinel;
}

static IUSCMicCaptureCursorBox *retireDirectCaptureBindingLocked(
    IUSCMicCaptureOutputSentinel *sentinel) {
    if (!sentinel) return nil;
    IUSCMicCaptureCursorBox *binding = sentinel.currentBinding;
    setCaptureBoxLifecycle(binding, false);
    sentinel.currentBinding = nil;
    sentinel.delegate = nil;
    sentinel->delegateIdentity = 0;
    sentinel->delegateQueue = nil;
    sentinel->delegateQueueIdentity = 0;
    sentinel->pendingBindingGeneration = 0;
    sentinel->activeBindingGeneration = 0;
    return binding;
}

/*
 * AVCaptureAudioDataOutput exposes its delegate and callback queue through
 * separate nonatomic getters.  A pair is authoritative only after two equal
 * reads, and every distinct queue observed by a torn pair remains drain debt.
 */
static BOOL snapshotDirectCaptureDelegateAndQueue(
    AVCaptureAudioDataOutput *output,
    id __strong *delegateOut,
    dispatch_queue_t __strong *queueOut,
    dispatch_queue_t __strong *alternateQueueOut) {
    if (delegateOut) *delegateOut = nil;
    if (queueOut) *queueOut = nil;
    if (alternateQueueOut) *alternateQueueOut = nil;
    if (!output) return NO;

    id firstDelegate = nil;
    id secondDelegate = nil;
    dispatch_queue_t firstQueue = nil;
    dispatch_queue_t secondQueue = nil;
    @try {
        firstDelegate = output.sampleBufferDelegate;
        firstQueue = output.sampleBufferCallbackQueue;
        secondDelegate = output.sampleBufferDelegate;
        secondQueue = output.sampleBufferCallbackQueue;
    } @catch (__unused NSException *exception) {
        if (queueOut) *queueOut = firstQueue;
        if (alternateQueueOut && secondQueue != firstQueue) {
            *alternateQueueOut = secondQueue;
        }
        return NO;
    }
    if (queueOut) *queueOut = firstQueue;
    if (alternateQueueOut && secondQueue != firstQueue) {
        *alternateQueueOut = secondQueue;
    }
    const BOOL stable = firstDelegate == secondDelegate &&
        firstQueue == secondQueue &&
        ((!secondDelegate && !secondQueue) ||
         (secondDelegate && secondQueue &&
          synchronizerDelegateQueueSupportsDrainBarrier(secondQueue)));
    if (stable && delegateOut) *delegateOut = secondDelegate;
    return stable;
}

static void recordDirectCaptureDelegateQueueDebt(
    IUSCMicCaptureOutputSentinel *sentinel,
    dispatch_group_t drainGroup,
    dispatch_queue_t queue) {
    if (!sentinel || !drainGroup || !queue) return;
    if (!synchronizerDelegateQueueSupportsDrainBarrier(queue)) {
        sentinel->delegateDrainPermanentlyUnsafe.store(
            true, std::memory_order_release);
        return;
    }
    dispatch_group_enter(drainGroup);
    dispatch_barrier_async(queue, ^{
        dispatch_group_leave(drainGroup);
    });
}

static void releaseRetiredDirectCaptureBindingAfterDrain(
    dispatch_group_t drainGroup,
    IUSCMicCaptureCursorBox *binding) {
    if (!binding) return;
    setCaptureBoxLifecycle(binding, false);
    IUSCMicCaptureDelegateSentinel *delegateSentinel =
        binding.delegateSentinel;
    if (!delegateSentinel) return;
    if (!drainGroup) {
        [delegateSentinel untrackDirectBinding:binding];
        return;
    }
    dispatch_group_notify(
        drainGroup,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            setCaptureBoxLifecycle(binding, false);
            [delegateSentinel untrackDirectBinding:binding];
        });
}

static BOOL beginDirectCaptureDelegateSetterOperation(
    AVCaptureAudioDataOutput *output,
    IUSCMicCaptureOutputSentinel *sentinel,
    uint64_t *transactionGenerationOut,
    dispatch_group_t __strong *drainGroupOut,
    dispatch_queue_t __strong *publishedQueueOut,
    IUSCMicCaptureCursorBox *__strong *publishedBindingOut) {
    if (transactionGenerationOut) *transactionGenerationOut = 0;
    if (drainGroupOut) *drainGroupOut = nil;
    if (publishedQueueOut) *publishedQueueOut = nil;
    if (publishedBindingOut) *publishedBindingOut = nil;
    if (!directCaptureOutputSentinelIsExactCurrent(output, sentinel)) return NO;

    BOOL registered = NO;
    os_unfair_lock_lock(&sentinel->stateLock);
    if (directCaptureOutputSentinelIsExactCurrent(output, sentinel) &&
        sentinel->delegateDrainGroup &&
        sentinel->delegateSetterInFlight != UINT32_MAX) {
        if (sentinel->delegateSetterInFlight == 0) {
            sentinel->delegateTransactionGeneration =
                nextCaptureSessionStateRevision(
                    sentinel->delegateTransactionGeneration);
            sentinel->delegateTransactionUnsafe = false;
        }
        if (transactionGenerationOut) {
            *transactionGenerationOut =
                sentinel->delegateTransactionGeneration;
        }
        if (drainGroupOut) {
            *drainGroupOut = sentinel->delegateDrainGroup;
        }
        if (publishedQueueOut) {
            *publishedQueueOut = sentinel->delegateQueue;
        }
        if (publishedBindingOut) {
            *publishedBindingOut = sentinel.currentBinding;
        }
        ++sentinel->delegateSetterInFlight;
        (void)retireDirectCaptureBindingLocked(sentinel);
        registered = YES;
    }
    os_unfair_lock_unlock(&sentinel->stateLock);
    return registered;
}

/* Allocate completion order immediately after Apple's setter returns/throws.
 * In-flight registration remains held until this operation has recorded every
 * queue debt, so the last convergence cannot outrun a concurrent completion. */
static uint64_t registerDirectCaptureDelegateCompletion(
    AVCaptureAudioDataOutput *output,
    IUSCMicCaptureOutputSentinel *sentinel,
    uint64_t expectedTransactionGeneration) {
    if (!output || !sentinel || expectedTransactionGeneration == 0) return 0;
    uint64_t revision = 0;
    os_unfair_lock_lock(&sentinel->stateLock);
    if (directCaptureOutputSentinelIsExactCurrent(output, sentinel) &&
        sentinel->delegateTransactionGeneration ==
            expectedTransactionGeneration &&
        sentinel->delegateSetterInFlight != 0) {
        sentinel->delegateCompletionRevision =
            nextCaptureSessionStateRevision(
                sentinel->delegateCompletionRevision);
        revision = sentinel->delegateCompletionRevision;
    }
    os_unfair_lock_unlock(&sentinel->stateLock);
    return revision;
}

static uint64_t finishDirectCaptureDelegateCompletionDebts(
    AVCaptureAudioDataOutput *output,
    IUSCMicCaptureOutputSentinel *sentinel,
    uint64_t expectedTransactionGeneration,
    uint64_t operationCompletionRevision,
    BOOL queueSnapshotsSafe,
    BOOL *shouldConvergeOut) {
    if (shouldConvergeOut) *shouldConvergeOut = NO;
    if (!output || !sentinel || expectedTransactionGeneration == 0 ||
        operationCompletionRevision == 0) {
        return 0;
    }
    uint64_t convergenceRevision = 0;
    os_unfair_lock_lock(&sentinel->stateLock);
    if (directCaptureOutputSentinelIsExactCurrent(output, sentinel) &&
        sentinel->delegateTransactionGeneration ==
            expectedTransactionGeneration &&
        sentinel->delegateSetterInFlight != 0 &&
        operationCompletionRevision <=
            sentinel->delegateCompletionRevision) {
        if (!queueSnapshotsSafe) {
            sentinel->delegateTransactionUnsafe = true;
        }
        --sentinel->delegateSetterInFlight;
        if (sentinel->delegateSetterInFlight == 0) {
            convergenceRevision = sentinel->delegateCompletionRevision;
            if (shouldConvergeOut) *shouldConvergeOut = YES;
        }
    }
    os_unfair_lock_unlock(&sentinel->stateLock);
    return convergenceRevision;
}

static BOOL directCaptureDelegateCompletionIsCurrent(
    AVCaptureAudioDataOutput *output,
    IUSCMicCaptureOutputSentinel *sentinel,
    uint64_t expectedTransactionGeneration,
    uint64_t expectedCompletionRevision) {
    if (!output || !sentinel || expectedTransactionGeneration == 0 ||
        expectedCompletionRevision == 0) {
        return NO;
    }
    BOOL current = NO;
    os_unfair_lock_lock(&sentinel->stateLock);
    current = directCaptureOutputSentinelIsExactCurrent(output, sentinel) &&
        sentinel->delegateTransactionGeneration ==
            expectedTransactionGeneration &&
        sentinel->delegateSetterInFlight == 0 &&
        sentinel->delegateCompletionRevision == expectedCompletionRevision;
    os_unfair_lock_unlock(&sentinel->stateLock);
    return current;
}

static BOOL beginDirectCaptureDelegateCleanupIfCurrent(
    AVCaptureAudioDataOutput *output,
    IUSCMicCaptureOutputSentinel *sentinel,
    uint64_t expectedTransactionGeneration,
    uint64_t expectedCompletionRevision,
    uint64_t *cleanupTransactionGenerationOut,
    dispatch_group_t __strong *drainGroupOut,
    dispatch_queue_t __strong *publishedQueueOut,
    IUSCMicCaptureCursorBox *__strong *publishedBindingOut) {
    if (cleanupTransactionGenerationOut) *cleanupTransactionGenerationOut = 0;
    if (drainGroupOut) *drainGroupOut = nil;
    if (publishedQueueOut) *publishedQueueOut = nil;
    if (publishedBindingOut) *publishedBindingOut = nil;
    if (!output || !sentinel || expectedTransactionGeneration == 0 ||
        expectedCompletionRevision == 0) {
        return NO;
    }

    BOOL registered = NO;
    os_unfair_lock_lock(&sentinel->stateLock);
    if (directCaptureOutputSentinelIsExactCurrent(output, sentinel) &&
        sentinel->delegateTransactionGeneration ==
            expectedTransactionGeneration &&
        sentinel->delegateSetterInFlight == 0 &&
        sentinel->delegateCompletionRevision == expectedCompletionRevision &&
        sentinel->delegateDrainGroup) {
        sentinel->delegateTransactionGeneration =
            nextCaptureSessionStateRevision(
                sentinel->delegateTransactionGeneration);
        sentinel->delegateTransactionUnsafe = false;
        if (cleanupTransactionGenerationOut) {
            *cleanupTransactionGenerationOut =
                sentinel->delegateTransactionGeneration;
        }
        if (drainGroupOut) *drainGroupOut = sentinel->delegateDrainGroup;
        if (publishedQueueOut) *publishedQueueOut = sentinel->delegateQueue;
        if (publishedBindingOut) {
            *publishedBindingOut = sentinel.currentBinding;
        }
        sentinel->delegateSetterInFlight = 1;
        (void)retireDirectCaptureBindingLocked(sentinel);
        registered = YES;
    }
    os_unfair_lock_unlock(&sentinel->stateLock);
    return registered;
}

static IUSCMicCaptureCursorBox *retireDirectCaptureCompletionIfCurrent(
    AVCaptureAudioDataOutput *output,
    IUSCMicCaptureOutputSentinel *sentinel,
    uint64_t expectedTransactionGeneration,
    uint64_t expectedCompletionRevision) {
    IUSCMicCaptureCursorBox *retiredBinding = nil;
    if (!output || !sentinel) return nil;
    os_unfair_lock_lock(&sentinel->stateLock);
    if (directCaptureOutputSentinelIsExactCurrent(output, sentinel) &&
        sentinel->delegateTransactionGeneration ==
            expectedTransactionGeneration &&
        sentinel->delegateSetterInFlight == 0 &&
        sentinel->delegateCompletionRevision == expectedCompletionRevision) {
        retiredBinding = retireDirectCaptureBindingLocked(sentinel);
    }
    os_unfair_lock_unlock(&sentinel->stateLock);
    return retiredBinding;
}

static DirectCaptureDelegateConvergenceResult
convergeDirectCaptureDelegateCompletion(
    AVCaptureAudioDataOutput *output,
    IUSCMicCaptureOutputSentinel *sentinel,
    uint64_t expectedTransactionGeneration,
    uint64_t expectedCompletionRevision) {
    if (!directCaptureDelegateCompletionIsCurrent(
            output, sentinel, expectedTransactionGeneration,
            expectedCompletionRevision)) {
        return DirectCaptureDelegateConvergenceResult::Superseded;
    }

    BOOL transactionUnsafe = NO;
    os_unfair_lock_lock(&sentinel->stateLock);
    if (directCaptureOutputSentinelIsExactCurrent(output, sentinel) &&
        sentinel->delegateTransactionGeneration ==
            expectedTransactionGeneration &&
        sentinel->delegateSetterInFlight == 0 &&
        sentinel->delegateCompletionRevision == expectedCompletionRevision) {
        transactionUnsafe = sentinel->delegateTransactionUnsafe;
    }
    os_unfair_lock_unlock(&sentinel->stateLock);
    if (transactionUnsafe ||
        sentinel->delegateDrainPermanentlyUnsafe.load(
            std::memory_order_acquire)) {
        return DirectCaptureDelegateConvergenceResult::NeedsClear;
    }

    for (unsigned snapshotAttempt = 0; snapshotAttempt < 3;
            ++snapshotAttempt) {
        id actualDelegate = nil;
        dispatch_queue_t actualQueue = nil;
        dispatch_queue_t alternateQueue = nil;
        const BOOL actualPairStable = snapshotDirectCaptureDelegateAndQueue(
            output, &actualDelegate, &actualQueue, &alternateQueue);
        recordDirectCaptureDelegateQueueDebt(
            sentinel, sentinel->delegateDrainGroup, actualQueue);
        recordDirectCaptureDelegateQueueDebt(
            sentinel, sentinel->delegateDrainGroup, alternateQueue);
        if (!actualPairStable) {
            return directCaptureDelegateCompletionIsCurrent(
                       output, sentinel, expectedTransactionGeneration,
                       expectedCompletionRevision)
                ? DirectCaptureDelegateConvergenceResult::NeedsClear
                : DirectCaptureDelegateConvergenceResult::Superseded;
        }

        if (!actualDelegate) {
            BOOL committed = NO;
            IUSCMicCaptureCursorBox *retiredBinding = nil;
            os_unfair_lock_lock(&sentinel->stateLock);
            if (directCaptureOutputSentinelIsExactCurrent(output, sentinel) &&
                sentinel->delegateTransactionGeneration ==
                    expectedTransactionGeneration &&
                sentinel->delegateSetterInFlight == 0 &&
                sentinel->delegateCompletionRevision ==
                    expectedCompletionRevision &&
                !sentinel->delegateTransactionUnsafe) {
                retiredBinding = retireDirectCaptureBindingLocked(sentinel);
                committed = YES;
            }
            os_unfair_lock_unlock(&sentinel->stateLock);
            releaseRetiredDirectCaptureBindingAfterDrain(
                sentinel->delegateDrainGroup, retiredBinding);
            return committed
                ? DirectCaptureDelegateConvergenceResult::Committed
                : DirectCaptureDelegateConvergenceResult::Superseded;
        }

        IUSCMicCaptureDelegateSentinel *delegateLifetime = nil;
        BOOL prepared = NO;
        @try {
            delegateLifetime = ensureCaptureDelegateSentinel(actualDelegate);
            prepared = delegateLifetime &&
                hookAudioDelegateClass([actualDelegate class]);
            if (prepared) IUSCMicStreamClientStart();
        } @catch (__unused NSException *exception) {
            prepared = NO;
        }
        if (!prepared) {
            return directCaptureDelegateCompletionIsCurrent(
                       output, sentinel, expectedTransactionGeneration,
                       expectedCompletionRevision)
                ? DirectCaptureDelegateConvergenceResult::NeedsClear
                : DirectCaptureDelegateConvergenceResult::Superseded;
        }

        IUSCMicCaptureCursorBox *newBinding = [IUSCMicCaptureCursorBox new];
        if (!newBinding) {
            return directCaptureDelegateCompletionIsCurrent(
                       output, sentinel, expectedTransactionGeneration,
                       expectedCompletionRevision)
                ? DirectCaptureDelegateConvergenceResult::NeedsClear
                : DirectCaptureDelegateConvergenceResult::Superseded;
        }
        newBinding.callbackObject = actualDelegate;
        newBinding.output = output;
        newBinding->callbackIdentity = captureObjectIdentity(actualDelegate);
        newBinding->outputIdentity = captureObjectIdentity(output);
        newBinding->directOutputSentinelIdentity =
            captureObjectIdentity(sentinel);
        setCaptureBoxLifecycle(newBinding, false);
        if (![delegateLifetime trackDirectBinding:newBinding
                                    callbackObject:actualDelegate]) {
            return directCaptureDelegateCompletionIsCurrent(
                       output, sentinel, expectedTransactionGeneration,
                       expectedCompletionRevision)
                ? DirectCaptureDelegateConvergenceResult::NeedsClear
                : DirectCaptureDelegateConvergenceResult::Superseded;
        }

        id finalDelegate = nil;
        dispatch_queue_t finalQueue = nil;
        dispatch_queue_t alternateFinalQueue = nil;
        const BOOL finalPairStable = snapshotDirectCaptureDelegateAndQueue(
            output, &finalDelegate, &finalQueue, &alternateFinalQueue);
        recordDirectCaptureDelegateQueueDebt(
            sentinel, sentinel->delegateDrainGroup, finalQueue);
        recordDirectCaptureDelegateQueueDebt(
            sentinel, sentinel->delegateDrainGroup, alternateFinalQueue);
        if (!finalPairStable) {
            [delegateLifetime untrackDirectBinding:newBinding];
            return directCaptureDelegateCompletionIsCurrent(
                       output, sentinel, expectedTransactionGeneration,
                       expectedCompletionRevision)
                ? DirectCaptureDelegateConvergenceResult::NeedsClear
                : DirectCaptureDelegateConvergenceResult::Superseded;
        }
        if (finalDelegate != actualDelegate || finalQueue != actualQueue) {
            [delegateLifetime untrackDirectBinding:newBinding];
            if (!directCaptureDelegateCompletionIsCurrent(
                    output, sentinel, expectedTransactionGeneration,
                    expectedCompletionRevision)) {
                return DirectCaptureDelegateConvergenceResult::Superseded;
            }
            continue;
        }

        BOOL committed = NO;
        uint64_t bindingGeneration = 0;
        dispatch_group_t drainGroup = nil;
        os_unfair_lock_lock(&sentinel->stateLock);
        if (directCaptureOutputSentinelIsExactCurrent(output, sentinel) &&
            sentinel->delegateTransactionGeneration ==
                expectedTransactionGeneration &&
            sentinel->delegateSetterInFlight == 0 &&
            sentinel->delegateCompletionRevision ==
                expectedCompletionRevision &&
            !sentinel->delegateTransactionUnsafe &&
            !sentinel->delegateDrainPermanentlyUnsafe.load(
                std::memory_order_acquire) &&
            !sentinel.currentBinding &&
            sentinel->pendingBindingGeneration == 0 &&
            sentinel->activeBindingGeneration == 0) {
            sentinel->delegateBindingGenerationCounter =
                nextCaptureSessionStateRevision(
                    sentinel->delegateBindingGenerationCounter);
            bindingGeneration = sentinel->delegateBindingGenerationCounter;
            newBinding->directBindingGeneration = bindingGeneration;
            sentinel.currentBinding = newBinding;
            sentinel.delegate = actualDelegate;
            sentinel->delegateIdentity = captureObjectIdentity(actualDelegate);
            sentinel->delegateQueue = actualQueue;
            sentinel->delegateQueueIdentity =
                synchronizerDelegateQueueIdentity(actualQueue);
            sentinel->pendingBindingGeneration = bindingGeneration;
            sentinel->activeBindingGeneration = 0;
            setCaptureBoxLifecycle(newBinding, false);
            drainGroup = sentinel->delegateDrainGroup;
            committed = YES;
        }
        os_unfair_lock_unlock(&sentinel->stateLock);
        if (!committed) {
            [delegateLifetime untrackDirectBinding:newBinding];
            return DirectCaptureDelegateConvergenceResult::Superseded;
        }

        __weak AVCaptureAudioDataOutput *weakOutput = output;
        __weak IUSCMicCaptureOutputSentinel *weakSentinel = sentinel;
        __weak id weakDelegate = actualDelegate;
        const uintptr_t expectedOutputIdentity = captureObjectIdentity(output);
        const uintptr_t expectedSentinelIdentity =
            captureObjectIdentity(sentinel);
        const uintptr_t expectedDelegateIdentity =
            captureObjectIdentity(actualDelegate);
        const uintptr_t expectedQueueIdentity =
            synchronizerDelegateQueueIdentity(actualQueue);
        dispatch_group_notify(
            drainGroup,
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            dispatch_barrier_async(actualQueue, ^{
                AVCaptureAudioDataOutput *strongOutput = weakOutput;
                IUSCMicCaptureOutputSentinel *strongSentinel = weakSentinel;
                id strongDelegate = weakDelegate;
                if (!strongOutput || !strongSentinel || !strongDelegate ||
                    captureObjectIdentity(strongOutput) !=
                        expectedOutputIdentity ||
                    captureObjectIdentity(strongSentinel) !=
                        expectedSentinelIdentity ||
                    captureObjectIdentity(strongDelegate) !=
                        expectedDelegateIdentity) {
                    return;
                }

                id queueDelegate = nil;
                dispatch_queue_t queueSnapshot = nil;
                dispatch_queue_t alternateQueueSnapshot = nil;
                const BOOL actualStillExact =
                    snapshotDirectCaptureDelegateAndQueue(
                        strongOutput, &queueDelegate, &queueSnapshot,
                        &alternateQueueSnapshot) &&
                    queueDelegate == strongDelegate &&
                    queueSnapshot == actualQueue &&
                    !alternateQueueSnapshot &&
                    synchronizerDelegateQueueIdentity(queueSnapshot) ==
                        expectedQueueIdentity;
                if (alternateQueueSnapshot) {
                    recordDirectCaptureDelegateQueueDebt(
                        strongSentinel,
                        strongSentinel->delegateDrainGroup,
                        alternateQueueSnapshot);
                }

                BOOL needsOrderedClear = NO;
                IUSCMicCaptureCursorBox *retiredBinding = nil;
                @synchronized(strongOutput) {
                    const BOOL desiredActive =
                        synchronizerOutputIsAuthoritativelyActiveLocked(
                            strongOutput);
                    os_unfair_lock_lock(&strongSentinel->stateLock);
                    const BOOL tokenStillExact =
                        directCaptureOutputSentinelIsExactCurrent(
                            strongOutput, strongSentinel) &&
                        strongSentinel->delegateTransactionGeneration ==
                            expectedTransactionGeneration &&
                        strongSentinel->delegateSetterInFlight == 0 &&
                        strongSentinel->delegateCompletionRevision ==
                            expectedCompletionRevision &&
                        strongSentinel.delegate == strongDelegate &&
                        strongSentinel->delegateIdentity ==
                            expectedDelegateIdentity &&
                        strongSentinel->delegateQueue == actualQueue &&
                        strongSentinel->delegateQueueIdentity ==
                            expectedQueueIdentity &&
                        strongSentinel->pendingBindingGeneration ==
                            bindingGeneration &&
                        strongSentinel->activeBindingGeneration == 0 &&
                        strongSentinel.currentBinding == newBinding &&
                        newBinding.callbackObject == strongDelegate &&
                        newBinding.output == strongOutput &&
                        newBinding->callbackIdentity ==
                            expectedDelegateIdentity &&
                        newBinding->outputIdentity ==
                            expectedOutputIdentity &&
                        newBinding->directOutputSentinelIdentity ==
                            expectedSentinelIdentity &&
                        newBinding->directBindingGeneration ==
                            bindingGeneration;
                    const BOOL activationSafe = tokenStillExact &&
                        !strongSentinel->delegateTransactionUnsafe &&
                        !strongSentinel->delegateDrainPermanentlyUnsafe.load(
                            std::memory_order_acquire);
                    if (activationSafe && actualStillExact) {
                        strongSentinel->pendingBindingGeneration = 0;
                        strongSentinel->activeBindingGeneration =
                            bindingGeneration;
                        setCaptureBoxLifecycle(newBinding, desiredActive);
                    } else if (tokenStillExact) {
                        retiredBinding =
                            retireDirectCaptureBindingLocked(strongSentinel);
                        needsOrderedClear = YES;
                    }
                    os_unfair_lock_unlock(&strongSentinel->stateLock);
                }
                if (retiredBinding) {
                    [delegateLifetime untrackDirectBinding:retiredBinding];
                }
                if (needsOrderedClear) {
                    @try {
                        [strongOutput setSampleBufferDelegate:nil queue:nil];
                    } @catch (__unused NSException *exception) {
                    }
                }
            });
        });
        return DirectCaptureDelegateConvergenceResult::Committed;
    }

    return directCaptureDelegateCompletionIsCurrent(
               output, sentinel, expectedTransactionGeneration,
               expectedCompletionRevision)
        ? DirectCaptureDelegateConvergenceResult::NeedsClear
        : DirectCaptureDelegateConvergenceResult::Superseded;
}

@implementation IUSCMicCaptureSessionObserver

- (instancetype)initWithSession:(AVCaptureSession *)session {
    self = [super init];
    if (!self) return nil;
    outputLock = OS_UNFAIR_LOCK_INIT;
    stateRevision = 1;
    ownerSessionIdentity = captureObjectIdentity(session);
    self.session = session;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    __weak AVCaptureSession *weakSession = session;
    __weak IUSCMicCaptureSessionObserver *weakObserver = self;

    id didStart = [center
        addObserverForName:AVCaptureSessionDidStartRunningNotification
                    object:session queue:nil
                usingBlock:^(__unused NSNotification *note) {
        AVCaptureSession *strongSession = weakSession;
        IUSCMicCaptureSessionObserver *strongObserver = weakObserver;
        if (strongSession && strongObserver) {
            convergeCaptureSessionDemandForObserver(
                strongSession, strongObserver);
        }
    }];
    id didStop = [center
        addObserverForName:AVCaptureSessionDidStopRunningNotification
                    object:session queue:nil
                usingBlock:^(__unused NSNotification *note) {
        AVCaptureSession *strongSession = weakSession;
        IUSCMicCaptureSessionObserver *strongObserver = weakObserver;
        if (strongSession && strongObserver) {
            setCaptureSessionDemandForObserver(
                strongSession, strongObserver, false);
        }
    }];
    id runtimeError = [center
        addObserverForName:AVCaptureSessionRuntimeErrorNotification
                    object:session queue:nil
                usingBlock:^(__unused NSNotification *note) {
        AVCaptureSession *strongSession = weakSession;
        IUSCMicCaptureSessionObserver *strongObserver = weakObserver;
        if (strongSession && strongObserver) {
            setCaptureSessionDemandForObserver(
                strongSession, strongObserver, false);
        }
    }];
    id interrupted = [center
        addObserverForName:AVCaptureSessionWasInterruptedNotification
                    object:session queue:nil
                usingBlock:^(__unused NSNotification *note) {
        AVCaptureSession *strongSession = weakSession;
        IUSCMicCaptureSessionObserver *strongObserver = weakObserver;
        if (strongSession && strongObserver) {
            setCaptureSessionDemandForObserver(
                strongSession, strongObserver, false);
        }
    }];
    id interruptionEnded = [center
        addObserverForName:AVCaptureSessionInterruptionEndedNotification
                    object:session queue:nil
                usingBlock:^(__unused NSNotification *note) {
        AVCaptureSession *strongSession = weakSession;
        IUSCMicCaptureSessionObserver *strongObserver = weakObserver;
        if (strongSession && strongObserver) {
            convergeCaptureSessionDemandForObserver(
                strongSession, strongObserver);
        }
    }];
    self.tokens = @[didStart, didStop, runtimeError,
                    interrupted, interruptionEnded];
    return self;
}

- (BOOL)authoritativelyClaimOutput:(AVCaptureOutput *)output
                       revisionOut:(uint64_t *)revisionOut
                         activeOut:(BOOL *)activeOut {
    if (revisionOut) *revisionOut = 0;
    if (activeOut) *activeOut = NO;
    if (!output) return NO;
    AVCaptureSession *ownerSession = self.session;
    if (!ownerSession ||
        ownerSessionIdentity != captureObjectIdentity(ownerSession) ||
        objc_getAssociatedObject(
            ownerSession, &gCaptureSessionObserverAssociationKey) != self) {
        return NO;
    }

    BOOL claimed = NO;
    BOOL active = NO;
    uint64_t revision = 0;
    __strong IUSCMicCaptureSessionObserver *previousObserver = nil;
    uint64_t previousEpoch = 0;
    @synchronized(output) {
        BOOL remainsMember = NO;
        @try {
            remainsMember = [ownerSession.outputs containsObject:output];
        } @catch (__unused NSException *exception) {
            remainsMember = NO;
        }
        if (!remainsMember ||
            objc_getAssociatedObject(
                ownerSession, &gCaptureSessionObserverAssociationKey) != self) {
            return NO;
        }

        const BOOL isAudio = [output isKindOfClass:
            [AVCaptureAudioDataOutput class]];
        IUSCMicCaptureSessionOutputOwnership *ownership = nil;
        if (isAudio) {
            ownership = objc_getAssociatedObject(
                output, &gCaptureSessionOutputOwnershipAssociationKey);
            if (!ownership) {
                ownership = [IUSCMicCaptureSessionOutputOwnership new];
                if (ownership) {
                    objc_setAssociatedObject(
                        output, &gCaptureSessionOutputOwnershipAssociationKey,
                        ownership, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            }
            if (!ownership) return NO;
        }

        os_unfair_lock_lock(&outputLock);
        size_t targetIndex = 64;
        if (isAudio) {
            size_t emptyIndex = 64;
            for (size_t i = 0; i < 64; ++i) {
                AVCaptureOutput *candidate = trackedOutputs[i];
                if (candidate == output) {
                    targetIndex = i;
                    break;
                }
                if (!candidate && emptyIndex == 64) emptyIndex = i;
            }
            if (targetIndex == 64) targetIndex = emptyIndex;
        }
        if (!isAudio || targetIndex < 64) {
            @try {
                active = captureSessionCanDemand(ownerSession);
            } @catch (__unused NSException *exception) {
                active = NO;
            }
            stateRevision = nextCaptureSessionStateRevision(stateRevision);
            revision = stateRevision;
            if (isAudio) {
                previousObserver = ownership.observer;
                previousEpoch = ownership.epoch;
                const uint64_t epoch = nextCaptureSessionOutputEpoch();
                trackedOutputs[targetIndex] = output;
                trackedOutputEpochs[targetIndex] = epoch;
                ownership.observer = self;
                ownership.session = ownerSession;
                ownership.observerIdentity = captureObjectIdentity(self);
                ownership.sessionIdentity =
                    captureObjectIdentity(ownerSession);
                ownership.epoch = epoch;
            }
            claimed = YES;
        }
        os_unfair_lock_unlock(&outputLock);
    }

    if (claimed && previousObserver && previousEpoch != 0 &&
        previousObserver != self) {
        [previousObserver forgetTrackedOutput:output epoch:previousEpoch];
    }
    if (claimed) {
        if (revisionOut) *revisionOut = revision;
        if (activeOut) *activeOut = active;
    }
    return claimed;
}

- (uint64_t)beginLifecycleUpdate {
    os_unfair_lock_lock(&outputLock);
    stateRevision = nextCaptureSessionStateRevision(stateRevision);
    const uint64_t revision = stateRevision;
    os_unfair_lock_unlock(&outputLock);
    return revision;
}

- (uint64_t)beginAuthoritativeLifecycleUpdate:(BOOL *)activeOut {
    if (activeOut) *activeOut = NO;
    BOOL active = NO;
    uint64_t revision = 0;
    os_unfair_lock_lock(&outputLock);
    @try {
        AVCaptureSession *ownerSession = self.session;
        if (ownerSession &&
            ownerSessionIdentity == captureObjectIdentity(ownerSession) &&
            objc_getAssociatedObject(
                ownerSession,
                &gCaptureSessionObserverAssociationKey) == self) {
            @try {
                active = captureSessionCanDemand(ownerSession);
            } @catch (__unused NSException *exception) {
                active = NO;
            }
            stateRevision = nextCaptureSessionStateRevision(stateRevision);
            revision = stateRevision;
        }
    } @finally {
        os_unfair_lock_unlock(&outputLock);
    }
    if (revision != 0 && activeOut) *activeOut = active;
    return revision;
}

- (uint64_t)beginAuthoritativeConnectionUpdateForOutput:
                (AVCaptureAudioDataOutput *)output
                                          expectedEpoch:(uint64_t)expectedEpoch
                                               activeOut:(BOOL *)activeOut {
    if (activeOut) *activeOut = NO;
    if (!output || expectedEpoch == 0) return 0;
    BOOL active = NO;
    uint64_t revision = 0;
    @synchronized(output) {
        AVCaptureSession *ownerSession = self.session;
        if (!ownerSession ||
            ownerSessionIdentity != captureObjectIdentity(ownerSession) ||
            objc_getAssociatedObject(
                ownerSession,
                &gCaptureSessionObserverAssociationKey) != self ||
            ![ownerSession.outputs containsObject:output]) {
            return 0;
        }
        IUSCMicCaptureSessionOutputOwnership *ownership =
            objc_getAssociatedObject(
                output, &gCaptureSessionOutputOwnershipAssociationKey);
        os_unfair_lock_lock(&outputLock);
        @try {
            if (ownership.observer == self &&
                ownership.session == ownerSession &&
                ownership.observerIdentity == captureObjectIdentity(self) &&
                ownership.sessionIdentity == ownerSessionIdentity &&
                ownership.epoch == expectedEpoch) {
                for (size_t i = 0; i < 64; ++i) {
                    if (trackedOutputs[i] == output &&
                        trackedOutputEpochs[i] == expectedEpoch) {
                        @try {
                            active = captureSessionCanDemand(ownerSession);
                        } @catch (__unused NSException *exception) {
                            active = NO;
                        }
                        stateRevision =
                            nextCaptureSessionStateRevision(stateRevision);
                        revision = stateRevision;
                        break;
                    }
                }
            }
        } @finally {
            os_unfair_lock_unlock(&outputLock);
        }
    }
    if (revision != 0 && activeOut) *activeOut = active;
    return revision;
}

- (uint64_t)beginAuthoritativeConvergenceIfCurrent:(uint64_t)expectedRevision
                                          activeOut:(BOOL *)activeOut {
    if (activeOut) *activeOut = NO;
    if (expectedRevision == 0) return 0;
    BOOL active = NO;
    uint64_t revision = 0;
    os_unfair_lock_lock(&outputLock);
    @try {
        AVCaptureSession *ownerSession = self.session;
        if (stateRevision == expectedRevision && ownerSession &&
            ownerSessionIdentity == captureObjectIdentity(ownerSession) &&
            objc_getAssociatedObject(
                ownerSession,
                &gCaptureSessionObserverAssociationKey) == self) {
            @try {
                active = captureSessionCanDemand(ownerSession);
            } @catch (__unused NSException *exception) {
                active = NO;
            }
            stateRevision = nextCaptureSessionStateRevision(stateRevision);
            revision = stateRevision;
        }
    } @finally {
        os_unfair_lock_unlock(&outputLock);
    }
    if (revision != 0 && activeOut) *activeOut = active;
    return revision;
}

- (uint64_t)invalidateAndUntrackOutput:(AVCaptureOutput *)output
                              activeOut:(BOOL *)activeOut
                               epochOut:(uint64_t *)epochOut {
    if (activeOut) *activeOut = NO;
    if (epochOut) *epochOut = 0;
    if (!output) return [self beginLifecycleUpdate];
    BOOL active = NO;
    uint64_t revision = 0;
    uint64_t epoch = 0;
    @synchronized(output) {
        BOOL shouldRetire = NO;
        os_unfair_lock_lock(&outputLock);
        @try {
            active = captureSessionCanDemand(self.session);
        } @catch (__unused NSException *exception) {
            active = NO;
        }
        stateRevision = nextCaptureSessionStateRevision(stateRevision);
        revision = stateRevision;
        if ([output isKindOfClass:[AVCaptureAudioDataOutput class]]) {
            for (size_t i = 0; i < 64; ++i) {
                if (trackedOutputs[i] == output) {
                    epoch = trackedOutputEpochs[i];
                    trackedOutputs[i] = nil;
                    trackedOutputEpochs[i] = 0;
                    break;
                }
            }
            IUSCMicCaptureSessionOutputOwnership *ownership =
                objc_getAssociatedObject(
                    output, &gCaptureSessionOutputOwnershipAssociationKey);
            if (epoch != 0 &&
                ownership.observerIdentity == captureObjectIdentity(self) &&
                ownership.sessionIdentity == ownerSessionIdentity &&
                ownership.epoch == epoch) {
                ownership.observer = nil;
                ownership.session = nil;
                ownership.observerIdentity = 0;
                ownership.sessionIdentity = 0;
                ownership.epoch = 0;
                shouldRetire = YES;
            }
        }
        os_unfair_lock_unlock(&outputLock);
        if (shouldRetire) {
            setCaptureOutputLifecycle(output, false);
        }
    }
    if (activeOut) *activeOut = active;
    if (epochOut) *epochOut = epoch;
    return revision;
}

- (BOOL)setOutput:(AVCaptureOutput *)output
    activeIfOwned:(BOOL)activeState
          revision:(uint64_t)revision {
    return [self setOutput:output
             activeIfOwned:activeState
                   revision:revision
              expectedEpoch:0];
}

- (BOOL)setOutput:(AVCaptureOutput *)output
    activeIfOwned:(BOOL)activeState
          revision:(uint64_t)revision
     expectedEpoch:(uint64_t)expectedEpoch {
    if (![output isKindOfClass:[AVCaptureAudioDataOutput class]]) return YES;
    if (revision == 0) return NO;
    BOOL updated = NO;
    @synchronized(output) {
        AVCaptureSession *ownerSession = self.session;
        if (!ownerSession ||
            ownerSessionIdentity != captureObjectIdentity(ownerSession) ||
            objc_getAssociatedObject(
                ownerSession,
                &gCaptureSessionObserverAssociationKey) != self ||
            ![ownerSession.outputs containsObject:output]) {
            return NO;
        }
        IUSCMicCaptureSessionOutputOwnership *ownership =
            objc_getAssociatedObject(
                output, &gCaptureSessionOutputOwnershipAssociationKey);
        os_unfair_lock_lock(&outputLock);
        @try {
            if (stateRevision == revision &&
                ownership.observer == self &&
                ownership.session == ownerSession &&
                ownership.observerIdentity == captureObjectIdentity(self) &&
                ownership.sessionIdentity == ownerSessionIdentity &&
                ownership.epoch != 0 &&
                (expectedEpoch == 0 ||
                 ownership.epoch == expectedEpoch)) {
                for (size_t i = 0; i < 64; ++i) {
                    if (trackedOutputs[i] == output &&
                        trackedOutputEpochs[i] == ownership.epoch) {
                        BOOL outputCanDeliver = NO;
                        @try {
                            outputCanDeliver = captureOutputIsActive(
                                (AVCaptureAudioDataOutput *)output);
                        } @catch (__unused NSException *exception) {
                            outputCanDeliver = NO;
                        }
                        setCaptureOutputLifecycle(
                            output, activeState && outputCanDeliver);
                        updated = YES;
                        break;
                    }
                }
            }
        } @finally {
            os_unfair_lock_unlock(&outputLock);
        }
    }
    return updated;
}

- (void)failCloseOutputIfOwned:(AVCaptureOutput *)output
                       revision:(uint64_t)revision {
    if (![output isKindOfClass:[AVCaptureAudioDataOutput class]] ||
        revision == 0) return;
    @synchronized(output) {
        AVCaptureSession *ownerSession = self.session;
        if (!ownerSession ||
            ownerSessionIdentity != captureObjectIdentity(ownerSession) ||
            objc_getAssociatedObject(
                ownerSession,
                &gCaptureSessionObserverAssociationKey) != self ||
            ![ownerSession.outputs containsObject:output]) {
            return;
        }
        IUSCMicCaptureSessionOutputOwnership *ownership =
            objc_getAssociatedObject(
                output, &gCaptureSessionOutputOwnershipAssociationKey);
        os_unfair_lock_lock(&outputLock);
        @try {
            if (stateRevision == revision &&
                ownership.observer == self &&
                ownership.session == ownerSession &&
                ownership.observerIdentity == captureObjectIdentity(self) &&
                ownership.sessionIdentity == ownerSessionIdentity &&
                ownership.epoch != 0) {
                for (size_t i = 0; i < 64; ++i) {
                    if (trackedOutputs[i] == output &&
                        trackedOutputEpochs[i] == ownership.epoch) {
                        setCaptureOutputLifecycle(output, false);
                        break;
                    }
                }
            }
        } @finally {
            os_unfair_lock_unlock(&outputLock);
        }
    }
}

- (void)forgetTrackedOutput:(AVCaptureOutput *)output epoch:(uint64_t)epoch {
    if (!output || epoch == 0) return;
    os_unfair_lock_lock(&outputLock);
    for (size_t i = 0; i < 64; ++i) {
        if (trackedOutputs[i] == output && trackedOutputEpochs[i] == epoch) {
            trackedOutputs[i] = nil;
            trackedOutputEpochs[i] = 0;
            break;
        }
    }
    os_unfair_lock_unlock(&outputLock);
}
- (void)retireTrackedOutputsMatchingRevision:(uint64_t)revision
                                  requireMatch:(BOOL)requireMatch {
    __strong AVCaptureOutput *snapshot[64] = {};
    uint64_t snapshotEpochs[64] = {};
    os_unfair_lock_lock(&outputLock);
    if (requireMatch && (revision == 0 || stateRevision != revision)) {
        os_unfair_lock_unlock(&outputLock);
        return;
    }
    stateRevision = nextCaptureSessionStateRevision(stateRevision);
    for (size_t i = 0; i < 64; ++i) {
        snapshot[i] = trackedOutputs[i];
        snapshotEpochs[i] = trackedOutputEpochs[i];
        trackedOutputs[i] = nil;
        trackedOutputEpochs[i] = 0;
    }
    os_unfair_lock_unlock(&outputLock);
    for (size_t i = 0; i < 64; ++i) {
        if (!snapshot[i] || snapshotEpochs[i] == 0) continue;
        @try {
            @synchronized(snapshot[i]) {
                IUSCMicCaptureSessionOutputOwnership *ownership =
                    objc_getAssociatedObject(
                        snapshot[i],
                        &gCaptureSessionOutputOwnershipAssociationKey);
                if (ownership.observerIdentity == captureObjectIdentity(self) &&
                    ownership.sessionIdentity == ownerSessionIdentity &&
                    ownership.epoch == snapshotEpochs[i]) {
                    ownership.observer = nil;
                    ownership.session = nil;
                    ownership.observerIdentity = 0;
                    ownership.sessionIdentity = 0;
                    ownership.epoch = 0;
                    setCaptureOutputLifecycle(snapshot[i], false);
                }
            }
        } @catch (__unused NSException *exception) {
        }
    }
}

- (void)retireTrackedOutputsForRevision:(uint64_t)revision {
    [self retireTrackedOutputsMatchingRevision:revision requireMatch:YES];
}

- (void)retireTrackedOutputs {
    [self retireTrackedOutputsMatchingRevision:0 requireMatch:NO];
}

- (void)dealloc {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    for (id token in self.tokens) {
        [center removeObserver:token];
    }
    [self retireTrackedOutputs];
}

@end

%hook AVCaptureAudioDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    requireCriticalCHooksReady();
    IUSCMicCaptureOutputSentinel *sentinel = nil;
    NSException *primaryException = nil;
    @try {
        sentinel = ensureCaptureOutputSentinel(self);
    } @catch (NSException *exception) {
        primaryException = exception;
    }
    if (!sentinel) {
        if (primaryException) @throw primaryException;
        /* No publication owner can safely coexist with an Apple delegate. */
        failStopForCriticalHookFailure();
    }

    uint64_t transactionGeneration = 0;
    dispatch_group_t drainGroup = nil;
    dispatch_queue_t publishedQueue = nil;
    IUSCMicCaptureCursorBox *publishedBinding = nil;
    const BOOL registered = beginDirectCaptureDelegateSetterOperation(
        self, sentinel, &transactionGeneration, &drainGroup,
        &publishedQueue, &publishedBinding);
    if (!registered) {
        /* Saturated or non-exact state cannot authorize an Apple side effect. */
        failStopForCriticalHookFailure();
    }

    /* Hook readiness precedes Apple's first possible synchronous enqueue, but
     * requested identity is never treated as an authoritative live binding. */
    BOOL requestedClassHooked = delegate == nil;
    if (delegate) {
        @try {
            requestedClassHooked = hookAudioDelegateClass([delegate class]);
        } @catch (__unused NSException *exception) {
            requestedClassHooked = NO;
        }
    }
    const BOOL forceAppleNil = delegate && !requestedClassHooked;

    id preDelegate = nil;
    dispatch_queue_t preQueue = nil;
    dispatch_queue_t alternatePreQueue = nil;
    const BOOL prePairStable = snapshotDirectCaptureDelegateAndQueue(
        self, &preDelegate, &preQueue, &alternatePreQueue);

    @try {
        if (forceAppleNil) {
            %orig(nil, nil);
        } else {
            %orig;
        }
    } @catch (NSException *exception) {
        primaryException = exception;
    }

    /* Return order, not hook-entry order, owns the completion revision. */
    const uint64_t operationCompletionRevision =
        registerDirectCaptureDelegateCompletion(
            self, sentinel, transactionGeneration);

    id postDelegate = nil;
    dispatch_queue_t postQueue = nil;
    dispatch_queue_t alternatePostQueue = nil;
    const BOOL postPairStable = snapshotDirectCaptureDelegateAndQueue(
        self, &postDelegate, &postQueue, &alternatePostQueue);
    recordDirectCaptureDelegateQueueDebt(sentinel, drainGroup, publishedQueue);
    recordDirectCaptureDelegateQueueDebt(sentinel, drainGroup, queue);
    recordDirectCaptureDelegateQueueDebt(sentinel, drainGroup, preQueue);
    recordDirectCaptureDelegateQueueDebt(
        sentinel, drainGroup, alternatePreQueue);
    recordDirectCaptureDelegateQueueDebt(sentinel, drainGroup, postQueue);
    recordDirectCaptureDelegateQueueDebt(
        sentinel, drainGroup, alternatePostQueue);
    releaseRetiredDirectCaptureBindingAfterDrain(
        drainGroup, publishedBinding);

    BOOL shouldConverge = NO;
    uint64_t completionRevision =
        finishDirectCaptureDelegateCompletionDebts(
            self, sentinel, transactionGeneration,
            operationCompletionRevision,
            prePairStable && postPairStable, &shouldConverge);
    NSException *cleanupException = nil;

    /* A failed authoritative reconciliation reserves its own exact ordered nil
     * operation before invoking Apple. A later setter can join or supersede the
     * reservation, so obsolete cleanup can never unconditionally clear it. */
    for (unsigned cleanupAttempt = 0;
            shouldConverge && completionRevision != 0 && cleanupAttempt < 3;
            ++cleanupAttempt) {
        DirectCaptureDelegateConvergenceResult result =
            DirectCaptureDelegateConvergenceResult::NeedsClear;
        @try {
            result = convergeDirectCaptureDelegateCompletion(
                self, sentinel, transactionGeneration,
                completionRevision);
        } @catch (__unused NSException *exception) {
            result = directCaptureDelegateCompletionIsCurrent(
                         self, sentinel, transactionGeneration,
                         completionRevision)
                ? DirectCaptureDelegateConvergenceResult::NeedsClear
                : DirectCaptureDelegateConvergenceResult::Superseded;
        }
        if (result == DirectCaptureDelegateConvergenceResult::Committed ||
            result == DirectCaptureDelegateConvergenceResult::Superseded) {
            shouldConverge = NO;
            break;
        }

        uint64_t cleanupTransactionGeneration = 0;
        dispatch_group_t cleanupDrainGroup = nil;
        dispatch_queue_t cleanupPublishedQueue = nil;
        IUSCMicCaptureCursorBox *cleanupPublishedBinding = nil;
        if (!beginDirectCaptureDelegateCleanupIfCurrent(
                self, sentinel, transactionGeneration, completionRevision,
                &cleanupTransactionGeneration, &cleanupDrainGroup,
                &cleanupPublishedQueue, &cleanupPublishedBinding)) {
            shouldConverge = NO;
            break;
        }

        id cleanupPreDelegate = nil;
        dispatch_queue_t cleanupPreQueue = nil;
        dispatch_queue_t cleanupAlternatePreQueue = nil;
        const BOOL cleanupPrePairStable =
            snapshotDirectCaptureDelegateAndQueue(
                self, &cleanupPreDelegate, &cleanupPreQueue,
                &cleanupAlternatePreQueue);
        NSException *attemptException = nil;
        @try {
            %orig(nil, nil);
        } @catch (NSException *exception) {
            attemptException = exception;
        }
        const uint64_t cleanupOperationCompletionRevision =
            registerDirectCaptureDelegateCompletion(
                self, sentinel, cleanupTransactionGeneration);
        id cleanupPostDelegate = nil;
        dispatch_queue_t cleanupPostQueue = nil;
        dispatch_queue_t cleanupAlternatePostQueue = nil;
        const BOOL cleanupPostPairStable =
            snapshotDirectCaptureDelegateAndQueue(
                self, &cleanupPostDelegate, &cleanupPostQueue,
                &cleanupAlternatePostQueue);
        recordDirectCaptureDelegateQueueDebt(
            sentinel, cleanupDrainGroup, cleanupPublishedQueue);
        recordDirectCaptureDelegateQueueDebt(
            sentinel, cleanupDrainGroup, cleanupPreQueue);
        recordDirectCaptureDelegateQueueDebt(
            sentinel, cleanupDrainGroup, cleanupAlternatePreQueue);
        recordDirectCaptureDelegateQueueDebt(
            sentinel, cleanupDrainGroup, cleanupPostQueue);
        recordDirectCaptureDelegateQueueDebt(
            sentinel, cleanupDrainGroup, cleanupAlternatePostQueue);
        releaseRetiredDirectCaptureBindingAfterDrain(
            cleanupDrainGroup, cleanupPublishedBinding);
        transactionGeneration = cleanupTransactionGeneration;
        completionRevision = finishDirectCaptureDelegateCompletionDebts(
            self, sentinel, transactionGeneration,
            cleanupOperationCompletionRevision,
            cleanupPrePairStable && cleanupPostPairStable,
            &shouldConverge);
        if (attemptException && !cleanupException) {
            cleanupException = attemptException;
        }
    }

    if (shouldConverge && completionRevision != 0) {
        IUSCMicCaptureCursorBox *retiredBinding =
            retireDirectCaptureCompletionIfCurrent(
                self, sentinel, transactionGeneration,
                completionRevision);
        releaseRetiredDirectCaptureBindingAfterDrain(
            sentinel->delegateDrainGroup, retiredBinding);
    }
    if (primaryException) @throw primaryException;
    if (cleanupException) @throw cleanupException;
}

%end

%hook AVCaptureDataOutputSynchronizer

- (instancetype)initWithDataOutputs:(NSArray<AVCaptureOutput *> *)dataOutputs {
    AVCaptureDataOutputSynchronizer *result = %orig;
    if (result) {
        @try {
            (void)ensureSynchronizerSentinel(result);
        } @catch (__unused NSException *exception) {
            /* Delegate installation will remain fail-closed without a sentinel. */
        }
    }
    return result;
}

- (void)setDelegate:(id<AVCaptureDataOutputSynchronizerDelegate>)delegate
               queue:(dispatch_queue_t)delegateCallbackQueue {
    requireCriticalCHooksReady();
    IUSCMicSynchronizerSentinel *sentinel = nil;
    NSException *primaryException = nil;
    @try {
        sentinel = ensureSynchronizerSentinel(self);
    } @catch (NSException *exception) {
        primaryException = exception;
    }

    uint64_t transactionGeneration = 0;
    dispatch_group_t drainGroup = nil;
    dispatch_queue_t publishedQueue = nil;
    const BOOL registered = !primaryException &&
        beginSynchronizerDelegateSetterOperation(
            self, sentinel, &transactionGeneration,
            &drainGroup, &publishedQueue);
    if (!registered) {
        /* Without a published sentinel no requested delegate may become a
         * physical-microphone bypass. Clear Apple state outside custom locks. */
        @try {
            %orig(nil, nil);
        } @catch (NSException *exception) {
            if (!primaryException) primaryException = exception;
        }
        [sentinel retireAllBindings];
        if (primaryException) @throw primaryException;
        return;
    }

    /*
     * This is hook readiness only, never requested binding ownership. Apple may
     * synchronously enqueue the new delegate before its setter returns, so the
     * requested class must already route through the fail-closed callback shim.
     */
    BOOL requestedClassHooked = delegate == nil;
    if (delegate) {
        @try {
            requestedClassHooked =
                hookSynchronizerDelegateClass([delegate class]);
        } @catch (__unused NSException *exception) {
            requestedClassHooked = NO;
        }
    }
    const BOOL forceAppleNil = delegate && !requestedClassHooked;

    id preDelegate = nil;
    dispatch_queue_t preQueue = nil;
    dispatch_queue_t alternatePreQueue = nil;
    const BOOL prePairStable = snapshotSynchronizerDelegateAndQueue(
        self, &preDelegate, &preQueue, &alternatePreQueue);

    @try {
        /* Requested delegate/queue are not authoritative until Apple returns. */
        if (forceAppleNil) {
            %orig(nil, nil);
        } else {
            %orig;
        }
    } @catch (NSException *exception) {
        primaryException = exception;
    }

    id postDelegate = nil;
    dispatch_queue_t postQueue = nil;
    dispatch_queue_t alternatePostQueue = nil;
    const BOOL postPairStable = snapshotSynchronizerDelegateAndQueue(
        self, &postDelegate, &postQueue, &alternatePostQueue);
    /* All debts are enqueued only after Apple's side effect returns or throws. */
    recordSynchronizerDelegateQueueDebt(
        sentinel, drainGroup, publishedQueue);
    recordSynchronizerDelegateQueueDebt(
        sentinel, drainGroup, delegateCallbackQueue);
    recordSynchronizerDelegateQueueDebt(sentinel, drainGroup, preQueue);
    recordSynchronizerDelegateQueueDebt(
        sentinel, drainGroup, alternatePreQueue);
    recordSynchronizerDelegateQueueDebt(sentinel, drainGroup, postQueue);
    recordSynchronizerDelegateQueueDebt(
        sentinel, drainGroup, alternatePostQueue);

    BOOL shouldConverge = NO;
    uint64_t completionRevision =
        completeSynchronizerDelegateSetterOperation(
            self, sentinel, registered, transactionGeneration,
            prePairStable && postPairStable, &shouldConverge);
    NSException *cleanupException = nil;

    /* A failed authoritative reconciliation becomes its own ordered Apple nil
     * operation. Newer external setters can enter concurrently; exact revision
     * checks ensure this cleanup cannot erase their later result. */
    for (unsigned cleanupAttempt = 0;
            shouldConverge && completionRevision != 0 && cleanupAttempt < 3;
            ++cleanupAttempt) {
        SynchronizerDelegateConvergenceResult result =
            SynchronizerDelegateConvergenceResult::NeedsClear;
        @try {
            result = convergeSynchronizerDelegateCompletion(
                self, sentinel, transactionGeneration,
                completionRevision);
        } @catch (__unused NSException *exception) {
            result = synchronizerDelegateCompletionIsCurrent(
                         self, sentinel, transactionGeneration,
                         completionRevision)
                ? SynchronizerDelegateConvergenceResult::NeedsClear
                : SynchronizerDelegateConvergenceResult::Superseded;
        }
        if (result == SynchronizerDelegateConvergenceResult::Committed ||
            result == SynchronizerDelegateConvergenceResult::Superseded) {
            shouldConverge = NO;
            break;
        }
        uint64_t cleanupTransactionGeneration = 0;
        dispatch_group_t cleanupDrainGroup = nil;
        dispatch_queue_t cleanupPublishedQueue = nil;
        if (!beginSynchronizerDelegateCleanupIfCurrent(
                self, sentinel, transactionGeneration, completionRevision,
                &cleanupTransactionGeneration, &cleanupDrainGroup,
                &cleanupPublishedQueue)) {
            shouldConverge = NO;
            break;
        }

        id cleanupPreDelegate = nil;
        dispatch_queue_t cleanupPreQueue = nil;
        dispatch_queue_t cleanupAlternatePreQueue = nil;
        const BOOL cleanupPrePairStable =
            snapshotSynchronizerDelegateAndQueue(
                self, &cleanupPreDelegate, &cleanupPreQueue,
                &cleanupAlternatePreQueue);
        NSException *attemptException = nil;
        @try {
            %orig(nil, nil);
        } @catch (NSException *exception) {
            attemptException = exception;
        }
        id cleanupPostDelegate = nil;
        dispatch_queue_t cleanupPostQueue = nil;
        dispatch_queue_t cleanupAlternatePostQueue = nil;
        const BOOL cleanupPostPairStable =
            snapshotSynchronizerDelegateAndQueue(
                self, &cleanupPostDelegate, &cleanupPostQueue,
                &cleanupAlternatePostQueue);
        recordSynchronizerDelegateQueueDebt(
            sentinel, cleanupDrainGroup, cleanupPublishedQueue);
        recordSynchronizerDelegateQueueDebt(
            sentinel, cleanupDrainGroup, cleanupPreQueue);
        recordSynchronizerDelegateQueueDebt(
            sentinel, cleanupDrainGroup, cleanupAlternatePreQueue);
        recordSynchronizerDelegateQueueDebt(
            sentinel, cleanupDrainGroup, cleanupPostQueue);
        recordSynchronizerDelegateQueueDebt(
            sentinel, cleanupDrainGroup, cleanupAlternatePostQueue);
        transactionGeneration = cleanupTransactionGeneration;
        completionRevision =
            completeSynchronizerDelegateSetterOperation(
                self, sentinel, YES, transactionGeneration,
                cleanupPrePairStable && cleanupPostPairStable,
                &shouldConverge);
        if (attemptException && !cleanupException) {
            cleanupException = attemptException;
        }
    }

    if (shouldConverge) {
        /* Bounded cleanup exhaustion remains locally retired. */
        [sentinel retireAllBindings];
    }
    if (primaryException) @throw primaryException;
    if (cleanupException) @throw cleanupException;
}

%end

%hook AVCaptureSession

- (void)beginConfiguration {
    requireCriticalCHooksReady();
    ensureCaptureSessionObserver(self);
    IUSCMicCaptureSessionObserver *observer = objc_getAssociatedObject(
        self, &gCaptureSessionObserverAssociationKey);
    beginCaptureSessionConfigurationScope(self, observer);
    NSException *operationException = nil;
    @try {
        %orig;
    } @catch (NSException *exception) {
        operationException = exception;
    }
    @try {
        finishCaptureSessionConfigurationScope(
            self, observer, operationException == nil, YES);
    } @catch (__unused NSException *cleanupException) {
        @try {
            (void)setCaptureSessionDemandForObserver(self, observer, false);
        } @catch (__unused NSException *failClosedException) {
        }
    }
    if (operationException) @throw operationException;
}

- (void)commitConfiguration {
    requireCriticalCHooksReady();
    ensureCaptureSessionObserver(self);
    IUSCMicCaptureSessionObserver *observer = objc_getAssociatedObject(
        self, &gCaptureSessionObserverAssociationKey);
    NSException *operationException = nil;
    @try {
        %orig;
    } @catch (NSException *exception) {
        operationException = exception;
    }
    @try {
        finishCaptureSessionConfigurationScope(
            self, observer, operationException == nil, NO);
    } @catch (__unused NSException *cleanupException) {
        @try {
            (void)setCaptureSessionDemandForObserver(self, observer, false);
        } @catch (__unused NSException *failClosedException) {
        }
    }
    if (operationException) @throw operationException;
}

- (void)addInput:(AVCaptureInput *)input {
    requireCriticalCHooksReady();
    ensureCaptureSessionObserver(self);
    IUSCMicCaptureSessionObserver *observer = objc_getAssociatedObject(
        self, &gCaptureSessionObserverAssociationKey);
    beginCaptureSessionTopologyMutation(self, observer);
    NSException *operationException = nil;
    @try {
        %orig;
    } @catch (NSException *exception) {
        operationException = exception;
    }
    @try {
        finishCaptureSessionTopologyMutation(
            self, observer, operationException == nil);
    } @catch (__unused NSException *cleanupException) {
        @try {
            (void)setCaptureSessionDemandForObserver(self, observer, false);
        } @catch (__unused NSException *failClosedException) {
        }
    }
    if (operationException) @throw operationException;
}

- (void)addInputWithNoConnections:(AVCaptureInput *)input {
    requireCriticalCHooksReady();
    ensureCaptureSessionObserver(self);
    IUSCMicCaptureSessionObserver *observer = objc_getAssociatedObject(
        self, &gCaptureSessionObserverAssociationKey);
    beginCaptureSessionTopologyMutation(self, observer);
    NSException *operationException = nil;
    @try {
        %orig;
    } @catch (NSException *exception) {
        operationException = exception;
    }
    @try {
        finishCaptureSessionTopologyMutation(
            self, observer, operationException == nil);
    } @catch (__unused NSException *cleanupException) {
        @try {
            (void)setCaptureSessionDemandForObserver(self, observer, false);
        } @catch (__unused NSException *failClosedException) {
        }
    }
    if (operationException) @throw operationException;
}

- (void)removeInput:(AVCaptureInput *)input {
    requireCriticalCHooksReady();
    ensureCaptureSessionObserver(self);
    IUSCMicCaptureSessionObserver *observer = objc_getAssociatedObject(
        self, &gCaptureSessionObserverAssociationKey);
    beginCaptureSessionTopologyMutation(self, observer);
    NSException *operationException = nil;
    @try {
        %orig;
    } @catch (NSException *exception) {
        operationException = exception;
    }
    @try {
        finishCaptureSessionTopologyMutation(
            self, observer, operationException == nil);
    } @catch (__unused NSException *cleanupException) {
        @try {
            (void)setCaptureSessionDemandForObserver(self, observer, false);
        } @catch (__unused NSException *failClosedException) {
        }
    }
    if (operationException) @throw operationException;
}

- (void)startRunning {
    requireCriticalCHooksReady();
    NSException *operationException = nil;
    @try {
        IUSCMicStreamClientStart();
        ensureCaptureSessionObserver(self);
        /* Arm before AVFoundation can deliver its first real-time callback. */
        setCaptureSessionDemand(self, true);
        %orig;
    } @catch (NSException *exception) {
        operationException = exception;
    } @finally {
        @try {
            /* isRunning/isInterrupted are authoritative even after an exception. */
            convergeCaptureSessionDemand(self);
        } @catch (NSException *convergenceException) {
            @try {
                setCaptureSessionDemand(self, false);
            } @catch (__unused NSException *failClosedException) {
            }
            if (!operationException) @throw convergenceException;
        }
    }
    if (operationException) @throw operationException;
}

- (void)stopRunning {
    requireCriticalCHooksReady();
    NSException *operationException = nil;
    @try {
        /* Tail callbacks during stop remain silent until authoritative convergence. */
        setCaptureSessionDemand(self, false);
        %orig;
    } @catch (NSException *exception) {
        operationException = exception;
    } @finally {
        @try {
            /* A failed stop may leave the session running; re-arm only then. */
            convergeCaptureSessionDemand(self);
        } @catch (NSException *convergenceException) {
            @try {
                setCaptureSessionDemand(self, false);
            } @catch (__unused NSException *failClosedException) {
            }
            if (!operationException) @throw convergenceException;
        }
    }
    if (operationException) @throw operationException;
}

- (void)addOutput:(AVCaptureOutput *)output {
    requireCriticalCHooksReady();
    ensureCaptureSessionObserver(self);
    IUSCMicCaptureSessionObserver *observer = objc_getAssociatedObject(
        self, &gCaptureSessionObserverAssociationKey);
    beginCaptureSessionTopologyMutation(self, observer);
    NSException *operationException = nil;
    @try {
        %orig;
    } @catch (NSException *exception) {
        operationException = exception;
    }
    if (operationException) {
        @try {
            failCloseCaptureOutputForSession(output, self, observer);
        } @catch (__unused NSException *failClosedException) {
        }
        @try {
            finishCaptureSessionTopologyMutation(self, observer, NO);
        } @catch (__unused NSException *cleanupException) {
        }
        @throw operationException;
    }
    @try {
        if (!authoritativelyCommitAddedCaptureOutput(
                self, observer, output)) {
            failCloseCaptureOutputAfterStateFailure(self, observer, output);
        } else {
            associateCaptureConnectionsForOutput(self, observer, output);
        }
    } @catch (__unused NSException *exception) {
        failCloseCaptureOutputAfterStateFailure(self, observer, output);
    }
    @try {
        finishCaptureSessionTopologyMutation(self, observer, YES);
    } @catch (__unused NSException *cleanupException) {
        @try {
            (void)setCaptureSessionDemandForObserver(self, observer, false);
        } @catch (__unused NSException *failClosedException) {
        }
    }
}

- (void)addOutputWithNoConnections:(AVCaptureOutput *)output {
    requireCriticalCHooksReady();
    ensureCaptureSessionObserver(self);
    IUSCMicCaptureSessionObserver *observer = objc_getAssociatedObject(
        self, &gCaptureSessionObserverAssociationKey);
    beginCaptureSessionTopologyMutation(self, observer);
    NSException *operationException = nil;
    @try {
        %orig;
    } @catch (NSException *exception) {
        operationException = exception;
    }
    if (operationException) {
        @try {
            failCloseCaptureOutputForSession(output, self, observer);
        } @catch (__unused NSException *failClosedException) {
        }
        @try {
            finishCaptureSessionTopologyMutation(self, observer, NO);
        } @catch (__unused NSException *cleanupException) {
        }
        @throw operationException;
    }
    @try {
        if (!authoritativelyCommitAddedCaptureOutput(
                self, observer, output)) {
            failCloseCaptureOutputAfterStateFailure(self, observer, output);
        } else {
            associateCaptureConnectionsForOutput(self, observer, output);
        }
    } @catch (__unused NSException *exception) {
        failCloseCaptureOutputAfterStateFailure(self, observer, output);
    }
    @try {
        finishCaptureSessionTopologyMutation(self, observer, YES);
    } @catch (__unused NSException *cleanupException) {
        @try {
            (void)setCaptureSessionDemandForObserver(self, observer, false);
        } @catch (__unused NSException *failClosedException) {
        }
    }
}

- (void)removeOutput:(AVCaptureOutput *)output {
    requireCriticalCHooksReady();
    ensureCaptureSessionObserver(self);
    IUSCMicCaptureSessionObserver *observer = objc_getAssociatedObject(
        self, &gCaptureSessionObserverAssociationKey);
    beginCaptureSessionTopologyMutation(self, observer);
    uint64_t preRemovalRevision = 0;
    uint64_t invalidatedOutputEpoch = 0;
    @try {
        preRemovalRevision =
            invalidateCaptureOutputAndApply(
                self, observer, output, &invalidatedOutputEpoch);
        clearCaptureConnectionAssociationsForOutput(
            self, observer, output, invalidatedOutputEpoch);
    } @catch (__unused NSException *exception) {
        failCloseCaptureOutputAfterStateFailure(self, observer, output);
    }

    NSException *operationException = nil;
    @try {
        %orig;
    } @catch (NSException *exception) {
        operationException = exception;
    }

    if (operationException) {
        /* Never replace AVFoundation's exception with cleanup failure. */
        failCloseCaptureOutputAfterStateFailure(self, observer, output);
        @try {
            finishCaptureSessionTopologyMutation(self, observer, NO);
        } @catch (__unused NSException *cleanupException) {
        }
        @throw operationException;
    }

    @try {
        const BOOL remainsMember = [self.outputs containsObject:output];
        if (remainsMember) {
            if (!authoritativelyCommitAddedCaptureOutput(
                    self, observer, output)) {
                failCloseCaptureOutputAfterStateFailure(
                    self, observer, output);
            } else {
                associateCaptureConnectionsForOutput(
                    self, observer, output);
            }
        } else {
            /*
             * If no newer event ran during AVFoundation, converge the exact
             * pre-removal revision against the now-authoritative membership.
             */
            convergeCaptureSessionDemandIfCurrent(
                self, observer, preRemovalRevision);
        }
    } @catch (__unused NSException *exception) {
        @try {
            failCloseCaptureOutputAfterStateFailure(
                self, observer, output);
        } @catch (__unused NSException *failClosedException) {
        }
    }
    @try {
        finishCaptureSessionTopologyMutation(self, observer, YES);
    } @catch (__unused NSException *cleanupException) {
        @try {
            (void)setCaptureSessionDemandForObserver(self, observer, false);
        } @catch (__unused NSException *failClosedException) {
        }
    }
}

- (void)addConnection:(AVCaptureConnection *)connection {
    requireCriticalCHooksReady();
    IUSCMicCaptureConnectionOperation *operation =
        beginCaptureConnectionOperation(connection, self);
    ensureCaptureSessionObserver(self);
    IUSCMicCaptureSessionObserver *observer = objc_getAssociatedObject(
        self, &gCaptureSessionObserverAssociationKey);
    markCaptureSessionConnectionOperationDirty(self, observer);
    AVCaptureAudioDataOutput *candidate = nil;
    @try {
        (void)preSilenceCaptureConnectionOperation(
            operation, NO);
        candidate = audioOutputForCaptureConnectionInSession(
            self, connection, true);
        if (candidate) {
            IUSCMicCaptureConnectionAssociation *association =
                associateCaptureConnection(
                    connection, self, observer, candidate, NO, operation);
            if (association) {
                registerCaptureConnectionAssociation(association);
            }
        }
        (void)preSilenceCaptureConnectionOperation(
            operation, NO);
    } @catch (__unused NSException *exception) {
        (void)preSilenceCaptureConnectionOperation(
            operation, NO);
    }

    NSException *operationException = nil;
    @try {
        %orig;
    } @catch (NSException *exception) {
        operationException = exception;
    }

    if (operationException) {
        @try {
            (void)completeCaptureConnectionOperation(
                operation, NO);
            finishCaptureSessionConnectionOperation(
                self, observer, NO);
        } @catch (__unused NSException *cleanupException) {
        }
        @throw operationException;
    }

    @try {
        AVCaptureAudioDataOutput *currentOutput =
            audioOutputForCaptureConnectionInSession(
                self, connection, false);
        if (currentOutput) {
            IUSCMicCaptureConnectionAssociation *association =
                associateCaptureConnection(
                    connection, self, observer, currentOutput, YES, operation);
            if (association) {
                registerCaptureConnectionAssociation(association);
            }
            (void)completeCaptureConnectionOperation(
                operation, YES);
        } else {
            (void)completeCaptureConnectionRemoval(
                operation);
        }
        finishCaptureSessionConnectionOperation(self, observer, YES);
    } @catch (__unused NSException *exception) {
        (void)completeCaptureConnectionOperation(
            operation, NO);
        finishCaptureSessionConnectionOperation(self, observer, NO);
    }
}

- (void)removeConnection:(AVCaptureConnection *)connection {
    requireCriticalCHooksReady();
    IUSCMicCaptureConnectionOperation *operation =
        beginCaptureConnectionOperation(connection, self);
    ensureCaptureSessionObserver(self);
    IUSCMicCaptureSessionObserver *observer = objc_getAssociatedObject(
        self, &gCaptureSessionObserverAssociationKey);
    markCaptureSessionConnectionOperationDirty(self, observer);
    AVCaptureAudioDataOutput *candidate = nil;
    @try {
        (void)preSilenceCaptureConnectionOperation(
            operation, NO);
        candidate = audioOutputForCaptureConnectionInSession(
            self, connection, false);
        if (candidate) {
            IUSCMicCaptureConnectionAssociation *association =
                associateCaptureConnection(
                    connection, self, observer, candidate, YES, operation);
            if (association) {
                registerCaptureConnectionAssociation(association);
            }
        }
        (void)preSilenceCaptureConnectionOperation(
            operation, YES);
    } @catch (__unused NSException *exception) {
        (void)preSilenceCaptureConnectionOperation(
            operation, NO);
    }

    NSException *operationException = nil;
    @try {
        %orig;
    } @catch (NSException *exception) {
        operationException = exception;
    }

    if (operationException) {
        @try {
            (void)completeCaptureConnectionOperation(
                operation, NO);
            finishCaptureSessionConnectionOperation(
                self, observer, NO);
        } @catch (__unused NSException *cleanupException) {
        }
        @throw operationException;
    }

    @try {
        AVCaptureAudioDataOutput *remaining =
            audioOutputForCaptureConnectionInSession(
                self, connection, false);
        if (remaining) {
            IUSCMicCaptureConnectionAssociation *association =
                associateCaptureConnection(
                    connection, self, observer, remaining, YES, operation);
            if (association) {
                registerCaptureConnectionAssociation(association);
            }
            (void)completeCaptureConnectionOperation(
                operation, YES);
        } else {
            (void)completeCaptureConnectionRemoval(
                operation);
        }
        finishCaptureSessionConnectionOperation(self, observer, YES);
    } @catch (__unused NSException *exception) {
        (void)completeCaptureConnectionOperation(
            operation, NO);
        finishCaptureSessionConnectionOperation(self, observer, NO);
    }
}

%end

%hook AVCaptureConnection

- (void)setEnabled:(BOOL)enabled {
    requireCriticalCHooksReady();
    IUSCMicCaptureConnectionOperation *operation =
        beginCaptureConnectionOperation(self, nil);
    @try {
        (void)preSilenceCaptureConnectionOperation(
            operation, YES);
        IUSCMicCaptureConnectionAssociation *association =
            associateCaptureConnectionFromCurrentOutputOwner(
                self, operation);
        if (association) {
            registerCaptureConnectionAssociation(association);
        }
        (void)preSilenceCaptureConnectionOperation(
            operation, YES);
    } @catch (__unused NSException *exception) {
        (void)preSilenceCaptureConnectionOperation(
            operation, NO);
    }

    NSException *operationException = nil;
    @try {
        %orig;
    } @catch (NSException *exception) {
        operationException = exception;
    }

    @try {
        /* Completion ordering is allocated only after Apple's setter returns
         * or throws; the newest exact-token completion re-reads actual state. */
        (void)completeCaptureConnectionOperation(
            operation, YES);
    } @catch (__unused NSException *exception) {
        (void)authoritativeConvergeCurrentCaptureConnectionOwner(self);
    }
    if (operationException) @throw operationException;
}

%end

static bool IUSCMicShouldExcludeCurrentProcess(void) {
    const char *name = getprogname();
    if (!name) return false;
    static const char *const excluded[] = {
        "IPhoneUSBMicD",
        "trollvncserver",
        "trollvncmanager",
        "TrollVNC",
    };
    for (const char *candidate : excluded) {
        if (strcmp(name, candidate) == 0) return true;
    }
    return false;
}

%ctor {
    if (IUSCMicShouldExcludeCurrentProcess()) return;
    MSHookFunction((void *)AudioComponentInstanceNew,
                   (void *)replacementAudioComponentInstanceNew,
                   (void **)&originalAudioComponentInstanceNew);
    MSHookFunction((void *)AudioComponentInstanceDispose,
                   (void *)replacementAudioComponentInstanceDispose,
                   (void **)&originalAudioComponentInstanceDispose);
    MSHookFunction((void *)AudioUnitSetProperty,
                   (void *)replacementAudioUnitSetProperty,
                   (void **)&originalAudioUnitSetProperty);
    MSHookFunction((void *)AudioUnitRender,
                   (void *)replacementAudioUnitRender,
                   (void **)&originalAudioUnitRender);
    MSHookFunction((void *)AudioOutputUnitStart,
                   (void *)replacementAudioOutputUnitStart,
                   (void **)&originalAudioOutputUnitStart);
    MSHookFunction((void *)AudioOutputUnitStop,
                   (void *)replacementAudioOutputUnitStop,
                   (void **)&originalAudioOutputUnitStop);
    MSHookFunction((void *)AudioQueueNewInput,
                   (void *)replacementAudioQueueNewInput,
                   (void **)&originalAudioQueueNewInput);
    MSHookFunction((void *)AudioQueueNewInputWithDispatchQueue,
                   (void *)replacementAudioQueueNewInputWithDispatchQueue,
                   (void **)&originalAudioQueueNewInputWithDispatchQueue);
    MSHookFunction((void *)AudioQueueDispose,
                   (void *)replacementAudioQueueDispose,
                   (void **)&originalAudioQueueDispose);
    MSHookFunction((void *)AudioQueueStart,
                   (void *)replacementAudioQueueStart,
                   (void **)&originalAudioQueueStart);
    MSHookFunction((void *)AudioQueueStop,
                   (void *)replacementAudioQueueStop,
                   (void **)&originalAudioQueueStop);
    MSHookFunction((void *)AudioQueuePause,
                   (void *)replacementAudioQueuePause,
                   (void **)&originalAudioQueuePause);
    MSHookFunction((void *)AudioQueueFlush,
                   (void *)replacementAudioQueueFlush,
                   (void **)&originalAudioQueueFlush);
    MSHookFunction((void *)AudioQueueReset,
                   (void *)replacementAudioQueueReset,
                   (void **)&originalAudioQueueReset);
    MSHookFunction((void *)AudioQueuePrime,
                   (void *)replacementAudioQueuePrime,
                   (void **)&originalAudioQueuePrime);
    const bool allCriticalHooksReady =
        originalAudioComponentInstanceNew &&
        originalAudioComponentInstanceDispose &&
        originalAudioUnitSetProperty &&
        originalAudioUnitRender &&
        originalAudioOutputUnitStart &&
        originalAudioOutputUnitStop &&
        originalAudioQueueNewInput &&
        originalAudioQueueNewInputWithDispatchQueue &&
        originalAudioQueueDispose &&
        originalAudioQueueStart &&
        originalAudioQueueStop &&
        originalAudioQueuePause &&
        originalAudioQueueFlush &&
        originalAudioQueueReset &&
        originalAudioQueuePrime;
    if (!allCriticalHooksReady) {
        failStopForCriticalHookFailure();
    }
    gCriticalCHooksReady.store(true, std::memory_order_release);
    %init;
}
