import Foundation

/// Headless owner of the local iPhone media path.
///
/// The process intentionally contains no setup UI. Capture is allowed only
/// when the exact DAL unique ID is supplied by configuration or was already
/// stored under the existing signed bundle's Keychain identity.
@MainActor
final class IPhoneUSBDriver {
    private let configuration: ConsoleConfiguration
    private let statusWriter: ConsoleStatusWriter
    private let capture: USBScreenCapture
    private let videoEncoder: H264VideoEncoder
    private let audioEncoder: OpusAudioEncoder
    private let mediaServer: UnixMediaSocketServer

    private var captureObserverToken: UInt64?
    private var audioObserverToken: UInt64?
    private var heartbeatTimer: Timer?
    private var mediaRestartWorkItem: DispatchWorkItem?
    private var mediaRestartAttempt = 0
    private var started = false
    private var shuttingDown = false

    init(configuration: ConsoleConfiguration) {
        self.configuration = configuration
        let credentialStore = SecureCredentialStore(tokenFileURL: configuration.bridgeTokenFileURL)
        let pairedCaptureID = configuration.captureDeviceUniqueID ??
            (try? credentialStore.loadCaptureDeviceUniqueID())

        statusWriter = ConsoleStatusWriter(
            fileURL: configuration.statusFileURL,
            deviceID: configuration.deviceID,
            displayName: configuration.displayName
        )
        capture = USBScreenCapture(
            targetUDID: configuration.targetUDID,
            expectedCaptureDeviceUniqueID: pairedCaptureID,
            targetFrameRate: Double(configuration.encoder.expectedFrameRate),
            audioPreviewPolicy: .disabled
        )
        videoEncoder = H264VideoEncoder(configuration: configuration.encoder)
        audioEncoder = OpusAudioEncoder(bitRate: configuration.audioBitRate)
        mediaServer = UnixMediaSocketServer(
            videoSocketURL: configuration.videoSocketURL,
            audioSocketURL: configuration.audioSocketURL,
            controlSocketURL: configuration.controlSocketURL
        )

        if pairedCaptureID == nil {
            statusWriter.updateError("capture_pairing_required")
        }
    }

    func start() {
        guard !started, !shuttingDown else { return }
        started = true
        configureCallbacks()

        videoEncoder.onConfiguration = { [weak mediaServer] configuration in
            mediaServer?.publish(videoConfiguration: configuration)
        }
        videoEncoder.onAccessUnit = { [weak mediaServer] accessUnit in
            mediaServer?.publish(videoAccessUnit: accessUnit)
        }
        audioEncoder.onConfiguration = { [weak mediaServer] configuration in
            mediaServer?.publish(audioConfiguration: configuration)
        }
        audioEncoder.onPacket = { [weak mediaServer] packet in
            mediaServer?.publish(audioPacket: packet)
        }
        mediaServer.onKeyFrameRequested = { [weak videoEncoder] in
            videoEncoder?.requestKeyFrame()
        }

        videoEncoder.start()
        audioEncoder.start()
        captureObserverToken = capture.addSampleBufferObserver { [weak videoEncoder] sample, timing in
            videoEncoder?.submit(sample, timing: timing)
        }
        audioObserverToken = capture.addAudioSampleBufferObserver { [weak audioEncoder] sample, timing in
            audioEncoder?.submit(sample, timing: timing)
        }

        statusWriter.updateDriverRunning(true)
        statusWriter.updateWebRunning(false)
        statusWriter.updateRFBConnected(false)
        statusWriter.updateMicrophoneBridgeState("direct")
        mediaServer.start()
        capture.start()
        startHeartbeat()
    }

    func shutdown() {
        guard started, !shuttingDown else { return }
        shuttingDown = true
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        mediaRestartWorkItem?.cancel()
        mediaRestartWorkItem = nil

        if let captureObserverToken {
            capture.removeSampleBufferObserver(captureObserverToken)
            self.captureObserverToken = nil
        }
        if let audioObserverToken {
            capture.removeAudioSampleBufferObserver(audioObserverToken)
            self.audioObserverToken = nil
        }

        capture.stop()
        videoEncoder.stop()
        audioEncoder.stop()
        mediaServer.stop()
        statusWriter.updateCapture(running: false, frameAgeMilliseconds: nil)
        statusWriter.updateAudioRunning(false)
        statusWriter.updateMediaSockets(video: false, audio: false, control: false)
        statusWriter.updateDriverRunning(false)
        statusWriter.updateMicrophoneBridgeState("unavailable")
    }

    private func configureCallbacks() {
        capture.onStateChange = { [weak self] state in
            guard let self else { return }
            let running = state == .running
            statusWriter.updateCapture(
                running: running,
                frameAgeMilliseconds: running ? capture.frameAgeMetrics.averageMilliseconds : nil
            )
            if running {
                statusWriter.updateError(nil)
            } else if let error = capture.lastError {
                statusWriter.updateError(captureErrorCode(error))
            }
        }
        capture.onFPSChange = { [weak self] _ in
            guard let self else { return }
            statusWriter.updateCapture(
                running: capture.state == .running,
                frameAgeMilliseconds: capture.frameAgeMetrics.averageMilliseconds
            )
        }
        capture.onFrameAgeChange = { [weak self] metrics in
            guard let self else { return }
            statusWriter.updateCapture(
                running: capture.state == .running,
                frameAgeMilliseconds: metrics.averageMilliseconds
            )
        }
        capture.onTargetUSBConnectionChange = { [weak self] connected in
            self?.statusWriter.updateUSBConnected(connected)
        }
        capture.onAudioAvailabilityChange = { [weak self] availability in
            self?.statusWriter.updateAudioRunning(availability == .available)
        }
        mediaServer.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .stopped, .starting:
                    statusWriter.updateMediaSockets(video: false, audio: false, control: false)
                case .running:
                    mediaRestartAttempt = 0
                    mediaRestartWorkItem?.cancel()
                    mediaRestartWorkItem = nil
                    statusWriter.updateMediaSockets(video: true, audio: true, control: true)
                    if capture.state == .running { statusWriter.updateError(nil) }
                case .failed(let reason):
                    statusWriter.updateMediaSockets(video: false, audio: false, control: false)
                    statusWriter.updateError("driver_socket_\(Self.sanitize(reason))")
                    scheduleMediaRestart()
                }
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in self?.statusWriter.heartbeat() }
        }
        heartbeatTimer?.tolerance = 1
    }

    private func scheduleMediaRestart() {
        guard !shuttingDown, mediaRestartWorkItem == nil else { return }
        let delay = min(pow(2, Double(mediaRestartAttempt)), 15)
        mediaRestartAttempt = min(mediaRestartAttempt + 1, 5)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            mediaRestartWorkItem = nil
            guard !shuttingDown else { return }
            mediaServer.start()
        }
        mediaRestartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func captureErrorCode(_ error: USBScreenCapture.CaptureError) -> String {
        switch error {
        case .targetUSBDeviceNotConnected:
            return "capture_target_usb_missing"
        case .captureDevicePairingRequired:
            return "capture_pairing_required"
        case .configuredCaptureDeviceUnavailable:
            return "capture_paired_device_missing"
        case .captureDevicePairingAmbiguous:
            return "capture_pairing_ambiguous"
        case .deviceInUse:
            return "capture_device_in_use"
        case .firstFrameTimedOut:
            return "capture_first_frame_timeout"
        case .streamStalled:
            return "capture_stream_stalled"
        default:
            return "capture_\(String(describing: error))"
        }
    }

    private static func sanitize(_ value: String) -> String {
        String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != "="
        }.prefix(160))
    }
}
