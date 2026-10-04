import Foundation
import OSLog

/// Arbitrates the single phone microphone-replacement stream shared by the
/// native Console and the one web controller lease. Audio is forwarded over
/// the existing authenticated, USB-only RFB connection.
final class MicrophoneInputCoordinator: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "local.iphone.usbconsole",
        category: "MicrophoneCoordinator"
    )

    enum BeginResult: Equatable, Sendable {
        case started(streamID: UInt32)
        case busy
        case controlUnavailable
    }

    struct ActiveStream: Equatable, Sendable {
        let owner: String
        let streamID: UInt32
    }

    var onStateChange: (@Sendable (ActiveStream?) -> Void)?

    private let inputClient: RFBInputClient
    private let lock = NSLock()
    private var activeStream: ActiveStream?

    init(inputClient: RFBInputClient) {
        self.inputClient = inputClient
    }

    func begin(owner: String, requestedStreamID: UInt32? = nil) -> BeginResult {
        guard !owner.isEmpty, inputClient.isConnected else { return .controlUnavailable }
        lock.lock()
        guard activeStream == nil else {
            lock.unlock()
            return .busy
        }
        var streamID = requestedStreamID ?? UInt32.random(in: 1...UInt32.max)
        if streamID == 0 { streamID = 1 }
        let stream = ActiveStream(owner: owner, streamID: streamID)
        activeStream = stream
        lock.unlock()

        let now = DispatchTime.now().uptimeNanoseconds / 1_000
        guard inputClient.beginMicrophoneStream(
            streamID: streamID,
            timestampMicroseconds: now
        ) else {
            lock.lock()
            if activeStream == stream { activeStream = nil }
            lock.unlock()
            return .controlUnavailable
        }
        notify(stream)
        return .started(streamID: streamID)
    }

    func send(
        owner: String,
        streamID: UInt32,
        packetSequence: UInt32,
        timestampMicroseconds: UInt64,
        sampleCount: UInt16,
        pcmData: Data
    ) -> Bool {
        lock.lock()
        let allowed = activeStream == ActiveStream(owner: owner, streamID: streamID)
        lock.unlock()
        guard allowed else {
            Self.logger.error(
                "PCM rejected because coordinator ownership changed stream=\(streamID, privacy: .public)"
            )
            return false
        }
        guard inputClient.sendMicrophonePCM(
            streamID: streamID,
            packetSequence: packetSequence,
            timestampMicroseconds: timestampMicroseconds,
            sampleCount: sampleCount,
            pcmData: pcmData
        ) else {
            Self.logger.error(
                "PCM rejected by RFB client stream=\(streamID, privacy: .public) sequence=\(packetSequence, privacy: .public)"
            )
            let stream = ActiveStream(owner: owner, streamID: streamID)
            lock.lock()
            let shouldRelease = activeStream == stream
            if shouldRelease {
                inputClient.endMicrophoneStream(
                    streamID: streamID,
                    timestampMicroseconds: DispatchTime.now().uptimeNanoseconds / 1_000
                )
                activeStream = nil
            }
            lock.unlock()
            if shouldRelease { notify(nil) }
            return false
        }
        return true
    }

    func end(owner: String, streamID: UInt32? = nil) {
        lock.lock()
        guard let current = activeStream,
              current.owner == owner,
              streamID == nil || streamID == current.streamID else {
            lock.unlock()
            return
        }
        // Invalidate/queue the RFB STOP before exposing the coordinator as idle.
        // This prevents a rapid release/re-press from racing a new START against
        // the previous outbound stream state.
        inputClient.endMicrophoneStream(
            streamID: current.streamID,
            timestampMicroseconds: DispatchTime.now().uptimeNanoseconds / 1_000
        )
        activeStream = nil
        lock.unlock()
        notify(nil)
    }

    func stopAll() {
        lock.lock()
        let current = activeStream
        if let current {
            inputClient.endMicrophoneStream(
                streamID: current.streamID,
                timestampMicroseconds: DispatchTime.now().uptimeNanoseconds / 1_000
            )
        }
        activeStream = nil
        lock.unlock()
        if current != nil { notify(nil) }
    }

    func snapshot() -> ActiveStream? {
        lock.lock()
        defer { lock.unlock() }
        return activeStream
    }

    private func notify(_ stream: ActiveStream?) {
        let callback = onStateChange
        DispatchQueue.main.async {
            callback?(stream)
        }
    }
}
