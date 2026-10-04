import AVFoundation
import Foundation
import OSLog

/// Legacy IUMC PCM capture retained for compatibility with older services.
/// Automatic iPhone microphone input uses WebRTC's native local audio track.
@MainActor
final class PushToTalkAudioCapture {
    enum CaptureError: Error {
        case permissionDenied
        case invalidInputFormat
        case invalidCanonicalFormat
        case engineStartFailed
    }

    private static let logger = Logger(
        subsystem: "com.dltengwen.remotehandset",
        category: "PushToTalk"
    )

    private var engine: AVAudioEngine?
    private var processor: PacketProcessor?
    private var wantsCapture = false

    var isRunning: Bool { engine?.isRunning == true }

    func start(
        onPacket: @escaping @Sendable (_ pcm: Data, _ timestampMicroseconds: UInt64) -> Void
    ) async throws {
        guard engine == nil else { return }
        wantsCapture = true

        guard await requestPermissionIfNeeded() else {
            wantsCapture = false
            throw CaptureError.permissionDenied
        }
        guard wantsCapture else { return }

        let newEngine = AVAudioEngine()
        let inputNode = newEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            wantsCapture = false
            throw CaptureError.invalidInputFormat
        }
        guard let canonicalFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(MicrophonePacket.sampleRate),
            channels: 1,
            interleaved: true
        ) else {
            wantsCapture = false
            throw CaptureError.invalidCanonicalFormat
        }

        let newProcessor = PacketProcessor(
            inputFormat: inputFormat,
            canonicalFormat: canonicalFormat,
            onPacket: onPacket
        )
        let tapFrames = AVAudioFrameCount(
            max(1, ceil(inputFormat.sampleRate * 0.02))
        )
        inputNode.installTap(
            onBus: 0,
            bufferSize: tapFrames,
            format: inputFormat
        ) { buffer, time in
            guard let copy = Self.copy(buffer: buffer) else { return }
            newProcessor.enqueue(
                copy,
                timestampMicroseconds: Self.microseconds(for: time)
            )
        }

        do {
            newEngine.prepare()
            try newEngine.start()
            guard wantsCapture else {
                inputNode.removeTap(onBus: 0)
                newEngine.stop()
                newProcessor.stop()
                return
            }
            engine = newEngine
            processor = newProcessor
        } catch {
            inputNode.removeTap(onBus: 0)
            newEngine.stop()
            newProcessor.stop()
            wantsCapture = false
            Self.logger.error(
                "Microphone engine start failed: \(String(describing: error), privacy: .public)"
            )
            throw CaptureError.engineStartFailed
        }
    }

    func stop() {
        wantsCapture = false
        processor?.stop()
        processor = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    private func requestPermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    nonisolated private static func microseconds(for time: AVAudioTime) -> UInt64 {
        if time.isHostTimeValid {
            let seconds = AVAudioTime.seconds(forHostTime: time.hostTime)
            if seconds.isFinite, seconds >= 0 {
                return UInt64((seconds * 1_000_000).rounded(.down))
            }
        }
        return DispatchTime.now().uptimeNanoseconds / 1_000
    }

    nonisolated private static func copy(
        buffer: AVAudioPCMBuffer
    ) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(
            buffer.mutableAudioBufferList
        )
        let destination = UnsafeMutableAudioBufferListPointer(
            copy.mutableAudioBufferList
        )
        guard source.count == destination.count else { return nil }
        for index in 0..<source.count {
            let byteCount = min(
                Int(source[index].mDataByteSize),
                Int(destination[index].mDataByteSize)
            )
            guard byteCount == 0
                    || (source[index].mData != nil
                        && destination[index].mData != nil) else {
                return nil
            }
            if byteCount > 0 {
                memcpy(
                    destination[index].mData,
                    source[index].mData,
                    byteCount
                )
                destination[index].mDataByteSize = UInt32(byteCount)
            }
        }
        return copy
    }
}

private final class PacketProcessor: @unchecked Sendable {
    private struct PendingInput {
        let buffer: AVAudioPCMBuffer
        let timestampMicroseconds: UInt64
        let epoch: UInt64
    }

    private static let maximumPendingInputs = 3

    private let inputFormat: AVAudioFormat
    private let canonicalFormat: AVAudioFormat
    private let onPacket: @Sendable (Data, UInt64) -> Void
    private let queue = DispatchQueue(
        label: "com.dltengwen.remotehandset.push-to-talk",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private var pendingInputs: [PendingInput] = []
    private var drainScheduled = false
    private var processingInput = false
    private var accepting = true
    private var epoch: UInt64 = 1

    // Accessed only on queue.
    private var converter: AVAudioConverter?
    private var pendingPCM = Data()
    private var nextTimestampMicroseconds: UInt64?
    private var processedEpoch: UInt64 = 1

    init(
        inputFormat: AVAudioFormat,
        canonicalFormat: AVAudioFormat,
        onPacket: @escaping @Sendable (Data, UInt64) -> Void
    ) {
        self.inputFormat = inputFormat
        self.canonicalFormat = canonicalFormat
        self.onPacket = onPacket
        if inputFormat != canonicalFormat {
            converter = AVAudioConverter(
                from: inputFormat,
                to: canonicalFormat
            )
        }
    }

    func enqueue(
        _ buffer: AVAudioPCMBuffer,
        timestampMicroseconds: UInt64
    ) {
        var shouldSchedule = false
        lock.lock()
        guard accepting else {
            lock.unlock()
            return
        }
        let retainedCount = pendingInputs.count + (processingInput ? 1 : 0)
        if retainedCount >= Self.maximumPendingInputs {
            pendingInputs.removeAll(keepingCapacity: true)
            epoch &+= 1
        }
        pendingInputs.append(PendingInput(
            buffer: buffer,
            timestampMicroseconds: timestampMicroseconds,
            epoch: epoch
        ))
        if !drainScheduled {
            drainScheduled = true
            shouldSchedule = true
        }
        lock.unlock()

        if shouldSchedule {
            queue.async { [weak self] in self?.drainOne() }
        }
    }

    func stop() {
        lock.lock()
        accepting = false
        epoch &+= 1
        pendingInputs.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private func drainOne() {
        lock.lock()
        guard accepting, !pendingInputs.isEmpty else {
            processingInput = false
            drainScheduled = false
            lock.unlock()
            return
        }
        let input = pendingInputs.removeFirst()
        processingInput = true
        lock.unlock()

        process(input)

        lock.lock()
        processingInput = false
        let shouldContinue = accepting && !pendingInputs.isEmpty
        if !shouldContinue { drainScheduled = false }
        lock.unlock()

        if shouldContinue {
            queue.async { [weak self] in self?.drainOne() }
        }
    }

    private func process(_ input: PendingInput) {
        guard isCurrent(input.epoch),
              let converted = canonicalPCM(from: input.buffer),
              converted.frameLength > 0,
              let samples = converted.int16ChannelData?[0] else { return }

        if processedEpoch != input.epoch {
            processedEpoch = input.epoch
            reset(at: input.timestampMicroseconds)
        }
        guard isCurrent(input.epoch) else { return }

        if nextTimestampMicroseconds == nil {
            nextTimestampMicroseconds = input.timestampMicroseconds
        }
        pendingPCM.append(
            contentsOf: UnsafeRawBufferPointer(
                start: samples,
                count: Int(converted.frameLength) * MemoryLayout<Int16>.size
            )
        )

        while pendingPCM.count >= MicrophonePacket.bytesPerPacket {
            guard isCurrent(input.epoch) else {
                reset(at: input.timestampMicroseconds)
                return
            }
            let packet = Data(
                pendingPCM.prefix(MicrophonePacket.bytesPerPacket)
            )
            pendingPCM.removeFirst(MicrophonePacket.bytesPerPacket)
            let timestamp = nextTimestampMicroseconds
                ?? input.timestampMicroseconds
            onPacket(packet, timestamp)
            nextTimestampMicroseconds = timestamp &+ 20_000
        }
    }

    private func canonicalPCM(
        from buffer: AVAudioPCMBuffer
    ) -> AVAudioPCMBuffer? {
        if buffer.format == canonicalFormat { return buffer }
        guard let converter else { return nil }
        let ratio = canonicalFormat.sampleRate
            / max(1, buffer.format.sampleRate)
        let capacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * ratio) + 32
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: canonicalFormat,
            frameCapacity: capacity
        ) else { return nil }

        if abs(buffer.format.sampleRate - canonicalFormat.sampleRate) < 0.5 {
            do {
                try converter.convert(to: output, from: buffer)
            } catch {
                return nil
            }
            return output.frameLength == buffer.frameLength ? output : nil
        }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(
            to: output,
            error: &conversionError
        ) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard conversionError == nil,
              status == .haveData || status == .inputRanDry,
              output.frameLength > 0 else { return nil }
        return output
    }

    private func reset(at timestampMicroseconds: UInt64) {
        pendingPCM.removeAll(keepingCapacity: true)
        nextTimestampMicroseconds = timestampMicroseconds
        converter?.reset()
    }

    private func isCurrent(_ expectedEpoch: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return accepting && epoch == expectedEpoch
    }
}
