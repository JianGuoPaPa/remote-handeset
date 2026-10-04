import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

final class WebConsoleRuntime: @unchecked Sendable {
    let auth: WebAuthStore
    let loginGate: WebLoginGate
    let status: WebConsoleStatusStore
    let inputClient: RFBInputClient
    let encoder: H264VideoEncoder
    let videoHub: WebVideoHub
    let audioEncoder: OpusAudioEncoder
    let audioHub: WebAudioHub
    let pcmAudioHub: WebAudioHub
    let microphoneCoordinator: MicrophoneInputCoordinator
    let controllers: WebControllerChannelRegistry
    let resourcesRoot: URL

    init(
        auth: WebAuthStore,
        status: WebConsoleStatusStore,
        inputClient: RFBInputClient,
        encoder: H264VideoEncoder,
        videoHub: WebVideoHub,
        audioEncoder: OpusAudioEncoder,
        audioHub: WebAudioHub,
        pcmAudioHub: WebAudioHub,
        microphoneCoordinator: MicrophoneInputCoordinator,
        controllers: WebControllerChannelRegistry,
        resourcesRoot: URL
    ) {
        self.auth = auth
        loginGate = WebLoginGate(auth: auth)
        self.status = status
        self.inputClient = inputClient
        self.encoder = encoder
        self.videoHub = videoHub
        self.audioEncoder = audioEncoder
        self.audioHub = audioHub
        self.pcmAudioHub = pcmAudioHub
        self.microphoneCoordinator = microphoneCoordinator
        self.controllers = controllers
        self.resourcesRoot = resourcesRoot
    }

    func shouldUpgrade(channel: Channel, request: HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?> {
        let token = WebRequestSecurity.sessionToken(from: request.headers)
        let normalOrigin = WebRequestSecurity.validHostAndOrigin(
            headers: request.headers,
            requireOrigin: true
        )
        let bridgeOrigin = auth.isBridgeSession(token: token) &&
            WebRequestSecurity.validLoopbackBridgeRequest(
                remoteAddress: channel.remoteAddress?.description,
                headers: request.headers,
                requireHTTPSOrigin: true
            )
        guard request.method == .GET,
              request.uri == "/ws/video" || request.uri == "/ws/audio" ||
                request.uri == "/ws/audio-pcm" || request.uri == "/ws/control",
              normalOrigin || bridgeOrigin,
              auth.validate(token: token, touch: false) != nil else {
            return channel.eventLoop.makeSucceededFuture(nil)
        }
        return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
    }

    func installWebSocketPipeline(channel: Channel, request: HTTPRequestHead) -> EventLoopFuture<Void> {
        let token = WebRequestSecurity.sessionToken(from: request.headers)
        let normalOrigin = WebRequestSecurity.validHostAndOrigin(
            headers: request.headers,
            requireOrigin: true
        )
        let bridgeOrigin = auth.isBridgeSession(token: token) &&
            WebRequestSecurity.validLoopbackBridgeRequest(
                remoteAddress: channel.remoteAddress?.description,
                headers: request.headers,
                requireHTTPSOrigin: true
            )
        guard normalOrigin || bridgeOrigin,
              let token,
              auth.validate(token: token, touch: false) != nil else {
            return channel.pipeline.addHandler(WebRejectedSocketHandler(
                code: "unauthorized",
                message: "会话已失效。",
                closeCode: 4401
            ))
        }

        switch request.uri {
        case "/ws/video":
            return channel.pipeline.addHandler(WebVideoSocketHandler(
                sessionToken: token,
                auth: auth,
                hub: videoHub
            ))
        case "/ws/audio":
            return channel.pipeline.addHandler(WebAudioSocketHandler(
                sessionToken: token,
                auth: auth,
                hub: audioHub
            ))
        case "/ws/audio-pcm":
            return channel.pipeline.addHandler(WebAudioSocketHandler(
                sessionToken: token,
                auth: auth,
                hub: pcmAudioHub
            ))
        case "/ws/control":
            let identifier = UUID().uuidString
            guard auth.acquireControllerLease(token: token, identifier: identifier) else {
                return channel.pipeline.addHandler(WebRejectedSocketHandler(
                    code: "controller_busy",
                    message: "已有一个网页控制会话正在使用输入通道。",
                    closeCode: 1008
                ))
            }
            return channel.pipeline.addHandler(WebControlSocketHandler(
                sessionToken: token,
                leaseIdentifier: identifier,
                auth: auth,
                status: status,
                inputClient: inputClient,
                microphoneCoordinator: microphoneCoordinator,
                controllers: controllers
            ))
        default:
            return channel.pipeline.addHandler(WebRejectedSocketHandler(
                code: "not_found",
                message: "WebSocket 端点不存在。",
                closeCode: 1008
            ))
        }
    }

    func expireSessions() {
        if let expiredController = auth.purgeExpired() {
            controllers.expire(identifier: expiredController.identifier)
            inputClient.releaseAllInputs()
        }
    }

    func shutdown() {
        _ = auth.removeAllSessions()
        controllers.closeAll()
        inputClient.releaseAllInputs()
        videoHub.closeAll()
        audioHub.closeAll()
        pcmAudioHub.closeAll()
    }
}

final class WebConsoleServer: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case stopped
        case starting
        case running
        case stopping
        case failed(String)
    }

    static let bindHost = "127.0.0.1"
    static let port = 18_765

    var onStateChange: ((State) -> Void)?

    var state: State {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedState
    }

    private let capture: USBScreenCapture
    private let inputClient: RFBInputClient
    private let microphoneCoordinator: MicrophoneInputCoordinator
    private let encoderConfiguration: VideoEncoderConfiguration
    private let audioBitRate: Int
    private let statusStore = WebConsoleStatusStore()
    private let stateLock = NSLock()
    private let lifecycleQueue = DispatchQueue(
        label: "local.iphone.usbconsole.web-server-lifecycle",
        qos: .userInitiated
    )

    private var storedState: State = .stopped
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var serverChannel: Channel?
    private var runtime: WebConsoleRuntime?
    private var captureObserverToken: UInt64?
    private var captureAudioObserverToken: UInt64?
    private var expiryTimer: DispatchSourceTimer?

    init(
        capture: USBScreenCapture,
        inputClient: RFBInputClient,
        microphoneCoordinator: MicrophoneInputCoordinator,
        encoderConfiguration: VideoEncoderConfiguration,
        audioBitRate: Int
    ) {
        self.capture = capture
        self.inputClient = inputClient
        self.microphoneCoordinator = microphoneCoordinator
        self.encoderConfiguration = encoderConfiguration
        self.audioBitRate = audioBitRate
    }

    deinit {
        stop()
    }

    func updateCaptureStatus(
        state: String,
        connected: Bool,
        fps: Double?,
        frameAgeMilliseconds: Double?,
        deviceName: String?
    ) {
        statusStore.updateCapture(
            state: state,
            connected: connected,
            fps: fps,
            frameAgeMilliseconds: frameAgeMilliseconds,
            deviceName: deviceName
        )
    }

    func updateControlStatus(
        state: String,
        connected: Bool,
        serverInfo: RFBInputClient.ServerInfo?
    ) {
        statusStore.updateControl(state: state, connected: connected, serverInfo: serverInfo)
    }

    func start(bridgeToken: String) {
        stateLock.lock()
        guard storedState == .stopped || {
            if case .failed = storedState { return true }
            return false
        }() else {
            stateLock.unlock()
            return
        }
        storedState = .starting
        stateLock.unlock()
        notifyState(.starting)

        lifecycleQueue.async { [weak self] in
            self?.performStart(bridgeToken: bridgeToken)
        }
    }

    func stop() {
        stateLock.lock()
        guard storedState != .stopped, storedState != .stopping else {
            stateLock.unlock()
            return
        }
        storedState = .stopping
        stateLock.unlock()
        notifyState(.stopping)

        lifecycleQueue.async { [weak self] in
            self?.performStop(finalState: .stopped)
        }
    }

    private func performStart(bridgeToken: String) {
        var provisionalGroup: MultiThreadedEventLoopGroup?
        var provisionalChannel: Channel?
        do {
            let bridgeVerifier = try BridgeTokenVerifier(token: bridgeToken)
            let auth = WebAuthStore(verifier: nil, bridgeVerifier: bridgeVerifier)
            guard let resourceRoot = Bundle.main.resourceURL?
                .appendingPathComponent("Web", isDirectory: true)
                .standardizedFileURL as URL?,
                  FileManager.default.fileExists(atPath: resourceRoot.appendingPathComponent("index.html").path)
            else {
                throw NSError(
                    domain: "WebConsoleServer",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "网页资源未包含在应用中"]
                )
            }

            let encoder = H264VideoEncoder(configuration: encoderConfiguration)
            let videoHub = WebVideoHub()
            let audioEncoder = OpusAudioEncoder(bitRate: audioBitRate)
            let audioViewerCapacity = WebAudioViewerCapacity()
            let audioHub = WebAudioHub(capacity: audioViewerCapacity)
            let pcmAudioHub = WebAudioHub(capacity: audioViewerCapacity)
            let controllers = WebControllerChannelRegistry()
            let runtime = WebConsoleRuntime(
                auth: auth,
                status: statusStore,
                inputClient: inputClient,
                encoder: encoder,
                videoHub: videoHub,
                audioEncoder: audioEncoder,
                audioHub: audioHub,
                pcmAudioHub: pcmAudioHub,
                microphoneCoordinator: microphoneCoordinator,
                controllers: controllers,
                resourcesRoot: resourceRoot
            )
            statusStore.onChange = { [weak controllers] status in
                controllers?.broadcast(status: status)
            }
            videoHub.requestKeyFrame = { [weak encoder] in
                encoder?.requestKeyFrame()
            }
            encoder.onConfiguration = { [weak videoHub] configuration in
                videoHub?.publish(configuration: configuration)
            }
            encoder.onAccessUnit = { [weak videoHub] accessUnit in
                videoHub?.publish(accessUnit: accessUnit)
            }
            audioEncoder.onConfiguration = { [weak audioHub] configuration in
                audioHub?.publish(configuration: configuration)
            }
            audioEncoder.onPacket = { [weak audioHub] packet in
                audioHub?.publish(packet: packet)
            }
            audioEncoder.onPCMConfiguration = { [weak pcmAudioHub] configuration in
                pcmAudioHub?.publish(configuration: configuration)
            }
            audioEncoder.onPCMPacket = { [weak pcmAudioHub] packet in
                pcmAudioHub?.publish(packet: packet)
            }

            let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
            provisionalGroup = group
            let upgrader = NIOWebSocketServerUpgrader(
                maxFrameSize: 4 * 1_024 * 1_024,
                shouldUpgrade: { [weak runtime] channel, request in
                    guard let runtime else {
                        return channel.eventLoop.makeSucceededFuture(nil)
                    }
                    return runtime.shouldUpgrade(channel: channel, request: request)
                },
                upgradePipelineHandler: { [weak runtime] channel, request in
                    guard let runtime else {
                        return channel.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
                    }
                    return runtime.installWebSocketPipeline(channel: channel, request: request)
                }
            )
            let upgradeConfiguration: NIOHTTPServerUpgradeConfiguration = (
                upgraders: [upgrader],
                completionHandler: { context in
                    // This application handler is added after NIO's built-in
                    // HTTP handlers, so the upgrader cannot remove it as one
                    // of its `extraHTTPHandlers`. Remove it synchronously before
                    // WebSocket frames begin flowing through the pipeline.
                    context.pipeline.syncOperations.removeHandler(
                        name: WebHTTPHandler.pipelineName,
                        promise: nil
                    )
                }
            )
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(.backlog, value: 128)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline(
                        withServerUpgrade: upgradeConfiguration,
                        withErrorHandling: true
                    ).flatMap {
                        channel.pipeline.addHandler(
                            WebHTTPHandler(runtime: runtime),
                            name: WebHTTPHandler.pipelineName
                        )
                    }
                }
                .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
                .childChannelOption(.maxMessagesPerRead, value: 16)

            let channel = try bootstrap.bind(host: Self.bindHost, port: Self.port).wait()
            provisionalChannel = channel

            stateLock.lock()
            guard storedState == .starting else {
                stateLock.unlock()
                try? channel.close().wait()
                try? group.syncShutdownGracefully()
                return
            }
            eventLoopGroup = group
            serverChannel = channel
            self.runtime = runtime
            provisionalChannel = nil
            provisionalGroup = nil
            stateLock.unlock()

            encoder.start()
            audioEncoder.start()
            let observerToken = capture.addSampleBufferObserver { [weak encoder] sampleBuffer, timing in
                encoder?.submit(sampleBuffer, timing: timing)
            }
            stateLock.lock()
            captureObserverToken = observerToken
            stateLock.unlock()
            let audioObserverToken = capture.addAudioSampleBufferObserver { [weak audioEncoder] sampleBuffer, timing in
                audioEncoder?.submit(sampleBuffer, timing: timing)
            }
            stateLock.lock()
            captureAudioObserverToken = audioObserverToken
            stateLock.unlock()
            startExpiryTimer(runtime: runtime)

            setState(.running)
        } catch {
            try? provisionalChannel?.close().wait()
            try? provisionalGroup?.syncShutdownGracefully()
            performStop(finalState: .failed(error.localizedDescription))
        }
    }

    private func performStop(finalState: State) {
        expiryTimer?.setEventHandler {}
        expiryTimer?.cancel()
        expiryTimer = nil

        stateLock.lock()
        let observerToken = captureObserverToken
        captureObserverToken = nil
        let audioObserverToken = captureAudioObserverToken
        captureAudioObserverToken = nil
        let runtime = self.runtime
        self.runtime = nil
        let channel = serverChannel
        serverChannel = nil
        let group = eventLoopGroup
        eventLoopGroup = nil
        stateLock.unlock()

        if let observerToken {
            capture.removeSampleBufferObserver(observerToken)
        }
        if let audioObserverToken {
            capture.removeAudioSampleBufferObserver(audioObserverToken)
        }
        runtime?.shutdown()
        runtime?.encoder.stop()
        runtime?.audioEncoder.stop()
        statusStore.onChange = nil
        try? channel?.close().wait()
        try? group?.syncShutdownGracefully()
        setState(finalState)
    }

    private func startExpiryTimer(runtime: WebConsoleRuntime) {
        let timer = DispatchSource.makeTimerSource(queue: lifecycleQueue)
        timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(1))
        timer.setEventHandler { [weak runtime] in
            runtime?.expireSessions()
        }
        timer.resume()
        expiryTimer = timer
    }

    private func setState(_ state: State) {
        stateLock.lock()
        storedState = state
        stateLock.unlock()
        notifyState(state)
    }

    private func notifyState(_ state: State) {
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(state)
        }
    }
}
