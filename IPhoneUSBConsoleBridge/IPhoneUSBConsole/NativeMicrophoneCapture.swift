import AVFAudio
import AVFoundation
import Foundation
import OSLog

/// Captures the Mac's selected microphone only while the native push-to-talk
/// control is held, converts it to canonical 48 kHz mono S16LE, and forwards
/// 20 ms packets through MicrophoneInputCoordinator.
final class NativeMicrophoneCapture: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "local.iphone.usbconsole",
        category: "NativeMicrophone"
    )

    enum State: Equatable, Sendable {
        case idle
        case requestingPermission
        case starting
        case running
        case busy
        case permissionDenied
        case failed
    }

    var onStateChange: (@Sendable (State) -> Void)?

    private static let sampleRate = 48_000
    private static let framesPerPacket = 960
    private static let bytesPerPacket = framesPerPacket * MemoryLayout<Int16>.size
    private static let maximumPendingInputs = 3

    private struct PendingInput {
        let buffer: AVAudioPCMBuffer
        let timestampMicroseconds: UInt64
        let epoch: UInt64
    }

    private let coordinator: MicrophoneInputCoordinator
    private let owner = "native:\(UUID().uuidString)"
    private let processingQueue = DispatchQueue(
        label: "local.iphone.usbconsole.native-microphone",
        qos: .userInitiated
    )
    private let desiredLock = NSLock()
    private let inputLock = NSLock()
    private var desiredRunning = false
    private var pendingInputs: [PendingInput] = []
    private var inputDrainScheduled = false
    private var inputProcessing = false
    private var inputAccepting = false
    private var inputEpoch: UInt64 = 0

    // Accessed only on processingQueue.
    private var engine: AVAudioEngine?
    private var streamID: UInt32?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var canonicalFormat: AVAudioFormat?
    private var pendingPCM = Data()
    private var nextPacketTimestampMicroseconds: UInt64?
    private var nextPacketSequence: UInt32 = 0
    private var processedInputEpoch: UInt64 = 0
    private var hasLoggedInputGeometry = false

    init(coordinator: MicrophoneInputCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        desiredLock.lock()
        desiredRunning = true
        desiredLock.unlock()

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startAuthorized()
        case .notDetermined:
            publish(.requestingPermission)
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self, isDesiredRunning() else { return }
                if granted {
                    startAuthorized()
                } else {
                    publish(.permissionDenied)
                }
            }
        case .denied, .restricted:
            publish(.permissionDenied)
        @unknown default:
            publish(.permissionDenied)
        }
    }

    func stop() {
        desiredLock.lock()
        desiredRunning = false
        desiredLock.unlock()
        disableInputHandoff()
        processingQueue.async { [weak self] in
            self?.performStop(publishIdle: true)
        }
    }

    func shutdown() {
        stop()
    }

    private func startAuthorized() {
        guard isDesiredRunning() else { return }
        publish(.starting)
        processingQueue.async { [weak self] in
            self?.performStart()
        }
    }

    private func performStart() {
        guard isDesiredRunning(), engine == nil else { return }
        let acquired = coordinator.begin(owner: owner)
        guard case .started(let streamID) = acquired else {
            Self.logger.error(
                "Microphone coordinator begin failed busy=\(acquired == .busy, privacy: .public)"
            )
            publish(acquired == .busy ? .busy : .failed)
            return
        }

        guard let canonical = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: true
        ) else {
            Self.logger.error("Unable to create canonical microphone format")
            coordinator.end(owner: owner, streamID: streamID)
            publish(.failed)
            return
        }

        let newEngine = AVAudioEngine()
        let inputNode = newEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            Self.logger.error(
                "Invalid input format channels=\(inputFormat.channelCount, privacy: .public) rate=\(inputFormat.sampleRate, privacy: .public)"
            )
            coordinator.end(owner: owner, streamID: streamID)
            publish(.failed)
            return
        }

        self.streamID = streamID
        canonicalFormat = canonical
        converterInputFormat = nil
        converter = nil
        pendingPCM.removeAll(keepingCapacity: true)
        nextPacketTimestampMicroseconds = nil
        nextPacketSequence = 0
        hasLoggedInputGeometry = false

        // macOS input taps are delivered in 100-400 ms batches. Request the
        // minimum supported 100 ms explicitly; packetization below still emits
        // canonical 20 ms frames for low-latency transport and phone playback.
        let tapBufferFrames = AVAudioFrameCount(
            min(
                Double(UInt32.max),
                max(1, ceil(inputFormat.sampleRate * 0.1))
            )
        )
        inputNode.installTap(onBus: 0, bufferSize: tapBufferFrames, format: inputFormat) { [weak self] buffer, time in
            guard let self, let copy = Self.copy(buffer: buffer) else { return }
            let timestamp = Self.microseconds(for: time)
            enqueueInput(copy, timestampMicroseconds: timestamp)
        }

        do {
            newEngine.prepare()
            try newEngine.start()
            guard isDesiredRunning() else {
                inputNode.removeTap(onBus: 0)
                newEngine.stop()
                coordinator.end(owner: owner, streamID: streamID)
                self.streamID = nil
                publish(.idle)
                return
            }
            engine = newEngine
            processedInputEpoch = enableInputHandoff()
            Self.logger.info(
                "Microphone engine running stream=\(streamID, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public) rate=\(inputFormat.sampleRate, privacy: .public)"
            )
            publish(.running)
        } catch {
            Self.logger.error(
                "Microphone engine start failed error=\(String(describing: error), privacy: .public)"
            )
            inputNode.removeTap(onBus: 0)
            newEngine.stop()
            coordinator.end(owner: owner, streamID: streamID)
            self.streamID = nil
            publish(.failed)
        }
    }

    private func performStop(publishIdle: Bool) {
        if engine != nil || streamID != nil {
            Self.logger.info(
                "Microphone engine stopping publish_idle=\(publishIdle, privacy: .public)"
            )
        }
        disableInputHandoff()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        if let streamID {
            coordinator.end(owner: owner, streamID: streamID)
            self.streamID = nil
        }
        converter = nil
        converterInputFormat = nil
        canonicalFormat = nil
        pendingPCM.removeAll(keepingCapacity: false)
        nextPacketTimestampMicroseconds = nil
        if publishIdle { publish(.idle) }
    }

    private func enqueueInput(_ buffer: AVAudioPCMBuffer, timestampMicroseconds: UInt64) {
        var shouldScheduleDrain = false
        inputLock.lock()
        guard inputAccepting else {
            inputLock.unlock()
            return
        }

        let retainedInputCount = pendingInputs.count + (inputProcessing ? 1 : 0)
        if retainedInputCount >= Self.maximumPendingInputs {
            pendingInputs.removeAll(keepingCapacity: true)
            inputEpoch &+= 1
        }
        pendingInputs.append(PendingInput(
            buffer: buffer,
            timestampMicroseconds: timestampMicroseconds,
            epoch: inputEpoch
        ))
        if !inputDrainScheduled {
            inputDrainScheduled = true
            shouldScheduleDrain = true
        }
        inputLock.unlock()

        if shouldScheduleDrain {
            processingQueue.async { [weak self] in
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

        process(
            input.buffer,
            timestampMicroseconds: input.timestampMicroseconds,
            inputEpoch: input.epoch
        )

        inputLock.lock()
        inputProcessing = false
        let shouldContinue = inputAccepting && !pendingInputs.isEmpty
        if !shouldContinue {
            inputDrainScheduled = false
        }
        inputLock.unlock()

        if shouldContinue {
            processingQueue.async { [weak self] in
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

    private func process(
        _ buffer: AVAudioPCMBuffer,
        timestampMicroseconds: UInt64,
        inputEpoch: UInt64
    ) {
        guard isDesiredRunning(), isInputEpochCurrent(inputEpoch), let streamID,
              let pcm = canonicalPCM(from: buffer),
              pcm.frameLength > 0,
              let samples = pcm.int16ChannelData?[0] else { return }

        if !hasLoggedInputGeometry {
            hasLoggedInputGeometry = true
            Self.logger.info(
                "First microphone callback input_frames=\(buffer.frameLength, privacy: .public) canonical_frames=\(pcm.frameLength, privacy: .public)"
            )
        }

        if processedInputEpoch != inputEpoch {
            processedInputEpoch = inputEpoch
            nextPacketSequence &+= 1
            resetPacketization(at: timestampMicroseconds)
        }
        guard isInputEpochCurrent(inputEpoch) else {
            resetPacketization(at: timestampMicroseconds)
            return
        }

        if nextPacketTimestampMicroseconds == nil {
            nextPacketTimestampMicroseconds = timestampMicroseconds
        }
        pendingPCM.append(
            contentsOf: UnsafeRawBufferPointer(
                start: samples,
                count: Int(pcm.frameLength) * MemoryLayout<Int16>.size
            )
        )

        while pendingPCM.count >= Self.bytesPerPacket {
            guard isInputEpochCurrent(inputEpoch) else {
                resetPacketization(at: timestampMicroseconds)
                return
            }
            let packet = Data(pendingPCM.prefix(Self.bytesPerPacket))
            pendingPCM.removeFirst(Self.bytesPerPacket)
            let timestamp = nextPacketTimestampMicroseconds ?? timestampMicroseconds
            nextPacketSequence &+= 1
            guard isInputEpochCurrent(inputEpoch) else {
                resetPacketization(at: timestampMicroseconds)
                return
            }
            guard coordinator.send(
                owner: owner,
                streamID: streamID,
                packetSequence: nextPacketSequence,
                timestampMicroseconds: timestamp,
                sampleCount: UInt16(Self.framesPerPacket),
                pcmData: packet
            ) else {
                Self.logger.error(
                    "First-stage microphone transport rejected PCM stream=\(streamID, privacy: .public) sequence=\(self.nextPacketSequence, privacy: .public)"
                )
                performStop(publishIdle: false)
                publish(.failed)
                return
            }
            nextPacketTimestampMicroseconds = timestamp &+ 20_000
        }
    }

    private func resetPacketization(at timestampMicroseconds: UInt64) {
        pendingPCM.removeAll(keepingCapacity: true)
        nextPacketTimestampMicroseconds = timestampMicroseconds
        converter?.reset()
    }

    private func canonicalPCM(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let canonicalFormat else { return nil }
        if buffer.format == canonicalFormat {
            return buffer
        }
        if converterInputFormat != buffer.format {
            converterInputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: canonicalFormat)
        }
        guard let converter else { return nil }
        let ratio = canonicalFormat.sampleRate / max(1, buffer.format.sampleRate)
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio) + 32)
        guard let converted = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: capacity) else {
            return nil
        }

        // The live aggregate input on this Mac is already 48 kHz; only the PCM
        // representation changes. The simple conversion API guarantees the
        // whole input buffer is converted when capacity >= input frameLength.
        // Using the streaming fill API here caps one call at 4096 frames and
        // silently discarded the final 704 frames from every 4800-frame tap,
        // producing a regular ~15 ms dropout every 100 ms.
        if abs(buffer.format.sampleRate - canonicalFormat.sampleRate) < 0.5 {
            do {
                try converter.convert(to: converted, from: buffer)
            } catch {
                Self.logger.error(
                    "Simple microphone conversion failed error=\(String(describing: error), privacy: .public)"
                )
                return nil
            }
            guard converted.frameLength == buffer.frameLength else {
                Self.logger.error(
                    "Simple microphone conversion truncated input=\(buffer.frameLength, privacy: .public) output=\(converted.frameLength, privacy: .public)"
                )
                return nil
            }
            return converted
        }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard error == nil,
              status == .haveData || status == .inputRanDry,
              converted.frameLength > 0 else { return nil }
        return converted
    }

    private static func copy(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in 0..<source.count {
            let byteCount = min(Int(source[index].mDataByteSize), Int(destination[index].mDataByteSize))
            guard byteCount == 0 || (source[index].mData != nil && destination[index].mData != nil) else {
                return nil
            }
            if byteCount > 0 {
                memcpy(destination[index].mData, source[index].mData, byteCount)
                destination[index].mDataByteSize = UInt32(byteCount)
            }
        }
        return copy
    }

    private func isDesiredRunning() -> Bool {
        desiredLock.lock()
        defer { desiredLock.unlock() }
        return desiredRunning
    }

    private func publish(_ state: State) {
        let callback = onStateChange
        DispatchQueue.main.async {
            callback?(state)
        }
    }

    private static func microseconds(for time: AVAudioTime) -> UInt64 {
        if time.isHostTimeValid {
            let seconds = AVAudioTime.seconds(forHostTime: time.hostTime)
            if seconds.isFinite, seconds >= 0 {
                return UInt64((seconds * 1_000_000).rounded(.down))
            }
        }
        return DispatchTime.now().uptimeNanoseconds / 1_000
    }
}
