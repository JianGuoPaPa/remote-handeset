import AVFoundation
import AudioToolbox
import Combine
import CoreMedia
import CoreMediaIO
import CryptoKit
import Foundation

/// Owns a single, wired iOS screen-capture session.
///
/// Capture configuration and recovery are serialized on a private queue. All
/// published properties and callbacks are delivered on the main queue. The
/// Capture is bound to a configured or explicitly paired device unique ID.
/// If the DAL cannot prove the relationship to the target usbmux UDID, capture
/// refuses to start rather than silently selecting another attached iPhone.
final class USBScreenCapture: NSObject, ObservableObject, @unchecked Sendable {
    /// Controls whether captured iPhone audio is also routed to the Mac's
    /// default output device. This is independent from `AVCaptureAudioDataOutput`,
    /// which remains available to remote encoders when local preview is disabled.
    enum AudioPreviewPolicy: Equatable, Sendable {
        case enabled
        case disabled
    }

    /// Timing captured at the beginning of the video-output callback.
    ///
    /// `arrivalAgeSeconds` is `hostArrivalTime - presentationHostTime`. A
    /// positive value is the age of the frame when AVFoundation delivered it;
    /// a small negative value means the sample PTS was slightly ahead of the
    /// host clock at delivery. It is nil when AVFoundation has no usable
    /// synchronization clock for the sample.
    struct SampleTiming: Equatable, Sendable {
        let presentationTime: CMTime
        let presentationHostTime: CMTime?
        let hostArrivalTime: CMTime
        let arrivalAgeSeconds: TimeInterval?
    }

    /// One approximately one-second window of frame-arrival age measurements.
    struct FrameAgeMetrics: Equatable, Sendable {
        let latestSeconds: TimeInterval?
        let averageSeconds: TimeInterval?
        let maximumSeconds: TimeInterval?
        let sampleCount: Int

        static let empty = FrameAgeMetrics(
            latestSeconds: nil,
            averageSeconds: nil,
            maximumSeconds: nil,
            sampleCount: 0
        )

        var latestMilliseconds: Double? { latestSeconds.map { $0 * 1_000 } }
        var averageMilliseconds: Double? { averageSeconds.map { $0 * 1_000 } }
        var maximumMilliseconds: Double? { maximumSeconds.map { $0 * 1_000 } }
    }

    struct CaptureCandidate: Equatable, Sendable {
        let localizedName: String
        let fingerprint: String

        var displayLabel: String {
            "\(localizedName) · \(fingerprint)"
        }
    }

    enum State: Equatable, Sendable {
        case idle
        case requestingAuthorization
        case searching
        case configuring
        case running
        case waitingForDevice
        case interrupted
        case recovering
        case permissionDenied
        case permissionRestricted
        case failed
    }

    enum AudioAvailability: Equatable, Sendable {
        case unavailable
        case requestingAuthorization
        case available
        case permissionDenied
        case permissionRestricted
    }

    enum CaptureError: Error, Equatable, Sendable {
        case coreMediaIO(status: OSStatus)
        case deviceInUse
        case deviceConfiguration(code: Int)
        case inputCreation(code: Int)
        case cannotAddInput
        case cannotAddVideoOutput
        case cannotAddAudioDataOutput
        case cannotAddAudioPreviewOutput
        case sessionDidNotStart
        case firstFrameTimedOut
        case streamStalled
        case runtimeError(code: Int)
        case targetUSBDeviceNotConnected
        case captureDevicePairingRequired(candidateFingerprints: [String])
        case configuredCaptureDeviceUnavailable
        case captureDevicePairingAmbiguous
    }

    typealias StateHandler = (State) -> Void
    typealias FPSHandler = (Double) -> Void
    typealias FrameAgeHandler = (FrameAgeMetrics) -> Void
    typealias AudioAvailabilityHandler = (AudioAvailability) -> Void
    typealias TargetUSBConnectionHandler = (Bool) -> Void
    typealias CaptureCandidatesHandler = ([CaptureCandidate]) -> Void
    typealias SampleBufferHandler = @Sendable (CMSampleBuffer, SampleTiming) -> Void

    private(set) var session: AVCaptureSession
    let targetFrameRate: Double

    @Published private(set) var state: State = .idle
    @Published private(set) var fps: Double = 0
    @Published private(set) var frameAgeMetrics: FrameAgeMetrics = .empty
    @Published private(set) var deviceName: String?
    @Published private(set) var lastError: CaptureError?
    @Published private(set) var audioAvailability: AudioAvailability = .unavailable
    @Published private(set) var targetUSBConnected = false
    @Published private(set) var captureSelectionStrategy = "unpaired"
    @Published private(set) var captureCandidateFingerprints: [String] = []
    @Published private(set) var captureCandidates: [CaptureCandidate] = []

    /// Invoked on the main queue after `state` has been updated.
    var onStateChange: StateHandler?

    /// Invoked on the main queue after `fps` has been updated.
    var onFPSChange: FPSHandler?

    /// Invoked on the main queue with the same aggregate published to
    /// `frameAgeMetrics`.
    var onFrameAgeChange: FrameAgeHandler?

    /// Invoked on the main queue whenever captured iPhone audio becomes
    /// available or is intentionally degraded to video-only operation.
    var onAudioAvailabilityChange: AudioAvailabilityHandler?

    /// Invoked on the main queue when target USB presence is re-evaluated.
    var onTargetUSBConnectionChange: TargetUSBConnectionHandler?

    /// Candidate labels contain only the DAL localized name and a short hash;
    /// the underlying unique ID remains private until explicit confirmation.
    var onCaptureCandidatesChange: CaptureCandidatesHandler?

    var framesPerSecond: Double { fps }
    var frameAgeMilliseconds: Double? { frameAgeMetrics.latestMilliseconds }

    private let sessionQueue = DispatchQueue(label: "USBScreenCapture.session", qos: .userInitiated)
    private let sampleBufferQueue = DispatchQueue(label: "USBScreenCapture.samples", qos: .userInteractive)
    private let audioSampleBufferQueue = DispatchQueue(
        label: "USBScreenCapture.audio-samples",
        qos: .userInteractive
    )
    private let sampleQueueKey = DispatchSpecificKey<UInt8>()
    private let audioSampleQueueKey = DispatchSpecificKey<UInt8>()

    private var videoOutput: AVCaptureVideoDataOutput
    private var audioDataOutput: AVCaptureAudioDataOutput
    private var audioPreviewOutput: AVCaptureAudioPreviewOutput
    private let sampleHandlerLock = NSLock()
    private let audioObserverLock = NSLock()
    private let sampleLivenessLock = NSLock()
    private var sampleHandlerToken: UInt64 = 0
    private var sampleBufferHandler: SampleBufferHandler?
    private var sampleObserverToken: UInt64 = 0
    private var sampleBufferObservers: [UInt64: SampleBufferHandler] = [:]
    private var audioObserverToken: UInt64 = 0
    private var audioSampleBufferObservers: [UInt64: SampleBufferHandler] = [:]
    private var requestedAudioPreviewVolume: Float = 1
    private let audioPreviewPolicy: AudioPreviewPolicy
    private var activeDevice: AVCaptureDevice?
    private let targetUDID: String
    private var expectedCaptureDeviceUniqueID: String?
    private var observerTokens: [NSObjectProtocol] = []
    private var retryWorkItem: DispatchWorkItem?
    private var firstFrameTimeoutWorkItem: DispatchWorkItem?
    private var frameWatchdogWorkItem: DispatchWorkItem?
    private var interruptionRecoveryWorkItem: DispatchWorkItem?
    private var lastSampleUptimeNanoseconds: UInt64 = 0
    private var recoveryAttempt = 0
    private var desiredRunning = false
    private var transitionInProgress = false
    private var authorizationRequestInFlight = false
    private var audioCaptureAuthorized = false
    // Accessed only on sessionQueue. The remote data path and the local
    // preview path are deliberately independent: failure of either output must
    // never remove, mute, or gate the other output.
    private var audioDataOutputConfigured = false
    private var audioPreviewOutputConfigured = false
    private var audioDataConnectionActive = false
    private var audioPreviewConnectionActive = false
    private var generation = 0
    private var firstFrameSeenGeneration = 0

    // Accessed only on sampleBufferQueue.
    private var sampleGeneration = 0
    private var sampleDeliveryEnabled = false
    private var sampleVideoOutput: AVCaptureVideoDataOutput?
    private var sampleSynchronizationClock: CMClock?
    private var firstFrameReportedGeneration = 0
    private var fpsWindowStartSeconds: Double?
    private var fpsWindowFrameCount = 0
    private var ageWindowLatestSeconds: Double?
    private var ageWindowTotalSeconds: Double = 0
    private var ageWindowMaximumSeconds: Double?
    private var ageWindowSampleCount = 0

    // Accessed only on audioSampleBufferQueue. Keeping the output identity,
    // generation, and synchronization clock on the delegate queue prevents a
    // callback from reading the session graph while sessionQueue replaces it.
    private var audioSampleGeneration = 0
    private var audioSampleDeliveryEnabled = false
    private var sampleAudioOutput: AVCaptureAudioDataOutput?
    private var audioSynchronizationClock: CMClock?

    // Accessed only on the main queue.
    private var publishedGeneration = 0

    init(
        targetUDID: String,
        expectedCaptureDeviceUniqueID: String?,
        targetFrameRate: Double = 30,
        audioPreviewPolicy: AudioPreviewPolicy = .enabled
    ) {
        self.targetUDID = targetUDID
        self.expectedCaptureDeviceUniqueID = expectedCaptureDeviceUniqueID
        self.targetFrameRate = targetFrameRate.isFinite ? min(max(1, targetFrameRate), 240) : 60
        self.audioPreviewPolicy = audioPreviewPolicy
        session = AVCaptureSession()
        videoOutput = AVCaptureVideoDataOutput()
        audioDataOutput = AVCaptureAudioDataOutput()
        audioPreviewOutput = AVCaptureAudioPreviewOutput()
        super.init()

        sampleBufferQueue.setSpecific(key: sampleQueueKey, value: 1)
        audioSampleBufferQueue.setSpecific(key: audioSampleQueueKey, value: 1)
        configureOutputDelegates()
        installObservers()
    }

    /// Persists the operator-confirmed DAL unique ID outside this class, then
    /// calls this method to make all future discovery strict.
    func setExpectedCaptureDeviceUniqueID(_ uniqueID: String) {
        sessionQueue.async { [weak self] in
            guard let self, !uniqueID.isEmpty else { return }
            expectedCaptureDeviceUniqueID = uniqueID
            desiredRunning = true
            transitionInProgress = false
            retryWorkItem?.cancel()
            retryWorkItem = nil
            invalidateGeneration()
            tearDownSession()
            discoverAndStart()
        }
    }

    /// Returns a pairing candidate only after an explicit operator action and
    /// only when the target usbmux device is present and the DAL exposes one
    /// unambiguous wired capture source. No automatic first-device fallback is
    /// ever performed.
    func requestSingleDevicePairingCandidate(
        completion: @escaping @Sendable (Result<String, CaptureError>) -> Void
    ) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let inspection = inspectUSBDevices()
            guard inspection.targetConnected else {
                DispatchQueue.main.async {
                    completion(.failure(.targetUSBDeviceNotConnected))
                }
                return
            }
            do {
                try configureCoreMediaIOScreenDiscovery()
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(.coreMediaIO(status: OSStatus((error as NSError).code))))
                }
                return
            }
            let candidates = discoverWiredMuxedDevices()
            guard candidates.count == 1, let candidate = candidates.first else {
                DispatchQueue.main.async {
                    completion(.failure(.captureDevicePairingAmbiguous))
                }
                return
            }
            let uniqueID = candidate.uniqueID
            DispatchQueue.main.async {
                completion(.success(uniqueID))
            }
        }
    }

    func requestPairingCandidate(
        fingerprint: String,
        completion: @escaping @Sendable (Result<String, CaptureError>) -> Void
    ) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let inspection = inspectUSBDevices()
            guard inspection.targetConnected else {
                DispatchQueue.main.async {
                    completion(.failure(.targetUSBDeviceNotConnected))
                }
                return
            }
            do {
                try configureCoreMediaIOScreenDiscovery()
            } catch let error as CaptureError {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(.captureDevicePairingAmbiguous))
                }
                return
            }
            let matches = discoverWiredMuxedDevices().filter {
                Self.captureFingerprint($0) == fingerprint
            }
            guard matches.count == 1, let candidate = matches.first else {
                DispatchQueue.main.async {
                    completion(.failure(.captureDevicePairingAmbiguous))
                }
                return
            }
            DispatchQueue.main.async {
                completion(.success(candidate.uniqueID))
            }
        }
    }

    deinit {
        retryWorkItem?.cancel()
        firstFrameTimeoutWorkItem?.cancel()
        frameWatchdogWorkItem?.cancel()
        interruptionRecoveryWorkItem?.cancel()
        observerTokens.forEach(NotificationCenter.default.removeObserver)
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        audioDataOutput.setSampleBufferDelegate(nil, queue: nil)
    }

    /// Installs the single synchronous sample consumer used by a custom
    /// preview. The callback runs on `sampleBufferQueue`; it must return
    /// promptly and retain or enqueue the sample before returning if it needs
    /// the sample afterwards. Installing a new callback replaces the old one.
    ///
    /// The returned token lets an owner clear only its own registration, so a
    /// stale preview cannot remove a newer consumer during teardown.
    @discardableResult
    func setSampleBufferHandler(_ handler: SampleBufferHandler?) -> UInt64 {
        sampleHandlerLock.lock()
        defer { sampleHandlerLock.unlock() }
        sampleHandlerToken &+= 1
        sampleBufferHandler = handler
        return sampleHandlerToken
    }

    /// Clears the callback only if it is still the registration represented by
    /// `token`.
    func clearSampleBufferHandler(ifMatching token: UInt64) {
        sampleHandlerLock.lock()
        defer { sampleHandlerLock.unlock() }
        guard sampleHandlerToken == token else { return }
        sampleHandlerToken &+= 1
        sampleBufferHandler = nil
    }

    /// Adds an independent synchronous observer without replacing the primary
    /// preview consumer. Observers run on `sampleBufferQueue` from a lock-free
    /// snapshot and therefore must only retain/replace work before returning.
    /// Removal prevents future snapshots but may not cancel a callback already
    /// in progress.
    @discardableResult
    func addSampleBufferObserver(_ observer: @escaping SampleBufferHandler) -> UInt64 {
        sampleHandlerLock.lock()
        defer { sampleHandlerLock.unlock() }
        repeat {
            sampleObserverToken &+= 1
        } while sampleObserverToken == 0 || sampleBufferObservers[sampleObserverToken] != nil
        sampleBufferObservers[sampleObserverToken] = observer
        return sampleObserverToken
    }

    func removeSampleBufferObserver(_ token: UInt64) {
        guard token != 0 else { return }
        sampleHandlerLock.lock()
        sampleBufferObservers.removeValue(forKey: token)
        sampleHandlerLock.unlock()
    }

    /// Adds an independent observer for the iPhone system-audio track carried
    /// by the same wired muxed capture device as the screen video. Callbacks are
    /// serialized on a dedicated high-priority queue and must return promptly.
    @discardableResult
    func addAudioSampleBufferObserver(_ observer: @escaping SampleBufferHandler) -> UInt64 {
        audioObserverLock.lock()
        defer { audioObserverLock.unlock() }
        repeat {
            audioObserverToken &+= 1
        } while audioObserverToken == 0 || audioSampleBufferObservers[audioObserverToken] != nil
        audioSampleBufferObservers[audioObserverToken] = observer
        return audioObserverToken
    }

    func removeAudioSampleBufferObserver(_ token: UInt64) {
        guard token != 0 else { return }
        audioObserverLock.lock()
        audioSampleBufferObservers.removeValue(forKey: token)
        audioObserverLock.unlock()
    }

    /// Controls AVFoundation's direct captured-audio preview path. The value is
    /// retained across USB graph recreation and clamped to the documented range.
    func setAudioPreviewVolume(_ volume: Float) {
        let clamped = min(max(volume.isFinite ? volume : 0, 0), 1)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard audioPreviewPolicy == .enabled else {
                requestedAudioPreviewVolume = 0
                audioPreviewOutput.volume = 0
                return
            }
            requestedAudioPreviewVolume = clamped
            audioPreviewOutput.volume = clamped
        }
    }

    /// Begins authorization, discovery, and capture. Safe to call repeatedly.
    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            desiredRunning = true
            recoveryAttempt = 0
            beginAuthorizationIfNeeded()
        }
    }

    /// Stops capture, releases the device, and cancels automatic recovery.
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            desiredRunning = false
            transitionInProgress = false
            retryWorkItem?.cancel()
            retryWorkItem = nil
            recoveryAttempt = 0
            invalidateGeneration()
            tearDownSession()
            publish(state: .idle, deviceName: nil, error: nil, fps: 0)
        }
    }

    /// Forces a clean rediscovery while keeping the desired running state.
    func retry() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            desiredRunning = true
            guard !authorizationRequestInFlight else { return }
            transitionInProgress = false
            retryWorkItem?.cancel()
            retryWorkItem = nil
            recoveryAttempt = 0
            invalidateGeneration()
            tearDownSession()
            beginAuthorizationIfNeeded()
        }
    }

    private func beginAuthorizationIfNeeded() {
        guard desiredRunning, !transitionInProgress else { return }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            beginAudioAuthorizationIfNeeded()
        case .notDetermined:
            transitionInProgress = true
            authorizationRequestInFlight = true
            publish(state: .requestingAuthorization, deviceName: nil, error: nil, fps: 0)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                sessionQueue.async {
                    self.authorizationRequestInFlight = false
                    self.transitionInProgress = false
                    guard self.desiredRunning else { return }
                    if granted {
                        self.beginAudioAuthorizationIfNeeded()
                    } else {
                        self.audioCaptureAuthorized = false
                        self.publish(audioAvailability: .unavailable)
                        self.publish(
                            state: .permissionDenied,
                            deviceName: nil,
                            error: nil,
                            fps: 0
                        )
                    }
                }
            }
        case .denied:
            audioCaptureAuthorized = false
            publish(audioAvailability: .unavailable)
            publish(state: .permissionDenied, deviceName: nil, error: nil, fps: 0)
        case .restricted:
            audioCaptureAuthorized = false
            publish(audioAvailability: .unavailable)
            publish(state: .permissionRestricted, deviceName: nil, error: nil, fps: 0)
        @unknown default:
            audioCaptureAuthorized = false
            publish(audioAvailability: .unavailable)
            publish(state: .permissionRestricted, deviceName: nil, error: nil, fps: 0)
        }
    }

    private func beginAudioAuthorizationIfNeeded() {
        guard desiredRunning, !transitionInProgress else { return }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            audioCaptureAuthorized = true
            publish(audioAvailability: .unavailable)
            discoverAndStart()
        case .notDetermined:
            transitionInProgress = true
            authorizationRequestInFlight = true
            publish(audioAvailability: .requestingAuthorization)
            publish(state: .requestingAuthorization, deviceName: nil, error: nil, fps: 0)
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else { return }
                sessionQueue.async {
                    self.authorizationRequestInFlight = false
                    self.transitionInProgress = false
                    guard self.desiredRunning else { return }
                    self.audioCaptureAuthorized = granted
                    self.publish(audioAvailability: granted ? .unavailable : .permissionDenied)
                    // Audio permission is optional for the USB console. A denial
                    // keeps the video/control path running instead of failing the
                    // entire capture session.
                    self.discoverAndStart()
                }
            }
        case .denied:
            audioCaptureAuthorized = false
            publish(audioAvailability: .permissionDenied)
            discoverAndStart()
        case .restricted:
            audioCaptureAuthorized = false
            publish(audioAvailability: .permissionRestricted)
            discoverAndStart()
        @unknown default:
            audioCaptureAuthorized = false
            publish(audioAvailability: .permissionRestricted)
            discoverAndStart()
        }
    }

    private func discoverAndStart() {
        guard desiredRunning, !transitionInProgress else { return }
        transitionInProgress = true
        retryWorkItem?.cancel()
        retryWorkItem = nil

        publish(state: .searching, deviceName: nil, error: nil, fps: 0)

        do {
            try configureCoreMediaIOScreenDiscovery()
        } catch let error as CaptureError {
            transitionInProgress = false
            publish(state: .failed, deviceName: nil, error: error, fps: 0)
            scheduleRecovery()
            return
        } catch {
            transitionInProgress = false
            publish(state: .failed, deviceName: nil, error: nil, fps: 0)
            scheduleRecovery()
            return
        }

        let inspection = inspectUSBDevices()
        publishUSBInspection(inspection)
        guard inspection.targetConnected else {
            transitionInProgress = false
            publish(
                state: .waitingForDevice,
                deviceName: nil,
                error: .targetUSBDeviceNotConnected,
                fps: 0
            )
            scheduleRecovery()
            return
        }

        let devices = discoverWiredMuxedDevices()
        publishCaptureCandidates(devices)
        guard !devices.isEmpty else {
            transitionInProgress = false
            publish(state: .waitingForDevice, deviceName: nil, error: nil, fps: 0)
            scheduleRecovery()
            return
        }

        let selection = selectTargetCaptureDevice(from: devices)
        guard let device = selection.device else {
            transitionInProgress = false
            publish(
                state: .waitingForDevice,
                deviceName: nil,
                error: selection.error,
                fps: 0
            )
            scheduleRecovery()
            return
        }
        publishCaptureSelectionStrategy(selection.strategy)

        guard !device.isInUseByAnotherApplication else {
            transitionInProgress = false
            publish(state: .waitingForDevice, deviceName: nil, error: .deviceInUse, fps: 0)
            scheduleRecovery()
            return
        }

        publish(state: .configuring, deviceName: device.localizedName, error: nil, fps: 0)

        do {
            try configureSession(for: device)
            guard desiredRunning else {
                transitionInProgress = false
                tearDownSession()
                return
            }

            let currentGeneration = beginGeneration()
            session.startRunning()
            guard session.isRunning else {
                throw CaptureError.sessionDidNotStart
            }
            refreshSampleSynchronizationClock(for: currentGeneration)
            validateAudioOutputsAfterStart(generation: currentGeneration)

            transitionInProgress = false
            recoveryAttempt = 0
            publish(
                state: .running,
                deviceName: device.localizedName,
                error: nil,
                fps: 0,
                generation: currentGeneration
            )
            scheduleFirstFrameTimeout(for: currentGeneration)
            scheduleFrameWatchdog(for: currentGeneration)
        } catch let error as CaptureError {
            transitionInProgress = false
            invalidateGeneration()
            tearDownSession()
            publish(state: .recovering, deviceName: nil, error: error, fps: 0)
            scheduleRecovery()
        } catch {
            let code = (error as NSError).code
            transitionInProgress = false
            invalidateGeneration()
            tearDownSession()
            publish(state: .recovering, deviceName: nil, error: .inputCreation(code: code), fps: 0)
            scheduleRecovery()
        }
    }

    private struct USBInspection {
        let deviceCount: UInt32
        let targetConnected: Bool
    }

    private struct CaptureSelection {
        let device: AVCaptureDevice?
        let strategy: String
        let error: CaptureError?
    }

    private func inspectUSBDevices() -> USBInspection {
        var count: UInt32 = 0
        var targetConnected: Int32 = 0
        let status = targetUDID.withCString { pointer in
            IUSCUSBMuxInspectUSBDevices(pointer, &count, &targetConnected)
        }
        guard status == IUSCUSBMuxSuccess else {
            return USBInspection(deviceCount: 0, targetConnected: false)
        }
        return USBInspection(deviceCount: count, targetConnected: targetConnected == 1)
    }

    private func selectTargetCaptureDevice(from devices: [AVCaptureDevice]) -> CaptureSelection {
        if let expectedCaptureDeviceUniqueID {
            if let exact = devices.first(where: { $0.uniqueID == expectedCaptureDeviceUniqueID }) {
                return CaptureSelection(device: exact, strategy: "paired_unique_id", error: nil)
            }
            return CaptureSelection(
                device: nil,
                strategy: "paired_device_missing",
                error: .configuredCaptureDeviceUnavailable
            )
        }

        let normalizedTarget = Self.normalizedHardwareIdentifier(targetUDID)
        let embeddedMatches = devices.filter {
            Self.normalizedHardwareIdentifier($0.uniqueID).contains(normalizedTarget)
        }
        if embeddedMatches.count == 1, let matched = embeddedMatches.first {
            return CaptureSelection(device: matched, strategy: "udid_embedded_in_dal_uid", error: nil)
        }

        return CaptureSelection(
            device: nil,
            strategy: "pairing_required",
            error: .captureDevicePairingRequired(
                candidateFingerprints: devices.map(Self.captureFingerprint)
            )
        )
    }

    private func publishUSBInspection(_ inspection: USBInspection) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            targetUSBConnected = inspection.targetConnected
            onTargetUSBConnectionChange?(inspection.targetConnected)
        }
    }

    private func publishCaptureCandidates(_ devices: [AVCaptureDevice]) {
        let candidates = devices.map { device in
            CaptureCandidate(
                localizedName: device.localizedName,
                fingerprint: Self.captureFingerprint(device)
            )
        }
        let fingerprints = candidates.map(\.fingerprint)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            captureCandidateFingerprints = fingerprints
            captureCandidates = candidates
            onCaptureCandidatesChange?(candidates)
        }
    }

    private func publishCaptureSelectionStrategy(_ strategy: String) {
        DispatchQueue.main.async { [weak self] in
            self?.captureSelectionStrategy = strategy
        }
    }

    private static func normalizedHardwareIdentifier(_ value: String) -> String {
        value.uppercased().filter(\.isHexDigit)
    }

    private static func captureFingerprint(_ device: AVCaptureDevice) -> String {
        let digest = SHA256.hash(data: Data(device.uniqueID.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private func configureCoreMediaIOScreenDiscovery() throws {
        try setCoreMediaIOProperty(kCMIOHardwarePropertyAllowScreenCaptureDevices, value: 1)
        try setCoreMediaIOProperty(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices, value: 0)
    }

    private func setCoreMediaIOProperty(_ selector: Int, value: UInt32) throws {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var mutableValue = value
        let status = CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &mutableValue
        )
        guard status == noErr else {
            throw CaptureError.coreMediaIO(status: status)
        }
    }

    private func discoverWiredMuxedDevices() -> [AVCaptureDevice] {
        // The system iOSScreenCapture DAL publishes the wired display as a
        // muxed external source. Wireless publication is disabled above.
        let externalDeviceType: AVCaptureDevice.DeviceType
        if #available(macOS 14.0, *) {
            externalDeviceType = .external
        } else {
            externalDeviceType = AVCaptureDevice.DeviceType(rawValue: "AVCaptureDeviceTypeExternalUnknown")
        }
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [externalDeviceType],
            mediaType: .muxed,
            position: .unspecified
        )
        let candidates = discoverySession.devices.filter { device in
            device.isConnected && !device.isSuspended
        }

        // Prefer an explicit USB transport while retaining compatibility with
        // DAL versions that report a virtual transport for the wired device.
        let usbTransport = Int32(bitPattern: 0x7573_6220) // 'usb '
        return candidates.sorted { lhs, rhs in
            let lhsRank = deviceRank(lhs, usbTransport: usbTransport)
            let rhsRank = deviceRank(rhs, usbTransport: usbTransport)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.localizedName.localizedStandardCompare(rhs.localizedName) == .orderedAscending
        }
    }

    private func deviceRank(_ device: AVCaptureDevice, usbTransport: Int32) -> Int {
        if device.isInUseByAnotherApplication { return 2 }
        if device.transportType == usbTransport { return 0 }
        return 1
    }

    private func configureSession(for device: AVCaptureDevice) throws {
        tearDownSession()

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        try configurePreferredFrameRate(on: device)

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CaptureError.inputCreation(code: (error as NSError).code)
        }

        guard session.canAddInput(input) else {
            throw CaptureError.cannotAddInput
        }
        session.addInput(input)

        guard session.canAddOutput(videoOutput) else {
            session.removeInput(input)
            throw CaptureError.cannotAddVideoOutput
        }
        // Request AVFoundation's default uncompressed native pixel-buffer
        // output. Independent image buffers are safe for latest-frame dropping.
        videoOutput.videoSettings = nil
        session.addOutput(videoOutput)

        configureAudioOutputsIfAvailable()

        activeDevice = device
    }

    private func configureAudioOutputsIfAvailable() {
        resetAudioOutputState()
        guard audioCaptureAuthorized else { return }

        if session.canAddOutput(audioDataOutput) {
            audioDataOutput.audioSettings = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            session.addOutput(audioDataOutput)
            audioDataOutputConfigured = true
        }

        if audioPreviewPolicy == .enabled, session.canAddOutput(audioPreviewOutput) {
            // nil follows the current macOS default output.
            // AVCaptureAudioPreviewOutput initializes muted, so always apply
            // the retained explicit volume when this best-effort path exists.
            audioPreviewOutput.outputDeviceUniqueID = nil
            audioPreviewOutput.volume = requestedAudioPreviewVolume
            session.addOutput(audioPreviewOutput)
            audioPreviewOutputConfigured = true
        }

        if !audioDataOutputConfigured, !audioPreviewOutputConfigured {
            publish(audioAvailability: .unavailable)
        }
    }

    private func validateAudioOutputsAfterStart(generation expectedGeneration: Int) {
        guard audioCaptureAuthorized else {
            resetAudioConnectionState()
            updateAudioSampleGate(generation: expectedGeneration, deliveryEnabled: false)
            return
        }

        audioDataConnectionActive = audioDataOutputConfigured &&
            audioDataOutput.connection(with: .audio)?.isActive == true
        audioPreviewConnectionActive = audioPreviewOutputConfigured &&
            audioPreviewOutput.connection(with: .audio)?.isActive == true

        // IUAC/Web delivery depends only on the data-output connection. Local
        // playback remains best-effort and can fail independently without
        // disabling or removing the remote output.
        updateAudioSampleGate(
            generation: expectedGeneration,
            deliveryEnabled: audioDataConnectionActive
        )

        if audioPreviewConnectionActive {
            audioPreviewOutput.volume = requestedAudioPreviewVolume
        } else {
            audioPreviewOutput.volume = 0
        }

        // This public state describes whether at least one captured-audio path
        // is usable. The remote sample gate above remains strictly data-only.
        publish(
            audioAvailability: audioDataConnectionActive || audioPreviewConnectionActive
                ? .available
                : .unavailable
        )
    }

    private func resetAudioOutputState() {
        audioDataOutputConfigured = false
        audioPreviewOutputConfigured = false
        resetAudioConnectionState()
    }

    private func resetAudioConnectionState() {
        audioDataConnectionActive = false
        audioPreviewConnectionActive = false
    }

    private func configurePreferredFrameRate(on device: AVCaptureDevice) throws {
        let target = targetFrameRate
        let formats = device.formats.filter { format in
            format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= target + 0.001 && range.maxFrameRate >= target - 0.001
            }
        }

        guard let preferredFormat = formats.max(by: { formatScore($0) < formatScore($1) }) else {
            return
        }

        do {
            try device.lockForConfiguration()
        } catch {
            throw CaptureError.deviceConfiguration(code: (error as NSError).code)
        }
        defer { device.unlockForConfiguration() }

        device.activeFormat = preferredFormat
        let duration = CMTime(seconds: 1 / target, preferredTimescale: 60_000)
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    private func formatScore(_ format: AVCaptureDevice.Format) -> Int64 {
        let description = format.formatDescription
        guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video else { return 0 }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        return Int64(dimensions.width) * Int64(dimensions.height)
    }

    private func tearDownSession() {
        firstFrameTimeoutWorkItem?.cancel()
        firstFrameTimeoutWorkItem = nil
        frameWatchdogWorkItem?.cancel()
        frameWatchdogWorkItem = nil
        interruptionRecoveryWorkItem?.cancel()
        interruptionRecoveryWorkItem = nil
        let hadActiveAudioConnection = audioDataConnectionActive || audioPreviewConnectionActive

        // Drain both delegate queues behind a disabled generation before
        // detaching or replacing outputs. Any late callback from the old graph
        // will therefore fail its queue-confined identity/delivery gate.
        resetSampleStatistics(
            generation: generation,
            videoDeliveryEnabled: false,
            audioDeliveryEnabled: false
        )

        let oldSession = session
        let oldVideoOutput = videoOutput
        let oldAudioDataOutput = audioDataOutput
        let oldAudioPreviewOutput = audioPreviewOutput
        oldVideoOutput.setSampleBufferDelegate(nil, queue: nil)
        oldAudioDataOutput.setSampleBufferDelegate(nil, queue: nil)
        oldAudioPreviewOutput.volume = 0
        if oldSession.isRunning {
            oldSession.stopRunning()
        }

        oldSession.beginConfiguration()
        oldSession.inputs.forEach(oldSession.removeInput)
        oldSession.outputs.forEach(oldSession.removeOutput)
        oldSession.commitConfiguration()

        activeDevice = nil
        resetAudioOutputState()
        if hadActiveAudioConnection {
            publish(audioAvailability: .unavailable)
        }

        // A USB detach/resume can poison the underlying iOSScreenCapture DAL
        // graph even though stop/start succeeds. A brand-new session and output
        // force AVFoundation/CoreMediaIO to create a new graph instead of
        // reusing the stale decoder/IPC chain.
        session = AVCaptureSession()
        videoOutput = AVCaptureVideoDataOutput()
        audioDataOutput = AVCaptureAudioDataOutput()
        audioPreviewOutput = AVCaptureAudioPreviewOutput()
        configureOutputDelegates()
    }

    private func configureOutputDelegates() {
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sampleBufferQueue)
        audioDataOutput.setSampleBufferDelegate(self, queue: audioSampleBufferQueue)
    }

    private func scheduleRecovery(immediate: Bool = false) {
        guard desiredRunning else { return }

        retryWorkItem?.cancel()
        let attempt = recoveryAttempt
        recoveryAttempt = min(recoveryAttempt + 1, 8)
        let delay = immediate ? 0 : min(0.5 * pow(2, Double(attempt)), 5)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, desiredRunning else { return }
            transitionInProgress = false
            discoverAndStart()
        }
        retryWorkItem = workItem
        sessionQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func beginGeneration() -> Int {
        generation &+= 1
        firstFrameSeenGeneration = 0
        resetAudioConnectionState()
        // Audio is enabled only after the data connection has been validated.
        // Video can begin immediately when the session starts.
        resetSampleStatistics(
            generation: generation,
            videoDeliveryEnabled: true,
            audioDeliveryEnabled: false
        )
        return generation
    }

    private func invalidateGeneration() {
        firstFrameTimeoutWorkItem?.cancel()
        firstFrameTimeoutWorkItem = nil
        frameWatchdogWorkItem?.cancel()
        frameWatchdogWorkItem = nil
        generation &+= 1
        firstFrameSeenGeneration = 0
        let hadActiveAudioConnection = audioDataConnectionActive || audioPreviewConnectionActive
        resetAudioConnectionState()
        resetSampleStatistics(
            generation: generation,
            videoDeliveryEnabled: false,
            audioDeliveryEnabled: false
        )
        if hadActiveAudioConnection {
            publish(audioAvailability: .unavailable)
        }
    }

    private func scheduleFirstFrameTimeout(for expectedGeneration: Int) {
        firstFrameTimeoutWorkItem?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.desiredRunning,
                  self.generation == expectedGeneration,
                  self.firstFrameSeenGeneration != expectedGeneration
            else { return }

            self.transitionInProgress = false
            self.invalidateGeneration()
            self.tearDownSession()
            self.publish(
                state: .recovering,
                deviceName: nil,
                error: .firstFrameTimedOut,
                fps: 0
            )
            self.scheduleRecovery()
        }
        firstFrameTimeoutWorkItem = timeout
        sessionQueue.asyncAfter(deadline: .now() + 4, execute: timeout)
    }

    private func noteFirstFrame(generation expectedGeneration: Int) {
        guard generation == expectedGeneration else { return }
        firstFrameSeenGeneration = expectedGeneration
        firstFrameTimeoutWorkItem?.cancel()
        firstFrameTimeoutWorkItem = nil
    }

    private func scheduleFrameWatchdog(for expectedGeneration: Int) {
        frameWatchdogWorkItem?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            self?.evaluateFrameWatchdog(for: expectedGeneration)
        }
        frameWatchdogWorkItem = watchdog
        sessionQueue.asyncAfter(deadline: .now() + .seconds(1), execute: watchdog)
    }

    private func evaluateFrameWatchdog(for expectedGeneration: Int) {
        guard desiredRunning, generation == expectedGeneration else { return }

        // The first-frame timeout owns startup. Once a generation has produced
        // a frame, this watchdog prevents stale running/FPS state if callbacks
        // silently stop without an AVFoundation error notification.
        guard firstFrameSeenGeneration == expectedGeneration else {
            scheduleFrameWatchdog(for: expectedGeneration)
            return
        }

        sampleLivenessLock.lock()
        let lastSample = lastSampleUptimeNanoseconds
        sampleLivenessLock.unlock()
        let now = DispatchTime.now().uptimeNanoseconds
        if lastSample > 0, now >= lastSample, now - lastSample > 3_000_000_000 {
            transitionInProgress = false
            invalidateGeneration()
            tearDownSession()
            publish(state: .recovering, deviceName: nil, error: .streamStalled, fps: 0)
            scheduleRecovery(immediate: true)
            return
        }
        scheduleFrameWatchdog(for: expectedGeneration)
    }

    private func scheduleInterruptionRecovery(for interruptedSession: AVCaptureSession) {
        interruptionRecoveryWorkItem?.cancel()
        let timeout = DispatchWorkItem { [weak self, weak interruptedSession] in
            guard let self, let interruptedSession,
                  self.desiredRunning,
                  interruptedSession === self.session else { return }
            self.transitionInProgress = false
            self.invalidateGeneration()
            self.tearDownSession()
            self.publish(state: .recovering, deviceName: nil, error: .streamStalled, fps: 0)
            self.scheduleRecovery(immediate: true)
        }
        interruptionRecoveryWorkItem = timeout
        sessionQueue.asyncAfter(deadline: .now() + .seconds(8), execute: timeout)
    }

    private func resetSampleStatistics(
        generation: Int,
        videoDeliveryEnabled: Bool,
        audioDeliveryEnabled: Bool
    ) {
        // Snapshot the mutable graph exclusively on sessionQueue, then install
        // those immutable identities on the queues that receive callbacks.
        let deliveryVideoOutput = videoDeliveryEnabled ? videoOutput : nil
        let deliveryAudioOutput = audioDeliveryEnabled && audioDataOutputConfigured
            ? audioDataOutput
            : nil
        let synchronizationClock = videoDeliveryEnabled || audioDeliveryEnabled
            ? session.synchronizationClock
            : nil

        let resetVideo = {
            self.sampleGeneration = generation
            self.sampleDeliveryEnabled = videoDeliveryEnabled
            self.sampleVideoOutput = deliveryVideoOutput
            self.sampleSynchronizationClock = videoDeliveryEnabled ? synchronizationClock : nil
            self.firstFrameReportedGeneration = generation &- 1
            self.fpsWindowStartSeconds = nil
            self.fpsWindowFrameCount = 0
            self.ageWindowLatestSeconds = nil
            self.ageWindowTotalSeconds = 0
            self.ageWindowMaximumSeconds = nil
            self.ageWindowSampleCount = 0
            self.sampleLivenessLock.lock()
            self.lastSampleUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            self.sampleLivenessLock.unlock()
        }
        if DispatchQueue.getSpecific(key: sampleQueueKey) != nil {
            resetVideo()
        } else {
            sampleBufferQueue.sync(execute: resetVideo)
        }

        let resetAudio = {
            self.audioSampleGeneration = generation
            self.audioSampleDeliveryEnabled = audioDeliveryEnabled && deliveryAudioOutput != nil
            self.sampleAudioOutput = deliveryAudioOutput
            self.audioSynchronizationClock = audioDeliveryEnabled ? synchronizationClock : nil
        }
        if DispatchQueue.getSpecific(key: audioSampleQueueKey) != nil {
            resetAudio()
        } else {
            audioSampleBufferQueue.sync(execute: resetAudio)
        }
    }

    private func updateAudioSampleGate(generation: Int, deliveryEnabled: Bool) {
        let deliveryAudioOutput = deliveryEnabled && audioDataOutputConfigured ? audioDataOutput : nil
        let synchronizationClock = deliveryEnabled ? session.synchronizationClock : nil
        let updateAudio = {
            self.audioSampleGeneration = generation
            self.audioSampleDeliveryEnabled = deliveryEnabled && deliveryAudioOutput != nil
            self.sampleAudioOutput = deliveryAudioOutput
            self.audioSynchronizationClock = synchronizationClock
        }
        if DispatchQueue.getSpecific(key: audioSampleQueueKey) != nil {
            updateAudio()
        } else {
            audioSampleBufferQueue.sync(execute: updateAudio)
        }
    }

    private func refreshSampleSynchronizationClock(for expectedGeneration: Int) {
        let synchronizationClock = session.synchronizationClock
        let updateVideo = {
            guard self.sampleGeneration == expectedGeneration,
                  self.sampleDeliveryEnabled else { return }
            self.sampleSynchronizationClock = synchronizationClock
        }
        if DispatchQueue.getSpecific(key: sampleQueueKey) != nil {
            updateVideo()
        } else {
            sampleBufferQueue.sync(execute: updateVideo)
        }

        let updateAudio = {
            guard self.audioSampleGeneration == expectedGeneration,
                  self.audioSampleDeliveryEnabled else { return }
            self.audioSynchronizationClock = synchronizationClock
        }
        if DispatchQueue.getSpecific(key: audioSampleQueueKey) != nil {
            updateAudio()
        } else {
            audioSampleBufferQueue.sync(execute: updateAudio)
        }
    }

    private func publish(
        state newState: State,
        deviceName newDeviceName: String?,
        error: CaptureError?,
        fps newFPS: Double,
        generation newGeneration: Int? = nil
    ) {
        let generationToPublish = newGeneration ?? generation
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let newGeneration {
                publishedGeneration = newGeneration
            } else if newState != .running {
                publishedGeneration = generationToPublish
            }
            state = newState
            deviceName = newDeviceName
            lastError = error
            fps = newFPS
            frameAgeMetrics = .empty
            onStateChange?(newState)
            onFPSChange?(newFPS)
            onFrameAgeChange?(.empty)
        }
    }

    private func publish(audioAvailability newAvailability: AudioAvailability) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            audioAvailability = newAvailability
            onAudioAvailabilityChange?(newAvailability)
        }
    }

    private func publishStatistics(
        fps newFPS: Double,
        frameAge newFrameAge: FrameAgeMetrics,
        generation: Int
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self, publishedGeneration == generation, state == .running else { return }
            fps = newFPS
            frameAgeMetrics = newFrameAge
            onFPSChange?(newFPS)
            onFrameAgeChange?(newFrameAge)
        }
    }

    private func currentSampleBufferConsumers() -> (SampleBufferHandler?, [SampleBufferHandler]) {
        sampleHandlerLock.lock()
        defer { sampleHandlerLock.unlock() }
        return (sampleBufferHandler, Array(sampleBufferObservers.values))
    }

    private func currentAudioSampleBufferObservers() -> [SampleBufferHandler] {
        audioObserverLock.lock()
        defer { audioObserverLock.unlock() }
        return Array(audioSampleBufferObservers.values)
    }

    private func sampleTiming(
        for sampleBuffer: CMSampleBuffer,
        hostArrivalTime: CMTime,
        synchronizationClock: CMClock?
    ) -> SampleTiming {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var presentationHostTime: CMTime?
        var arrivalAgeSeconds: Double?

        if CMTIME_IS_NUMERIC(presentationTime),
           let synchronizationClock {
            let converted = CMSyncConvertTime(
                presentationTime,
                from: synchronizationClock,
                to: CMClockGetHostTimeClock()
            )
            if CMTIME_IS_NUMERIC(converted) {
                let age = CMTimeGetSeconds(CMTimeSubtract(hostArrivalTime, converted))
                if age.isFinite {
                    presentationHostTime = converted
                    arrivalAgeSeconds = age
                }
            }
        }

        return SampleTiming(
            presentationTime: presentationTime,
            presentationHostTime: presentationHostTime,
            hostArrivalTime: hostArrivalTime,
            arrivalAgeSeconds: arrivalAgeSeconds
        )
    }

    private func installObservers() {
        let center = NotificationCenter.default

        observerTokens.append(center.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self, notification.object is AVCaptureDevice else { return }
            sessionQueue.async {
                guard self.desiredRunning, self.activeDevice == nil else { return }
                self.retryWorkItem?.cancel()
                self.retryWorkItem = nil
                self.recoveryAttempt = 0
                self.transitionInProgress = false
                self.discoverAndStart()
            }
        })

        observerTokens.append(center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self, let disconnectedDevice = notification.object as? AVCaptureDevice else { return }
            let disconnectedIdentity = ObjectIdentifier(disconnectedDevice)
            sessionQueue.async {
                guard self.desiredRunning,
                      let activeDevice = self.activeDevice,
                      ObjectIdentifier(activeDevice) == disconnectedIdentity
                else { return }
                self.transitionInProgress = false
                self.invalidateGeneration()
                self.tearDownSession()
                self.publish(state: .waitingForDevice, deviceName: nil, error: nil, fps: 0)
                self.scheduleRecovery()
            }
        })

        observerTokens.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self, let observedSession = notification.object as? AVCaptureSession else { return }
            let code = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.code ?? 0
            sessionQueue.async {
                guard self.desiredRunning, observedSession === self.session else { return }
                self.transitionInProgress = false
                self.invalidateGeneration()
                self.tearDownSession()
                self.publish(
                    state: .recovering,
                    deviceName: nil,
                    error: .runtimeError(code: code),
                    fps: 0
                )
                self.scheduleRecovery(immediate: true)
            }
        })

        observerTokens.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self, let observedSession = notification.object as? AVCaptureSession else { return }
            sessionQueue.async {
                guard self.desiredRunning, observedSession === self.session else { return }
                self.invalidateGeneration()
                self.publish(
                    state: .interrupted,
                    deviceName: self.activeDevice?.localizedName,
                    error: nil,
                    fps: 0
                )
                self.scheduleInterruptionRecovery(for: observedSession)
            }
        })

        observerTokens.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self, let observedSession = notification.object as? AVCaptureSession else { return }
            sessionQueue.async {
                guard self.desiredRunning, observedSession === self.session else { return }
                self.interruptionRecoveryWorkItem?.cancel()
                self.interruptionRecoveryWorkItem = nil
                if self.session.isRunning, let activeDevice = self.activeDevice {
                    let currentGeneration = self.beginGeneration()
                    self.refreshSampleSynchronizationClock(for: currentGeneration)
                    self.validateAudioOutputsAfterStart(generation: currentGeneration)
                    self.publish(
                        state: .running,
                        deviceName: activeDevice.localizedName,
                        error: nil,
                        fps: 0,
                        generation: currentGeneration
                    )
                    self.scheduleFirstFrameTimeout(for: currentGeneration)
                    self.scheduleFrameWatchdog(for: currentGeneration)
                } else {
                    self.transitionInProgress = false
                    self.scheduleRecovery(immediate: true)
                }
            }
        })
    }
}

extension USBScreenCapture: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if let callbackAudioOutput = output as? AVCaptureAudioDataOutput {
            guard audioSampleDeliveryEnabled,
                  audioSampleGeneration > 0,
                  callbackAudioOutput === sampleAudioOutput,
                  CMSampleBufferDataIsReady(sampleBuffer) else { return }
            let hostArrivalTime = CMClockGetTime(CMClockGetHostTimeClock())
            let timing = sampleTiming(
                for: sampleBuffer,
                hostArrivalTime: hostArrivalTime,
                synchronizationClock: audioSynchronizationClock
            )
            for observer in currentAudioSampleBufferObservers() {
                observer(sampleBuffer, timing)
            }
            return
        }

        guard let callbackVideoOutput = output as? AVCaptureVideoDataOutput,
              callbackVideoOutput === sampleVideoOutput else { return }
        guard sampleDeliveryEnabled, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        sampleLivenessLock.lock()
        lastSampleUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        sampleLivenessLock.unlock()

        // Measure before doing any statistics or display work. This isolates
        // latency accumulated by CMIO/AVCapture from latency introduced by a
        // preview layer after the callback.
        let hostArrivalTime = CMClockGetTime(CMClockGetHostTimeClock())
        let timing = sampleTiming(
            for: sampleBuffer,
            hostArrivalTime: hostArrivalTime,
            synchronizationClock: sampleSynchronizationClock
        )

        if firstFrameReportedGeneration != sampleGeneration {
            firstFrameReportedGeneration = sampleGeneration
            let currentGeneration = sampleGeneration
            sessionQueue.async { [weak self] in
                self?.noteFirstFrame(generation: currentGeneration)
            }
        }
        let (primaryConsumer, observers) = currentSampleBufferConsumers()
        primaryConsumer?(sampleBuffer, timing)
        for observer in observers {
            observer(sampleBuffer, timing)
        }

        if let age = timing.arrivalAgeSeconds {
            ageWindowLatestSeconds = age
            ageWindowTotalSeconds += age
            ageWindowMaximumSeconds = max(ageWindowMaximumSeconds ?? age, age)
            ageWindowSampleCount += 1
        }

        let hostSeconds = CMTimeGetSeconds(hostArrivalTime)
        guard hostSeconds.isFinite else { return }

        guard let windowStart = fpsWindowStartSeconds, hostSeconds >= windowStart else {
            fpsWindowStartSeconds = hostSeconds
            fpsWindowFrameCount = 1
            return
        }

        fpsWindowFrameCount += 1
        let elapsed = hostSeconds - windowStart
        guard elapsed >= 1 else { return }

        let measuredFPS = Double(max(0, fpsWindowFrameCount - 1)) / elapsed
        let currentGeneration = sampleGeneration
        let ageMetrics: FrameAgeMetrics
        if ageWindowSampleCount > 0, let latestAge = ageWindowLatestSeconds {
            ageMetrics = FrameAgeMetrics(
                latestSeconds: latestAge,
                averageSeconds: ageWindowTotalSeconds / Double(ageWindowSampleCount),
                maximumSeconds: ageWindowMaximumSeconds,
                sampleCount: ageWindowSampleCount
            )
        } else {
            ageMetrics = .empty
        }

        fpsWindowStartSeconds = hostSeconds
        fpsWindowFrameCount = 1
        ageWindowLatestSeconds = nil
        ageWindowTotalSeconds = 0
        ageWindowMaximumSeconds = nil
        ageWindowSampleCount = 0

        if measuredFPS.isFinite {
            publishStatistics(
                fps: measuredFPS,
                frameAge: ageMetrics,
                generation: currentGeneration
            )
        }
    }
}
