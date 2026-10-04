import AVFAudio
import AudioToolbox
import CoreMedia
import Foundation

struct OpusStreamConfiguration: Equatable, Sendable {
    let codec: String
    let sampleRate: Int
    let numberOfChannels: Int
    let frameDurationMicroseconds: Int
}

struct OpusAudioPacket: Sendable {
    let timestampMicroseconds: UInt64
    let sequence: UInt32
    let frameCount: UInt16
    let payload: Data
    let discontinuity: Bool

    func markingDiscontinuity() -> OpusAudioPacket {
        OpusAudioPacket(
            timestampMicroseconds: timestampMicroseconds,
            sequence: sequence,
            frameCount: frameCount,
            payload: payload,
            discontinuity: true
        )
    }
}

/// Converts the wired iOS screen-capture audio track to one shared Opus stream.
/// All conversion and packetization are serialized away from AVCapture's audio
/// callback so a slow encoder can never block the device callback queue.
final class OpusAudioEncoder: @unchecked Sendable {
    typealias ConfigurationHandler = @Sendable (OpusStreamConfiguration) -> Void
    typealias PacketHandler = @Sendable (OpusAudioPacket) -> Void

    static let configuration = OpusStreamConfiguration(
        codec: "opus",
        sampleRate: 48_000,
        numberOfChannels: 2,
        frameDurationMicroseconds: 20_000
    )

    /// Uncompressed fallback for browsers where WebCodecs or AudioWorklet is
    /// unavailable. Payloads are interleaved signed 16-bit little-endian PCM.
    static let pcmConfiguration = OpusStreamConfiguration(
        codec: "pcm_s16le",
        sampleRate: 48_000,
        numberOfChannels: 2,
        frameDurationMicroseconds: 20_000
    )

    var onConfiguration: ConfigurationHandler?
    var onPacket: PacketHandler?
    var onPCMConfiguration: ConfigurationHandler?
    var onPCMPacket: PacketHandler?

    private static let framesPerPacket: AVAudioFrameCount = 960
    private static let channelCount: AVAudioChannelCount = 2
    private static let bytesPerFrame = Int(channelCount) * MemoryLayout<Int16>.size
    private static let bytesPerPacket = Int(framesPerPacket) * bytesPerFrame
    private static let discontinuityToleranceMicroseconds: UInt64 = 8_000
    private static let maximumPendingInputs = 3

    private struct PendingInput {
        let sampleBuffer: CMSampleBuffer
        let timing: USBScreenCapture.SampleTiming
        let epoch: UInt64
    }

    private enum PacketEncodingResult {
        case packet(Data)
        case needsMoreInput
        case hardFailure
    }

    private let queue = DispatchQueue(
        label: "local.iphone.usbconsole.opus-encoder",
        qos: .userInitiated
    )
    private let bitRate: Int
    private let inputLock = NSLock()
    private var pendingInputs: [PendingInput] = []
    private var inputDrainScheduled = false
    private var inputProcessing = false
    private var inputAccepting = false
    private var inputEpoch: UInt64 = 0

    // Accessed only on queue.
    private var running = false
    private var processedInputEpoch: UInt64 = 0
    private var canonicalFormat: AVAudioFormat?
    private var opusFormat: AVAudioFormat?
    private var opusConverter: AVAudioConverter?
    private var sourceConverter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var pendingPCM = Data()
    private var nextPacketTimestampMicroseconds: UInt64?
    private var nextPCMPacketTimestampMicroseconds: UInt64?
    private var expectedInputTimestampMicroseconds: UInt64?
    private var nextSequence: UInt32 = 0
    private var nextPCMSequence: UInt32 = 0
    private var pendingDiscontinuity = true
    private var pendingPCMDiscontinuity = true

    init(bitRate: Int = 64_000) {
        self.bitRate = min(max(bitRate, 32_000), 128_000)
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !running else { return }
            guard configureFormats() else { return }
            running = true
            pendingPCM.removeAll(keepingCapacity: true)
            nextPacketTimestampMicroseconds = nil
            nextPCMPacketTimestampMicroseconds = nil
            expectedInputTimestampMicroseconds = nil
            pendingDiscontinuity = true
            pendingPCMDiscontinuity = true
            processedInputEpoch = enableInputHandoff()
            onConfiguration?(Self.configuration)
            onPCMConfiguration?(Self.pcmConfiguration)
        }
    }

    func stop() {
        disableInputHandoff()
        queue.async { [weak self] in
            guard let self else { return }
            running = false
            pendingPCM.removeAll(keepingCapacity: false)
            nextPacketTimestampMicroseconds = nil
            nextPCMPacketTimestampMicroseconds = nil
            expectedInputTimestampMicroseconds = nil
            sourceConverter = nil
            sourceFormat = nil
            opusConverter = nil
            opusFormat = nil
            canonicalFormat = nil
            pendingDiscontinuity = true
            pendingPCMDiscontinuity = true
        }
    }

    func submit(_ sampleBuffer: CMSampleBuffer, timing: USBScreenCapture.SampleTiming) {
        var shouldScheduleDrain = false
        inputLock.lock()
        guard inputAccepting else {
            inputLock.unlock()
            return
        }

        let retainedInputCount = pendingInputs.count + (inputProcessing ? 1 : 0)
        if retainedInputCount >= Self.maximumPendingInputs {
            // Retain the newest audio only. The epoch change makes the in-flight
            // encoder discard any result from the superseded timeline and makes
            // the next input clear partial PCM and codec state.
            pendingInputs.removeAll(keepingCapacity: true)
            inputEpoch &+= 1
        }
        pendingInputs.append(PendingInput(
            sampleBuffer: sampleBuffer,
            timing: timing,
            epoch: inputEpoch
        ))
        if !inputDrainScheduled {
            inputDrainScheduled = true
            shouldScheduleDrain = true
        }
        inputLock.unlock()

        if shouldScheduleDrain {
            queue.async { [weak self] in
                self?.drainOneInput()
            }
        }
    }

    private func drainOneInput() {
        inputLock.lock()
        guard inputAccepting, !pendingInputs.isEmpty else {
            inputProcessing = false
            inputDrainScheduled = false
            inputLock.unlock()
            return
        }
        let input = pendingInputs.removeFirst()
        inputProcessing = true
        inputLock.unlock()

        encode(input.sampleBuffer, timing: input.timing, inputEpoch: input.epoch)

        inputLock.lock()
        inputProcessing = false
        let shouldContinue = inputAccepting && !pendingInputs.isEmpty
        if !shouldContinue {
            inputDrainScheduled = false
        }
        inputLock.unlock()

        if shouldContinue {
            queue.async { [weak self] in
                self?.drainOneInput()
            }
        }
    }

    private func enableInputHandoff() -> UInt64 {
        inputLock.lock()
        inputEpoch &+= 1
        pendingInputs.removeAll(keepingCapacity: true)
        inputAccepting = true
        let epoch = inputEpoch
        inputLock.unlock()
        return epoch
    }

    private func disableInputHandoff() {
        inputLock.lock()
        inputAccepting = false
        inputEpoch &+= 1
        pendingInputs.removeAll(keepingCapacity: false)
        inputLock.unlock()
    }

    private func isInputEpochCurrent(_ expectedEpoch: UInt64) -> Bool {
        inputLock.lock()
        defer { inputLock.unlock() }
        return inputAccepting && inputEpoch == expectedEpoch
    }

    private func configureFormats() -> Bool {
        guard let canonical = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(Self.configuration.sampleRate),
            channels: Self.channelCount,
            interleaved: true
        ), let opus = AVAudioFormat(settings: [
            AVFormatIDKey: Int(kAudioFormatOpus),
            AVSampleRateKey: Self.configuration.sampleRate,
            AVNumberOfChannelsKey: Self.configuration.numberOfChannels,
            AVEncoderBitRateKey: bitRate
        ]), let converter = AVAudioConverter(from: canonical, to: opus) else {
            return false
        }
        converter.bitRate = bitRate
        canonicalFormat = canonical
        opusFormat = opus
        opusConverter = converter
        return true
    }

    private func encode(
        _ sampleBuffer: CMSampleBuffer,
        timing: USBScreenCapture.SampleTiming,
        inputEpoch: UInt64
    ) {
        guard running,
              isInputEpochCurrent(inputEpoch),
              CMSampleBufferDataIsReady(sampleBuffer),
              let pcm = canonicalPCMBuffer(from: sampleBuffer),
              pcm.frameLength > 0,
              let samples = pcm.int16ChannelData?[0] else { return }

        let timestamp = Self.microseconds(for: timing.presentationHostTime ?? timing.hostArrivalTime)
        if processedInputEpoch != inputEpoch {
            processedInputEpoch = inputEpoch
            resetPacketization(at: timestamp)
        }
        guard isInputEpochCurrent(inputEpoch) else {
            resetPacketization(at: timestamp)
            return
        }
        let duration = UInt64(pcm.frameLength) * 1_000_000 / UInt64(Self.configuration.sampleRate)
        if let expected = expectedInputTimestampMicroseconds {
            let difference = timestamp > expected ? timestamp - expected : expected - timestamp
            if difference > Self.discontinuityToleranceMicroseconds {
                resetPacketization(at: timestamp)
            }
        }
        if nextPacketTimestampMicroseconds == nil {
            nextPacketTimestampMicroseconds = timestamp
        }
        if nextPCMPacketTimestampMicroseconds == nil {
            nextPCMPacketTimestampMicroseconds = timestamp
        }
        expectedInputTimestampMicroseconds = timestamp &+ duration

        pendingPCM.append(
            contentsOf: UnsafeRawBufferPointer(
                start: samples,
                count: Int(pcm.frameLength) * Self.bytesPerFrame
            )
        )

        while pendingPCM.count >= Self.bytesPerPacket {
            guard isInputEpochCurrent(inputEpoch) else {
                resetPacketization(at: timestamp)
                return
            }
            let packetPCM = Data(pendingPCM.prefix(Self.bytesPerPacket))
            pendingPCM.removeFirst(Self.bytesPerPacket)
            guard isInputEpochCurrent(inputEpoch) else {
                resetPacketization(at: timestamp)
                return
            }
            let pcmPacketTimestamp = nextPCMPacketTimestampMicroseconds ?? timestamp
            nextPCMSequence &+= 1
            onPCMPacket?(OpusAudioPacket(
                timestampMicroseconds: pcmPacketTimestamp,
                sequence: nextPCMSequence,
                frameCount: UInt16(Self.framesPerPacket),
                payload: packetPCM,
                discontinuity: pendingPCMDiscontinuity
            ))
            pendingPCMDiscontinuity = false
            nextPCMPacketTimestampMicroseconds = pcmPacketTimestamp
                &+ UInt64(Self.pcmConfiguration.frameDurationMicroseconds)
            let result = encodePacket(pcmData: packetPCM)
            guard isInputEpochCurrent(inputEpoch) else {
                resetPacketization(at: timestamp)
                return
            }
            switch result {
            case .needsMoreInput:
                continue
            case .hardFailure:
                resetPacketization(at: expectedInputTimestampMicroseconds ?? timestamp)
                return
            case .packet(let payload):
                let packetTimestamp = nextPacketTimestampMicroseconds ?? timestamp
                nextSequence &+= 1
                let packet = OpusAudioPacket(
                    timestampMicroseconds: packetTimestamp,
                    sequence: nextSequence,
                    frameCount: UInt16(Self.framesPerPacket),
                    payload: payload,
                    discontinuity: pendingDiscontinuity
                )
                pendingDiscontinuity = false
                nextPacketTimestampMicroseconds = packetTimestamp &+ UInt64(Self.configuration.frameDurationMicroseconds)
                onPacket?(packet)
            }
        }
    }

    private func canonicalPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let canonicalFormat else { return nil }
        let incomingFormat = AVAudioFormat(cmAudioFormatDescription: description)
        let streamDescription = incomingFormat.streamDescription.pointee
        guard streamDescription.mFormatID == kAudioFormatLinearPCM,
              incomingFormat.channelCount > 0,
              incomingFormat.sampleRate.isFinite,
              incomingFormat.sampleRate > 0 else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0, frameCount <= Int(Int32.max),
              let incomingBuffer = AVAudioPCMBuffer(
                  pcmFormat: incomingFormat,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ) else { return nil }
        incomingBuffer.frameLength = AVAudioFrameCount(frameCount)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: incomingBuffer.mutableAudioBufferList
        ) == noErr else { return nil }

        if incomingFormat == canonicalFormat {
            return incomingBuffer
        }

        if sourceFormat != incomingFormat {
            sourceFormat = incomingFormat
            sourceConverter = AVAudioConverter(from: incomingFormat, to: canonicalFormat)
        }
        guard let sourceConverter else { return nil }

        let ratio = canonicalFormat.sampleRate / max(1, incomingFormat.sampleRate)
        let capacity = AVAudioFrameCount(ceil(Double(frameCount) * ratio) + 32)
        guard let converted = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: capacity) else {
            return nil
        }
        var supplied = false
        var conversionError: NSError?
        let status = sourceConverter.convert(to: converted, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return incomingBuffer
        }
        guard conversionError == nil,
              status == .haveData || status == .inputRanDry,
              converted.frameLength > 0 else { return nil }
        return converted
    }

    private func encodePacket(pcmData: Data) -> PacketEncodingResult {
        guard let canonicalFormat, let opusFormat, let opusConverter,
              let input = AVAudioPCMBuffer(
                  pcmFormat: canonicalFormat,
                  frameCapacity: Self.framesPerPacket
              ), let samples = input.int16ChannelData?[0] else { return .hardFailure }
        input.frameLength = Self.framesPerPacket
        pcmData.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                memcpy(samples, baseAddress, Self.bytesPerPacket)
            }
        }

        let output = AVAudioCompressedBuffer(
            format: opusFormat,
            packetCapacity: 1,
            maximumPacketSize: opusConverter.maximumOutputPacketSize
        )
        var supplied = false
        var conversionError: NSError?
        let status = opusConverter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard conversionError == nil, status != .error else { return .hardFailure }
        if output.packetCount == 1, output.byteLength > 0,
           status == .haveData || status == .inputRanDry {
            return .packet(Data(bytes: output.data, count: Int(output.byteLength)))
        }
        if status == .inputRanDry || status == .endOfStream {
            // The converter consumed the supplied PCM but has not emitted a
            // packet yet (for example while priming). Keep its internal state
            // and feed the next 20 ms input instead of resetting forever.
            return .needsMoreInput
        }
        return .hardFailure
    }

    private func resetPacketization(at timestamp: UInt64) {
        pendingPCM.removeAll(keepingCapacity: true)
        nextPacketTimestampMicroseconds = timestamp
        nextPCMPacketTimestampMicroseconds = timestamp
        expectedInputTimestampMicroseconds = nil
        pendingDiscontinuity = true
        pendingPCMDiscontinuity = true
        opusConverter?.reset()
        sourceConverter?.reset()
    }

    private static func microseconds(for time: CMTime) -> UInt64 {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds > 0 else {
            return DispatchTime.now().uptimeNanoseconds / 1_000
        }
        let value = seconds * 1_000_000
        guard value < Double(UInt64.max) else { return UInt64.max - 1 }
        return UInt64(value.rounded(.down))
    }
}
