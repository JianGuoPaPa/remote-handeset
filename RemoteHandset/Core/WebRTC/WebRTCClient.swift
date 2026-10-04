import AVFoundation
import Foundation
import WebRTC

final class WebRTCClient: NSObject {
    enum ClientError: LocalizedError {
        case peerConnectionUnavailable
        case failedToCreateOffer
        case dataChannelsUnavailable
        case invalidRemoteDescription
        case localAudioUnavailable
        case audioSessionActivationFailed
        case audioSessionRecoveryFailed

        var errorDescription: String? {
            switch self {
            case .peerConnectionUnavailable:
                return "无法创建 WebRTC 连接"
            case .failedToCreateOffer:
                return "无法生成远程会话"
            case .dataChannelsUnavailable:
                return "控制通道尚未连接"
            case .invalidRemoteDescription:
                return "远端会话信息无效"
            case .localAudioUnavailable:
                return "无法创建音频输入通道"
            case .audioSessionActivationFailed:
                return "无法启动音频会话"
            case .audioSessionRecoveryFailed:
                return "音频会话无法恢复"
            }
        }
    }

    enum ConnectionState: Equatable {
        case new
        case checking
        case connected
        case disconnected
        case failed
        case closed
    }

    enum SendResult: Equatable {
        case sent
        case droppedForBackpressure
        case channelUnavailable
    }

    var onConnectionStateChange: ((ConnectionState) -> Void)?
    var onIceGatheringComplete: (() -> Void)?
    var onVideoTrack: ((RTCVideoTrack) -> Void)?
    var onVideoSizeChange: ((CGSize) -> Void)?
    var onVideoFrameDecoded: ((UInt64) -> Void)?
    var onFirstFramesReady: (() -> Void)?
    var onControlFeedback: ((Data) -> Void)?
    var onDataChannelsReady: (() -> Void)?
    var onDataChannelsUnavailable: (() -> Void)?
    var onMicrophoneFeedback: ((Data) -> Void)?
    var onMicrophoneChannelsReadyChange: ((Bool) -> Void)?
    var onAudioSessionRecoveryFailure: ((ClientError) -> Void)?

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitFieldTrialDictionary([
            "WebRTC-ZeroPlayoutDelay": "min_pacing:3ms,max_decode_queue_size:2"
        ])
        RTCInitializeSSL()
        // WebRTC's iOS audio unit is a VoiceProcessingIO unit that REQUIRES the
        // playAndRecord category - forcing plain .playback silently breaks
        // rendering. The same unit supplies echo-cancelled microphone audio when
        // a remote demand temporarily attaches the pre-created local track.
        // Follow the system's chosen output. .allowBluetoothA2DP routes media to
        // Bluetooth headphones, .allowAirPlay to AirPlay; .defaultToSpeaker only
        // kicks in when nothing external is connected (so it falls back to the
        // speaker, not the earpiece). Do NOT force the output port to the
        // speaker - that overrides a connected Bluetooth route.
        let audioConfiguration = RTCAudioSessionConfiguration.webRTC()
        audioConfiguration.category = AVAudioSession.Category.playAndRecord.rawValue
        audioConfiguration.categoryOptions = [
            .defaultToSpeaker,
            .allowBluetoothHFP,
            .allowBluetoothA2DP,
            .allowAirPlay
        ]
        audioConfiguration.mode = AVAudioSession.Mode.videoChat.rawValue
        RTCAudioSessionConfiguration.setWebRTC(audioConfiguration)
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    private var peerConnection: RTCPeerConnection?
    private(set) var orderedChannel: RTCDataChannel?
    private(set) var unorderedChannel: RTCDataChannel?
    private(set) var transientChannel: RTCDataChannel?
    private(set) var microphoneControlChannel: RTCDataChannel?
    private(set) var microphoneDataChannel: RTCDataChannel?
    private var microphoneSender: RTCRtpSender?
    private var localMicrophoneSource: RTCAudioSource?
    private var localMicrophoneTrack: RTCAudioTrack?
    private let iceWaitLock = NSLock()
    private var iceContinuation: CheckedContinuation<Void, Never>?
    private var iceTimeoutWorkItem: DispatchWorkItem?
    private var channelReadyReported = false
    private var microphoneChannelReadyReported = false
    private let remoteAudioStateQueue = DispatchQueue(
        label: "com.dltengwen.remotehandset.remote-audio-state",
        qos: .userInteractive
    )
    private var observedVideoTrack: RTCVideoTrack?
    private var observedAudioTrack: RTCAudioTrack?
    private var remoteAudioMuted = false
    private var systemOutputVolume = AVAudioSession.sharedInstance().outputVolume
    private var systemOutputRouteKey = ""
    private var systemOutputVolumeFloor: Float = 0
    private var isAudioSessionDelegateRegistered = false
    // Accessed only while RTCAudioSession's configuration lock is held.
    private var ownsAudioSessionActivation = false

    private static let calibratedVoiceOutputFloors: [String: Float] = [
        AVAudioSession.Port.builtInSpeaker.rawValue: 1.0 / 16.0,
        AVAudioSession.Port.builtInReceiver.rawValue: 1.0 / 16.0,
        AVAudioSession.Port.bluetoothHFP.rawValue: 1.0 / 16.0
    ]

    var microphoneChannelsReady: Bool {
        microphoneControlChannel?.readyState == .open
    }
    private lazy var frameReadinessRenderer = FrameReadinessRenderer(
        onReady: { [weak self] in
            self?.onFirstFramesReady?()
        },
        onSize: { [weak self] size in
            self?.onVideoSizeChange?(size)
        },
        onFrame: { [weak self] decodedAt in
            self?.onVideoFrameDecoded?(decodedAt)
        }
    )

    deinit {
        releaseAudioSessionActivation()
    }

    func prepare(
        iceServers: [IceServerPayload],
        relayOnly: Bool = true,
        supportsMicrophoneSending: Bool = false,
        initialRemoteAudioMuted: Bool = false
    ) throws {
        close()
        configureInitialRemoteAudioState(muted: initialRemoteAudioMuted)
        registerAudioSessionDelegate()
        var preparationSucceeded = false
        defer {
            if !preparationSucceeded {
                close()
            }
        }

        try activateAudioSession(isRecovery: false)

        let configuration = RTCConfiguration()
        configuration.iceServers = iceServers.map {
            RTCIceServer(
                urlStrings: $0.urls,
                username: $0.username,
                credential: $0.credential
            )
        }
        configuration.iceTransportPolicy = relayOnly ? .relay : .all
        // The current gateway exchanges one complete SDP and does not support
        // trickle ICE, so gathering must be allowed to finish.
        configuration.continualGatheringPolicy = .gatherOnce
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.iceCandidatePoolSize = 1
        configuration.shouldPruneTurnPorts = false
        configuration.shouldPresumeWritableWhenFullyRelayed = true
        configuration.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: [
                "DtlsSrtpKeyAgreement": "true"
            ]
        )

        guard let peerConnection = Self.factory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: self
        ) else {
            throw ClientError.peerConnectionUnavailable
        }
        self.peerConnection = peerConnection

        let receiveOnly = RTCRtpTransceiverInit()
        receiveOnly.direction = .recvOnly
        peerConnection.addTransceiver(of: .video, init: receiveOnly)

        let audioTransceiverConfiguration = RTCRtpTransceiverInit()
        audioTransceiverConfiguration.direction = supportsMicrophoneSending
            ? .sendRecv
            : .recvOnly
        guard let audioTransceiver = peerConnection.addTransceiver(
            of: .audio,
            init: audioTransceiverConfiguration
        ) else {
            throw ClientError.localAudioUnavailable
        }
        if supportsMicrophoneSending {
            let localSource = Self.factory.audioSource(with: nil)
            let localTrack = Self.factory.audioTrack(
                with: localSource,
                trackId: "remote-handset-microphone"
            )
            localTrack.isEnabled = false
            audioTransceiver.sender.track = nil
            microphoneSender = audioTransceiver.sender
            localMicrophoneSource = localSource
            localMicrophoneTrack = localTrack
        }

        let orderedConfig = RTCDataChannelConfiguration()
        orderedConfig.isOrdered = true
        orderedChannel = peerConnection.dataChannel(
            forLabel: "control-ordered",
            configuration: orderedConfig
        )

        let unorderedConfig = RTCDataChannelConfiguration()
        unorderedConfig.isOrdered = false
        unorderedChannel = peerConnection.dataChannel(
            forLabel: "control-unordered",
            configuration: unorderedConfig
        )

        let transientConfig = RTCDataChannelConfiguration()
        transientConfig.isOrdered = false
        transientConfig.maxRetransmits = 0
        transientChannel = peerConnection.dataChannel(
            forLabel: "control-transient",
            configuration: transientConfig
        )

        // Critical START/STOP packets must be reliable and ordered. PCM packets
        // are intentionally placed on a separate no-retransmit channel so old
        // speech can never build a latency queue behind packet loss.
        let microphoneControlConfig = RTCDataChannelConfiguration()
        microphoneControlConfig.isOrdered = true
        microphoneControlChannel = peerConnection.dataChannel(
            forLabel: "microphone-control",
            configuration: microphoneControlConfig
        )

        let microphoneDataConfig = RTCDataChannelConfiguration()
        // The Console validates monotonically increasing IUMC sequences. Keep
        // delivery ordered while still disabling retransmission, so a loss is
        // skipped without allowing later PCM packets to overtake one another.
        microphoneDataConfig.isOrdered = true
        microphoneDataConfig.maxRetransmits = 0
        microphoneDataChannel = peerConnection.dataChannel(
            forLabel: "microphone-data",
            configuration: microphoneDataConfig
        )

        guard orderedChannel != nil,
              unorderedChannel != nil,
              transientChannel != nil,
              microphoneControlChannel != nil,
              microphoneDataChannel != nil else {
            throw ClientError.dataChannelsUnavailable
        }

        orderedChannel?.delegate = self
        unorderedChannel?.delegate = self
        transientChannel?.delegate = self
        microphoneControlChannel?.delegate = self
        microphoneDataChannel?.delegate = self
        preparationSucceeded = true
    }

    func createOfferWaitingForIce() async throws -> String {
        guard let peerConnection else {
            throw ClientError.peerConnectionUnavailable
        }

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveVideo": "true",
                "OfferToReceiveAudio": "true"
            ],
            optionalConstraints: nil
        )

        let offer = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            peerConnection.offer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: ClientError.failedToCreateOffer)
                }
            }
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setLocalDescription(offer) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        if peerConnection.iceGatheringState != .complete {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Void, Never>) in
                iceWaitLock.lock()
                iceContinuation = continuation
                let timeoutWorkItem = DispatchWorkItem { [weak self] in
                    self?.finishWaitingForIce()
                }
                iceTimeoutWorkItem = timeoutWorkItem
                iceWaitLock.unlock()

                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + 10,
                    execute: timeoutWorkItem
                )

                if peerConnection.iceGatheringState == .complete {
                    finishWaitingForIce()
                }
            }
        }

        guard let local = peerConnection.localDescription else {
            throw ClientError.failedToCreateOffer
        }
        return local.sdp
    }

    func setRemoteAnswer(_ sdp: String) async throws {
        guard let peerConnection else {
            throw ClientError.peerConnectionUnavailable
        }
        guard !sdp.isEmpty else {
            throw ClientError.invalidRemoteDescription
        }

        let normalized = sdp
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        let answer = RTCSessionDescription(type: .answer, sdp: normalized)

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(answer) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    @discardableResult
    func sendOrdered(
        _ data: Data,
        maximumBufferedAmount: UInt64? = nil
    ) -> SendResult {
        guard let orderedChannel, orderedChannel.readyState == .open else {
            return .channelUnavailable
        }
        if let maximumBufferedAmount,
           orderedChannel.bufferedAmount > maximumBufferedAmount {
            return .droppedForBackpressure
        }
        return orderedChannel.sendData(
            RTCDataBuffer(data: data, isBinary: true)
        ) ? .sent : .channelUnavailable
    }

    @discardableResult
    func sendTransient(_ data: Data) -> SendResult {
        guard let transientChannel, transientChannel.readyState == .open else {
            return .channelUnavailable
        }
        guard transientChannel.bufferedAmount
                <= AppConfiguration.transientChannelHighWaterMark
        else {
            return .droppedForBackpressure
        }
        return transientChannel.sendData(
            RTCDataBuffer(data: data, isBinary: true)
        ) ? .sent : .channelUnavailable
    }

    @discardableResult
    func sendMicrophoneControl(_ data: Data) -> SendResult {
        sendMicrophoneControl(data, isBinary: true)
    }

    @discardableResult
    func sendMicrophoneControlJSON(_ data: Data) -> SendResult {
        sendMicrophoneControl(data, isBinary: false)
    }

    private func sendMicrophoneControl(
        _ data: Data,
        isBinary: Bool
    ) -> SendResult {
        guard let microphoneControlChannel,
              microphoneControlChannel.readyState == .open else {
            return .channelUnavailable
        }
        guard microphoneControlChannel.bufferedAmount <= 64 * 1_024 else {
            return .droppedForBackpressure
        }
        return microphoneControlChannel.sendData(
            RTCDataBuffer(data: data, isBinary: isBinary)
        ) ? .sent : .channelUnavailable
    }

    @discardableResult
    func sendMicrophoneData(_ data: Data) -> SendResult {
        guard let microphoneDataChannel,
              microphoneDataChannel.readyState == .open else {
            return .channelUnavailable
        }
        // Retained for legacy IUMC clients. Two 20 ms packets are the normal
        // soft ceiling; stale speech is dropped rather than queued.
        guard microphoneDataChannel.bufferedAmount < 3_896 else {
            return .droppedForBackpressure
        }
        return microphoneDataChannel.sendData(
            RTCDataBuffer(data: data, isBinary: true)
        ) ? .sent : .channelUnavailable
    }

    func setRemoteAudioMuted(_ muted: Bool) {
        remoteAudioStateQueue.sync {
            remoteAudioMuted = muted
            applyRemoteAudioGainLocked()
        }
    }

    /// Attaches the WebRTC-native microphone source to the already-negotiated
    /// send/receive audio transceiver. Keeping the sender track nil at rest
    /// prevents the application from publishing microphone audio without a
    /// current, generation-bound demand from the remote device.
    @discardableResult
    func setLocalMicrophoneSending(_ enabled: Bool) -> Bool {
        guard let microphoneSender else { return !enabled }
        if enabled {
            guard let localMicrophoneTrack else { return false }
            localMicrophoneTrack.isEnabled = true
            microphoneSender.track = localMicrophoneTrack
            return microphoneSender.track != nil
        }
        microphoneSender.track = nil
        localMicrophoneTrack?.isEnabled = false
        return microphoneSender.track == nil
    }

    func statistics() async -> RTCStatisticsReport? {
        guard let peerConnection else { return nil }
        return await withCheckedContinuation { continuation in
            peerConnection.statistics { report in
                continuation.resume(returning: report)
            }
        }
    }

    func armDecodedFrameConfirmation() {
        frameReadinessRenderer.armFrameCallback()
    }

    func close() {
        finishWaitingForIce()
        _ = setLocalMicrophoneSending(false)
        orderedChannel?.delegate = nil
        unorderedChannel?.delegate = nil
        transientChannel?.delegate = nil
        microphoneControlChannel?.delegate = nil
        microphoneDataChannel?.delegate = nil
        orderedChannel?.close()
        unorderedChannel?.close()
        transientChannel?.close()
        microphoneControlChannel?.close()
        microphoneDataChannel?.close()
        orderedChannel = nil
        unorderedChannel = nil
        transientChannel = nil
        microphoneControlChannel = nil
        microphoneDataChannel = nil
        microphoneSender = nil
        localMicrophoneTrack = nil
        localMicrophoneSource = nil
        observedVideoTrack?.remove(frameReadinessRenderer)
        observedVideoTrack = nil
        remoteAudioStateQueue.sync {
            observedAudioTrack = nil
            remoteAudioMuted = false
        }
        frameReadinessRenderer.reset()
        peerConnection?.close()
        peerConnection = nil
        releaseAudioSessionActivation()
        unregisterAudioSessionDelegate()
        channelReadyReported = false
        microphoneChannelReadyReported = false
    }

    func detachCallbacks() {
        onConnectionStateChange = nil
        onIceGatheringComplete = nil
        onVideoTrack = nil
        onVideoSizeChange = nil
        onVideoFrameDecoded = nil
        onFirstFramesReady = nil
        onControlFeedback = nil
        onDataChannelsReady = nil
        onDataChannelsUnavailable = nil
        onMicrophoneFeedback = nil
        onMicrophoneChannelsReadyChange = nil
        onAudioSessionRecoveryFailure = nil
    }

    private func reportChannelReadinessIfNeeded() {
        let allChannelsOpen =
            orderedChannel?.readyState == .open
            && unorderedChannel?.readyState == .open
            && transientChannel?.readyState == .open

        if channelReadyReported, !allChannelsOpen {
            channelReadyReported = false
            onDataChannelsUnavailable?()
            return
        }

        guard !channelReadyReported, allChannelsOpen else {
            return
        }
        channelReadyReported = true
        onDataChannelsReady?()

        reportMicrophoneChannelReadinessIfNeeded()
    }

    private func reportMicrophoneChannelReadinessIfNeeded() {
        let isReady = microphoneChannelsReady
        guard isReady != microphoneChannelReadyReported else { return }
        microphoneChannelReadyReported = isReady
        onMicrophoneChannelsReadyChange?(isReady)
    }

    private func reportVideoTrack(_ track: RTCVideoTrack) {
        if observedVideoTrack !== track {
            observedVideoTrack?.remove(frameReadinessRenderer)
            observedVideoTrack = track
            frameReadinessRenderer.reset()
            track.add(frameReadinessRenderer)
        }
        onVideoTrack?(track)
    }

    private func reportAudioTrack(_ track: RTCAudioTrack) {
        // Hold a strong reference: an unretained remote audio track can be
        // released and stop feeding the speaker. The prebuilt WebRTC audio
        // device renders through VoiceProcessingIO, whose communication-volume
        // path may not attenuate received audio to silence. Mirror the user's
        // system output volume into the remote source gain as well, so volume
        // zero is an unconditional digital mute before the audio reaches the
        // output route.
        remoteAudioStateQueue.sync {
            observedAudioTrack = track
            applyRemoteAudioGainLocked()
        }
    }

    private func registerAudioSessionDelegate() {
        guard !isAudioSessionDelegateRegistered else { return }
        let session = RTCAudioSession.sharedInstance()
        session.add(self)
        isAudioSessionDelegateRegistered = true
        refreshRemoteAudioRoute(using: session)
    }

    private func unregisterAudioSessionDelegate() {
        guard isAudioSessionDelegateRegistered else { return }
        RTCAudioSession.sharedInstance().remove(self)
        isAudioSessionDelegateRegistered = false
    }

    private func updateSystemOutputVolume(_ outputVolume: Float) {
        let clampedVolume = min(max(outputVolume, 0), 1)
        remoteAudioStateQueue.sync {
            systemOutputVolume = clampedVolume
            applyRemoteAudioGainLocked()
        }
    }

    private func applyRemoteAudioGainLocked() {
        guard let track = observedAudioTrack else { return }
        let gain = Self.remoteAudioGain(
            systemOutputVolume: systemOutputVolume,
            floor: systemOutputVolumeFloor,
            muted: remoteAudioMuted
        )
        // Keeping the renderer alive avoids an audio-unit teardown/restart and
        // preserves continuous downlink playback during full-duplex capture.
        track.isEnabled = true
        track.source.volume = gain
    }

    private static func remoteAudioGain(
        systemOutputVolume: Float,
        floor: Float,
        muted: Bool
    ) -> Double {
        guard !muted else { return 0 }
        let clampedVolume = min(max(systemOutputVolume, 0), 1)
        let clampedFloor = min(max(floor, 0), 0.99)
        guard clampedVolume > clampedFloor + 0.000_1 else { return 0 }
        return Double(
            (clampedVolume - clampedFloor) / (1 - clampedFloor)
        )
    }

    private func configureInitialRemoteAudioState(muted: Bool) {
        let session = RTCAudioSession.sharedInstance()
        let route = Self.remoteAudioRouteSnapshot(session.currentRoute.outputs)
        let outputVolume = min(max(session.outputVolume, 0), 1)
        remoteAudioStateQueue.sync {
            remoteAudioMuted = muted
            systemOutputVolume = outputVolume
            systemOutputRouteKey = route.key
            systemOutputVolumeFloor = route.floor
            applyRemoteAudioGainLocked()
        }
    }

    private func refreshRemoteAudioRoute(using session: RTCAudioSession) {
        let route = Self.remoteAudioRouteSnapshot(session.currentRoute.outputs)
        let outputVolume = min(max(session.outputVolume, 0), 1)
        remoteAudioStateQueue.sync {
            systemOutputVolume = outputVolume
            if systemOutputRouteKey != route.key {
                systemOutputRouteKey = route.key
                systemOutputVolumeFloor = route.floor
            }
            applyRemoteAudioGainLocked()
        }
    }

    private static func remoteAudioRouteSnapshot(
        _ outputs: [AVAudioSessionPortDescription]
    ) -> (key: String, floor: Float) {
        let routeParts = outputs.map { output in
            "\(output.portType.rawValue)|\(output.uid)"
        }
        let floor = outputs.compactMap { output in
            calibratedVoiceOutputFloors[output.portType.rawValue]
        }.max() ?? 0
        return (routeParts.joined(separator: ","), floor)
    }

    private func activateAudioSession(isRecovery: Bool) throws {
        let session = RTCAudioSession.sharedInstance()
        var activationError: ClientError?
        session.lockForConfiguration()
        do {
            try session.setCategory(
                .playAndRecord,
                with: [
                    .defaultToSpeaker,
                    .allowBluetoothHFP,
                    .allowBluetoothA2DP,
                    .allowAirPlay
                ]
            )
            try session.setMode(.videoChat)
            // No manual overrideOutputAudioPort: .defaultToSpeaker in the
            // category options already routes to the speaker only when nothing
            // external is attached, and follows Bluetooth/headphones/AirPlay
            // when they are - dynamically, including mid-session plug/unplug.
            if !ownsAudioSessionActivation {
                try session.setActive(true)
                ownsAudioSessionActivation = true
            } else if !session.isActive {
                throw isRecovery
                    ? ClientError.audioSessionRecoveryFailed
                    : ClientError.audioSessionActivationFailed
            }
        } catch {
            activationError = isRecovery
                ? .audioSessionRecoveryFailed
                : .audioSessionActivationFailed
        }
        session.unlockForConfiguration()
        if let activationError {
            throw activationError
        }
        refreshRemoteAudioRoute(using: session)
    }

    private func releaseAudioSessionActivation() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        if ownsAudioSessionActivation {
            // RTCAudioSession balances its activation counter for every
            // setActive(false) attempt, including a failed AVAudioSession
            // deactivation. Clear our ownership exactly once so close/deinit
            // cannot issue a second, unbalanced release after an error.
            ownsAudioSessionActivation = false
            do {
                try session.setActive(false)
            } catch {
                // The WebRTC activation reference has still been balanced.
                // A subsequent connection will perform a fresh activation.
            }
        }
        session.unlockForConfiguration()
    }

    private func recoverAudioSession() {
        do {
            try activateAudioSession(isRecovery: true)
        } catch {
            onAudioSessionRecoveryFailure?(.audioSessionRecoveryFailed)
        }
    }

    private func finishWaitingForIce() {
        iceWaitLock.lock()
        let continuation = iceContinuation
        let timeoutWorkItem = iceTimeoutWorkItem
        iceContinuation = nil
        iceTimeoutWorkItem = nil
        iceWaitLock.unlock()

        timeoutWorkItem?.cancel()
        continuation?.resume()
    }
}

extension WebRTCClient: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let track = stream.videoTracks.first {
            reportVideoTrack(track)
        }
        if let track = stream.audioTracks.first {
            reportAudioTrack(track)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete {
            finishWaitingForIce()
            onIceGatheringComplete?()
        }
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didGenerate candidate: RTCIceCandidate
    ) {
        let sdp = candidate.sdp
        let type: String
        if sdp.contains("typ relay") {
            type = "relay"
        } else if sdp.contains("typ srflx") {
            type = "srflx"
        } else if sdp.contains("typ host") {
            type = "host"
        } else {
            type = "other"
        }
        NSLog("RH_ICE candidate %@", type)
        // Relay-only session: the relay candidate is the only one we can use, so
        // stop waiting for full ICE gathering the instant it arrives. Full
        // gathering otherwise stalls ~15s on the STUN server the portal derives
        // from the TURN URL. A short grace lets the candidate land in the SDP.
        if type == "relay" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.finishWaitingForIce()
            }
        }
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove candidates: [RTCIceCandidate]
    ) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didOpen dataChannel: RTCDataChannel
    ) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCPeerConnectionState
    ) {
        let state: ConnectionState
        switch newState {
        case .new:
            state = .new
        case .connecting:
            state = .checking
        case .connected:
            state = .connected
        case .disconnected:
            state = .disconnected
        case .failed:
            state = .failed
        case .closed:
            state = .closed
        @unknown default:
            return
        }
        if newState == .connected {
            // Fallback: don't rely on the didAdd/didStartReceiving callback
            // timing. Once connected, sweep every receiver and wire up the audio
            // track directly. This is what actually starts playback if the
            // per-track delegate never fired for audio.
            let receivers = peerConnection.receivers
            for receiver in receivers {
                if let track = receiver.track as? RTCAudioTrack {
                    reportAudioTrack(track)
                }
            }
        }
        onConnectionStateChange?(state)
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        if let track = rtpReceiver.track as? RTCVideoTrack {
            reportVideoTrack(track)
        }
        if let track = rtpReceiver.track as? RTCAudioTrack {
            reportAudioTrack(track)
        }
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didStartReceivingOn transceiver: RTCRtpTransceiver
    ) {
        if let track = transceiver.receiver.track as? RTCVideoTrack {
            reportVideoTrack(track)
        }
        if let track = transceiver.receiver.track as? RTCAudioTrack {
            reportAudioTrack(track)
        }
    }
}

extension WebRTCClient: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        reportChannelReadinessIfNeeded()
        if dataChannel === microphoneControlChannel
            || dataChannel === microphoneDataChannel {
            reportMicrophoneChannelReadinessIfNeeded()
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        if dataChannel === unorderedChannel {
            onControlFeedback?(buffer.data)
        } else if dataChannel === microphoneControlChannel {
            onMicrophoneFeedback?(buffer.data)
        }
    }
}

extension WebRTCClient: RTCAudioSessionDelegate {
    func audioSession(
        _ audioSession: RTCAudioSession,
        didChangeOutputVolume outputVolume: Float
    ) {
        updateSystemOutputVolume(outputVolume)
    }

    func audioSessionDidChangeRoute(
        _ audioSession: RTCAudioSession,
        reason: AVAudioSession.RouteChangeReason,
        previousRoute: AVAudioSessionRouteDescription
    ) {
        refreshRemoteAudioRoute(using: audioSession)
    }

    func audioSessionDidEndInterruption(
        _ audioSession: RTCAudioSession,
        shouldResumeSession: Bool
    ) {
        guard shouldResumeSession else { return }
        recoverAudioSession()
    }

    func audioSessionMediaServerReset(_ audioSession: RTCAudioSession) {
        recoverAudioSession()
    }
}

private final class FrameReadinessRenderer: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private let onReady: () -> Void
    private let onSize: (CGSize) -> Void
    private let onFrame: (UInt64) -> Void
    private var frameCount = 0
    private var hasReported = false
    private var lastSize = CGSize.zero
    private var isFrameCallbackArmed = false

    init(
        onReady: @escaping () -> Void,
        onSize: @escaping (CGSize) -> Void,
        onFrame: @escaping (UInt64) -> Void
    ) {
        self.onReady = onReady
        self.onSize = onSize
        self.onFrame = onFrame
    }

    func setSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        lock.lock()
        let changed = size != lastSize
        if changed {
            lastSize = size
        }
        lock.unlock()

        if changed {
            onSize(size)
        }
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard frame != nil else { return }
        lock.lock()
        frameCount += 1
        let shouldReport = frameCount >= 3 && !hasReported
        if shouldReport {
            hasReported = true
        }
        let shouldReportFrame = isFrameCallbackArmed
        if shouldReportFrame {
            isFrameCallbackArmed = false
        }
        lock.unlock()

        if shouldReport {
            onReady()
        }
        if shouldReportFrame {
            onFrame(DispatchTime.now().uptimeNanoseconds / 1_000)
        }
    }

    func armFrameCallback() {
        lock.lock()
        isFrameCallbackArmed = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        frameCount = 0
        hasReported = false
        lastSize = .zero
        isFrameCallbackArmed = false
        lock.unlock()
    }
}
