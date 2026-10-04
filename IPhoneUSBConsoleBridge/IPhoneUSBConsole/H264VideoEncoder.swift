import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct H264StreamConfiguration: Equatable, Sendable {
    let codec: String
    let codedWidth: Int
    let codedHeight: Int
    let avcDecoderConfigurationRecord: Data
}

struct H264AccessUnit: Sendable {
    let sequence: UInt32
    let timestampMicroseconds: UInt64
    let isKeyFrame: Bool
    let avccData: Data
}

/// Hardware-backed, latest-frame-first H.264 encoder for the web companion.
///
/// Capture callbacks only replace a single pending sample. VideoToolbox is
/// allowed one in-flight frame, B-frames are disabled, and a new key frame is
/// generated on the configured GOP interval, while a viewer may request an
/// immediate resynchronization frame without building a frame backlog.
final class H264VideoEncoder: @unchecked Sendable {
    typealias ConfigurationHandler = @Sendable (H264StreamConfiguration) -> Void
    typealias AccessUnitHandler = @Sendable (H264AccessUnit) -> Void

    var onConfiguration: ConfigurationHandler?
    var onAccessUnit: AccessUnitHandler?

    private struct PendingFrame {
        let sampleBuffer: CMSampleBuffer
        let timestampMicroseconds: UInt64
    }

    private let stateLock = NSLock()
    private let configuration: VideoEncoderConfiguration
    private let encoderQueue = DispatchQueue(
        label: "local.iphone.usbconsole.web-h264",
        qos: .userInteractive
    )
    private let encoderQueueKey = DispatchSpecificKey<UInt8>()

    private var active = false
    private var pendingFrame: PendingFrame?
    private var drainScheduled = false
    private var inFlightAttemptID: UInt64?
    private var nextAttemptID: UInt64 = 0
    private var forceNextKeyFrame = true
    private var lastSubmittedTimestamp: UInt64 = 0
    private var lastForcedKeyFrameUptimeNanoseconds: UInt64 = 0

    // Accessed only on encoderQueue.
    private var compressionSession: VTCompressionSession?
    private struct SessionGeometry {
        let sourceWidth: Int32
        let sourceHeight: Int32
        let encodedWidth: Int32
        let encodedHeight: Int32
        let pixelFormat: OSType
    }

    private var sessionGeometry: SessionGeometry?
    private var publishedConfiguration: H264StreamConfiguration?
    private var outputSequence: UInt32 = 0
    private var encodeWatchdogWorkItem: DispatchWorkItem?
    private var pixelTransferSession: VTPixelTransferSession?
    private var resizedPixelBufferPool: CVPixelBufferPool?

    init(configuration: VideoEncoderConfiguration = .productionDefault) {
        self.configuration = configuration
        encoderQueue.setSpecific(key: encoderQueueKey, value: 1)
    }

    deinit {
        stop()
    }

    func start() {
        stateLock.lock()
        active = true
        forceNextKeyFrame = true
        lastForcedKeyFrameUptimeNanoseconds = 0
        stateLock.unlock()
    }

    func stop() {
        stateLock.lock()
        active = false
        pendingFrame = nil
        drainScheduled = false
        stateLock.unlock()

        let invalidate = { [self] in
            encodeWatchdogWorkItem?.cancel()
            encodeWatchdogWorkItem = nil
            if let compressionSession { VTCompressionSessionInvalidate(compressionSession) }
            compressionSession = nil
            sessionGeometry = nil
            pixelTransferSession = nil
            resizedPixelBufferPool = nil
            publishedConfiguration = nil
            outputSequence = 0
            stateLock.lock()
            inFlightAttemptID = nil
            nextAttemptID = 0
            lastSubmittedTimestamp = 0
            lastForcedKeyFrameUptimeNanoseconds = 0
            stateLock.unlock()
        }

        if DispatchQueue.getSpecific(key: encoderQueueKey) != nil {
            invalidate()
        } else {
            encoderQueue.sync(execute: invalidate)
        }
    }

    /// Called directly from the AVFoundation sample queue. This method never
    /// waits for VideoToolbox and retains at most one not-yet-encoded sample.
    func submit(_ sampleBuffer: CMSampleBuffer, timing: USBScreenCapture.SampleTiming) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }

        // Use the capture session's presentation time converted onto the host
        // clock, matching the USB audio stream. Fall back to callback arrival
        // when the device does not expose a synchronization clock.
        var timestamp = Self.microseconds(for: timing.presentationHostTime ?? timing.hostArrivalTime)
        stateLock.lock()
        guard active else {
            stateLock.unlock()
            return
        }
        if timestamp <= lastSubmittedTimestamp {
            timestamp = lastSubmittedTimestamp &+ 1
        }
        lastSubmittedTimestamp = timestamp
        pendingFrame = PendingFrame(sampleBuffer: sampleBuffer, timestampMicroseconds: timestamp)
        scheduleDrainLocked()
        stateLock.unlock()
    }

    func requestKeyFrame() {
        stateLock.lock()
        forceNextKeyFrame = true
        stateLock.unlock()
    }

    private func scheduleDrainLocked() {
        guard active, !drainScheduled, inFlightAttemptID == nil, pendingFrame != nil else { return }
        drainScheduled = true
        encoderQueue.async { [weak self] in
            self?.drainLatestFrame()
        }
    }

    private func drainLatestFrame() {
        stateLock.lock()
        drainScheduled = false
        guard active, inFlightAttemptID == nil, let frame = pendingFrame else {
            stateLock.unlock()
            return
        }
        pendingFrame = nil
        nextAttemptID &+= 1
        let attemptID = nextAttemptID
        inFlightAttemptID = attemptID
        stateLock.unlock()

        guard let imageBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer) else {
            finishEncodingAttempt(attemptID: attemptID)
            return
        }

        let width = Int32(CVPixelBufferGetWidth(imageBuffer))
        let height = Int32(CVPixelBufferGetHeight(imageBuffer))
        let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        guard width > 0, height > 0,
              prepareSession(width: width, height: height, pixelFormat: pixelFormat),
              let compressionSession else {
            finishEncodingAttempt(attemptID: attemptID)
            return
        }
        let imageBufferToEncode: CVPixelBuffer
        if let sessionGeometry,
           sessionGeometry.sourceWidth != sessionGeometry.encodedWidth ||
            sessionGeometry.sourceHeight != sessionGeometry.encodedHeight {
            guard let resized = resize(
                imageBuffer,
                width: sessionGeometry.encodedWidth,
                height: sessionGeometry.encodedHeight
            ) else {
                finishEncodingAttempt(attemptID: attemptID)
                return
            }
            imageBufferToEncode = resized
        } else {
            imageBufferToEncode = imageBuffer
        }

        let now = DispatchTime.now().uptimeNanoseconds
        stateLock.lock()
        let minimumForceInterval: UInt64 = 250_000_000
        let forceKeyFrame = forceNextKeyFrame
            && (lastForcedKeyFrameUptimeNanoseconds == 0
                || now &- lastForcedKeyFrameUptimeNanoseconds >= minimumForceInterval)
        if forceKeyFrame {
            forceNextKeyFrame = false
            lastForcedKeyFrameUptimeNanoseconds = now
        }
        stateLock.unlock()
        let frameProperties: CFDictionary? = forceKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        let presentationTime = CMTime(
            value: CMTimeValue(clamping: frame.timestampMicroseconds),
            timescale: 1_000_000
        )
        var flags = VTEncodeInfoFlags()
        let timestampMicroseconds = frame.timestampMicroseconds
        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: imageBufferToEncode,
            presentationTimeStamp: presentationTime,
            duration: CMTime(
                value: 1,
                timescale: CMTimeScale(configuration.expectedFrameRate)
            ),
            frameProperties: frameProperties,
            infoFlagsOut: &flags
        ) { [weak self] status, infoFlags, sampleBuffer in
            self?.receiveEncodedFrame(
                status: status,
                infoFlags: infoFlags,
                sampleBuffer: sampleBuffer,
                attemptID: attemptID,
                timestampMicroseconds: timestampMicroseconds
            )
        }

        if status != noErr || flags.contains(.frameDropped) {
            stateLock.lock()
            forceNextKeyFrame = true
            stateLock.unlock()
            finishEncodingAttempt(attemptID: attemptID)
            return
        }

        let watchdog = DispatchWorkItem { [weak self] in
            self?.recoverHungEncode(attemptID: attemptID)
        }
        encodeWatchdogWorkItem?.cancel()
        encodeWatchdogWorkItem = watchdog
        encoderQueue.asyncAfter(deadline: .now() + .seconds(2), execute: watchdog)
    }

    private func prepareSession(width: Int32, height: Int32, pixelFormat: OSType) -> Bool {
        let encodedDimensions = Self.encodedDimensions(
            sourceWidth: width,
            sourceHeight: height,
            maximumDimension: configuration.maximumDimension
        )
        if compressionSession != nil,
           let sessionGeometry,
           sessionGeometry.sourceWidth == width,
           sessionGeometry.sourceHeight == height,
           sessionGeometry.encodedWidth == encodedDimensions.width,
           sessionGeometry.encodedHeight == encodedDimensions.height,
           sessionGeometry.pixelFormat == pixelFormat {
            return true
        }

        if let compressionSession { VTCompressionSessionInvalidate(compressionSession) }
        compressionSession = nil
        sessionGeometry = nil
        publishedConfiguration = nil
        pixelTransferSession = nil
        resizedPixelBufferPool = nil

        var newSession: VTCompressionSession?
        let creationStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: encodedDimensions.width,
            height: encodedDimensions.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: NSNumber(value: pixelFormat),
                kCVPixelBufferWidthKey: NSNumber(value: encodedDimensions.width),
                kCVPixelBufferHeightKey: NSNumber(value: encodedDimensions.height)
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &newSession
        )
        guard creationStatus == noErr, let newSession else { return false }

        let averageBitRate = configuration.averageBitRate
        let keyFrameInterval = max(
            1,
            Int((Double(configuration.expectedFrameRate) * configuration.keyFrameIntervalSeconds).rounded())
        )
        // VideoToolbox expresses the first DataRateLimits value in bytes for
        // the following time window. A two-second window tolerates a keyframe
        // burst without allowing a sustained rate above the configured target.
        let dataRateLimit = [max(1, averageBitRate / 4), 2] as CFArray
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: configuration.expectedFrameRate)),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: keyFrameInterval)),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: configuration.keyFrameIntervalSeconds)),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: averageBitRate)),
            (kVTCompressionPropertyKey_DataRateLimits, dataRateLimit),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel),
            (kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
        ]
        for (key, value) in properties {
            guard VTSessionSetProperty(newSession, key: key, value: value) == noErr else {
                VTCompressionSessionInvalidate(newSession)
                return false
            }
        }
        guard VTCompressionSessionPrepareToEncodeFrames(newSession) == noErr else {
            VTCompressionSessionInvalidate(newSession)
            return false
        }

        if width != encodedDimensions.width || height != encodedDimensions.height {
            var transferSession: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(
                allocator: kCFAllocatorDefault,
                pixelTransferSessionOut: &transferSession
            ) == noErr,
                  let transferSession else {
                VTCompressionSessionInvalidate(newSession)
                return false
            }
            guard VTSessionSetProperty(
                transferSession,
                key: kVTPixelTransferPropertyKey_ScalingMode,
                value: kVTScalingMode_Normal
            ) == noErr else {
                VTCompressionSessionInvalidate(newSession)
                return false
            }
            var pool: CVPixelBufferPool?
            let poolAttributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: NSNumber(value: pixelFormat),
                kCVPixelBufferWidthKey: NSNumber(value: encodedDimensions.width),
                kCVPixelBufferHeightKey: NSNumber(value: encodedDimensions.height),
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            guard CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                nil,
                poolAttributes as CFDictionary,
                &pool
            ) == kCVReturnSuccess, let pool else {
                VTCompressionSessionInvalidate(newSession)
                return false
            }
            pixelTransferSession = transferSession
            resizedPixelBufferPool = pool
        }

        compressionSession = newSession
        sessionGeometry = SessionGeometry(
            sourceWidth: width,
            sourceHeight: height,
            encodedWidth: encodedDimensions.width,
            encodedHeight: encodedDimensions.height,
            pixelFormat: pixelFormat
        )
        stateLock.lock()
        forceNextKeyFrame = true
        stateLock.unlock()
        return true
    }

    private func resize(
        _ source: CVPixelBuffer,
        width: Int32,
        height: Int32
    ) -> CVPixelBuffer? {
        guard let pixelTransferSession, let resizedPixelBufferPool else { return nil }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            resizedPixelBufferPool,
            &destination
        ) == kCVReturnSuccess, let destination else { return nil }
        guard CVPixelBufferGetWidth(destination) == Int(width),
              CVPixelBufferGetHeight(destination) == Int(height),
              VTPixelTransferSessionTransferImage(
                  pixelTransferSession,
                  from: source,
                  to: destination
              ) == noErr else { return nil }
        return destination
    }

    private static func encodedDimensions(
        sourceWidth: Int32,
        sourceHeight: Int32,
        maximumDimension: Int
    ) -> (width: Int32, height: Int32) {
        let sourceMaximum = max(sourceWidth, sourceHeight)
        guard sourceMaximum > Int32(maximumDimension) else {
            return (sourceWidth, sourceHeight)
        }
        let scale = Double(maximumDimension) / Double(sourceMaximum)
        let width = max(2, Int32((Double(sourceWidth) * scale / 2).rounded(.down)) * 2)
        let height = max(2, Int32((Double(sourceHeight) * scale / 2).rounded(.down)) * 2)
        return (width, height)
    }

    private func receiveEncodedFrame(
        status: OSStatus,
        infoFlags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?,
        attemptID: UInt64,
        timestampMicroseconds: UInt64
    ) {
        encoderQueue.async { [weak self] in
            guard let self else { return }
            stateLock.lock()
            let currentAttempt = active && inFlightAttemptID == attemptID
            stateLock.unlock()
            guard currentAttempt else { return }

            encodeWatchdogWorkItem?.cancel()
            encodeWatchdogWorkItem = nil
            defer { finishEncodingAttempt(attemptID: attemptID) }
            guard status == noErr,
                  !infoFlags.contains(.frameDropped),
                  let sampleBuffer,
                  CMSampleBufferDataIsReady(sampleBuffer),
                  let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
                  let encodedData = Self.copyData(from: dataBuffer) else {
                stateLock.lock()
                forceNextKeyFrame = true
                stateLock.unlock()
                return
            }

            if let configuration = Self.makeConfiguration(from: formatDescription),
               configuration != publishedConfiguration {
                publishedConfiguration = configuration
                onConfiguration?(configuration)
            }

            let keyFrame = Self.isKeyFrame(sampleBuffer)
            outputSequence &+= 1
            onAccessUnit?(H264AccessUnit(
                sequence: outputSequence,
                timestampMicroseconds: timestampMicroseconds,
                isKeyFrame: keyFrame,
                avccData: encodedData
            ))
        }
    }

    private func finishEncodingAttempt(attemptID: UInt64) {
        stateLock.lock()
        guard inFlightAttemptID == attemptID else {
            stateLock.unlock()
            return
        }
        inFlightAttemptID = nil
        scheduleDrainLocked()
        stateLock.unlock()
    }

    /// VideoToolbox is asynchronous and, after a device/decoder reset, can
    /// accept a frame without ever invoking its output handler. Rebuild only
    /// the shared encoder; capture and every viewer socket remain connected.
    private func recoverHungEncode(attemptID: UInt64) {
        stateLock.lock()
        guard active, inFlightAttemptID == attemptID else {
            stateLock.unlock()
            return
        }
        inFlightAttemptID = nil
        forceNextKeyFrame = true
        lastForcedKeyFrameUptimeNanoseconds = 0
        stateLock.unlock()

        encodeWatchdogWorkItem = nil
        if let compressionSession { VTCompressionSessionInvalidate(compressionSession) }
        compressionSession = nil
        sessionGeometry = nil
        publishedConfiguration = nil
        pixelTransferSession = nil
        resizedPixelBufferPool = nil

        stateLock.lock()
        scheduleDrainLocked()
        stateLock.unlock()
    }

    private static func microseconds(for time: CMTime) -> UInt64 {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds > 0 else {
            return DispatchTime.now().uptimeNanoseconds / 1_000
        }
        let microseconds = seconds * 1_000_000
        guard microseconds < Double(UInt64.max) else { return UInt64.max - 1 }
        return UInt64(microseconds.rounded(.down))
    }

    private static func copyData(from blockBuffer: CMBlockBuffer) -> Data? {
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            guard let address = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: address
            )
        }
        return status == kCMBlockBufferNoErr ? data : nil
    }

    private static func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]],
        let first = attachments.first else {
            return true
        }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    private static func makeConfiguration(
        from formatDescription: CMFormatDescription
    ) -> H264StreamConfiguration? {
        var parameterSetCount = 0
        var nalUnitHeaderLength: Int32 = 0
        let countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        guard countStatus == noErr,
              parameterSetCount > 0,
              (1...4).contains(nalUnitHeaderLength) else { return nil }

        var sequenceParameterSets: [Data] = []
        var pictureParameterSets: [Data] = []
        for index in 0..<parameterSetCount {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer, size > 0 else { return nil }
            let parameterSet = Data(bytes: pointer, count: size)
            switch pointer[0] & 0x1F {
            case 7: sequenceParameterSets.append(parameterSet)
            case 8: pictureParameterSets.append(parameterSet)
            default: break
            }
        }
        guard let firstSPS = sequenceParameterSets.first,
              firstSPS.count >= 4,
              !pictureParameterSets.isEmpty,
              sequenceParameterSets.count <= 31,
              pictureParameterSets.count <= 255 else { return nil }

        var avcC = Data([
            1,
            firstSPS[1],
            firstSPS[2],
            firstSPS[3],
            0xFC | UInt8(nalUnitHeaderLength - 1),
            0xE0 | UInt8(sequenceParameterSets.count)
        ])
        for parameterSet in sequenceParameterSets {
            guard parameterSet.count <= Int(UInt16.max) else { return nil }
            avcC.append(UInt8(parameterSet.count >> 8))
            avcC.append(UInt8(truncatingIfNeeded: parameterSet.count))
            avcC.append(parameterSet)
        }
        avcC.append(UInt8(pictureParameterSets.count))
        for parameterSet in pictureParameterSets {
            guard parameterSet.count <= Int(UInt16.max) else { return nil }
            avcC.append(UInt8(parameterSet.count >> 8))
            avcC.append(UInt8(truncatingIfNeeded: parameterSet.count))
            avcC.append(parameterSet)
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        guard dimensions.width > 0, dimensions.height > 0 else { return nil }
        let codec = String(
            format: "avc1.%02X%02X%02X",
            firstSPS[1],
            firstSPS[2],
            firstSPS[3]
        )
        return H264StreamConfiguration(
            codec: codec,
            codedWidth: Int(dimensions.width),
            codedHeight: Int(dimensions.height),
            avcDecoderConfigurationRecord: avcC
        )
    }
}
